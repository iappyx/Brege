use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use brege_identity::{DeviceId, PAIRING_EXPORTER_LABEL, SecretKey};
use brege_proto::{ALPN, ALPN_PAIR, StreamType};
use bytes::Bytes;
use quinn::crypto::rustls::{HandshakeData, QuicClientConfig, QuicServerConfig};
use rustls::pki_types::CertificateDer;

use crate::filter::{FilterState, FilteredSocket, SourceFilter};
use crate::framing::read_varint;
use crate::{TransportError, TrustStore, tls};

/// Server name placed in the ClientHello; identity is checked by key, never by name.
const SERVER_NAME: &str = "brege.invalid";

#[derive(Debug, Clone)]
pub struct EndpointOptions {
    pub keep_alive: Duration,
    pub idle_timeout: Duration,
}

impl Default for EndpointOptions {
    fn default() -> Self {
        // Keep-alive every 15 s, idle timeout 45 s.
        Self {
            keep_alive: Duration::from_secs(15),
            idle_timeout: Duration::from_secs(45),
        }
    }
}

/// One UDP socket that both accepts and dials Brêge connections.
#[derive(Clone)]
pub struct Endpoint {
    inner: quinn::Endpoint,
    key: Arc<SecretKey>,
    trust: Arc<dyn TrustStore>,
    pairing_open: Arc<AtomicBool>,
    transport: Arc<quinn::TransportConfig>,
    filter: Arc<FilterState>,
    runtime: Arc<dyn quinn::Runtime>,
}

impl Endpoint {
    pub fn bind(
        addr: SocketAddr,
        key: SecretKey,
        trust: Arc<dyn TrustStore>,
        options: EndpointOptions,
    ) -> Result<Self, TransportError> {
        let pairing_open = Arc::new(AtomicBool::new(false));
        let mut transport = quinn::TransportConfig::default();
        transport
            .keep_alive_interval(Some(options.keep_alive))
            .max_idle_timeout(Some(
                options
                    .idle_timeout
                    .try_into()
                    .map_err(|_| TransportError::Protocol("idle timeout out of range"))?,
            ));
        let transport = Arc::new(transport);

        let tls = tls::server_config(
            &key,
            trust.clone(),
            pairing_open.clone(),
            &[ALPN, ALPN_PAIR],
        )?;
        let crypto = QuicServerConfig::try_from(Arc::new(tls))
            .map_err(|_| TransportError::Protocol("tls config not usable for QUIC"))?;
        let mut server = quinn::ServerConfig::with_crypto(Arc::new(crypto));
        server.transport_config(transport.clone());

        let runtime = quinn::default_runtime()
            .ok_or_else(|| std::io::Error::other("no async runtime found"))?;
        let filter = Arc::new(FilterState::default());
        let socket = Arc::new(FilteredSocket {
            inner: runtime.wrap_udp_socket(std::net::UdpSocket::bind(addr)?)?,
            state: filter.clone(),
        });
        let inner = quinn::Endpoint::new_with_abstract_socket(
            quinn::EndpointConfig::default(),
            Some(server),
            socket,
            runtime.clone(),
        )?;
        Ok(Self {
            inner,
            key: Arc::new(key),
            trust,
            pairing_open,
            transport,
            filter,
            runtime,
        })
    }

    /// Lets datagrams reach QUIC only from sources `filter` allows, or that this endpoint dialled
    /// within the last minute. Without a filter everything is let through.
    pub fn set_source_filter(&self, filter: std::sync::Weak<dyn SourceFilter>) {
        self.filter.set_policy(filter);
    }

    /// Forgets cached filter decisions; call when the rules behind the filter change.
    pub fn refresh_source_filter(&self) {
        self.filter.forget_decisions();
    }

    pub fn device_id(&self) -> DeviceId {
        self.key.device_id()
    }

    pub fn local_addr(&self) -> Result<SocketAddr, TransportError> {
        Ok(self.inner.local_addr()?)
    }

    /// Opens or closes the pairing window. While closed, unpinned keys fail the TLS handshake.
    pub fn is_pairing_open(&self) -> bool {
        self.pairing_open.load(Ordering::SeqCst)
    }

