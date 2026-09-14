//! Per-peer sessions: control-stream handshake, writer/reader tasks, duplicate resolution.

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use brege_identity::DeviceId;
use brege_proto::StreamType;
use brege_proto::v1::{self as proto, Envelope, envelope::Payload};
use brege_transport::{Connection, RecvStream, SendStream, TrustStore, read_msg, write_msg};
use tokio::sync::mpsc;

use crate::node::Inner;
use crate::{
    CoreError, Event, Result, audio, dialer, files, messaging, pairing, router, transfers,
};

const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);
/// Two connections created within this window are a simultaneous dial, resolved by id order.
const SIMULTANEOUS_WINDOW: Duration = Duration::from_secs(3);
const OUTBOX: usize = 256;

pub(crate) struct SessionHandle {
    pub id: u64,
    pub conn: Connection,
    pub tx: mpsc::Sender<Payload>,
    pub dialer: DeviceId,
    pub established: Instant,
    /// This device's address towards the peer when the session started.
    pub local_ip: Option<IpAddr>,
}

pub(crate) async fn accept_loop(inner: Arc<Inner>) {
    loop {
        let accepting = tokio::select! {
            _ = inner.cancel.cancelled() => return,
            accepting = inner.endpoint.accept() => match accepting {
                Some(a) => a,
                None => return,
            },
        };
        let inner = inner.clone();
        tokio::spawn(async move {
            let remote = accepting.remote_addr();
            if !inner.may_answer(remote) {
                tracing::debug!(%remote, "ignoring connection attempt on an untrusted network");
                return accepting.ignore();
            }
            let _hold = inner.hold_address(remote);
            let conn = match tokio::time::timeout(HANDSHAKE_TIMEOUT, accepting.finish()).await {
                Ok(Ok(conn)) => conn,
                Ok(Err(e)) => return tracing::debug!(%remote, "incoming handshake refused: {e}"),
                Err(_) => return tracing::debug!(%remote, "incoming handshake timed out"),
            };
            let peer = conn.peer();
            let result = if conn.is_pairing() {
                pairing::respond(&inner, conn).await
            } else {
                // Keeps the dialer from starting a second connection meanwhile.
                let _connecting = dialer::begin_connecting(&inner, peer);
                establish_incoming(&inner, conn).await
            };
            if let Err(e) = result {
                tracing::info!(?peer, "incoming connection failed: {e}");
            }
        });
    }
}

fn hello(inner: &Inner) -> Envelope {
    let port = inner
        .endpoint
        .local_addr()
        .map(|a| a.port())
        .unwrap_or_default();
    Envelope {
        seq: 0,
        ack: 0,
        ts_ms: crate::now_ms(),
        payload: Some(Payload::Hello(proto::Hello {
            name: inner.config.name.clone(),
            platform: inner.config.platform as i32,
            app_version: inner.config.app_version.clone(),
            features: vec![
                "clipboard".into(),
                "notifications".into(),
                "files".into(),
                "open".into(),
                "status".into(),
            ],
            listen_port: u32::from(port),
        })),
    }
}

async fn read_hello(recv: &mut RecvStream) -> Result<proto::Hello> {
    match read_msg::<Envelope>(recv).await? {
        Some(Envelope {
            payload: Some(Payload::Hello(h)),
            ..
        }) => Ok(h),
        _ => Err(CoreError::InvalidInput("expected Hello".into())),
    }
}

/// Dials all known addresses of a peer at once and continues with the first that answers.
/// A Mac on Wi‑Fi and Ethernet in the same subnet only answers from one of its addresses,
/// so trying them one after another would waste a connect timeout per wrong address.
pub(crate) async fn establish_outgoing(
    inner: &Arc<Inner>,
    addrs: Vec<SocketAddr>,
    peer: DeviceId,
) -> Result<()> {
    let mut attempts = tokio::task::JoinSet::new();
    for addr in addrs {
        let endpoint = inner.endpoint.clone();
        attempts.spawn(async move {
            let result = tokio::time::timeout(CONNECT_TIMEOUT, endpoint.connect(addr, peer)).await;
            (addr, result)
        });
    }
    let mut last_err = CoreError::NotConnected;
    while let Some(joined) = attempts.join_next().await {
        let Ok((addr, result)) = joined else { continue };
        match result {
            Ok(Ok(conn)) => {
                attempts.abort_all();
                tracing::info!(?peer, %addr, "dialled peer");
                return establish_on(inner, conn).await;
            }
            Ok(Err(e)) => {
                tracing::debug!(?peer, %addr, "dial failed: {e}");
                last_err = e.into();
            }
            Err(_) => {
                tracing::debug!(?peer, %addr, "dial timed out");
                last_err = CoreError::Timeout;
            }
        }
    }
    Err(last_err)
}

