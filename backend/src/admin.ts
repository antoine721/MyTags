// /v1/admin/* routes (admin token only): catalog writes from the Mac CLI,
// apply bookkeeping, devices and configuration reset.

import { forgetDevice, newDeviceToken, tokenHash } from "./auth";
import { CURRENT_REV, jsonParam, patchSql, readRev, softDeleteMissingSql, upsertSql, writeWithRev } from "./db";
import { badRequest, isObject, json, notFound, nowIso, readJsonObject, type JsonObject } from "./http";
import type { RequestContext } from "./router";
import { CONFIG_TABLES, TABLES } from "./tables";
import { arrayOf, checkValue, requireString, requireStringArray, validateRow, validateRows } from "./validate";

const MAX_TRACKS = 200;
const MAX_PATCHES = 500;
const MAX_MARK_TRACKS = 1000;
const MAX_CONFIG_ROWS = 500;
const MAX_DEVICE_NAME = 100;

// ---------------------------------------------------------------------------
// Tracks

const UPSERT_TRACKS = upsertSql(TABLES.tracks, { lww: false, serverTime: true });

/** Track columns a patch may set (id identifies the row; updated_at and rev are server-managed). */
const PATCHABLE_TRACK_COLUMNS = Object.keys(TABLES.tracks.columns).filter(
  (name) => name !== "id" && name !== "updated_at",
);
const PATCHABLE = new Set(PATCHABLE_TRACK_COLUMNS);
const PATCH_TRACKS = patchSql(TABLES.tracks, PATCHABLE_TRACK_COLUMNS);

/** POST /v1/admin/tracks {tracks: [full rows]}: insert or replace; updated_at = now. */
export async function handleTracksUpsert({ request, env }: RequestContext): Promise<Response> {
  const body = await readJsonObject(request);
  if (body.tracks === undefined) throw badRequest("tracks is required");
  const tracks = validateRows(TABLES.tracks, body.tracks, "tracks", MAX_TRACKS, { serverTime: true });
  if (tracks.length === 0) return json({ upserted: 0, rev: await readRev(env.DB) });
  const { rev } = await writeWithRev(env.DB, [
    env.DB.prepare(UPSERT_TRACKS).bind(jsonParam(tracks), nowIso()),
  ]);
  return json({ upserted: tracks.length, rev });
}

/** POST /v1/admin/tracks/patch {patches: [{id, ...columns}]}: partial updates; updated_at = now. */
export async function handleTracksPatch({ request, env }: RequestContext): Promise<Response> {
  const body = await readJsonObject(request);
  if (body.patches === undefined) throw badRequest("patches is required");
  const items = arrayOf(body.patches, "patches", MAX_PATCHES);
  // Several patches of the same track are merged (later keys win): UPDATE ... FROM
  // would otherwise apply only one of them.
  const merged = new Map<string, JsonObject>();
  items.forEach((item, index) => {
    const patch = validatePatch(item, `patches[${index}]`);
    const id = patch.id as string;
    merged.set(id, { ...merged.get(id), ...patch });
  });
  if (merged.size === 0) return json({ updated: 0, rev: await readRev(env.DB) });
  const { rev, results } = await writeWithRev(env.DB, [
    env.DB.prepare(PATCH_TRACKS).bind(jsonParam([...merged.values()]), nowIso()),
  ]);
  return json({ updated: results[0]?.meta.changes ?? 0, rev });
}

function validatePatch(item: unknown, where: string): JsonObject {
  if (!isObject(item)) throw badRequest(`${where} must be an object`);
  requireString(item.id, `${where}.id`);
  for (const [name, value] of Object.entries(item)) {
    if (name === "id") continue;
    const column = TABLES.tracks.columns[name];
    if (column === undefined || !PATCHABLE.has(name)) {
      throw badRequest(`${where}.${name} cannot be patched`);
    }
    const notNull = column.required === true || column.default !== undefined;
    if (value === null && notNull) throw badRequest(`${where}.${name} cannot be null`);
    checkValue(value, column, `${where}.${name}`, false);
  }
  return item;
}

// ---------------------------------------------------------------------------
// Changes and apply runs

const CHANGE_STATUSES = new Set(["sent", "applied", "superseded"]);

/**
 * ?1 track ids JSON, ?2 new status, ?3 from_status, ?4 now,
 * ?5 1 to set apply_run_id to ?6 (0 keeps it), ?7 up_to_rev (NULL = no bound).
 */
const MARK_CHANGES = `
UPDATE changes SET status = ?2,
                   apply_run_id = CASE WHEN ?5 THEN ?6 ELSE apply_run_id END,
                   updated_at = ?4, rev = ${CURRENT_REV}
WHERE status = ?3
  AND track_id IN (SELECT value FROM json_each(?1))
  AND (?7 IS NULL OR rev <= ?7)`;

/**
 * POST /v1/admin/changes/mark
 * {track_ids, status, from_status = "sent", apply_run_id?, up_to_rev?}:
 * changes of these tracks currently in `from_status` take `status` (apply:
 * sent -> applied; rollback: applied -> sent). apply_run_id is stored when the
 * key is present (null clears it). With up_to_rev, only changes the caller has
 * seen (rev <= up_to_rev) are updated, so a change pushed during an apply run
 * stays 'sent'.
 */
