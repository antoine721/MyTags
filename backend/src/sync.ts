// POST /v1/sync/pull and POST /v1/sync/push.

import { CURRENT_REV, jsonParam, pageSql, readRev, readRevStatement, revOf, upsertSql, writeWithRev } from "./db";
import { HttpError, badRequest, isObject, json, jsonText, nowIso, readJsonObject, type JsonObject } from "./http";
import { apiToColumn } from "./json";
import { principalOf, type RequestContext } from "./router";
import { CONFIG_TABLES, DEVICE_PULL_TABLES, TABLES, isTableName, type TableName } from "./tables";
import { arrayOf, validateRow, validateRows } from "./validate";

const PULL_DEFAULT_LIMIT = 500;
const PULL_MAX_LIMIT = 1000;
const MAX_CHANGES = 500;
const MAX_CONFIG_ROWS = 500;

/** device_id recorded for changes pushed with the admin token. */
const ADMIN_DEVICE_ID = "mac";

// ---------------------------------------------------------------------------
// Pull

interface Cursor {
  rev: number;
  rowid: number;
}

interface PageRow {
  rev: number;
  rid: number;
  /** The row serialized by SQLite (json_object). */
  obj: string;
}

const PAGE_SQL = Object.fromEntries(
  Object.values(TABLES).map((spec) => [spec.name, pageSql(spec)]),
) as Record<TableName, string>;

export async function handlePull(context: RequestContext): Promise<Response> {
  const { env } = context;
  const principal = principalOf(context);
  const body = await readJsonObject(context.request);
  const limit = parseLimit(body.limit);
  if (!isObject(body.cursors)) throw badRequest("cursors must be an object");

  const requested = Object.entries(body.cursors).map(([table, cursor]) => {
    if (!isTableName(table)) throw badRequest(`Unknown table: ${table}`);
    if (principal.role !== "admin" && !DEVICE_PULL_TABLES.has(table)) {
      throw new HttpError(403, "forbidden", `Table ${table} requires the admin token`);
    }
    return { table, cursor: parseCursor(cursor, `cursors.${table}`) };
  });

  // One batch = one consistent snapshot of every table and of server_rev.
  const [revResult, ...pages] = await env.DB.batch([
    readRevStatement(env.DB),
    ...requested.map(({ table, cursor }) =>
      env.DB.prepare(PAGE_SQL[table]).bind(cursor.rev, cursor.rowid, limit + 1),
    ),
  ]);

  // Rows arrive as JSON text from SQLite: splice them in instead of parsing.
  const tables = requested.map(
    ({ table, cursor }, index) => `"${table}":${pageJson(pages[index], cursor, limit)}`,
  );
  return jsonText(`{"tables":{${tables.join(",")}},"server_rev":${revOf(revResult)}}`);
}

function pageJson(result: D1Result | undefined, cursor: Cursor, limit: number): string {
  const rows = (result?.results ?? []) as PageRow[];
  const hasMore = rows.length > limit;
  if (hasMore) rows.length = limit;
  const last = rows.at(-1);
  const next = last === undefined ? cursor : { rev: last.rev, rowid: last.rid };
  return (
    `{"rows":[${rows.map((row) => row.obj).join(",")}],` +
    `"cursor":{"rev":${next.rev},"rowid":${next.rowid}},"has_more":${hasMore}}`
  );
}

function parseLimit(value: unknown): number {
  if (value === undefined || value === null) return PULL_DEFAULT_LIMIT;
  if (!Number.isSafeInteger(value) || (value as number) < 1) {
    throw badRequest("limit must be a positive integer");
  }
  return Math.min(value as number, PULL_MAX_LIMIT);
}

function parseCursor(value: unknown, where: string): Cursor {
  if (value === null) return { rev: 0, rowid: 0 };
  if (!isObject(value)) throw badRequest(`${where} must be an object {rev, rowid}`);
  const rev = value.rev ?? 0;
  const rowid = value.rowid ?? 0;
  if (!isCounter(rev) || !isCounter(rowid)) {
    throw badRequest(`${where}.rev and .rowid must be non-negative integers`);
  }
  return { rev, rowid };
}

function isCounter(value: unknown): value is number {
  return Number.isSafeInteger(value) && (value as number) >= 0;
}

// ---------------------------------------------------------------------------
// Push

const changeColumn = (name: string) => {
  const column = TABLES.changes.columns[name];
  if (column === undefined) throw new Error(`unknown column changes.${name}`);
  return apiToColumn(name, column, "j.value");
};

/** ?1 = changes JSON, ?2 = device id, ?3 = now. Known ids are ignored (idempotent). */
const INSERT_CHANGES = `
INSERT INTO changes (id, track_id, field_id, old_value, new_value, source, created_at,
                     device_id, status, apply_run_id, updated_at, rev)
SELECT ${changeColumn("id")}, ${changeColumn("track_id")}, ${changeColumn("field_id")}, ${changeColumn("old_value")},
       ${changeColumn("new_value")}, ${changeColumn("source")}, ${changeColumn("created_at")},
       ?2, 'sent', NULL, ?3, ${CURRENT_REV}
FROM json_each(?1) AS j WHERE true
ON CONFLICT (id) DO NOTHING`;

/**
 * Applies the changes inserted by this batch (rev = current) to track_values,
 * last write wins on created_at (ties: the later change). A retried change is
 * not re-inserted above, so it rewrites nothing here.
 */
