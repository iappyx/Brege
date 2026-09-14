//! TLS 1.3 with Ed25519 raw public keys (RFC 7250) for both sides of a QUIC connection.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use brege_identity::{DeviceId, SecretKey};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{
    CryptoProvider, WebPkiSupportedAlgorithms, verify_tls13_signature_with_raw_key,
};
use rustls::pki_types::{
    CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName, SubjectPublicKeyInfoDer,
    UnixTime,
};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::sign::CertifiedKey;
use rustls::{
    CertificateError, DigitallySignedStruct, DistinguishedName, Error, PeerIncompatible,
    SignatureScheme,
};

use crate::TrustStore;

pub(crate) fn provider() -> Arc<CryptoProvider> {
    Arc::new(rustls::crypto::ring::default_provider())
}

fn certified_key(key: &SecretKey, provider: &CryptoProvider) -> Result<Arc<CertifiedKey>, Error> {
    let der = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.to_pkcs8_der()));
    let signing_key = provider.key_provider.load_private_key(der)?;
    let spki = CertificateDer::from(key.device_id().to_spki_der());
    Ok(Arc::new(CertifiedKey::new(vec![spki], signing_key)))
}

pub(crate) fn server_config(
    key: &SecretKey,
    trust: Arc<dyn TrustStore>,
    pairing_open: Arc<AtomicBool>,
    alpns: &[&[u8]],
) -> Result<rustls::ServerConfig, Error> {
    let provider = provider();
    let verifier = Arc::new(ClientVerifier {
        trust,
        pairing_open,
        algs: provider.signature_verification_algorithms,
    });
    let mut config = rustls::ServerConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_client_cert_verifier(verifier)
        .with_cert_resolver(Arc::new(
            rustls::server::AlwaysResolvesServerRawPublicKeys::new(certified_key(key, &provider)?),
        ));
    config.alpn_protocols = alpns.iter().map(|a| a.to_vec()).collect();
    Ok(config)
}

pub(crate) fn client_config(
    key: &SecretKey,
    expected_peer: DeviceId,
    alpn: &[u8],
) -> Result<rustls::ClientConfig, Error> {
    let provider = provider();
    let verifier = Arc::new(ServerVerifier {
        expected_peer,
        algs: provider.signature_verification_algorithms,
    });
    let mut config = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .dangerous()
        .with_custom_certificate_verifier(verifier)
        .with_client_cert_resolver(Arc::new(
            rustls::client::AlwaysResolvesClientRawPublicKeys::new(certified_key(key, &provider)?),
        ));
    config.alpn_protocols = vec![alpn.to_vec()];
    Ok(config)
}

fn peer_id(end_entity: &CertificateDer<'_>) -> Result<DeviceId, Error> {
    DeviceId::from_spki_der(end_entity.as_ref())
        .map_err(|_| Error::InvalidCertificate(CertificateError::BadEncoding))
}

fn verify_sig(
    message: &[u8],
    cert: &CertificateDer<'_>,
    dss: &DigitallySignedStruct,
    algs: &WebPkiSupportedAlgorithms,
) -> Result<HandshakeSignatureValid, Error> {
    if dss.scheme != SignatureScheme::ED25519 {
        return Err(PeerIncompatible::NoSignatureSchemesInCommon.into());
    }
    let spki = SubjectPublicKeyInfoDer::from(cert.as_ref());
    verify_tls13_signature_with_raw_key(message, &spki, dss, algs)
}

/// Client side: the server must present exactly the key we dialled.
#[derive(Debug)]
struct ServerVerifier {
    expected_peer: DeviceId,
    algs: WebPkiSupportedAlgorithms,
}

impl ServerCertVerifier for ServerVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        if peer_id(end_entity)? == self.expected_peer {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(Error::InvalidCertificate(
                CertificateError::ApplicationVerificationFailure,
            ))
        }
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        Err(PeerIncompatible::Tls12NotOffered.into())
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        verify_sig(message, cert, dss, &self.algs)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![SignatureScheme::ED25519]
    }

    fn requires_raw_public_keys(&self) -> bool {
        true
    }
}

/// Server side: only pinned peers, unless the pairing window is open.
/// When pairing is open, the endpoint still refuses unpinned peers on the normal ALPN.
#[derive(Debug)]
struct ClientVerifier {
    trust: Arc<dyn TrustStore>,
    pairing_open: Arc<AtomicBool>,
    algs: WebPkiSupportedAlgorithms,
}

impl ClientCertVerifier for ClientVerifier {
    fn offer_client_auth(&self) -> bool {
        true
    }

    fn client_auth_mandatory(&self) -> bool {
        true
    }

    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        &[]
    }

    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: UnixTime,
    ) -> Result<ClientCertVerified, Error> {
        let id = peer_id(end_entity)?;
        if self.trust.is_trusted(&id) || self.pairing_open.load(Ordering::SeqCst) {
            Ok(ClientCertVerified::assertion())
        } else {
            Err(Error::InvalidCertificate(
                CertificateError::ApplicationVerificationFailure,
            ))
        }
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        Err(PeerIncompatible::Tls12NotOffered.into())
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        verify_sig(message, cert, dss, &self.algs)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        vec![SignatureScheme::ED25519]
    }

    fn requires_raw_public_keys(&self) -> bool {
        true
    }
}
