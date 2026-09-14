//! File transfer orchestration: offers, uploads, verified receives and resume.

use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use brege_identity::DeviceId;
use brege_proto::StreamType;
use brege_proto::v1::{self as proto, envelope::Payload};
use brege_store::{TransferDirection, TransferRecord, TransferState};
use brege_transfer::{DEFAULT_CHUNK_SIZE, Manifest, Offer, Receiver, TransferError};
use brege_transport::{RecvStream, SendStream, read_msg, write_msg};
use tokio::sync::oneshot;

use crate::node::Inner;
use crate::{CoreError, Event, Result};

const ACCEPT_TIMEOUT: Duration = Duration::from_secs(60);
const PROGRESS_INTERVAL: Duration = Duration::from_millis(250);

pub(crate) async fn send_file(inner: &Arc<Inner>, peer: DeviceId, path: PathBuf) -> Result<String> {
    if !inner.is_connected(&peer) {
        return Err(CoreError::NotConnected);
    }
    let manifest = Manifest::from_file(&path, DEFAULT_CHUNK_SIZE).await?;
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .ok_or_else(|| CoreError::InvalidInput("path has no file name".into()))?;
    let record = TransferRecord {
        id: crate::random_hex(16),
        device_id: peer,
        direction: TransferDirection::Outgoing,
        name,
        size: manifest.size,
        chunk_size: manifest.chunk_size,
        root_hash: manifest.root(),
        state: TransferState::Offered,
        path: Some(path.to_string_lossy().into_owned()),
        created_at_ms: crate::now_ms(),
    };
    inner.store.lock().unwrap().insert_transfer(&record)?;
    let id = record.id.clone();
    offer_and_upload(inner.clone(), record, manifest, path)?;
    Ok(id)
}

/// Re-offers unfinished outgoing transfers when a peer reconnects.
pub(crate) async fn resume_outgoing(inner: Arc<Inner>, peer: DeviceId) {
    let pending = match inner.store.lock().unwrap().unfinished_outgoing(&peer) {
        Ok(p) => p,
        Err(e) => {
            tracing::warn!("cannot load unfinished transfers: {e}");
            return;
        }
    };
    for record in pending {
        if inner
            .pending_accepts
            .lock()
            .unwrap()
            .contains_key(&record.id)
        {
            continue; // already in flight
        }
        let Some(path) = record.path.clone().map(PathBuf::from) else {
            continue;
        };
        match Manifest::from_file(&path, record.chunk_size).await {
            Ok(manifest) if manifest.root() == record.root_hash => {
                tracing::info!(id = %record.id, "resuming transfer");
                if let Err(e) = offer_and_upload(inner.clone(), record, manifest, path) {
                    tracing::debug!("resume failed: {e}");
                }
            }
            _ => fail(
                &inner,
                peer,
                &record.id,
                "source file changed or missing",
                false,
            ),
        }
    }
}

fn offer_and_upload(
    inner: Arc<Inner>,
    record: TransferRecord,
    manifest: Manifest,
    path: PathBuf,
) -> Result<()> {
    let (tx, rx) = oneshot::channel();
    inner
        .pending_accepts
        .lock()
        .unwrap()
        .insert(record.id.clone(), tx);
    let offer = proto::TransferOffer {
        id: record.id.clone(),
        name: record.name.clone(),
        size: record.size,
        mime: String::new(),
        root_hash: record.root_hash.to_vec(),
        chunk_size: record.chunk_size,
    };
    if let Err(e) = inner.send_to(&record.device_id, Payload::TransferOffer(offer)) {
        inner.pending_accepts.lock().unwrap().remove(&record.id);
        return Err(e);
    }

    tokio::spawn(async move {
        let peer = record.device_id;
        let id = record.id.clone();
        let accept = match tokio::time::timeout(ACCEPT_TIMEOUT, rx).await {
            Ok(Ok(accept)) => accept,
            _ => {
                inner.pending_accepts.lock().unwrap().remove(&id);
                // Stays Offered in the store, so it is re-offered on the next connection.
                tracing::info!(%id, "transfer offer not answered");
                return;
            }
        };
        match upload(&inner, &record, &manifest, &path, accept).await {
            Ok(()) => {
                let _ = inner.store.lock().unwrap().set_transfer_state(
                    &id,
                    TransferState::Complete,
                    None,
                );
                inner.emit(Event::TransferCompleted {
                    peer,
                    id,
                    path,
                    incoming: false,
                });
            }
            Err(e) => {
                // Connection loss keeps the transfer resumable; only data errors fail it.
                tracing::info!(%id, "upload interrupted: {e}");
                if matches!(e, CoreError::Transfer(TransferError::ChunkMismatch(_))) {
                    fail(
                        &inner,
                        peer,
                        &id,
                        "source file changed during transfer",
                        false,
                    );
                }
            }
        }
    });
    Ok(())
}

