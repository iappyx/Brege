//! Generated Protobuf types for the Brêge wire protocol, plus stream framing.

// Generated code: the Payload oneof holds NotificationPost inline, as prost generates it.
#[allow(clippy::large_enum_variant)]
pub mod v1 {
    include!(concat!(env!("OUT_DIR"), "/brege.v1.rs"));
}

pub use prost::Message;

/// ALPN for normal sessions between paired devices.
pub const ALPN: &[u8] = b"brege/1";
/// ALPN for the pairing handshake.
pub const ALPN_PAIR: &[u8] = b"brege-pair/1";

/// Maximum size of one length-prefixed control message (clipboard images are the largest).
pub const MAX_FRAME_LEN: usize = 12 * 1024 * 1024;

/// First byte of a microphone audio datagram.
pub const AUDIO_KIND_MIC: u8 = 1;
/// Datagram header: kind (1) + sequence number (4).
pub const AUDIO_HEADER_LEN: usize = 5;

/// First varint on every QUIC stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u64)]
pub enum StreamType {
    Control = 1,
    File = 2,
    Fs = 3,
    Video = 4,
}

impl StreamType {
    pub fn from_u64(v: u64) -> Option<Self> {
        match v {
            1 => Some(Self::Control),
            2 => Some(Self::File),
            3 => Some(Self::Fs),
            4 => Some(Self::Video),
            _ => None,
        }
    }
}

/// Encodes a message as a varint length prefix followed by its bytes.
pub fn encode_frame<M: Message>(msg: &M) -> Vec<u8> {
    msg.encode_length_delimited_to_vec()
}

/// Encodes `v` as a Protobuf-style varint.
pub fn encode_varint(v: u64) -> Vec<u8> {
    let mut buf = Vec::with_capacity(10);
    prost::encoding::encode_varint(v, &mut buf);
    buf
}

#[cfg(test)]
mod tests {
    use super::v1::*;
    use super::*;

    #[test]
    fn envelope_roundtrip() {
        let env = Envelope {
            seq: 3,
            ack: 2,
            ts_ms: 1_788_000_000_000,
            payload: Some(envelope::Payload::Clipboard(Clipboard {
                kind: clipboard::Kind::Text as i32,
                data: b"hello".to_vec(),
                origin_change_id: 9,
            })),
        };
        let frame = encode_frame(&env);
        let decoded = Envelope::decode_length_delimited(frame.as_slice()).unwrap();
        assert_eq!(decoded, env);
    }

    #[test]
    fn unknown_payload_is_tolerated() {
        // Field 999 (unknown to this version) must decode to an empty payload, not an error.
        let mut bytes = Envelope {
            seq: 1,
            ..Default::default()
        }
        .encode_to_vec();
        prost::encoding::string::encode(999, &"future".to_string(), &mut bytes);
        let decoded = Envelope::decode(bytes.as_slice()).unwrap();
        assert_eq!(decoded.seq, 1);
        assert!(decoded.payload.is_none());
    }
}