async fn establish_on(inner: &Arc<Inner>, conn: Connection) -> Result<()> {
    let (mut send, mut recv) = conn.open_stream(StreamType::Control).await?;
    write_msg(&mut send, &hello(inner)).await?;
    let peer_hello = tokio::time::timeout(HANDSHAKE_TIMEOUT, read_hello(&mut recv)).await??;
    register(inner, conn, send, recv, peer_hello, inner.id)
}

async fn establish_incoming(inner: &Arc<Inner>, conn: Connection) -> Result<()> {
    let (kind, mut send, mut recv) =
        tokio::time::timeout(HANDSHAKE_TIMEOUT, conn.accept_stream()).await??;
    if kind != StreamType::Control {
        conn.close(3, b"expected control stream");
        return Err(CoreError::InvalidInput(
            "first stream must be CONTROL".into(),
        ));
    }
    let peer_hello = tokio::time::timeout(HANDSHAKE_TIMEOUT, read_hello(&mut recv)).await??;
    write_msg(&mut send, &hello(inner)).await?;
    let dialer = conn.peer();
    register(inner, conn, send, recv, peer_hello, dialer)
}

fn register(
    inner: &Arc<Inner>,
    conn: Connection,
    send: SendStream,
    recv: RecvStream,
    peer_hello: proto::Hello,
    dialer: DeviceId,
) -> Result<()> {
    let peer = conn.peer();
    let session_id = inner.next_session_id.fetch_add(1, Ordering::SeqCst);
    let (tx, rx) = mpsc::channel(OUTBOX);
    let local_ip = crate::paths::local_address_towards(conn.remote_addr().ip());

    {
        let mut sessions = inner.sessions.lock().unwrap();
        // The device may have been forgotten while this handshake was in flight. Checked under
        // the sessions lock: `forget_locally` revokes trust before it removes the session.
        if !inner.trust.is_trusted(&peer) {
            conn.close(4, b"unpaired");
            return Err(CoreError::NotPaired);
        }
        if let Some(existing) = sessions.get(&peer)
            && !existing.conn.is_closed()
        {
            // Both sides dialled at once: keep the connection dialled by the smaller id,
            // which both sides compute identically. Otherwise the newest connection wins,
            // because the old one is probably stale after a network change.
            let preferred = inner.id.min(peer);
            if existing.established.elapsed() < SIMULTANEOUS_WINDOW
                && existing.dialer == preferred
                && dialer != preferred
            {
                conn.close(2, b"duplicate");
                return Ok(());
            }
            existing.conn.close(2, b"replaced");
        }
        sessions.insert(
            peer,
            SessionHandle {
                id: session_id,
                conn: conn.clone(),
                tx,
                dialer,
                established: Instant::now(),
                local_ip,
            },
        );
    }

    let peer_platform = proto::Platform::try_from(peer_hello.platform).unwrap_or_default();
    let listen_addr = SocketAddr::new(conn.remote_addr().ip(), peer_hello.listen_port as u16);
    if let Err(e) = inner.store.lock().unwrap().mark_seen(
        &peer,
        crate::now_ms(),
        (peer_hello.listen_port != 0)
            .then(|| listen_addr.to_string())
            .as_deref(),
    ) {
        tracing::warn!("could not record peer address: {e}");
    }
    dialer::reset_backoff(inner, Some(&peer));
    inner.icons.lock().unwrap().remove(&peer);
    inner.connected_over(conn.remote_addr(), peer, false);
    // Forgotten just after the check above: `forget_locally` already dropped the session.
    if !inner.trust.is_trusted(&peer) {
        conn.close(4, b"unpaired");
        return Err(CoreError::NotPaired);
    }
    tracing::info!(
        ?peer,
        name = %peer_hello.name,
        remote = %conn.remote_addr(),
        dialled_by_us = dialer == inner.id,
        session_id,
        "peer connected"
    );
    inner.emit(Event::PeerConnected {
        device_id: peer,
        name: peer_hello.name,
    });

    let last_rx = Arc::new(AtomicU64::new(0));
    tokio::spawn(writer(send, rx, last_rx.clone()));
    tokio::spawn(reader(
        inner.clone(),
        conn.clone(),
        recv,
        session_id,
        last_rx,
    ));
    tokio::spawn(stream_acceptor(inner.clone(), conn.clone()));
    tokio::spawn(audio::receive_loop(inner.clone(), conn));
    tokio::spawn(transfers::resume_outgoing(inner.clone(), peer));
    // A Mac keeps a message cache for each phone and refreshes it on every connection.
    // When both sides dial at once, two sessions register briefly; only the survivor syncs.
    if inner.config.platform == proto::Platform::Macos && peer_platform == proto::Platform::Android
    {
        let inner = inner.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(500)).await;
            let current = inner
                .sessions
                .lock()
                .unwrap()
                .get(&peer)
                .is_some_and(|s| s.id == session_id);
            if current && let Err(e) = messaging::request_sync(&inner, &peer) {
                tracing::debug!("message sync not requested: {e}");
            }
        });
    }
    Ok(())
}

