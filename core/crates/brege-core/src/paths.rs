//! Network privacy: the connection paths Brêge may use.
//!
//! A path is the local interface the operating system would use to reach an address. Brêge
//! announces, dials and answers only on trusted paths: networks and tunnels the user allowed, the
//! network a device was paired on, the phone's own hotspot and the network joined through a
//! hotspot request. Other networks are never trusted by themselves; the apps ask.

use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};
use std::sync::Arc;

use brege_identity::DeviceId;
use brege_store::KnownNetwork;

use crate::node::Inner;
use crate::{CoreError, Event, Result};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InterfaceKind {
    Wifi,
    Ethernet,
    Cellular,
    /// A tunnel: WireGuard, IPsec, any VPN app.
    Vpn,
    /// The phone's own hotspot (or USB / Bluetooth tethering).
    Hotspot,
    Loopback,
    Other,
}

/// One interface as the platform reports it.
#[derive(Debug, Clone)]
pub struct NetInterface {
    pub name: String,
    pub kind: InterfaceKind,
    /// Addresses with their prefix length.
    pub addresses: Vec<(IpAddr, u8)>,
    pub gateway: Option<IpAddr>,
    /// The gateway's hardware address, where the platform can read it (the Mac).
    pub gateway_hw: Option<String>,
    /// The Wi‑Fi name, where the platform may read it (Location access).
    pub ssid: Option<String>,
}

/// A path to one address.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Path {
    pub interface: String,
    pub kind: InterfaceKind,
    /// Identifies the network or tunnel; empty for loopback, hotspot and mobile data.
    pub fingerprint: String,
    pub label: String,
    pub ssid: Option<String>,
    /// The router's hardware address is part of the fingerprint.
    pub has_router_hw: bool,
    /// The address is inside the interface's own subnet.
    pub on_link: bool,
    /// The interface's IPv4 router.
    pub router: Option<IpAddr>,
}

/// A network the device is on, or a tunnel that was needed to reach a paired device, for the
/// apps' "Use Brêge on this network?" and "Use this VPN?" questions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NetworkPath {
    pub fingerprint: String,
    pub is_vpn: bool,
    pub label: String,
    pub ssid: String,
    pub trusted: bool,
    /// The user chose not to use this network ("Not here"): do not ask again.
    pub declined: bool,
    /// Paired devices that could not be reached because this path is not trusted.
    pub blocked_devices: Vec<DeviceId>,
}

/// An address a paired device announced with its rotating Bonjour id.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Candidate {
    pub addr: SocketAddr,
    /// The network ([`network_key`]) the announcement came from; `None` while the interfaces are
    /// not reported yet. The announcement proves the device only on that network.
    pub network: Option<String>,
}

/// Mac side: a running hotspot request.
#[derive(Debug, Clone)]
struct HotspotRequest {
    phone: DeviceId,
    /// The Wi‑Fi name of the hotspot, where known.
    ssid: Option<String>,
}

#[derive(Default)]
pub(crate) struct PathState {
    /// `None` until the platform reports its interfaces. Nothing is restricted before that, unless
    /// [`crate::NodeConfig::restrict_network_until_reported`] is set.
    interfaces: Option<Vec<NetInterface>>,
    /// Mac side: the Wi‑Fi network a hotspot request joins may be used, and is remembered once the
    /// phone connects over it.
    hotspot: Option<HotspotRequest>,
    /// Tunnels allowed for this run only ("Allow once"); never remembered.
    allowed_once: HashSet<String>,
    /// Untrusted paths that blocked a dial, with the devices behind them.
    blocked: HashMap<String, (Path, HashSet<DeviceId>)>,
}

/// How much a known network record says about a path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Standing {
    /// Allowed, and the network cannot be mistaken for a look-alike: the router's hardware address
    /// or the Wi‑Fi name matched.
    Verified,
    /// Allowed, but only subnet and router address matched, which other networks can share.
    Unverified,
    Declined,
    Unknown,
}

/// Separates the Wi‑Fi names of one known network in its `ssid` column (e.g. both bands of a
/// router, or a name added later). A single name is stored as it is.
const NAME_SEPARATOR: char = '\u{1f}';

fn names(record: &KnownNetwork) -> impl Iterator<Item = &str> {
    record.ssid.split(NAME_SEPARATOR).filter(|n| !n.is_empty())
}

fn has_name(record: &KnownNetwork, name: &str) -> bool {
    names(record).any(|n| n == name)
}

/// `record`'s names plus `name`.
fn with_name(record: &KnownNetwork, name: Option<&str>) -> String {
    let mut all: Vec<&str> = names(record).collect();
    if let Some(name) = name.filter(|n| !n.is_empty() && !all.contains(n)) {
        all.push(name);
    }
    all.join(&NAME_SEPARATOR.to_string())
}

fn standing(path: &Path, known: &HashMap<String, KnownNetwork>) -> Standing {
    let Some(record) = known.get(&path.fingerprint) else {
        return Standing::Unknown;
    };
    let named = names(record).next().is_some();
    // A different Wi‑Fi name with the same addresses is a different network, for a "Not here" too.
    if let Some(ssid) = &path.ssid
        && named
        && !has_name(record, ssid)
    {
        return Standing::Unknown;
    }
    if !record.trusted {
        return Standing::Declined;
    }
    if (path.ssid.is_some() && named) || path.has_router_hw || path.kind == InterfaceKind::Vpn {
        Standing::Verified
    } else {
        Standing::Unverified
    }
}

/// Identifies the network a Bonjour announcement arrived on: the fingerprint plus the Wi‑Fi name,
/// because look-alike networks share a fingerprint.
fn network_key(path: &Path) -> String {
    format!(
        "{}{NAME_SEPARATOR}{}",
        path.fingerprint,
        path.ssid.as_deref().unwrap_or_default()
    )
}

