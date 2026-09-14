//! QUIC transport between Brêge devices.
//!
//! This is the quinn + rustls backend. Feature crates only see [`Endpoint`] and [`Connection`],
//! so another backend can replace it without touching them.

mod endpoint;
mod filter;
mod framing;
mod tls;

use std::fmt::Debug;

pub use endpoint::{Accepting, Connection, Endpoint, EndpointOptions, read_stream_type};
pub use filter::SourceFilter;
pub use framing::{read_msg, read_varint, write_msg};
pub use quinn::{RecvStream, SendStream};

/// Answers whether a device is paired. Implemented by the core's peer store.
pub trait TrustStore: Debug + Send + Sync {
    fn is_trusted(&self, id: &brege_identity::DeviceId) -> bool;
}

#[derive(Debug, thiserror::Error)]
pub enum TransportError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("tls: {0}")]
    Tls(#[from] rustls::Error),
    #[error("connect: {0}")]
    Connect(#[from] quinn::ConnectError),
    #[error("connection: {0}")]
    Connection(#[from] quinn::ConnectionError),
    #[error("write: {0}")]
    Write(#[from] quinn::WriteError),
    #[error("read: {0}")]
    Read(#[from] quinn::ReadExactError),
    #[error("stream closed: {0}")]
    ClosedStream(#[from] quinn::ClosedStream),
    #[error("datagram: {0}")]
    Datagram(#[from] quinn::SendDatagramError),
    #[error("decode: {0}")]
    Decode(#[from] prost::DecodeError),
    #[error("protocol violation: {0}")]
    Protocol(&'static str),
    #[error("peer is not trusted for this protocol")]
    Untrusted,
}
