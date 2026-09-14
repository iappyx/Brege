use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use brege_features::clipboard::{Clip, ClipboardSync, Outgoing};
use brege_features::notifications::IconTracker;
use brege_identity::{DeviceId, SecretKey};
use brege_proto::v1::{self as proto, envelope::Payload};
use brege_store::{NotificationRecord, Store};
use brege_transport::{Endpoint, EndpointOptions};
use tokio::sync::{Notify, oneshot};
use tokio_util::sync::CancellationToken;

use crate::pairing::PendingInvite;
use crate::session::SessionHandle;
use crate::trust::PeerTrust;
use crate::{
    CoreError, EventSink, Result, audio, dialer, files, messaging, pairing, session, transfers,
};

#[derive(Debug, Clone)]
pub struct NodeConfig {
    pub name: String,
    pub platform: proto::Platform,
    pub app_version: String,
    /// Ed25519 seed from Keychain / Keystore-wrapped storage.
    pub identity_seed: [u8; 32],
    /// `None` keeps the database in memory (tests).
    pub db_path: Option<PathBuf>,
    pub db_key: [u8; 32],
    pub listen_addr: SocketAddr,
    pub download_dir: PathBuf,
    /// Skips the user confirmation of incoming pairing requests (tests and simulations only).
    pub auto_accept_pairing: bool,
    /// Uses no network path but loopback until [`Node::set_network_interfaces`] is first called.
    /// Apps set this; without it nothing is restricted before the first report.
    pub restrict_network_until_reported: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceInfo {
    pub id: DeviceId,
    pub name: String,
    pub platform: proto::Platform,
    pub connected: bool,
    pub last_seen_ms: Option<i64>,
}

pub(crate) struct Inner {
    pub config: NodeConfig,
    pub id: DeviceId,
    pub endpoint: Endpoint,
    pub store: Mutex<Store>,
    pub trust: Arc<PeerTrust>,
    pub events: Arc<dyn EventSink>,
    pub sessions: Mutex<HashMap<DeviceId, SessionHandle>>,
    pub next_session_id: AtomicU64,
    pub clipboard: Mutex<ClipboardSync>,
    pub icons: Mutex<HashMap<DeviceId, IconTracker>>,
    pub invite: Mutex<Option<PendingInvite>>,
    pub pair_decisions: Mutex<HashMap<u64, oneshot::Sender<bool>>>,
    pub next_request_id: AtomicU64,
    pub pending_accepts: Mutex<HashMap<String, oneshot::Sender<proto::TransferAccept>>>,
    pub(crate) candidates: Mutex<HashMap<DeviceId, Vec<crate::paths::Candidate>>>,
    pub dial_state: Mutex<HashMap<DeviceId, dialer::Backoff>>,
    pub dial_now: Notify,
    /// Which networks and tunnels may be used (network privacy plan).
    pub(crate) paths: Mutex<crate::paths::PathState>,
    /// Cache of the known networks by fingerprint; `None` after a change.
    pub(crate) known_networks: Mutex<Option<Arc<HashMap<String, brege_store::KnownNetwork>>>>,
    /// Peer addresses of connections that are not sessions yet (see [`crate::paths::AddressHold`]).
    pub(crate) held_addresses: Mutex<HashMap<IpAddr, usize>>,
    pub cancel: CancellationToken,
    /// Phone side: shared folders served to the Mac.
    pub fs_backend: std::sync::RwLock<Option<Arc<dyn crate::FsBackend>>>,
    /// Mac side: receives microphone audio.
    pub audio_sink: std::sync::RwLock<Option<Arc<dyn crate::AudioSink>>>,
    pub video_sink: std::sync::RwLock<Option<Arc<dyn crate::VideoSink>>>,
    pub(crate) video: crate::video::VideoSender,
}

impl Inner {
    pub fn emit(&self, event: crate::Event) {
        self.events.on_event(event);
    }

    pub fn is_connected(&self, id: &DeviceId) -> bool {
        self.sessions
            .lock()
            .unwrap()
            .get(id)
            .is_some_and(|s| !s.conn.is_closed())
    }

    /// Queues a control message for one peer.
    pub fn send_to(&self, peer: &DeviceId, payload: Payload) -> Result<()> {
        let tx = self
            .sessions
            .lock()
            .unwrap()
            .get(peer)
            .map(|s| s.tx.clone())
            .ok_or(CoreError::NotConnected)?;
        tx.try_send(payload).map_err(|_| CoreError::NotConnected)
    }

