//! The source filter keeps the port silent towards sources the node must not answer.

use std::collections::HashSet;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use brege_identity::{DeviceId, SecretKey};
use brege_transport::{Endpoint, EndpointOptions, SourceFilter, TrustStore};

#[derive(Debug, Default)]
struct Trust(Mutex<HashSet<DeviceId>>);

impl TrustStore for Trust {
    fn is_trusted(&self, id: &DeviceId) -> bool {
        self.0.lock().unwrap().contains(id)
    }
}

#[derive(Default)]
struct Policy(AtomicBool);

impl SourceFilter for Policy {
    fn allow(&self, _source: SocketAddr) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

fn endpoint() -> (Endpoint, Arc<Trust>, Arc<Policy>) {
    let trust = Arc::new(Trust::default());
    let ep = Endpoint::bind(
        "127.0.0.1:0".parse().unwrap(),
        SecretKey::generate().unwrap(),
        trust.clone(),
        EndpointOptions::default(),
    )
    .unwrap();
    let policy = Arc::new(Policy::default());
    let weak: std::sync::Weak<dyn SourceFilter> = Arc::downgrade(&policy) as _;
    ep.set_source_filter(weak);
    (ep, trust, policy)
}

/// A QUIC Initial with `version`, padded to 1200 bytes.
fn initial(version: u32) -> Vec<u8> {
    let mut p = vec![0xC0u8];
    p.extend_from_slice(&version.to_be_bytes());
    p.push(8);
    p.extend_from_slice(&[1, 2, 3, 4, 5, 6, 7, 8]);
    p.push(8);
    p.extend_from_slice(&[9; 8]);
    p.push(0); // token length
    let rest = 1200 - p.len() - 2;
    p.push(0x40 | (rest >> 8) as u8);
    p.push((rest & 0xff) as u8);
    p.resize(1200, 0);
    p
}

async fn probe(server: SocketAddr, packet: &[u8]) -> bool {
    let socket = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
    socket.send_to(packet, server).await.unwrap();
    let mut buf = [0u8; 2000];
    tokio::time::timeout(Duration::from_millis(700), socket.recv_from(&mut buf))
        .await
        .is_ok()
}

#[tokio::test]
async fn filtered_source_gets_no_version_negotiation() {
    let (mac, _, policy) = endpoint();
    let addr = mac.local_addr().unwrap();
    tokio::spawn({
        let mac = mac.clone();
        async move {
            while let Some(attempt) = mac.accept().await {
                attempt.ignore();
            }
        }
    });

    policy.0.store(true, Ordering::SeqCst);
    assert!(
        probe(addr, &initial(0x1a2a_3a4a)).await,
        "an allowed source gets a Version Negotiation packet"
    );

    policy.0.store(false, Ordering::SeqCst);
    mac.refresh_source_filter();
    assert!(!probe(addr, &initial(0x1a2a_3a4a)).await);
    assert!(!probe(addr, &initial(1)).await);
}

#[tokio::test]
async fn allowed_and_dialled_sources_still_connect() {
    let (mac, mac_trust, mac_policy) = endpoint();
    let (phone, phone_trust, phone_policy) = endpoint();
    mac_trust.0.lock().unwrap().insert(phone.device_id());
    phone_trust.0.lock().unwrap().insert(mac.device_id());
    tokio::spawn({
        let mac = mac.clone();
        async move {
            while let Some(attempt) = mac.accept().await {
                if let Ok(conn) = attempt.finish().await {
                    tokio::spawn(async move { conn.closed().await });
                }
            }
        }
    });

    // The Mac filters the phone: the dial never gets an answer.
    let refused = tokio::time::timeout(
        Duration::from_secs(2),
        phone.connect(mac.local_addr().unwrap(), mac.device_id()),
    )
    .await;
    assert!(!matches!(refused, Ok(Ok(_))), "filtered dial connected");

    // Allowed on the Mac. The phone still filters everyone, but lets replies from the address it
    // dialled through.
    mac_policy.0.store(true, Ordering::SeqCst);
    mac.refresh_source_filter();
    assert!(!phone_policy.0.load(Ordering::SeqCst));
    let conn = tokio::time::timeout(
        Duration::from_secs(5),
        phone.connect(mac.local_addr().unwrap(), mac.device_id()),
    )
    .await
    .expect("dial timed out")
    .expect("dial failed");
    assert_eq!(conn.peer(), mac.device_id());
    conn.close(0, b"done");
}
