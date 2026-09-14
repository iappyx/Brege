//! Notification mirroring: filtering on the phone and icon de-duplication.

use std::collections::{HashSet, VecDeque};

use brege_proto::v1::NotificationPost;

pub const MAX_PICTURE_BYTES: usize = 256 * 1024;
pub const MAX_ICON_BYTES: usize = 64 * 1024;
const ICON_CACHE: usize = 256;

/// Packages whose notifications are handled by the Messages module instead.
pub const MESSAGING_PACKAGES: &[&str] = &[
    "com.google.android.apps.messaging",
    "com.samsung.android.messaging",
];

#[derive(Debug, Clone, Default)]
pub struct Filter {
    pub own_package: String,
    pub excluded_packages: HashSet<String>,
    pub messages_module_enabled: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Mirror,
    Skip(&'static str),
}

impl Filter {
    /// `ongoing` covers ongoing and foreground-service notifications.
    pub fn decide(&self, package: &str, ongoing: bool) -> Decision {
        if ongoing {
            Decision::Skip("ongoing")
        } else if package == self.own_package {
            Decision::Skip("own")
        } else if self.excluded_packages.contains(package) {
            Decision::Skip("excluded")
        } else if self.messages_module_enabled && MESSAGING_PACKAGES.contains(&package) {
            Decision::Skip("messages module")
        } else {
            Decision::Mirror
        }
    }
}

/// Tracks which app icons a peer already has, so each icon is sent once.
#[derive(Debug, Default)]
pub struct IconTracker {
    sent: VecDeque<String>,
}

impl IconTracker {
    /// Fills `icon_ref` and includes the PNG only the first time; enforces size caps.
    pub fn prepare(&mut self, post: &mut NotificationPost, icon_png: Option<&[u8]>) {
        post.icon_png.clear();
        if post.picture.len() > MAX_PICTURE_BYTES {
            post.picture.clear();
        }
        if post.sender_icon.len() > MAX_ICON_BYTES {
            post.sender_icon.clear();
        }
        let Some(png) = icon_png.filter(|p| !p.is_empty() && p.len() <= MAX_ICON_BYTES) else {
            post.icon_ref.clear();
            return;
        };
        let reference = blake3::hash(png).to_hex().to_string();
        if !self.sent.contains(&reference) {
            post.icon_png = png.to_vec();
            self.sent.push_back(reference.clone());
            if self.sent.len() > ICON_CACHE {
                self.sent.pop_front();
            }
        }
        post.icon_ref = reference;
    }

    /// Forgets one icon, e.g. when the notification that carried it could not be sent.
    pub fn forget(&mut self, reference: &str) {
        self.sent.retain(|r| r != reference);
    }

    /// Forget everything after a reconnect: the peer may have lost its cache.
    pub fn reset(&mut self) {
        self.sent.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn filter_rules() {
        let f = Filter {
            own_package: "app.brege".into(),
            excluded_packages: ["com.bank".to_string()].into(),
            messages_module_enabled: true,
        };
        assert_eq!(f.decide("com.whatsapp", false), Decision::Mirror);
        assert_eq!(f.decide("com.whatsapp", true), Decision::Skip("ongoing"));
        assert_eq!(f.decide("app.brege", false), Decision::Skip("own"));
        assert_eq!(f.decide("com.bank", false), Decision::Skip("excluded"));
        assert!(matches!(
            f.decide("com.google.android.apps.messaging", false),
            Decision::Skip(_)
        ));
    }

    #[test]
    fn icons_sent_once() {
        let mut t = IconTracker::default();
        let icon = vec![9u8; 100];
        let mut a = NotificationPost::default();
        t.prepare(&mut a, Some(&icon));
        assert_eq!(a.icon_png, icon);
        let mut b = NotificationPost::default();
        t.prepare(&mut b, Some(&icon));
        assert!(b.icon_png.is_empty());
        assert_eq!(a.icon_ref, b.icon_ref);
        t.forget(&a.icon_ref);
        let mut b = NotificationPost::default();
        t.prepare(&mut b, Some(&icon));
        assert_eq!(b.icon_png, icon, "resent after a failed send");
        t.reset();
        let mut c = NotificationPost {
            picture: vec![0; MAX_PICTURE_BYTES + 1],
            ..Default::default()
        };
        t.prepare(&mut c, Some(&icon));
        assert_eq!(c.icon_png, icon);
        assert!(c.picture.is_empty());
    }
}