    /// Queues a control message for every connected peer. Returns how many received it.
    pub fn broadcast(&self, payload: Payload) -> usize {
        let txs: Vec<_> = self
            .sessions
            .lock()
            .unwrap()
            .values()
            .map(|s| s.tx.clone())
            .collect();
        txs.iter()
            .filter(|tx| tx.try_send(payload.clone()).is_ok())
            .count()
    }

    /// Like [`Inner::broadcast`], but waits for queue space so large syncs are never dropped.
    pub async fn broadcast_reliable(&self, payload: Payload) -> usize {
        let txs: Vec<_> = self
            .sessions
            .lock()
            .unwrap()
            .values()
            .map(|s| s.tx.clone())
            .collect();
        let mut sent = 0;
        for tx in txs {
            let send = tx.send(payload.clone());
            if let Ok(Ok(())) = tokio::time::timeout(std::time::Duration::from_secs(30), send).await
            {
                sent += 1;
            }
        }
        sent
    }

    pub fn device_info(&self, record: &brege_store::DeviceRecord) -> DeviceInfo {
        DeviceInfo {
            id: record.id,
            name: record.name.clone(),
            platform: proto::Platform::try_from(record.platform).unwrap_or_default(),
            connected: self.is_connected(&record.id),
            last_seen_ms: record.last_seen_ms,
        }
    }
}

/// A running Brêge core. Cheap to clone.
#[derive(Clone)]
pub struct Node {
    pub(crate) inner: Arc<Inner>,
}

impl Node {
    /// Opens the database, binds the endpoint and starts accepting and dialling peers.
    /// Must be called inside a Tokio runtime.
    pub async fn start(config: NodeConfig, events: Arc<dyn EventSink>) -> Result<Self> {
        let key = SecretKey::from_seed(config.identity_seed)?;
        let id = key.device_id();
        let store = match &config.db_path {
            Some(path) => Store::open(path, &config.db_key)?,
            None => Store::open_in_memory(&config.db_key)?,
        };
        let trust = Arc::new(PeerTrust::default());
        trust.replace_all(store.devices()?.into_iter().map(|d| d.id));
        let endpoint = Endpoint::bind(
            config.listen_addr,
            key,
            trust.clone(),
            EndpointOptions::default(),
        )?;
        let pruned = store.prune_notifications(crate::now_ms())?;
        tracing::debug!(pruned, "pruned old notifications");

        let inner = Arc::new(Inner {
            config,
            id,
            endpoint,
            store: Mutex::new(store),
            trust,
            events,
            sessions: Mutex::default(),
            next_session_id: AtomicU64::new(1),
            clipboard: Mutex::default(),
            icons: Mutex::default(),
            invite: Mutex::new(None),
            pair_decisions: Mutex::default(),
            next_request_id: AtomicU64::new(1),
            pending_accepts: Mutex::default(),
            candidates: Mutex::default(),
            dial_state: Mutex::default(),
            dial_now: Notify::new(),
            paths: Mutex::default(),
            known_networks: Mutex::default(),
            held_addresses: Mutex::default(),
            cancel: CancellationToken::new(),
            fs_backend: std::sync::RwLock::new(None),
            audio_sink: std::sync::RwLock::new(None),
            video_sink: std::sync::RwLock::new(None),
            video: Default::default(),
        });

        let filter: std::sync::Weak<dyn brege_transport::SourceFilter> =
            Arc::downgrade(&inner) as _;
        inner.endpoint.set_source_filter(filter);
        tokio::spawn(session::accept_loop(inner.clone()));
        tokio::spawn(dialer::run(inner.clone()));
        tokio::spawn(prune_notifications(inner.clone()));
        Ok(Self { inner })
    }

    pub fn device_id(&self) -> DeviceId {
        self.inner.id
    }

    pub fn local_addr(&self) -> Result<SocketAddr> {
        Ok(self.inner.endpoint.local_addr()?)
    }

    // --- pairing ----------------------------------------------------------------------------

    /// Creates a QR-code URI and opens the pairing window for five minutes.
    /// `addrs` are this device's LAN addresses as reported by the shell.
    pub fn create_pairing_invite(&self, addrs: Vec<SocketAddr>) -> Result<String> {
        pairing::create_invite(&self.inner, addrs)
    }