impl PathState {
    /// The network a hotspot request for `phone` (any phone: `None`) joins may be used: a Wi‑Fi
    /// network, with the requested name where both names are known.
    fn hotspot_allows(&self, path: &Path, phone: Option<DeviceId>) -> bool {
        self.hotspot.as_ref().is_some_and(|h| {
            path.kind == InterfaceKind::Wifi
                && phone.is_none_or(|p| p == h.phone)
                && match (&h.ssid, &path.ssid) {
                    (Some(wanted), Some(ssid)) => wanted == ssid,
                    _ => true,
                }
        })
    }
}

impl Inner {
    /// Known networks, read from the database once and cached: the dialer and the socket filter
    /// ask often. Every write goes through [`Inner::remember_network`] or
    /// [`crate::Node::forget_network`], which drop the cache.
    fn known_networks_by_fingerprint(&self) -> Arc<HashMap<String, KnownNetwork>> {
        let mut cache = self.known_networks.lock().unwrap();
        if let Some(known) = cache.as_ref() {
            return known.clone();
        }
        let known: Arc<HashMap<_, _>> = match self.store.lock().unwrap().known_networks() {
            Ok(networks) => Arc::new(
                networks
                    .into_iter()
                    .map(|n| (n.fingerprint.clone(), n))
                    .collect(),
            ),
            // Not cached, so the next call tries again.
            Err(e) => {
                tracing::warn!("cannot read known networks: {e}");
                return Arc::default();
            }
        };
        *cache = Some(known.clone());
        known
    }

    fn remember_network(&self, network: &KnownNetwork) -> Result<()> {
        let result = self.store.lock().unwrap().remember_network(network);
        *self.known_networks.lock().unwrap() = None;
        Ok(result?)
    }

    /// Whether nothing may be used before the platform reports its interfaces, except loopback.
    fn restricted_until_reported(&self, addr: IpAddr) -> bool {
        self.config.restrict_network_until_reported && !addr.to_canonical().is_loopback()
    }

    /// The rules deciding which paths may be used changed (interfaces, decisions, the pairing
    /// window, a hotspot request): forget cached socket filter decisions, close sessions that
    /// lost their path, let the dialer try at once and the apps ask again.
    pub(crate) fn network_rules_changed(&self) {
        self.endpoint.refresh_source_filter();
        self.recheck_sessions();
        crate::dialer::reset_backoff(self, None);
        self.dial_now.notify_one();
        self.emit(Event::NetworkPathsChanged);
    }

    /// The network key of the path to `addr`, for tagging a Bonjour announcement.
    pub(crate) fn network_key_towards(&self, addr: SocketAddr) -> Option<String> {
        let state = self.paths.lock().unwrap();
        path_to(state.interfaces.as_ref()?, addr.ip()).map(|p| network_key(&p))
    }

    /// Mac side: while a hotspot request for `phone` runs, the phone is the router of the Wi‑Fi
    /// network it joins, so its default port there is worth a try.
    pub(crate) fn hotspot_addresses(&self, phone: DeviceId) -> Vec<SocketAddr> {
        let state = self.paths.lock().unwrap();
        if state.hotspot.as_ref().is_none_or(|h| h.phone != phone) {
            return Vec::new();
        }
        state
            .interfaces
            .iter()
            .flatten()
            .filter(|i| i.kind == InterfaceKind::Wifi)
            .filter_map(|i| {
                let (address, prefix) = *i.addresses.iter().find(|(a, _)| a.is_ipv4())?;
                let path = lan_path(i, address, prefix, true)?;
                let router = path
                    .router
                    .filter(|_| state.hotspot_allows(&path, Some(phone)))?;
                Some(SocketAddr::new(router, crate::DEFAULT_PORT))
            })
            .collect()
    }

    fn is_trusted(
        &self,
        path: &Path,
        state: &PathState,
        known: &HashMap<String, KnownNetwork>,
    ) -> bool {
        match path.kind {
            InterfaceKind::Loopback | InterfaceKind::Hotspot => true,
            InterfaceKind::Cellular => false,
            InterfaceKind::Vpn => {
                matches!(
                    standing(path, known),
                    Standing::Verified | Standing::Unverified
                ) || state.allowed_once.contains(&path.fingerprint)
            }
            InterfaceKind::Wifi | InterfaceKind::Ethernet | InterfaceKind::Other => {
                matches!(
                    standing(path, known),
                    Standing::Verified | Standing::Unverified
                ) || state.hotspot_allows(path, None)
                    || self.endpoint.is_pairing_open()
            }
        }
    }

    /// Whether the dialer may try `addr` for `device`. `discovered_on`: the network key of a
    /// Bonjour announcement of this address with the device's rotating id, which proves it is the
    /// device, but only while the path still leads to that network.
    pub(crate) fn may_dial(
        &self,
        device: DeviceId,
        addr: SocketAddr,
        discovered_on: Option<&str>,
    ) -> bool {
        let known = self.known_networks_by_fingerprint();
        let mut state = self.paths.lock().unwrap();
        let Some(interfaces) = state.interfaces.as_ref() else {
            return !self.restricted_until_reported(addr.ip());
        };
        let Some(path) = path_to(interfaces, addr.ip()) else {
            return false;
        };
        let allowed = match path.kind {
            InterfaceKind::Loopback | InterfaceKind::Hotspot => true,
            InterfaceKind::Cellular => false,
            InterfaceKind::Vpn => self.is_trusted(&path, &state, &known),
            // A stored address is only tried where the network is certain; otherwise the device
            // must announce itself first, so a look-alike network (same subnet and router address)
            // never sees a dial.
            _ => {
                let standing = standing(&path, &known);
                let discovered = discovered_on.is_some_and(|key| key == network_key(&path));
                // "Not here" also holds when the other device announces itself on that network.
                (path.on_link
                    && standing != Standing::Declined
                    && (discovered
                        || standing == Standing::Verified
                        || state.hotspot_allows(&path, Some(device))
                        || self.endpoint.is_pairing_open()))
                    // Addresses beyond the local subnet (a routed home network) only where the
                    // network is certain.
                    || (!path.on_link && standing == Standing::Verified)
            }
        };
        if !allowed
            && !path.fingerprint.is_empty()
            && (path.kind == InterfaceKind::Vpn || path.on_link)
        {
            let first = !state.blocked.contains_key(&path.fingerprint);
            state
                .blocked
                .entry(path.fingerprint.clone())
                .or_insert_with(|| (path.clone(), HashSet::new()))
                .1
                .insert(device);
            if first {
                drop(state);
                self.emit(Event::NetworkPathsChanged);
            }
        }
        allowed
    }

