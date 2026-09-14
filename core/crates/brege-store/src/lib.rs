//! Encrypted local persistence for the core.
//!
//! SQLCipher-encrypted SQLite. The 32-byte database key is generated and held by the shell
//! (Keychain / Keystore-wrapped) and passed in on open.

use std::collections::BTreeSet;
use std::path::Path;

use brege_identity::{DeviceId, PresenceKey};
use rusqlite::{Connection, OptionalExtension, params};
use rusqlite_migration::{M, Migrations};

mod messages;

pub use messages::{MessageRecord, SimRecord, ThreadRecord};

fn migrations() -> Migrations<'static> {
    Migrations::new(vec![
        M::up(include_str!("../migrations/001_initial.sql")),
        M::up(include_str!("../migrations/002_messages.sql")),
        M::up(include_str!("../migrations/003_known_networks.sql")),
        M::up(include_str!("../migrations/004_network_names.sql")),
    ])
}

/// Notification history is kept for seven days.
pub const NOTIFICATION_RETENTION_MS: i64 = 7 * 24 * 60 * 60 * 1000;
/// Upper bound on stored notifications, whatever their timestamps say.
pub const MAX_NOTIFICATIONS: i64 = 5_000;

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("migration: {0}")]
    Migration(#[from] rusqlite_migration::Error),
    #[error("database key rejected or file is not a Brêge database")]
    WrongKey,
    #[error("corrupt row: {0}")]
    Corrupt(&'static str),
}

/// A network or tunnel Brêge trusts (network privacy plan).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnownNetwork {
    pub fingerprint: String,
    pub kind: String,
    pub label: String,
    pub added_ms: i64,
    pub last_used_ms: i64,
    /// Wi‑Fi name when it was known, else "".
    pub ssid: String,
    /// False for a network the user chose not to use ("Not here").
    pub trusted: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceRecord {
    pub id: DeviceId,
    pub name: String,
    pub platform: i32,
    pub presence_key: PresenceKey,
    pub paired_at_ms: i64,
    pub last_seen_ms: Option<i64>,
    pub last_addr: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotificationRecord {
    pub device_id: DeviceId,
    pub key: String,
    pub package: String,
    pub app_label: String,
    pub title: String,
    pub text: String,
    pub posted_at_ms: i64,
    pub dismissed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferDirection {
    Incoming = 0,
    Outgoing = 1,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransferState {
    Offered = 0,
    InProgress = 1,
    Complete = 2,
    Failed = 3,
    Cancelled = 4,
}

impl TransferState {
    fn from_i64(v: i64) -> Result<Self, StoreError> {
        Ok(match v {
            0 => Self::Offered,
            1 => Self::InProgress,
            2 => Self::Complete,
            3 => Self::Failed,
            4 => Self::Cancelled,
            _ => return Err(StoreError::Corrupt("transfer state")),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransferRecord {
    pub id: String,
    pub device_id: DeviceId,
    pub direction: TransferDirection,
    pub name: String,
    pub size: u64,
    pub chunk_size: u32,
    pub root_hash: [u8; 32],
    pub state: TransferState,
    pub path: Option<String>,
    pub created_at_ms: i64,
}

pub struct Store {
    conn: Connection,
}

impl Store {
    pub fn open(path: &Path, key: &[u8; 32]) -> Result<Self, StoreError> {
        Self::init(Connection::open(path)?, key)
    }

    pub fn open_in_memory(key: &[u8; 32]) -> Result<Self, StoreError> {
        Self::init(Connection::open_in_memory()?, key)
    }

    fn init(mut conn: Connection, key: &[u8; 32]) -> Result<Self, StoreError> {
        // Raw 256-bit key, bypassing SQLCipher's passphrase KDF.
        let hex: String = key.iter().map(|b| format!("{b:02x}")).collect();
        conn.execute_batch(&format!("PRAGMA key = \"x'{hex}'\";"))?;
        // The first read fails if the key is wrong.
        if conn
            .query_row("SELECT count(*) FROM sqlite_master", [], |r| {
                r.get::<_, i64>(0)
            })
            .is_err()
        {
            return Err(StoreError::WrongKey);
        }
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", "ON")?;
        migrations().to_latest(&mut conn)?;
        Ok(Self { conn })
    }

    // --- known networks ---------------------------------------------------------------------

    /// Stores a decision about a network: trusted, or "not here" (`trusted` false).
    pub fn remember_network(&self, network: &KnownNetwork) -> Result<(), StoreError> {
        self.conn.execute(
            "INSERT INTO known_network (fingerprint, kind, label, added_ms, last_used_ms, ssid, trusted)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(fingerprint) DO UPDATE SET kind = excluded.kind, label = excluded.label,
               last_used_ms = excluded.last_used_ms, ssid = excluded.ssid, trusted = excluded.trusted",
            params![
                network.fingerprint,
                network.kind,
                network.label,
                network.added_ms,
                network.last_used_ms,
                network.ssid,
                network.trusted
            ],
        )?;
        Ok(())
    }

    pub fn known_networks(&self) -> Result<Vec<KnownNetwork>, StoreError> {
        let mut stmt = self.conn.prepare(
            "SELECT fingerprint, kind, label, added_ms, last_used_ms, ssid, trusted
             FROM known_network ORDER BY trusted DESC, last_used_ms DESC",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(KnownNetwork {
                fingerprint: r.get(0)?,
                kind: r.get(1)?,
                label: r.get(2)?,
                added_ms: r.get(3)?,
                last_used_ms: r.get(4)?,
                ssid: r.get(5)?,
                trusted: r.get(6)?,
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn forget_network(&self, fingerprint: &str) -> Result<(), StoreError> {
        self.conn.execute(
            "DELETE FROM known_network WHERE fingerprint = ?1",
            [fingerprint],
        )?;
        Ok(())
    }

    /// Returns the SQLCipher version, proving the encrypted build is linked.
    pub fn cipher_version(&self) -> Result<Option<String>, StoreError> {
        Ok(self
            .conn
            .query_row("PRAGMA cipher_version", [], |r| r.get(0))
            .optional()?)
    }

    // --- devices ----------------------------------------------------------------------------

    pub fn upsert_device(&self, d: &DeviceRecord) -> Result<(), StoreError> {
        self.conn.execute(
            "INSERT INTO device (id, name, platform, presence_key, paired_at_ms, last_seen_ms, last_addr)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(id) DO UPDATE SET name = excluded.name, platform = excluded.platform,
               presence_key = excluded.presence_key, last_seen_ms = excluded.last_seen_ms,
               last_addr = excluded.last_addr",
            params![
                d.id.as_bytes().as_slice(),
                d.name,
                d.platform,
                d.presence_key.as_bytes().as_slice(),
                d.paired_at_ms,
                d.last_seen_ms,
                d.last_addr
            ],
        )?;
        Ok(())
    }

    pub fn remove_device(&self, id: &DeviceId) -> Result<bool, StoreError> {
        Ok(self.conn.execute(
            "DELETE FROM device WHERE id = ?1",
            [id.as_bytes().as_slice()],
        )? > 0)
    }

    pub fn device(&self, id: &DeviceId) -> Result<Option<DeviceRecord>, StoreError> {
        self.conn
            .query_row(
                "SELECT id, name, platform, presence_key, paired_at_ms, last_seen_ms, last_addr
                 FROM device WHERE id = ?1",
                [id.as_bytes().as_slice()],
                row_to_device,
            )
            .optional()?
            .transpose()
    }

    pub fn devices(&self) -> Result<Vec<DeviceRecord>, StoreError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, name, platform, presence_key, paired_at_ms, last_seen_ms, last_addr
             FROM device ORDER BY paired_at_ms",
        )?;
        let rows = stmt.query_map([], row_to_device)?;
        rows.map(|r| r?).collect()
    }

    pub fn mark_seen(
        &self,
        id: &DeviceId,
        at_ms: i64,
        addr: Option<&str>,
    ) -> Result<(), StoreError> {
        self.conn.execute(
            "UPDATE device SET last_seen_ms = ?2, last_addr = COALESCE(?3, last_addr) WHERE id = ?1",
            params![id.as_bytes().as_slice(), at_ms, addr],
        )?;
        Ok(())
    }

    // --- notifications ----------------------------------------------------------------------

    pub fn upsert_notification(&self, n: &NotificationRecord) -> Result<(), StoreError> {
        self.conn.execute(
            "INSERT INTO notification (key, device_id, package, app_label, title, text, posted_at_ms, dismissed)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(device_id, key) DO UPDATE SET package = excluded.package,
               app_label = excluded.app_label, title = excluded.title, text = excluded.text,
               posted_at_ms = excluded.posted_at_ms, dismissed = excluded.dismissed",
            params![
                n.key,
                n.device_id.as_bytes().as_slice(),
                n.package,
                n.app_label,
                n.title,
                n.text,
                n.posted_at_ms,
                n.dismissed
            ],
        )?;
        Ok(())
    }

    pub fn dismiss_notification(&self, device: &DeviceId, key: &str) -> Result<(), StoreError> {
        self.conn.execute(
            "UPDATE notification SET dismissed = 1 WHERE device_id = ?1 AND key = ?2",
            params![device.as_bytes().as_slice(), key],
        )?;
        Ok(())
    }

    pub fn recent_notifications(&self, limit: u32) -> Result<Vec<NotificationRecord>, StoreError> {
        let mut stmt = self.conn.prepare(
            "SELECT device_id, key, package, app_label, title, text, posted_at_ms, dismissed
             FROM notification ORDER BY posted_at_ms DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map([limit], |r| {
            Ok((
                r.get::<_, Vec<u8>>(0)?,
                NotificationRecord {
                    device_id: DeviceId::from_bytes([0; 32]),
                    key: r.get(1)?,
                    package: r.get(2)?,
                    app_label: r.get(3)?,
                    title: r.get(4)?,
                    text: r.get(5)?,
                    posted_at_ms: r.get(6)?,
                    dismissed: r.get(7)?,
                },
            ))
        })?;
        rows.map(|row| {
            let (id, mut rec) = row?;
            rec.device_id = device_id(id)?;
            Ok(rec)
        })
        .collect()
    }

    /// Deletes notifications outside the retention window (timestamps come from the phone's
    /// clock, so implausibly far-future ones go too) and the oldest beyond
    /// [`MAX_NOTIFICATIONS`]. Returns the number removed.
    pub fn prune_notifications(&self, now_ms: i64) -> Result<usize, StoreError> {
        let expired = self.conn.execute(
            "DELETE FROM notification WHERE posted_at_ms < ?1 OR posted_at_ms > ?2",
            [
                now_ms.saturating_sub(NOTIFICATION_RETENTION_MS),
                now_ms.saturating_add(NOTIFICATION_RETENTION_MS),
            ],
        )?;
        let excess = self.conn.execute(
            "DELETE FROM notification WHERE rowid IN
               (SELECT rowid FROM notification ORDER BY posted_at_ms DESC LIMIT -1 OFFSET ?1)",
            [MAX_NOTIFICATIONS],
        )?;
        Ok(expired + excess)
    }

    // --- transfers --------------------------------------------------------------------------

    pub fn insert_transfer(&self, t: &TransferRecord) -> Result<(), StoreError> {
        self.conn.execute(
            "INSERT INTO transfer (id, device_id, direction, name, size, chunk_size, root_hash, state, path, created_at_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                t.id,
                t.device_id.as_bytes().as_slice(),
                t.direction as i64,
                t.name,
                t.size as i64,
                t.chunk_size,
                t.root_hash.as_slice(),
                t.state as i64,
                t.path,
                t.created_at_ms
            ],
        )?;
        Ok(())
    }

    pub fn transfer(&self, id: &str) -> Result<Option<TransferRecord>, StoreError> {
        Ok(self
            .query_transfers("WHERE id = ?1", params![id])?
            .into_iter()
            .next())
    }

    /// Outgoing transfers to `device` that have not completed, oldest first (for resume).
    pub fn unfinished_outgoing(
        &self,
        device: &DeviceId,
    ) -> Result<Vec<TransferRecord>, StoreError> {
        self.query_transfers(
            "WHERE device_id = ?1 AND direction = 1 AND state IN (0, 1) ORDER BY created_at_ms",
            params![device.as_bytes().as_slice()],
        )
    }

    fn query_transfers(
        &self,
        clause: &str,
        args: impl rusqlite::Params,
    ) -> Result<Vec<TransferRecord>, StoreError> {
        let mut stmt = self.conn.prepare(&format!(
            "SELECT id, device_id, direction, name, size, chunk_size, root_hash, state, path, created_at_ms
             FROM transfer {clause}"
        ))?;
        let rows = stmt.query_map(args, |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, i64>(4)?,
                r.get::<_, u32>(5)?,
                r.get::<_, Vec<u8>>(6)?,
                r.get::<_, i64>(7)?,
                r.get::<_, Option<String>>(8)?,
                r.get::<_, i64>(9)?,
            ))
        })?;
        rows.map(|row| {
            let (id, dev, dir, name, size, chunk_size, root, state, path, created) = row?;
            Ok(TransferRecord {
                id,
                device_id: device_id(dev)?,
                direction: if dir == 0 {
                    TransferDirection::Incoming
                } else {
                    TransferDirection::Outgoing
                },
                name,
                size: size as u64,
                chunk_size,
                root_hash: root
                    .try_into()
                    .map_err(|_| StoreError::Corrupt("root hash"))?,
                state: TransferState::from_i64(state)?,
                path,
                created_at_ms: created,
            })
        })
        .collect()
    }

    pub fn set_transfer_state(
        &self,
        id: &str,
        state: TransferState,
        path: Option<&str>,
    ) -> Result<(), StoreError> {
        self.conn.execute(
            "UPDATE transfer SET state = ?2, path = COALESCE(?3, path) WHERE id = ?1",
            params![id, state as i64, path],
        )?;
        Ok(())
    }

    pub fn add_transfer_chunk(&self, id: &str, index: u32) -> Result<(), StoreError> {
        self.conn.execute(
            "INSERT OR IGNORE INTO transfer_chunk (transfer_id, idx) VALUES (?1, ?2)",
            params![id, index],
        )?;
        Ok(())
    }

    /// Forgets which chunks arrived, e.g. when the partial file is gone.
    pub fn clear_transfer_chunks(&self, id: &str) -> Result<(), StoreError> {
        self.conn
            .execute("DELETE FROM transfer_chunk WHERE transfer_id = ?1", [id])?;
        Ok(())
    }

    pub fn transfer_chunks(&self, id: &str) -> Result<BTreeSet<u32>, StoreError> {
        let mut stmt = self
            .conn
            .prepare("SELECT idx FROM transfer_chunk WHERE transfer_id = ?1")?;
        let rows = stmt.query_map([id], |r| r.get::<_, u32>(0))?;
        Ok(rows.collect::<Result<_, _>>()?)
    }
}

fn device_id(bytes: Vec<u8>) -> Result<DeviceId, StoreError> {
    let bytes: [u8; 32] = bytes
        .try_into()
        .map_err(|_| StoreError::Corrupt("device id"))?;
    Ok(DeviceId::from_bytes(bytes))
}

fn row_to_device(r: &rusqlite::Row<'_>) -> rusqlite::Result<Result<DeviceRecord, StoreError>> {
    let id: Vec<u8> = r.get(0)?;
    let presence: Vec<u8> = r.get(3)?;
    let name = r.get(1)?;
    let platform = r.get(2)?;
    let paired_at_ms = r.get(4)?;
    let last_seen_ms = r.get(5)?;
    let last_addr = r.get(6)?;
    Ok((|| {
        Ok(DeviceRecord {
            id: device_id(id)?,
            name,
            platform,
            presence_key: PresenceKey::from_bytes(
                presence
                    .try_into()
                    .map_err(|_| StoreError::Corrupt("presence key"))?,
            ),
            paired_at_ms,
            last_seen_ms,
            last_addr,
        })
    })())
}

#[cfg(test)]
mod tests {
    use super::*;
    use brege_identity::SecretKey;

    #[test]
    fn migrations_are_valid() {
        migrations().validate().unwrap();
    }

    fn device() -> DeviceRecord {
        DeviceRecord {
            id: SecretKey::generate().unwrap().device_id(),
            name: "Pixel 9".into(),
            platform: 2,
            presence_key: PresenceKey::generate().unwrap(),
            paired_at_ms: 1,
            last_seen_ms: None,
            last_addr: None,
        }
    }

    #[test]
    fn file_is_encrypted_and_needs_the_key() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("brege.db");
        let key = [42u8; 32];
        {
            let store = Store::open(&path, &key).unwrap();
            assert!(
                store.cipher_version().unwrap().is_some(),
                "SQLCipher must be linked"
            );
            store.upsert_device(&device()).unwrap();
        }
        let raw = std::fs::read(&path).unwrap();
        assert!(
            !raw.starts_with(b"SQLite format 3"),
            "database must not be plaintext"
        );
        assert!(matches!(
            Store::open(&path, &[1u8; 32]),
            Err(StoreError::WrongKey)
        ));
        assert_eq!(
            Store::open(&path, &key).unwrap().devices().unwrap().len(),
            1
        );
    }

    #[test]
    fn devices_and_cascade() {
        let store = Store::open_in_memory(&[0u8; 32]).unwrap();
        let d = device();
        store.upsert_device(&d).unwrap();
        store.mark_seen(&d.id, 99, Some("10.0.0.2:47400")).unwrap();
        let got = store.device(&d.id).unwrap().unwrap();
        assert_eq!(got.last_seen_ms, Some(99));
        assert_eq!(got.last_addr.as_deref(), Some("10.0.0.2:47400"));

        store
            .upsert_notification(&NotificationRecord {
                device_id: d.id,
                key: "k1".into(),
                package: "com.whatsapp".into(),
                app_label: "WhatsApp".into(),
                title: "Anna".into(),
                text: "hoi".into(),
                posted_at_ms: 1_000,
                dismissed: false,
            })
            .unwrap();
        store.dismiss_notification(&d.id, "k1").unwrap();
        assert!(store.recent_notifications(10).unwrap()[0].dismissed);
        assert!(store.remove_device(&d.id).unwrap());
        assert!(
            store.recent_notifications(10).unwrap().is_empty(),
            "cascade delete"
        );
    }

    #[test]
    fn notification_pruning() {
        let store = Store::open_in_memory(&[0u8; 32]).unwrap();
        let d = device();
        store.upsert_device(&d).unwrap();
        for (key, at) in [
            ("old", 0),
            ("new", NOTIFICATION_RETENTION_MS + 10),
            ("future", 3 * NOTIFICATION_RETENTION_MS),
        ] {
            store
                .upsert_notification(&NotificationRecord {
                    device_id: d.id,
                    key: key.into(),
                    package: "p".into(),
                    app_label: "a".into(),
                    title: "t".into(),
                    text: "x".into(),
                    posted_at_ms: at,
                    dismissed: false,
                })
                .unwrap();
        }
        assert_eq!(
            store
                .prune_notifications(NOTIFICATION_RETENTION_MS + 20)
                .unwrap(),
            2
        );
        let left = store.recent_notifications(10).unwrap();
        assert_eq!(left.len(), 1);
        assert_eq!(left[0].key, "new");

        let now = 2 * NOTIFICATION_RETENTION_MS;
        for i in 0..MAX_NOTIFICATIONS + 3 {
            store
                .upsert_notification(&NotificationRecord {
                    device_id: d.id,
                    key: format!("k{i}"),
                    package: "p".into(),
                    app_label: "a".into(),
                    title: "t".into(),
                    text: "x".into(),
                    posted_at_ms: now - i,
                    dismissed: false,
                })
                .unwrap();
        }
        // Nothing expired, but "new" and the three oldest k rows are over the cap.
        assert_eq!(store.prune_notifications(now).unwrap(), 4);
        let left = store.recent_notifications(u32::MAX).unwrap();
        assert_eq!(left.len() as i64, MAX_NOTIFICATIONS);
        assert_eq!(
            left.last().unwrap().key,
            format!("k{}", MAX_NOTIFICATIONS - 1)
        );
    }

    #[test]
    fn transfer_resume_state() {
        let store = Store::open_in_memory(&[0u8; 32]).unwrap();
        let d = device();
        store.upsert_device(&d).unwrap();
        let t = TransferRecord {
            id: "abc".into(),
            device_id: d.id,
            direction: TransferDirection::Incoming,
            name: "a.jpg".into(),
            size: 5_000_000,
            chunk_size: 1 << 20,
            root_hash: [9; 32],
            state: TransferState::Offered,
            path: None,
            created_at_ms: 5,
        };
        store.insert_transfer(&t).unwrap();
        store.add_transfer_chunk("abc", 3).unwrap();
        store.add_transfer_chunk("abc", 0).unwrap();
        store.add_transfer_chunk("abc", 3).unwrap();
        assert_eq!(store.transfer_chunks("abc").unwrap(), [0, 3].into());
        store
            .set_transfer_state("abc", TransferState::Complete, Some("/tmp/a.jpg"))
            .unwrap();
        let got = store.transfer("abc").unwrap().unwrap();
        assert_eq!(got.state, TransferState::Complete);
        assert_eq!(got.path.as_deref(), Some("/tmp/a.jpg"));
        assert!(store.unfinished_outgoing(&d.id).unwrap().is_empty());
        store
            .insert_transfer(&TransferRecord {
                id: "out".into(),
                direction: TransferDirection::Outgoing,
                ..t
            })
            .unwrap();
        assert_eq!(store.unfinished_outgoing(&d.id).unwrap()[0].id, "out");
    }
}