    pub fn cancel_pairing(&self) {
        pairing::close_window(&self.inner);
    }

    /// Answers an [`crate::Event::PairingRequested`].
    pub fn respond_to_pairing(&self, request_id: u64, accept: bool) {
        if let Some(tx) = self
            .inner
            .pair_decisions
            .lock()
            .unwrap()
            .remove(&request_id)
        {
            let _ = tx.send(accept);
        }
    }

    /// Pairs with the device that showed `uri` (phone side).
    pub async fn pair_with_invite(&self, uri: &str) -> Result<DeviceInfo> {
        pairing::pair_with_invite(&self.inner, uri).await
    }

    pub fn devices(&self) -> Result<Vec<DeviceInfo>> {
        let records = self.inner.store.lock().unwrap().devices()?;
        Ok(records.iter().map(|r| self.inner.device_info(r)).collect())
    }

    /// Unpairs locally and tells the peer if it is connected.
    pub async fn forget_device(&self, id: DeviceId) -> Result<()> {
        let _ = self.inner.send_to(&id, Payload::Unpair(proto::Unpair {}));
        // Give the writer a moment to flush the Unpair before the connection closes.
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
        session::forget_locally(&self.inner, &id);
        Ok(())
    }

    // --- discovery and connectivity --------------------------------------------------------

    /// The peer's current address while it is connected, e.g. to find its wireless-debugging
    /// service for screen streaming.
    pub fn peer_address(&self, id: &DeviceId) -> Option<std::net::SocketAddr> {
        self.inner
            .sessions
            .lock()
            .unwrap()
            .get(id)
            .filter(|s| !s.conn.is_closed())
            .map(|s| s.conn.remote_addr())
    }

    /// Mac side: the keyed ids for its Bonjour TXT record, one per paired phone, for the current
    /// 15-minute slot (network privacy plan, step 2).
    pub fn bonjour_tokens(&self) -> Vec<String> {
        let now = unix_secs();
        self.inner
            .store
            .lock()
            .unwrap()
            .devices()
            .unwrap_or_default()
            .iter()
            .map(|d| brege_identity::bonjour_token(&d.presence_key, now))
            .collect()
    }

    /// Reports a Bonjour / NSD result: `tokens` are the TXT record's keyed ids (comma-separated).
    /// Only a paired device's current id matches, so a stranger's record is ignored.
    pub fn address_discovered(&self, tokens: &str, addr: SocketAddr) {
        let devices = match self.inner.store.lock().unwrap().devices() {
            Ok(d) => d,
            Err(_) => return,
        };
        let now = unix_secs();
        let tokens: Vec<&str> = tokens.split(',').map(str::trim).take(32).collect();
        let Some(device) = devices.iter().find(|d| {
            tokens
                .iter()
                .any(|t| brege_identity::bonjour_token_matches(&d.presence_key, t, now))
        }) else {
            return;
        };
        let network = self.inner.network_key_towards(addr);
        let mut candidates = self.inner.candidates.lock().unwrap();
        let list = candidates.entry(device.id).or_default();
        if let Some(known) = list.iter_mut().find(|c| c.addr == addr) {
            // Records repeat. A known address still means the peer is back (e.g. its app
            // restarted), so reconnect at once, but only while it is not connected.
            known.network = network;
            drop(candidates);
            if self.inner.is_connected(&device.id) {
                return;
            }
        } else {
            list.insert(
                0,
                crate::paths::Candidate {
                    addr,
                    network: network.clone(),
                },
            );
            list.truncate(4);
            drop(candidates);
            self.close_if_moved(device.id, addr, network.as_deref());
        }
        dialer::reset_backoff(&self.inner, Some(&device.id));
        self.inner.dial_now.notify_one();
    }

    /// A connected peer announced a new IP. If this device dialled the session, the peer is a QUIC
    /// server that cannot move to a new address: the session is dead, so dial the new address.
    fn close_if_moved(&self, peer: DeviceId, addr: SocketAddr, network: Option<&str>) {
        let conn = self
            .inner
            .sessions
            .lock()
            .unwrap()
            .get(&peer)
            .filter(|s| s.dialer == self.inner.id && !s.conn.is_closed())
            .map(|s| s.conn.clone());
        let Some(conn) = conn else { return };
        let remote = conn.remote_addr().ip().to_canonical();
        let ip = addr.ip().to_canonical();
        // Only another IP of the same family, and only where it may be dialled: a peer announces
        // IPv4 and IPv6 addresses side by side.
        if remote == ip
            || remote.is_ipv4() != ip.is_ipv4()
            || !self.inner.may_dial(peer, addr, network)
        {
            return;
        }
        tracing::info!(?peer, %addr, "peer announced a new address; dialling it");
        conn.close(6, b"address changed");
    }

