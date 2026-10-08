import { beforeEach, describe, expect, it } from "vitest";
import defaultConfig from "../../shared/default-config.json";
import { ADMIN, admin, change, createDevice, dbRows, expectError, expectJson, pull, pullAll, push, resetDb, track, ts } from "./helpers";

beforeEach(resetDb);

const ISO_MS = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

describe("POST /v1/admin/tracks", () => {
  it("inserts and replaces tracks with server updated_at and rev", async () => {
    const before = new Date().toISOString();
    const first = await expectJson(
      admin("POST", "/v1/admin/tracks", {
        tracks: [
          track("t1", {
            bpm: 128,
            duration_ms: 215000,
            source_tags: { genre: "Rap", comment: "FR EXTEND" },
            baseline: { genre: "RAP FR", grouping: null, comment: "FR EXTEND ()", rating: 4 },
            updated_at: "1999-01-01T00:00:00.000Z",
            rev: 999,
          }),
          track("t2"),
        ],
      }),
      200,
    );
    expect(first).toEqual({ upserted: 2, rev: 1 });

    const rows = await pullAll(ADMIN, "tracks");
    expect(rows).toHaveLength(2);
    const t1 = rows.find((row) => row.id === "t1");
    expect(t1).toMatchObject({
      file_path: "/Music/t1.mp3",
      bpm: 128,
      duration_ms: 215000,
      source_tags: { genre: "Rap", comment: "FR EXTEND" },
      baseline: { genre: "RAP FR", grouping: null, comment: "FR EXTEND ()", rating: 4 },
      apply_status: "aucun",
      rev: 1,
      deleted_at: null,
    });
    expect(t1.updated_at).toMatch(ISO_MS);
    expect(t1.updated_at >= before).toBe(true);

    const second = await expectJson(
      admin("POST", "/v1/admin/tracks", { tracks: [track("t1", { title: "Renamed", apply_status: "applique" })] }),
      200,
    );
    expect(second.rev).toBe(2);
    const replaced = (await pullAll(ADMIN, "tracks")).find((row) => row.id === "t1");
    expect(replaced).toMatchObject({ title: "Renamed", apply_status: "applique", bpm: null, source_tags: null, rev: 2 });
  });

  it("validates and limits the batch", async () => {
    await expectError(admin("POST", "/v1/admin/tracks", {}), 400);
    await expectError(admin("POST", "/v1/admin/tracks", { tracks: [{ id: "t1", file_format: "mp3" }] }), 400);
    await expectError(admin("POST", "/v1/admin/tracks", { tracks: [track("t1", { bpm: "fast" })] }), 400);
    await expectError(admin("POST", "/v1/admin/tracks", { tracks: [track("t1", { file_size: 1.5 })] }), 400);
    const tracks = Array.from({ length: 201 }, (_, i) => track(`t${i}`));
    await expectError(admin("POST", "/v1/admin/tracks", { tracks }), 413, "payload_too_large");
    expect((await expectJson(admin("POST", "/v1/admin/tracks", { tracks: tracks.slice(0, 200) }), 200)).upserted).toBe(200);
  });

  it("returns 413 when a batch exceeds D1's 2 MB parameter limit", async () => {
    const tracks = Array.from({ length: 200 }, (_, i) => track(`big${i}`, { waveform: "A".repeat(10_000) }));
    await expectError(admin("POST", "/v1/admin/tracks", { tracks }), 413, "payload_too_large");
    expect(await dbRows("SELECT id FROM tracks")).toHaveLength(0);
  });
});

describe("POST /v1/admin/tracks/patch", () => {
  it("updates only the given columns and moves rows past the pull cursor", async () => {
    await expectJson(admin("POST", "/v1/admin/tracks", { tracks: [track("t1", { bpm: 120 }), track("t2"), track("t3")] }), 200);
    const { token } = await createDevice();
    const synced = (await pull(token, { tracks: null })).tables.tracks!;
    expect(synced.rows).toHaveLength(3);
    const before = synced.rows.find((row) => row.id === "t1");

    const res = await expectJson(
      admin("POST", "/v1/admin/tracks/patch", {
        patches: [
          { id: "t1", apply_status: "applique", baseline: { genre: "POP" }, applied_at: ts(5) },
          { id: "t1", apply_message: null },
          { id: "t2", deleted_at: ts(6) },
          { id: "missing", title: "x" },
        ],
      }),
      200,
    );
    expect(res).toEqual({ updated: 2, rev: 2 });

    const page = (await pull(token, { tracks: synced.cursor })).tables.tracks!;
    expect(page.rows.map((row) => row.id).sort()).toEqual(["t1", "t2"]);
    const t1 = page.rows.find((row) => row.id === "t1");
    expect(t1).toMatchObject({
      apply_status: "applique",
      baseline: { genre: "POP" },
      applied_at: ts(5),
      apply_message: null,
      bpm: 120,
      title: "Title t1",
      file_path: "/Music/t1.mp3",
      rev: 2,
    });
    expect(t1.updated_at > before.updated_at || t1.updated_at === before.updated_at).toBe(true);
    expect(page.rows.find((row) => row.id === "t2").deleted_at).toBe(ts(6));
  });

  it("rejects unknown, server-managed and non-nullable columns", async () => {
    const patch = (patches: unknown) => admin("POST", "/v1/admin/tracks/patch", { patches });
    await expectError(patch([{ title: "no id" }]), 400);
    await expectError(patch([{ id: "t1", nope: 1 }]), 400);
    await expectError(patch([{ id: "t1", rev: 5 }]), 400);
    await expectError(patch([{ id: "t1", updated_at: ts(1) }]), 400);
    await expectError(patch([{ id: "t1", file_path: null }]), 400);
    await expectError(patch([{ id: "t1", apply_status: null }]), 400);
    await expectError(patch([{ id: "t1", bpm: "x" }]), 400);
    await expectError(patch(Array.from({ length: 501 }, (_, i) => ({ id: `t${i}`, title: "x" }))), 413);
  });
});

