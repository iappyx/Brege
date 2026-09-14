-- Schema version 3: networks and tunnels a paired device was reached through.
-- Brêge only announces, dials and answers on these.

CREATE TABLE known_network (
    fingerprint   TEXT PRIMARY KEY,            -- "lan:<subnet>|<gateway>|<gateway hw>" or "vpn:<address>"
    kind          TEXT NOT NULL,               -- "lan" or "vpn"
    label         TEXT NOT NULL,               -- shown in Settings, e.g. "Wi‑Fi 192.168.50.0/24"
    added_ms      INTEGER NOT NULL,
    last_used_ms  INTEGER NOT NULL
) STRICT;
