//! Phone as microphone: PCM frames as QUIC datagrams from the phone to the Mac.

use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};

use brege_identity::DeviceId;
use brege_proto::{AUDIO_HEADER_LEN, AUDIO_KIND_MIC};
use brege_transport::Connection;
use bytes::{BufMut, Bytes, BytesMut};

use crate::node::Inner;

/// Receives microphone audio on the Mac. Called on a core thread for every datagram, so
/// implementations must be quick (copy into a ring buffer).
pub trait AudioSink: Send + Sync + 'static {
    fn on_mic_frame(&self, from: DeviceId, seq: u32, pcm: &[u8]);
}

pub(crate) static MIC_SEQ: AtomicU32 = AtomicU32::new(0);

/// Phone side: sends one PCM frame to `to`, or every connected peer. Returns how many got it.
pub(crate) fn send_mic_frame(inner: &Inner, to: Option<DeviceId>, pcm: &[u8]) -> usize {
    let seq = MIC_SEQ.fetch_add(1, Ordering::Relaxed);
    let mut buf = BytesMut::with_capacity(AUDIO_HEADER_LEN + pcm.len());
    buf.put_u8(AUDIO_KIND_MIC);
    buf.put_u32_le(seq);
    buf.put_slice(pcm);
    let datagram: Bytes = buf.freeze();
    let conns: Vec<Connection> = inner
        .sessions
        .lock()
        .unwrap()
        .iter()
        .filter(|(id, _)| to.is_none_or(|to| to == **id))
        .map(|(_, s)| s.conn.clone())
        .collect();
    conns
        .iter()
        .filter(|c| {
            c.max_datagram_size()
                .is_some_and(|max| datagram.len() <= max)
                && c.send_datagram(datagram.clone()).is_ok()
        })
        .count()
}

/// Largest PCM payload that fits in one datagram on `conn`, if datagrams are available.
pub(crate) fn max_frame_bytes(conn: &Connection) -> Option<usize> {
    conn.max_datagram_size()
        .map(|m| m.saturating_sub(AUDIO_HEADER_LEN))
}

/// Mac side: delivers datagrams from one connection to the audio sink until it closes.
pub(crate) async fn receive_loop(inner: Arc<Inner>, conn: Connection) {
    let from = conn.peer();
    while let Ok(datagram) = conn.read_datagram().await {
        if datagram.len() <= AUDIO_HEADER_LEN || datagram[0] != AUDIO_KIND_MIC {
            continue;
        }
        let seq = u32::from_le_bytes(datagram[1..5].try_into().expect("4 bytes"));
        let sink = inner.audio_sink.read().unwrap().clone();
        if let Some(sink) = sink {
            sink.on_mic_frame(from, seq, &datagram[AUDIO_HEADER_LEN..]);
        }
    }
}
