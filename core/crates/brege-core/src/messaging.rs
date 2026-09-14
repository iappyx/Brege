//! Messages and calls.
//!
//! The phone owns SMS/MMS/RCS data and telephony; the Mac caches messages in its encrypted store
//! and sends requests. Handlers here run on both sides; the role follows from the message type.

use std::sync::Arc;

use brege_features::messages::{self, SYNC_BATCH};
use brege_identity::DeviceId;
use brege_proto::v1::{self as proto, envelope::Payload};
use brege_store::{MessageRecord, SimRecord, ThreadRecord};

use crate::node::Inner;
use crate::{Event, Result};

/// Initial sync window: enough history to be useful without flooding the link.
const INITIAL_THREADS: u32 = 100;
const INITIAL_PER_THREAD: u32 = 50;
/// Overlap for incremental syncs so status changes of recent messages are picked up.
const RESYNC_OVERLAP_MS: i64 = 24 * 60 * 60 * 1000;

// --- Mac side -------------------------------------------------------------------------------

/// Asks a phone for threads and messages newer than the local cache.
pub(crate) fn request_sync(inner: &Inner, phone: &DeviceId) -> Result<()> {
    let newest = inner.store.lock().unwrap().newest_message_ms(phone)?;
    let since_ms = newest
        .map(|ms| ms.saturating_sub(RESYNC_OVERLAP_MS).max(0))
        .unwrap_or(0);
    tracing::info!(peer = ?phone, since_ms, "requesting message sync");
    inner.send_to(
        phone,
        Payload::SmsSyncRequest(proto::SmsSyncRequest {
            since_ms,
            max_threads: INITIAL_THREADS,
            messages_per_thread: INITIAL_PER_THREAD,
        }),
    )
}

pub(crate) fn thread_record(device: DeviceId, t: &proto::SmsThread) -> ThreadRecord {
    ThreadRecord {
        device_id: device,
        id: t.id.clone(),
        addresses: t.addresses.clone(),
        names: t.names.clone(),
        title: t.title.clone(),
        snippet: t.snippet.clone(),
        last_ms: t.last_ms,
        kind: t.kind,
        can_reply: t.can_reply,
        unread: false,
    }
}

pub(crate) fn message_record(device: DeviceId, m: &proto::SmsMessage) -> MessageRecord {
    MessageRecord {
        device_id: device,
        id: m.id.clone(),
        thread_id: m.thread_id.clone(),
        address: m.address.clone(),
        sender_name: m.sender_name.clone(),
        body: m.body.clone(),
        ts_ms: m.ts_ms,
        outgoing: m.outgoing,
        sub_id: m.sub_id,
        status: m.status,
        has_media: m.has_media,
        kind: m.kind,
    }
}

fn handle_threads(inner: &Inner, from: DeviceId, list: proto::SmsThreadList) {
    let store = inner.store.lock().unwrap();
    let mut ids = Vec::with_capacity(list.threads.len());
    for t in &list.threads {
        if !valid_thread_id(&t.id) {
            continue;
        }
        if let Err(e) = store.upsert_thread(&thread_record(from, t), false) {
            tracing::warn!("cannot store thread: {e}");
            continue;
        }
        ids.push(t.id.clone());
    }
    drop(store);
    if !ids.is_empty() {
        inner.emit(Event::MessagesUpdated {
            from,
            thread_ids: ids,
            new_incoming: 0,
        });
    }
}

fn handle_messages(inner: &Inner, from: DeviceId, list: proto::SmsMessageList) {
    let store = inner.store.lock().unwrap();
    let mut ids: Vec<String> = Vec::new();
    let mut new_incoming = 0u32;
    for m in &list.messages {
        if !valid_thread_id(&m.thread_id) || m.id.is_empty() {
            continue;
        }
        match store.upsert_message(&message_record(from, m)) {
            Ok(is_new) => {
                // Only live pushes make a thread unread; syncs and history pages never do.
                if is_new && !m.outgoing && !list.history && is_recent(m.ts_ms) {
                    new_incoming += 1;
                    let _ = store.set_thread_unread(&from, &m.thread_id, true);
                }
                if !ids.contains(&m.thread_id) {
                    ids.push(m.thread_id.clone());
                }
            }
            Err(e) => tracing::warn!("cannot store message: {e}"),
        }
    }
    drop(store);
    if !ids.is_empty() {
        inner.emit(Event::MessagesUpdated {
            from,
            thread_ids: ids,
            new_incoming,
        });
    }
}

