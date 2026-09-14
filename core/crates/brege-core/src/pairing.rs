//! QR pairing: invite creation, the responder (Mac) and the initiator (phone).

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, SystemTime};

use brege_identity::{
    PairingInvite, PairingToken, PresenceKey, pairing_proof, verify_pairing_proof,
};
use brege_proto::StreamType;
use brege_proto::v1::{self as proto, pair_response};
use brege_store::DeviceRecord;
use brege_transport::{Connection, read_msg, write_msg};
use tokio::sync::oneshot;

use crate::node::{DeviceInfo, Inner};
use crate::{CoreError, Event, Result};

const INVITE_LIFETIME: Duration = Duration::from_secs(5 * 60);
const USER_DECISION_TIMEOUT: Duration = Duration::from_secs(120);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(6);

pub(crate) struct PendingInvite {
    token: PairingToken,
}

pub(crate) fn create_invite(inner: &Arc<Inner>, mut addrs: Vec<SocketAddr>) -> Result<String> {
    let port = inner.endpoint.local_addr()?.port();
    for addr in &mut addrs {
        if addr.port() == 0 {
            addr.set_port(port);
        }
    }
    if addrs.is_empty() {
        addrs.push(inner.endpoint.local_addr()?);
    }
    let token = PairingToken::generate()?;
    let invite = PairingInvite {
        device_id: inner.id,
        token: *token.as_bytes(),
        name: inner.config.name.clone(),
        addrs,
    };
    *inner.invite.lock().unwrap() = Some(PendingInvite {
        token: token.clone(),
    });
    set_window_open(inner, true);

    let weak = Arc::downgrade(inner);
    tokio::spawn(async move {
        tokio::time::sleep(INVITE_LIFETIME).await;
        if let Some(inner) = weak.upgrade() {
            let mut invite = inner.invite.lock().unwrap();
            if invite.as_ref().is_some_and(|i| i.token == token) {
                *invite = None;
                drop(invite);
                set_window_open(&inner, false);
            }
        }
    });
    Ok(invite.to_uri())
}

/// While the window is open, any Wi‑Fi or Ethernet network may be used.
fn set_window_open(inner: &Inner, open: bool) {
    inner.endpoint.set_pairing_open(open);
    inner.network_rules_changed();
}

pub(crate) fn close_window(inner: &Inner) {
    *inner.invite.lock().unwrap() = None;
    set_window_open(inner, false);
}

/// Closes the pairing window if it still holds the unexpired `token`. Returns whether it did.
fn consume_token(inner: &Inner, token: &[u8; 32]) -> bool {
    let mut invite = inner.invite.lock().unwrap();
    let valid = invite
        .as_ref()
        .is_some_and(|i| i.token.as_bytes() == token && !i.token.is_expired(SystemTime::now()));
    if valid {
        *invite = None;
        drop(invite);
        set_window_open(inner, false);
    }
    valid
}

