//! "Phone in Finder" on the Mac without a File Provider extension.
//!
//! A WebDAV server bound to 127.0.0.1 exposes the phone's shared folders; macOS mounts it as a
//! network volume. The URL contains a random secret, so other processes cannot browse the phone
//! without it. Finder's hidden metadata (`._*`, `.DS_Store`, …) stays on the Mac.

mod fs;

use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};

use brege_core::{DeviceId, Node};
use dav_server::DavHandler;
use dav_server::fakels::FakeLs;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper_util::rt::TokioIo;
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;

pub use fs::PhoneFs;

#[derive(Debug, thiserror::Error)]
pub enum DriveError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

/// A running drive for one phone. Dropping it stops the server.
pub struct Drive {
    url: String,
    volume_name: String,
    addr: SocketAddr,
    cancel: CancellationToken,
}

impl Drive {
    /// Starts serving `phone`'s shared folders. `volume_name` becomes the Finder volume name.
    /// Must be called inside a Tokio runtime.
    pub async fn start(node: Node, phone: DeviceId, volume_name: &str) -> Result<Self, DriveError> {
        let volume_name = sanitize_volume_name(volume_name);
        let secret = random_hex(16);
        let prefix = format!("/{secret}/{volume_name}");

        let handler = DavHandler::builder()
            .filesystem(Box::new(PhoneFs::new(node, phone)))
            .locksystem(FakeLs::new())
            .strip_prefix(prefix.clone())
            .build_handler();

        let (listener, v6) = bind_loopback().await?;
        let addr = listener.local_addr()?;
        let cancel = CancellationToken::new();
        if let Some(v6) = v6 {
            tokio::spawn(serve(v6, handler.clone(), prefix.clone(), cancel.clone()));
        }
        tokio::spawn(serve(listener, handler, prefix.clone(), cancel.clone()));
        tracing::info!(%addr, "phone drive started");
        Ok(Self {
            url: format!("http://{addr}{prefix}/"),
            volume_name,
            addr,
            cancel,
        })
    }

    /// The URL to mount (contains the secret).
    pub fn url(&self) -> &str {
        &self.url
    }

    pub fn volume_name(&self) -> &str {
        &self.volume_name
    }

    pub fn local_addr(&self) -> SocketAddr {
        self.addr
    }

    pub fn stop(&self) {
        self.cancel.cancel();
    }
}

impl Drop for Drive {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}

/// Binds 127.0.0.1 and ::1 on the same port. The mount hostname resolves to both loopback
/// addresses, so serving on only one would let another local process on the other receive the
/// secret URL. Tries other ports while ::1 is taken.
async fn bind_loopback() -> std::io::Result<(TcpListener, Option<TcpListener>)> {
    const ATTEMPTS: usize = 16;
    let mut last_err = None;
    for _ in 0..ATTEMPTS {
        let v4 = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0))).await?;
        let port = v4.local_addr()?.port();
        match TcpListener::bind(SocketAddr::from((Ipv6Addr::LOCALHOST, port))).await {
            Ok(v6) => return Ok((v4, Some(v6))),
            // No IPv6 loopback at all: then no other process can listen on ::1 either.
            Err(e) if e.kind() == std::io::ErrorKind::AddrNotAvailable => {
                tracing::debug!("drive: no IPv6 loopback listener: {e}");
                return Ok((v4, None));
            }
            Err(e) => {
                tracing::debug!(port, "drive: [::1] port unavailable, trying another: {e}");
                last_err = Some(e);
            }
        }
    }
    Err(last_err.expect("at least one attempt"))
}

async fn serve(
    listener: TcpListener,
    handler: DavHandler,
    prefix: String,
    cancel: CancellationToken,
) {
    loop {
        let (stream, _) = tokio::select! {
            _ = cancel.cancelled() => return,
            accepted = listener.accept() => match accepted {
                Ok(a) => a,
                Err(e) => {
                    tracing::warn!("drive accept failed: {e}");
                    continue;
                }
            },
        };
        let handler = handler.clone();
        let prefix = prefix.clone();
        let cancel = cancel.clone();
        tokio::spawn(async move {
            let service = service_fn(move |req: hyper::Request<hyper::body::Incoming>| {
                let handler = handler.clone();
                let allowed = req.uri().path().starts_with(&prefix);
                async move {
                    if !allowed {
                        let mut not_found =
                            hyper::Response::new(dav_server::body::Body::from("not found"));
                        *not_found.status_mut() = hyper::StatusCode::NOT_FOUND;
                        return Ok::<_, std::convert::Infallible>(not_found);
                    }
                    Ok(handler.handle(req).await)
                }
            });
            let connection = http1::Builder::new()
                .keep_alive(true)
                .serve_connection(TokioIo::new(stream), service);
            tokio::select! {
                _ = cancel.cancelled() => {}
                result = connection => {
                    if let Err(e) = result {
                        tracing::debug!("drive connection ended: {e}");
                    }
                }
            }
        });
    }
}

/// Finder uses the last URL component as the volume name; keep it simple and URL-safe.
pub fn sanitize_volume_name(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c
            } else {
                '-'
            }
        })
        .collect();
    let trimmed = cleaned.trim_matches('-');
    let mut collapsed = String::with_capacity(trimmed.len());
    for c in trimmed.chars() {
        if !(c == '-' && collapsed.ends_with('-')) {
            collapsed.push(c);
        }
    }
    if collapsed.is_empty() {
        "Phone".to_string()
    } else {
        collapsed
    }
}

fn random_hex(bytes: usize) -> String {
    use ring::rand::SecureRandom;
    let mut buf = vec![0u8; bytes];
    ring::rand::SystemRandom::new()
        .fill(&mut buf)
        .expect("system rng");
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn volume_names() {
        assert_eq!(sanitize_volume_name("Pixel 10 Pro"), "Pixel-10-Pro");
        assert_eq!(sanitize_volume_name("  Sam's  Galaxy!! "), "Sam-s-Galaxy");
        assert_eq!(sanitize_volume_name("///"), "Phone");
    }

    #[tokio::test]
    async fn listens_on_both_loopbacks_on_one_port() {
        let (v4, v6) = bind_loopback().await.unwrap();
        if let Some(v6) = v6 {
            assert_eq!(
                v4.local_addr().unwrap().port(),
                v6.local_addr().unwrap().port()
            );
        }
    }
}
