//! Dispatches control messages from a peer to feature logic and shell events.

use std::time::Instant;

use brege_features::clipboard::Clip;
use brege_features::open_request;
use brege_identity::DeviceId;
use brege_proto::v1::{self as proto, envelope::Payload};
use brege_store::NotificationRecord;

use crate::node::Inner;
use crate::{Event, messaging, session, transfers};

pub(crate) async fn dispatch(inner: &std::sync::Arc<Inner>, from: DeviceId, payload: Payload) {
    let Some(payload) = messaging::dispatch(inner, from, payload) else {
        return;
    };
    match payload {
        Payload::Hello(_) | Payload::Ping(_) => {}
        Payload::Clipboard(msg) => {
            let Some(clip) = Clip::from_proto(msg) else {
                tracing::debug!("dropping invalid clipboard message");
                return;
            };
            inner
                .clipboard
                .lock()
                .unwrap()
                .on_remote(&clip, Instant::now());
            inner.emit(Event::ClipboardReceived { from, clip });
        }
        Payload::Notification(post) => {
            let record = NotificationRecord {
                device_id: from,
                key: post.key.clone(),
                package: post.package.clone(),
                app_label: post.app_label.clone(),
                title: post.title.clone(),
                text: post.text.clone(),
                // The phone's clock may be ahead; a future time would outlive the retention.
                posted_at_ms: post.posted_ms.min(crate::now_ms()),
                dismissed: false,
            };
            if let Err(e) = inner.store.lock().unwrap().upsert_notification(&record) {
                tracing::warn!("failed to store notification: {e}");
            }
            inner.emit(Event::NotificationPosted { from, post });
        }
        Payload::NotificationRemoved(msg) => {
            let _ = inner
                .store
                .lock()
                .unwrap()
                .dismiss_notification(&from, &msg.key);
            inner.emit(Event::NotificationRemoved { from, key: msg.key });
        }
        Payload::NotificationAct(act) => inner.emit(Event::NotificationAction { from, act }),
        Payload::Status(status) => inner.emit(Event::StatusUpdated { from, status }),
        Payload::Media(media) => inner.emit(Event::MediaUpdated { from, media }),
        Payload::OpenActivity(activity) => match open_request::classify(activity) {
            Some(request) => inner.emit(Event::OpenRequestReceived { from, request }),
            None => tracing::debug!("dropping invalid open request"),
        },
        Payload::Command(cmd) => {
            if let Ok(command) = proto::command::Kind::try_from(cmd.kind)
                && command != proto::command::Kind::Unspecified
            {
                inner.emit(Event::CommandReceived { from, command });
            }
        }
        Payload::TransferOffer(offer) => transfers::handle_offer(inner, from, offer),
        Payload::TransferAccept(accept) => {
            if let Some(tx) = inner.pending_accepts.lock().unwrap().remove(&accept.id) {
                let _ = tx.send(accept);
            }
        }
        Payload::TransferCancel(cancel) => transfers::handle_cancel(inner, from, cancel),
        Payload::Unpair(_) => {
            tracing::info!(peer = ?from, "peer unpaired us");
            session::forget_locally(inner, &from);
        }
        Payload::MicState(state) => inner.emit(Event::MicStateChanged { from, state }),
        Payload::CameraRequest(request) => inner.emit(Event::CameraRequested { from, request }),
        Payload::CameraState(mut state) => {
            crate::apps::truncate(&mut state.codec, 16);
            crate::apps::truncate(&mut state.detail, 300);
            inner.emit(Event::CameraStateChanged { from, state });
        }
        Payload::RecentMediaRequest(request) => inner.emit(Event::RecentMediaRequested {
            from,
            limit: request.limit.clamp(1, crate::apps::MAX_MEDIA_ITEMS as u32),
        }),
        Payload::RecentMedia(list) => inner.emit(Event::RecentMediaReceived {
            from,
            items: crate::apps::sanitize_media(list.items),
            new_screenshot: list.new_screenshot,
            permission_needed: list.permission_needed,
        }),
        Payload::MediaFetch(fetch) => {
            if crate::apps::valid_request_id(&fetch.request_id)
                && crate::apps::valid_media_id(&fetch.media_id)
            {
                inner.emit(Event::MediaFetchRequested {
                    from,
                    request_id: fetch.request_id,
                    media_id: fetch.media_id,
                });
            }
        }
        Payload::OngoingActivity(activity) => {
            if let Some(activity) = crate::apps::sanitize_ongoing_activity(activity) {
                inner.emit(Event::OngoingActivityUpdated { from, activity });
            }
        }
        Payload::OngoingActivityEnded(ended) => inner.emit(Event::OngoingActivityEnded {
            from,
            key: ended.key,
        }),
        Payload::CaptureRequest(request) => {
            let kind_known = matches!(
                proto::capture_request::Kind::try_from(request.kind),
                Ok(proto::capture_request::Kind::Photo | proto::capture_request::Kind::Document)
            );
            if kind_known && crate::apps::valid_request_id(&request.request_id) {
                inner.emit(Event::CaptureRequested { from, request });
            }
        }
        Payload::CaptureResult(result) => {
            if crate::apps::valid_request_id(&result.request_id) {
                inner.emit(Event::CaptureResultReceived { from, result });
            }
        }
        Payload::AppListRequest(_) => inner.emit(Event::AppListRequested { from }),
        Payload::AppList(list) => inner.emit(Event::AppListReceived {
            from,
            apps: crate::apps::sanitize(list.apps),
        }),
        Payload::FsChanged(_) => {
            // Not implemented yet; ignored (forward compatible by design).
        }
        // Handled by `messaging::dispatch` above.
        Payload::SmsSyncRequest(_)
        | Payload::SmsHistoryRequest(_)
        | Payload::SmsThreads(_)
        | Payload::SmsMessages(_)
        | Payload::SmsSend(_)
        | Payload::SmsSendStatus(_)
        | Payload::Sims(_)
        | Payload::CallState(_)
        | Payload::CallAction(_)
        | Payload::ContactPhotoRequest(_)
        | Payload::ContactPhotos(_) => {}
    }
}