async fn upload(
    inner: &Arc<Inner>,
    record: &TransferRecord,
    manifest: &Manifest,
    path: &std::path::Path,
    accept: proto::TransferAccept,
) -> Result<()> {
    let conn = inner
        .sessions
        .lock()
        .unwrap()
        .get(&record.device_id)
        .map(|s| s.conn.clone())
        .ok_or(CoreError::NotConnected)?;
    inner
        .store
        .lock()
        .unwrap()
        .set_transfer_state(&record.id, TransferState::InProgress, None)?;

    let (mut send, mut recv) = conn.open_stream(StreamType::File).await?;
    write_msg(
        &mut send,
        &proto::FileStreamHeader {
            transfer_id: record.id.clone(),
        },
    )
    .await?;
    let have: BTreeSet<u32> = accept.have_chunks.into_iter().collect();
    let mut last_event = Instant::now();
    let total = record.size;
    brege_transfer::send_file(&mut send, path, manifest, &have, |bytes| {
        if last_event.elapsed() >= PROGRESS_INTERVAL {
            last_event = Instant::now();
            inner.emit(Event::TransferProgress {
                peer: record.device_id,
                id: record.id.clone(),
                bytes,
                total,
                incoming: false,
            });
        }
    })
    .await?;
    send.finish().map_err(|_| CoreError::NotConnected)?;
    // The receiver answers with one status byte after verifying and moving the file into place,
    // so "complete" on this side means verified on the other.
    let mut status = [0u8; 1];
    match recv.read_exact(&mut status).await {
        Ok(()) if status[0] == STATUS_OK => Ok(()),
        Ok(()) => Err(CoreError::InvalidInput("receiver rejected the file".into())),
        Err(_) => Err(CoreError::NotConnected),
    }
}

const STATUS_OK: u8 = 0;
const STATUS_FAILED: u8 = 1;

pub(crate) fn handle_offer(inner: &Arc<Inner>, from: DeviceId, offer: proto::TransferOffer) {
    let Ok(root_hash) = <[u8; 32]>::try_from(offer.root_hash.as_slice()) else {
        return;
    };
    let checked = Offer {
        id: offer.id.clone(),
        name: String::new(),
        size: offer.size,
        chunk_size: offer.chunk_size,
        root_hash,
    };
    if let Err(e) = brege_transfer::validate_offer(&checked) {
        tracing::warn!("rejecting file offer: {e}");
        return;
    }
    let store = inner.store.lock().unwrap();
    let mut offered = None;
    let have = match store.transfer(&offer.id) {
        Ok(Some(existing))
            if existing.device_id == from
                && existing.direction == TransferDirection::Incoming
                && existing.root_hash == root_hash =>
        {
            if existing.state == TransferState::Complete {
                // Already done (the sender missed our completion); report everything present.
                (0..brege_transfer::chunk_count(existing.size, existing.chunk_size)).collect()
            } else if part_file_intact(inner, &existing) {
                store.transfer_chunks(&offer.id).unwrap_or_default()
            } else {
                // The partial file was deleted or damaged: receive everything again.
                let _ = store.clear_transfer_chunks(&offer.id);
                BTreeSet::new()
            }
        }
        Ok(Some(_)) => {
            tracing::warn!(id = %offer.id, "transfer id collision; rejecting offer");
            return;
        }
        Ok(None) => {
            let record = TransferRecord {
                id: offer.id.clone(),
                device_id: from,
                direction: TransferDirection::Incoming,
                name: brege_transfer::sanitize_file_name(&offer.name),
                size: offer.size,
                chunk_size: offer.chunk_size,
                root_hash,
                state: TransferState::Offered,
                path: None,
                created_at_ms: crate::now_ms(),
            };
            if let Err(e) = store.insert_transfer(&record) {
                tracing::warn!("cannot record incoming transfer: {e}");
                return;
            }
            offered = Some(record.name);
            BTreeSet::new()
        }
        Err(e) => {
            tracing::warn!("store error on offer: {e}");
            return;
        }
    };
    // Never call into the shell while holding the store lock: its handler may call back in.
    drop(store);
    if let Some(name) = offered {
        inner.emit(Event::TransferOffered {
            from,
            id: offer.id.clone(),
            name,
            size: offer.size,
        });
    }
    // Auto-accept is the default; a confirmation setting would hold this reply.
    let _ = inner.send_to(
        &from,
        Payload::TransferAccept(proto::TransferAccept {
            id: offer.id,
            have_chunks: have.into_iter().collect(),
        }),
    );
}

