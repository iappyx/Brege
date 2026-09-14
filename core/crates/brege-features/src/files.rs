//! Phone folders in Finder: validation of paths that arrive from a peer.
//!
//! Paths are absolute and "/" separated. The phone resolves them only inside folders the user
//! shared, but it must still never see `..`, empty components or control characters.

pub const MAX_PATH_LEN: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("invalid path")]
pub struct InvalidPath;

/// Normalises a peer-supplied path: collapses repeated and trailing slashes and rejects `.`,
/// `..` and control characters. The root is `/`.
pub fn normalize(path: &str) -> Result<String, InvalidPath> {
    if !path.starts_with('/') || path.len() > MAX_PATH_LEN || path.chars().any(char::is_control) {
        return Err(InvalidPath);
    }
    let mut out = String::with_capacity(path.len());
    for part in path.split('/').filter(|p| !p.is_empty()) {
        if part == "." || part == ".." || part.contains('\\') {
            return Err(InvalidPath);
        }
        out.push('/');
        out.push_str(part);
    }
    if out.is_empty() {
        out.push('/');
    }
    Ok(out)
}

/// Splits a normalised path into its parent and last component (`None` for the root).
pub fn split_parent(path: &str) -> Option<(&str, &str)> {
    if path == "/" {
        return None;
    }
    let index = path.rfind('/')?;
    let parent = if index == 0 { "/" } else { &path[..index] };
    Some((parent, &path[index + 1..]))
}

/// Finder metadata that should stay on the Mac instead of being written to the phone.
/// Name prefix of the phone's temporary files while a replaced file uploads.
pub const UPLOAD_PREFIX: &str = ".brege-upload-";

/// A file Brêge writes while an upload runs; not shown in Finder.
pub fn is_upload_temp(name: &str) -> bool {
    name.starts_with(UPLOAD_PREFIX)
}

pub fn is_mac_metadata(name: &str) -> bool {
    name.starts_with("._")
        || name == ".DS_Store"
        || name == ".localized"
        || name == ".Spotlight-V100"
        || name == ".Trashes"
        || name == ".fseventsd"
        || name == ".TemporaryItems"
        || name == ".metadata_never_index"
        || name == ".ql_disablethumbnails"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes() {
        assert_eq!(normalize("/").unwrap(), "/");
        assert_eq!(normalize("//DCIM///Camera/").unwrap(), "/DCIM/Camera");
        assert_eq!(
            normalize("/Documents/a b.pdf").unwrap(),
            "/Documents/a b.pdf"
        );
        assert!(normalize("DCIM").is_err());
        assert!(normalize("/DCIM/../../data").is_err());
        assert!(normalize("/./x").is_err());
        assert!(normalize("/a\u{0}b").is_err());
        assert!(normalize("/a\\b").is_err());
    }

    #[test]
    fn parents() {
        assert_eq!(split_parent("/"), None);
        assert_eq!(split_parent("/DCIM"), Some(("/", "DCIM")));
        assert_eq!(
            split_parent("/DCIM/Camera/x.jpg"),
            Some(("/DCIM/Camera", "x.jpg"))
        );
    }

    #[test]
    fn metadata_names() {
        assert!(is_mac_metadata("._IMG_0001.jpg"));
        assert!(is_mac_metadata(".DS_Store"));
        assert!(!is_mac_metadata(".nomedia"));
        assert!(!is_mac_metadata("IMG_0001.jpg"));
        assert!(is_upload_temp(".brege-upload-0a1b2c3d.pdf"));
        assert!(!is_upload_temp("brege-upload.pdf"));
    }
}