const APPLY_NEW_CHANGES = `
INSERT INTO track_values (track_id, field_id, option_ids, rating, text_value, state, source,
                          updated_at, device_id, deleted_at, rev)
SELECT track_id, field_id,
       coalesce(nullif(new_value -> '$.option_ids', 'null'), '[]'),
       new_value ->> '$.rating',
       new_value ->> '$.text',
       'confirmed', source, created_at, device_id,
       CASE WHEN new_value IS NULL THEN created_at END,
       rev
FROM changes WHERE rev = ${CURRENT_REV}
ORDER BY rowid
ON CONFLICT (track_id, field_id) DO UPDATE SET
  option_ids = excluded.option_ids, rating = excluded.rating, text_value = excluded.text_value,
  state = excluded.state, source = excluded.source, updated_at = excluded.updated_at,
  device_id = excluded.device_id, deleted_at = excluded.deleted_at, rev = excluded.rev
WHERE excluded.updated_at >= track_values.updated_at`;

/**
 * Gives the current rev to every track_values row touched by this batch whose
 * upsert lost to a newer stored value (its values are left as they are). The
 * pushing device may have skipped that row during an earlier pull because it
 * had a pending edit, and its cursor is already past it: the new rev sends it
 * the winning value on its next pull. Must run before SUPERSEDE_OLDER, which
 * also gives the current rev to changes.
 */
const REPUBLISH_LOSING_VALUES = `
UPDATE track_values SET rev = ${CURRENT_REV}
WHERE (track_id, field_id) IN (SELECT track_id, field_id FROM changes WHERE rev = ${CURRENT_REV})
  AND rev <> ${CURRENT_REV}`;

/**
 * For the (track_id, field_id) pairs touched by this batch, 'sent' changes
 * that have a newer change become 'superseded'. ?1 = now.
 */
const SUPERSEDE_OLDER = `
UPDATE changes SET status = 'superseded', updated_at = ?1, rev = ${CURRENT_REV}
WHERE status = 'sent'
  AND (track_id, field_id) IN (SELECT track_id, field_id FROM changes WHERE rev = ${CURRENT_REV})
  AND EXISTS (
    SELECT 1 FROM changes AS newer
    WHERE newer.track_id = changes.track_id AND newer.field_id = changes.field_id
      AND (newer.created_at > changes.created_at
           OR (newer.created_at = changes.created_at AND newer.rowid > changes.rowid)))`;

const CONFIG_UPSERT_SQL = Object.fromEntries(
  CONFIG_TABLES.map((table) => [table, upsertSql(TABLES[table], { lww: true, serverTime: false })]),
) as Record<(typeof CONFIG_TABLES)[number], string>;

export async function handlePush(context: RequestContext): Promise<Response> {
  const { env } = context;
  const principal = principalOf(context);
  const body = await readJsonObject(context.request);
  const changes = validateChanges(body.changes);
  const config = CONFIG_TABLES.map(
    (table) => [table, validateRows(TABLES[table], body[table], table, MAX_CONFIG_ROWS)] as const,
  );
  const acceptedChanges = [...new Set(changes.map((row) => row.id as string))];

  const db = env.DB;
  const statements: D1PreparedStatement[] = [];
  if (changes.length > 0) {
    const now = nowIso();
    const deviceId = principal.role === "device" ? principal.deviceId : ADMIN_DEVICE_ID;
    statements.push(
      db.prepare(INSERT_CHANGES).bind(jsonParam(changes), deviceId, now),
      db.prepare(APPLY_NEW_CHANGES),
      db.prepare(REPUBLISH_LOSING_VALUES),
      db.prepare(SUPERSEDE_OLDER).bind(now),
    );
  }
  for (const [table, rows] of config) {
    if (rows.length > 0) statements.push(db.prepare(CONFIG_UPSERT_SQL[table]).bind(jsonParam(rows)));
  }

  const rev = statements.length === 0 ? await readRev(db) : (await writeWithRev(db, statements)).rev;
  return json({ accepted_changes: acceptedChanges, rev });
}

function validateChanges(value: unknown): JsonObject[] {
  return arrayOf(value, "changes", MAX_CHANGES).map((item, index) => {
    const where = `changes[${index}]`;
    const row = validateRow(TABLES.changes, item, where, { serverTime: true });
    if (!("new_value" in row)) {
      throw badRequest(`${where}.new_value is required (null resets the value to the file's)`);
    }
    validateNewValue(row.new_value, `${where}.new_value`);
    return row;
  });
}

function validateNewValue(value: unknown, where: string): void {
  if (value === null) return;
  if (!isObject(value)) throw badRequest(`${where} must be an object or null`);
  const { option_ids: optionIds, rating, text } = value;
  if (
    optionIds !== undefined &&
    optionIds !== null &&
    !(Array.isArray(optionIds) && optionIds.every((id) => typeof id === "string"))
  ) {
    throw badRequest(`${where}.option_ids must be an array of strings`);
  }
  if (rating !== undefined && rating !== null && !Number.isSafeInteger(rating)) {
    throw badRequest(`${where}.rating must be an integer or null`);
  }
  if (text !== undefined && text !== null && typeof text !== "string") {
    throw badRequest(`${where}.text must be a string or null`);
  }
}
