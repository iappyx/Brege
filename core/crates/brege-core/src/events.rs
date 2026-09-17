use std::path::PathBuf;

use brege_features::clipboard::Clip;
use brege_features::open_request::OpenRequest;
use brege_identity::DeviceId;
use brege_proto::v1 as proto;

use crate::DeviceInfo;

/// Everything the core reports to the shell. Delivered on core threads; shells hop to their UI thread.
#[derive(Debug, Clone)]
// Events are moved to the sink once; boxing notification posts would not save anything.
#[allow(clippy::large_enum_variant)]
pub enum Event {
    /// Someone scanned our invite and proved the token; the user must confirm.
    PairingRequested {
        request_id: u64,
        device_id: DeviceId,
        name: String,
        platform: proto::Platform,
    },
    /// Phone side: the Mac was reached and is asking its user to confirm.
    PairingWaitingForConfirmation {
        name: String,
    },
    DevicePaired {
        device: DeviceInfo,
    },
    DeviceForgotten {
        device_id: DeviceId,
    },
    PeerConnected {
        device_id: DeviceId,
        name: String,
    },
    PeerDisconnected {
        device_id: DeviceId,
    },
    /// Trusted or blocked networks and tunnels changed (network privacy plan).
    NetworkPathsChanged,
    ClipboardReceived {
        from: DeviceId,
        clip: Clip,
    },
    NotificationPosted {
        from: DeviceId,
        post: proto::NotificationPost,
    },
    NotificationRemoved {
        from: DeviceId,
        key: String,
    },
    NotificationAction {
        from: DeviceId,
        act: proto::NotificationAct,
    },
    StatusUpdated {
        from: DeviceId,
        status: proto::StatusUpdate,
    },
    MediaUpdated {
        from: DeviceId,
        media: proto::MediaState,
    },
    OpenRequestReceived {
        from: DeviceId,
        request: OpenRequest,
    },
    CommandReceived {
        from: DeviceId,
        command: proto::command::Kind,
    },
    TransferOffered {
        from: DeviceId,
        id: String,
        name: String,
        size: u64,
    },
    TransferProgress {
        peer: DeviceId,
        id: String,
        bytes: u64,
        total: u64,
        incoming: bool,
    },
    TransferCompleted {
        peer: DeviceId,
        id: String,
        path: PathBuf,
        incoming: bool,
    },
    TransferFailed {
        peer: DeviceId,
        id: String,
        reason: String,
        incoming: bool,
    },

    // --- Messages and calls, Mac side ----------------
    /// Cached threads or messages changed; `new_incoming` counts newly arrived incoming messages.
    MessagesUpdated {
        from: DeviceId,
        thread_ids: Vec<String>,
        new_incoming: u32,
    },
    SmsSendStatus {
        from: DeviceId,
        status: proto::SmsSendStatus,
    },
    SimsUpdated {
        from: DeviceId,
        sims: Vec<proto::Sim>,
    },
    CallStateChanged {
        from: DeviceId,
        call: proto::CallState,
    },
    /// Cached recent calls changed; `new_missed` counts newly arrived missed calls.
    CallLogUpdated {
        from: DeviceId,
        new_missed: u32,
    },
    MicStateChanged {
        from: DeviceId,
        state: proto::MicState,
    },
    /// Mac side: the phone's torch, sound and Do Not Disturb state.
    PhoneControlStateChanged {
        from: DeviceId,
        state: proto::PhoneControlState,
    },
    CameraRequested {
        from: DeviceId,
        request: proto::CameraRequest,
    },
    CameraStateChanged {
        from: DeviceId,
        state: proto::CameraState,
    },
    RecentMediaReceived {
        from: DeviceId,
        items: Vec<proto::MediaItem>,
        new_screenshot: bool,
        permission_needed: bool,
    },
    RecentMediaRequested {
        from: DeviceId,
        limit: u32,
    },
    /// Mac side: one page of the phone's photo library.
    MediaLibraryPageReceived {
        from: DeviceId,
        page: proto::MediaLibraryPage,
    },
    /// Mac side: the albums of the phone's library.
    MediaAlbumsReceived {
        from: DeviceId,
        albums: Vec<proto::MediaAlbum>,
    },
    /// Phone side: a Mac asks for a page of the library. Already clamped.
    MediaLibraryRequested {
        from: DeviceId,
        request: proto::MediaLibraryRequest,
    },
    /// Phone side: a Mac asks for the albums.
    MediaAlbumsRequested {
        from: DeviceId,
        include_videos: bool,
    },
    /// Mac side: the phone's installed apps.
    AppInventoryReceived {
        from: DeviceId,
        inventory: proto::AppInventory,
    },
    /// Mac side: the notification settings of one app on the phone.
    NotificationSettingsReceived {
        from: DeviceId,
        settings: proto::NotificationSettings,
    },
    /// Phone side: a Mac asks for the installed apps.
    AppInventoryRequested {
        from: DeviceId,
        include_system: bool,
    },
    /// Phone side: a Mac asks to uninstall an app or open its settings.
    AppActionRequested {
        from: DeviceId,
        action: proto::AppAction,
    },
    /// Phone side: a Mac asks for an app's notification settings.
    NotificationSettingsRequested {
        from: DeviceId,
        package: String,
    },
    /// Phone side: a Mac changes one notification channel.
    NotificationChannelUpdateRequested {
        from: DeviceId,
        update: proto::NotificationChannelUpdate,
    },
    /// Already validated media id; answer with a capture result.
    MediaFetchRequested {
        from: DeviceId,
        request_id: String,
        media_id: String,
    },
    OngoingActivityUpdated {
        from: DeviceId,
        activity: proto::OngoingActivity,
    },
    OngoingActivityEnded {
        from: DeviceId,
        key: String,
    },
    CaptureResultReceived {
        from: DeviceId,
        result: proto::CaptureResult,
    },
    /// Already validated (known kind, plausible request id).
    CaptureRequested {
        from: DeviceId,
        request: proto::CaptureRequest,
    },
    AppListReceived {
        from: DeviceId,
        apps: Vec<proto::PhoneApp>,
    },
    AppListRequested {
        from: DeviceId,
    },
    /// Photos too large for [`brege_features::messages::MAX_PHOTO_BYTES`] arrive empty.
    ContactPhotosReceived {
        from: DeviceId,
        photos: Vec<proto::ContactPhoto>,
    },

    // --- Messages and calls, phone side ---
    SmsSyncRequested {
        from: DeviceId,
        request: proto::SmsSyncRequest,
    },
    SmsHistoryRequested {
        from: DeviceId,
        request: proto::SmsHistoryRequest,
    },
    /// Already validated (`brege_features::messages::validate_send`).
    SmsSendRequested {
        from: DeviceId,
        send: proto::SmsSend,
    },
    /// Addresses already sanitized.
    ContactPhotosRequested {
        from: DeviceId,
        addresses: Vec<String>,
    },
    /// Already validated.
    CallActionRequested {
        from: DeviceId,
        action: proto::CallAction,
    },
    CallLogRequested {
        from: DeviceId,
        request: proto::CallLogRequest,
    },
    /// Phone side: already validated and clamped.
    PhoneControlRequested {
        from: DeviceId,
        control: proto::PhoneControl,
    },
}

pub trait EventSink: Send + Sync + 'static {
    fn on_event(&self, event: Event);
}
