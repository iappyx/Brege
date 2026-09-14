-- Schema version 2: message cache on the Mac.

CREATE TABLE msg_thread (
    device_id     BLOB NOT NULL REFERENCES device(id) ON DELETE CASCADE,
    id            TEXT NOT NULL,               -- "sms:<id>" or "rcs:<key>"
    addresses     TEXT NOT NULL,               -- JSON-free: unit-separator (0x1F) joined
    names         TEXT NOT NULL,               -- parallel to addresses
    title         TEXT NOT NULL,
    snippet       TEXT NOT NULL,
    last_ms       INTEGER NOT NULL,
    kind          INTEGER NOT NULL,            -- brege.v1.MessageKind
    can_reply     INTEGER NOT NULL,
    unread        INTEGER NOT NULL DEFAULT 0,  -- local to the Mac
    PRIMARY KEY (device_id, id)
) STRICT;
CREATE INDEX msg_thread_last ON msg_thread(device_id, last_ms);

CREATE TABLE msg_message (
    device_id     BLOB NOT NULL REFERENCES device(id) ON DELETE CASCADE,
    id            TEXT NOT NULL,               -- "sms:<id>", "mms:<id>", "rcs:<hash>"
    thread_id     TEXT NOT NULL,
    address       TEXT NOT NULL,
    sender_name   TEXT NOT NULL,
    body          TEXT NOT NULL,
    ts_ms         INTEGER NOT NULL,
    outgoing      INTEGER NOT NULL,
    sub_id        INTEGER NOT NULL,
    status        INTEGER NOT NULL,            -- brege.v1.SmsMessage.Status
    has_media     INTEGER NOT NULL,
    kind          INTEGER NOT NULL,
    PRIMARY KEY (device_id, id)
) STRICT;
CREATE INDEX msg_message_thread ON msg_message(device_id, thread_id, ts_ms);

CREATE TABLE sim (
    device_id     BLOB NOT NULL REFERENCES device(id) ON DELETE CASCADE,
    sub_id        INTEGER NOT NULL,
    label         TEXT NOT NULL,
    slot          INTEGER NOT NULL,
    PRIMARY KEY (device_id, sub_id)
) STRICT;