/// Responder side: verify the proof, ask the user, store the peer.
pub(crate) async fn respond(inner: &Arc<Inner>, conn: Connection) -> Result<()> {
    let (kind, mut send, mut recv) =
        tokio::time::timeout(REQUEST_TIMEOUT, conn.accept_stream()).await??;
    if kind != StreamType::Control {
        return Err(CoreError::InvalidInput(
            "pairing expects a control stream".into(),
        ));
    }
    let request: proto::PairRequest = tokio::time::timeout(REQUEST_TIMEOUT, read_msg(&mut recv))
        .await??
        .ok_or_else(|| CoreError::InvalidInput("missing PairRequest".into()))?;

    let token = inner
        .invite
        .lock()
        .unwrap()
        .as_ref()
        .filter(|i| !i.token.is_expired(SystemTime::now()))
        .map(|i| *i.token.as_bytes());

    let reply = |result: pair_response::Result| proto::PairResponse {
        result: result as i32,
        name: inner.config.name.clone(),
        platform: inner.config.platform as i32,
        presence_key: Vec::new(),
    };

    let Some(token) = token else {
        write_msg(&mut send, &reply(pair_response::Result::TokenExpired)).await?;
        return finish(conn, send).await;
    };
    let exporter = conn.pairing_exporter()?;
    if !verify_pairing_proof(&token, &exporter, &request.proof) {
        tracing::warn!(peer = ?conn.peer(), "pairing proof rejected");
        write_msg(&mut send, &reply(pair_response::Result::InvalidProof)).await?;
        return finish(conn, send).await;
    }

    let accepted = if inner.config.auto_accept_pairing {
        true
    } else {
        let request_id = inner.next_request_id.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        inner.pair_decisions.lock().unwrap().insert(request_id, tx);
        inner.emit(Event::PairingRequested {
            request_id,
            device_id: conn.peer(),
            name: request.name.clone(),
            platform: proto::Platform::try_from(request.platform).unwrap_or_default(),
        });
        let decision = tokio::time::timeout(USER_DECISION_TIMEOUT, rx).await;
        inner.pair_decisions.lock().unwrap().remove(&request_id);
        matches!(decision, Ok(Ok(true)))
    };

    if !accepted {
        write_msg(&mut send, &reply(pair_response::Result::RejectedByUser)).await?;
        return finish(conn, send).await;
    }

    // The token is single-use: consume it before storing the peer. The window may have been
    // cancelled, expired or used by another device while the user was deciding.
    if !consume_token(inner, &token) {
        write_msg(&mut send, &reply(pair_response::Result::TokenExpired)).await?;
        return finish(conn, send).await;
    }
    let presence_key = PresenceKey::generate()?;
    let record = DeviceRecord {
        id: conn.peer(),
        name: request.name,
        platform: request.platform,
        presence_key: presence_key.clone(),
        paired_at_ms: crate::now_ms(),
        last_seen_ms: None,
        last_addr: None,
    };
    // The phone may have given up while the user was deciding. Only a delivered answer pairs, so
    // this side never keeps a device that does not know it.
    let mut response = reply(pair_response::Result::Accepted);
    response.presence_key = presence_key.as_bytes().to_vec();
    if conn.is_closed() {
        return Err(CoreError::NotConnected);
    }
    write_msg(&mut send, &response).await?;
    inner.store.lock().unwrap().upsert_device(&record)?;
    inner.trust.add(record.id);
    // The network the pairing happened on is trusted from now on.
    inner.connected_over(conn.remote_addr(), record.id, true);
    inner.emit(Event::DevicePaired {
        device: inner.device_info(&record),
    });
    finish(conn, send).await
}

async fn finish(conn: Connection, mut send: brege_transport::SendStream) -> Result<()> {
    let _ = send.finish();
    // Let the initiator read the response and close first.
    let _ = tokio::time::timeout(Duration::from_secs(5), conn.closed()).await;
    Ok(())
}

/// Initiator side (phone): connect using the key from the QR code and prove the token.
pub(crate) async fn pair_with_invite(inner: &Arc<Inner>, uri: &str) -> Result<DeviceInfo> {
    let invite = PairingInvite::parse(uri)?;
    if invite.device_id == inner.id {
        return Err(CoreError::InvalidInput("cannot pair with self".into()));
    }
    if invite.addrs.is_empty() {
        return Err(CoreError::PairingFailed(
            "the pairing code has no addresses".into(),
        ));
    }
    let (conn, addr) = connect_any(inner, &invite).await?;
    // The Mac answers only once its user confirms; its packets must pass the socket filter until
    // then, on a network this device may not use otherwise.
    let _hold = inner.hold_address(addr);
    tracing::info!(%addr, "reached {} for pairing; waiting for confirmation", invite.name);
    inner.emit(Event::PairingWaitingForConfirmation {
        name: invite.name.clone(),
    });
    try_pair(inner, &invite, conn, addr).await
}