pub(crate) async fn receive_stream(
    inner: Arc<Inner>,
    from: DeviceId,
    mut send: SendStream,
    mut recv: RecvStream,
) {
    let header: proto::FileStreamHeader = match read_msg(&mut recv).await {
        Ok(Some(h)) => h,
        _ => return,
    };
    let id = header.transfer_id;
    let record = match inner.store.lock().unwrap().transfer(&id) {
        Ok(Some(r)) if r.device_id == from && r.direction == TransferDirection::Incoming => r,
        _ => {
            let _ = recv.stop(1u32.into());
            return;
        }
    };
    if record.state == TransferState::Complete {
        // Drain the (chunk-less) stream so the sender's writes succeed, then confirm.
        let _ = recv.read_to_end(64 * 1024 * 1024).await;
        let _ = send.write_all(&[STATUS_OK]).await;
        let _ = send.finish();
        return;
    }
    let have = inner
        .store
        .lock()
        .unwrap()
        .transfer_chunks(&id)
        .unwrap_or_default();
    let offer = Offer {
        id: id.clone(),
        name: record.name.clone(),
        size: record.size,
        chunk_size: record.chunk_size,
        root_hash: record.root_hash,
    };
    let _ = inner
        .store
        .lock()
        .unwrap()
        .set_transfer_state(&id, TransferState::InProgress, None);

    let mut receiver = match Receiver::new(offer, inner.config.download_dir.clone(), have) {
        Ok(r) => r,
        Err(e) => {
            fail(&inner, from, &id, &e.to_string(), true);
            return;
        }
    };
    let mut last_event = Instant::now();
    let result = receiver
        .receive(&mut recv, |index, bytes| {
            if let Err(e) = inner.store.lock().unwrap().add_transfer_chunk(&id, index) {
                tracing::warn!("cannot persist chunk state: {e}");
            }
            if last_event.elapsed() >= PROGRESS_INTERVAL {
                last_event = Instant::now();
                inner.emit(Event::TransferProgress {
                    peer: from,
                    id: id.clone(),
                    bytes,
                    total: record.size,
                    incoming: true,
                });
            }
        })
        .await;

    match result {
        Ok(()) => match receiver.finish().await {
            Ok(path) => {
                let _ = inner.store.lock().unwrap().set_transfer_state(
                    &id,
                    TransferState::Complete,
                    Some(&path.to_string_lossy()),
                );
                let _ = send.write_all(&[STATUS_OK]).await;
                let _ = send.finish();
                inner.emit(Event::TransferCompleted {
                    peer: from,
                    id,
                    path,
                    incoming: true,
                });
            }
            // Stream ended early (disconnect): keep InProgress for resume.
            Err(TransferError::Incomplete { missing }) => {
                tracing::info!(%id, missing, "incoming transfer incomplete; will resume");
            }
            Err(e) => {
                let _ = send.write_all(&[STATUS_FAILED]).await;
                fail(&inner, from, &id, &e.to_string(), true)
            }
        },
        Err(TransferError::Io(e)) => {
            tracing::info!(%id, "incoming transfer interrupted: {e}");
        }
        Err(e) => {
            if matches!(e, TransferError::PartMissing) {
                // The next offer of this file then sends every chunk again.
                let _ = inner.store.lock().unwrap().clear_transfer_chunks(&id);
            }
            let _ = send.write_all(&[STATUS_FAILED]).await;
            let _ = recv.stop(2u32.into());
            fail(&inner, from, &id, &e.to_string(), true);
        }
    }
}

/// Whether the partial file of an interrupted incoming transfer is still there, at full length.
fn part_file_intact(inner: &Inner, record: &TransferRecord) -> bool {
    std::fs::metadata(brege_transfer::part_path(
        &inner.config.download_dir,
        &record.id,
    ))
    .is_ok_and(|m| m.len() == record.size)
}

/// Deletes the partial file of an incoming transfer that will not be resumed.
fn remove_part_file(inner: &Inner, id: &str) {
    if brege_transfer::valid_id(id) {
        let _ = std::fs::remove_file(brege_transfer::part_path(&inner.config.download_dir, id));
    }
}

pub(crate) fn handle_cancel(inner: &Arc<Inner>, from: DeviceId, cancel: proto::TransferCancel) {
    let incoming = match inner.store.lock().unwrap().transfer(&cancel.id) {
        Ok(Some(r)) if r.device_id == from => r.direction == TransferDirection::Incoming,
        _ => return,
    };
    let _ =
        inner
            .store
            .lock()
            .unwrap()
            .set_transfer_state(&cancel.id, TransferState::Cancelled, None);
    if incoming {
        remove_part_file(inner, &cancel.id);
    }
    inner.emit(Event::TransferFailed {
        peer: from,
        id: cancel.id,
        reason: format!("cancelled by peer: {}", cancel.reason),
        incoming,
    });
}

fn fail(inner: &Inner, peer: DeviceId, id: &str, reason: &str, incoming: bool) {
    let _ = inner
        .store
        .lock()
        .unwrap()
        .set_transfer_state(id, TransferState::Failed, None);
    if incoming {
        remove_part_file(inner, id);
    }
    let _ = inner.send_to(
        &peer,
        Payload::TransferCancel(proto::TransferCancel {
            id: id.to_string(),
            reason: reason.to_string(),
        }),
    );
    inner.emit(Event::TransferFailed {
        peer,
        id: id.to_string(),
        reason: reason.to_string(),
        incoming,
    });
}