    /// A connection keeps working when a device moves to another network (QUIC follows it), so
    /// after every network change each one is checked again. Those whose route is no longer
    /// allowed are closed; the dialer then applies the rules and the apps can ask.
    ///
    /// QUIC only follows the side that dialled: when this device answered a connection and its
    /// own address towards the peer changed, the peer drops everything sent from the new address.
    /// Such sessions are closed too, and this device dials again.
    pub(crate) fn recheck_sessions(&self) {
        let known = self.known_networks_by_fingerprint();
        let sessions: Vec<_> = self
            .sessions
            .lock()
            .unwrap()
            .iter()
            .map(|(id, s)| (*id, s.conn.clone(), s.dialer == self.id, s.local_ip))
            .collect();
        let state = self.paths.lock().unwrap();
        let Some(interfaces) = state.interfaces.as_ref() else {
            return;
        };
        let mut untrusted = Vec::new();
        let mut moved = Vec::new();
        for (peer, conn, dialled_by_us, local_ip) in sessions {
            let remote = conn.remote_addr().ip();
            let allowed = path_to(interfaces, remote).is_some_and(|path| {
                self.is_trusted(&path, &state, &known)
                    // An authenticated device on the same link, e.g. found by its rotating id.
                    || (is_lan(path.kind)
                        && path.on_link
                        && standing(&path, &known) != Standing::Declined)
            });
            if !allowed {
                untrusted.push((peer, conn));
            } else if !dialled_by_us
                && local_ip.is_some()
                && local_address_towards(remote) != local_ip
            {
                moved.push((peer, conn));
            }
        }
        drop(state);
        for (peer, conn) in untrusted {
            tracing::info!(?peer, "closing connection: its network is not allowed");
            conn.close(5, b"network not allowed");
        }
        for (peer, conn) in &moved {
            tracing::info!(?peer, "closing connection: this device's address changed");
            conn.close(6, b"address changed");
        }
        if !moved.is_empty() {
            self.dial_now.notify_one();
        }
    }

    /// Whether to answer a connection attempt from `remote` at all. Untrusted attempts get no
    /// reply, so the port looks closed and the device's key is not handed out.
    pub(crate) fn may_answer(&self, remote: SocketAddr) -> bool {
        let known = self.known_networks_by_fingerprint();
        let state = self.paths.lock().unwrap();
        let Some(interfaces) = state.interfaces.as_ref() else {
            return !self.restricted_until_reported(remote.ip());
        };
        path_to(interfaces, remote.ip()).is_some_and(|path| self.is_trusted(&path, &state, &known))
    }

    /// After an authenticated connection with `peer`. Remembers the network only where the user
    /// started something on it (pairing, a hotspot request); on a trusted network it records the
    /// Wi‑Fi name once it is readable, where the router's hardware address proves the network.
    pub(crate) fn connected_over(&self, remote: SocketAddr, peer: DeviceId, pairing: bool) {
        let known = self.known_networks_by_fingerprint();
        let (path, hotspot) = {
            let state = self.paths.lock().unwrap();
            let Some(interfaces) = state.interfaces.as_ref() else {
                return;
            };
            match path_to(interfaces, remote.ip()) {
                Some(path) if !path.fingerprint.is_empty() && path.kind != InterfaceKind::Vpn => {
                    // Only the network the phone itself provides: the phone is its router, or it
                    // has the requested Wi‑Fi name.
                    let hotspot = state.hotspot.as_ref().is_some_and(|h| {
                        state.hotspot_allows(&path, Some(peer))
                            && (path.router == Some(remote.ip().to_canonical())
                                || (h.ssid.is_some() && h.ssid == path.ssid))
                    });
                    (path, hotspot)
                }
                _ => return,
            }
        };
        let record = known.get(&path.fingerprint);
        let now = crate::now_ms();
        let update = match record {
            None if pairing || hotspot => Some(KnownNetwork {
                fingerprint: path.fingerprint.clone(),
                kind: "lan".into(),
                label: path.label.clone(),
                added_ms: now,
                last_used_ms: now,
                ssid: path.ssid.clone().unwrap_or_default(),
                trusted: true,
            }),
            // Pairing is the user's choice of this network, also where they declined it before.
            Some(r)
                if pairing
                    && (!r.trusted || path.ssid.as_ref().is_some_and(|s| !has_name(r, s))) =>
            {
                Some(KnownNetwork {
                    label: path.label.clone(),
                    ssid: if r.trusted {
                        with_name(r, path.ssid.as_deref())
                    } else {
                        path.ssid.clone().unwrap_or_default()
                    },
                    last_used_ms: now,
                    trusted: true,
                    ..r.clone()
                })
            }
            Some(r)
                if r.trusted
                    && names(r).next().is_none()
                    && path.ssid.is_some()
                    && path.has_router_hw =>
            {
                Some(KnownNetwork {
                    label: path.label.clone(),
                    ssid: path.ssid.clone().unwrap_or_default(),
                    last_used_ms: now,
                    ..r.clone()
                })
            }
            _ => None,
        };
        let Some(network) = update else { return };
        if let Err(e) = self.remember_network(&network) {
            tracing::warn!("could not remember network: {e}");
            return;
        }
        tracing::info!(label = %network.label, "network remembered");
        self.paths
            .lock()
            .unwrap()
            .blocked
            .remove(&network.fingerprint);
        self.endpoint.refresh_source_filter();
        self.emit(Event::NetworkPathsChanged);
    }
}

