//! Shared clipboard: size limits and echo suppression.

use std::time::{Duration, Instant};

use brege_proto::v1::{Clipboard, clipboard};

/// Payload cap for one clip.
pub const MAX_CLIP_BYTES: usize = 10 * 1024 * 1024;

/// How long a clip received from a peer is remembered, so the local write it causes is not
/// sent back. Covers the 250 ms macOS pasteboard poll with margin.
const ECHO_WINDOW: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Clip {
    Text(String),
    Png(Vec<u8>),
}

impl Clip {
    fn bytes(&self) -> &[u8] {
        match self {
            Clip::Text(t) => t.as_bytes(),
            Clip::Png(p) => p,
        }
    }

    fn digest(&self) -> [u8; 32] {
        let mut h = blake3::Hasher::new();
        h.update(match self {
            Clip::Text(_) => b"t",
            Clip::Png(_) => b"p",
        });
        h.update(self.bytes());
        *h.finalize().as_bytes()
    }

    pub fn to_proto(&self, origin_change_id: u64) -> Clipboard {
        let (kind, data) = match self {
            Clip::Text(t) => (clipboard::Kind::Text, t.as_bytes().to_vec()),
            Clip::Png(p) => (clipboard::Kind::Png, p.clone()),
        };
        Clipboard {
            kind: kind as i32,
            data,
            origin_change_id,
        }
    }

    pub fn from_proto(msg: Clipboard) -> Option<Self> {
        if msg.data.len() > MAX_CLIP_BYTES {
            return None;
        }
        match clipboard::Kind::try_from(msg.kind).ok()? {
            clipboard::Kind::Text => String::from_utf8(msg.data).ok().map(Clip::Text),
            clipboard::Kind::Png => Some(Clip::Png(msg.data)),
            clipboard::Kind::Unspecified => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outgoing {
    Send,
    /// Same content was just received from a peer; sending it would echo.
    SkipEcho,
    /// Same content was already sent.
    SkipDuplicate,
    TooLarge,
    Empty,
}

#[derive(Debug, Default)]
pub struct ClipboardSync {
    last_received: Option<([u8; 32], Instant)>,
    last_sent: Option<[u8; 32]>,
}

impl ClipboardSync {
    /// Decides whether a local clipboard change should be sent to peers. Call
    /// [`ClipboardSync::sent`] once it reached one.
    pub fn on_local_change(&mut self, clip: &Clip, now: Instant) -> Outgoing {
        if clip.bytes().is_empty() {
            return Outgoing::Empty;
        }
        if clip.bytes().len() > MAX_CLIP_BYTES {
            return Outgoing::TooLarge;
        }
        let digest = clip.digest();
        if let Some((received, at)) = self.last_received
            && received == digest
            && now.duration_since(at) < ECHO_WINDOW
        {
            return Outgoing::SkipEcho;
        }
        if self.last_sent == Some(digest) {
            return Outgoing::SkipDuplicate;
        }
        Outgoing::Send
    }

    /// Records that a clip reached at least one peer. A clip copied while no peer was connected
    /// is sent when copied again.
    pub fn sent(&mut self, clip: &Clip) {
        self.last_sent = Some(clip.digest());
    }

    /// Records a clip received from a peer before the shell writes it locally. The echo window
    /// covers that write; a later identical local copy is new user intent.
    pub fn on_remote(&mut self, clip: &Clip, now: Instant) {
        self.last_received = Some((clip.digest(), now));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suppresses_echo_of_received_clip() {
        let mut sync = ClipboardSync::default();
        let t0 = Instant::now();
        let clip = Clip::Text("hello".into());
        sync.on_remote(&clip, t0);
        assert_eq!(
            sync.on_local_change(&clip, t0 + Duration::from_millis(300)),
            Outgoing::SkipEcho
        );
        let other = Clip::Text("world".into());
        assert_eq!(sync.on_local_change(&other, t0), Outgoing::Send);
        sync.sent(&other);
        assert_eq!(sync.on_local_change(&other, t0), Outgoing::SkipDuplicate);
    }

    #[test]
    fn unsent_and_received_clips_can_be_sent_again() {
        let mut sync = ClipboardSync::default();
        let t0 = Instant::now();
        let clip = Clip::Text("x".into());
        // Copied while no peer was connected: nothing reached a peer.
        assert_eq!(sync.on_local_change(&clip, t0), Outgoing::Send);
        assert_eq!(
            sync.on_local_change(&clip, t0 + Duration::from_secs(60)),
            Outgoing::Send
        );
        // Received, then copied again by the user after the echo window.
        let mut sync = ClipboardSync::default();
        sync.on_remote(&clip, t0);
        assert_eq!(
            sync.on_local_change(&clip, t0 + Duration::from_secs(60)),
            Outgoing::Send
        );
    }

    #[test]
    fn limits_and_proto() {
        let mut sync = ClipboardSync::default();
        let now = Instant::now();
        assert_eq!(
            sync.on_local_change(&Clip::Text(String::new()), now),
            Outgoing::Empty
        );
        assert_eq!(
            sync.on_local_change(&Clip::Png(vec![0; MAX_CLIP_BYTES + 1]), now),
            Outgoing::TooLarge
        );
        let clip = Clip::Png(vec![1, 2, 3]);
        assert_eq!(Clip::from_proto(clip.to_proto(7)), Some(clip));
        let bad = Clipboard {
            kind: 1,
            data: vec![0xff, 0xfe],
            origin_change_id: 0,
        };
        assert_eq!(Clip::from_proto(bad), None, "invalid UTF-8 text is dropped");
    }
}