/// Messages from the last ten minutes count as "new" when they first arrive.
fn is_recent(ts_ms: i64) -> bool {
    // The phone supplies the time: any value must be safe.
    crate::now_ms().saturating_sub(ts_ms) < 10 * 60 * 1000
}

fn valid_thread_id(id: &str) -> bool {
    (id.starts_with("sms:") || id.starts_with("rcs:")) && id.len() > 4 && id.len() <= 200
}

// --- dispatch -------------------------------------------------------------------------------

/// Returns the payload back if it is not a messaging or call message.
pub(crate) fn dispatch(inner: &Arc<Inner>, from: DeviceId, payload: Payload) -> Option<Payload> {
    match payload {
        // Phone → Mac
        Payload::SmsThreads(list) => handle_threads(inner, from, list),
        Payload::SmsMessages(list) => handle_messages(inner, from, list),
        Payload::SmsSendStatus(status) => inner.emit(Event::SmsSendStatus { from, status }),
        Payload::Sims(list) => {
            let sims: Vec<SimRecord> = list
                .sims
                .iter()
                .map(|s| SimRecord {
                    sub_id: s.sub_id,
                    label: s.label.clone(),
                    slot: s.slot,
                })
                .collect();
            if let Err(e) = inner.store.lock().unwrap().replace_sims(&from, &sims) {
                tracing::warn!("cannot store SIMs: {e}");
            }
            inner.emit(Event::SimsUpdated {
                from,
                sims: list.sims,
            });
        }
        Payload::CallState(call) => inner.emit(Event::CallStateChanged { from, call }),
        Payload::ContactPhotos(list) => {
            let photos = list
                .photos
                .into_iter()
                .map(|mut p| {
                    if p.jpeg.len() > messages::MAX_PHOTO_BYTES {
                        p.jpeg.clear();
                    }
                    p
                })
                .collect();
            inner.emit(Event::ContactPhotosReceived { from, photos });
        }

        // Mac → phone
        Payload::SmsSyncRequest(request) => inner.emit(Event::SmsSyncRequested { from, request }),
        Payload::ContactPhotoRequest(request) => {
            let addresses = messages::sanitize_photo_addresses(request.addresses);
            if !addresses.is_empty() {
                inner.emit(Event::ContactPhotosRequested { from, addresses });
            }
        }
        Payload::SmsHistoryRequest(request) => {
            if valid_thread_id(&request.thread_id) {
                inner.emit(Event::SmsHistoryRequested { from, request });
            }
        }
        Payload::SmsSend(send) => match messages::validate_send(&send) {
            Ok(()) => inner.emit(Event::SmsSendRequested { from, send }),
            Err(e) => {
                tracing::info!("rejecting send request: {e}");
                let _ = inner.send_to(
                    &from,
                    Payload::SmsSendStatus(proto::SmsSendStatus {
                        client_id: send.client_id,
                        status: proto::sms_message::Status::Failed as i32,
                        error: e.to_string(),
                    }),
                );
            }
        },
        Payload::CallAction(action) => match messages::validate_call_action(&action) {
            Ok(_) => inner.emit(Event::CallActionRequested { from, action }),
            Err(e) => tracing::info!("rejecting call action: {e}"),
        },
        other => return Some(other),
    }
    None
}

// --- phone side publishing ------------------------------------------------------------------

/// Sends threads to every connected peer, in batches.
pub(crate) async fn publish_threads(inner: &Inner, threads: Vec<proto::SmsThread>) -> usize {
    let mut sent = 0;
    for batch in threads.chunks(SYNC_BATCH) {
        sent = inner
            .broadcast_reliable(Payload::SmsThreads(proto::SmsThreadList {
                threads: batch.to_vec(),
            }))
            .await;
    }
    sent
}

/// Sends messages to every connected peer, in batches.
pub(crate) async fn publish_messages(
    inner: &Inner,
    messages: Vec<proto::SmsMessage>,
    history: bool,
) -> usize {
    let mut sent = 0;
    for batch in messages.chunks(SYNC_BATCH) {
        sent = inner
            .broadcast_reliable(Payload::SmsMessages(proto::SmsMessageList {
                messages: batch.to_vec(),
                history,
            }))
            .await;
    }
    sent
}

#[cfg(test)]
mod tests {
    #[test]
    fn phone_timestamps_never_overflow() {
        assert!(!super::is_recent(i64::MIN));
        assert!(super::is_recent(i64::MAX));
        assert!(super::is_recent(crate::now_ms()));
    }
}