/// Lets the socket filter pass only sources this device may answer, or that belong to a
/// connection it already has.
impl brege_transport::SourceFilter for Inner {
    fn allow(&self, source: SocketAddr) -> bool {
        let ip = source.ip().to_canonical();
        self.may_answer(source)
            || self.held_addresses.lock().unwrap().contains_key(&ip)
            || self
                .sessions
                .lock()
                .unwrap()
                .values()
                .any(|s| s.conn.remote_addr().ip().to_canonical() == ip)
    }
}

/// Keeps datagrams from a peer's address passing the socket filter while a connection that is not
/// a session yet (a handshake, pairing) uses it.
pub(crate) struct AddressHold<'a> {
    inner: &'a Inner,
    ip: IpAddr,
}

impl Inner {
    pub(crate) fn hold_address(&self, addr: SocketAddr) -> AddressHold<'_> {
        let ip = addr.ip().to_canonical();
        *self.held_addresses.lock().unwrap().entry(ip).or_default() += 1;
        AddressHold { inner: self, ip }
    }
}

impl Drop for AddressHold<'_> {
    fn drop(&mut self) {
        let mut held = self.inner.held_addresses.lock().unwrap();
        if let Some(count) = held.get_mut(&self.ip) {
            *count -= 1;
            if *count == 0 {
                held.remove(&self.ip);
            }
        }
    }
}

impl crate::Node {
    /// The platform's interfaces, on start and after every network change. Also resets reconnect
    /// backoff, like [`crate::Node::network_changed`].
    pub fn set_network_interfaces(&self, interfaces: Vec<NetInterface>) {
        {
            let mut state = self.inner.paths.lock().unwrap();
            // An announcement only proves the device on the network it came from.
            let mut candidates = self.inner.candidates.lock().unwrap();
            for list in candidates.values_mut() {
                list.retain_mut(|c| {
                    let key = path_to(&interfaces, c.addr.ip()).map(|p| network_key(&p));
                    // Announced before the first report: most likely on the current network.
                    let network = c
                        .network
                        .get_or_insert_with(|| key.clone().unwrap_or_default());
                    key.as_deref() == Some(network.as_str())
                });
            }
            candidates.retain(|_, list| !list.is_empty());
            drop(candidates);
            state.interfaces = Some(interfaces);
            state.blocked.clear();
        }
        self.inner.network_rules_changed();
    }

    /// Mac side: while a hotspot request for `phone` runs, the Wi‑Fi network it joins may be used
    /// (`ssid`: the hotspot's name, where known).
    pub fn set_hotspot_pending(&self, phone: DeviceId, ssid: Option<String>, pending: bool) {
        self.inner.paths.lock().unwrap().hotspot = pending.then(|| HotspotRequest {
            phone,
            ssid: ssid.filter(|s| !s.is_empty()),
        });
        self.inner.network_rules_changed();
    }

    /// Networks the device is on, plus tunnels that blocked a paired device.
    pub fn network_paths(&self) -> Vec<NetworkPath> {
        let known = self.inner.known_networks_by_fingerprint();
        let state = self.inner.paths.lock().unwrap();
        let blocked_devices = |fingerprint: &str| -> Vec<DeviceId> {
            state
                .blocked
                .get(fingerprint)
                .map(|(_, d)| d.iter().copied().collect())
                .unwrap_or_default()
        };
        let mut paths: Vec<NetworkPath> = state
            .interfaces
            .iter()
            .flatten()
            .filter(|i| is_lan(i.kind) && i.gateway.is_some_and(|g| g.is_ipv4()))
            .filter_map(|i| {
                let (address, prefix) = *i.addresses.iter().find(|(a, _)| a.is_ipv4())?;
                lan_path(i, address, prefix, false)
            })
            .map(|path| NetworkPath {
                trusted: self.inner.is_trusted(&path, &state, &known),
                declined: standing(&path, &known) == Standing::Declined,
                blocked_devices: blocked_devices(&path.fingerprint),
                ssid: path.ssid.clone().unwrap_or_default(),
                fingerprint: path.fingerprint,
                is_vpn: false,
                label: path.label,
            })
            .collect();
        for (fingerprint, (path, devices)) in &state.blocked {
            if path.kind == InterfaceKind::Vpn {
                paths.push(NetworkPath {
                    fingerprint: fingerprint.clone(),
                    is_vpn: true,
                    label: path.label.clone(),
                    ssid: String::new(),
                    trusted: false,
                    declined: standing(path, &known) == Standing::Declined,
                    blocked_devices: devices.iter().copied().collect(),
                });
            }
        }
        paths
    }

    /// Uses a network or tunnel from [`crate::Node::network_paths`] from now on (`trusted`), or
    /// never ("Not here").
    pub fn decide_network(&self, fingerprint: &str, trusted: bool) -> Result<()> {
        let path = self
            .network_paths()
            .into_iter()
            .find(|p| p.fingerprint == fingerprint)
            .ok_or_else(|| CoreError::InvalidInput("unknown network".into()))?;
        let known = self.inner.known_networks_by_fingerprint();
        let existing = known.get(fingerprint);
        let now = crate::now_ms();
        // The same decision on another Wi‑Fi name of this network adds the name; the opposite
        // decision replaces the names, it is about the network the user is on now.
        let ssid = match existing {
            Some(r) if r.trusted == trusted => with_name(r, Some(&path.ssid)),
            _ => path.ssid,
        };
        self.inner.remember_network(&KnownNetwork {
            fingerprint: fingerprint.to_string(),
            kind: if path.is_vpn { "vpn" } else { "lan" }.into(),
            label: path.label,
            added_ms: existing.map_or(now, |r| r.added_ms),
            last_used_ms: now,
            ssid,
            trusted,
        })?;
        self.inner.paths.lock().unwrap().blocked.remove(fingerprint);
        self.inner.network_rules_changed();
        Ok(())
    }

