//! Open requests (a link, text or file to open on the other device): validation of content received
//! from a peer.
//!
//! A paired device is trusted, but a compromised or buggy peer must not be able to make the
//! other side open arbitrary URL schemes (e.g. `file:`, custom app schemes) without the user.

use brege_proto::v1::{OpenActivity, open_activity};

pub const MAX_URL_LEN: usize = 8 * 1024;
pub const MAX_TEXT_LEN: usize = 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OpenRequest {
    /// May be opened directly (after the user taps the notification, or automatically if enabled).
    Url {
        url: String,
        title: String,
    },
    /// Any other scheme: shown to the user as text, never opened automatically.
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

const AUTO_OPEN_SCHEMES: &[&str] = &["https", "http", "mailto", "tel", "sms", "geo"];

pub fn classify(activity: OpenActivity) -> Option<OpenRequest> {
    match open_activity::Kind::try_from(activity.kind).ok()? {
        open_activity::Kind::Url => {
            let url = activity.content.trim().to_string();
            if url.is_empty() || url.len() > MAX_URL_LEN || url.chars().any(char::is_control) {
                return None;
            }
            let scheme = url.split_once(':')?.0.to_ascii_lowercase();
            if AUTO_OPEN_SCHEMES.contains(&scheme.as_str()) {
                Some(OpenRequest::Url {
                    url,
                    title: activity.title,
                })
            } else {
                Some(OpenRequest::UnsafeUrl { url })
            }
        }
        open_activity::Kind::Text => {
            (activity.content.len() <= MAX_TEXT_LEN).then_some(OpenRequest::Text {
                text: activity.content,
            })
        }
        open_activity::Kind::File => Some(OpenRequest::File {
            transfer_id: activity.content,
        }),
        open_activity::Kind::Unspecified => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn url(u: &str) -> OpenActivity {
        OpenActivity {
            kind: open_activity::Kind::Url as i32,
            content: u.into(),
            ..Default::default()
        }
    }

    #[test]
    fn only_safe_schemes_open() {
        assert!(matches!(
            classify(url("https://brege.app")),
            Some(OpenRequest::Url { .. })
        ));
        assert!(matches!(
            classify(url("HTTPS://x")),
            Some(OpenRequest::Url { .. })
        ));
        assert!(matches!(
            classify(url("file:///etc/passwd")),
            Some(OpenRequest::UnsafeUrl { .. })
        ));
        assert!(matches!(
            classify(url("intent://evil#Intent;end")),
            Some(OpenRequest::UnsafeUrl { .. })
        ));
        assert_eq!(classify(url("no-scheme")), None);
        assert_eq!(classify(url("https://a\nb")), None);
        assert_eq!(
            classify(url(&format!("https://{}", "a".repeat(MAX_URL_LEN)))),
            None
        );
    }
}