    /// Call on every network change; resets reconnect backoff.
    pub fn network_changed(&self) {
        dialer::reset_backoff(&self.inner, None);
        self.inner.dial_now.notify_one();
    }

    pub fn is_connected(&self, id: &DeviceId) -> bool {
        self.inner.is_connected(id)
    }

    // --- clipboard --------------------------------------------------------------------------

    /// Reports a local clipboard change. Returns true if it was sent to at least one peer.
    pub fn local_clipboard_changed(&self, clip: Clip, change_id: u64) -> bool {
        let decision = self
            .inner
            .clipboard
            .lock()
            .unwrap()
            .on_local_change(&clip, Instant::now());
        if decision != Outgoing::Send {
            tracing::debug!(?decision, "clipboard change not sent");
            return false;
        }
        let sent = self
            .inner
            .broadcast(Payload::Clipboard(clip.to_proto(change_id)))
            > 0;
        if sent {
            self.inner.clipboard.lock().unwrap().sent(&clip);
        }
        sent
    }

    // --- notifications ----------------------------------------------------------------------

    /// Phone side: mirrors a notification to all connected peers.
    pub fn post_notification(
        &self,
        post: proto::NotificationPost,
        icon_png: Option<Vec<u8>>,
    ) -> usize {
        let peers: Vec<DeviceId> = self
            .inner
            .sessions
            .lock()
            .unwrap()
            .keys()
            .copied()
            .collect();
        let mut icons = self.inner.icons.lock().unwrap();
        peers
            .into_iter()
            .filter(|peer| {
                let mut post = post.clone();
                let tracker = icons.entry(*peer).or_default();
                tracker.prepare(&mut post, icon_png.as_deref());
                let new_icon = (!post.icon_png.is_empty()).then(|| post.icon_ref.clone());
                let sent = self
                    .inner
                    .send_to(peer, Payload::Notification(post))
                    .is_ok();
                // Not queued: the peer never got the icon, so include it again next time.
                if !sent && let Some(reference) = new_icon {
                    tracker.forget(&reference);
                }
                sent
            })
            .count()
    }

    pub fn remove_notification(&self, key: &str) {
        self.inner
            .broadcast(Payload::NotificationRemoved(proto::NotificationRemoved {
                key: key.to_string(),
            }));
    }

    /// Mac side: triggers an action, reply or dismissal on the phone.
    pub fn act_on_notification(&self, device: DeviceId, act: proto::NotificationAct) -> Result<()> {
        if matches!(act.act, Some(proto::notification_act::Act::Dismiss(true))) {
            self.inner
                .store
                .lock()
                .unwrap()
                .dismiss_notification(&device, &act.key)?;
        }
        self.inner.send_to(&device, Payload::NotificationAct(act))
    }

    pub fn recent_notifications(&self, limit: u32) -> Result<Vec<NotificationRecord>> {
        Ok(self
            .inner
            .store
            .lock()
            .unwrap()
            .recent_notifications(limit)?)
    }

    // --- status, media, commands, open requests --------------------------------------------

    pub fn send_status(&self, status: proto::StatusUpdate) -> usize {
        self.inner.broadcast(Payload::Status(status))
    }

    pub fn send_media(&self, media: proto::MediaState) -> usize {
        self.inner.broadcast(Payload::Media(media))
    }

    pub fn send_command(&self, device: DeviceId, kind: proto::command::Kind) -> Result<()> {
        self.inner.send_to(
            &device,
            Payload::Command(proto::Command { kind: kind as i32 }),
        )
    }

    // --- phone screen -------------------------------------------------------------------------

    // --- phone hotspot --------------------------------------------------------------------------

    /// Mac side: the BLE service UUID to advertise to ask this phone for its hotspot.
    pub fn hotspot_request_uuid(&self, phone: DeviceId) -> Result<[u8; 16]> {
        let record = self
            .inner
            .store
            .lock()
            .unwrap()
            .device(&phone)?
            .ok_or(CoreError::NotPaired)?;
        Ok(brege_identity::hotspot_request_uuid(
            &record.presence_key,
            unix_secs(),
        ))
    }

