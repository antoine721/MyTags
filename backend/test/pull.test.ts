import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { jsonParam, upsertSql, writeWithRev } from "../src/db";
import { TABLES } from "../src/tables";
import { ADMIN, admin, call, createDevice, expectError, expectJson, pull, pullPages, resetDb, track } from "./helpers";

beforeEach(resetDb);

/** Inserts `count` tracks in a single batch, so they all share one rev. */
async function insertTracksInOneRev(count: number, prefix = "t"): Promise<number> {
  const rows = Array.from({ length: count }, (_, i) => track(`${prefix}${String(i).padStart(5, "0")}`));
  const statement = env.DB.prepare(upsertSql(TABLES.tracks, { lww: false, serverTime: true })).bind(
    jsonParam(rows),
    new Date().toISOString(),
  );
  return (await writeWithRev(env.DB, [statement])).rev;
}

describe("POST /v1/sync/pull", () => {
  it("pages through 1200 rows sharing one rev", async () => {
    const { token } = await createDevice();
    const rev = await insertTracksInOneRev(1200);

    const pages = await pullPages(token, "tracks", 500);
    expect(pages.map((page) => page.rows.length)).toEqual([500, 500, 200]);
    expect(pages.map((page) => page.has_more)).toEqual([true, true, false]);

    const rows = pages.flatMap((page) => page.rows);
    expect(new Set(rows.map((row) => row.id)).size).toBe(1200);
    expect(rows.every((row) => row.rev === rev)).toBe(true);

    // Cursors stay on the shared rev and advance through the rowids.
    expect(pages.every((page) => page.cursor.rev === rev)).toBe(true);
    const rowids = pages.map((page) => page.cursor.rowid);
    expect([...rowids].sort((a, b) => a - b)).toEqual(rowids);
    expect(new Set(rowids).size).toBe(3);

    // Nothing after the final cursor: same cursor back, no more pages.
    const last = pages.at(-1)!.cursor;
    const after = await pull(token, { tracks: last }, 500);
    expect(after.tables.tracks).toEqual({ rows: [], cursor: last, has_more: false });
    expect(after.server_rev).toBe(rev);
  });

  it("continues with rows of later revs after a page boundary inside a rev", async () => {
    const { token } = await createDevice();
    const firstRev = await insertTracksInOneRev(30, "a");
    const secondRev = await insertTracksInOneRev(30, "b");
    const pages = await pullPages(token, "tracks", 25);
    expect(pages.map((page) => page.rows.length)).toEqual([25, 25, 10]);
    const rows = pages.flatMap((page) => page.rows);
    expect(rows.map((row) => row.rev)).toEqual([...Array(30).fill(firstRev), ...Array(30).fill(secondRev)]);
    expect(new Set(rows.map((row) => row.id)).size).toBe(60);
  });

  it("applies the default limit of 500 and caps it at 1000", async () => {
    await insertTracksInOneRev(1100);
    const start = { tracks: { rev: 0, rowid: 0 } };
    expect((await pull(ADMIN, start)).tables.tracks!.rows).toHaveLength(500);
    const capped = (await pull(ADMIN, start, 5000)).tables.tracks!;
    expect(capped.rows).toHaveLength(1000);
    expect(capped.has_more).toBe(true);
  });

  it("returns only the requested tables, with server_rev", async () => {
    const rev = await insertTracksInOneRev(2);
    const res = await pull(ADMIN, { fields: { rev: 0, rowid: 0 }, settings: null });
    expect(Object.keys(res.tables).sort()).toEqual(["fields", "settings"]);
    expect(res.tables.fields).toEqual({ rows: [], cursor: { rev: 0, rowid: 0 }, has_more: false });
    expect(res.tables.settings!.cursor).toEqual({ rev: 0, rowid: 0 });
    expect(res.server_rev).toBe(rev);
  });

  it("includes soft-deleted rows", async () => {
    await expectJson(admin("POST", "/v1/admin/tracks", { tracks: [track("gone", { deleted_at: "2026-10-08T00:00:00.000Z" })] }), 200);
    const rows = (await pull(ADMIN, { tracks: null })).tables.tracks!.rows;
    expect(rows).toHaveLength(1);
    expect(rows[0].deleted_at).toBe("2026-10-08T00:00:00.000Z");
  });

  it("validates the request", async () => {
    const bad = (body: unknown) => call("POST", "/v1/sync/pull", { token: ADMIN, body });
    await expectError(bad({}), 400, "bad_request");
    await expectError(bad({ cursors: [] }), 400);
    await expectError(bad({ cursors: { nope: null } }), 400);
    await expectError(bad({ cursors: { tracks: { rev: -1, rowid: 0 } } }), 400);
    await expectError(bad({ cursors: { tracks: { rev: "1", rowid: 0 } } }), 400);
    await expectError(bad({ cursors: { tracks: 5 } }), 400);
    await expectError(bad({ cursors: {}, limit: 0 }), 400);
    await expectError(bad({ cursors: {}, limit: 2.5 }), 400);
  });
});