async fn writer(mut send: SendStream, mut rx: mpsc::Receiver<Payload>, last_rx: Arc<AtomicU64>) {
    let mut seq = 0u64;
    while let Some(payload) = rx.recv().await {
        seq += 1;
        let env = Envelope {
            seq,
            ack: last_rx.load(Ordering::Relaxed),
            ts_ms: crate::now_ms(),
            payload: Some(payload),
        };
        if let Err(e) = write_msg(&mut send, &env).await {
            tracing::debug!("control writer stopped: {e}");
            break;
        }
    }
}

async fn reader(
    inner: Arc<Inner>,
    conn: Connection,
    mut recv: RecvStream,
    session_id: u64,
    last_rx: Arc<AtomicU64>,
) {
    let peer = conn.peer();
    // Also runs if handling a message panics: the session must not live on without a reader.
    let _end = SessionEnd {
        inner: inner.clone(),
        conn: conn.clone(),
        peer,
        session_id,
    };
    loop {
        match read_msg::<Envelope>(&mut recv).await {
            Ok(Some(env)) => {
                last_rx.store(env.seq, Ordering::Relaxed);
                if let Some(payload) = env.payload {
                    router::dispatch(&inner, peer, payload).await;
                }
            }
            Ok(None) => break,
            Err(e) => {
                tracing::debug!(?peer, "control reader stopped: {e}");
                break;
            }
        }
    }
}

/// Closes the connection and forgets the session when the control reader ends.
struct SessionEnd {
    inner: Arc<Inner>,
    conn: Connection,
    peer: DeviceId,
    session_id: u64,
}

impl Drop for SessionEnd {
    fn drop(&mut self) {
        self.conn.close(0, b"control stream ended");
        unregister(&self.inner, &self.peer, self.session_id);
    }
}

/// How long a new stream may take to say what it is.
const STREAM_TYPE_TIMEOUT: Duration = Duration::from_secs(10);

async fn stream_acceptor(inner: Arc<Inner>, conn: Connection) {
    let peer = conn.peer();
    // Only a lost connection ends the loop; each stream announces its type in its own task.
    while let Ok((mut send, mut recv)) = conn.accept_bi().await {
        let inner = inner.clone();
        tokio::spawn(async move {
            let kind = tokio::time::timeout(
                STREAM_TYPE_TIMEOUT,
                brege_transport::read_stream_type(&mut recv),
            )
            .await;
            match kind {
                Ok(Ok(Some(StreamType::File))) => {
                    transfers::receive_stream(inner, peer, send, recv).await
                }
                Ok(Ok(Some(StreamType::Fs))) => files::serve(inner, send, recv).await,
                Ok(Ok(Some(StreamType::Video))) => crate::video::receive(inner, peer, recv).await,
                kind => {
                    tracing::debug!(?kind, "ignoring unsupported stream");
                    let _ = send.reset(0u32.into());
                    let _ = recv.stop(0u32.into());
                }
            }
        });
    }
}

pub(crate) fn unregister(inner: &Inner, peer: &DeviceId, session_id: u64) {
    let removed = {
        let mut sessions = inner.sessions.lock().unwrap();
        if sessions.get(peer).is_some_and(|s| s.id == session_id) {
            sessions.remove(peer)
        } else {
            None
        }
    };
    if removed.is_some() {
        tracing::info!(?peer, session_id, "peer disconnected");
        inner.emit(Event::PeerDisconnected { device_id: *peer });
        inner.dial_now.notify_one();
    }
}

/// Removes a device from the store and trust set and closes any connection.
pub(crate) fn forget_locally(inner: &Inner, peer: &DeviceId) {
    inner.trust.remove(peer);
    if let Err(e) = inner.store.lock().unwrap().remove_device(peer) {
        tracing::warn!("failed to remove device: {e}");
    }
    inner.candidates.lock().unwrap().remove(peer);
    inner.dial_state.lock().unwrap().remove(peer);
    if let Some(session) = inner.sessions.lock().unwrap().remove(peer) {
        session.conn.close(4, b"unpaired");
    }
    inner.emit(Event::DeviceForgotten { device_id: *peer });
}