/// Dials every address in the invite at once and keeps the first that answers (a Mac often
/// has several interfaces, e.g. Wi‑Fi, Ethernet and virtual-machine bridges).
async fn connect_any(
    inner: &Arc<Inner>,
    invite: &PairingInvite,
) -> Result<(Connection, SocketAddr)> {
    let mut attempts = tokio::task::JoinSet::new();
    for addr in invite.addrs.clone() {
        let endpoint = inner.endpoint.clone();
        let peer = invite.device_id;
        attempts.spawn(async move {
            tracing::info!(%addr, "pairing: dialling");
            let result =
                tokio::time::timeout(CONNECT_TIMEOUT, endpoint.connect_pairing(addr, peer)).await;
            (addr, result)
        });
    }
    let mut failures = Vec::new();
    while let Some(joined) = attempts.join_next().await {
        let Ok((addr, result)) = joined else { continue };
        match result {
            Ok(Ok(conn)) => {
                attempts.abort_all();
                return Ok((conn, addr));
            }
            Ok(Err(e)) => {
                tracing::warn!(%addr, "pairing: connection failed: {e}");
                failures.push(format!("{addr} ({e})"));
            }
            Err(_) => {
                tracing::warn!(%addr, "pairing: no answer within {CONNECT_TIMEOUT:?}");
                failures.push(format!("{addr} (no answer)"));
            }
        }
    }
    Err(CoreError::PairingFailed(format!(
        "Could not reach {} at {}. Make sure both devices are on the same Wi‑Fi network, the pairing \
         window is still open on the Mac, and the network does not isolate devices.",
        invite.name,
        failures.join(", ")
    )))
}

async fn try_pair(
    inner: &Arc<Inner>,
    invite: &PairingInvite,
    conn: Connection,
    addr: SocketAddr,
) -> Result<DeviceInfo> {
    let (mut send, mut recv) = conn.open_stream(StreamType::Control).await?;
    let request = proto::PairRequest {
        name: inner.config.name.clone(),
        platform: inner.config.platform as i32,
        model: String::new(),
        proof: pairing_proof(&invite.token, &conn.pairing_exporter()?).to_vec(),
    };
    write_msg(&mut send, &request).await?;
    let response: proto::PairResponse =
        tokio::time::timeout(USER_DECISION_TIMEOUT + REQUEST_TIMEOUT, read_msg(&mut recv))
            .await??
            .ok_or_else(|| CoreError::PairingFailed("no response".into()))?;
    conn.close(0, b"paired");

    let result = pair_response::Result::try_from(response.result).unwrap_or_default();
    match result {
        pair_response::Result::Accepted => {}
        pair_response::Result::RejectedByUser => {
            return Err(CoreError::PairingFailed(
                "RejectedByUser: pairing was declined on the Mac".into(),
            ));
        }
        pair_response::Result::TokenExpired => {
            return Err(CoreError::PairingFailed(
                "TokenExpired: the pairing code expired or the window was closed; show a new code"
                    .into(),
            ));
        }
        other => return Err(CoreError::PairingFailed(format!("{other:?}"))),
    }
    let presence_key: [u8; 32] = response
        .presence_key
        .try_into()
        .map_err(|_| CoreError::PairingFailed("bad presence key".into()))?;
    let record = DeviceRecord {
        id: invite.device_id,
        name: if response.name.is_empty() {
            invite.name.clone()
        } else {
            response.name
        },
        platform: response.platform,
        presence_key: PresenceKey::from_bytes(presence_key),
        paired_at_ms: crate::now_ms(),
        last_seen_ms: None,
        last_addr: Some(addr.to_string()),
    };
    inner.store.lock().unwrap().upsert_device(&record)?;
    inner.trust.add(record.id);
    inner.connected_over(addr, record.id, true);
    inner.dial_now.notify_one();
    let info = inner.device_info(&record);
    inner.emit(Event::DevicePaired {
        device: info.clone(),
    });
    Ok(info)
}