    /// Allows a tunnel until Brêge quits, without remembering it.
    pub fn allow_network_once(&self, fingerprint: &str) {
        {
            let mut state = self.inner.paths.lock().unwrap();
            state.allowed_once.insert(fingerprint.to_string());
            state.blocked.remove(fingerprint);
        }
        self.inner.network_rules_changed();
    }

    pub fn known_networks(&self) -> Result<Vec<KnownNetwork>> {
        Ok(self.inner.store.lock().unwrap().known_networks()?)
    }

    pub fn forget_network(&self, fingerprint: &str) -> Result<()> {
        let result = self.inner.store.lock().unwrap().forget_network(fingerprint);
        *self.inner.known_networks.lock().unwrap() = None;
        result?;
        self.inner.network_rules_changed();
        Ok(())
    }

    /// Mac side: the interfaces to announce Bonjour on: trusted networks, or all while a hotspot
    /// request runs or pairing is open.
    pub fn announce_interfaces(&self) -> Vec<String> {
        let known = self.inner.known_networks_by_fingerprint();
        let state = self.inner.paths.lock().unwrap();
        let unrestricted = state.interfaces.is_none();
        state
            .interfaces
            .iter()
            .flatten()
            .filter(|i| is_lan(i.kind))
            .filter(|i| {
                unrestricted
                    || i.addresses
                        .iter()
                        .filter(|(a, _)| a.is_ipv4())
                        .filter_map(|&(a, p)| lan_path(i, a, p, false))
                        .any(|path| self.inner.is_trusted(&path, &state, &known))
            })
            .map(|i| i.name.clone())
            .collect()
    }
}

fn is_lan(kind: InterfaceKind) -> bool {
    matches!(
        kind,
        InterfaceKind::Wifi | InterfaceKind::Ethernet | InterfaceKind::Other
    )
}

/// The path the operating system would use to reach `remote`. Asks the routing table by
/// connecting an unbound UDP socket, which sends nothing.
pub(crate) fn path_to(interfaces: &[NetInterface], remote: IpAddr) -> Option<Path> {
    let remote = remote.to_canonical();
    if remote.is_loopback() {
        return Some(Path {
            interface: "lo".into(),
            kind: InterfaceKind::Loopback,
            fingerprint: String::new(),
            label: String::new(),
            ssid: None,
            has_router_hw: false,
            on_link: true,
            router: None,
        });
    }
    let local = local_address_towards(remote)?;
    let interface = interfaces
        .iter()
        .find(|i| i.addresses.iter().any(|(a, _)| *a == local))?;
    let prefix = interface.addresses.iter().find(|(a, _)| *a == local)?.1;
    let on_link = same_subnet(local, remote, prefix);
    match interface.kind {
        InterfaceKind::Vpn => Some(Path {
            interface: interface.name.clone(),
            kind: InterfaceKind::Vpn,
            fingerprint: format!("vpn:{local}"),
            label: format!("VPN {local} ({})", interface.name),
            ssid: None,
            has_router_hw: false,
            on_link,
            router: None,
        }),
        kind if is_lan(kind) => {
            // The network is identified by its IPv4 subnet and router, whichever address family
            // this path uses, so IPv6 on a known network is not a different network.
            let (address, identity_prefix) = interface
                .addresses
                .iter()
                .find(|(a, _)| a.is_ipv4())
                .copied()
                .unwrap_or((local, prefix));
            lan_path(interface, address, identity_prefix, on_link)
        }
        kind => Some(Path {
            interface: interface.name.clone(),
            kind,
            fingerprint: String::new(),
            label: String::new(),
            ssid: None,
            has_router_hw: false,
            on_link,
            router: None,
        }),
    }
}

fn lan_path(interface: &NetInterface, address: IpAddr, prefix: u8, on_link: bool) -> Option<Path> {
    let network = masked(address, prefix);
    // The IPv4 router only: an IPv6 router is usually link-local and may be reported or not.
    let router = interface.gateway.filter(IpAddr::is_ipv4);
    let gateway = router.map(|g| g.to_string()).unwrap_or_default();
    let hardware = interface
        .gateway_hw
        .clone()
        .unwrap_or_default()
        .to_lowercase();
    let ssid = interface.ssid.clone().filter(|s| !s.is_empty());
    let label = match (&ssid, interface.kind) {
        (Some(name), _) => format!("Wi‑Fi “{name}”"),
        (None, InterfaceKind::Wifi) => format!("Wi‑Fi {network}/{prefix}"),
        (None, InterfaceKind::Ethernet) => format!("Ethernet {network}/{prefix}"),
        (None, _) => format!("Network {network}/{prefix}"),
    };
    Some(Path {
        interface: interface.name.clone(),
        kind: interface.kind,
        fingerprint: format!("lan:{network}/{prefix}|{gateway}|{hardware}"),
        label,
        has_router_hw: !hardware.is_empty(),
        ssid,
        on_link,
        router,
    })
}

pub(crate) fn local_address_towards(remote: IpAddr) -> Option<IpAddr> {
    let unspecified: IpAddr = if remote.is_ipv4() {
        Ipv4Addr::UNSPECIFIED.into()
    } else {
        Ipv6Addr::UNSPECIFIED.into()
    };
    let socket = UdpSocket::bind(SocketAddr::new(unspecified, 0)).ok()?;
    socket.connect(SocketAddr::new(remote, 9)).ok()?;
    Some(socket.local_addr().ok()?.ip())
}

fn masked(address: IpAddr, prefix: u8) -> IpAddr {
    match address {
        IpAddr::V4(a) => {
            let bits = u32::from(a)
                & u32::MAX
                    .checked_shl(32 - u32::from(prefix.min(32)))
                    .unwrap_or(0);
            IpAddr::V4(bits.into())
        }
        IpAddr::V6(a) => {
            let bits = u128::from(a)
                & u128::MAX
                    .checked_shl(128 - u32::from(prefix.min(128)))
                    .unwrap_or(0);
            IpAddr::V6(bits.into())
        }
    }
}

