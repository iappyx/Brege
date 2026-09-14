//! Message cache on the Mac: threads, messages and SIMs per paired phone.

use brege_identity::DeviceId;
use rusqlite::{OptionalExtension, params};

use crate::{Store, StoreError};

/// Separator for list columns; cannot occur in phone numbers or contact names in practice.
const SEP: char = '\u{1F}';

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThreadRecord {
    pub device_id: DeviceId,
    pub id: String,
    pub addresses: Vec<String>,
    pub names: Vec<String>,
    pub title: String,
    pub snippet: String,
    pub last_ms: i64,
    pub kind: i32,
    pub can_reply: bool,
    pub unread: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageRecord {
    pub device_id: DeviceId,
    pub id: String,
    pub thread_id: String,
    pub address: String,
    pub sender_name: String,
    pub body: String,
    pub ts_ms: i64,
    pub outgoing: bool,
    pub sub_id: i32,
    pub status: i32,
    pub has_media: bool,
    pub kind: i32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SimRecord {
    pub sub_id: i32,
    pub label: String,
    pub slot: i32,
}

fn join(values: &[String]) -> String {
    values.join(&SEP.to_string())
}

fn split(value: String) -> Vec<String> {
    if value.is_empty() {
        Vec::new()
    } else {
        value.split(SEP).map(str::to_string).collect()
    }
}

impl Store {
    /// Inserts or updates a thread. The local unread flag is kept unless `mark_unread` is set.
    pub fn upsert_thread(&self, t: &ThreadRecord, mark_unread: bool) -> Result<(), StoreError> {
        self.conn.execute(
            "INSERT INTO msg_thread (device_id, id, addresses, names, title, snippet, last_ms, kind, can_reply, unread)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
             ON CONFLICT(device_id, id) DO UPDATE SET addresses = excluded.addresses,
               names = excluded.names, title = excluded.title,
               snippet = CASE WHEN excluded.last_ms >= msg_thread.last_ms THEN excluded.snippet ELSE msg_thread.snippet END,
               last_ms = MAX(msg_thread.last_ms, excluded.last_ms),
               kind = excluded.kind, can_reply = excluded.can_reply,
               unread = CASE WHEN ?10 THEN 1 ELSE msg_thread.unread END",
            params![
                t.device_id.as_bytes().as_slice(),
                t.id,
                join(&t.addresses),
                join(&t.names),
                t.title,
                t.snippet,
                t.last_ms,
                t.kind,
                t.can_reply,
                mark_unread
            ],
        )?;
        Ok(())
    }

    pub fn threads(&self, device: &DeviceId, limit: u32) -> Result<Vec<ThreadRecord>, StoreError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, addresses, names, title, snippet, last_ms, kind, can_reply, unread
             FROM msg_thread WHERE device_id = ?1 ORDER BY last_ms DESC LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![device.as_bytes().as_slice(), limit], |r| {
            Ok(ThreadRecord {
                device_id: *device,
                id: r.get(0)?,
                addresses: split(r.get(1)?),
                names: split(r.get(2)?),
                title: r.get(3)?,
                snippet: r.get(4)?,
                last_ms: r.get(5)?,
                kind: r.get(6)?,
                can_reply: r.get(7)?,
                unread: r.get(8)?,
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }

    pub fn set_thread_unread(
        &self,
        device: &DeviceId,
        thread_id: &str,
        unread: bool,
    ) -> Result<(), StoreError> {
        self.conn.execute(
            "UPDATE msg_thread SET unread = ?3 WHERE device_id = ?1 AND id = ?2",
            params![device.as_bytes().as_slice(), thread_id, unread],
        )?;
        Ok(())
    }

    /// Inserts or updates a message. Returns true if the message was new.
    pub fn upsert_message(&self, m: &MessageRecord) -> Result<bool, StoreError> {
        let existed: bool = self
            .conn
            .query_row(
                "SELECT 1 FROM msg_message WHERE device_id = ?1 AND id = ?2",
                params![m.device_id.as_bytes().as_slice(), m.id],
                |_| Ok(true),
            )
            .optional()?
            .unwrap_or(false);
        self.conn.execute(
            "INSERT INTO msg_message (device_id, id, thread_id, address, sender_name, body, ts_ms, outgoing, sub_id, status, has_media, kind)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
             ON CONFLICT(device_id, id) DO UPDATE SET thread_id = excluded.thread_id,
               address = excluded.address, sender_name = excluded.sender_name, body = excluded.body,
               ts_ms = excluded.ts_ms, outgoing = excluded.outgoing, sub_id = excluded.sub_id,
               status = excluded.status, has_media = excluded.has_media, kind = excluded.kind",
            params![
                m.device_id.as_bytes().as_slice(),
                m.id,
                m.thread_id,
                m.address,
                m.sender_name,
                m.body,
                m.ts_ms,
                m.outgoing,
                m.sub_id,
                m.status,
                m.has_media,
                m.kind
            ],
        )?;
        Ok(!existed)
    }

    /// The newest `limit` messages of a thread older than `before_ms`, oldest first.
    pub fn messages(
        &self,
        device: &DeviceId,
        thread_id: &str,
        before_ms: i64,
        limit: u32,
    ) -> Result<Vec<MessageRecord>, StoreError> {
        let mut stmt = self.conn.prepare(
            "SELECT id, thread_id, address, sender_name, body, ts_ms, outgoing, sub_id, status, has_media, kind
             FROM msg_message WHERE device_id = ?1 AND thread_id = ?2 AND ts_ms <= ?3
             ORDER BY ts_ms DESC LIMIT ?4",
        )?;
        let rows = stmt.query_map(
            params![device.as_bytes().as_slice(), thread_id, before_ms, limit],
            |r| {
                Ok(MessageRecord {
                    device_id: *device,
                    id: r.get(0)?,
                    thread_id: r.get(1)?,
                    address: r.get(2)?,
                    sender_name: r.get(3)?,
                    body: r.get(4)?,
                    ts_ms: r.get(5)?,
                    outgoing: r.get(6)?,
                    sub_id: r.get(7)?,
                    status: r.get(8)?,
                    has_media: r.get(9)?,
                    kind: r.get(10)?,
                })
            },
        )?;
        let mut messages: Vec<MessageRecord> = rows.collect::<Result<_, _>>()?;
        messages.reverse();
        Ok(messages)
    }

    /// Timestamp of the newest cached message for a phone, used as the incremental sync cursor.
    pub fn newest_message_ms(&self, device: &DeviceId) -> Result<Option<i64>, StoreError> {
        Ok(self.conn.query_row(
            "SELECT MAX(ts_ms) FROM msg_message WHERE device_id = ?1",
            [device.as_bytes().as_slice()],
            |r| r.get(0),
        )?)
    }

    pub fn replace_sims(&self, device: &DeviceId, sims: &[SimRecord]) -> Result<(), StoreError> {
        let tx = self.conn.unchecked_transaction()?;
        tx.execute(
            "DELETE FROM sim WHERE device_id = ?1",
            [device.as_bytes().as_slice()],
        )?;
        for sim in sims {
            tx.execute(
                "INSERT INTO sim (device_id, sub_id, label, slot) VALUES (?1, ?2, ?3, ?4)",
                params![
                    device.as_bytes().as_slice(),
                    sim.sub_id,
                    sim.label,
                    sim.slot
                ],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn sims(&self, device: &DeviceId) -> Result<Vec<SimRecord>, StoreError> {
        let mut stmt = self
            .conn
            .prepare("SELECT sub_id, label, slot FROM sim WHERE device_id = ?1 ORDER BY slot")?;
        let rows = stmt.query_map([device.as_bytes().as_slice()], |r| {
            Ok(SimRecord {
                sub_id: r.get(0)?,
                label: r.get(1)?,
                slot: r.get(2)?,
            })
        })?;
        Ok(rows.collect::<Result<_, _>>()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::DeviceRecord;
    use brege_identity::{PresenceKey, SecretKey};

    fn setup() -> (Store, DeviceId) {
        let store = Store::open_in_memory(&[0u8; 32]).unwrap();
        let id = SecretKey::generate().unwrap().device_id();
        store
            .upsert_device(&DeviceRecord {
                id,
                name: "Pixel".into(),
                platform: 2,
                presence_key: PresenceKey::generate().unwrap(),
                paired_at_ms: 1,
                last_seen_ms: None,
                last_addr: None,
            })
            .unwrap();
        (store, id)
    }

    fn message(device: DeviceId, id: &str, ts: i64) -> MessageRecord {
        MessageRecord {
            device_id: device,
            id: id.into(),
            thread_id: "sms:1".into(),
            address: "+31600000000".into(),
            sender_name: "Anna".into(),
            body: format!("body {id}"),
            ts_ms: ts,
            outgoing: false,
            sub_id: 1,
            status: 1,
            has_media: false,
            kind: 1,
        }
    }

    #[test]
    fn threads_keep_newest_snippet_and_local_unread() {
        let (store, dev) = setup();
        let mut t = ThreadRecord {
            device_id: dev,
            id: "sms:1".into(),
            addresses: vec!["+31600000000".into(), "+31611111111".into()],
            names: vec!["Anna".into(), String::new()],
            title: String::new(),
            snippet: "new".into(),
            last_ms: 200,
            kind: 1,
            can_reply: false,
            unread: false,
        };
        store.upsert_thread(&t, true).unwrap();
        t.snippet = "old".into();
        t.last_ms = 100;
        store.upsert_thread(&t, false).unwrap();
        let got = &store.threads(&dev, 10).unwrap()[0];
        assert_eq!(got.snippet, "new");
        assert_eq!(got.last_ms, 200);
        assert!(got.unread, "unread survives an update without mark_unread");
        assert_eq!(got.names, vec!["Anna".to_string(), String::new()]);
        store.set_thread_unread(&dev, "sms:1", false).unwrap();
        assert!(!store.threads(&dev, 10).unwrap()[0].unread);
    }

    #[test]
    fn messages_paging_and_cursor() {
        let (store, dev) = setup();
        for (i, ts) in [10, 30, 20, 40].into_iter().enumerate() {
            assert!(
                store
                    .upsert_message(&message(dev, &format!("sms:{i}"), ts))
                    .unwrap()
            );
        }
        assert!(
            !store.upsert_message(&message(dev, "sms:0", 10)).unwrap(),
            "update, not new"
        );
        let page = store.messages(&dev, "sms:1", i64::MAX, 2).unwrap();
        assert_eq!(
            page.iter().map(|m| m.ts_ms).collect::<Vec<_>>(),
            vec![30, 40]
        );
        // Inclusive, so messages sharing the oldest shown time are not skipped.
        let older = store.messages(&dev, "sms:1", 30, 10).unwrap();
        assert_eq!(
            older.iter().map(|m| m.ts_ms).collect::<Vec<_>>(),
            vec![10, 20, 30]
        );
        assert_eq!(store.newest_message_ms(&dev).unwrap(), Some(40));
    }

    #[test]
    fn sims_replace() {
        let (store, dev) = setup();
        let sims = vec![
            SimRecord {
                sub_id: 2,
                label: "Work".into(),
                slot: 1,
            },
            SimRecord {
                sub_id: 1,
                label: "KPN".into(),
                slot: 0,
            },
        ];
        store.replace_sims(&dev, &sims).unwrap();
        store.replace_sims(&dev, &sims[1..]).unwrap();
        assert_eq!(store.sims(&dev).unwrap(), vec![sims[1].clone()]);
    }
}
