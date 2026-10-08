-- MyTags D1 schema. Every synced table carries `rev` (global server revision,
-- bumped in the same transaction as the write) and is pulled with a
-- (rev, rowid) cursor. Timestamps are ISO 8601 UTC strings with milliseconds.

CREATE TABLE counters (
  name  TEXT PRIMARY KEY,
  value INTEGER NOT NULL
);
INSERT INTO counters (name, value) VALUES ('rev', 0);

CREATE TABLE tracks (
  id             TEXT PRIMARY KEY,
  file_path      TEXT NOT NULL,
  file_format    TEXT NOT NULL,
  file_size      INTEGER,
  file_mtime     TEXT,
  fingerprint    TEXT,
  title          TEXT,
  artist         TEXT,
  album          TEXT,
  bpm            REAL,
  musical_key    TEXT,
  duration_ms    INTEGER,
  added_at       TEXT,
  start_ms       INTEGER,
  waveform       TEXT,              -- base64, ~600 bytes
  audio_key      TEXT,
  audio_size     INTEGER,
  cover_key      TEXT,              -- prefix: <cover_key>_600.jpg / _150.jpg
  source_tags    TEXT,              -- JSON
  baseline       TEXT,              -- JSON {genre, grouping, comment, rating}
  comment_status TEXT,              -- conforme | incomplet | non_conforme
  apply_status   TEXT NOT NULL DEFAULT 'aucun', -- aucun | applique | conflit | erreur
  apply_message  TEXT,
  applied_at     TEXT,
  updated_at     TEXT NOT NULL,
  deleted_at     TEXT,
  rev            INTEGER NOT NULL
);
CREATE INDEX tracks_rev ON tracks (rev);

CREATE TABLE fields (
  id                 TEXT PRIMARY KEY,
  key                TEXT NOT NULL,
  name               TEXT NOT NULL,
  kind               TEXT NOT NULL,   -- single | multi | rating | text
  target_tag         TEXT NOT NULL,   -- GENRE | GROUPING | COMMENT | RATING
  target_slot        INTEGER,
  required           INTEGER NOT NULL DEFAULT 0,
  visible            INTEGER NOT NULL DEFAULT 1,
  position           INTEGER NOT NULL DEFAULT 0,
  default_option_id  TEXT,
  is_advance_trigger INTEGER NOT NULL DEFAULT 0,
  artist_level       INTEGER NOT NULL DEFAULT 0,
  updated_at         TEXT NOT NULL,
  deleted_at         TEXT,
  rev                INTEGER NOT NULL
);
CREATE INDEX fields_rev ON fields (rev);

CREATE TABLE field_options (
  id         TEXT PRIMARY KEY,
  field_id   TEXT NOT NULL,
  value      TEXT NOT NULL,
  label      TEXT,
  color      TEXT,
  aliases    TEXT NOT NULL DEFAULT '[]', -- JSON array of strings
  position   INTEGER NOT NULL DEFAULT 0,
  archived   INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  rev        INTEGER NOT NULL
);
CREATE INDEX field_options_rev ON field_options (rev);

CREATE TABLE track_values (
  track_id   TEXT NOT NULL,
  field_id   TEXT NOT NULL,
  option_ids TEXT NOT NULL DEFAULT '[]', -- JSON array of option ids
  rating     INTEGER,
  text_value TEXT,
  state      TEXT NOT NULL DEFAULT 'confirmed',
  source     TEXT NOT NULL DEFAULT 'user',
  updated_at TEXT NOT NULL,             -- created_at of the winning change
  device_id  TEXT,
  deleted_at TEXT,
  rev        INTEGER NOT NULL,
  PRIMARY KEY (track_id, field_id)
);
CREATE INDEX track_values_rev ON track_values (rev);

CREATE TABLE changes (
  id           TEXT PRIMARY KEY,        -- created by the writing device
  track_id     TEXT NOT NULL,
  field_id     TEXT NOT NULL,
  old_value    TEXT,                    -- JSON or NULL
  new_value    TEXT,                    -- JSON or NULL (NULL = back to file value)
  source       TEXT NOT NULL DEFAULT 'user',
  created_at   TEXT NOT NULL,
  device_id    TEXT,
  status       TEXT NOT NULL DEFAULT 'sent', -- sent | applied | superseded
  apply_run_id TEXT,
  updated_at   TEXT NOT NULL,
  rev          INTEGER NOT NULL
);
CREATE INDEX changes_rev ON changes (rev);
CREATE INDEX changes_track_field ON changes (track_id, field_id, created_at);

CREATE TABLE apply_runs (
  id             TEXT PRIMARY KEY,
  started_at     TEXT NOT NULL,
  finished_at    TEXT,
  mode           TEXT NOT NULL,         -- dry_run | apply | rollback
  tracks_written INTEGER NOT NULL DEFAULT 0,
  conflicts      INTEGER NOT NULL DEFAULT 0,
  errors         INTEGER NOT NULL DEFAULT 0,
  backup_path    TEXT,
  report_path    TEXT,
  updated_at     TEXT NOT NULL,
  rev            INTEGER NOT NULL
);
CREATE INDEX apply_runs_rev ON apply_runs (rev);

CREATE TABLE rules (
  id         TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  enabled    INTEGER NOT NULL DEFAULT 1,
  position   INTEGER NOT NULL DEFAULT 0,
  condition  TEXT NOT NULL,             -- JSON
  action     TEXT NOT NULL,             -- JSON
  mode       TEXT NOT NULL DEFAULT 'suggest', -- suggest | apply
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  rev        INTEGER NOT NULL
);
CREATE INDEX rules_rev ON rules (rev);

CREATE TABLE saved_views (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  filters       TEXT NOT NULL DEFAULT '{}', -- JSON
  sort          TEXT NOT NULL DEFAULT '{}', -- JSON
  skip_complete INTEGER NOT NULL DEFAULT 0,
  position      INTEGER NOT NULL DEFAULT 0,
  builtin       INTEGER NOT NULL DEFAULT 0,
  updated_at    TEXT NOT NULL,
  deleted_at    TEXT,
  rev           INTEGER NOT NULL
);
CREATE INDEX saved_views_rev ON saved_views (rev);

CREATE TABLE settings (
  key        TEXT PRIMARY KEY,
  value      TEXT,                      -- JSON
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  rev        INTEGER NOT NULL
);
CREATE INDEX settings_rev ON settings (rev);

CREATE TABLE devices (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL,
  token_hash   TEXT NOT NULL UNIQUE,
  created_at   TEXT NOT NULL,
  last_seen_at TEXT,
  revoked_at   TEXT
);
