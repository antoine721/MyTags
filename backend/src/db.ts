// Revision handling and the bulk SQL statements shared by sync and admin routes.
//
// Every write request runs as one D1 batch (one transaction):
//   1. UPDATE counters (rev + 1)
//   2. one statement per table, each reading all its rows from json_each(?1)
//   3. SELECT the new rev
// All rows written by the request therefore share the same `rev`.

import { tooLarge } from "./http";
import { apiToColumn, ident, rowObject } from "./json";
import type { TableSpec } from "./tables";

const BUMP_REV = "UPDATE counters SET value = value + 1 WHERE name = 'rev'";
const READ_REV = "SELECT value FROM counters WHERE name = 'rev'";
/** The revision of the running write batch (after BUMP_REV). */
export const CURRENT_REV = `(${READ_REV})`;

/** D1 caps a bound string at 2 MB; keep a margin. */
const MAX_PARAM_BYTES = 1_900_000;

export interface WriteResult {
  rev: number;
  /** Results of `statements`, in order. */
  results: D1Result[];
}

/** Runs `statements` in a single batch wrapped by the rev bump. */
export async function writeWithRev(
  db: D1Database,
  statements: D1PreparedStatement[],
): Promise<WriteResult> {
  const results = await db.batch([db.prepare(BUMP_REV), ...statements, db.prepare(READ_REV)]);
  return { rev: revOf(results.at(-1)), results: results.slice(1, -1) };
}

export async function readRev(db: D1Database): Promise<number> {
  return revOf(await db.prepare(READ_REV).all());
}

export function readRevStatement(db: D1Database): D1PreparedStatement {
  return db.prepare(READ_REV);
}

export function revOf(result: D1Result | undefined): number {
  const row = result?.results[0] as { value: number } | undefined;
  if (row === undefined) throw new Error("counters row 'rev' is missing");
  return row.value;
}

/** Serializes rows for a json_each(?) parameter, enforcing D1's parameter size limit. */
export function jsonParam(rows: readonly unknown[]): string {
  const text = JSON.stringify(rows);
  // A UTF-16 code unit is at most 3 UTF-8 bytes: only measure exactly when it may matter.
  if (text.length * 3 > MAX_PARAM_BYTES && new TextEncoder().encode(text).length > MAX_PARAM_BYTES) {
    throw tooLarge("Batch is too large for one request; send fewer rows per request");
  }
  return text;
}

export interface UpsertOptions {
  /**
   * Only replace an existing row's values when the incoming updated_at is >=
   * the stored one. The rev is bumped either way, so that a device whose older
   * write lost receives the stored row on its next pull.
   */
  lww: boolean;
  /** updated_at comes from parameter ?2 (server time) instead of the rows. */
  serverTime: boolean;
}

/**
 * INSERT ... SELECT FROM json_each(?1) ... ON CONFLICT DO UPDATE: full-row
 * upsert of every row of the JSON array bound to ?1.
 */
export function upsertSql(spec: TableSpec, options: UpsertOptions): string {
  const names = Object.keys(spec.columns);
  const values = Object.entries(spec.columns).map(([name, column]) =>
    options.serverTime && name === "updated_at" ? "?2" : apiToColumn(name, column, "j.value"),
  );
  const table = ident(spec.name);
  // Every right-hand side reads the stored row as it was before this update,
  // so assigning updated_at does not affect the other CASE conditions.
  const incomingWins = `excluded."updated_at" >= ${table}."updated_at"`;
  const assignments = names
    .filter((name) => name !== spec.key)
    .map((name) =>
      options.lww
        ? `${ident(name)} = CASE WHEN ${incomingWins} THEN excluded.${ident(name)} ELSE ${table}.${ident(name)} END`
        : `${ident(name)} = excluded.${ident(name)}`,
    );
  return [
    `INSERT INTO ${table} (${[...names, "rev"].map(ident).join(", ")})`,
    `SELECT ${[...values, CURRENT_REV].join(", ")}`,
    // `WHERE true` resolves the parser ambiguity between a join's ON and ON CONFLICT.
    `FROM json_each(?1) AS j WHERE true`,
    `ON CONFLICT (${ident(spec.key)}) DO UPDATE SET ${assignments.join(", ")}, "rev" = excluded."rev"`,
  ].join("\n");
}

/** Soft-deletes (deleted_at = ?2) live rows whose key is absent from the JSON array ?1. */
export function softDeleteMissingSql(spec: TableSpec): string {
  const key = ident(spec.key);
  return [
    `UPDATE ${ident(spec.name)} SET "deleted_at" = ?2, "updated_at" = ?2, "rev" = ${CURRENT_REV}`,
    `WHERE "deleted_at" IS NULL`,
    `AND ${key} NOT IN (SELECT j.value ->> '$.${spec.key}' FROM json_each(?1) AS j)`,
  ].join("\n");
}

/**
 * Partial update from the JSON array ?1 of patches ({key, ...columns}): a
 * column changes only when its key is present in the patch. updated_at = ?2.
 */
export function patchSql(spec: TableSpec, patchable: readonly string[]): string {
  const table = ident(spec.name);
  const assignments = patchable.map((name) => {
    const column = spec.columns[name];
    if (column === undefined) throw new Error(`unknown column ${spec.name}.${name}`);
    const present = `p.value -> '$.${name}' IS NOT NULL`;
    return `${ident(name)} = CASE WHEN ${present} THEN ${apiToColumn(name, column, "p.value")} ELSE ${table}.${ident(name)} END`;
  });
  return [
    `UPDATE ${table} SET ${assignments.join(",\n  ")},`,
    `  "updated_at" = ?2, "rev" = ${CURRENT_REV}`,
    `FROM json_each(?1) AS p`,
    `WHERE ${table}.${ident(spec.key)} = p.value ->> '$.${spec.key}'`,
  ].join("\n");
}

/**
 * One pull page: rows strictly after the (rev, rowid) cursor (?1, ?2), in
 * cursor order, at most ?3 rows, each already serialized as JSON text.
 * SQLite walks the `<table>_rev` index (its entries end with the rowid), so
 * there is no sort and the scan stops at the LIMIT.
 */
export function pageSql(spec: TableSpec): string {
  return [
    `SELECT "rev" AS rev, rowid AS rid, ${rowObject(spec)} AS obj FROM ${ident(spec.name)}`,
    `WHERE "rev" > ?1 OR ("rev" = ?1 AND rowid > ?2)`,
    `ORDER BY "rev", rowid LIMIT ?3`,
  ].join("\n");
}
