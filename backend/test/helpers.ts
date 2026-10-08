import { env, exports } from "cloudflare:workers";
import { expect } from "vitest";

export const ADMIN = env.ADMIN_TOKEN;

type Body = unknown;

export interface CallOptions {
  token?: string | undefined;
  body?: Body;
  headers?: Record<string, string>;
}

/** Calls the Worker through its real fetch handler. */
export function call(method: string, path: string, options: CallOptions = {}): Promise<Response> {
  const headers = new Headers(options.headers);
  if (options.token !== undefined) headers.set("authorization", `Bearer ${options.token}`);
  let body: BodyInit | undefined;
  if (options.body instanceof Uint8Array || options.body instanceof ReadableStream || typeof options.body === "string") {
    body = options.body;
  } else if (options.body !== undefined) {
    body = JSON.stringify(options.body);
    headers.set("content-type", "application/json");
  }
  return exports.default.fetch(new Request(`https://api.test${path}`, { method, headers, body }));
}

export function admin(method: string, path: string, body?: Body): Promise<Response> {
  return call(method, path, { token: ADMIN, body });
}

/** Asserts the status and returns the parsed JSON body. */
export async function expectJson<T = any>(response: Response | Promise<Response>, status: number): Promise<T> {
  const res = await response;
  const text = await res.text();
  expect(res.status, text).toBe(status);
  return JSON.parse(text) as T;
}

export async function expectError(response: Response | Promise<Response>, status: number, code?: string) {
  const body = await expectJson<{ error: string; message: string }>(response, status);
  expect(typeof body.message).toBe("string");
  if (code !== undefined) expect(body.error).toBe(code);
  return body;
}

const SYNCED = ["tracks", "fields", "field_options", "track_values", "changes", "apply_runs", "rules", "saved_views", "settings"];

export async function resetDb(): Promise<void> {
  await env.DB.batch([
    ...[...SYNCED, "devices"].map((table) => env.DB.prepare(`DELETE FROM ${table}`)),
    env.DB.prepare("UPDATE counters SET value = 0 WHERE name = 'rev'"),
  ]);
}

export async function resetBucket(): Promise<void> {
  const listed = await env.BUCKET.list();
  if (listed.objects.length > 0) await env.BUCKET.delete(listed.objects.map((object) => object.key));
}

export async function createDevice(name = "iPhone"): Promise<{ device_id: string; token: string }> {
  return expectJson(admin("POST", "/v1/admin/devices", { name }), 201);
}

/** Deterministic timestamps: ts(0) = 2026-10-08T12:00:00.000Z, one second per step. */
export function ts(seconds: number): string {
  return new Date(Date.UTC(2026, 9, 8, 12, 0, 0) + seconds * 1000).toISOString();
}

export function track(id: string, extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id,
    file_path: `/Music/${id}.mp3`,
    file_format: "mp3",
    title: `Title ${id}`,
    artist: "Artist",
    ...extra,
  };
}

export interface Cursor {
  rev: number;
  rowid: number;
}

export interface Page<Row = any> {
  rows: Row[];
  cursor: Cursor;
  has_more: boolean;
}

export interface PullResponse {
  tables: Record<string, Page>;
  server_rev: number;
}

export async function pull(
  token: string,
  cursors: Record<string, Cursor | null>,
  limit?: number,
): Promise<PullResponse> {
  return expectJson<PullResponse>(call("POST", "/v1/sync/pull", { token, body: { cursors, limit } }), 200);
}

/** Pulls one table until has_more is false; returns every page. */
export async function pullPages(token: string, table: string, limit?: number, from: Cursor = { rev: 0, rowid: 0 }) {
  const pages: Page[] = [];
  let cursor = from;
  for (;;) {
    const page = (await pull(token, { [table]: cursor }, limit)).tables[table]!;
    pages.push(page);
    cursor = page.cursor;
    if (!page.has_more) return pages;
  }
}

export async function pullAll(token: string, table: string): Promise<any[]> {
  return (await pullPages(token, table, 1000)).flatMap((page) => page.rows);
}

export function change(
  id: string,
  trackId: string,
  fieldId: string,
  createdAt: string,
  newValue: Record<string, unknown> | null,
  extra: Record<string, unknown> = {},
) {
  return {
    id,
    track_id: trackId,
    field_id: fieldId,
    old_value: null,
    new_value: newValue,
    source: "user",
    created_at: createdAt,
    ...extra,
  };
}

export async function push(token: string, body: Record<string, unknown>) {
  return expectJson<{ accepted_changes: string[]; rev: number }>(call("POST", "/v1/sync/push", { token, body }), 200);
}

export async function dbRows<T = Record<string, unknown>>(sql: string, ...params: unknown[]): Promise<T[]> {
  return (await env.DB.prepare(sql).bind(...params).all<T>()).results;
}
