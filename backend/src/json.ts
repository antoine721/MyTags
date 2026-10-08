// API <-> D1 value conversions, expressed as SQL so that bulk reads and
// writes never convert rows one by one in JavaScript (Workers free plan: 10 ms CPU).
//
// Writes read each API row from a `json_each(?)` alias; reads build each row
// with json_object(). Booleans are 0/1 in D1, JSON columns are TEXT in D1.

import type { Column, TableSpec } from "./tables";

/** Quotes an SQL identifier. Names come from the static table specs only. */
export function ident(name: string): string {
  return `"${name}"`;
}

/**
 * SQL expression giving the D1 value of API key `name` in the JSON object
 * `source` (typically `j.value` from json_each).
 *
 * `->>` yields SQL scalars (true/false become 1/0, JSON null becomes NULL).
 * `->` yields JSON text (strings stay quoted), and JSON null comes back as the
 * text 'null', which is stored as SQL NULL.
 */
export function apiToColumn(name: string, column: Column, source: string): string {
  const path = `'$.${name}'`;
  const value =
    column.type === "json" ? `nullif(${source} -> ${path}, 'null')` : `${source} ->> ${path}`;
  return column.default === undefined ? value : `coalesce(${value}, ${column.default})`;
}

/** SQL expression giving the API (JSON) value of a stored column, for json_object(). */
function columnToApi(name: string, column: Column): string {
  switch (column.type) {
    case "bool":
      return `json(CASE WHEN ${ident(name)} THEN 'true' ELSE 'false' END)`;
    case "json":
      return `json(${ident(name)})`;
    default:
      return ident(name);
  }
}

/** json_object(...) expression serializing a whole row of `spec`, `rev` included. */
export function rowObject(spec: TableSpec): string {
  const pairs = Object.entries(spec.columns).map(
    ([name, column]) => `'${name}', ${columnToApi(name, column)}`,
  );
  pairs.push(`'rev', "rev"`);
  return `json_object(${pairs.join(", ")})`;
}
