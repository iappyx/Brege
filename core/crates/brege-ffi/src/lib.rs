//! UniFFI bindings: the API the SwiftUI and Compose shells call.
//!
//! Types here are FFI-friendly mirrors of `brege-core` types. All core work runs on one
//! Tokio runtime owned by this crate, so shells can call in from any thread.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

use brege_core::proto::{self, notification_act};
use brege_core::{
    Clip, CoreError, DeviceId, Event, EventSink, Node, NodeConfig, OpenRequest, SecretKey,
};

uniffi::setup_scaffolding!();

/// Routes core logs to the platform log: os_log on Apple platforms (Console.app, subsystem
/// `app.brege.core`), logcat on Android (tag `BregeCore`). No message content is logged.
fn init_logging() {
    static ONCE: OnceLock<()> = OnceLock::new();
    ONCE.get_or_init(|| {
        #[cfg(target_vendor = "apple")]
        {
            let _ = oslog::OsLogger::new("app.brege.core")
                .level_filter(log::LevelFilter::Info)
                .category_level_filter("quinn", log::LevelFilter::Warn)
                .category_level_filter("quinn_proto", log::LevelFilter::Warn)
                .init();
        }
        #[cfg(target_os = "android")]
        android_logger::init_once(
            android_logger::Config::default()
                .with_tag("BregeCore")
                .with_max_level(log::LevelFilter::Info)
                .with_filter(
                    android_logger::FilterBuilder::new()
                        .parse("info,quinn=warn,quinn_proto=warn,rustls=warn")
                        .build(),
                ),
        );
    });
}

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        init_logging();
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("brege-core")
            .enable_all()
            .build()
            .expect("tokio runtime")
    })
}

/// Runs a future on the core runtime and awaits it from whatever executor the binding uses.
async fn on_runtime<F, T>(fut: F) -> T
where
    F: Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    runtime().spawn(fut).await.expect("core task panicked")
}

// --- errors -----------------------------------------------------------------------------------

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum BregeError {
    #[error("device is not connected")]
    NotConnected,
    #[error("device is not paired")]
    NotPaired,
    #[error("timed out")]
    Timeout,
    #[error("pairing failed: {reason}")]
    PairingFailed { reason: String },
    #[error("invalid input: {detail}")]
    InvalidInput { detail: String },
    #[error("{detail}")]
    Failed { detail: String },
}

impl From<CoreError> for BregeError {
    fn from(e: CoreError) -> Self {
        match e {
            CoreError::NotConnected => Self::NotConnected,
            CoreError::NotPaired => Self::NotPaired,
            CoreError::Timeout => Self::Timeout,
            CoreError::PairingFailed(reason) => Self::PairingFailed { reason },
            CoreError::InvalidInput(detail) => Self::InvalidInput { detail },
            other => Self::Failed {
                detail: other.to_string(),
            },
        }
    }
}

type Result<T> = std::result::Result<T, BregeError>;

fn parse_id(id: &str) -> Result<DeviceId> {
    id.parse().map_err(|_| BregeError::InvalidInput {
        detail: format!("invalid device id {id}"),
    })
}

// --- records ----------------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Platform {
    Unknown,
    MacOs,
    Android,
}

impl From<proto::Platform> for Platform {
    fn from(p: proto::Platform) -> Self {
        match p {
            proto::Platform::Macos => Self::MacOs,
            proto::Platform::Android => Self::Android,
            proto::Platform::Unspecified => Self::Unknown,
        }
    }
}

