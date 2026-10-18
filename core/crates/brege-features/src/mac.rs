//! What a phone, or the watch behind it, may ask of a Mac.

use brege_proto::v1::{MacAction, mac_action::Kind};

#[derive(Debug, PartialEq, Eq)]
pub enum Invalid {
    BadKind,
}

impl std::fmt::Display for Invalid {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadKind => write!(f, "unknown action"),
        }
    }
}

/// True for the actions that work by sending a key to whatever is in front on the Mac.
pub fn needs_key_control(kind: Kind) -> bool {
    matches!(
        kind,
        Kind::MediaPlayPause
            | Kind::MediaNext
            | Kind::MediaPrevious
            | Kind::SlideNext
            | Kind::SlidePrevious
    )
}

/// Returns the action with its value brought into range, or why it is refused.
pub fn validate(action: &MacAction) -> Result<MacAction, Invalid> {
    let kind = action.kind();
    if kind == Kind::Unspecified {
        return Err(Invalid::BadKind);
    }
    let value = match kind {
        Kind::Volume => action.value.clamp(0, 100),
        // Ring and mute are switches: 1 starts, 0 stops.
        Kind::Mute | Kind::Ring => i32::from(action.value != 0),
        _ => 0,
    };
    Ok(MacAction {
        kind: action.kind,
        value,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn action(kind: Kind, value: i32) -> MacAction {
        MacAction {
            kind: kind as i32,
            value,
        }
    }

    #[test]
    fn volume_is_clamped() {
        assert_eq!(validate(&action(Kind::Volume, 140)).unwrap().value, 100);
        assert_eq!(validate(&action(Kind::Volume, -5)).unwrap().value, 0);
    }

    #[test]
    fn mute_is_a_flag() {
        assert_eq!(validate(&action(Kind::Mute, 7)).unwrap().value, 1);
        assert_eq!(validate(&action(Kind::Mute, 0)).unwrap().value, 0);
    }

    #[test]
    fn ring_keeps_its_switch() {
        assert_eq!(validate(&action(Kind::Ring, 1)).unwrap().value, 1);
        assert_eq!(validate(&action(Kind::Ring, 0)).unwrap().value, 0);
    }

    #[test]
    fn an_unknown_action_is_refused() {
        assert_eq!(
            validate(&action(Kind::Unspecified, 0)),
            Err(Invalid::BadKind)
        );
    }
}