    pub fn set_pairing_open(&self, open: bool) {
        self.pairing_open.store(open, Ordering::SeqCst);
    }

    /// Dials a paired peer on the normal protocol.
    pub async fn connect(
        &self,
        addr: SocketAddr,
        peer: DeviceId,
    ) -> Result<Connection, TransportError> {
        self.connect_alpn(addr, peer, ALPN).await
    }

    /// Dials a device from a pairing invite; its key comes from the QR code.
    pub async fn connect_pairing(
        &self,
        addr: SocketAddr,
        peer: DeviceId,
    ) -> Result<Connection, TransportError> {
        self.connect_alpn(addr, peer, ALPN_PAIR).await
    }

    async fn connect_alpn(
        &self,
        addr: SocketAddr,
        peer: DeviceId,
        alpn: &[u8],
    ) -> Result<Connection, TransportError> {
        let tls = tls::client_config(&self.key, peer, alpn)?;
        let crypto = QuicClientConfig::try_from(Arc::new(tls))
            .map_err(|_| TransportError::Protocol("tls config not usable for QUIC"))?;
        let mut config = quinn::ClientConfig::new(Arc::new(crypto));
        config.transport_config(self.transport.clone());
        self.filter.note_dial(addr);
        let conn = self.inner.connect_with(config, addr, SERVER_NAME)?.await?;
        Connection::from_quinn(conn)
    }

    /// Waits for the next incoming connection attempt. Returns `None` once the endpoint is closed.
    ///
    /// The handshake runs in [`Accepting::finish`], so callers can drive many handshakes
    /// concurrently and one slow peer cannot stall the others.
    pub async fn accept(&self) -> Option<Accepting> {
        let incoming = self.inner.accept().await?;
        Some(Accepting {
            incoming,
            trust: self.trust.clone(),
            pairing_open: self.pairing_open.clone(),
        })
    }

    /// Rebinds to a new local socket after a network change (client-side migration).
    pub fn rebind(&self, addr: SocketAddr) -> Result<(), TransportError> {
        let socket = Arc::new(FilteredSocket {
            inner: self
                .runtime
                .wrap_udp_socket(std::net::UdpSocket::bind(addr)?)?,
            state: self.filter.clone(),
        });
        Ok(self.inner.rebind_abstract(socket)?)
    }

    pub async fn close(&self) {
        self.inner.close(0u32.into(), b"shutdown");
        self.inner.wait_idle().await;
    }
}

/// An incoming connection whose handshake has not completed yet.
pub struct Accepting {
    incoming: quinn::Incoming,
    trust: Arc<dyn TrustStore>,
    pairing_open: Arc<AtomicBool>,
}

impl Accepting {
    pub fn remote_addr(&self) -> SocketAddr {
        self.incoming.remote_address()
    }

    /// Drops the attempt without sending anything back, so the port looks closed.
    pub fn ignore(self) {
        self.incoming.ignore();
    }

    /// Completes the handshake and applies the trust rules: pinned peers on `brege/1`,
    /// anyone on `brege-pair/1` while the pairing window is open.
    pub async fn finish(self) -> Result<Connection, TransportError> {
        let conn = Connection::from_quinn(self.incoming.await?)?;
        let allowed = if conn.is_pairing() {
            self.pairing_open.load(Ordering::SeqCst)
        } else {
            self.trust.is_trusted(&conn.peer)
        };
        if allowed {
            Ok(conn)
        } else {
            tracing::info!(peer = ?conn.peer, pairing = conn.is_pairing(), "refusing untrusted peer");
            conn.close(1, b"untrusted");
            Err(TransportError::Untrusted)
        }
    }
}

/// An authenticated connection to one peer.
#[derive(Clone, Debug)]
pub struct Connection {
    inner: quinn::Connection,
    peer: DeviceId,
    alpn: Vec<u8>,
}