    /// Phone side: BLE service UUIDs to advertise while not connected, one per paired Mac that is
    /// not connected, so a Mac can tell the phone is nearby.
    pub fn presence_uuids(&self) -> Vec<[u8; 16]> {
        let now = unix_secs();
        self.inner
            .store
            .lock()
            .unwrap()
            .devices()
            .unwrap_or_default()
            .iter()
            .filter(|d| !self.inner.is_connected(&d.id))
            .map(|d| brege_identity::phone_presence_uuid(&d.presence_key, now))
            .collect()
    }

    /// Mac side: which paired phone, if any, advertised this presence UUID.
    pub fn match_presence(&self, uuid: &[u8; 16]) -> Option<DeviceId> {
        let now = unix_secs();
        self.inner
            .store
            .lock()
            .unwrap()
            .devices()
            .ok()?
            .into_iter()
            .find(|d| brege_identity::phone_presence_matches(&d.presence_key, uuid, now))
            .map(|d| d.id)
    }

    /// Phone side: which paired Mac, if any, advertised this hotspot request UUID.
    pub fn match_hotspot_request(&self, uuid: &[u8; 16]) -> Result<Option<DeviceId>> {
        let now = unix_secs();
        Ok(self
            .inner
            .store
            .lock()
            .unwrap()
            .devices()?
            .into_iter()
            .find(|d| brege_identity::hotspot_request_matches(&d.presence_key, uuid, now))
            .map(|d| d.id))
    }

    // --- recent photos ----------------------------------------------------------------------------

    /// Mac side: asks for the newest photos and screenshots ([`crate::Event::RecentMediaReceived`]).
    pub fn request_recent_media(&self, phone: DeviceId, limit: u32) -> Result<()> {
        self.inner.send_to(
            &phone,
            Payload::RecentMediaRequest(proto::RecentMediaRequest { limit }),
        )
    }

    /// Phone side: answers a request (`to`), or pushes a new screenshot to every Mac (`None`).
    pub fn send_recent_media(
        &self,
        to: Option<DeviceId>,
        items: Vec<proto::MediaItem>,
        new_screenshot: bool,
        permission_needed: bool,
    ) -> Result<usize> {
        let payload = Payload::RecentMedia(proto::RecentMediaList {
            items: crate::apps::sanitize_media(items),
            new_screenshot,
            permission_needed,
        });
        match to {
            Some(to) => self.inner.send_to(&to, payload).map(|()| 1),
            None => Ok(self.inner.broadcast(payload)),
        }
    }

    /// Mac side: asks for the full file of a media item; returns the request id that the
    /// phone's capture result refers to.
    pub fn request_media(&self, phone: DeviceId, media_id: &str) -> Result<String> {
        if !crate::apps::valid_media_id(media_id) {
            return Err(CoreError::InvalidInput("media id".into()));
        }
        let request_id = crate::random_hex(16);
        self.inner.send_to(
            &phone,
            Payload::MediaFetch(proto::MediaFetchRequest {
                request_id: request_id.clone(),
                media_id: media_id.to_string(),
            }),
        )?;
        Ok(request_id)
    }

    // --- ongoing activities --------------------------------------------------------------------

    /// Phone side: publishes or updates an ongoing activity to connected Macs.
    pub fn publish_ongoing_activity(&self, activity: proto::OngoingActivity) -> usize {
        match crate::apps::sanitize_ongoing_activity(activity) {
            Some(activity) => self.inner.broadcast(Payload::OngoingActivity(activity)),
            None => 0,
        }
    }

    pub fn end_ongoing_activity(&self, key: &str) -> usize {
        self.inner
            .broadcast(Payload::OngoingActivityEnded(proto::OngoingActivityEnded {
                key: key.to_string(),
            }))
    }

    // --- import from phone ---------------------------------------------------------------------

    /// Mac side: asks the phone to take a photo or scan a document. Returns the request id that
    /// [`crate::Event::CaptureResultReceived`] refers to.
    pub fn request_capture(
        &self,
        phone: DeviceId,
        kind: proto::capture_request::Kind,
    ) -> Result<String> {
        let request_id = crate::random_hex(16);
        self.inner.send_to(
            &phone,
            Payload::CaptureRequest(proto::CaptureRequest {
                request_id: request_id.clone(),
                kind: kind as i32,
            }),
        )?;
        Ok(request_id)
    }

