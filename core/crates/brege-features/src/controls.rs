//! Phone controls (torch, sound, Do Not Disturb): validation of requests from the Mac.
//!
//! The phone acts on these, so values are clamped and unknown kinds are refused.

use brege_proto::v1::{PhoneControl, phone_control};

/// Longest buzz the Mac may ask for.
pub const MAX_VIBRATE_MS: i32 = 2_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum Invalid {
    #[error("unsupported control")]
    BadKind,
    #[error("control needs a stream")]
    MissingStream,
}

/// Returns the control with its value clamped to what the phone accepts.
pub fn validate(control: &PhoneControl) -> Result<PhoneControl, Invalid> {
    use phone_control::{Kind, Stream};
    let kind = Kind::try_from(control.kind).map_err(|_| Invalid::BadKind)?;
    let stream = Stream::try_from(control.stream).unwrap_or(Stream::Unspecified);
    let value = match kind {
        Kind::Unspecified => return Err(Invalid::BadKind),
        Kind::Torch => control.value.clamp(0, 1),
        // The phone clamps to its own maximum; here we only keep it sane.
        Kind::TorchLevel => control.value.clamp(1, 1_000),
        Kind::RingerMode | Kind::Dnd => control.value.max(0),
        Kind::StreamVolume => {
            if stream == Stream::Unspecified {
                return Err(Invalid::MissingStream);
            }
            control.value.clamp(0, 100)
        }
        Kind::Vibrate => control.value.clamp(1, MAX_VIBRATE_MS),
        Kind::ClearNotifications => 0,
    };
    Ok(PhoneControl {
        kind: control.kind,
        value,
        stream: control.stream,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use brege_proto::v1::phone_control::{Kind, Stream};

    fn control(kind: Kind, value: i32, stream: Stream) -> PhoneControl {
        PhoneControl {
            kind: kind as i32,
            value,
            stream: stream as i32,
        }
    }

    #[test]
    fn values_are_clamped() {
        assert_eq!(
            validate(&control(Kind::Torch, 7, Stream::Unspecified))
                .unwrap()
                .value,
            1
        );
        assert_eq!(
            validate(&control(Kind::Vibrate, 60_000, Stream::Unspecified))
                .unwrap()
                .value,
            MAX_VIBRATE_MS
        );
        assert_eq!(
            validate(&control(Kind::StreamVolume, -3, Stream::Ring))
                .unwrap()
                .value,
            0
        );
    }

    #[test]
    fn unsupported_and_incomplete_controls_are_refused() {
        assert_eq!(
            validate(&control(Kind::Unspecified, 1, Stream::Unspecified)),
            Err(Invalid::BadKind)
        );
        assert_eq!(
            validate(&control(Kind::StreamVolume, 5, Stream::Unspecified)),
            Err(Invalid::MissingStream)
        );
        assert_eq!(
            validate(&PhoneControl {
                kind: 99,
                value: 0,
                stream: 0
            }),
            Err(Invalid::BadKind)
        );
    }
}
