use ring::hmac;
use ring::rand::{SecureRandom, SystemRandom};

use crate::IdentityError;

/// Rotation period of BLE presence identifiers.
pub const PRESENCE_SLOT_SECS: u64 = 900;

/// Random per-pair secret exchanged at pairing; derives rotating BLE identifiers.
#[derive(Clone, PartialEq, Eq)]
pub struct PresenceKey([u8; 32]);

impl PresenceKey {
    pub fn generate() -> Result<Self, IdentityError> {
        let mut bytes = [0u8; 32];
        SystemRandom::new()
            .fill(&mut bytes)
            .map_err(|_| IdentityError::Rng)?;
        Ok(Self(bytes))
    }

    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

impl std::fmt::Debug for PresenceKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PresenceKey(..)")
    }
}

/// `HMAC-SHA256(presence_key, slot)[0..8]` with `slot = floor(unix_secs / 900)`.
pub fn presence_id(key: &PresenceKey, unix_secs: u64) -> [u8; 8] {
    id_for_slot(key, unix_secs / PRESENCE_SLOT_SECS)
}

/// Accepts the current slot and its neighbours to tolerate clock skew between devices.
pub fn presence_matches(key: &PresenceKey, id: &[u8; 8], unix_secs: u64) -> bool {
    let slot = unix_secs / PRESENCE_SLOT_SECS;
    [slot.saturating_sub(1), slot, slot + 1]
        .into_iter()
        .any(|s| ct_eq(&id_for_slot(key, s), id))
}

/// First four bytes of the BLE service UUID a Mac advertises to ask for the phone's hotspot.
/// Android's background scan filters on this prefix.
pub const HOTSPOT_UUID_PREFIX: [u8; 4] = [0xB7, 0xE6, 0x00, 0x02];

/// 128-bit service UUID for a hotspot request: the prefix plus
/// `HMAC-SHA256(presence_key, "brege-hotspot" || slot)[0..12]`. Only the paired phone can tell it
/// apart from noise; it rotates with the presence slot.
pub fn hotspot_request_uuid(key: &PresenceKey, unix_secs: u64) -> [u8; 16] {
    hotspot_uuid_for_slot(key, unix_secs / PRESENCE_SLOT_SECS)
}

/// Accepts the current slot and its neighbours, like [`presence_matches`].
pub fn hotspot_request_matches(key: &PresenceKey, uuid: &[u8; 16], unix_secs: u64) -> bool {
    let slot = unix_secs / PRESENCE_SLOT_SECS;
    [slot.saturating_sub(1), slot, slot + 1]
        .into_iter()
        .any(|s| {
            hotspot_uuid_for_slot(key, s)
                .iter()
                .zip(uuid)
                .fold(0u8, |acc, (x, y)| acc | (x ^ y))
                == 0
        })
}

fn hotspot_uuid_for_slot(key: &PresenceKey, slot: u64) -> [u8; 16] {
    let mut message = b"brege-hotspot".to_vec();
    message.extend_from_slice(&slot.to_be_bytes());
    let tag = hmac::sign(&hmac::Key::new(hmac::HMAC_SHA256, &key.0), &message);
    let mut uuid = [0u8; 16];
    uuid[..4].copy_from_slice(&HOTSPOT_UUID_PREFIX);
    uuid[4..].copy_from_slice(&tag.as_ref()[..12]);
    uuid
}

/// First four bytes of the BLE service UUID a phone advertises while it is not connected, so a
/// paired Mac can tell it is nearby (network privacy plan: ask about a new network only then).
pub const PHONE_PRESENCE_UUID_PREFIX: [u8; 4] = [0xB7, 0xE6, 0x00, 0x03];

/// `PHONE_PRESENCE_UUID_PREFIX` plus `HMAC-SHA256(presence_key, "brege-presence" || slot)[0..12]`.
pub fn phone_presence_uuid(key: &PresenceKey, unix_secs: u64) -> [u8; 16] {
    phone_presence_uuid_for_slot(key, unix_secs / PRESENCE_SLOT_SECS)
}

/// Accepts the current slot and its neighbours, like [`presence_matches`].
pub fn phone_presence_matches(key: &PresenceKey, uuid: &[u8; 16], unix_secs: u64) -> bool {
    let slot = unix_secs / PRESENCE_SLOT_SECS;
    [slot.saturating_sub(1), slot, slot + 1]
        .into_iter()
        .any(|s| {
            phone_presence_uuid_for_slot(key, s)
                .iter()
                .zip(uuid)
                .fold(0u8, |acc, (x, y)| acc | (x ^ y))
                == 0
        })
}