    /// Phone side: reports the outcome of a capture request.
    pub fn send_capture_result(&self, to: DeviceId, result: proto::CaptureResult) -> Result<()> {
        self.inner.send_to(&to, Payload::CaptureResult(result))
    }

    /// Mac side: asks the phone for its launchable apps ([`crate::Event::AppListReceived`]).
    pub fn request_app_list(&self, phone: DeviceId) -> Result<()> {
        self.inner
            .send_to(&phone, Payload::AppListRequest(proto::AppListRequest {}))
    }

    /// Phone side: answers [`crate::Event::AppListRequested`].
    pub fn send_app_list(&self, to: DeviceId, apps: Vec<proto::PhoneApp>) -> Result<()> {
        let apps = crate::apps::sanitize(apps);
        self.inner
            .send_to(&to, Payload::AppList(proto::AppList { apps }))
    }

    pub fn send_open_request(&self, device: DeviceId, activity: proto::OpenActivity) -> Result<()> {
        self.inner.send_to(&device, Payload::OpenActivity(activity))
    }

    // --- messages, Mac side ------------------------------------------------------------------

    /// Re-requests threads and messages newer than the cache (also done on every connection).
    pub fn request_message_sync(&self, phone: DeviceId) -> Result<()> {
        messaging::request_sync(&self.inner, &phone)
    }

    /// Asks the phone for messages of a thread older than `before_ms`; they arrive as
    /// [`crate::Event::MessagesUpdated`].
    pub fn request_message_history(
        &self,
        phone: DeviceId,
        thread_id: &str,
        before_ms: i64,
        limit: u32,
    ) -> Result<()> {
        self.inner.send_to(
            &phone,
            Payload::SmsHistoryRequest(proto::SmsHistoryRequest {
                thread_id: thread_id.to_string(),
                before_ms,
                limit,
            }),
        )
    }

    /// Asks the phone for contact photos; they arrive as [`crate::Event::ContactPhotosReceived`].
    pub fn request_contact_photos(&self, phone: DeviceId, addresses: Vec<String>) -> Result<()> {
        let addresses = brege_features::messages::sanitize_photo_addresses(addresses);
        if addresses.is_empty() {
            return Ok(());
        }
        self.inner.send_to(
            &phone,
            Payload::ContactPhotoRequest(proto::ContactPhotoRequest { addresses }),
        )
    }

    /// Phone side: answers [`crate::Event::ContactPhotosRequested`].
    pub fn send_contact_photos(
        &self,
        to: DeviceId,
        photos: Vec<proto::ContactPhoto>,
    ) -> Result<()> {
        let photos = photos
            .into_iter()
            .map(|mut p| {
                if p.jpeg.len() > brege_features::messages::MAX_PHOTO_BYTES {
                    p.jpeg.clear();
                }
                p
            })
            .collect();
        self.inner.send_to(
            &to,
            Payload::ContactPhotos(proto::ContactPhotoList { photos }),
        )
    }

    pub fn message_threads(
        &self,
        phone: DeviceId,
        limit: u32,
    ) -> Result<Vec<brege_store::ThreadRecord>> {
        Ok(self.inner.store.lock().unwrap().threads(&phone, limit)?)
    }

    /// Cached messages of a thread, oldest first.
    pub fn thread_messages(
        &self,
        phone: DeviceId,
        thread_id: &str,
        before_ms: i64,
        limit: u32,
    ) -> Result<Vec<brege_store::MessageRecord>> {
        Ok(self
            .inner
            .store
            .lock()
            .unwrap()
            .messages(&phone, thread_id, before_ms, limit)?)
    }

    pub fn mark_thread_read(&self, phone: DeviceId, thread_id: &str) -> Result<()> {
        Ok(self
            .inner
            .store
            .lock()
            .unwrap()
            .set_thread_unread(&phone, thread_id, false)?)
    }

    pub fn sims(&self, phone: DeviceId) -> Result<Vec<brege_store::SimRecord>> {
        Ok(self.inner.store.lock().unwrap().sims(&phone)?)
    }

