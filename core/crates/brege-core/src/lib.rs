//! The Brêge core: owns all state and drives pairing, sessions and feature modules.
//!
//! Shells create one [`Node`], feed it platform input (clipboard changes, notifications,
//! discovery results) and receive [`Event`]s through an [`EventSink`].

pub mod apps;
pub use brege_features::codes;
mod audio;
mod dialer;
mod events;
mod files;
mod messaging;
mod node;
mod pairing;
mod paths;
mod router;
mod session;
mod transfers;
mod trust;
mod video;

pub use audio::AudioSink;
pub use brege_features::clipboard::Clip;
pub use brege_features::open_request::OpenRequest;
pub use brege_identity::{DeviceId, SecretKey};
pub use brege_proto::v1 as proto;
pub use brege_store::KnownNetwork;
pub use brege_store::{CallRecord, MessageRecord, SimRecord, ThreadRecord};
pub use dialer::DEFAULT_PORT;
pub use events::{Event, EventSink};
pub use files::{FsBackend, FsErrorKind, FsFailure, FsWriter, MAX_READ};
pub use node::{DeviceInfo, Node, NodeConfig};
pub use paths::{InterfaceKind, NetInterface, NetworkPath};
pub use video::{
    FLAG_CONFIG as VIDEO_FLAG_CONFIG, FLAG_KEY_FRAME as VIDEO_FLAG_KEY_FRAME, VideoSink,
};

#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("store: {0}")]
    Store(#[from] brege_store::StoreError),
    #[error("transport: {0}")]
    Transport(#[from] brege_transport::TransportError),
    #[error("identity: {0}")]
    Identity(#[from] brege_identity::IdentityError),
    #[error("transfer: {0}")]
    Transfer(#[from] brege_transfer::TransferError),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("device is not paired")]
    NotPaired,
    #[error("device is not connected")]
    NotConnected,
    #[error("pairing failed: {0}")]
    PairingFailed(String),
    #[error("timed out")]
    Timeout,
    #[error("invalid input: {0}")]
    InvalidInput(String),
    #[error("node is shut down")]
    Shutdown,
    #[error("file system: {0}")]
    FileSystem(files::FsFailure),
}

impl From<tokio::time::error::Elapsed> for CoreError {
    fn from(_: tokio::time::error::Elapsed) -> Self {
        CoreError::Timeout
    }
}

pub type Result<T, E = CoreError> = std::result::Result<T, E>;

pub(crate) fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or_default()
}

pub(crate) fn random_hex(bytes: usize) -> String {
    use ring::rand::SecureRandom;
    let mut buf = vec![0u8; bytes];
    ring::rand::SystemRandom::new()
        .fill(&mut buf)
        .expect("system rng");
    buf.iter().map(|b| format!("{b:02x}")).collect()
}
