-- Schema version 4: Wi‑Fi names for known networks, and networks the user chose not to use.

ALTER TABLE known_network ADD COLUMN ssid TEXT NOT NULL DEFAULT '';      -- "" when unknown
ALTER TABLE known_network ADD COLUMN trusted INTEGER NOT NULL DEFAULT 1; -- 0: "Not here"