fn same_subnet(a: IpAddr, b: IpAddr, prefix: u8) -> bool {
    a.is_ipv4() == b.is_ipv4() && masked(a, prefix) == masked(b, prefix)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wifi(address: &str, gateway: &str, hw: Option<&str>, ssid: Option<&str>) -> NetInterface {
        NetInterface {
            name: "wlan0".into(),
            kind: InterfaceKind::Wifi,
            addresses: vec![(address.parse().unwrap(), 24)],
            gateway: Some(gateway.parse().unwrap()),
            gateway_hw: hw.map(Into::into),
            ssid: ssid.map(Into::into),
        }
    }

    fn path(interface: &NetInterface) -> Path {
        lan_path(interface, interface.addresses[0].0, 24, true).unwrap()
    }

    fn record(path: &Path, ssid: &str, trusted: bool) -> HashMap<String, KnownNetwork> {
        HashMap::from([(
            path.fingerprint.clone(),
            KnownNetwork {
                fingerprint: path.fingerprint.clone(),
                kind: "lan".into(),
                label: path.label.clone(),
                added_ms: 0,
                last_used_ms: 0,
                ssid: ssid.into(),
                trusted,
            },
        )])
    }

    #[test]
    fn subnets() {
        let a: IpAddr = "192.168.50.41".parse().unwrap();
        assert_eq!(masked(a, 24), "192.168.50.0".parse::<IpAddr>().unwrap());
        assert!(same_subnet(a, "192.168.50.196".parse().unwrap(), 24));
        assert!(!same_subnet(a, "192.168.3.1".parse().unwrap(), 24));
        assert_eq!(masked(a, 0), "0.0.0.0".parse::<IpAddr>().unwrap());
        assert!(same_subnet(
            "fd00::1".parse().unwrap(),
            "fd00::abcd".parse().unwrap(),
            64
        ));
    }

    #[test]
    fn fingerprints_and_labels() {
        let home = wifi(
            "192.168.50.41",
            "192.168.50.1",
            Some("AA:BB:CC:DD:EE:FF"),
            Some("Thuis"),
        );
        let p = path(&home);
        assert_eq!(
            p.fingerprint,
            "lan:192.168.50.0/24|192.168.50.1|aa:bb:cc:dd:ee:ff"
        );
        assert_eq!(p.label, "Wi‑Fi “Thuis”");
        let unnamed = wifi("192.168.50.41", "192.168.50.1", None, None);
        assert_eq!(path(&unnamed).label, "Wi‑Fi 192.168.50.0/24");
    }

    #[test]
    fn look_alike_networks() {
        // The phone: no router hardware address.
        let home = path(&wifi("192.168.1.20", "192.168.1.1", None, Some("Thuis")));
        let known = record(&home, "Thuis", true);
        assert_eq!(standing(&home, &known), Standing::Verified);
        // Same addresses, other Wi‑Fi name: a different network.
        let cafe = path(&wifi("192.168.1.77", "192.168.1.1", None, Some("Café")));
        assert_eq!(standing(&cafe, &known), Standing::Unknown);
        // No Wi‑Fi name available: allowed, but not certain.
        let unnamed = path(&wifi("192.168.1.77", "192.168.1.1", None, None));
        assert_eq!(standing(&unnamed, &known), Standing::Unverified);
        // The Mac: the router's hardware address makes it certain.
        let mac = path(&wifi(
            "192.168.1.20",
            "192.168.1.1",
            Some("aa:bb:cc:dd:ee:ff"),
            None,
        ));
        assert_eq!(standing(&mac, &record(&mac, "", true)), Standing::Verified);
        assert_eq!(standing(&mac, &record(&mac, "", false)), Standing::Declined);
        assert_eq!(standing(&mac, &HashMap::new()), Standing::Unknown);
    }

    #[test]
    fn several_wifi_names() {
        let home = path(&wifi("192.168.1.20", "192.168.1.1", None, Some("Thuis")));
        let mut known = record(&home, "Thuis", true);
        let r = known.get_mut(&home.fingerprint).unwrap();
        r.ssid = with_name(r, Some("Thuis 5G"));
        assert_eq!(r.ssid, "Thuis\u{1f}Thuis 5G");
        assert_eq!(with_name(r, Some("Thuis")), r.ssid, "no duplicates");
        let band = path(&wifi("192.168.1.20", "192.168.1.1", None, Some("Thuis 5G")));
        assert_eq!(standing(&home, &known), Standing::Verified);
        assert_eq!(standing(&band, &known), Standing::Verified);
        let cafe = path(&wifi("192.168.1.77", "192.168.1.1", None, Some("Café")));
        assert_eq!(standing(&cafe, &known), Standing::Unknown);
        // "Not here" holds for the named network only.
        let declined = record(&cafe, "Café", false);
        assert_eq!(standing(&cafe, &declined), Standing::Declined);
        assert_eq!(standing(&home, &declined), Standing::Unknown);
        assert_ne!(network_key(&home), network_key(&cafe));
    }

    #[test]
    fn only_an_ipv4_router_identifies_a_network() {
        let mut interface = wifi("192.168.1.20", "192.168.1.1", None, None);
        let v4 = path(&interface);
        interface.gateway = Some("fe80::1".parse().unwrap());
        let v6 = path(&interface);
        interface.gateway = None;
        assert_eq!(v6.fingerprint, path(&interface).fingerprint);
        assert_eq!(v6.router, None);
        assert_eq!(v4.router, Some("192.168.1.1".parse().unwrap()));
    }

    #[test]
    fn loopback_is_local() {
        let path = path_to(&[], "127.0.0.1".parse().unwrap()).unwrap();
        assert_eq!(path.kind, InterfaceKind::Loopback);
    }
}

/// The rules on a running node. Paths come from the routing table, so these tests need an IPv4
/// route on this machine and are skipped without one. They send nothing.
#[cfg(test)]
mod node_tests {
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use std::sync::Arc;