export async function handleChangesMark({ request, env }: RequestContext): Promise<Response> {
  const body = await readJsonObject(request);
  const trackIds = requireStringArray(body.track_ids, "track_ids", MAX_MARK_TRACKS);
  const status = changeStatus(body.status, "status");
  const fromStatus = body.from_status === undefined ? "sent" : changeStatus(body.from_status, "from_status");
  if (status === fromStatus) throw badRequest("status and from_status must differ");
  const setApplyRun = "apply_run_id" in body;
  const applyRunId = body.apply_run_id ?? null;
  if (applyRunId !== null && typeof applyRunId !== "string") {
    throw badRequest("apply_run_id must be a string or null");
  }
  const upToRev = body.up_to_rev ?? null;
  if (upToRev !== null && !(Number.isSafeInteger(upToRev) && (upToRev as number) >= 0)) {
    throw badRequest("up_to_rev must be a non-negative integer or null");
  }
  if (trackIds.length === 0) return json({ updated: 0, rev: await readRev(env.DB) });
  const statement = env.DB.prepare(MARK_CHANGES).bind(
    JSON.stringify(trackIds),
    status,
    fromStatus,
    nowIso(),
    setApplyRun ? 1 : 0,
    applyRunId,
    upToRev,
  );
  const { rev, results } = await writeWithRev(env.DB, [statement]);
  return json({ updated: results[0]?.meta.changes ?? 0, rev });
}

function changeStatus(value: unknown, where: string): string {
  if (typeof value !== "string" || !CHANGE_STATUSES.has(value)) {
    throw badRequest(`${where} must be 'sent', 'applied' or 'superseded'`);
  }
  return value;
}

const UPSERT_APPLY_RUN = upsertSql(TABLES.apply_runs, { lww: false, serverTime: true });

/** POST /v1/admin/apply-runs {run}: insert or replace one apply run; updated_at = now. */
export async function handleApplyRunUpsert({ request, env }: RequestContext): Promise<Response> {
  const body = await readJsonObject(request);
  const run = validateRow(TABLES.apply_runs, body.run, "run", { serverTime: true });
  const { rev } = await writeWithRev(env.DB, [
    env.DB.prepare(UPSERT_APPLY_RUN).bind(jsonParam([run]), nowIso()),
  ]);
  return json({ id: run.id, rev });
}

// ---------------------------------------------------------------------------
// Devices

/** POST /v1/admin/devices {name}: the token is returned once and never stored. */
export async function handleDeviceCreate({ request, env }: RequestContext): Promise<Response> {
  const body = await readJsonObject(request);
  const name = requireString(body.name, "name").trim();
  if (name.length === 0 || name.length > MAX_DEVICE_NAME) {
    throw badRequest(`name must have 1 to ${MAX_DEVICE_NAME} characters`);
  }
  const deviceId = crypto.randomUUID();
  const token = newDeviceToken();
  const createdAt = nowIso();
  await env.DB.prepare("INSERT INTO devices (id, name, token_hash, created_at) VALUES (?1, ?2, ?3, ?4)")
    .bind(deviceId, name, await tokenHash(token), createdAt)
    .run();
  return json({ device_id: deviceId, name, token, created_at: createdAt }, 201);
}

/** GET /v1/admin/devices: every device, without token hashes. */
export async function handleDeviceList({ env }: RequestContext): Promise<Response> {
  const { results } = await env.DB.prepare(
    "SELECT id, name, created_at, last_seen_at, revoked_at FROM devices ORDER BY created_at, id",
  ).all();
  return json({ devices: results });
}

/** DELETE /v1/admin/devices/<id>: revokes the device (idempotent). */
export async function handleDeviceRevoke({ env, params }: RequestContext): Promise<Response> {
  const deviceId = decodeURIComponent(params[0] ?? "");
  const row = await env.DB.prepare(
    "UPDATE devices SET revoked_at = coalesce(revoked_at, ?2) WHERE id = ?1 RETURNING id, revoked_at",
  )
    .bind(deviceId, nowIso())
    .first<{ id: string; revoked_at: string }>();
  if (row === null) throw notFound(`Unknown device: ${deviceId}`);
  forgetDevice(deviceId);
  return json({ device_id: row.id, revoked_at: row.revoked_at });
}

// ---------------------------------------------------------------------------
// Configuration reset

const RESET_SQL = CONFIG_TABLES.map((table) => ({
  table,
  upsert: upsertSql(TABLES[table], { lww: false, serverTime: true }),
  softDelete: softDeleteMissingSql(TABLES[table]),
}));

/**
 * POST /v1/admin/config/reset {config}: `config` has the shape of
 * shared/default-config.json. Given rows are written with updated_at = now;
 * live rows of those tables that are absent from it are soft-deleted.
 */
export async function handleConfigReset({ request, env }: RequestContext): Promise<Response> {
  const body = await readJsonObject(request);
  const config = body.config;
  if (!isObject(config)) throw badRequest("config must be an object");
  const now = nowIso();
  const statements = RESET_SQL.flatMap(({ table, upsert, softDelete }) => {
    // Every section is required: an omitted one would soft-delete the whole table.
    if (!Array.isArray(config[table])) throw badRequest(`config.${table} must be an array`);
    const rows = validateRows(TABLES[table], config[table], `config.${table}`, MAX_CONFIG_ROWS, {
      serverTime: true,
    });
    const param = jsonParam(rows);
    const write = rows.length > 0 ? [env.DB.prepare(upsert).bind(param, now)] : [];
    return [...write, env.DB.prepare(softDelete).bind(param, now)];
  });
  const { rev } = await writeWithRev(env.DB, statements);
  return json({ rev });
}
