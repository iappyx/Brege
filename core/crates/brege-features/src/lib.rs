//! Platform-independent logic of the feature modules.
//!
//! Each module is pure logic with no I/O, so it is unit-tested here and driven by `brege-core`.

pub mod clipboard;
pub mod codes;
pub mod controls;
pub mod files;
pub mod messages;
pub mod notifications;
pub mod open_request;
