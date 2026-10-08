// Request validation. Rows are checked against the table specs and then
// passed to SQL unchanged (unknown keys are ignored by the SQL).

import { badRequest, isObject, tooLarge, type JsonObject } from "./http";
import type { Column, TableSpec } from "./tables";

const ISO_MS = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

export function isTimestamp(value: unknown): value is string {
  return typeof value === "string" && ISO_MS.test(value);
}

function matchesType(value: unknown, column: Column): boolean {
  switch (column.type) {
    case "text":
      return typeof value === "string";
    case "time":
      return isTimestamp(value);
    case "int":
      return Number.isSafeInteger(value);
    case "real":
      return typeof value === "number" && Number.isFinite(value);
    case "bool":
      return typeof value === "boolean";
    case "json":
      return true;
  }
}

const TYPE_NAMES = {
  text: "a string",
  time: "an ISO 8601 UTC timestamp with milliseconds (2026-10-08T12:00:00.000Z)",
  int: "an integer",
  real: "a number",
  bool: "a boolean",
  json: "a JSON value",
} as const;

/** Checks one column value; `undefined` means the key is absent. */
export function checkValue(value: unknown, column: Column, where: string, required: boolean): void {
  if (value === undefined || value === null) {
    if (required) throw badRequest(`${where} is required`);
    return;
  }
  if (!matchesType(value, column)) throw badRequest(`${where} must be ${TYPE_NAMES[column.type]}`);
}

/** Returns `value` as an array of at most `max` items (absent means empty), or throws 400/413. */
export function arrayOf(value: unknown, label: string, max: number): unknown[] {
  if (value === undefined) return [];
  if (!Array.isArray(value)) throw badRequest(`${label} must be an array`);
  if (value.length > max) throw tooLarge(`${label}: at most ${max} items per request`);
  return value;
}

export interface RowOptions {
  /** updated_at is assigned by the server, so rows need not carry it. */
  serverTime?: boolean;
}

/** Validates full rows of `spec` for an upsert. */
export function validateRows(
  spec: TableSpec,
  value: unknown,
  label: string,
  max: number,
  options: RowOptions = {},
): JsonObject[] {
  return arrayOf(value, label, max).map((row, index) => validateRow(spec, row, `${label}[${index}]`, options));
}

export function validateRow(spec: TableSpec, row: unknown, where: string, options: RowOptions = {}): JsonObject {
  if (!isObject(row)) throw badRequest(`${where} must be an object`);
  for (const [name, column] of Object.entries(spec.columns)) {
    const required = column.required === true && !(options.serverTime && name === "updated_at");
    checkValue(row[name], column, `${where}.${name}`, required);
  }
  return row;
}

export function requireString(value: unknown, where: string): string {
  if (typeof value !== "string" || value.length === 0) throw badRequest(`${where} must be a non-empty string`);
  return value;
}

export function requireStringArray(value: unknown, where: string, max: number): string[] {
  if (value === undefined) throw badRequest(`${where} is required`);
  const items = arrayOf(value, where, max);
  for (const item of items) {
    if (typeof item !== "string") throw badRequest(`${where} must contain only strings`);
  }
  return items as string[];
}

