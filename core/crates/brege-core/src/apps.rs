//! App list for the phone-screen app launcher.

use brege_proto::v1 as proto;

pub const MAX_APPS: usize = 500;
pub const MAX_ICON_BYTES: usize = 32 * 1024;

/// Drops malformed entries and enforces size limits, on both the sending and receiving side.
pub(crate) fn sanitize(apps: Vec<proto::PhoneApp>) -> Vec<proto::PhoneApp> {
    apps.into_iter()
        .filter(|a| valid_package(&a.package) && a.label.len() <= 200)
        .take(MAX_APPS)
        .map(|mut a| {
            if a.icon_png.len() > MAX_ICON_BYTES {
                a.icon_png.clear();
            }
            a
        })
        .collect()
}

/// Keeps an ongoing activity within size limits; `None` drops it.
pub(crate) fn sanitize_ongoing_activity(
    mut a: proto::OngoingActivity,
) -> Option<proto::OngoingActivity> {
    if a.key.is_empty() || a.key.len() > 512 {
        return None;
    }
    for text in [&mut a.title, &mut a.text, &mut a.app_label] {
        truncate(text, 1000);
    }
    truncate(&mut a.short_text, 40);
    if a.icon_png.len() > MAX_ICON_BYTES {
        a.icon_png.clear();
    }
    a.actions.truncate(3);
    a.actions
        .iter_mut()
        .for_each(|action| truncate(&mut action.label, 100));
    a.progress_max = a.progress_max.max(0);
    a.progress = a.progress.clamp(0, a.progress_max.max(0));
    Some(a)
}

/// Shortens `text` to at most `max` bytes without splitting a character.
pub(crate) fn truncate(text: &mut String, max: usize) {
    if text.len() > max {
        let mut end = max;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
    }
}

pub const MAX_MEDIA_ITEMS: usize = 12;
pub const MAX_THUMBNAIL_BYTES: usize = 64 * 1024;

pub(crate) fn sanitize_media(items: Vec<proto::MediaItem>) -> Vec<proto::MediaItem> {
    items
        .into_iter()
        .filter(|m| valid_media_id(&m.id))
        .take(MAX_MEDIA_ITEMS)
        .map(|mut m| {
            truncate(&mut m.name, 255);
            truncate(&mut m.mime, 100);
            if m.thumbnail_jpeg.len() > MAX_THUMBNAIL_BYTES {
                m.thumbnail_jpeg.clear();
            }
            m
        })
        .collect()
}

/// MediaStore ids are decimal numbers.
pub fn valid_media_id(id: &str) -> bool {
    (1..=20).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_digit())
}

/// Request ids for Import from phone: 8–64 lowercase hex characters.
pub fn valid_request_id(id: &str) -> bool {
    (8..=64).contains(&id.len())
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// Android package names: dot-separated segments of letters, digits and underscores.
pub fn valid_package(package: &str) -> bool {
    package.len() <= 255
        && package.contains('.')
        && package.split('.').all(|segment| {
            segment
                .chars()
                .next()
                .is_some_and(|c| c.is_ascii_alphabetic())
                && segment
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_')
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn package_names() {
        assert!(valid_package("com.whatsapp"));
        assert!(valid_package("org.thoughtcrime.securesms"));
        assert!(!valid_package("whatsapp"));
        assert!(!valid_package("com.what sapp"));
        assert!(!valid_package("com..app"));
        assert!(
            !valid_package("+com.app"),
            "scrcpy start_app prefixes must not pass"
        );
        assert!(!valid_package("1com.app"));
    }

    #[test]
    fn ongoing_activity_limits() {
        let activity = proto::OngoingActivity {
            key: "0|com.google.android.deskclock|1|timer".into(),
            short_text: "é".repeat(30),
            progress: 50,
            progress_max: 10,
            actions: vec![proto::NotificationAction::default(); 5],
            ..Default::default()
        };
        let a = sanitize_ongoing_activity(activity).unwrap();
        assert!(a.short_text.len() <= 40);
        assert_eq!(a.progress, 10);
        assert_eq!(a.actions.len(), 3);
        assert!(sanitize_ongoing_activity(proto::OngoingActivity::default()).is_none());
    }

    #[test]
    fn request_ids() {
        assert!(valid_request_id("0123456789abcdef"));
        assert!(!valid_request_id("short"));
        assert!(!valid_request_id("0123456789ABCDEF"));
        assert!(!valid_request_id("../../etc/passwd"));
    }

    #[test]
    fn limits() {
        let apps = (0..MAX_APPS + 10)
            .map(|i| proto::PhoneApp {
                package: format!("com.example.app{i}"),
                label: "App".into(),
                icon_png: vec![0; if i == 0 { MAX_ICON_BYTES + 1 } else { 10 }],
            })
            .collect();
        let apps = sanitize(apps);
        assert_eq!(apps.len(), MAX_APPS);
        assert!(apps[0].icon_png.is_empty());
        assert_eq!(apps[1].icon_png.len(), 10);
    }
}