impl From<Platform> for proto::Platform {
    fn from(p: Platform) -> Self {
        match p {
            Platform::MacOs => Self::Macos,
            Platform::Android => Self::Android,
            Platform::Unknown => Self::Unspecified,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NodeOptions {
    pub name: String,
    pub platform: Platform,
    pub app_version: String,
    /// 32 bytes from [`generate_identity_seed`], stored by the shell in Keychain / Keystore.
    pub identity_seed: Vec<u8>,
    pub db_path: String,
    /// 32 bytes from [`generate_db_key`], stored like the identity seed.
    pub db_key: Vec<u8>,
    /// 0 picks a free port.
    pub listen_port: u16,
    pub download_dir: String,
    /// Uses no network but loopback until the first `set_network_interfaces` (network privacy).
    pub restrict_network_until_reported: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Device {
    pub id: String,
    pub short_id: String,
    pub name: String,
    pub platform: Platform,
    pub connected: bool,
    pub last_seen_ms: Option<i64>,
}

impl From<brege_core::DeviceInfo> for Device {
    fn from(d: brege_core::DeviceInfo) -> Self {
        Self {
            id: d.id.to_string(),
            short_id: d.id.short(),
            name: d.name,
            platform: d.platform.into(),
            connected: d.connected,
            last_seen_ms: d.last_seen_ms,
        }
    }
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum ClipData {
    Text { text: String },
    Png { data: Vec<u8> },
}

impl From<Clip> for ClipData {
    fn from(c: Clip) -> Self {
        match c {
            Clip::Text(text) => Self::Text { text },
            Clip::Png(data) => Self::Png { data },
        }
    }
}

impl From<ClipData> for Clip {
    fn from(c: ClipData) -> Self {
        match c {
            ClipData::Text { text } => Clip::Text(text),
            ClipData::Png { data } => Clip::Png(data),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NotificationActionData {
    pub label: String,
    pub accepts_reply: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ConversationLineData {
    pub sender: String,
    pub text: String,
    pub ts_ms: i64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NotificationData {
    pub key: String,
    pub package: String,
    pub app_label: String,
    pub title: String,
    pub text: String,
    pub big_text: String,
    pub posted_ms: i64,
    pub group_key: String,
    pub actions: Vec<NotificationActionData>,
    pub conversation: Vec<ConversationLineData>,
    /// Stable reference for the app icon; the PNG is only present the first time.
    pub icon_ref: String,
    pub icon_png: Vec<u8>,
    pub picture: Vec<u8>,
    /// The sender's or conversation's avatar, when the app provides one.
    pub sender_icon: Vec<u8>,
    /// Set for missed-call notifications, so the Mac can call back or message the number itself.
    pub call_number: String,
}

impl From<proto::NotificationPost> for NotificationData {
    fn from(p: proto::NotificationPost) -> Self {
        Self {
            key: p.key,
            package: p.package,
            app_label: p.app_label,
            title: p.title,
            text: p.text,
            big_text: p.big_text,
            posted_ms: p.posted_ms,
            group_key: p.group_key,
            actions: p
                .actions
                .into_iter()
                .map(|a| NotificationActionData {
                    label: a.label,
                    accepts_reply: a.accepts_reply,
                })
                .collect(),
            conversation: p
                .conversation
                .into_iter()
                .map(|l| ConversationLineData {
                    sender: l.sender,
                    text: l.text,
                    ts_ms: l.ts_ms,
                })
                .collect(),
            icon_ref: p.icon_ref,
            icon_png: p.icon_png,
            picture: p.picture,
            sender_icon: p.sender_icon,
            call_number: p.call_number,
        }
    }
}

impl From<NotificationData> for proto::NotificationPost {
    fn from(n: NotificationData) -> Self {
        Self {
            key: n.key,
            package: n.package,
            app_label: n.app_label,
            title: n.title,
            text: n.text,
            big_text: n.big_text,
            conversation: n
                .conversation
                .into_iter()
                .map(|l| proto::ConversationLine {
                    sender: l.sender,
                    text: l.text,
                    ts_ms: l.ts_ms,
                })
                .collect(),
            posted_ms: n.posted_ms,
            group_key: n.group_key,
            actions: n
                .actions
                .into_iter()
                .map(|a| proto::NotificationAction {
                    label: a.label,
                    accepts_reply: a.accepts_reply,
                })
                .collect(),
            icon_ref: String::new(),
            icon_png: Vec::new(),
            picture: n.picture,
            sender_icon: n.sender_icon,
            call_number: n.call_number,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct StoredNotification {
    pub device_id: String,
    pub key: String,
    pub package: String,
    pub app_label: String,
    pub title: String,
    pub text: String,
    pub posted_ms: i64,
    pub dismissed: bool,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum NotificationActKind {
    Action { index: u32 },
    Reply { index: u32, text: String },
    Dismiss,
}

impl From<Option<notification_act::Act>> for NotificationActKind {
    fn from(a: Option<notification_act::Act>) -> Self {
        match a {
            Some(notification_act::Act::ActionIndex(index)) => Self::Action { index },
            Some(notification_act::Act::Reply(r)) => Self::Reply {
                index: r.action_index,
                text: r.text,
            },
            _ => Self::Dismiss,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct StatusData {
    pub battery_pct: u32,
    pub charging: bool,
    pub signal_bars: u32,
    pub network_type: String,
    pub dnd: bool,
    pub volume_pct: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct MediaData {
    pub app_label: String,
    pub title: String,
    pub artist: String,
    pub playing: bool,
    pub position_ms: i64,
    pub duration_ms: i64,
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum CommandKind {
    Ring,
    StopRing,
    MediaPlayPause,
    MediaNext,
    MediaPrevious,
    MicStart,
    MicStop,
    EnableWirelessDebugging,
}

impl From<CommandKind> for proto::command::Kind {
    fn from(c: CommandKind) -> Self {
        match c {
            CommandKind::Ring => Self::Ring,
            CommandKind::StopRing => Self::StopRing,
            CommandKind::MediaPlayPause => Self::MediaPlayPause,
            CommandKind::MediaNext => Self::MediaNext,
            CommandKind::MediaPrevious => Self::MediaPrevious,
            CommandKind::MicStart => Self::MicStart,
            CommandKind::MicStop => Self::MicStop,
            CommandKind::EnableWirelessDebugging => Self::EnableWirelessDebugging,
        }
    }
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum OpenRequestData {
    /// Safe to open (http, https, mailto, tel, sms, geo).
    Url {
        url: String,
        title: String,
    },
    /// Other schemes: show, never open automatically.
    UnsafeUrl {
        url: String,
    },
    Text {
        text: String,
    },
    File {
        transfer_id: String,
    },
}

#[derive(Debug, Clone, uniffi::Enum)]
#[allow(clippy::large_enum_variant)] // UniFFI enums cannot hold boxed fields
pub enum BregeEvent {
    PairingRequested {
        request_id: u64,
        device_id: String,
        name: String,
        platform: Platform,
    },
    PairingWaitingForConfirmation {
        name: String,
    },
    DevicePaired {
        device: Device,
    },
    DeviceForgotten {
        device_id: String,
    },
    PeerConnected {
        device_id: String,
        name: String,
    },
    PeerDisconnected {
        device_id: String,
    },
    /// Trusted or blocked networks and tunnels changed; read [`BregeNode::network_paths`].
    NetworkPathsChanged,
    ClipboardReceived {
        from: String,
        clip: ClipData,
    },
    NotificationPosted {
        from: String,
        notification: NotificationData,
    },
    NotificationRemoved {
        from: String,
        key: String,
    },
    NotificationAction {
        from: String,
        key: String,
        act: NotificationActKind,
    },
    StatusUpdated {
        from: String,
        status: StatusData,
    },
    MediaUpdated {
        from: String,
        media: MediaData,
    },
    OpenRequestReceived {
        from: String,
        request: OpenRequestData,
    },
    CommandReceived {
        from: String,
        command: CommandKind,
    },
    TransferOffered {
        from: String,
        id: String,
        name: String,
        size: u64,
    },
    TransferProgress {
        peer: String,
        id: String,
        bytes: u64,
        total: u64,
        incoming: bool,
    },
    TransferCompleted {
        peer: String,
        id: String,
        path: String,
        incoming: bool,
    },
    TransferFailed {
        peer: String,
        id: String,
        reason: String,
        incoming: bool,
    },
    // Messages and calls, Mac side
    MessagesUpdated {
        from: String,
        thread_ids: Vec<String>,
        new_incoming: u32,
    },
    MessageSendStatus {
        from: String,
        client_id: String,
        status: MessageStatus,
        error: String,
    },
    /// Mac side: the phone's controls changed (torch, sound, Do Not Disturb, storage, alarm).
    PhoneControlsChanged {
        from: String,
        state: PhoneControlsData,
    },
    /// Recent calls changed in the cache; `new_missed` counts newly arrived missed calls.
    CallLogUpdated {
        from: String,
        new_missed: u32,
    },
    SimsUpdated {
        from: String,
        sims: Vec<SimData>,
    },
    CallStateChanged {
        from: String,
        call: CallData,
    },
    MicStateChanged {
        from: String,
        active: bool,
        sample_rate: u32,
        detail: String,
    },
    ContactPhotosReceived {
        from: String,
        photos: Vec<ContactPhotoData>,
    },
    AppListReceived {
        from: String,
        apps: Vec<PhoneAppData>,
    },
    OngoingActivityUpdated {
        from: String,
        activity: OngoingActivityData,
    },
    CameraRequested {
        from: String,
        start: bool,
        front: bool,
        torch: bool,
        audio: bool,
    },
    CameraStateChanged {
        from: String,
        state: CameraStateData,
    },
    RecentMediaReceived {
        from: String,
        items: Vec<MediaItemData>,
        new_screenshot: bool,
        permission_needed: bool,
    },
    RecentMediaRequested {
        from: String,
        limit: u32,
    },
    /// Mac: one page of the phone's photo library.
    MediaLibraryPage {
        from: String,
        items: Vec<MediaItemData>,
        end: bool,
        album: String,
        permission_needed: bool,
        partial_access: bool,
    },
    /// Mac: the albums of the phone's library.
    MediaAlbumsReceived {
        from: String,
        albums: Vec<MediaAlbumData>,
    },
    /// Phone: a Mac asks for a page of the library.
    MediaLibraryRequested {
        from: String,
        before_ms: i64,
        limit: u32,
        album: String,
        include_videos: bool,
    },
    /// Phone: a Mac asks for the albums.
    MediaAlbumsRequested {
        from: String,
        include_videos: bool,
    },
    /// Mac: the phone's installed apps.
    AppInventoryReceived {
        from: String,
        apps: Vec<InstalledAppData>,
        usage_access: bool,
    },
    /// Mac: the notification settings of one app on the phone.
    NotificationSettingsReceived {
        from: String,
        settings: NotificationSettingsData,
    },
    /// Phone: a Mac asks for the installed apps.
    AppInventoryRequested {
        from: String,
        include_system: bool,
    },
    /// Phone: a Mac asks to uninstall an app or open one of its settings pages.
    AppActionRequested {
        from: String,
        kind: AppActionKind,
        package: String,
    },
    /// Phone: a Mac asks for an app's notification settings.
    NotificationSettingsRequested {
        from: String,
        package: String,
    },
    /// Phone: a Mac changes one notification category.
    NotificationChannelUpdateRequested {
        from: String,
        package: String,
        channel_id: String,
        importance: u32,
    },
    MediaFetchRequested {
        from: String,
        request_id: String,
        media_id: String,
    },
    OngoingActivityEnded {
        from: String,
        key: String,
    },
    CaptureResultReceived {
        from: String,
        request_id: String,
        status: CaptureStatus,
        transfer_id: String,
        detail: String,
    },
    CaptureRequested {
        from: String,
        request_id: String,
        kind: CaptureKind,
    },
    AppListRequested {
        from: String,
    },
    // Messages and calls, phone side
    ContactPhotosRequested {
        from: String,
        addresses: Vec<String>,
    },
    MessageSyncRequested {
        from: String,
        since_ms: i64,
        max_threads: u32,
        messages_per_thread: u32,
    },
    MessageHistoryRequested {
        from: String,
        thread_id: String,
        before_ms: i64,
        limit: u32,
    },
    MessageSendRequested {
        from: String,
        client_id: String,
        thread_id: String,
        address: String,
        body: String,
        sub_id: i32,
    },
    CallActionRequested {
        from: String,
        action: CallActionKind,
        number: String,
        sub_id: i32,
    },
    /// Phone side: the Mac asks to change a control. Already validated and clamped.
    PhoneControlRequested {
        from: String,
        kind: ControlKind,
        value: i32,
        stream: Option<VolumeStream>,
    },
    /// Phone side: a Mac asks for recent calls. `beforeMs` 0 means the newest ones.
    CallLogRequested {
        from: String,
        since_ms: i64,
        before_ms: i64,
        limit: u32,
    },
}

fn convert_event(event: Event) -> Option<BregeEvent> {
    Some(match event {
        Event::PairingRequested {
            request_id,
            device_id,
            name,
            platform,
        } => BregeEvent::PairingRequested {
            request_id,
            device_id: device_id.to_string(),
            name,
            platform: platform.into(),
        },
        Event::PairingWaitingForConfirmation { name } => {
            BregeEvent::PairingWaitingForConfirmation { name }
        }
        Event::DevicePaired { device } => BregeEvent::DevicePaired {
            device: device.into(),
        },
        Event::DeviceForgotten { device_id } => BregeEvent::DeviceForgotten {
            device_id: device_id.to_string(),
        },
        Event::PeerConnected { device_id, name } => BregeEvent::PeerConnected {
            device_id: device_id.to_string(),
            name,
        },
        Event::PeerDisconnected { device_id } => BregeEvent::PeerDisconnected {
            device_id: device_id.to_string(),
        },
        Event::NetworkPathsChanged => BregeEvent::NetworkPathsChanged,
        Event::ClipboardReceived { from, clip } => BregeEvent::ClipboardReceived {
            from: from.to_string(),
            clip: clip.into(),
        },
        Event::NotificationPosted { from, post } => BregeEvent::NotificationPosted {
            from: from.to_string(),
            notification: post.into(),
        },
        Event::NotificationRemoved { from, key } => BregeEvent::NotificationRemoved {
            from: from.to_string(),
            key,
        },
        Event::NotificationAction { from, act } => BregeEvent::NotificationAction {
            from: from.to_string(),
            key: act.key,
            act: act.act.into(),
        },
        Event::StatusUpdated { from, status } => BregeEvent::StatusUpdated {
            from: from.to_string(),
            status: StatusData {
                battery_pct: status.battery_pct,
                charging: status.charging,
                signal_bars: status.signal_bars,
                network_type: status.network_type,
                dnd: status.dnd,
                volume_pct: status.volume_pct,
            },
        },
        Event::MediaUpdated { from, media } => BregeEvent::MediaUpdated {
            from: from.to_string(),
            media: MediaData {
                app_label: media.app_label,
                title: media.title,
                artist: media.artist,
                playing: media.playing,
                position_ms: media.position_ms,
                duration_ms: media.duration_ms,
            },
        },
        Event::OpenRequestReceived { from, request } => BregeEvent::OpenRequestReceived {
            from: from.to_string(),
            request: match request {
                OpenRequest::Url { url, title } => OpenRequestData::Url { url, title },
                OpenRequest::UnsafeUrl { url } => OpenRequestData::UnsafeUrl { url },
                OpenRequest::Text { text } => OpenRequestData::Text { text },
                OpenRequest::File { transfer_id } => OpenRequestData::File { transfer_id },
            },
        },
        Event::CommandReceived { from, command } => BregeEvent::CommandReceived {
            from: from.to_string(),
            command: match command {
                proto::command::Kind::Ring => CommandKind::Ring,
                proto::command::Kind::StopRing => CommandKind::StopRing,
                proto::command::Kind::MediaPlayPause => CommandKind::MediaPlayPause,
                proto::command::Kind::MediaNext => CommandKind::MediaNext,
                proto::command::Kind::MediaPrevious => CommandKind::MediaPrevious,
                proto::command::Kind::MicStart => CommandKind::MicStart,
                proto::command::Kind::MicStop => CommandKind::MicStop,
                proto::command::Kind::EnableWirelessDebugging => {
                    CommandKind::EnableWirelessDebugging
                }
                proto::command::Kind::Unspecified => return None,
            },
        },
        Event::TransferOffered {
            from,
            id,
            name,
            size,
        } => BregeEvent::TransferOffered {
            from: from.to_string(),
            id,
            name,
            size,
        },
        Event::TransferProgress {
            peer,
            id,
            bytes,
            total,
            incoming,
        } => BregeEvent::TransferProgress {
            peer: peer.to_string(),
            id,
            bytes,
            total,
            incoming,
        },
        Event::TransferCompleted {
            peer,
            id,
            path,
            incoming,
        } => BregeEvent::TransferCompleted {
            peer: peer.to_string(),
            id,
            path: path.to_string_lossy().into_owned(),
            incoming,
        },
        Event::TransferFailed {
            peer,
            id,
            reason,
            incoming,
        } => BregeEvent::TransferFailed {
            peer: peer.to_string(),
            id,
            reason,
            incoming,
        },
        Event::MessagesUpdated {
            from,
            thread_ids,
            new_incoming,
        } => BregeEvent::MessagesUpdated {
            from: from.to_string(),
            thread_ids,
            new_incoming,
        },
        Event::SmsSendStatus { from, status } => BregeEvent::MessageSendStatus {
            from: from.to_string(),
            client_id: status.client_id,
            status: MessageStatus::from_proto(status.status),
            error: status.error,
        },
        Event::PhoneControlStateChanged { from, state } => BregeEvent::PhoneControlsChanged {
            from: from.to_string(),
            state: state.into(),
        },
        Event::CallLogUpdated { from, new_missed } => BregeEvent::CallLogUpdated {
            from: from.to_string(),
            new_missed,
        },
        Event::SimsUpdated { from, sims } => BregeEvent::SimsUpdated {
            from: from.to_string(),
            sims: sims.into_iter().map(SimData::from).collect(),
        },
        Event::CallStateChanged { from, call } => BregeEvent::CallStateChanged {
            from: from.to_string(),
            call: call.into(),
        },
        Event::MicStateChanged { from, state } => BregeEvent::MicStateChanged {
            from: from.to_string(),
            active: state.active,
            sample_rate: state.sample_rate,
            detail: state.detail,
        },
        Event::CameraRequested { from, request } => BregeEvent::CameraRequested {
            from: from.to_string(),
            start: request.start,
            front: request.facing == proto::CameraFacing::Front as i32,
            torch: request.torch,
            audio: request.audio,
        },
        Event::CameraStateChanged { from, state } => BregeEvent::CameraStateChanged {
            from: from.to_string(),
            state: CameraStateData {
                active: state.active,
                codec: state.codec,
                width: state.width,
                height: state.height,
                rotation: state.rotation,
                front: state.facing == proto::CameraFacing::Front as i32,
                torch: state.torch,
                torch_available: state.torch_available,
                detail: state.detail,
            },
        },
        Event::AppInventoryReceived { from, inventory } => BregeEvent::AppInventoryReceived {
            from: from.to_string(),
            apps: inventory.apps.into_iter().map(Into::into).collect(),
            usage_access: inventory.usage_access,
        },
        Event::NotificationSettingsReceived { from, settings } => {
            BregeEvent::NotificationSettingsReceived {
                from: from.to_string(),
                settings: settings.into(),
            }
        }
        Event::AppInventoryRequested {
            from,
            include_system,
        } => BregeEvent::AppInventoryRequested {
            from: from.to_string(),
            include_system,
        },
        Event::AppActionRequested { from, action } => BregeEvent::AppActionRequested {
            from: from.to_string(),
            kind: AppActionKind::from_proto(action.kind)?,
            package: action.package,
        },
        Event::NotificationSettingsRequested { from, package } => {
            BregeEvent::NotificationSettingsRequested {
                from: from.to_string(),
                package,
            }
        }
        Event::NotificationChannelUpdateRequested { from, update } => {
            BregeEvent::NotificationChannelUpdateRequested {
                from: from.to_string(),
                package: update.package,
                channel_id: update.channel_id,
                importance: update.importance,
            }
        }
        Event::MediaLibraryPageReceived { from, page } => BregeEvent::MediaLibraryPage {
            from: from.to_string(),
            items: page.items.into_iter().map(Into::into).collect(),
            end: page.end,
            album: page.album,
            permission_needed: page.permission_needed,
            partial_access: page.partial_access,
        },
        Event::MediaAlbumsReceived { from, albums } => BregeEvent::MediaAlbumsReceived {
            from: from.to_string(),
            albums: albums.into_iter().map(Into::into).collect(),
        },
        Event::MediaLibraryRequested { from, request } => BregeEvent::MediaLibraryRequested {
            from: from.to_string(),
            before_ms: request.before_ms,
            limit: request.limit,
            album: request.album,
            include_videos: request.include_videos,
        },
        Event::MediaAlbumsRequested {
            from,
            include_videos,
        } => BregeEvent::MediaAlbumsRequested {
            from: from.to_string(),
            include_videos,
        },
        Event::RecentMediaReceived {
            from,
            items,
            new_screenshot,
            permission_needed,
        } => BregeEvent::RecentMediaReceived {
            from: from.to_string(),
            items: items.into_iter().map(Into::into).collect(),
            new_screenshot,
            permission_needed,
        },
        Event::RecentMediaRequested { from, limit } => BregeEvent::RecentMediaRequested {
            from: from.to_string(),
            limit,
        },
        Event::MediaFetchRequested {
            from,
            request_id,
            media_id,
        } => BregeEvent::MediaFetchRequested {
            from: from.to_string(),
            request_id,
            media_id,
        },
        Event::OngoingActivityUpdated { from, activity } => BregeEvent::OngoingActivityUpdated {
            from: from.to_string(),
            activity: activity.into(),
        },
        Event::OngoingActivityEnded { from, key } => BregeEvent::OngoingActivityEnded {
            from: from.to_string(),
            key,
        },
        Event::CaptureResultReceived { from, result } => BregeEvent::CaptureResultReceived {
            from: from.to_string(),
            request_id: result.request_id,
            status: match proto::capture_result::Status::try_from(result.status) {
                Ok(proto::capture_result::Status::Sending) => CaptureStatus::Sending,
                Ok(proto::capture_result::Status::Cancelled) => CaptureStatus::Cancelled,
                _ => CaptureStatus::Failed,
            },
            transfer_id: result.transfer_id,
            detail: result.detail,
        },
        Event::CaptureRequested { from, request } => BregeEvent::CaptureRequested {
            from: from.to_string(),
            request_id: request.request_id,
            kind: match proto::capture_request::Kind::try_from(request.kind) {
                Ok(proto::capture_request::Kind::Document) => CaptureKind::Document,
                _ => CaptureKind::Photo,
            },
        },
        Event::AppListReceived { from, apps } => BregeEvent::AppListReceived {
            from: from.to_string(),
            apps: apps
                .into_iter()
                .map(|a| PhoneAppData {
                    package: a.package,
                    label: a.label,
                    icon_png: a.icon_png,
                })
                .collect(),
        },
        Event::AppListRequested { from } => BregeEvent::AppListRequested {
            from: from.to_string(),
        },
        Event::ContactPhotosReceived { from, photos } => BregeEvent::ContactPhotosReceived {
            from: from.to_string(),
            photos: photos
                .into_iter()
                .map(|p| ContactPhotoData {
                    address: p.address,
                    jpeg: p.jpeg,
                })
                .collect(),
        },
        Event::ContactPhotosRequested { from, addresses } => BregeEvent::ContactPhotosRequested {
            from: from.to_string(),
            addresses,
        },
        Event::SmsSyncRequested { from, request } => BregeEvent::MessageSyncRequested {
            from: from.to_string(),
            since_ms: request.since_ms,
            max_threads: request.max_threads,
            messages_per_thread: request.messages_per_thread,
        },
        Event::SmsHistoryRequested { from, request } => BregeEvent::MessageHistoryRequested {
            from: from.to_string(),
            thread_id: request.thread_id,
            before_ms: request.before_ms,
            limit: request.limit,
        },
        Event::SmsSendRequested { from, send } => BregeEvent::MessageSendRequested {
            from: from.to_string(),
            client_id: send.client_id,
            thread_id: send.thread_id,
            address: send.address,
            body: send.body,
            sub_id: send.sub_id,
        },
        Event::CallActionRequested { from, action } => BregeEvent::CallActionRequested {
            from: from.to_string(),
            action: CallActionKind::from_proto(action.kind)?,
            number: action.number,
            sub_id: action.sub_id,
        },
        Event::PhoneControlRequested { from, control } => BregeEvent::PhoneControlRequested {
            from: from.to_string(),
            kind: ControlKind::from_proto(control.kind)?,
            value: control.value,
            stream: VolumeStream::from_proto(control.stream),
        },
        Event::CallLogRequested { from, request } => BregeEvent::CallLogRequested {
            from: from.to_string(),
            since_ms: request.since_ms,
            before_ms: request.before_ms,
            limit: request.limit,
        },
    })
}

// --- messages and calls ----------------------------------------------------------------------

/// The phone camera as reported by the phone.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CameraStateData {
    pub active: bool,
    /// "h264" or "h265".
    pub codec: String,
    /// Encoded size, before rotation.
    pub width: u32,
    pub height: u32,
    /// Degrees clockwise to show the picture upright.
    pub rotation: u32,
    pub front: bool,
    pub torch: bool,
    pub torch_available: bool,
    /// Why the camera is not active, e.g. "Tap the notification on your phone".
    pub detail: String,
}

/// Receives camera video on the Mac. Called on a core thread per packet; copy and return.
#[uniffi::export(foreign)]
pub trait VideoPacketListener: Send + Sync {
    /// `flags`: 1 = codec config, 2 = key frame. `data` is Annex-B.
    fn on_video_packet(&self, from: String, flags: u8, pts_us: u64, data: Vec<u8>);
    fn on_video_end(&self, from: String);
}

struct VideoAdapter(Arc<dyn VideoPacketListener>);

impl brege_core::VideoSink for VideoAdapter {
    fn on_video_packet(&self, from: DeviceId, flags: u8, pts_us: u64, data: &[u8]) {
        self.0
            .on_video_packet(from.to_string(), flags, pts_us, data.to_vec());
    }

    fn on_video_end(&self, from: DeviceId) {
        self.0.on_video_end(from.to_string());
    }
}

/// An app installed on the phone, for the inventory on the Mac.
#[derive(Debug, Clone, uniffi::Record)]
pub struct InstalledAppData {
    pub package: String,
    pub label: String,
    pub version: String,
    pub size_bytes: u64,
    pub last_used_ms: i64,
    pub system: bool,
    pub installed_ms: i64,
    pub icon_png: Vec<u8>,
}

impl From<proto::InstalledApp> for InstalledAppData {
    fn from(a: proto::InstalledApp) -> Self {
        Self {
            package: a.package,
            label: a.label,
            version: a.version,
            size_bytes: a.size_bytes,
            last_used_ms: a.last_used_ms,
            system: a.system,
            installed_ms: a.installed_ms,
            icon_png: a.icon_png,
        }
    }
}

impl From<InstalledAppData> for proto::InstalledApp {
    fn from(a: InstalledAppData) -> Self {
        Self {
            package: a.package,
            label: a.label,
            version: a.version,
            size_bytes: a.size_bytes,
            last_used_ms: a.last_used_ms,
            system: a.system,
            installed_ms: a.installed_ms,
            icon_png: a.icon_png,
        }
    }
}

/// What the Mac asks the phone to do with an app; the phone always asks the user first.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum AppActionKind {
    Uninstall,
    AppSettings,
    NotificationSettings,
    UsageAccess,
}

impl AppActionKind {
    fn to_proto(self) -> proto::app_action::Kind {
        use proto::app_action::Kind;
        match self {
            Self::Uninstall => Kind::Uninstall,
            Self::AppSettings => Kind::AppSettings,
            Self::NotificationSettings => Kind::NotificationSettings,
            Self::UsageAccess => Kind::UsageAccess,
        }
    }

    fn from_proto(v: i32) -> Option<Self> {
        use proto::app_action::Kind;
        Some(match Kind::try_from(v).ok()? {
            Kind::Uninstall => Self::Uninstall,
            Kind::AppSettings => Self::AppSettings,
            Kind::NotificationSettings => Self::NotificationSettings,
            Kind::UsageAccess => Self::UsageAccess,
            Kind::Unspecified => return None,
        })
    }
}

/// One notification category of an app on the phone (Android calls these channels).
#[derive(Debug, Clone, uniffi::Record)]
pub struct NotificationChannelData {
    pub id: String,
    pub name: String,
    pub group: String,
    /// 0 off, 1 silent, 2 low, 3 normal, 4 high, 5 urgent.
    pub importance: u32,
    pub blocked: bool,
}

/// The notification settings of one app on the phone.
#[derive(Debug, Clone, uniffi::Record)]
pub struct NotificationSettingsData {
    pub package: String,
    pub app_label: String,
    pub channels: Vec<NotificationChannelData>,
    pub app_blocked: bool,
    /// False when the phone does not let Brêge change these.
    pub allowed: bool,
}

impl From<proto::NotificationSettings> for NotificationSettingsData {
    fn from(s: proto::NotificationSettings) -> Self {
        Self {
            package: s.package,
            app_label: s.app_label,
            channels: s
                .channels
                .into_iter()
                .map(|c| NotificationChannelData {
                    id: c.id,
                    name: c.name,
                    group: c.group,
                    importance: c.importance,
                    blocked: c.blocked,
                })
                .collect(),
            app_blocked: s.app_blocked,
            allowed: s.allowed,
        }
    }
}

impl From<NotificationSettingsData> for proto::NotificationSettings {
    fn from(s: NotificationSettingsData) -> Self {
        Self {
            package: s.package,
            app_label: s.app_label,
            channels: s
                .channels
                .into_iter()
                .map(|c| proto::NotificationChannel {
                    id: c.id,
                    name: c.name,
                    group: c.group,
                    importance: c.importance,
                    blocked: c.blocked,
                })
                .collect(),
            app_blocked: s.app_blocked,
            allowed: s.allowed,
        }
    }
}

/// A recent photo or screenshot on the phone.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MediaItemData {
    pub id: String,
    pub name: String,
    pub taken_ms: i64,
    pub screenshot: bool,
    pub mime: String,
    pub thumbnail_jpeg: Vec<u8>,
    pub size_bytes: u64,
    pub duration_ms: u32,
    pub video: bool,
}

/// An album of the phone's photo library (its gallery folders).
#[derive(Debug, Clone, uniffi::Record)]
pub struct MediaAlbumData {
    pub id: String,
    pub name: String,
    pub count: u32,
    pub cover_id: String,
}

impl From<proto::MediaAlbum> for MediaAlbumData {
    fn from(a: proto::MediaAlbum) -> Self {
        Self {
            id: a.id,
            name: a.name,
            count: a.count,
            cover_id: a.cover_id,
        }
    }
}

impl From<MediaAlbumData> for proto::MediaAlbum {
    fn from(a: MediaAlbumData) -> Self {
        Self {
            id: a.id,
            name: a.name,
            count: a.count,
            cover_id: a.cover_id,
        }
    }
}

impl From<proto::MediaItem> for MediaItemData {
    fn from(m: proto::MediaItem) -> Self {
        Self {
            id: m.id,
            name: m.name,
            taken_ms: m.taken_ms,
            screenshot: m.screenshot,
            mime: m.mime,
            thumbnail_jpeg: m.thumbnail_jpeg,
            size_bytes: m.size_bytes,
            duration_ms: m.duration_ms,
            video: m.video,
        }
    }
}

impl From<MediaItemData> for proto::MediaItem {
    fn from(m: MediaItemData) -> Self {
        Self {
            id: m.id,
            name: m.name,
            taken_ms: m.taken_ms,
            screenshot: m.screenshot,
            mime: m.mime,
            thumbnail_jpeg: m.thumbnail_jpeg,
            size_bytes: m.size_bytes,
            duration_ms: m.duration_ms,
            video: m.video,
        }
    }
}

/// The one-time code in a notification's text ("Your code is 482913"), digits only.
#[uniffi::export]
pub fn detect_verification_code(text: String) -> Option<String> {
    brege_core::codes::detect(&text)
}

/// An ongoing phone notification shown on the Mac (timer, navigation, delivery …).
#[derive(Debug, Clone, uniffi::Record)]
pub struct OngoingActivityData {
    pub key: String,
    pub package: String,
    pub app_label: String,
    pub title: String,
    pub text: String,
    /// Compact text for the menu bar, when the app provides one.
    pub short_text: String,
    pub progress: i32,
    /// 0 = no progress bar.
    pub progress_max: i32,
    pub indeterminate: bool,
    /// Epoch ms the timer counts from (or down to); 0 = no timer.
    pub chronometer_base_ms: i64,
    pub counts_down: bool,
    /// App icon, only present in the first update for a key.
    pub icon_png: Vec<u8>,
    pub actions: Vec<NotificationActionData>,
    pub updated_ms: i64,
}

impl From<proto::OngoingActivity> for OngoingActivityData {
    fn from(a: proto::OngoingActivity) -> Self {
        Self {
            key: a.key,
            package: a.package,
            app_label: a.app_label,
            title: a.title,
            text: a.text,
            short_text: a.short_text,
            progress: a.progress,
            progress_max: a.progress_max,
            indeterminate: a.indeterminate,
            chronometer_base_ms: a.chronometer_base_ms,
            counts_down: a.counts_down,
            icon_png: a.icon_png,
            actions: a
                .actions
                .into_iter()
                .map(|x| NotificationActionData {
                    label: x.label,
                    accepts_reply: x.accepts_reply,
                })
                .collect(),
            updated_ms: a.updated_ms,
        }
    }
}

impl From<OngoingActivityData> for proto::OngoingActivity {
    fn from(a: OngoingActivityData) -> Self {
        Self {
            key: a.key,
            package: a.package,
            app_label: a.app_label,
            title: a.title,
            text: a.text,
            short_text: a.short_text,
            progress: a.progress,
            progress_max: a.progress_max,
            indeterminate: a.indeterminate,
            chronometer_base_ms: a.chronometer_base_ms,
            counts_down: a.counts_down,
            icon_png: a.icon_png,
            actions: a
                .actions
                .into_iter()
                .map(|x| proto::NotificationAction {
                    label: x.label,
                    accepts_reply: x.accepts_reply,
                })
                .collect(),
            updated_ms: a.updated_ms,
        }
    }
}

/// Import from phone: what to capture.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CaptureKind {
    Photo,
    Document,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CaptureStatus {
    /// The file is on its way as the transfer `transfer_id`.
    Sending,
    Cancelled,
    Failed,
}

/// A launchable app on the phone.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PhoneAppData {
    pub package: String,
    pub label: String,
    pub icon_png: Vec<u8>,
}

/// A contact photo for one address; empty `jpeg` means there is none.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ContactPhotoData {
    pub address: String,
    pub jpeg: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MessageKind {
    Sms,
    Rcs,
}

impl MessageKind {
    fn from_proto(v: i32) -> Self {
        if v == proto::MessageKind::Rcs as i32 {
            Self::Rcs
        } else {
            Self::Sms
        }
    }

    fn to_proto(self) -> i32 {
        match self {
            Self::Sms => proto::MessageKind::Sms as i32,
            Self::Rcs => proto::MessageKind::Rcs as i32,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MessageStatus {
    Received,
    Sent,
    Sending,
    Failed,
}

impl MessageStatus {
    fn from_proto(v: i32) -> Self {
        match proto::sms_message::Status::try_from(v).unwrap_or_default() {
            proto::sms_message::Status::Sent => Self::Sent,
            proto::sms_message::Status::Sending => Self::Sending,
            proto::sms_message::Status::Failed => Self::Failed,
            _ => Self::Received,
        }
    }

    fn to_proto(self) -> i32 {
        (match self {
            Self::Received => proto::sms_message::Status::Received,
            Self::Sent => proto::sms_message::Status::Sent,
            Self::Sending => proto::sms_message::Status::Sending,
            Self::Failed => proto::sms_message::Status::Failed,
        }) as i32
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct ThreadData {
    pub id: String,
    pub addresses: Vec<String>,
    pub names: Vec<String>,
    pub title: String,
    pub snippet: String,
    pub last_ms: i64,
    pub kind: MessageKind,
    pub can_reply: bool,
    /// Local to the Mac; always false when published by the phone.
    pub unread: bool,
}

impl From<brege_core::ThreadRecord> for ThreadData {
    fn from(t: brege_core::ThreadRecord) -> Self {
        Self {
            id: t.id,
            addresses: t.addresses,
            names: t.names,
            title: t.title,
            snippet: t.snippet,
            last_ms: t.last_ms,
            kind: MessageKind::from_proto(t.kind),
            can_reply: t.can_reply,
            unread: t.unread,
        }
    }
}

impl From<ThreadData> for proto::SmsThread {
    fn from(t: ThreadData) -> Self {
        Self {
            id: t.id,
            addresses: t.addresses,
            names: t.names,
            snippet: t.snippet,
            last_ms: t.last_ms,
            kind: t.kind.to_proto(),
            can_reply: t.can_reply,
            title: t.title,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct MessageData {
    pub id: String,
    pub thread_id: String,
    pub address: String,
    pub sender_name: String,
    pub body: String,
    pub ts_ms: i64,
    pub outgoing: bool,
    pub sub_id: i32,
    pub status: MessageStatus,
    pub has_media: bool,
    pub kind: MessageKind,
}

impl From<brege_core::MessageRecord> for MessageData {
    fn from(m: brege_core::MessageRecord) -> Self {
        Self {
            id: m.id,
            thread_id: m.thread_id,
            address: m.address,
            sender_name: m.sender_name,
            body: m.body,
            ts_ms: m.ts_ms,
            outgoing: m.outgoing,
            sub_id: m.sub_id,
            status: MessageStatus::from_proto(m.status),
            has_media: m.has_media,
            kind: MessageKind::from_proto(m.kind),
        }
    }
}

impl From<MessageData> for proto::SmsMessage {
    fn from(m: MessageData) -> Self {
        Self {
            id: m.id,
            thread_id: m.thread_id,
            address: m.address,
            sender_name: m.sender_name,
            body: m.body,
            ts_ms: m.ts_ms,
            outgoing: m.outgoing,
            sub_id: m.sub_id,
            status: m.status.to_proto(),
            has_media: m.has_media,
            kind: m.kind.to_proto(),
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SimData {
    pub sub_id: i32,
    pub label: String,
    pub slot: i32,
}

impl From<proto::Sim> for SimData {
    fn from(s: proto::Sim) -> Self {
        Self {
            sub_id: s.sub_id,
            label: s.label,
            slot: s.slot,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CallStatus {
    Ringing,
    Dialing,
    Active,
    Ended,
}

/// What the Mac asks the phone to change.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ControlKind {
    Torch,
    TorchLevel,
    RingerMode,
    StreamVolume,
    Dnd,
    Vibrate,
    ClearNotifications,
}

impl ControlKind {
    fn to_proto(self) -> proto::phone_control::Kind {
        use proto::phone_control::Kind;
        match self {
            Self::Torch => Kind::Torch,
            Self::TorchLevel => Kind::TorchLevel,
            Self::RingerMode => Kind::RingerMode,
            Self::StreamVolume => Kind::StreamVolume,
            Self::Dnd => Kind::Dnd,
            Self::Vibrate => Kind::Vibrate,
            Self::ClearNotifications => Kind::ClearNotifications,
        }
    }

    fn from_proto(v: i32) -> Option<Self> {
        use proto::phone_control::Kind;
        Some(match Kind::try_from(v).ok()? {
            Kind::Torch => Self::Torch,
            Kind::TorchLevel => Self::TorchLevel,
            Kind::RingerMode => Self::RingerMode,
            Kind::StreamVolume => Self::StreamVolume,
            Kind::Dnd => Self::Dnd,
            Kind::Vibrate => Self::Vibrate,
            Kind::ClearNotifications => Self::ClearNotifications,
            Kind::Unspecified => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum VolumeStream {
    Ring,
    Media,
    Alarm,
    Notification,
}

impl VolumeStream {
    fn to_proto(self) -> proto::phone_control::Stream {
        use proto::phone_control::Stream;
        match self {
            Self::Ring => Stream::Ring,
            Self::Media => Stream::Media,
            Self::Alarm => Stream::Alarm,
            Self::Notification => Stream::Notification,
        }
    }

    fn from_proto(v: i32) -> Option<Self> {
        use proto::phone_control::Stream;
        Some(match Stream::try_from(v).ok()? {
            Stream::Ring => Self::Ring,
            Stream::Media => Self::Media,
            Stream::Alarm => Self::Alarm,
            Stream::Notification => Self::Notification,
            Stream::Unspecified => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RingerMode {
    Silent,
    Vibrate,
    Normal,
}

impl RingerMode {
    fn to_proto(self) -> proto::RingerMode {
        match self {
            Self::Silent => proto::RingerMode::Silent,
            Self::Vibrate => proto::RingerMode::Vibrate,
            Self::Normal => proto::RingerMode::Normal,
        }
    }

    fn from_proto(v: i32) -> Self {
        match proto::RingerMode::try_from(v).unwrap_or(proto::RingerMode::Unspecified) {
            proto::RingerMode::Silent => Self::Silent,
            proto::RingerMode::Vibrate => Self::Vibrate,
            proto::RingerMode::Normal | proto::RingerMode::Unspecified => Self::Normal,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DndMode {
    Off,
    Priority,
    Alarms,
    None,
}

impl DndMode {
    fn to_proto(self) -> proto::DndMode {
        match self {
            Self::Off => proto::DndMode::DndOff,
            Self::Priority => proto::DndMode::DndPriority,
            Self::Alarms => proto::DndMode::DndAlarms,
            Self::None => proto::DndMode::DndNone,
        }
    }

    fn from_proto(v: i32) -> Self {
        match proto::DndMode::try_from(v).unwrap_or(proto::DndMode::Unspecified) {
            proto::DndMode::DndPriority => Self::Priority,
            proto::DndMode::DndAlarms => Self::Alarms,
            proto::DndMode::DndNone => Self::None,
            proto::DndMode::DndOff | proto::DndMode::Unspecified => Self::Off,
        }
    }
}

/// Where the phone's controls stand, and what it is allowed to change.
#[derive(Debug, Clone, uniffi::Record)]
pub struct PhoneControlsData {
    pub has_torch: bool,
    pub torch_on: bool,
    pub torch_level: u32,
    pub torch_max_level: u32,
    pub ringer_mode: RingerMode,
    pub volume_ring: u32,
    pub volume_ring_max: u32,
    pub volume_media: u32,
    pub volume_media_max: u32,
    pub volume_alarm: u32,
    pub volume_alarm_max: u32,
    pub dnd: DndMode,
    pub needs_dnd_access: bool,
    pub next_alarm_ms: i64,
    pub storage_free_bytes: u64,
    pub storage_total_bytes: u64,
    pub battery_temperature_dc: i32,
    pub battery_health: String,
    pub charging_source: String,
}

impl From<proto::PhoneControlState> for PhoneControlsData {
    fn from(s: proto::PhoneControlState) -> Self {
        Self {
            has_torch: s.has_torch,
            torch_on: s.torch_on,
            torch_level: s.torch_level,
            torch_max_level: s.torch_max_level,
            ringer_mode: RingerMode::from_proto(s.ringer_mode),
            volume_ring: s.volume_ring,
            volume_ring_max: s.volume_ring_max,
            volume_media: s.volume_media,
            volume_media_max: s.volume_media_max,
            volume_alarm: s.volume_alarm,
            volume_alarm_max: s.volume_alarm_max,
            dnd: DndMode::from_proto(s.dnd),
            needs_dnd_access: s.needs_dnd_access,
            next_alarm_ms: s.next_alarm_ms,
            storage_free_bytes: s.storage_free_bytes,
            storage_total_bytes: s.storage_total_bytes,
            battery_temperature_dc: s.battery_temperature_dc,
            battery_health: s.battery_health,
            charging_source: s.charging_source,
        }
    }
}

impl From<PhoneControlsData> for proto::PhoneControlState {
    fn from(s: PhoneControlsData) -> Self {
        Self {
            has_torch: s.has_torch,
            torch_on: s.torch_on,
            torch_level: s.torch_level,
            torch_max_level: s.torch_max_level,
            ringer_mode: s.ringer_mode.to_proto() as i32,
            volume_ring: s.volume_ring,
            volume_ring_max: s.volume_ring_max,
            volume_media: s.volume_media,
            volume_media_max: s.volume_media_max,
            volume_alarm: s.volume_alarm,
            volume_alarm_max: s.volume_alarm_max,
            dnd: s.dnd.to_proto() as i32,
            needs_dnd_access: s.needs_dnd_access,
            next_alarm_ms: s.next_alarm_ms,
            storage_free_bytes: s.storage_free_bytes,
            storage_total_bytes: s.storage_total_bytes,
            battery_temperature_dc: s.battery_temperature_dc,
            battery_health: s.battery_health,
            charging_source: s.charging_source,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CallDirection {
    Incoming,
    Outgoing,
    Missed,
    Rejected,
    Blocked,
    Voicemail,
}

impl CallDirection {
    fn from_proto(v: i32) -> Self {
        use proto::call_log_entry::Direction;
        match Direction::try_from(v).unwrap_or(Direction::Unspecified) {
            Direction::Outgoing => Self::Outgoing,
            Direction::Missed => Self::Missed,
            Direction::Rejected => Self::Rejected,
            Direction::Blocked => Self::Blocked,
            Direction::Voicemail => Self::Voicemail,
            Direction::Incoming | Direction::Unspecified => Self::Incoming,
        }
    }

    fn to_proto(self) -> proto::call_log_entry::Direction {
        use proto::call_log_entry::Direction;
        match self {
            Self::Incoming => Direction::Incoming,
            Self::Outgoing => Direction::Outgoing,
            Self::Missed => Direction::Missed,
            Self::Rejected => Direction::Rejected,
            Self::Blocked => Direction::Blocked,
            Self::Voicemail => Direction::Voicemail,
        }
    }
}

/// One entry of the phone's call log.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CallLogData {
    pub id: String,
    pub number: String,
    pub contact_name: String,
    pub direction: CallDirection,
    pub started_ms: i64,
    pub duration_s: u32,
    pub sub_id: i32,
}

impl From<brege_core::CallRecord> for CallLogData {
    fn from(c: brege_core::CallRecord) -> Self {
        Self {
            id: c.id,
            number: c.number,
            contact_name: c.name,
            direction: CallDirection::from_proto(c.direction),
            started_ms: c.started_ms,
            duration_s: c.duration_s,
            sub_id: c.sub_id,
        }
    }
}

impl From<CallLogData> for proto::CallLogEntry {
    fn from(c: CallLogData) -> Self {
        Self {
            id: c.id,
            number: c.number,
            contact_name: c.contact_name,
            direction: c.direction.to_proto() as i32,
            started_ms: c.started_ms,
            duration_s: c.duration_s,
            sub_id: c.sub_id,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CallData {
    pub call_id: String,
    pub status: CallStatus,
    pub number: String,
    pub contact_name: String,
    pub incoming: bool,
    pub started_ms: i64,
}

impl From<proto::CallState> for CallData {
    fn from(c: proto::CallState) -> Self {
        use proto::call_state::State;
        Self {
            call_id: c.call_id,
            status: match State::try_from(c.state).unwrap_or_default() {
                State::Ringing => CallStatus::Ringing,
                State::Dialing => CallStatus::Dialing,
                State::Active => CallStatus::Active,
                State::Ended | State::Unspecified => CallStatus::Ended,
            },
            number: c.number,
            contact_name: c.contact_name,
            incoming: c.incoming,
            started_ms: c.started_ms,
        }
    }
}

impl From<CallData> for proto::CallState {
    fn from(c: CallData) -> Self {
        use proto::call_state::State;
        Self {
            call_id: c.call_id,
            state: (match c.status {
                CallStatus::Ringing => State::Ringing,
                CallStatus::Dialing => State::Dialing,
                CallStatus::Active => State::Active,
                CallStatus::Ended => State::Ended,
            }) as i32,
            number: c.number,
            contact_name: c.contact_name,
            incoming: c.incoming,
            started_ms: c.started_ms,
        }
    }
}

// --- network privacy ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NetworkInterfaceKind {
    Wifi,
    Ethernet,
    Cellular,
    Vpn,
    Hotspot,
    Loopback,
    Other,
}

/// One network interface as the platform sees it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct NetworkInterfaceData {
    pub name: String,
    pub kind: NetworkInterfaceKind,
    /// "address/prefix", IPv4 or IPv6.
    pub addresses: Vec<String>,
    /// Router address, or "".
    pub gateway: String,
    /// Router hardware address where readable (the Mac), or "".
    pub gateway_hw: String,
    /// Wi‑Fi name where readable (Location access), or "".
    pub ssid: String,
}

/// A network the device is on, or a tunnel that blocked a paired device.
#[derive(Debug, Clone, uniffi::Record)]
pub struct NetworkPathData {
    pub fingerprint: String,
    pub is_vpn: bool,
    pub label: String,
    /// Wi‑Fi name, or "".
    pub ssid: String,
    pub trusted: bool,
    /// The user chose "Not here": do not ask again.
    pub declined: bool,
    pub blocked_device_ids: Vec<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct KnownNetworkData {
    pub fingerprint: String,
    pub is_vpn: bool,
    pub label: String,
    pub last_used_ms: i64,
    /// False for a network the user chose not to use.
    pub trusted: bool,
}

impl NetworkInterfaceData {
    fn into_core(self) -> brege_core::NetInterface {
        use brege_core::InterfaceKind as K;
        brege_core::NetInterface {
            name: self.name,
            kind: match self.kind {
                NetworkInterfaceKind::Wifi => K::Wifi,
                NetworkInterfaceKind::Ethernet => K::Ethernet,
                NetworkInterfaceKind::Cellular => K::Cellular,
                NetworkInterfaceKind::Vpn => K::Vpn,
                NetworkInterfaceKind::Hotspot => K::Hotspot,
                NetworkInterfaceKind::Loopback => K::Loopback,
                NetworkInterfaceKind::Other => K::Other,
            },
            addresses: self
                .addresses
                .iter()
                .filter_map(|a| {
                    let (ip, prefix) = a.split_once('/')?;
                    // Scoped IPv6 addresses ("fe80::1%en0") are link-local and never a path.
                    Some((ip.split('%').next()?.parse().ok()?, prefix.parse().ok()?))
                })
                .collect(),
            // Only an IPv4 router identifies a network.
            gateway: self.gateway.parse().ok().filter(std::net::IpAddr::is_ipv4),
            gateway_hw: (!self.gateway_hw.is_empty()).then_some(self.gateway_hw),
            ssid: (!self.ssid.is_empty()).then_some(self.ssid),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CallActionKind {
    Answer,
    Decline,
    HangUp,
    Dial,
}

impl CallActionKind {
    fn from_proto(v: i32) -> Option<Self> {
        use proto::call_action::Kind;
        Some(match Kind::try_from(v).ok()? {
            Kind::Answer => Self::Answer,
            Kind::Decline => Self::Decline,
            Kind::HangUp => Self::HangUp,
            Kind::Dial => Self::Dial,
            Kind::Unspecified => return None,
        })
    }

    fn to_proto(self) -> proto::call_action::Kind {
        use proto::call_action::Kind;
        match self {
            Self::Answer => Kind::Answer,
            Self::Decline => Kind::Decline,
            Self::HangUp => Kind::HangUp,
            Self::Dial => Kind::Dial,
        }
    }
}

// --- phone folders -----------------------------------------------------------------------------

#[derive(Debug, Clone, uniffi::Record)]
pub struct FsEntryData {
    pub name: String,
    pub dir: bool,
    pub size: u64,
    pub modified_ms: i64,
    pub mime: String,
}

impl From<FsEntryData> for proto::FsEntry {
    fn from(e: FsEntryData) -> Self {
        Self {
            name: e.name,
            dir: e.dir,
            size: e.size,
            modified_ms: e.modified_ms,
            mime: e.mime,
        }
    }
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FsBackendError {
    #[error("not found: {detail}")]
    NotFound { detail: String },
    #[error("forbidden: {detail}")]
    Forbidden { detail: String },
    #[error("exists: {detail}")]
    Exists { detail: String },
    #[error("unavailable: {detail}")]
    Unavailable { detail: String },
    #[error("io: {detail}")]
    Io { detail: String },
}

impl From<uniffi::UnexpectedUniFFICallbackError> for FsBackendError {
    fn from(e: uniffi::UnexpectedUniFFICallbackError) -> Self {
        Self::Io { detail: e.reason }
    }
}

impl From<FsBackendError> for brege_core::FsFailure {
    fn from(e: FsBackendError) -> Self {
        use brege_core::FsErrorKind as K;
        let (kind, detail) = match e {
            FsBackendError::NotFound { detail } => (K::NotFound, detail),
            FsBackendError::Forbidden { detail } => (K::Forbidden, detail),
            FsBackendError::Exists { detail } => (K::Exists, detail),
            FsBackendError::Unavailable { detail } => (K::Unavailable, detail),
            FsBackendError::Io { detail } => (K::Io, detail),
        };
        brege_core::FsFailure::new(kind, detail)
    }
}

/// Implemented by the Android shell over the Storage Access Framework. `/` lists the shared
/// folders. `open_*` return a file descriptor whose ownership passes to the core.
#[uniffi::export(foreign)]
pub trait PhoneStorage: Send + Sync {
    fn list(&self, path: String) -> std::result::Result<Vec<FsEntryData>, FsBackendError>;
    fn stat(&self, path: String) -> std::result::Result<FsEntryData, FsBackendError>;
    fn open_read(&self, path: String) -> std::result::Result<i32, FsBackendError>;
    fn open_write(&self, path: String, truncate: bool) -> std::result::Result<i32, FsBackendError>;
    fn mkdir(&self, path: String) -> std::result::Result<FsEntryData, FsBackendError>;
    fn delete(&self, path: String) -> std::result::Result<(), FsBackendError>;
    fn rename(&self, from: String, to: String) -> std::result::Result<(), FsBackendError>;
}

struct StorageAdapter(Arc<dyn PhoneStorage>);

#[cfg(unix)]
fn file_from_fd(fd: i32) -> std::result::Result<std::fs::File, brege_core::FsFailure> {
    use std::os::fd::FromRawFd;
    if fd < 0 {
        return Err(brege_core::FsFailure::new(
            brege_core::FsErrorKind::Io,
            "invalid file descriptor",
        ));
    }
    // SAFETY: the shell detached this descriptor and hands its ownership to us.
    Ok(unsafe { std::fs::File::from_raw_fd(fd) })
}

#[cfg(not(unix))]
fn file_from_fd(_fd: i32) -> std::result::Result<std::fs::File, brege_core::FsFailure> {
    Err(brege_core::FsFailure::new(
        brege_core::FsErrorKind::Unavailable,
        "unsupported platform",
    ))
}

impl brege_core::FsBackend for StorageAdapter {
    fn list(&self, path: &str) -> std::result::Result<Vec<proto::FsEntry>, brege_core::FsFailure> {
        Ok(self
            .0
            .list(path.to_string())?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    fn stat(&self, path: &str) -> std::result::Result<proto::FsEntry, brege_core::FsFailure> {
        Ok(self.0.stat(path.to_string())?.into())
    }

    fn open_read(&self, path: &str) -> std::result::Result<std::fs::File, brege_core::FsFailure> {
        file_from_fd(self.0.open_read(path.to_string())?)
    }

    fn open_write(
        &self,
        path: &str,
        truncate: bool,
    ) -> std::result::Result<std::fs::File, brege_core::FsFailure> {
        file_from_fd(self.0.open_write(path.to_string(), truncate)?)
    }

    fn mkdir(&self, path: &str) -> std::result::Result<proto::FsEntry, brege_core::FsFailure> {
        Ok(self.0.mkdir(path.to_string())?.into())
    }

    fn delete(&self, path: &str) -> std::result::Result<(), brege_core::FsFailure> {
        Ok(self.0.delete(path.to_string())?)
    }

    fn rename(&self, from: &str, to: &str) -> std::result::Result<(), brege_core::FsFailure> {
        Ok(self.0.rename(from.to_string(), to.to_string())?)
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct DriveInfo {
    /// URL to mount; contains a random secret.
    pub url: String,
    pub volume_name: String,
}

// --- callbacks --------------------------------------------------------------------------------

/// Implemented by the shell. Called on a core thread; hop to the UI thread before touching UI.
#[uniffi::export(foreign)]
pub trait EventListener: Send + Sync {
    fn on_event(&self, event: BregeEvent);
}

/// Mac side: receives microphone PCM (16-bit LE mono) from a phone. Called for every 10 ms
/// frame on a core thread; copy the data and return quickly.
#[uniffi::export(foreign)]
pub trait AudioFrameListener: Send + Sync {
    fn on_mic_frame(&self, from: String, seq: u32, pcm: Vec<u8>);
}

struct AudioAdapter(Arc<dyn AudioFrameListener>);

impl brege_core::AudioSink for AudioAdapter {
    fn on_mic_frame(&self, from: DeviceId, seq: u32, pcm: &[u8]) {
        self.0.on_mic_frame(from.to_string(), seq, pcm.to_vec());
    }
}

struct ListenerSink(Arc<dyn EventListener>);

impl EventSink for ListenerSink {
    fn on_event(&self, event: Event) {
        if let Some(event) = convert_event(event) {
            self.0.on_event(event);
        }
    }
}

// --- free functions ---------------------------------------------------------------------------

/// A new random identity seed (32 bytes). Store it in Keychain / Keystore-wrapped storage.
#[uniffi::export]
pub fn generate_identity_seed() -> Result<Vec<u8>> {
    Ok(SecretKey::generate()
        .map_err(|e| BregeError::Failed {
            detail: e.to_string(),
        })?
        .to_seed()
        .to_vec())
}

/// A new random database key (32 bytes).
#[uniffi::export]
pub fn generate_db_key() -> Result<Vec<u8>> {
    generate_identity_seed()
}

/// The device id belonging to an identity seed.
#[uniffi::export]
pub fn device_id_for_seed(seed: Vec<u8>) -> Result<String> {
    let seed: [u8; 32] = seed.try_into().map_err(|_| BregeError::InvalidInput {
        detail: "seed must be 32 bytes".into(),
    })?;
    Ok(SecretKey::from_seed(seed)
        .map_err(|e| BregeError::Failed {
            detail: e.to_string(),
        })?
        .device_id()
        .to_string())
}

// --- node -------------------------------------------------------------------------------------

#[derive(uniffi::Object)]
pub struct BregeNode {
    node: Node,
    #[cfg(feature = "drive")]
    drives: std::sync::Mutex<std::collections::HashMap<String, brege_drive::Drive>>,
}

#[uniffi::export]
impl BregeNode {
    /// Starts the core. Call once per process.
    #[uniffi::constructor]
    pub async fn start(
        options: NodeOptions,
        listener: Arc<dyn EventListener>,
    ) -> Result<Arc<Self>> {
        let to32 = |v: Vec<u8>, what: &str| -> Result<[u8; 32]> {
            v.try_into().map_err(|_| BregeError::InvalidInput {
                detail: format!("{what} must be 32 bytes"),
            })
        };
        let config = NodeConfig {
            name: options.name,
            platform: options.platform.into(),
            app_version: options.app_version,
            identity_seed: to32(options.identity_seed, "identity_seed")?,
            db_path: Some(PathBuf::from(options.db_path)),
            db_key: to32(options.db_key, "db_key")?,
            listen_addr: SocketAddr::from(([0, 0, 0, 0], options.listen_port)),
            download_dir: PathBuf::from(options.download_dir),
            auto_accept_pairing: false,
            restrict_network_until_reported: options.restrict_network_until_reported,
        };
        let sink = Arc::new(ListenerSink(listener));
        let node = on_runtime(async move { Node::start(config, sink).await }).await?;
        Ok(Arc::new(Self {
            node,
            #[cfg(feature = "drive")]
            drives: Default::default(),
        }))
    }

    pub fn device_id(&self) -> String {
        self.node.device_id().to_string()
    }

    pub fn short_id(&self) -> String {
        self.node.device_id().short()
    }

    pub fn listen_port(&self) -> u16 {
        self.node.local_addr().map(|a| a.port()).unwrap_or_default()
    }

    /// Returns the `brege://pair?…` URI to show as a QR code. `addresses` are "ip" or "ip:port".
    pub fn create_pairing_invite(&self, addresses: Vec<String>) -> Result<String> {
        let port = self.listen_port();
        let addrs = addresses
            .iter()
            .map(|a| {
                a.parse::<SocketAddr>()
                    .or_else(|_| {
                        a.parse::<std::net::IpAddr>()
                            .map(|ip| SocketAddr::new(ip, port))
                    })
                    .map_err(|_| BregeError::InvalidInput {
                        detail: format!("bad address {a}"),
                    })
            })
            .collect::<Result<Vec<_>>>()?;
        let _guard = runtime().enter();
        Ok(self.node.create_pairing_invite(addrs)?)
    }

    pub fn cancel_pairing(&self) {
        self.node.cancel_pairing();
    }

    pub fn respond_to_pairing(&self, request_id: u64, accept: bool) {
        self.node.respond_to_pairing(request_id, accept);
    }

    pub async fn pair_with_invite(&self, uri: String) -> Result<Device> {
        let node = self.node.clone();
        Ok(on_runtime(async move { node.pair_with_invite(&uri).await })
            .await?
            .into())
    }

    pub fn devices(&self) -> Result<Vec<Device>> {
        Ok(self.node.devices()?.into_iter().map(Into::into).collect())
    }

    /// The device's current IP address (without port) while it is connected.
    pub fn peer_ip(&self, device_id: String) -> Option<String> {
        let id = parse_id(&device_id).ok()?;
        self.node
            .peer_address(&id)
            .map(|a| a.ip().to_canonical().to_string())
    }

    pub async fn forget_device(&self, device_id: String) -> Result<()> {
        let id = parse_id(&device_id)?;
        let node = self.node.clone();
        Ok(on_runtime(async move { node.forget_device(id).await }).await?)
    }

    /// Bonjour / NSD result: `tokens` is the TXT record's `k` value, `address` "ip:port".
    pub fn address_discovered(&self, tokens: String, address: String) -> Result<()> {
        let addr = address.parse().map_err(|_| BregeError::InvalidInput {
            detail: format!("bad address {address}"),
        })?;
        self.node.address_discovered(&tokens, addr);
        Ok(())
    }

    /// Mac side: the `k` value for the Bonjour TXT record (keyed ids of the paired phones for the
    /// current 15 minutes). Refresh it when it changes.
    pub fn bonjour_tokens(&self) -> String {
        self.node.bonjour_tokens().join(",")
    }

    pub fn network_changed(&self) {
        self.node.network_changed();
    }

    /// The platform's interfaces, on start and after every network change (network privacy).
    pub fn set_network_interfaces(&self, interfaces: Vec<NetworkInterfaceData>) {
        self.node.set_network_interfaces(
            interfaces
                .into_iter()
                .map(NetworkInterfaceData::into_core)
                .collect(),
        );
    }

    /// Mac side: while a hotspot request to `device_id` runs, the Wi‑Fi network it joins may be
    /// used. `ssid`: the hotspot's Wi‑Fi name, or "" when unknown. `pending: false` ends any
    /// request.
    pub fn set_hotspot_pending(&self, device_id: String, ssid: String, pending: bool) {
        let ssid = (!ssid.is_empty()).then_some(ssid);
        match parse_id(&device_id) {
            Ok(id) => self.node.set_hotspot_pending(id, ssid, pending),
            // The device does not matter when a request ends.
            Err(_) if !pending => self
                .node
                .set_hotspot_pending(self.node.device_id(), None, false),
            Err(_) => tracing::warn!("hotspot request for an invalid device id"),
        }
    }

    /// Networks this device is on and tunnels that blocked a paired device.
    pub fn network_paths(&self) -> Vec<NetworkPathData> {
        self.node
            .network_paths()
            .into_iter()
            .map(|p| NetworkPathData {
                fingerprint: p.fingerprint,
                is_vpn: p.is_vpn,
                label: p.label,
                ssid: p.ssid,
                trusted: p.trusted,
                declined: p.declined,
                blocked_device_ids: p.blocked_devices.iter().map(|d| d.to_string()).collect(),
            })
            .collect()
    }

    /// Uses this network or VPN from now on.
    pub fn trust_network(&self, fingerprint: String) -> Result<()> {
        Ok(self.node.decide_network(&fingerprint, true)?)
    }

    /// "Not here": stays silent on this network and does not ask again.
    pub fn decline_network(&self, fingerprint: String) -> Result<()> {
        Ok(self.node.decide_network(&fingerprint, false)?)
    }

    /// Allows a tunnel until the app quits, without remembering it.
    pub fn allow_network_once(&self, fingerprint: String) {
        self.node.allow_network_once(&fingerprint);
    }

    pub fn known_networks(&self) -> Result<Vec<KnownNetworkData>> {
        Ok(self
            .node
            .known_networks()?
            .into_iter()
            .map(|n| KnownNetworkData {
                is_vpn: n.kind == "vpn",
                fingerprint: n.fingerprint,
                label: n.label,
                last_used_ms: n.last_used_ms,
                trusted: n.trusted,
            })
            .collect())
    }

    pub fn forget_network(&self, fingerprint: String) -> Result<()> {
        Ok(self.node.forget_network(&fingerprint)?)
    }

    /// Mac side: interface names to announce Bonjour on.
    pub fn announce_interfaces(&self) -> Vec<String> {
        self.node.announce_interfaces()
    }

    /// Returns true if the clip was sent to at least one device.
    pub fn local_clipboard_changed(&self, clip: ClipData, change_id: u64) -> bool {
        self.node.local_clipboard_changed(clip.into(), change_id)
    }

    /// Phone: mirror a notification. `icon_png` is the app icon; it is only sent when new.
    pub fn post_notification(
        &self,
        notification: NotificationData,
        icon_png: Option<Vec<u8>>,
    ) -> u32 {
        self.node.post_notification(notification.into(), icon_png) as u32
    }

    pub fn remove_notification(&self, key: String) {
        self.node.remove_notification(&key);
    }

    /// Mac: run an action, send a reply, or dismiss a notification on the phone.
    pub fn act_on_notification(
        &self,
        device_id: String,
        key: String,
        act: NotificationActKind,
    ) -> Result<()> {
        let act = proto::NotificationAct {
            key,
            act: Some(match act {
                NotificationActKind::Action { index } => notification_act::Act::ActionIndex(index),
                NotificationActKind::Reply { index, text } => {
                    notification_act::Act::Reply(proto::Reply {
                        action_index: index,
                        text,
                    })
                }
                NotificationActKind::Dismiss => notification_act::Act::Dismiss(true),
            }),
        };
        Ok(self.node.act_on_notification(parse_id(&device_id)?, act)?)
    }

    pub fn recent_notifications(&self, limit: u32) -> Result<Vec<StoredNotification>> {
        Ok(self
            .node
            .recent_notifications(limit)?
            .into_iter()
            .map(|n| StoredNotification {
                device_id: n.device_id.to_string(),
                key: n.key,
                package: n.package,
                app_label: n.app_label,
                title: n.title,
                text: n.text,
                posted_ms: n.posted_at_ms,
                dismissed: n.dismissed,
            })
            .collect())
    }

    pub fn send_status(&self, status: StatusData) -> u32 {
        self.node.send_status(proto::StatusUpdate {
            battery_pct: status.battery_pct,
            charging: status.charging,
            signal_bars: status.signal_bars,
            network_type: status.network_type,
            dnd: status.dnd,
            volume_pct: status.volume_pct,
        }) as u32
    }

    pub fn send_media(&self, media: MediaData) -> u32 {
        self.node.send_media(proto::MediaState {
            app_label: media.app_label,
            title: media.title,
            artist: media.artist,
            playing: media.playing,
            position_ms: media.position_ms,
            duration_ms: media.duration_ms,
        }) as u32
    }

    pub fn send_command(&self, device_id: String, command: CommandKind) -> Result<()> {
        Ok(self
            .node
            .send_command(parse_id(&device_id)?, command.into())?)
    }

    pub fn send_url(&self, device_id: String, url: String, title: String) -> Result<()> {
        Ok(self.node.send_open_request(
            parse_id(&device_id)?,
            proto::OpenActivity {
                kind: proto::open_activity::Kind::Url as i32,
                content: url,
                title,
                app_hint: String::new(),
            },
        )?)
    }

    pub fn send_text(&self, device_id: String, text: String) -> Result<()> {
        Ok(self.node.send_open_request(
            parse_id(&device_id)?,
            proto::OpenActivity {
                kind: proto::open_activity::Kind::Text as i32,
                content: text,
                title: String::new(),
                app_hint: String::new(),
            },
        )?)
    }

    /// Returns the transfer id; progress and completion arrive as events.
    pub async fn send_file(&self, device_id: String, path: String) -> Result<String> {
        let id = parse_id(&device_id)?;
        let node = self.node.clone();
        Ok(
            on_runtime(async move { node.send_file(id, std::path::Path::new(&path)).await })
                .await?,
        )
    }

    // --- messages and calls, Mac side ---

    pub fn request_message_sync(&self, device_id: String) -> Result<()> {
        Ok(self.node.request_message_sync(parse_id(&device_id)?)?)
    }

    /// Mac: the BLE service UUID (e.g. "B7E60002-…") to advertise to ask this phone for its
    /// hotspot. It rotates every 15 minutes.
    pub fn hotspot_request_uuid(&self, device_id: String) -> Result<String> {
        let bytes = self.node.hotspot_request_uuid(parse_id(&device_id)?)?;
        Ok(format_uuid(&bytes))
    }

    /// Phone: BLE service UUIDs to advertise while a paired Mac is not connected (network
    /// privacy plan). They rotate every 15 minutes.
    pub fn presence_uuids(&self) -> Vec<String> {
        self.node.presence_uuids().iter().map(format_uuid).collect()
    }

    /// Mac: the paired phone that advertised this presence UUID, if any.
    pub fn match_presence_uuid(&self, uuid: String) -> Option<String> {
        self.node
            .match_presence(&parse_uuid(&uuid)?)
            .map(|id| id.to_string())
    }

    /// Phone: the paired Mac that advertised this service UUID, if any.
    pub fn match_hotspot_request(&self, uuid: String) -> Option<String> {
        let bytes = parse_uuid(&uuid)?;
        self.node
            .match_hotspot_request(&bytes)
            .ok()
            .flatten()
            .map(|id| id.to_string())
    }

    // --- phone camera ---

    /// Mac: receives camera video from phones.
    pub fn set_video_listener(&self, listener: Arc<dyn VideoPacketListener>) {
        self.node
            .set_video_sink(Some(Arc::new(VideoAdapter(listener))));
    }

    /// Mac: starts (or changes) the phone camera; `start = false` stops it.
    pub fn request_camera(
        &self,
        device_id: String,
        start: bool,
        front: bool,
        torch: bool,
        audio: bool,
    ) -> Result<()> {
        let facing = if front {
            proto::CameraFacing::Front
        } else {
            proto::CameraFacing::Back
        };
        Ok(self.node.request_camera(
            parse_id(&device_id)?,
            proto::CameraRequest {
                start,
                facing: facing as i32,
                torch,
                audio,
            },
        )?)
    }

    /// Phone: reports the camera state to the Mac `to`, or to all connected Macs (`None`).
    pub fn publish_camera_state(&self, state: CameraStateData, to: Option<String>) -> u32 {
        let Ok(to) = to.as_deref().map(parse_id).transpose() else {
            return 0;
        };
        let facing = if state.front {
            proto::CameraFacing::Front
        } else {
            proto::CameraFacing::Back
        };
        self.node.publish_camera_state(
            to,
            proto::CameraState {
                active: state.active,
                codec: state.codec,
                width: state.width,
                height: state.height,
                rotation: state.rotation,
                facing: facing as i32,
                torch: state.torch,
                torch_available: state.torch_available,
                detail: state.detail,
            },
        ) as u32
    }

    /// Phone: opens the video stream to the Mac that asked for the camera.
    pub async fn open_video_stream(&self, device_id: String) -> Result<()> {
        let id = parse_id(&device_id)?;
        let node = self.node.clone();
        Ok(on_runtime(async move { node.open_video_stream(id).await }).await?)
    }

    /// Phone: sends one encoded packet from the encoder thread (not the main thread: it can
    /// wait briefly for config and key frames). Returns false when no stream is open.
    pub fn send_video_packet(&self, flags: u8, pts_us: u64, data: Vec<u8>) -> bool {
        self.node.send_video_packet(flags, pts_us, data)
    }

    pub fn close_video_stream(&self) {
        self.node.close_video_stream();
    }

    /// Mac: asks the phone for its newest photos and screenshots.
    pub fn request_recent_media(&self, device_id: String, limit: u32) -> Result<()> {
        Ok(self
            .node
            .request_recent_media(parse_id(&device_id)?, limit)?)
    }

    /// Phone: answers a request (`device_id`), or pushes a new screenshot to all Macs (`None`).
    pub fn send_recent_media(
        &self,
        device_id: Option<String>,
        items: Vec<MediaItemData>,
        new_screenshot: bool,
        permission_needed: bool,
    ) -> Result<u32> {
        let to = device_id.as_deref().map(parse_id).transpose()?;
        let items = items.into_iter().map(Into::into).collect();
        Ok(self
            .node
            .send_recent_media(to, items, new_screenshot, permission_needed)? as u32)
    }

    /// Mac: asks the phone which apps are installed.
    pub fn request_app_inventory(&self, device_id: String, include_system: bool) -> Result<()> {
        Ok(self
            .node
            .request_app_inventory(parse_id(&device_id)?, include_system)?)
    }

    /// Mac: uninstall an app or open one of its settings pages; the phone asks the user.
    pub fn send_app_action(
        &self,
        device_id: String,
        kind: AppActionKind,
        package: String,
    ) -> Result<()> {
        Ok(self
            .node
            .send_app_action(parse_id(&device_id)?, kind.to_proto(), &package)?)
    }

    /// Mac: asks for one app's notification settings.
    pub fn request_notification_settings(&self, device_id: String, package: String) -> Result<()> {
        Ok(self
            .node
            .request_notification_settings(parse_id(&device_id)?, &package)?)
    }

    /// Mac: changes how loud one notification category of an app is (0 off … 5 urgent).
    pub fn update_notification_channel(
        &self,
        device_id: String,
        package: String,
        channel_id: String,
        importance: u32,
    ) -> Result<()> {
        Ok(self.node.update_notification_channel(
            parse_id(&device_id)?,
            &package,
            &channel_id,
            importance,
        )?)
    }

    /// Phone: answers with the installed apps.
    pub fn send_app_inventory(
        &self,
        device_id: String,
        apps: Vec<InstalledAppData>,
        usage_access: bool,
    ) -> Result<()> {
        Ok(self.node.send_app_inventory(
            parse_id(&device_id)?,
            apps.into_iter().map(Into::into).collect(),
            usage_access,
        )?)
    }

    /// Phone: answers with one app's notification settings.
    pub fn send_notification_settings(
        &self,
        device_id: String,
        settings: NotificationSettingsData,
    ) -> Result<()> {
        Ok(self
            .node
            .send_notification_settings(parse_id(&device_id)?, settings.into())?)
    }

    /// Mac: cached notifications whose app, title or text contain `query`.
    pub fn search_notifications(
        &self,
        query: String,
        limit: u32,
    ) -> Result<Vec<StoredNotification>> {
        Ok(self
            .node
            .search_notifications(&query, limit)?
            .into_iter()
            .map(|n| StoredNotification {
                device_id: n.device_id.to_string(),
                key: n.key,
                package: n.package,
                app_label: n.app_label,
                title: n.title,
                text: n.text,
                posted_ms: n.posted_at_ms,
                dismissed: n.dismissed,
            })
            .collect())
    }

    /// Mac: asks for one page of the photo library; `beforeMs` 0 starts at the newest.
    pub fn request_media_library(
        &self,
        device_id: String,
        before_ms: i64,
        limit: u32,
        album: String,
        include_videos: bool,
    ) -> Result<()> {
        Ok(self.node.request_media_library(
            parse_id(&device_id)?,
            before_ms,
            limit,
            &album,
            include_videos,
        )?)
    }

    /// Mac: asks the phone for the albums of its library.
    pub fn request_media_albums(&self, device_id: String, include_videos: bool) -> Result<()> {
        Ok(self
            .node
            .request_media_albums(parse_id(&device_id)?, include_videos)?)
    }

    /// Phone: answers one Mac with a page of the library.
    pub fn send_media_library_page(
        &self,
        device_id: String,
        items: Vec<MediaItemData>,
        end: bool,
        album: String,
        permission_needed: bool,
        partial_access: bool,
    ) -> Result<()> {
        Ok(self.node.send_media_library_page(
            parse_id(&device_id)?,
            items.into_iter().map(Into::into).collect(),
            end,
            &album,
            permission_needed,
            partial_access,
        )?)
    }

    /// Phone: answers one Mac with the albums of its library.
    pub fn send_media_albums(&self, device_id: String, albums: Vec<MediaAlbumData>) -> Result<()> {
        Ok(self.node.send_media_albums(
            parse_id(&device_id)?,
            albums.into_iter().map(Into::into).collect(),
        )?)
    }

    /// Mac: asks for the full file of a photo; the phone answers like a capture request.
    pub fn request_media(&self, device_id: String, media_id: String) -> Result<String> {
        Ok(self.node.request_media(parse_id(&device_id)?, &media_id)?)
    }

    /// Phone: publishes or updates an ongoing activity; returns how many Macs received it.
    pub fn publish_ongoing_activity(&self, activity: OngoingActivityData) -> u32 {
        self.node.publish_ongoing_activity(activity.into()) as u32
    }

    pub fn end_ongoing_activity(&self, key: String) -> u32 {
        self.node.end_ongoing_activity(&key) as u32
    }

    /// Mac: asks the phone to take a photo or scan a document; returns the request id.
    pub fn request_capture(&self, device_id: String, kind: CaptureKind) -> Result<String> {
        let kind = match kind {
            CaptureKind::Photo => proto::capture_request::Kind::Photo,
            CaptureKind::Document => proto::capture_request::Kind::Document,
        };
        Ok(self.node.request_capture(parse_id(&device_id)?, kind)?)
    }

    /// Phone: answers a `CaptureRequested` event. `transfer_id` is set for `Sending`.
    pub fn send_capture_result(
        &self,
        device_id: String,
        request_id: String,
        status: CaptureStatus,
        transfer_id: String,
        detail: String,
    ) -> Result<()> {
        let status = match status {
            CaptureStatus::Sending => proto::capture_result::Status::Sending,
            CaptureStatus::Cancelled => proto::capture_result::Status::Cancelled,
            CaptureStatus::Failed => proto::capture_result::Status::Failed,
        };
        Ok(self.node.send_capture_result(
            parse_id(&device_id)?,
            proto::CaptureResult {
                request_id,
                status: status as i32,
                transfer_id,
                detail,
            },
        )?)
    }

    /// Mac: asks the phone for its launchable apps; they arrive as `AppListReceived`.
    pub fn request_app_list(&self, device_id: String) -> Result<()> {
        Ok(self.node.request_app_list(parse_id(&device_id)?)?)
    }

    /// Phone: answers an `AppListRequested` event.
    pub fn send_app_list(&self, device_id: String, apps: Vec<PhoneAppData>) -> Result<()> {
        let apps = apps
            .into_iter()
            .map(|a| proto::PhoneApp {
                package: a.package,
                label: a.label,
                icon_png: a.icon_png,
            })
            .collect();
        Ok(self.node.send_app_list(parse_id(&device_id)?, apps)?)
    }

    /// Mac: whether a string is a plain Android package name (safe to pass to the screen server).
    pub fn is_valid_package_name(&self, package: String) -> bool {
        brege_core::apps::valid_package(&package)
    }

    /// Mac: asks the phone for contact photos (at most 50 addresses per call).
    pub fn request_contact_photos(&self, device_id: String, addresses: Vec<String>) -> Result<()> {
        Ok(self
            .node
            .request_contact_photos(parse_id(&device_id)?, addresses)?)
    }

    /// Phone: answers a `ContactPhotosRequested` event.
    pub fn send_contact_photos(
        &self,
        device_id: String,
        photos: Vec<ContactPhotoData>,
    ) -> Result<()> {
        let photos = photos
            .into_iter()
            .map(|p| proto::ContactPhoto {
                address: p.address,
                jpeg: p.jpeg,
            })
            .collect();
        Ok(self
            .node
            .send_contact_photos(parse_id(&device_id)?, photos)?)
    }

    pub fn request_message_history(
        &self,
        device_id: String,
        thread_id: String,
        before_ms: i64,
        limit: u32,
    ) -> Result<()> {
        Ok(self.node.request_message_history(
            parse_id(&device_id)?,
            &thread_id,
            before_ms,
            limit,
        )?)
    }

    pub fn message_threads(&self, device_id: String, limit: u32) -> Result<Vec<ThreadData>> {
        Ok(self
            .node
            .message_threads(parse_id(&device_id)?, limit)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Cached messages, oldest first. Pass `i64::MAX` as `before_ms` for the newest page.
    pub fn thread_messages(
        &self,
        device_id: String,
        thread_id: String,
        before_ms: i64,
        limit: u32,
    ) -> Result<Vec<MessageData>> {
        Ok(self
            .node
            .thread_messages(parse_id(&device_id)?, &thread_id, before_ms, limit)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn mark_thread_read(&self, device_id: String, thread_id: String) -> Result<()> {
        Ok(self
            .node
            .mark_thread_read(parse_id(&device_id)?, &thread_id)?)
    }

    pub fn sims(&self, device_id: String) -> Result<Vec<SimData>> {
        Ok(self
            .node
            .sims(parse_id(&device_id)?)?
            .into_iter()
            .map(|s| SimData {
                sub_id: s.sub_id,
                label: s.label,
                slot: s.slot,
            })
            .collect())
    }

    /// Returns the client id used by the matching `MessageSendStatus` event.
    pub fn send_message(
        &self,
        device_id: String,
        thread_id: String,
        address: String,
        body: String,
        sub_id: i32,
    ) -> Result<String> {
        Ok(self
            .node
            .send_message(parse_id(&device_id)?, &thread_id, &address, &body, sub_id)?)
    }

    /// Mac: changes a control on the phone (torch, sound, Do Not Disturb, clear notifications).
    pub fn send_phone_control(
        &self,
        device_id: String,
        kind: ControlKind,
        value: i32,
        stream: Option<VolumeStream>,
    ) -> Result<()> {
        let control = proto::PhoneControl {
            kind: kind.to_proto() as i32,
            value,
            stream: stream
                .map(|s| s.to_proto() as i32)
                .unwrap_or(proto::phone_control::Stream::Unspecified as i32),
        };
        Ok(self
            .node
            .send_phone_control(parse_id(&device_id)?, control)?)
    }

    /// Phone: tells the Macs where the controls stand.
    pub fn publish_control_state(&self, state: PhoneControlsData) -> u32 {
        self.node.publish_control_state(state.into()) as u32
    }

    /// Cached recent calls, newest first.
    pub fn recent_calls(&self, device_id: String, limit: u32) -> Result<Vec<CallLogData>> {
        Ok(self
            .node
            .recent_calls(parse_id(&device_id)?, limit)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Asks the phone for calls that are newer than the cache.
    pub fn request_call_log(&self, device_id: String, limit: u32) -> Result<()> {
        Ok(self.node.request_call_log(parse_id(&device_id)?, limit)?)
    }

    /// Asks the phone for calls older than the oldest cached one.
    pub fn request_older_calls(&self, device_id: String, limit: u32) -> Result<()> {
        Ok(self
            .node
            .request_older_calls(parse_id(&device_id)?, limit)?)
    }

    pub fn call_action(
        &self,
        device_id: String,
        action: CallActionKind,
        number: String,
        sub_id: i32,
    ) -> Result<()> {
        Ok(self
            .node
            .call_action(parse_id(&device_id)?, action.to_proto(), &number, sub_id)?)
    }

    // --- messages and calls, phone side ---

    pub async fn publish_message_threads(&self, threads: Vec<ThreadData>) -> u32 {
        let node = self.node.clone();
        let threads = threads.into_iter().map(Into::into).collect();
        on_runtime(async move { node.publish_message_threads(threads).await }).await as u32
    }

    pub async fn publish_messages(&self, messages: Vec<MessageData>, history: bool) -> u32 {
        let node = self.node.clone();
        let messages = messages.into_iter().map(Into::into).collect();
        on_runtime(async move { node.publish_messages(messages, history).await }).await as u32
    }

    pub fn publish_send_status(
        &self,
        device_id: String,
        client_id: String,
        status: MessageStatus,
        error: String,
    ) -> Result<()> {
        Ok(self.node.publish_send_status(
            parse_id(&device_id)?,
            proto::SmsSendStatus {
                client_id,
                status: status.to_proto(),
                error,
            },
        )?)
    }

    pub fn publish_sims(&self, sims: Vec<SimData>) -> u32 {
        self.node.publish_sims(
            sims.into_iter()
                .map(|s| proto::Sim {
                    sub_id: s.sub_id,
                    label: s.label,
                    slot: s.slot,
                })
                .collect(),
        ) as u32
    }

    /// Phone: sends recent calls to every connected Mac.
    pub fn publish_call_log(&self, entries: Vec<CallLogData>) -> u32 {
        self.node
            .publish_call_log(entries.into_iter().map(Into::into).collect(), false) as u32
    }

    /// Phone: answers one Mac's request for recent calls.
    pub fn send_call_log(
        &self,
        device_id: String,
        entries: Vec<CallLogData>,
        history: bool,
    ) -> Result<()> {
        Ok(self.node.send_call_log(
            parse_id(&device_id)?,
            entries.into_iter().map(Into::into).collect(),
            history,
        )?)
    }

    pub fn publish_call_state(&self, call: CallData) -> u32 {
        self.node.publish_call_state(call.into()) as u32
    }

    // --- phone as microphone ---

    pub fn set_audio_listener(&self, listener: Arc<dyn AudioFrameListener>) {
        self.node
            .set_audio_sink(Some(Arc::new(AudioAdapter(listener))));
    }

    pub fn clear_audio_listener(&self) {
        self.node.set_audio_sink(None);
    }

    /// Phone side: one PCM frame (16-bit LE mono) to the Mac `to`, or to all connected Macs
    /// (`None`). Returns the number of Macs it was sent to.
    pub fn send_mic_frame(&self, pcm: Vec<u8>, to: Option<String>) -> u32 {
        let Ok(to) = to.as_deref().map(parse_id).transpose() else {
            return 0;
        };
        self.node.send_mic_frame(to, &pcm) as u32
    }

    /// Phone side: largest PCM frame that fits in one datagram, 0 when not connected.
    pub fn max_mic_frame_bytes(&self) -> u32 {
        self.node.max_mic_frame_bytes().unwrap_or(0) as u32
    }

    /// Phone side: the microphone state for the Mac `to`, or for all connected Macs (`None`).
    pub fn publish_mic_state(
        &self,
        active: bool,
        sample_rate: u32,
        detail: String,
        to: Option<String>,
    ) -> u32 {
        let Ok(to) = to.as_deref().map(parse_id).transpose() else {
            return 0;
        };
        self.node
            .publish_mic_state(to, active, sample_rate, &detail) as u32
    }

    // --- phone folders ---

    /// Phone side: serve the folders the user shared.
    pub fn set_phone_storage(&self, storage: Arc<dyn PhoneStorage>) {
        self.node
            .set_fs_backend(Some(Arc::new(StorageAdapter(storage))));
    }

    pub fn clear_phone_storage(&self) {
        self.node.set_fs_backend(None);
    }

    /// Mac side: lists a folder on the phone (also used to check whether folders are shared).
    pub async fn phone_folder(&self, device_id: String, path: String) -> Result<Vec<FsEntryData>> {
        let id = parse_id(&device_id)?;
        let node = self.node.clone();
        let entries = on_runtime(async move { node.fs_list(id, &path).await }).await?;
        Ok(entries
            .into_iter()
            .map(|e| FsEntryData {
                name: e.name,
                dir: e.dir,
                size: e.size,
                modified_ms: e.modified_ms,
                mime: e.mime,
            })
            .collect())
    }

    pub async fn shutdown(&self) {
        let node = self.node.clone();
        on_runtime(async move { node.shutdown().await }).await;
    }
}

/// Mac only: the phone drive.
#[cfg(feature = "drive")]
#[uniffi::export]
impl BregeNode {
    /// Mac side: starts (or returns) the local WebDAV drive for a phone.
    pub async fn start_phone_drive(
        &self,
        device_id: String,
        volume_name: String,
    ) -> Result<DriveInfo> {
        if let Some(drive) = self.drives.lock().unwrap().get(&device_id) {
            return Ok(DriveInfo {
                url: drive.url().to_string(),
                volume_name: drive.volume_name().to_string(),
            });
        }
        let id = parse_id(&device_id)?;
        let node = self.node.clone();
        let drive =
            on_runtime(async move { brege_drive::Drive::start(node, id, &volume_name).await })
                .await
                .map_err(|e| BregeError::Failed {
                    detail: e.to_string(),
                })?;
        let info = DriveInfo {
            url: drive.url().to_string(),
            volume_name: drive.volume_name().to_string(),
        };
        self.drives.lock().unwrap().insert(device_id, drive);
        Ok(info)
    }

    pub fn stop_phone_drive(&self, device_id: String) {
        self.drives.lock().unwrap().remove(&device_id);
    }
}

fn parse_uuid(uuid: &str) -> Option<[u8; 16]> {
    let hex: Vec<u8> = uuid.bytes().filter(u8::is_ascii_hexdigit).collect();
    if hex.len() != 32 {
        return None;
    }
    let mut bytes = [0u8; 16];
    for (i, pair) in hex.chunks(2).enumerate() {
        bytes[i] = u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok()?;
    }
    Some(bytes)
}

fn format_uuid(b: &[u8; 16]) -> String {
    let hex: String = b.iter().map(|x| format!("{x:02X}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seed_and_id() {
        let seed = generate_identity_seed().unwrap();
        assert_eq!(seed.len(), 32);
        let id = device_id_for_seed(seed.clone()).unwrap();
        assert_eq!(id, device_id_for_seed(seed).unwrap());
        assert!(device_id_for_seed(vec![1, 2]).is_err());
    }
}
