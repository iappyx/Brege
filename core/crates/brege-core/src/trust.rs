use std::collections::HashSet;
use std::sync::RwLock;

use brege_identity::DeviceId;
use brege_transport::TrustStore;

/// In-memory mirror of paired device ids, consulted during every TLS handshake.
#[derive(Debug, Default)]
pub(crate) struct PeerTrust(RwLock<HashSet<DeviceId>>);

impl PeerTrust {
    pub fn replace_all(&self, ids: impl IntoIterator<Item = DeviceId>) {
        *self.0.write().unwrap() = ids.into_iter().collect();
    }

    pub fn add(&self, id: DeviceId) {
        self.0.write().unwrap().insert(id);
    }

    pub fn remove(&self, id: &DeviceId) {
        self.0.write().unwrap().remove(id);
    }
}

impl TrustStore for PeerTrust {
    fn is_trusted(&self, id: &DeviceId) -> bool {
        self.0.read().unwrap().contains(id)
    }
}
