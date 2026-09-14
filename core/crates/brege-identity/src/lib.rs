//! Device identity, pairing primitives and BLE presence identifiers.
//!
//! Every device has one Ed25519 key pair; the public key is the [`DeviceId`].
//! All cryptography comes from `ring`, the same provider the transport's TLS stack uses.

mod key;
mod pairing;
mod presence;

pub use key::{DeviceId, SecretKey};
pub use pairing::{PairingInvite, PairingToken, pairing_proof, verify_pairing_proof};
pub use presence::{
    HOTSPOT_UUID_PREFIX, PHONE_PRESENCE_UUID_PREFIX, PRESENCE_SLOT_SECS, PresenceKey,
    bonjour_token, bonjour_token_matches, hotspot_request_matches, hotspot_request_uuid,
    phone_presence_matches, phone_presence_uuid, presence_id, presence_matches,
};

/// TLS exporter label used to bind the pairing proof to one TLS session.
pub const PAIRING_EXPORTER_LABEL: &[u8] = b"EXPORTER-brege-pair";

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum IdentityError {
    #[error("invalid key material")]
    InvalidKey,
    #[error("invalid device id encoding")]
    InvalidDeviceId,
    #[error("invalid pairing invite: {0}")]
    InvalidInvite(&'static str),
    #[error("unsupported pairing invite version {0}")]
    UnsupportedVersion(u32),
    #[error("system random number generator failed")]
    Rng,
}
