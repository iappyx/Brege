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
        Payload::MediaLibraryRequest(mut request) => {
            request.limit = request
                .limit
                .clamp(1, crate::apps::MAX_LIBRARY_ITEMS as u32);
            crate::apps::truncate(&mut request.album, crate::apps::MAX_ALBUM_NAME);
            inner.emit(Event::MediaLibraryRequested { from, request });
        }
        Payload::MediaLibraryPage(mut page) => {
            page.items =
                crate::apps::sanitize_media_items(page.items, crate::apps::MAX_LIBRARY_ITEMS);
            crate::apps::truncate(&mut page.album, crate::apps::MAX_ALBUM_NAME);
            inner.emit(Event::MediaLibraryPageReceived { from, page });
        }
        Payload::MediaAlbumsRequest(request) => inner.emit(Event::MediaAlbumsRequested {
            from,
            include_videos: request.include_videos,
        }),
        Payload::MediaAlbums(list) => inner.emit(Event::MediaAlbumsReceived {
            from,
            albums: crate::apps::sanitize_albums(list.albums),
        }),
        Payload::AppInventoryRequest(request) => inner.emit(Event::AppInventoryRequested {
            from,
            include_system: request.include_system,
        }),
        Payload::AppInventory(mut inventory) => {
            inventory.apps.truncate(crate::apps::MAX_APPS);
            for app in &mut inventory.apps {
                crate::apps::truncate(&mut app.label, 120);
                crate::apps::truncate(&mut app.version, 40);
                crate::apps::truncate(&mut app.package, 255);
                if app.icon_png.len() > crate::apps::MAX_ICON_BYTES {
                    app.icon_png.clear();
                }
            }
            inner.emit(Event::AppInventoryReceived { from, inventory });
        }
        Payload::AppAction(action) => {
            if crate::apps::valid_package(&action.package) {
                inner.emit(Event::AppActionRequested { from, action });
            }
        }
        Payload::NotificationSettingsRequest(request) => {
            if crate::apps::valid_package(&request.package) {
                inner.emit(Event::NotificationSettingsRequested {
                    from,
                    package: request.package,
                });
            }
        }
        Payload::NotificationSettings(mut settings) => {
            settings.channels.truncate(crate::apps::MAX_CHANNELS);
            for channel in &mut settings.channels {
                crate::apps::truncate(&mut channel.name, 120);
                crate::apps::truncate(&mut channel.group, 120);
                crate::apps::truncate(&mut channel.id, 255);
            }
            crate::apps::truncate(&mut settings.app_label, 120);
            inner.emit(Event::NotificationSettingsReceived { from, settings });
        }
        Payload::SensorsRequest(request) => inner.emit(Event::ConditionsRequested {
            from,
            history_hours: request.history_hours.clamp(1, crate::apps::MAX_HISTORY_HOURS),
            watch_motion: request.watch_motion,
        }),
        Payload::Conditions(mut conditions) => {
            conditions
                .history
                .truncate(crate::apps::MAX_PRESSURE_POINTS);
            inner.emit(Event::ConditionsChanged { from, conditions });
        }
        Payload::NotificationChannelUpdate(update) => {
            if crate::apps::valid_package(&update.package) && !update.channel_id.is_empty() {
                inner.emit(Event::NotificationChannelUpdateRequested { from, update });
            }
        }
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
        | Payload::CallLogRequest(_)
        | Payload::CallLog(_)
        | Payload::PhoneControl(_)
        | Payload::PhoneControlState(_)
        | Payload::ContactPhotoRequest(_)
        | Payload::ContactPhotos(_) => {}
    }
}
