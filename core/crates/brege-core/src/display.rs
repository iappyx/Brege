//! The Mac's second display on a tablet: encoded video (H.264 / H.265, Annex-B) on a dedicated QUIC
//! stream, from the Mac to the phone — the camera's stream the other way round
//! (`docs/brege-second-display-plan.md`). Each packet is framed exactly as the camera's is,
//! `[flags u8][pts µs u64 LE][length u32 LE][data]`, flags: 1 = codec config, 2 = key frame, so
//! there is only one shape of video packet for either side to understand.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use brege_identity::DeviceId;
use brege_proto::StreamType;
use brege_transport::RecvStream;
use tokio::sync::mpsc;

use crate::node::Inner;
use crate::video::{FLAG_CONFIG, FLAG_KEY_FRAME};
use crate::{CoreError, Result};

/// Larger packets are a protocol error (a 4K key frame is a few megabytes at most).
const MAX_PACKET: usize = 16 * 1024 * 1024;
/// Queued packets before non-essential ones are dropped (about half a second at 60 fps).
const QUEUE: usize = 30;
const HEADER: usize = 13;

/// Receives the Mac's display on the phone, on a core thread.
pub trait DisplaySink: Send + Sync + 'static {
    fn on_display_packet(&self, from: DeviceId, flags: u8, pts_us: u64, data: &[u8]);
    /// The stream ended (the Mac stopped sending, or the connection dropped).
    fn on_display_end(&self, from: DeviceId);
}

struct Packet {
    flags: u8,
    pts_us: u64,
    data: Vec<u8>,
}

/// Mac side: the open display stream, if any.
///
/// The counters are what tells the Mac whether the link is keeping up: a frame dropped here is one
/// the network had no room for, which is the signal to encode more cheaply. Measuring it at the
/// queue rather than asking the transport means no round trip and no new message — the backlog is
/// visible where it forms.
#[derive(Default)]
pub(crate) struct DisplaySender {
    tx: Mutex<Option<mpsc::Sender<Packet>>>,
    sent: AtomicU64,
    dropped: AtomicU64,
}

impl DisplaySender {
    /// Opens a display stream to `peer`, replacing an earlier one.
    pub(crate) async fn open(inner: &Arc<Inner>, peer: DeviceId) -> Result<()> {
        let conn = inner
            .sessions
            .lock()
            .unwrap()
            .get(&peer)
            .map(|s| s.conn.clone())
            .ok_or(CoreError::NotConnected)?;
        let (mut send, _recv) = conn.open_stream(StreamType::Display).await?;
        let (tx, mut rx) = mpsc::channel::<Packet>(QUEUE);
        *inner.display.tx.lock().unwrap() = Some(tx);
        tokio::spawn(async move {
            while let Some(p) = rx.recv().await {
                let mut header = [0u8; HEADER];
                header[0] = p.flags;
                header[1..9].copy_from_slice(&p.pts_us.to_le_bytes());
                header[9..13].copy_from_slice(&(p.data.len() as u32).to_le_bytes());
                if send.write_all(&header).await.is_err() || send.write_all(&p.data).await.is_err()
                {
                    break;
                }
            }
            let _ = send.finish();
        });
        Ok(())
    }

    /// Queues a packet. Config and key frames wait for room, because a tablet that misses them has
    /// nothing to decode; other frames are dropped when the network falls behind, so what does
    /// arrive is current rather than a backlog. Returns false when no stream is open.
    pub(crate) fn send(&self, flags: u8, pts_us: u64, data: Vec<u8>) -> bool {
        let Some(tx) = self.tx.lock().unwrap().clone() else {
            return false;
        };
        let packet = Packet {
            flags,
            pts_us,
            data,
        };
        if flags & (FLAG_CONFIG | FLAG_KEY_FRAME) != 0 {
            let queued = tx.blocking_send(packet).is_ok();
            if queued {
                self.sent.fetch_add(1, Ordering::Relaxed);
            }
            queued
        } else {
            match tx.try_send(packet) {
                Ok(()) => {
                    self.sent.fetch_add(1, Ordering::Relaxed);
                    true
                }
                Err(mpsc::error::TrySendError::Full(_)) => {
                    self.dropped.fetch_add(1, Ordering::Relaxed);
                    true // dropped, stream still open
                }
                Err(mpsc::error::TrySendError::Closed(_)) => false,
            }
        }
    }

    /// Frames queued and frames the queue had no room for, since the stream opened.
    pub(crate) fn stats(&self) -> (u64, u64) {
        (
            self.sent.load(Ordering::Relaxed),
            self.dropped.load(Ordering::Relaxed),
        )
    }

    pub(crate) fn close(&self) {
        self.tx.lock().unwrap().take();
        self.sent.store(0, Ordering::Relaxed);
        self.dropped.store(0, Ordering::Relaxed);
    }
}

/// Phone side: reads one display stream into the sink until it ends.
pub(crate) async fn receive(inner: Arc<Inner>, from: DeviceId, mut recv: RecvStream) {
    let mut header = [0u8; HEADER];
    loop {
        if recv.read_exact(&mut header).await.is_err() {
            break;
        }
        let flags = header[0];
        let pts_us = u64::from_le_bytes(header[1..9].try_into().expect("8 bytes"));
        let len = u32::from_le_bytes(header[9..13].try_into().expect("4 bytes")) as usize;
        if len > MAX_PACKET {
            tracing::warn!(len, "display packet too large");
            break;
        }
        let mut data = vec![0u8; len];
        if recv.read_exact(&mut data).await.is_err() {
            break;
        }
        let sink = inner.display_sink.read().unwrap().clone();
        if let Some(sink) = sink {
            sink.on_display_packet(from, flags, pts_us, &data);
        }
    }
    let sink = inner.display_sink.read().unwrap().clone();
    if let Some(sink) = sink {
        sink.on_display_end(from);
    }
}