describe("POST /v1/admin/changes/mark", () => {
  async function seed() {
    await push(ADMIN, {
      changes: [
        change("a1", "t1", "f1", ts(1), { option_ids: ["x"] }),
        change("a2", "t1", "f2", ts(1), { option_ids: ["y"] }),
        change("b1", "t2", "f1", ts(1), { option_ids: ["z"] }),
        change("old", "t1", "f3", ts(1), { option_ids: ["p"] }),
        change("new", "t1", "f3", ts(2), { option_ids: ["q"] }),
      ],
    });
  }
  const statuses = async () =>
    Object.fromEntries(
      (await dbRows<{ id: string; status: string; apply_run_id: string | null }>("SELECT id, status, apply_run_id FROM changes")).map(
        (row) => [row.id, `${row.status}:${row.apply_run_id ?? "-"}`],
      ),
    );

  it("marks the 'sent' changes of the given tracks", async () => {
    await seed();
    const res = await expectJson(
      admin("POST", "/v1/admin/changes/mark", { track_ids: ["t1"], status: "applied", apply_run_id: "run-1" }),
      200,
    );
    expect(res).toEqual({ updated: 3, rev: 2 });
    expect(await statuses()).toEqual({
      a1: "applied:run-1",
      a2: "applied:run-1",
      new: "applied:run-1",
      old: "superseded:-",
      b1: "sent:-",
    });
    const changes = await pullAll(ADMIN, "changes");
    const a1 = changes.find((row) => row.id === "a1");
    expect(a1).toMatchObject({ status: "applied", apply_run_id: "run-1", rev: 2 });
    expect(a1.updated_at).toMatch(ISO_MS);
  });

  it("rolls back with from_status", async () => {
    await seed();
    await expectJson(admin("POST", "/v1/admin/changes/mark", { track_ids: ["t1", "t2"], status: "applied", apply_run_id: "run-1" }), 200);
    const res = await expectJson(
      admin("POST", "/v1/admin/changes/mark", { track_ids: ["t1"], from_status: "applied", status: "sent", apply_run_id: null }),
      200,
    );
    expect(res).toEqual({ updated: 3, rev: 3 });
    expect(await statuses()).toEqual({
      a1: "sent:-",
      a2: "sent:-",
      new: "sent:-",
      old: "superseded:-",
      b1: "applied:run-1",
    });
    // Without apply_run_id the stored value is kept.
    await expectJson(admin("POST", "/v1/admin/changes/mark", { track_ids: ["t2"], from_status: "applied", status: "sent" }), 200);
    expect((await statuses()).b1).toBe("sent:run-1");
  });

  it("leaves changes pushed after up_to_rev untouched", async () => {
    await seed();
    await push(ADMIN, { changes: [change("late", "t2", "f9", ts(3), { option_ids: [] })] });
    const res = await expectJson(
      admin("POST", "/v1/admin/changes/mark", { track_ids: ["t2"], status: "applied", up_to_rev: 1 }),
      200,
    );
    expect(res.updated).toBe(1);
    const all = await statuses();
    expect(all.b1).toBe("applied:-");
    expect(all.late).toBe("sent:-");
  });

  it("validates the body", async () => {
    const mark = (body: unknown) => admin("POST", "/v1/admin/changes/mark", body);
    await expectError(mark({ status: "applied" }), 400);
    await expectError(mark({ track_ids: ["t1"], status: "done" }), 400);
    await expectError(mark({ track_ids: ["t1"], status: "applied", from_status: "nope" }), 400);
    await expectError(mark({ track_ids: ["t1"], status: "sent" }), 400);
    await expectError(mark({ track_ids: [1], status: "applied" }), 400);
    await expectError(mark({ track_ids: ["t1"], status: "applied", apply_run_id: 5 }), 400);
    await expectError(mark({ track_ids: ["t1"], status: "applied", up_to_rev: -1 }), 400);
    await expectError(mark({ track_ids: Array(1001).fill("t"), status: "applied" }), 413);
  });
});