    use brege_identity::{PresenceKey, SecretKey};
    use brege_store::DeviceRecord;
    use brege_transport::SourceFilter;

    use super::*;
    use crate::{Event, EventSink, Node, NodeConfig, proto};

    struct Quiet;
    impl EventSink for Quiet {
        fn on_event(&self, _event: Event) {}
    }

    /// This machine's IPv4 address towards other networks.
    fn local_ip() -> Option<Ipv4Addr> {
        match local_address_towards("192.0.2.1".parse().unwrap())? {
            IpAddr::V4(ip) if !ip.is_loopback() => Some(ip),
            _ => None,
        }
    }

    macro_rules! local_ip_or_skip {
        () => {
            match local_ip() {
                Some(ip) => ip,
                None => return eprintln!("skipped: no IPv4 route"),
            }
        };
    }

    async fn node(restrict: bool) -> (Node, DeviceId) {
        let config = NodeConfig {
            name: "Mac".into(),
            platform: proto::Platform::Macos,
            app_version: "test".into(),
            identity_seed: SecretKey::generate().unwrap().to_seed(),
            db_path: None,
            db_key: [1; 32],
            listen_addr: "127.0.0.1:0".parse().unwrap(),
            download_dir: std::env::temp_dir(),
            auto_accept_pairing: false,
            restrict_network_until_reported: restrict,
        };
        let node = Node::start(config, Arc::new(Quiet)).await.unwrap();
        let phone = SecretKey::generate().unwrap().device_id();
        node.inner
            .store
            .lock()
            .unwrap()
            .upsert_device(&DeviceRecord {
                id: phone,
                name: "Phone".into(),
                platform: proto::Platform::Android as i32,
                presence_key: PresenceKey::generate().unwrap(),
                paired_at_ms: 0,
                last_seen_ms: None,
                last_addr: None,
            })
            .unwrap();
        node.inner.trust.add(phone);
        (node, phone)
    }

    /// `ip`'s /24 Wi‑Fi network with router `.1`.
    fn wifi(ip: Ipv4Addr, hw: Option<&str>, ssid: Option<&str>) -> NetInterface {
        let [a, b, c, _] = ip.octets();
        NetInterface {
            name: "en0".into(),
            kind: InterfaceKind::Wifi,
            addresses: vec![(ip.into(), 24)],
            gateway: Some(Ipv4Addr::new(a, b, c, 1).into()),
            gateway_hw: hw.map(Into::into),
            ssid: ssid.map(Into::into),
        }
    }

    /// Another address in `ip`'s /24.
    fn neighbour(ip: Ipv4Addr) -> SocketAddr {
        let [a, b, c, d] = ip.octets();
        SocketAddr::new(
            Ipv4Addr::new(a, b, c, if d == 77 { 78 } else { 77 }).into(),
            47400,
        )
    }

    fn fingerprint(node: &Node) -> String {
        node.network_paths()[0].fingerprint.clone()
    }

    #[tokio::test]
    async fn announcements_only_count_on_their_network() {
        let ip = local_ip_or_skip!();
        let (node, phone) = node(false).await;
        let addr = neighbour(ip);
        let inner = &node.inner;
        node.set_network_interfaces(vec![wifi(ip, None, Some("Thuis"))]);
        node.decide_network(&fingerprint(&node), true).unwrap();
        let home = inner.network_key_towards(addr).unwrap();
        inner.candidates.lock().unwrap().insert(
            phone,
            vec![Candidate {
                addr,
                network: Some(home.clone()),
            }],
        );
        assert!(inner.may_dial(phone, addr, Some(&home)));

        // A look-alike network: same subnet and router, other name.
        node.set_network_interfaces(vec![wifi(ip, None, Some("Café"))]);
        assert!(!inner.may_dial(phone, addr, Some(&home)));
        assert!(
            inner.candidates.lock().unwrap().is_empty(),
            "stale candidate kept"
        );

        // Announced before the first report: tagged with the network then.
        let (node, phone) = self::node(false).await;
        node.inner.candidates.lock().unwrap().insert(
            phone,
            vec![Candidate {
                addr,
                network: None,
            }],
        );
        node.set_network_interfaces(vec![wifi(ip, None, Some("Thuis"))]);
        let tagged = node.inner.candidates.lock().unwrap()[&phone][0]
            .network
            .clone();
        assert_eq!(tagged, node.inner.network_key_towards(addr));
    }

    #[tokio::test]
    async fn several_names_per_network() {
        let ip = local_ip_or_skip!();
        let (node, _) = node(false).await;
        node.set_network_interfaces(vec![wifi(ip, None, Some("Thuis"))]);
        node.decide_network(&fingerprint(&node), true).unwrap();
        node.set_network_interfaces(vec![wifi(ip, None, Some("Thuis 5G"))]);
        assert!(!node.network_paths()[0].trusted);
        node.decide_network(&fingerprint(&node), true).unwrap();
        assert!(node.network_paths()[0].trusted);
        node.set_network_interfaces(vec![wifi(ip, None, Some("Thuis"))]);
        assert!(node.network_paths()[0].trusted);
        let known = node.known_networks().unwrap();
        assert_eq!(known.len(), 1);
        assert_eq!(known[0].ssid, "Thuis\u{1f}Thuis 5G");
    }

    #[tokio::test]
    async fn restricted_until_reported() {
        let ip = local_ip_or_skip!();
        let (node, phone) = node(true).await;
        let inner = &node.inner;
        let remote = neighbour(ip);
        let loopback: SocketAddr = "127.0.0.1:47400".parse().unwrap();
        assert!(!inner.may_dial(phone, remote, None));
        assert!(!inner.may_answer(remote));
        assert!(!inner.allow(remote));
        assert!(inner.may_dial(phone, loopback, None));
        assert!(inner.allow(loopback));
        assert!(node.announce_interfaces().is_empty());

        node.set_network_interfaces(vec![wifi(ip, Some("aa:bb:cc:dd:ee:ff"), None)]);
        assert!(!inner.may_answer(remote));
        node.decide_network(&fingerprint(&node), true).unwrap();
        assert!(inner.may_answer(remote));
        assert!(inner.allow(remote));
        assert_eq!(node.announce_interfaces(), vec!["en0".to_string()]);

        // Unrestricted nodes use everything before the report.
        let (node, phone) = self::node(false).await;
        assert!(node.inner.may_dial(phone, remote, None));
        assert!(node.inner.may_answer(remote));
    }

