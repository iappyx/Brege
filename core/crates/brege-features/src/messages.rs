//! Messages and calls: validation of requests that arrive from a peer.
//!
//! The phone executes these requests with telephony permissions, so it must not trust the Mac
//! blindly: bodies are bounded and numbers are restricted to dialable characters.

use brege_proto::v1::{CallAction, SmsSend, call_action};

/// Upper bound for one outgoing message; long SMS are split into parts by the phone.
pub const MAX_BODY_CHARS: usize = 5_000;
pub const MAX_NUMBER_LEN: usize = 32;
/// Upper bound for a contact name arriving from a peer.
pub const MAX_NAME_CHARS: usize = 100;

/// Messages per batch when a phone publishes threads or messages (keeps frames well below the cap).
pub const SYNC_BATCH: usize = 200;

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum Invalid {
    #[error("message body is empty")]
    EmptyBody,
    #[error("message body is too long")]
    BodyTooLong,
    #[error("invalid phone number")]
    BadNumber,
    #[error("unknown thread")]
    BadThread,
    #[error("unsupported call action")]
    BadAction,
}

/// Accepts digits, `+`, `*`, `#` and common separators. Short alphanumeric sender ids are not
/// valid recipients.
pub fn is_dialable(number: &str) -> bool {
    let digits = number.chars().filter(char::is_ascii_digit).count();
    !number.is_empty()
        && number.len() <= MAX_NUMBER_LEN
        && digits > 0
        && number.chars().all(|c| {
            c.is_ascii_digit() || matches!(c, '+' | '*' | '#' | ' ' | '-' | '(' | ')' | '.')
        })
}

/// Most addresses in one contact-photo request.
pub const MAX_PHOTO_ADDRESSES: usize = 50;
/// Largest contact photo accepted from the phone.
pub const MAX_PHOTO_BYTES: usize = 64 * 1024;

/// Keeps a request within limits: at most [`MAX_PHOTO_ADDRESSES`] plausible, distinct addresses.
pub fn sanitize_photo_addresses(addresses: Vec<String>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for address in addresses {
        let trimmed = address.trim();
        if !trimmed.is_empty() && trimmed.len() <= 128 && !out.iter().any(|a| a == trimmed) {
            out.push(trimmed.to_string());
        }
        if out.len() == MAX_PHOTO_ADDRESSES {
            break;
        }
    }
    out
}

pub fn validate_send(send: &SmsSend) -> Result<(), Invalid> {
    if send.body.trim().is_empty() {
        return Err(Invalid::EmptyBody);
    }
    if send.body.chars().count() > MAX_BODY_CHARS {
        return Err(Invalid::BodyTooLong);
    }
    if send.thread_id.starts_with("rcs:") {
        // Replies to mirrored RCS threads go through the messaging app's notification.
        return Ok(());
    }
    if !send.thread_id.is_empty() && !send.thread_id.starts_with("sms:") {
        return Err(Invalid::BadThread);
    }
    if !is_dialable(&send.address) {
        return Err(Invalid::BadNumber);
    }
    Ok(())
}

/// Cuts a string from a peer to `max` characters, so a rogue peer cannot bloat the cache.
pub fn clamp(text: &str, max: usize) -> String {
    text.chars().take(max).collect()
}

pub fn validate_call_action(action: &CallAction) -> Result<call_action::Kind, Invalid> {
    let kind = call_action::Kind::try_from(action.kind).map_err(|_| Invalid::BadAction)?;
    match kind {
        call_action::Kind::Unspecified => Err(Invalid::BadAction),
        call_action::Kind::Dial if !is_dialable(&action.number) => Err(Invalid::BadNumber),
        kind => Ok(kind),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn send(thread: &str, address: &str, body: &str) -> SmsSend {
        SmsSend {
            client_id: "c1".into(),
            thread_id: thread.into(),
            address: address.into(),
            body: body.into(),
            sub_id: -1,
        }
    }

    #[test]
    fn numbers() {
        assert!(is_dialable("+31 6 1234 5678"));
        assert!(is_dialable("*#06#"));
        assert!(!is_dialable("ING Bank"));
        assert!(!is_dialable("+-()"));
        assert!(!is_dialable("123;rm -rf"));
        assert!(!is_dialable(&"1".repeat(40)));
    }

    #[test]
    fn sends() {
        assert_eq!(validate_send(&send("sms:4", "+31612345678", "Hoi")), Ok(()));
        assert_eq!(validate_send(&send("", "0612345678", "Hoi")), Ok(()));
        assert_eq!(validate_send(&send("rcs:abc", "", "Hoi")), Ok(()));
        assert_eq!(
            validate_send(&send("sms:4", "+316", "  ")),
            Err(Invalid::EmptyBody)
        );
        assert_eq!(
            validate_send(&send("sms:4", "KPN", "Hoi")),
            Err(Invalid::BadNumber)
        );
        assert_eq!(
            validate_send(&send("x:4", "+316", "Hoi")),
            Err(Invalid::BadThread)
        );
        let long = "a".repeat(MAX_BODY_CHARS + 1);
        assert_eq!(
            validate_send(&send("sms:4", "+316", &long)),
            Err(Invalid::BodyTooLong)
        );
    }

    #[test]
    fn call_actions() {
        let dial = |n: &str| CallAction {
            kind: call_action::Kind::Dial as i32,
            number: n.into(),
            sub_id: -1,
        };
        assert_eq!(
            validate_call_action(&dial("112")),
            Ok(call_action::Kind::Dial)
        );
        assert_eq!(
            validate_call_action(&dial("tel:112")),
            Err(Invalid::BadNumber)
        );
        let answer = CallAction {
            kind: call_action::Kind::Answer as i32,
            ..Default::default()
        };
        assert_eq!(validate_call_action(&answer), Ok(call_action::Kind::Answer));
        let bad = CallAction {
            kind: 99,
            ..Default::default()
        };
        assert_eq!(validate_call_action(&bad), Err(Invalid::BadAction));
    }
}
