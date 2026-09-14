use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use brege_identity::{DeviceId, SecretKey};
use brege_proto::StreamType;
use brege_proto::v1::{Envelope, Ping, envelope};
use brege_transport::{Endpoint, EndpointOptions, TrustStore, read_msg, write_msg};

#[derive(Debug, Default)]
struct Trust(Mutex<HashSet<DeviceId>>);

impl Trust {
    fn add(&self, id: DeviceId) {
        self.0.lock().unwrap().insert(id);
    }
}

impl TrustStore for Trust {
    fn is_trusted(&self, id: &DeviceId) -> bool {
        self.0.lock().unwrap().contains(id)
    }
}

/// In TLS 1.3 the client finishes its handshake before the server has checked the client key,
/// so a refused client may briefly see a connection that is then closed by the server.
async fn assert_refused(
    result: Result<brege_transport::Connection, brege_transport::TransportError>,
) {
    if let Ok(conn) = result {
        tokio::time::timeout(Duration::from_secs(2), conn.closed())
            .await
            .expect("server should close a refused connection");
    }
}

fn endpoint() -> (Endpoint, Arc<Trust>) {
    let trust = Arc::new(Trust::default());
    let ep = Endpoint::bind(
        "127.0.0.1:0".parse().unwrap(),
        SecretKey::generate().unwrap(),
        trust.clone(),
        EndpointOptions::default(),
    )
    .unwrap();
    (ep, trust)
}

#[tokio::test]
async fn untrusted_peer_is_refused_while_pairing_closed() {
    let (mac, _) = endpoint();
    let (phone, _) = endpoint();
    let addr = mac.local_addr().unwrap();
    let accept = tokio::spawn({
        let mac = mac.clone();
        async move {
            tokio::time::timeout(Duration::from_millis(1500), async {
                loop {
                    if let Ok(conn) = mac.accept().await.unwrap().finish().await {
                        return conn;
                    }
                }
            })
            .await
        }
    });
    assert_refused(phone.connect(addr, mac.device_id()).await).await;
    assert_refused(phone.connect_pairing(addr, mac.device_id()).await).await;
    assert!(accept.await.unwrap().is_err(), "nothing should be accepted");
}

#[tokio::test]
async fn pairing_connection_shares_exporter() {
    let (mac, _) = endpoint();
    let (phone, _) = endpoint();
    mac.set_pairing_open(true);
    let addr = mac.local_addr().unwrap();
    let server = tokio::spawn({
        let mac = mac.clone();
        async move { mac.accept().await.unwrap().finish().await.unwrap() }
    });
    let client = phone.connect_pairing(addr, mac.device_id()).await.unwrap();
    let server = server.await.unwrap();
    assert!(client.is_pairing() && server.is_pairing());
    assert_eq!(server.peer(), phone.device_id());
    assert_eq!(client.peer(), mac.device_id());
    assert_eq!(
        client.pairing_exporter().unwrap(),
        server.pairing_exporter().unwrap()
    );
}

#[tokio::test]
async fn untrusted_peer_cannot_use_normal_alpn_during_pairing() {
    let (mac, _) = endpoint();
    let (phone, _) = endpoint();
    mac.set_pairing_open(true);
    let addr = mac.local_addr().unwrap();
    let accept = tokio::spawn({
        let mac = mac.clone();
        async move {
            tokio::time::timeout(Duration::from_millis(1500), async {
                loop {
                    if let Ok(conn) = mac.accept().await.unwrap().finish().await {
                        return conn;
                    }
                }
            })
            .await
        }
    });
    // The TLS handshake succeeds (pairing is open), but the endpoint closes it immediately.
    assert_refused(phone.connect(addr, mac.device_id()).await).await;
    assert!(accept.await.unwrap().is_err());
}

#[tokio::test]
async fn wrong_server_key_fails() {
    let (mac, _) = endpoint();
    let (phone, _) = endpoint();
    mac.set_pairing_open(true);
    let impostor = SecretKey::generate().unwrap().device_id();
    let accept = tokio::spawn({
        let mac = mac.clone();
        async move {
            tokio::time::timeout(Duration::from_millis(1500), async {
                loop {
                    if let Ok(conn) = mac.accept().await.unwrap().finish().await {
                        return conn;
                    }
                }
            })
            .await
        }
    });
    assert!(
        phone
            .connect_pairing(mac.local_addr().unwrap(), impostor)
            .await
            .is_err()
    );
    assert!(accept.await.unwrap().is_err());
}

#[tokio::test]
async fn trusted_peers_exchange_typed_streams_and_datagrams() {
    let (mac, mac_trust) = endpoint();
    let (phone, phone_trust) = endpoint();
    mac_trust.add(phone.device_id());
    phone_trust.add(mac.device_id());
    let addr = mac.local_addr().unwrap();

    let server = tokio::spawn({
        let mac = mac.clone();
        async move {
            let conn = mac.accept().await.unwrap().finish().await.unwrap();
            let (kind, mut send, mut recv) = conn.accept_stream().await.unwrap();
            assert_eq!(kind, StreamType::Control);
            let msg: Envelope = read_msg(&mut recv).await.unwrap().unwrap();
            write_msg(
                &mut send,
                &Envelope {
                    ack: msg.seq,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
            send.finish().unwrap();
            let dg = conn.read_datagram().await.unwrap();
            conn.send_datagram(dg).unwrap();
            conn.closed().await;
        }
    });

    let conn = phone.connect(addr, mac.device_id()).await.unwrap();
    assert!(!conn.is_pairing());
    let (mut send, mut recv) = conn.open_stream(StreamType::Control).await.unwrap();
    let ping = Envelope {
        seq: 42,
        payload: Some(envelope::Payload::Ping(Ping {})),
        ..Default::default()
    };
    write_msg(&mut send, &ping).await.unwrap();
    let reply: Envelope = read_msg(&mut recv).await.unwrap().unwrap();
    assert_eq!(reply.ack, 42);
    assert!(
        read_msg::<Envelope>(&mut recv).await.unwrap().is_none(),
        "stream finished"
    );

    conn.send_datagram(bytes::Bytes::from_static(b"opus"))
        .unwrap();
    assert_eq!(&conn.read_datagram().await.unwrap()[..], b"opus");
    conn.close(0, b"done");
    server.await.unwrap();
}