describe("POST /v1/admin/apply-runs", () => {
  it("inserts then replaces a run", async () => {
    const run = { id: "run-1", started_at: ts(1), mode: "dry_run", tracks_written: 0, backup_path: null };
    expect(await expectJson(admin("POST", "/v1/admin/apply-runs", { run }), 200)).toEqual({ id: "run-1", rev: 1 });
    await expectJson(
      admin("POST", "/v1/admin/apply-runs", {
        run: { ...run, mode: "apply", finished_at: ts(9), tracks_written: 12, conflicts: 1, errors: 2, report_path: "/r.json" },
      }),
      200,
    );
    const rows = await pullAll(ADMIN, "apply_runs");
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      id: "run-1",
      mode: "apply",
      finished_at: ts(9),
      tracks_written: 12,
      conflicts: 1,
      errors: 2,
      report_path: "/r.json",
      rev: 2,
    });
  });

  it("validates the run", async () => {
    await expectError(admin("POST", "/v1/admin/apply-runs", {}), 400);
    await expectError(admin("POST", "/v1/admin/apply-runs", { run: { id: "r", started_at: ts(1) } }), 400);
  });
});

describe("POST /v1/admin/config/reset", () => {
  const counts = {
    fields: defaultConfig.fields.length,
    field_options: defaultConfig.field_options.length,
    rules: defaultConfig.rules.length,
    saved_views: defaultConfig.saved_views.length,
    settings: defaultConfig.settings.length,
  };

  it("loads shared/default-config.json and soft-deletes rows it does not contain", async () => {
    await push(ADMIN, {
      fields: [{ id: "extra", key: "x", name: "X", kind: "text", target_tag: "COMMENT", updated_at: ts(1) }],
      settings: [{ key: "extra.setting", value: 1, updated_at: ts(1) }],
    });
    const start = new Date().toISOString();
    const { rev } = await expectJson(admin("POST", "/v1/admin/config/reset", { config: defaultConfig }), 200);
    expect(rev).toBe(2);

    const tables = (await pull(ADMIN, { fields: null, field_options: null, rules: null, saved_views: null, settings: null })).tables;
    for (const [table, count] of Object.entries(counts)) {
      const live = tables[table]!.rows.filter((row) => row.deleted_at === null);
      expect(live, table).toHaveLength(count);
      expect(live.every((row) => row.rev === rev && row.updated_at >= start)).toBe(true);
    }
    const extraField = tables.fields!.rows.find((row) => row.id === "extra");
    expect(extraField).toMatchObject({ rev, deleted_at: expect.stringMatching(ISO_MS) });
    expect(tables.settings!.rows.find((row) => row.key === "extra.setting").deleted_at).not.toBeNull();

    const genre = tables.fields!.rows.find((row) => row.key === "genre");
    const { updated_at: _u, ...expected } = defaultConfig.fields[0]!;
    expect(genre).toMatchObject(expected);
    const formats = tables.settings!.rows.find((row) => row.key === "rating.write_formats");
    expect(formats.value).toEqual(["mp3", "wav", "aiff"]);
    const rule = tables.rules!.rows[0];
    expect(rule.condition).toEqual(defaultConfig.rules.find((r) => r.id === rule.id)!.condition);
  });

  it("restores soft-deleted rows and keeps already deleted ones untouched", async () => {
    await expectJson(admin("POST", "/v1/admin/config/reset", { config: defaultConfig }), 200);
    const option = defaultConfig.field_options[0]!;
    await push(ADMIN, { field_options: [{ ...option, deleted_at: "2099-01-01T00:00:00.000Z", updated_at: "2099-01-01T00:00:00.000Z" }] });
    const smaller = { ...defaultConfig, rules: defaultConfig.rules.slice(1) };
    const { rev } = await expectJson(admin("POST", "/v1/admin/config/reset", { config: smaller }), 200);
    const options = await pullAll(ADMIN, "field_options");
    expect(options.find((row) => row.id === option.id).deleted_at).toBeNull();
    const rules = await pullAll(ADMIN, "rules");
    expect(rules.filter((row) => row.deleted_at !== null).map((row) => row.id)).toEqual([defaultConfig.rules[0]!.id]);

    // A third reset does not re-delete (nor bump) the already deleted rule.
    await expectJson(admin("POST", "/v1/admin/config/reset", { config: smaller }), 200);
    const deleted = (await pullAll(ADMIN, "rules")).find((row) => row.id === defaultConfig.rules[0]!.id);
    expect(deleted.rev).toBe(rev);
  });

  it("requires every section", async () => {
    await expectError(admin("POST", "/v1/admin/config/reset", {}), 400);
    const { rules: _r, ...withoutRules } = defaultConfig;
    await expectError(admin("POST", "/v1/admin/config/reset", { config: withoutRules }), 400);
    expect(await dbRows("SELECT id FROM fields")).toHaveLength(0);
  });
});
