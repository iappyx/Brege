//! Reconnects to paired devices with exponential backoff.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use brege_identity::DeviceId;

use crate::node::Inner;
use crate::session;

/// Port both apps try to listen on, so either side can dial the other.
pub const DEFAULT_PORT: u16 = 47400;
const MIN_BACKOFF: Duration = Duration::from_secs(1);
const MAX_BACKOFF: Duration = Duration::from_secs(60);
const TICK: Duration = Duration::from_millis(500);

#[derive(Debug, Clone, Copy)]
pub(crate) struct Backoff {
    next_attempt: Instant,
    delay: Duration,
    /// A dial or an incoming handshake with the device runs. Survives backoff resets, so a burst
    /// of discoveries or network changes never starts a second connection next to it.
    in_flight: bool,
}

impl Backoff {
    fn new(now: Instant) -> Self {
        Self {
            next_attempt: now,
            delay: MIN_BACKOFF,
            in_flight: false,
        }
    }
}

/// Lets the next dial to `peer` (all devices: `None`) start at once. Connections in progress are
/// kept track of.
pub(crate) fn reset_backoff(inner: &Inner, peer: Option<&DeviceId>) {
    let now = Instant::now();
    let mut state = inner.dial_state.lock().unwrap();
    state.retain(|id, entry| {
        if peer.is_some_and(|p| p != id) {
            return true;
        }
        *entry = Backoff {
            in_flight: entry.in_flight,
            ..Backoff::new(now)
        };
        entry.in_flight
    });
}

/// Marks a connection with `peer` as in progress until the guard is dropped, unless one already
/// is; then returns `None`.
pub(crate) fn begin_connecting(inner: &Inner, peer: DeviceId) -> Option<Connecting<'_>> {
    let mut state = inner.dial_state.lock().unwrap();
    let entry = state
        .entry(peer)
        .or_insert_with(|| Backoff::new(Instant::now()));
    if entry.in_flight {
        return None;
    }
    entry.in_flight = true;
    Some(Connecting { inner, peer })
}

pub(crate) struct Connecting<'a> {
    inner: &'a Inner,
    peer: DeviceId,
}

impl Drop for Connecting<'_> {
    fn drop(&mut self) {
        if let Some(entry) = self.inner.dial_state.lock().unwrap().get_mut(&self.peer) {
            entry.in_flight = false;
        }
    }
}

pub(crate) async fn run(inner: Arc<Inner>) {
    loop {
        tokio::select! {
            _ = inner.cancel.cancelled() => return,
            _ = inner.dial_now.notified() => {}
            _ = tokio::time::sleep(TICK) => {}
        }
        let devices = match inner.store.lock().unwrap().devices() {
            Ok(d) => d,
            Err(e) => {
                tracing::warn!("dialer cannot read devices: {e}");
                continue;
            }
        };
        for device in devices {
            if inner.is_connected(&device.id) {
                continue;
            }
            let now = Instant::now();
            // Backoff first, so the path checks below do not run on every tick.
            if inner
                .dial_state
                .lock()
                .unwrap()
                .get(&device.id)
                .is_some_and(|e| e.in_flight || now < e.next_attempt)
            {
                continue;
            }
            // Candidates come from Bonjour with the device's rotating id: proof it is the device.
            let discovered = inner
                .candidates
                .lock()
                .unwrap()
                .get(&device.id)
                .cloned()
                .unwrap_or_default();
            let mut addrs: Vec<SocketAddr> = discovered.iter().map(|c| c.addr).collect();
            if let Some(addr) = device.last_addr.as_deref().and_then(|a| a.parse().ok())
                && !addrs.contains(&addr)
            {
                addrs.push(addr);
            }
            // Peers listen on DEFAULT_PORT unless it was taken; a stored address may carry an
            // older random port, so also try the default port on the same IP.
            for addr in addrs.clone() {
                let default = SocketAddr::new(addr.ip(), DEFAULT_PORT);
                if !addrs.contains(&default) {
                    addrs.push(default);
                }
            }
            for addr in inner.hotspot_addresses(device.id) {
                if !addrs.contains(&addr) {
                    addrs.push(addr);
                }
            }
            // Only paths the network privacy rules allow.
            addrs.retain(|a| {
                let network = discovered
                    .iter()
                    .find(|c| c.addr == *a)
                    .and_then(|c| c.network.as_deref());
                inner.may_dial(device.id, *a, network)
            });
            {
                let mut state = inner.dial_state.lock().unwrap();
                let entry = state.entry(device.id).or_insert_with(|| Backoff::new(now));
                if entry.in_flight || now < entry.next_attempt {
                    continue;
                }
                // Also when nothing may be dialled: every change of the rules resets the backoff.
                entry.next_attempt = now + entry.delay;
                entry.delay = (entry.delay * 2).min(MAX_BACKOFF);
                if addrs.is_empty() {
                    continue;
                }
                entry.in_flight = true;
            }

            let inner = inner.clone();
            tokio::spawn(async move {
                if let Err(e) = session::establish_outgoing(&inner, addrs, device.id).await {
                    tracing::debug!(peer = ?device.id, "reconnect attempt failed: {e}");
                }
                if let Some(entry) = inner.dial_state.lock().unwrap().get_mut(&device.id) {
                    entry.in_flight = false;
                }
            });
        }
    }
}