fn phone_presence_uuid_for_slot(key: &PresenceKey, slot: u64) -> [u8; 16] {
    let mut message = b"brege-presence".to_vec();
    message.extend_from_slice(&slot.to_be_bytes());
    let tag = hmac::sign(&hmac::Key::new(hmac::HMAC_SHA256, &key.0), &message);
    let mut uuid = [0u8; 16];
    uuid[..4].copy_from_slice(&PHONE_PRESENCE_UUID_PREFIX);
    uuid[4..].copy_from_slice(&tag.as_ref()[..12]);
    uuid
}

/// Keyed id a Mac puts in its Bonjour TXT record for one paired phone (network privacy plan,
/// step 2): `HMAC-SHA256(presence_key, "brege-bonjour" || slot)[0..6]` as 12 hex digits. Others
/// see a value that changes every slot and cannot tell which devices are paired.
pub fn bonjour_token(key: &PresenceKey, unix_secs: u64) -> String {
    bonjour_token_for_slot(key, unix_secs / PRESENCE_SLOT_SECS)
}

/// Accepts the current slot and its neighbours, like [`presence_matches`].
pub fn bonjour_token_matches(key: &PresenceKey, token: &str, unix_secs: u64) -> bool {
    let slot = unix_secs / PRESENCE_SLOT_SECS;
    token.len() == 12
        && [slot.saturating_sub(1), slot, slot + 1]
            .into_iter()
            .any(|s| {
                bonjour_token_for_slot(key, s)
                    .bytes()
                    .zip(token.bytes())
                    .fold(0u8, |acc, (x, y)| acc | (x ^ y))
                    == 0
            })
}

fn bonjour_token_for_slot(key: &PresenceKey, slot: u64) -> String {
    let mut message = b"brege-bonjour".to_vec();
    message.extend_from_slice(&slot.to_be_bytes());
    let tag = hmac::sign(&hmac::Key::new(hmac::HMAC_SHA256, &key.0), &message);
    tag.as_ref()[..6]
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

fn ct_eq(a: &[u8; 8], b: &[u8; 8]) -> bool {
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn id_for_slot(key: &PresenceKey, slot: u64) -> [u8; 8] {
    let tag = hmac::sign(
        &hmac::Key::new(hmac::HMAC_SHA256, &key.0),
        &slot.to_be_bytes(),
    );
    tag.as_ref()[..8].try_into().expect("8 <= 32")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hotspot_request_uuids() {
        let key = PresenceKey::generate().unwrap();
        let t = 1_788_000_000;
        let uuid = hotspot_request_uuid(&key, t);
        assert_eq!(uuid[..4], HOTSPOT_UUID_PREFIX);
        assert!(hotspot_request_matches(&key, &uuid, t + 900));
        assert!(!hotspot_request_matches(&key, &uuid, t + 900 * 3));
        assert!(!hotspot_request_matches(
            &PresenceKey::generate().unwrap(),
            &uuid,
            t
        ));
        assert_ne!(
            uuid[4..12],
            presence_id(&key, t),
            "separate from the presence id"
        );
    }

    #[test]
    fn phone_presence_uuids() {
        let key = PresenceKey::generate().unwrap();
        let t = 1_788_000_000;
        let uuid = phone_presence_uuid(&key, t);
        assert_eq!(uuid[..4], PHONE_PRESENCE_UUID_PREFIX);
        assert!(phone_presence_matches(&key, &uuid, t + 900));
        assert!(!phone_presence_matches(&key, &uuid, t + 900 * 3));
        assert_ne!(
            uuid[4..],
            hotspot_request_uuid(&key, t)[4..],
            "separate from the hotspot request"
        );
    }

    #[test]
    fn bonjour_tokens() {
        let key = PresenceKey::generate().unwrap();
        let t = 1_788_000_000;
        let token = bonjour_token(&key, t);
        assert_eq!(token.len(), 12);
        assert!(bonjour_token_matches(&key, &token, t + 900));
        assert!(!bonjour_token_matches(&key, &token, t + 900 * 3));
        assert!(!bonjour_token_matches(
            &PresenceKey::generate().unwrap(),
            &token,
            t
        ));
        assert!(!bonjour_token_matches(&key, "", t));
    }

    #[test]
    fn rotates_per_slot_and_tolerates_skew() {
        let key = PresenceKey::generate().unwrap();
        let t = 1_788_000_000;
        let id = presence_id(&key, t);
        assert_eq!(id, presence_id(&key, t - t % 900 + 899));
        assert_ne!(id, presence_id(&key, t + 900 * 2));
        assert!(presence_matches(&key, &id, t + 900));
        assert!(!presence_matches(&key, &id, t + 900 * 3));
        assert!(!presence_matches(&PresenceKey::generate().unwrap(), &id, t));
    }
}
