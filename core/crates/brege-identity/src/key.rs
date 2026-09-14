use std::fmt;
use std::str::FromStr;

use data_encoding::BASE32_NOPAD;
use ring::rand::{SecureRandom, SystemRandom};
use ring::signature::{ED25519, Ed25519KeyPair, KeyPair, UnparsedPublicKey};

use crate::IdentityError;

/// DER prefix of an Ed25519 SubjectPublicKeyInfo (RFC 8410); the 32-byte key follows.
const SPKI_PREFIX: [u8; 12] = [
    0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00,
];

/// DER prefix of an Ed25519 PKCS#8 v1 private key (RFC 8410); the 32-byte seed follows.
const PKCS8_PREFIX: [u8; 16] = [
    0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
];

/// A device's Ed25519 public key. Its text form is lowercase unpadded base32 (52 chars).
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct DeviceId([u8; 32]);

impl DeviceId {
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }

    /// SubjectPublicKeyInfo DER, as carried in a TLS raw-public-key handshake.
    pub fn to_spki_der(&self) -> Vec<u8> {
        let mut der = Vec::with_capacity(44);
        der.extend_from_slice(&SPKI_PREFIX);
        der.extend_from_slice(&self.0);
        der
    }

    /// Parses an Ed25519 SubjectPublicKeyInfo. Any other key type is rejected.
    pub fn from_spki_der(der: &[u8]) -> Result<Self, IdentityError> {
        let key = der
            .strip_prefix(&SPKI_PREFIX)
            .ok_or(IdentityError::InvalidKey)?;
        let bytes: [u8; 32] = key.try_into().map_err(|_| IdentityError::InvalidKey)?;
        Ok(Self(bytes))
    }

    /// Verifies an Ed25519 signature made by this device.
    pub fn verify(&self, message: &[u8], signature: &[u8]) -> bool {
        UnparsedPublicKey::new(&ED25519, &self.0)
            .verify(message, signature)
            .is_ok()
    }

    /// First 8 base32 characters, for display and Bonjour TXT records.
    pub fn short(&self) -> String {
        self.to_string()[..8].to_string()
    }
}

impl fmt::Display for DeviceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&BASE32_NOPAD.encode(&self.0).to_ascii_lowercase())
    }
}

impl fmt::Debug for DeviceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "DeviceId({})", self.short())
    }
}

impl FromStr for DeviceId {
    type Err = IdentityError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let bytes = BASE32_NOPAD
            .decode(s.to_ascii_uppercase().as_bytes())
            .map_err(|_| IdentityError::InvalidDeviceId)?;
        let bytes: [u8; 32] = bytes
            .try_into()
            .map_err(|_| IdentityError::InvalidDeviceId)?;
        Ok(Self(bytes))
    }
}

/// A device's Ed25519 private key (32-byte seed).
///
/// Shells persist [`SecretKey::to_seed`] in Keychain / Keystore-wrapped storage.
pub struct SecretKey {
    seed: [u8; 32],
    public: DeviceId,
}

impl SecretKey {
    pub fn generate() -> Result<Self, IdentityError> {
        let mut seed = [0u8; 32];
        SystemRandom::new()
            .fill(&mut seed)
            .map_err(|_| IdentityError::Rng)?;
        Self::from_seed(seed)
    }

    pub fn from_seed(seed: [u8; 32]) -> Result<Self, IdentityError> {
        let pair =
            Ed25519KeyPair::from_seed_unchecked(&seed).map_err(|_| IdentityError::InvalidKey)?;
        let public: [u8; 32] = pair
            .public_key()
            .as_ref()
            .try_into()
            .map_err(|_| IdentityError::InvalidKey)?;
        Ok(Self {
            seed,
            public: DeviceId(public),
        })
    }

    pub fn to_seed(&self) -> [u8; 32] {
        self.seed
    }

    pub fn device_id(&self) -> DeviceId {
        self.public
    }

    /// PKCS#8 v1 DER encoding, as expected by the TLS signing-key loader.
    pub fn to_pkcs8_der(&self) -> Vec<u8> {
        let mut der = Vec::with_capacity(48);
        der.extend_from_slice(&PKCS8_PREFIX);
        der.extend_from_slice(&self.seed);
        der
    }

    pub fn sign(&self, message: &[u8]) -> [u8; 64] {
        let pair = Ed25519KeyPair::from_seed_unchecked(&self.seed)
            .expect("seed validated at construction");
        pair.sign(message)
            .as_ref()
            .try_into()
            .expect("ed25519 signatures are 64 bytes")
    }
}

impl Clone for SecretKey {
    fn clone(&self) -> Self {
        Self {
            seed: self.seed,
            public: self.public,
        }
    }
}

impl Drop for SecretKey {
    fn drop(&mut self) {
        // Best-effort wipe; the seed may still exist in copies made by callers.
        self.seed.iter_mut().for_each(|b| *b = 0);
    }
}

impl fmt::Debug for SecretKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "SecretKey({:?})", self.public)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_id_text_roundtrip() {
        let key = SecretKey::generate().unwrap();
        let id = key.device_id();
        let text = id.to_string();
        assert_eq!(text.len(), 52);
        assert_eq!(text.parse::<DeviceId>().unwrap(), id);
        assert_eq!(text.to_uppercase().parse::<DeviceId>().unwrap(), id);
    }

    #[test]
    fn spki_roundtrip_and_rejects_other_keys() {
        let id = SecretKey::generate().unwrap().device_id();
        assert_eq!(DeviceId::from_spki_der(&id.to_spki_der()).unwrap(), id);
        let mut wrong = id.to_spki_der();
        wrong[8] = 0x6e; // X448 OID
        assert!(DeviceId::from_spki_der(&wrong).is_err());
        assert!(DeviceId::from_spki_der(&id.to_spki_der()[..40]).is_err());
    }

    #[test]
    fn seed_is_deterministic_and_signs() {
        let key = SecretKey::generate().unwrap();
        let again = SecretKey::from_seed(key.to_seed()).unwrap();
        assert_eq!(key.device_id(), again.device_id());
        let sig = key.sign(b"hello");
        assert!(key.device_id().verify(b"hello", &sig));
        assert!(!key.device_id().verify(b"hellO", &sig));
    }

    #[test]
    fn pkcs8_is_loadable_by_ring() {
        let key = SecretKey::generate().unwrap();
        let pair = Ed25519KeyPair::from_pkcs8_maybe_unchecked(&key.to_pkcs8_der()).unwrap();
        assert_eq!(pair.public_key().as_ref(), key.device_id().as_bytes());
    }
}
