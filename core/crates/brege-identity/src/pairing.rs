use std::net::SocketAddr;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use data_encoding::BASE32_NOPAD;
use ring::hmac;
use ring::rand::{SecureRandom, SystemRandom};

use crate::{DeviceId, IdentityError};

const INVITE_VERSION: u32 = 2;
const TOKEN_LIFETIME: Duration = Duration::from_secs(5 * 60);

/// Single-use pairing secret shown in the QR code.
#[derive(Clone, PartialEq, Eq)]
pub struct PairingToken {
    bytes: [u8; 32],
    expires_at: SystemTime,
}

impl PairingToken {
    pub fn generate() -> Result<Self, IdentityError> {
        let mut bytes = [0u8; 32];
        SystemRandom::new()
            .fill(&mut bytes)
            .map_err(|_| IdentityError::Rng)?;
        Ok(Self {
            bytes,
            expires_at: SystemTime::now() + TOKEN_LIFETIME,
        })
    }

    /// A token received in an invite; expiry is only enforced by the side that created it.
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self {
            bytes,
            expires_at: UNIX_EPOCH,
        }
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.bytes
    }

    pub fn is_expired(&self, now: SystemTime) -> bool {
        now >= self.expires_at
    }
}

impl std::fmt::Debug for PairingToken {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PairingToken(..)")
    }
}

/// Contents of the pairing QR code:
/// `brege://pair?v=2&id=<device id>&tok=<token>&name=<name>&addr=<ip:port>[,<ip:port>…]`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingInvite {
    pub device_id: DeviceId,
    pub token: [u8; 32],
    pub name: String,
    pub addrs: Vec<SocketAddr>,
}

impl PairingInvite {
    pub fn to_uri(&self) -> String {
        let addrs = self
            .addrs
            .iter()
            .map(SocketAddr::to_string)
            .collect::<Vec<_>>()
            .join(",");
        format!(
            "brege://pair?v={INVITE_VERSION}&id={}&tok={}&name={}&addr={}",
            self.device_id,
            BASE32_NOPAD.encode(&self.token).to_ascii_lowercase(),
            percent_encode(&self.name),
            percent_encode(&addrs),
        )
    }

    pub fn parse(uri: &str) -> Result<Self, IdentityError> {
        let query = uri
            .strip_prefix("brege://pair?")
            .ok_or(IdentityError::InvalidInvite("not a brege pairing uri"))?;

        let (mut version, mut id, mut tok, mut name, mut addr) = (None, None, None, None, None);
        for pair in query.split('&') {
            let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
            let v = percent_decode(v).ok_or(IdentityError::InvalidInvite("bad escape"))?;
            match k {
                "v" => version = Some(v),
                "id" => id = Some(v),
                "tok" => tok = Some(v),
                "name" => name = Some(v),
                "addr" => addr = Some(v),
                _ => {} // unknown keys are ignored for forward compatibility
            }
        }

        let version: u32 = version
            .ok_or(IdentityError::InvalidInvite("missing v"))?
            .parse()
            .map_err(|_| IdentityError::InvalidInvite("bad v"))?;
        if version != INVITE_VERSION {
            return Err(IdentityError::UnsupportedVersion(version));
        }
        let device_id = id
            .ok_or(IdentityError::InvalidInvite("missing id"))?
            .parse()?;
        let token: [u8; 32] = BASE32_NOPAD
            .decode(
                tok.ok_or(IdentityError::InvalidInvite("missing tok"))?
                    .to_ascii_uppercase()
                    .as_bytes(),
            )
            .ok()
            .and_then(|b| b.try_into().ok())
            .ok_or(IdentityError::InvalidInvite("bad tok"))?;
        let addrs = addr
            .unwrap_or_default()
            .split(',')
            .filter(|s| !s.is_empty())
            .map(|s| s.parse::<SocketAddr>())
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| IdentityError::InvalidInvite("bad addr"))?;

        Ok(Self {
            device_id,
            token,
            name: name.unwrap_or_default(),
            addrs,
        })
    }
}

/// `HMAC-SHA256(token, exporter)`, where `exporter` is 32 bytes of TLS keying material
/// exported with [`crate::PAIRING_EXPORTER_LABEL`].
pub fn pairing_proof(token: &[u8; 32], exporter: &[u8]) -> [u8; 32] {
    let key = hmac::Key::new(hmac::HMAC_SHA256, token);
    hmac::sign(&key, exporter)
        .as_ref()
        .try_into()
        .expect("sha256 output is 32 bytes")
}

/// Constant-time check of a pairing proof.
pub fn verify_pairing_proof(token: &[u8; 32], exporter: &[u8], proof: &[u8]) -> bool {
    let key = hmac::Key::new(hmac::HMAC_SHA256, token);
    hmac::verify(&key, exporter, proof).is_ok()
}

fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~' | b':' | b',') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn percent_decode(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' => {
                let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
                out.push(u8::from_str_radix(hex, 16).ok()?);
                i += 3;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8(out).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SecretKey;

    fn invite() -> PairingInvite {
        PairingInvite {
            device_id: SecretKey::generate().unwrap().device_id(),
            token: *PairingToken::generate().unwrap().as_bytes(),
            name: "Sam's Mac & co".into(),
            addrs: vec![
                "192.168.1.20:47400".parse().unwrap(),
                "[fe80::1]:47400".parse().unwrap(),
            ],
        }
    }

    #[test]
    fn invite_roundtrip() {
        let invite = invite();
        let uri = invite.to_uri();
        assert!(uri.starts_with("brege://pair?v=2&id="));
        assert!(!uri.contains(' '));
        assert_eq!(PairingInvite::parse(&uri).unwrap(), invite);
    }

    #[test]
    fn invite_rejects_bad_input() {
        let uri = invite().to_uri();
        assert_eq!(
            PairingInvite::parse(&uri.replace("v=2", "v=9")),
            Err(IdentityError::UnsupportedVersion(9))
        );
        assert!(PairingInvite::parse("https://example.com").is_err());
        assert!(PairingInvite::parse(&uri.replace("tok=", "tok=zz")).is_err());
        // Unknown keys are tolerated.
        assert!(PairingInvite::parse(&format!("{uri}&future=1")).is_ok());
    }

    #[test]
    fn token_expiry() {
        let token = PairingToken::generate().unwrap();
        assert!(!token.is_expired(SystemTime::now()));
        assert!(token.is_expired(SystemTime::now() + Duration::from_secs(301)));
    }

    #[test]
    fn proof_binds_token_and_session() {
        let token = *PairingToken::generate().unwrap().as_bytes();
        let exporter = [7u8; 32];
        let proof = pairing_proof(&token, &exporter);
        assert!(verify_pairing_proof(&token, &exporter, &proof));
        assert!(!verify_pairing_proof(&token, &[8u8; 32], &proof));
        assert!(!verify_pairing_proof(&[0u8; 32], &exporter, &proof));
    }
}