    #[tokio::test]
    async fn held_addresses_pass_the_filter() {
        let ip = local_ip_or_skip!();
        let (node, _) = node(false).await;
        let remote = neighbour(ip);
        node.set_network_interfaces(vec![wifi(ip, None, None)]);
        assert!(!node.inner.allow(remote));
        let hold = node.inner.hold_address(remote);
        let second = node.inner.hold_address(remote);
        assert!(node.inner.allow(remote));
        drop(hold);
        assert!(node.inner.allow(remote));
        drop(second);
        assert!(!node.inner.allow(remote));
    }

    #[tokio::test]
    async fn off_link_only_on_a_verified_network() {
        let ip = local_ip_or_skip!();
        let (node, phone) = node(false).await;
        // Beyond the /24, routed through the same interface.
        let routed = SocketAddr::new("198.51.100.20".parse().unwrap(), 47400);
        if local_address_towards(routed.ip()) != Some(ip.into()) {
            return eprintln!("skipped: no default route through {ip}");
        }
        node.set_network_interfaces(vec![wifi(ip, None, None)]);
        node.decide_network(&fingerprint(&node), true).unwrap();
        assert!(
            !node.inner.may_dial(phone, routed, None),
            "unverified network"
        );
        node.set_network_interfaces(vec![wifi(ip, Some("aa:bb:cc:dd:ee:ff"), None)]);
        assert!(!node.inner.may_dial(phone, routed, None), "unknown network");
        node.decide_network(&fingerprint(&node), true).unwrap();
        assert!(node.inner.may_dial(phone, routed, None), "verified network");
        node.decide_network(&fingerprint(&node), false).unwrap();
        assert!(
            !node.inner.may_dial(phone, routed, None),
            "declined network"
        );
    }

    #[tokio::test]
    async fn hotspot_request() {
        let ip = local_ip_or_skip!();
        let (node, phone) = node(false).await;
        let other = SecretKey::generate().unwrap().device_id();
        let inner = &node.inner;
        let [a, b, c, _] = ip.octets();
        let router = SocketAddr::new(Ipv4Addr::new(a, b, c, 1).into(), crate::DEFAULT_PORT);
        let remote = neighbour(ip);
        node.set_network_interfaces(vec![wifi(ip, None, Some("Pixel"))]);
        assert!(!inner.may_dial(phone, remote, None));
        assert!(inner.hotspot_addresses(phone).is_empty());

        node.set_hotspot_pending(phone, Some("Other".into()), true);
        assert!(!inner.may_dial(phone, remote, None), "another Wi‑Fi name");
        assert!(!inner.may_answer(remote));
        node.set_hotspot_pending(phone, Some("Pixel".into()), true);
        assert!(inner.may_dial(phone, remote, None));
        assert!(!inner.may_dial(other, remote, None), "another device");
        assert!(inner.may_answer(remote));
        assert_eq!(inner.hotspot_addresses(phone), vec![router]);

        // Remembered only when the phone is the network's router, or the name matches.
        node.set_network_interfaces(vec![wifi(ip, None, None)]);
        node.set_hotspot_pending(phone, None, true);
        inner.connected_over(remote, phone, false);
        assert!(node.known_networks().unwrap().is_empty());
        inner.connected_over(router, other, false);
        assert!(node.known_networks().unwrap().is_empty());
        inner.connected_over(router, phone, false);
        assert_eq!(node.known_networks().unwrap().len(), 1);

        // Ethernet is never the hotspot.
        let (node, phone) = self::node(false).await;
        let mut ethernet = wifi(ip, None, None);
        ethernet.kind = InterfaceKind::Ethernet;
        node.set_network_interfaces(vec![ethernet]);
        node.set_hotspot_pending(phone, None, true);
        assert!(!node.inner.may_answer(remote));
        assert!(node.inner.hotspot_addresses(phone).is_empty());
    }

    #[tokio::test]
    async fn remembering_on_connections() {
        let ip = local_ip_or_skip!();
        let (node, phone) = node(false).await;
        let inner = &node.inner;
        let remote = neighbour(ip);

        // Pairing on a declined network is a decision to use it.
        node.set_network_interfaces(vec![wifi(ip, None, Some("Thuis"))]);
        node.decide_network(&fingerprint(&node), false).unwrap();
        inner.connected_over(remote, phone, true);
        let known = node.known_networks().unwrap();
        assert!(known[0].trusted);
        assert_eq!(known[0].ssid, "Thuis");

        // A name read later is only adopted where the router's hardware address proves the network.
        let (node, phone) = self::node(false).await;
        let inner = &node.inner;
        node.set_network_interfaces(vec![wifi(ip, None, None)]);
        node.decide_network(&fingerprint(&node), true).unwrap();
        node.set_network_interfaces(vec![wifi(ip, None, Some("Café"))]);
        inner.connected_over(remote, phone, false);
        assert_eq!(node.known_networks().unwrap()[0].ssid, "");

        let (node, phone) = self::node(false).await;
        let inner = &node.inner;
        let hw = Some("aa:bb:cc:dd:ee:ff");
        node.set_network_interfaces(vec![wifi(ip, hw, None)]);
        node.decide_network(&fingerprint(&node), true).unwrap();
        node.set_network_interfaces(vec![wifi(ip, hw, Some("Thuis"))]);
        inner.connected_over(remote, phone, false);
        assert_eq!(node.known_networks().unwrap()[0].ssid, "Thuis");
    }
}
