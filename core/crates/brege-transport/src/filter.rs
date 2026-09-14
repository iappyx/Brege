//! Drops datagrams from sources Brêge must not answer, before quinn sees them.
//!
//! quinn replies to some packets without asking the application, e.g. with a Version Negotiation
//! packet to an unknown QUIC version. `Incoming::ignore` comes too late for those, so the socket
//! itself filters by source: towards an untrusted network the port looks closed.

use std::collections::HashMap;
use std::fmt;
use std::io::{self, IoSliceMut};
use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
use std::sync::{Arc, Mutex, RwLock, Weak};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use quinn::udp::{RecvMeta, Transmit};
use quinn::{AsyncUdpSocket, UdpPoller};

/// Decides which sources may reach the QUIC stack. Called on the endpoint's I/O task with the
/// endpoint locked, at most every [`DECISION_TTL`] per source IP: it must be quick and must not
/// call back into the endpoint.
pub trait SourceFilter: Send + Sync + 'static {
    fn allow(&self, source: SocketAddr) -> bool;
}

/// How long a decision per source IP is reused.
const DECISION_TTL: Duration = Duration::from_secs(10);
/// Replies from an address this endpoint dialled are let through for this long.
const DIAL_TTL: Duration = Duration::from_secs(60);
/// Batches in a row that are dropped entirely before the socket yields to other tasks.
const MAX_DROPPED_BATCHES: usize = 16;

#[derive(Default)]
pub(crate) struct FilterState {
    /// `None` lets everything through (no policy installed).
    policy: RwLock<Option<Weak<dyn SourceFilter>>>,
    decisions: Mutex<HashMap<IpAddr, (Instant, bool)>>,
    dialed: Mutex<HashMap<IpAddr, Instant>>,
}

impl FilterState {
    pub fn set_policy(&self, policy: Weak<dyn SourceFilter>) {
        *self.policy.write().unwrap() = Some(policy);
        self.forget_decisions();
    }

    pub fn forget_decisions(&self) {
        self.decisions.lock().unwrap().clear();
    }

    pub fn note_dial(&self, addr: SocketAddr) {
        let ip = addr.ip().to_canonical();
        let now = Instant::now();
        let mut dialed = self.dialed.lock().unwrap();
        dialed.retain(|_, at| now.duration_since(*at) < DIAL_TTL);
        dialed.insert(ip, now);
        drop(dialed);
        self.decisions.lock().unwrap().remove(&ip);
    }

    fn allows(&self, source: SocketAddr) -> bool {
        if self.policy.read().unwrap().is_none() {
            return true;
        }
        let ip = source.ip().to_canonical();
        let now = Instant::now();
        if let Some(&(at, allowed)) = self.decisions.lock().unwrap().get(&ip)
            && now.duration_since(at) < DECISION_TTL
        {
            return allowed;
        }
        if self
            .dialed
            .lock()
            .unwrap()
            .get(&ip)
            .is_some_and(|at| now.duration_since(*at) < DIAL_TTL)
        {
            return true;
        }
        let policy = self.policy.read().unwrap().as_ref().and_then(Weak::upgrade);
        // The node is gone; nothing is served any more.
        let Some(policy) = policy else {
            return true;
        };
        let allowed = policy.allow(source);
        let mut decisions = self.decisions.lock().unwrap();
        if decisions.len() >= 1024 {
            decisions.retain(|_, (at, _)| now.duration_since(*at) < DECISION_TTL);
        }
        decisions.insert(ip, (now, allowed));
        allowed
    }
}

/// The runtime's UDP socket with [`FilterState`] applied to everything it receives.
pub(crate) struct FilteredSocket {
    pub inner: Arc<dyn AsyncUdpSocket>,
    pub state: Arc<FilterState>,
}

impl fmt::Debug for FilteredSocket {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("FilteredSocket")
            .field("inner", &self.inner)
            .finish_non_exhaustive()
    }
}

impl AsyncUdpSocket for FilteredSocket {
    fn create_io_poller(self: Arc<Self>) -> Pin<Box<dyn UdpPoller>> {
        self.inner.clone().create_io_poller()
    }

    fn try_send(&self, transmit: &Transmit) -> io::Result<()> {
        self.inner.try_send(transmit)
    }

    fn poll_recv(
        &self,
        cx: &mut Context,
        bufs: &mut [IoSliceMut<'_>],
        meta: &mut [RecvMeta],
    ) -> Poll<io::Result<usize>> {
        for _ in 0..MAX_DROPPED_BATCHES {
            let received = match self.inner.poll_recv(cx, bufs, meta) {
                Poll::Ready(Ok(n)) => n,
                other => return other,
            };
            // Moves the datagrams that pass to the front, so quinn reads them as one batch.
            let mut kept = 0;
            for i in 0..received {
                if !self.state.allows(meta[i].addr) {
                    continue;
                }
                if kept != i {
                    meta[kept] = meta[i];
                    let len = meta[i].len;
                    let (front, rest) = bufs.split_at_mut(i);
                    front[kept][..len].copy_from_slice(&rest[0][..len]);
                }
                kept += 1;
            }
            if kept > 0 || received == 0 {
                return Poll::Ready(Ok(kept));
            }
        }
        // A flood of dropped datagrams must not starve the runtime: try again on the next poll.
        cx.waker().wake_by_ref();
        Poll::Pending
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        self.inner.local_addr()
    }

    fn max_transmit_segments(&self) -> usize {
        self.inner.max_transmit_segments()
    }

    fn max_receive_segments(&self) -> usize {
        self.inner.max_receive_segments()
    }

    fn may_fragment(&self) -> bool {
        self.inner.may_fragment()
    }
}