    /// Sends an SMS (or an RCS reply for `rcs:` threads) through the phone. Returns the client id
    /// that the resulting [`crate::Event::SmsSendStatus`] refers to.
    pub fn send_message(
        &self,
        phone: DeviceId,
        thread_id: &str,
        address: &str,
        body: &str,
        sub_id: i32,
    ) -> Result<String> {
        let send = proto::SmsSend {
            client_id: crate::random_hex(8),
            thread_id: thread_id.to_string(),
            address: address.trim().to_string(),
            body: body.to_string(),
            sub_id,
        };
        brege_features::messages::validate_send(&send)
            .map_err(|e| CoreError::InvalidInput(e.to_string()))?;
        let id = send.client_id.clone();
        self.inner.send_to(&phone, Payload::SmsSend(send))?;
        Ok(id)
    }

    // --- calls, Mac side ---------------------------------------------------------------------

    pub fn call_action(
        &self,
        phone: DeviceId,
        kind: proto::call_action::Kind,
        number: &str,
        sub_id: i32,
    ) -> Result<()> {
        let action = proto::CallAction {
            kind: kind as i32,
            number: number.trim().to_string(),
            sub_id,
        };
        brege_features::messages::validate_call_action(&action)
            .map_err(|e| CoreError::InvalidInput(e.to_string()))?;
        self.inner.send_to(&phone, Payload::CallAction(action))
    }

    // --- messages and calls, phone side -----------------------------------------------------

    pub async fn publish_message_threads(&self, threads: Vec<proto::SmsThread>) -> usize {
        messaging::publish_threads(&self.inner, threads).await
    }

    /// `history` marks an answer to [`crate::Event::SmsHistoryRequested`].
    pub async fn publish_messages(&self, messages: Vec<proto::SmsMessage>, history: bool) -> usize {
        messaging::publish_messages(&self.inner, messages, history).await
    }

    pub fn publish_send_status(&self, to: DeviceId, status: proto::SmsSendStatus) -> Result<()> {
        self.inner.send_to(&to, Payload::SmsSendStatus(status))
    }

    pub fn publish_sims(&self, sims: Vec<proto::Sim>) -> usize {
        self.inner.broadcast(Payload::Sims(proto::SimList { sims }))
    }

    pub fn publish_call_state(&self, call: proto::CallState) -> usize {
        self.inner.broadcast(Payload::CallState(call))
    }

    // --- phone as microphone -----------------------------------------------------------------

    // --- phone camera ---------------------------------------------------------------------------

    /// Mac side: where camera video from phones goes; `None` drops it.
    pub fn set_video_sink(&self, sink: Option<Arc<dyn crate::VideoSink>>) {
        *self.inner.video_sink.write().unwrap() = sink;
    }

    /// Mac side: starts, changes (camera, torch) or stops the phone camera.
    pub fn request_camera(&self, phone: DeviceId, request: proto::CameraRequest) -> Result<()> {
        self.inner.send_to(&phone, Payload::CameraRequest(request))
    }

    /// Phone side: reports the camera state to one Mac (`to`), or to every connected Mac.
    pub fn publish_camera_state(&self, to: Option<DeviceId>, state: proto::CameraState) -> usize {
        self.send_or_broadcast(to, Payload::CameraState(state))
    }

    fn send_or_broadcast(&self, to: Option<DeviceId>, payload: Payload) -> usize {
        match to {
            Some(to) => usize::from(self.inner.send_to(&to, payload).is_ok()),
            None => self.inner.broadcast(payload),
        }
    }

    /// Phone side: opens the video stream to the Mac that asked for the camera.
    pub async fn open_video_stream(&self, mac: DeviceId) -> Result<()> {
        crate::video::VideoSender::open(&self.inner, mac).await
    }

    /// Phone side: sends one encoded packet (blocking briefly for config and key frames).
    pub fn send_video_packet(&self, flags: u8, pts_us: u64, data: Vec<u8>) -> bool {
        self.inner.video.send(flags, pts_us, data)
    }

    pub fn close_video_stream(&self) {
        self.inner.video.close();
    }

    /// Mac side: where microphone audio from phones goes; `None` drops it.
    pub fn set_audio_sink(&self, sink: Option<Arc<dyn crate::AudioSink>>) {
        *self.inner.audio_sink.write().unwrap() = sink;
    }