impl Connection {
    fn from_quinn(inner: quinn::Connection) -> Result<Self, TransportError> {
        let alpn = inner
            .handshake_data()
            .and_then(|d| d.downcast::<HandshakeData>().ok())
            .and_then(|d| d.protocol)
            .ok_or(TransportError::Protocol("no ALPN negotiated"))?;
        let certs = inner
            .peer_identity()
            .and_then(|i| i.downcast::<Vec<CertificateDer<'static>>>().ok())
            .ok_or(TransportError::Untrusted)?;
        let peer = certs
            .first()
            .and_then(|c| DeviceId::from_spki_der(c.as_ref()).ok())
            .ok_or(TransportError::Untrusted)?;
        Ok(Self {
            inner,
            peer,
            alpn: alpn.to_vec(),
        })
    }

    pub fn peer(&self) -> DeviceId {
        self.peer
    }

    pub fn is_pairing(&self) -> bool {
        self.alpn == ALPN_PAIR
    }

    pub fn remote_addr(&self) -> SocketAddr {
        self.inner.remote_address()
    }

    /// Opens a bidirectional stream and announces its type.
    pub async fn open_stream(
        &self,
        kind: StreamType,
    ) -> Result<(quinn::SendStream, quinn::RecvStream), TransportError> {
        let (mut send, recv) = self.inner.open_bi().await?;
        send.write_all(&brege_proto::encode_varint(kind as u64))
            .await?;
        Ok((send, recv))
    }

    /// Accepts the peer's next bidirectional stream without reading its type; fails only when
    /// the connection is gone. Read the type with [`read_stream_type`], so one bad or slow
    /// stream cannot hold up the others.
    pub async fn accept_bi(
        &self,
    ) -> Result<(quinn::SendStream, quinn::RecvStream), TransportError> {
        Ok(self.inner.accept_bi().await?)
    }

    /// Accepts the peer's next bidirectional stream and reads its type.
    pub async fn accept_stream(
        &self,
    ) -> Result<(StreamType, quinn::SendStream, quinn::RecvStream), TransportError> {
        let (send, mut recv) = self.inner.accept_bi().await?;
        let kind = read_varint(&mut recv)
            .await?
            .and_then(StreamType::from_u64)
            .ok_or(TransportError::Protocol("unknown stream type"))?;
        Ok((kind, send, recv))
    }

    pub async fn open_uni(&self, kind: StreamType) -> Result<quinn::SendStream, TransportError> {
        let mut send = self.inner.open_uni().await?;
        send.write_all(&brege_proto::encode_varint(kind as u64))
            .await?;
        Ok(send)
    }

    pub async fn accept_uni(&self) -> Result<(StreamType, quinn::RecvStream), TransportError> {
        let mut recv = self.inner.accept_uni().await?;
        let kind = read_varint(&mut recv)
            .await?
            .and_then(StreamType::from_u64)
            .ok_or(TransportError::Protocol("unknown stream type"))?;
        Ok((kind, recv))
    }

    pub fn send_datagram(&self, data: Bytes) -> Result<(), TransportError> {
        Ok(self.inner.send_datagram(data)?)
    }

    pub async fn read_datagram(&self) -> Result<Bytes, TransportError> {
        Ok(self.inner.read_datagram().await?)
    }

    pub fn max_datagram_size(&self) -> Option<usize> {
        self.inner.max_datagram_size()
    }

    /// 32 bytes of TLS keying material bound to this session, for the pairing proof.
    pub fn pairing_exporter(&self) -> Result<[u8; 32], TransportError> {
        let mut out = [0u8; 32];
        self.inner
            .export_keying_material(&mut out, PAIRING_EXPORTER_LABEL, b"")
            .map_err(|_| TransportError::Protocol("keying material export failed"))?;
        Ok(out)
    }

    pub fn close(&self, code: u32, reason: &[u8]) {
        self.inner.close(code.into(), reason);
    }

    /// Resolves when the connection is closed, with the reason.
    pub async fn closed(&self) -> quinn::ConnectionError {
        self.inner.closed().await
    }

    pub fn is_closed(&self) -> bool {
        self.inner.close_reason().is_some()
    }

    pub fn rtt(&self) -> Duration {
        self.inner.rtt()
    }
}

/// Reads the type a peer announced on a stream: `None` for a type this version does not know,
/// or a stream that ended before announcing one.
pub async fn read_stream_type(
    recv: &mut quinn::RecvStream,
) -> Result<Option<StreamType>, TransportError> {
    Ok(read_varint(recv).await?.and_then(StreamType::from_u64))
}
