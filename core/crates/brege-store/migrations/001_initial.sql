-- Brêge core database, schema version 1.

CREATE TABLE device (
    id            BLOB PRIMARY KEY NOT NULL,   -- 32-byte Ed25519 public key
    name          TEXT NOT NULL,
    platform      INTEGER NOT NULL,            -- brege.v1.Platform
    presence_key  BLOB NOT NULL,               -- 32 bytes
    paired_at_ms  INTEGER NOT NULL,
    last_seen_ms  INTEGER,
    last_addr     TEXT                         -- last known ip:port, for dialling
) STRICT;

CREATE TABLE notification (
    key           TEXT NOT NULL,
    device_id     BLOB NOT NULL REFERENCES device(id) ON DELETE CASCADE,
    package       TEXT NOT NULL,
    app_label     TEXT NOT NULL,
    title         TEXT NOT NULL,
    text          TEXT NOT NULL,
    posted_at_ms  INTEGER NOT NULL,
    dismissed     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (device_id, key)
) STRICT;
CREATE INDEX notification_posted ON notification(posted_at_ms);

CREATE TABLE transfer (
    id            TEXT PRIMARY KEY NOT NULL,
    device_id     BLOB NOT NULL REFERENCES device(id) ON DELETE CASCADE,
    direction     INTEGER NOT NULL,            -- 0 = incoming, 1 = outgoing
    name          TEXT NOT NULL,
    size          INTEGER NOT NULL,
    chunk_size    INTEGER NOT NULL,
    root_hash     BLOB NOT NULL,
    state         INTEGER NOT NULL,            -- see TransferState
    path          TEXT,                        -- source path (outgoing) or final path (incoming)
    created_at_ms INTEGER NOT NULL
) STRICT;

CREATE TABLE transfer_chunk (
    transfer_id   TEXT NOT NULL REFERENCES transfer(id) ON DELETE CASCADE,
    idx           INTEGER NOT NULL,
    PRIMARY KEY (transfer_id, idx)
) STRICT, WITHOUT ROWID;

CREATE TABLE clipboard_history (
    id            INTEGER PRIMARY KEY,
    kind          INTEGER NOT NULL,
    data          BLOB NOT NULL,
    ts_ms         INTEGER NOT NULL,
    origin_device BLOB
) STRICT;