    /// Phone side: sends one PCM frame (16-bit LE mono) to one Mac (`to`), or to every connected
    /// Mac.
    pub fn send_mic_frame(&self, to: Option<DeviceId>, pcm: &[u8]) -> usize {
        audio::send_mic_frame(&self.inner, to, pcm)
    }

    /// Phone side: the largest PCM frame that fits in one datagram to any connected Mac.
    pub fn max_mic_frame_bytes(&self) -> Option<usize> {
        self.inner
            .sessions
            .lock()
            .unwrap()
            .values()
            .filter_map(|s| audio::max_frame_bytes(&s.conn))
            .min()
    }

    /// Phone side: the microphone state for one Mac (`to`), or for every connected Mac.
    pub fn publish_mic_state(
        &self,
        to: Option<DeviceId>,
        active: bool,
        sample_rate: u32,
        detail: &str,
    ) -> usize {
        self.send_or_broadcast(
            to,
            Payload::MicState(proto::MicState {
                active,
                sample_rate,
                detail: detail.to_string(),
            }),
        )
    }

    // --- phone folders -----------------------------------------------------------------------

    /// Phone side: serve shared folders through `backend`; `None` stops serving.
    pub fn set_fs_backend(&self, backend: Option<Arc<dyn crate::FsBackend>>) {
        *self.inner.fs_backend.write().unwrap() = backend;
    }

    pub async fn fs_list(&self, phone: DeviceId, path: &str) -> Result<Vec<proto::FsEntry>> {
        files::list(&self.inner, &phone, path).await
    }

    pub async fn fs_stat(&self, phone: DeviceId, path: &str) -> Result<proto::FsEntry> {
        files::stat(&self.inner, &phone, path).await
    }

    /// Reads up to `length` bytes (at most [`crate::MAX_READ`]); shorter at the end of the file.
    pub async fn fs_read(
        &self,
        phone: DeviceId,
        path: &str,
        offset: u64,
        length: u64,
    ) -> Result<Vec<u8>> {
        files::read(&self.inner, &phone, path, offset, length).await
    }

    pub async fn fs_write(
        &self,
        phone: DeviceId,
        path: &str,
        truncate: bool,
    ) -> Result<crate::FsWriter> {
        files::write(&self.inner, &phone, path, truncate).await
    }

    pub async fn fs_mkdir(&self, phone: DeviceId, path: &str) -> Result<proto::FsEntry> {
        files::mkdir(&self.inner, &phone, path).await
    }

    pub async fn fs_delete(&self, phone: DeviceId, path: &str) -> Result<()> {
        files::delete(&self.inner, &phone, path).await
    }

    pub async fn fs_rename(&self, phone: DeviceId, from: &str, to: &str) -> Result<()> {
        files::rename(&self.inner, &phone, from, to).await
    }

    // --- files ------------------------------------------------------------------------------

    /// Offers a file to a connected device. Returns the transfer id; progress arrives as events.
    pub async fn send_file(&self, device: DeviceId, path: &Path) -> Result<String> {
        transfers::send_file(&self.inner, device, path.to_path_buf()).await
    }

    // --- lifecycle --------------------------------------------------------------------------

    pub async fn shutdown(&self) {
        self.inner.cancel.cancel();
        let sessions: Vec<_> = self.inner.sessions.lock().unwrap().drain().collect();
        for (_, s) in sessions {
            s.conn.close(0, b"shutdown");
        }
        self.inner.endpoint.close().await;
    }

    #[doc(hidden)]
    pub fn session_count(&self) -> usize {
        self.inner.sessions.lock().unwrap().len()
    }

    #[doc(hidden)]
    pub fn next_session_id(&self) -> u64 {
        self.inner.next_session_id.load(Ordering::SeqCst)
    }
}

/// The app can run for weeks, so history is pruned periodically, not only at start.
async fn prune_notifications(inner: Arc<Inner>) {
    const INTERVAL: std::time::Duration = std::time::Duration::from_secs(60 * 60);
    loop {
        tokio::select! {
            _ = inner.cancel.cancelled() => return,
            _ = tokio::time::sleep(INTERVAL) => {}
        }
        match inner
            .store
            .lock()
            .unwrap()
            .prune_notifications(crate::now_ms())
        {
            Ok(pruned) => tracing::debug!(pruned, "pruned old notifications"),
            Err(e) => tracing::warn!("failed to prune notifications: {e}"),
        }
    }
}

fn unix_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}
