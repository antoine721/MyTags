// Column specs of the synced tables (mirror of migrations/0001_init.sql).
// They drive request validation and the generated SQL (json_each writes,
// json_object reads), so API <-> D1 conversions live in one place.

/**
 * - text/int/real: stored as-is.
 * - time: TEXT holding an ISO 8601 UTC timestamp with milliseconds; compared
 *   as strings for last-write-wins, hence the strict format.
 * - bool: INTEGER 0/1 in D1, true/false in the API.
 * - json: TEXT holding JSON in D1, a real JSON value in the API.
 */
export type ColumnType = "text" | "int" | "real" | "time" | "bool" | "json";

export interface Column {
  type: ColumnType;
  /** The key must be present and non-null in API rows. */
  required?: true;
  /** SQL literal used when the API value is absent or null (NOT NULL DEFAULT columns). */
  default?: string;
}

export interface TableSpec {
  name: TableName;
  /** Primary key column (conflict target). track_values is never upserted generically. */
  key: string;
  /** Every column except `rev`, which the server always assigns. */
  columns: Readonly<Record<string, Column>>;
}

export type TableName =
  | "tracks"
  | "fields"
  | "field_options"
  | "track_values"
  | "changes"
  | "apply_runs"
  | "rules"
  | "saved_views"
  | "settings";

const text = { type: "text" } as const;
const requiredText = { type: "text", required: true } as const;
const int = { type: "int" } as const;
const json = { type: "json" } as const;
const updatedAt = { type: "time", required: true } as const;
const deletedAt = text;
const position = { type: "int", default: "0" } as const;
const boolDefault = (value: 0 | 1): Column => ({ type: "bool", default: String(value) });

const tracks: TableSpec = {
  name: "tracks",
  key: "id",
  columns: {
    id: requiredText,
    file_path: requiredText,
    file_format: requiredText,
    file_size: int,
    file_mtime: text,
    fingerprint: text,
    title: text,
    artist: text,
    album: text,
    bpm: { type: "real" },
    musical_key: text,
    duration_ms: int,
    added_at: text,
    start_ms: int,
    waveform: text,
    audio_key: text,
    audio_size: int,
    cover_key: text,
    source_tags: json,
    baseline: json,
    comment_status: text,
    apply_status: { type: "text", default: "'aucun'" },
    apply_message: text,
    applied_at: text,
    updated_at: updatedAt,
    deleted_at: deletedAt,
  },
};

const fields: TableSpec = {
  name: "fields",
  key: "id",
  columns: {
    id: requiredText,
    key: requiredText,
    name: requiredText,
    kind: requiredText,
    target_tag: requiredText,
    target_slot: int,
    required: boolDefault(0),
    visible: boolDefault(1),
    position,
    default_option_id: text,
    is_advance_trigger: boolDefault(0),
    artist_level: boolDefault(0),
    updated_at: updatedAt,
    deleted_at: deletedAt,
  },
};

const fieldOptions: TableSpec = {
  name: "field_options",
  key: "id",
  columns: {
    id: requiredText,
    field_id: requiredText,
    value: requiredText,
    label: text,
    color: text,
    aliases: { type: "json", default: "'[]'" },
    position,
    archived: boolDefault(0),
    updated_at: updatedAt,
    deleted_at: deletedAt,
  },
};

const trackValues: TableSpec = {
  name: "track_values",
  key: "track_id",
  columns: {
    track_id: requiredText,
    field_id: requiredText,
    option_ids: { type: "json", default: "'[]'" },
    rating: int,
    text_value: text,
    state: { type: "text", default: "'confirmed'" },
    source: { type: "text", default: "'user'" },
    updated_at: updatedAt,
    device_id: text,
    deleted_at: deletedAt,
  },
};

const changes: TableSpec = {
  name: "changes",
  key: "id",
  columns: {
    id: requiredText,
    track_id: requiredText,
    field_id: requiredText,
    old_value: json,
    new_value: json,
    source: { type: "text", default: "'user'" },
    created_at: { type: "time", required: true },
    device_id: text,
    status: { type: "text", default: "'sent'" },
    apply_run_id: text,
    updated_at: updatedAt,
  },
};

const applyRuns: TableSpec = {
  name: "apply_runs",
  key: "id",
  columns: {
    id: requiredText,
    started_at: requiredText,
    finished_at: text,
    mode: requiredText,
    tracks_written: { type: "int", default: "0" },
    conflicts: { type: "int", default: "0" },
    errors: { type: "int", default: "0" },
    backup_path: text,
    report_path: text,
    updated_at: updatedAt,
  },
};

const rules: TableSpec = {
  name: "rules",
  key: "id",
  columns: {
    id: requiredText,
    name: requiredText,
    enabled: boolDefault(1),
    position,
    condition: { type: "json", required: true },
    action: { type: "json", required: true },
    mode: { type: "text", default: "'suggest'" },
    updated_at: updatedAt,
    deleted_at: deletedAt,
  },
};

const savedViews: TableSpec = {
  name: "saved_views",
  key: "id",
  columns: {
    id: requiredText,
    name: requiredText,
    filters: { type: "json", default: "'{}'" },
    sort: { type: "json", default: "'{}'" },
    skip_complete: boolDefault(0),
    position,
    builtin: boolDefault(0),
    updated_at: updatedAt,
    deleted_at: deletedAt,
  },
};

const settings: TableSpec = {
  name: "settings",
  key: "key",
  columns: {
    key: requiredText,
    value: json,
    updated_at: updatedAt,
    deleted_at: deletedAt,
  },
};

export const TABLES: Readonly<Record<TableName, TableSpec>> = {
  tracks,
  fields,
  field_options: fieldOptions,
  track_values: trackValues,
  changes,
  apply_runs: applyRuns,
  rules,
  saved_views: savedViews,
  settings,
};

/** Tables a device token may pull. */
export const DEVICE_PULL_TABLES: ReadonlySet<TableName> = new Set([
  "tracks",
  "fields",
  "field_options",
  "track_values",
  "rules",
  "saved_views",
  "settings",
]);

/** Configuration tables written by POST /v1/sync/push and POST /v1/admin/config/reset. */
export const CONFIG_TABLES = ["fields", "field_options", "rules", "saved_views", "settings"] as const;

export function isTableName(name: string): name is TableName {
  return Object.hasOwn(TABLES, name);
}
