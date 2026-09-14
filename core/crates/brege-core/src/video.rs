//! Phone camera on the Mac: encoded video (H.264 / H.265, Annex-B) on a dedicated QUIC stream
//! from the phone to the Mac. Each packet is framed as
//! `[flags u8][pts µs u64 LE][length u32 LE][data]`, flags: 1 = codec config, 2 = key frame.

use std::sync::{Arc, Mutex};

use brege_identity::DeviceId;
use brege_proto::StreamType;
use brege_transport::RecvStream;
use tokio::sync::mpsc;

use crate::node::Inner;
use crate::{CoreError, Result};

pub const FLAG_CONFIG: u8 = 1;
pub const FLAG_KEY_FRAME: u8 = 2;
/// Larger packets are a protocol error (a 4K key frame is a few megabytes at most).
const MAX_PACKET: usize = 16 * 1024 * 1024;
/// Queued packets before non-essential ones are dropped (about one second at 30 fps).
const QUEUE: usize = 30;

/// Receives camera video on the Mac, on a core thread.
pub trait VideoSink: Send + Sync + 'static {
    fn on_video_packet(&self, from: DeviceId, flags: u8, pts_us: u64, data: &[u8]);
    /// The stream ended (camera stopped, or the connection dropped).
    fn on_video_end(&self, from: DeviceId);
}

struct Packet {
    flags: u8,
    pts_us: u64,
    data: Vec<u8>,
}

/// Phone side: the open video stream, if any.
#[derive(Default)]
pub(crate) struct VideoSender {
    tx: Mutex<Option<mpsc::Sender<Packet>>>,
}

impl VideoSender {
    /// Opens a video stream to `peer`, replacing an earlier one.
    pub(crate) async fn open(inner: &Arc<Inner>, peer: DeviceId) -> Result<()> {
        let conn = inner
            .sessions
            .lock()
            .unwrap()
            .get(&peer)
            .map(|s| s.conn.clone())
            .ok_or(CoreError::NotConnected)?;
        let (mut send, _recv) = conn.open_stream(StreamType::Video).await?;
        let (tx, mut rx) = mpsc::channel::<Packet>(QUEUE);
        *inner.video.tx.lock().unwrap() = Some(tx);
        tokio::spawn(async move {
            while let Some(p) = rx.recv().await {
                let mut header = [0u8; 13];
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

    /// Queues a packet. Config and key frames wait for room; other frames are dropped when the
    /// network falls behind, so the picture stays live. Returns false when no stream is open.
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
            tx.blocking_send(packet).is_ok()
        } else {
            match tx.try_send(packet) {
                Ok(()) => true,
                Err(mpsc::error::TrySendError::Full(_)) => true, // dropped, stream still open
                Err(mpsc::error::TrySendError::Closed(_)) => false,
            }
        }
    }

    pub(crate) fn close(&self) {
        self.tx.lock().unwrap().take();
    }
}

/// Mac side: reads one video stream into the sink until it ends.
pub(crate) async fn receive(inner: Arc<Inner>, from: DeviceId, mut recv: RecvStream) {
    let mut header = [0u8; 13];
    loop {
        if recv.read_exact(&mut header).await.is_err() {
            break;
        }
        let flags = header[0];
        let pts_us = u64::from_le_bytes(header[1..9].try_into().expect("8 bytes"));
        let len = u32::from_le_bytes(header[9..13].try_into().expect("4 bytes")) as usize;
        if len > MAX_PACKET {
            tracing::warn!(len, "video packet too large");
            break;
        }
        let mut data = vec![0u8; len];
        if recv.read_exact(&mut data).await.is_err() {
            break;
        }
        let sink = inner.video_sink.read().unwrap().clone();
        if let Some(sink) = sink {
            sink.on_video_packet(from, flags, pts_us, &data);
        }
    }
    let sink = inner.video_sink.read().unwrap().clone();
    if let Some(sink) = sink {
        sink.on_video_end(from);
    }
}
