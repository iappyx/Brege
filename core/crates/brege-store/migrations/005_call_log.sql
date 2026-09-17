-- Schema version 5: the phone's recent calls, cached on the Mac.

CREATE TABLE call_log (
    device_id     BLOB NOT NULL REFERENCES device(id) ON DELETE CASCADE,
    id            TEXT NOT NULL,               -- the phone's call-log row id
    number        TEXT NOT NULL,
    name          TEXT NOT NULL,               -- contact name, "" if unknown
    direction     INTEGER NOT NULL,            -- brege.v1.CallLogEntry.Direction
    started_ms    INTEGER NOT NULL,
    duration_s    INTEGER NOT NULL,
    sub_id        INTEGER NOT NULL,            -- -1 when unknown
    PRIMARY KEY (device_id, id)
) STRICT;
CREATE INDEX call_log_started ON call_log(device_id, started_ms);
