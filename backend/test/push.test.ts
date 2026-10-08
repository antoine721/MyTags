import { beforeEach, describe, expect, it } from "vitest";
import {
  ADMIN,
  call,
  change,
  createDevice,
  dbRows,
  expectError,
  pull,
  pullAll,
  push,
  resetDb,
  ts,
} from "./helpers";

beforeEach(resetDb);

const FIELD = "field-genre";

async function trackValues(token = ADMIN) {
  return pullAll(token, "track_values");
}

async function changeRows() {
  return dbRows<{ id: string; status: string; device_id: string; rev: number }>(
    "SELECT id, status, device_id, rev FROM changes ORDER BY created_at, id",
  );
}

describe("POST /v1/sync/push: changes", () => {
  it("stores a change and updates track_values", async () => {
    const { token, device_id } = await createDevice();
    const res = await push(token, {
      device_id: "ignored",
      changes: [change("c1", "t1", FIELD, ts(1), { option_ids: ["o1", "o2"], rating: null, text: null })],
    });
    expect(res.accepted_changes).toEqual(["c1"]);
    expect(res.rev).toBe(1);

    const values = await trackValues(token);
    expect(values).toEqual([
      {
        track_id: "t1",
        field_id: FIELD,
        option_ids: ["o1", "o2"],
        rating: null,
        text_value: null,
        state: "confirmed",
        source: "user",
        updated_at: ts(1),
        device_id,
        deleted_at: null,
        rev: 1,
      },
    ]);
    const [stored] = await pullAll(ADMIN, "changes");
    expect(stored).toMatchObject({
      id: "c1",
      status: "sent",
      device_id,
      old_value: null,
      new_value: { option_ids: ["o1", "o2"], rating: null, text: null },
      created_at: ts(1),
      rev: 1,
    });
  });

  it("stores rating and text values", async () => {
    await push(ADMIN, {
      changes: [
        change("c1", "t1", "field-note", ts(1), { rating: 4 }, { source: "rule" }),
        change("c2", "t1", "field-text", ts(1), { text: "Très bien" }),
      ],
    });
    const values = await trackValues();
    expect(values.find((v) => v.field_id === "field-note")).toMatchObject({ rating: 4, option_ids: [], source: "rule" });
    expect(values.find((v) => v.field_id === "field-text")).toMatchObject({ text_value: "Très bien", rating: null });
  });

  it("records device_id 'mac' for the admin token", async () => {
    await push(ADMIN, { changes: [change("c1", "t1", FIELD, ts(1), { option_ids: ["o1"] })] });
    expect((await changeRows())[0]!.device_id).toBe("mac");
    expect((await trackValues())[0].device_id).toBe("mac");
  });

  it("is idempotent: a change sent twice is stored once and rewrites nothing", async () => {
    const { token } = await createDevice();
    const body = { changes: [change("c1", "t1", FIELD, ts(1), { option_ids: ["o1"] })] };
    const first = await push(token, body);
    const second = await push(token, body);
    expect(second.accepted_changes).toEqual(["c1"]);
    expect(second.rev).toBeGreaterThan(first.rev);
    const rows = await changeRows();
    expect(rows).toHaveLength(1);
    expect(rows[0]!.rev).toBe(first.rev);
    const values = await trackValues();
    expect(values).toHaveLength(1);
    expect(values[0].rev).toBe(first.rev);
  });

  it("accepts a retried batch mixing known and new changes", async () => {
    await push(ADMIN, { changes: [change("c1", "t1", FIELD, ts(1), { option_ids: ["o1"] })] });
    const res = await push(ADMIN, {
      changes: [
        change("c1", "t1", FIELD, ts(1), { option_ids: ["o1"] }),
        change("c2", "t2", FIELD, ts(2), { option_ids: ["o2"] }),
        change("c2", "t2", FIELD, ts(2), { option_ids: ["o2"] }),
      ],
    });
    expect(res.accepted_changes).toEqual(["c1", "c2"]);
    expect(await changeRows()).toHaveLength(2);
  });

  it("keeps the newest value when an older change arrives later (LWW)", async () => {
    await push(ADMIN, { changes: [change("new", "t1", FIELD, ts(10), { option_ids: ["newer"] })] });
    await push(ADMIN, { changes: [change("old", "t1", FIELD, ts(5), { option_ids: ["older"] })] });
    const values = await trackValues();
    expect(values).toHaveLength(1);
    expect(values[0]).toMatchObject({ option_ids: ["newer"], updated_at: ts(10) });
    const statuses = Object.fromEntries((await changeRows()).map((row) => [row.id, row.status]));
    expect(statuses).toEqual({ old: "superseded", new: "sent" });
  });

  it("applies LWW inside one request regardless of order", async () => {
    await push(ADMIN, {
      changes: [
        change("b", "t1", FIELD, ts(2), { option_ids: ["two"] }),
        change("a", "t1", FIELD, ts(1), { option_ids: ["one"] }),
        change("c", "t2", FIELD, ts(1), { option_ids: ["x"] }),
        change("d", "t2", FIELD, ts(3), { option_ids: ["y"] }),
      ],
    });
    const byTrack = Object.fromEntries((await trackValues()).map((v) => [v.track_id, v.option_ids]));
    expect(byTrack).toEqual({ t1: ["two"], t2: ["y"] });
    const statuses = Object.fromEntries((await changeRows()).map((row) => [row.id, row.status]));
    expect(statuses).toEqual({ a: "superseded", b: "sent", c: "superseded", d: "sent" });
  });

  it("sends the winning value back to a device whose older change lost", async () => {
    const { token: phone } = await createDevice();
    await push(ADMIN, {
      changes: [
        change("init", "t1", "field-note", ts(0), { rating: 3 }),
        change("other", "t2", "field-note", ts(0), { rating: 1 }),
      ],
    });
    // The phone is up to date, then edits t1 at ts(10) while offline (pending).
    const upToDate = (await pull(phone, { track_values: null })).tables.track_values!;
    expect(upToDate.rows).toHaveLength(2);

    // The Mac writes a newer rating; the phone pulls it but skips the key (pending edit).
    await push(ADMIN, { changes: [change("mac", "t1", "field-note", ts(15), { rating: 2 })] });
    const skipped = (await pull(phone, { track_values: upToDate.cursor })).tables.track_values!;
    expect(skipped.rows).toEqual([expect.objectContaining({ track_id: "t1", rating: 2 })]);
    const winner = skipped.rows[0];

    // The phone pushes its older edit: accepted, but it loses.
    const res = await push(phone, { changes: [change("phone", "t1", "field-note", ts(10), { rating: 4 })] });
    expect(res.accepted_changes).toEqual(["phone"]);

    // Its next pull from the cursor it already holds returns the winning row, values unchanged.
    const next = (await pull(phone, { track_values: skipped.cursor })).tables.track_values!;
    expect(next.rows).toEqual([{ ...winner, rev: res.rev }]);
    expect(next.rows[0]).toMatchObject({ rating: 2, updated_at: ts(15), device_id: "mac" });
    const statuses = Object.fromEntries((await changeRows()).map((row) => [row.id, row.status]));
    expect(statuses).toEqual({ init: "superseded", other: "sent", phone: "superseded", mac: "sent" });
  });

  it("lets the later change win on equal created_at", async () => {
    await push(ADMIN, { changes: [change("first", "t1", FIELD, ts(1), { option_ids: ["first"] })] });
    await push(ADMIN, { changes: [change("second", "t1", FIELD, ts(1), { option_ids: ["second"] })] });
    expect((await trackValues())[0].option_ids).toEqual(["second"]);
    const statuses = Object.fromEntries((await changeRows()).map((row) => [row.id, row.status]));
    expect(statuses).toEqual({ first: "superseded", second: "sent" });
  });

  it("soft-deletes the value when new_value is null", async () => {
    await push(ADMIN, { changes: [change("c1", "t1", FIELD, ts(1), { option_ids: ["o1"], rating: 3, text: "x" })] });
    const res = await push(ADMIN, { changes: [change("c2", "t1", FIELD, ts(2), null)] });
    const values = await trackValues();
    expect(values).toEqual([
      expect.objectContaining({
        option_ids: [],
        rating: null,
        text_value: null,
        updated_at: ts(2),
        deleted_at: ts(2),
        rev: res.rev,
      }),
    ]);
    const [, reset] = await pullAll(ADMIN, "changes").then((rows) => rows.sort((a, b) => a.created_at.localeCompare(b.created_at)));
    expect(reset.new_value).toBeNull();

    // A later value revives the row.
    await push(ADMIN, { changes: [change("c3", "t1", FIELD, ts(3), { option_ids: ["o2"] })] });
    expect((await trackValues())[0]).toMatchObject({ option_ids: ["o2"], deleted_at: null });
  });

  it("supersedes only older 'sent' changes of the same pair", async () => {
    await push(ADMIN, {
      changes: [
        change("old-applied", "t1", FIELD, ts(1), { option_ids: ["a"] }),
        change("other-field", "t1", "field-other", ts(1), { option_ids: ["b"] }),
        change("other-track", "t2", FIELD, ts(1), { option_ids: ["c"] }),
      ],
    });
    await call("POST", "/v1/admin/changes/mark", {
      token: ADMIN,
      body: { track_ids: ["t1"], status: "applied", apply_run_id: "run1" },
    });
    await push(ADMIN, { changes: [change("old-sent", "t1", FIELD, ts(2), { option_ids: ["d"] })] });
    await push(ADMIN, { changes: [change("newest", "t1", FIELD, ts(3), { option_ids: ["e"] })] });
    const statuses = Object.fromEntries((await changeRows()).map((row) => [row.id, row.status]));
    expect(statuses).toEqual({
      "old-applied": "applied",
      "other-field": "applied",
      "other-track": "sent",
      "old-sent": "superseded",
      newest: "sent",
    });
    // Superseding bumps the change's rev so the Mac sees it.
    const changes = await pullAll(ADMIN, "changes");
    const oldSent = changes.find((row) => row.id === "old-sent");
    const newest = changes.find((row) => row.id === "newest");
    expect(oldSent.rev).toBe(newest.rev);
  });

  it("returns the current rev for an empty push without writing", async () => {
    await push(ADMIN, { changes: [change("c1", "t1", FIELD, ts(1), { option_ids: [] })] });
    expect(await push(ADMIN, {})).toEqual({ accepted_changes: [], rev: 1 });
    expect(await push(ADMIN, { changes: [], fields: [] })).toEqual({ accepted_changes: [], rev: 1 });
  });

  it("rejects malformed changes", async () => {
    const bad = (changes: unknown) => call("POST", "/v1/sync/push", { token: ADMIN, body: { changes } });
    const valid = change("c1", "t1", FIELD, ts(1), { option_ids: ["o1"] });
    const without = (key: string) => Object.fromEntries(Object.entries(valid).filter(([k]) => k !== key));
    await expectError(bad("nope"), 400, "bad_request");
    await expectError(bad([42]), 400);
    for (const key of ["id", "track_id", "field_id", "created_at", "new_value"]) {
      await expectError(bad([without(key)]), 400);
    }
    await expectError(bad([{ ...valid, created_at: "2026-10-08T12:00:00Z" }]), 400);
    await expectError(bad([{ ...valid, new_value: "o1" }]), 400);
    await expectError(bad([{ ...valid, new_value: { option_ids: "o1" } }]), 400);
    await expectError(bad([{ ...valid, new_value: { option_ids: [1] } }]), 400);
    await expectError(bad([{ ...valid, new_value: { rating: 4.5 } }]), 400);
    await expectError(bad([{ ...valid, new_value: { text: 3 } }]), 400);
    expect(await changeRows()).toHaveLength(0);
  });

  it("returns 413 above 500 changes or 500 rows per config table", async () => {
    const changes = Array.from({ length: 501 }, (_, i) => change(`c${i}`, `t${i}`, FIELD, ts(1), { option_ids: [] }));
    await expectError(call("POST", "/v1/sync/push", { token: ADMIN, body: { changes } }), 413, "payload_too_large");
    const settings = Array.from({ length: 501 }, (_, i) => ({ key: `k${i}`, value: i, updated_at: ts(1) }));
    await expectError(call("POST", "/v1/sync/push", { token: ADMIN, body: { settings } }), 413);
    expect(
      await push(ADMIN, { changes: changes.slice(0, 500), settings: settings.slice(0, 500) }),
    ).toMatchObject({ rev: 1 });
    expect(await changeRows()).toHaveLength(500);
  });
});

describe("POST /v1/sync/push: configuration", () => {
  const field = (updatedAt: string, name: string) => ({
    id: "f1",
    key: "genre",
    name,
    kind: "single",
    target_tag: "GENRE",
    target_slot: null,
    required: true,
    visible: false,
    position: 3,
    default_option_id: null,
    is_advance_trigger: false,
    artist_level: true,
    updated_at: updatedAt,
    deleted_at: null,
  });

  it("upserts with last-write-wins on updated_at", async () => {
    const { token } = await createDevice();
    await push(token, { fields: [field(ts(10), "Ten")] });
    await push(token, { fields: [field(ts(5), "Five")] });
    expect((await pullAll(token, "fields"))[0].name).toBe("Ten");
    await push(token, { fields: [field(ts(10), "Ten again")] });
    expect((await pullAll(token, "fields"))[0].name).toBe("Ten again");
    await push(token, { fields: [field(ts(11), "Eleven")] });
    const rows = await pullAll(token, "fields");
    expect(rows).toHaveLength(1);
    expect(rows[0].name).toBe("Eleven");
  });

  it("sends the stored row back to a device whose older config row lost", async () => {
    const { token: phone } = await createDevice();
    await push(ADMIN, {
      fields: [field(ts(10), "Ten")],
      settings: [{ key: "comment.separator", value: " ", updated_at: ts(10) }],
    });
    const before = await pull(phone, { fields: null, settings: null });
    const [storedField] = before.tables.fields!.rows;
    const [storedSetting] = before.tables.settings!.rows;

    // Older rows differing in every column: nothing changes but the rev.
    const older = {
      ...field(ts(5), "Five"),
      key: "genre-old",
      kind: "multi",
      target_tag: "GROUPING",
      target_slot: 2,
      required: false,
      visible: true,
      position: 9,
      default_option_id: "o9",
      is_advance_trigger: true,
      artist_level: false,
      deleted_at: ts(5),
    };
    const res = await push(phone, {
      fields: [older],
      settings: [{ key: "comment.separator", value: "-", updated_at: ts(5), deleted_at: ts(5) }],
    });

    const after = await pull(phone, { fields: before.tables.fields!.cursor, settings: before.tables.settings!.cursor });
    expect(after.tables.fields!.rows).toEqual([{ ...storedField, rev: res.rev }]);
    expect(after.tables.settings!.rows).toEqual([{ ...storedSetting, rev: res.rev }]);
    expect(storedField).toMatchObject({ name: "Ten", updated_at: ts(10) });
  });

  it("keys settings by key, with LWW", async () => {
    await push(ADMIN, { settings: [{ key: "comment.separator", value: " ", updated_at: ts(2) }] });
    await push(ADMIN, { settings: [{ key: "comment.separator", value: "-", updated_at: ts(1) }] });
    await push(ADMIN, { settings: [{ key: "multi.separator", value: "/", updated_at: ts(1) }] });
    const settings = Object.fromEntries((await pullAll(ADMIN, "settings")).map((row) => [row.key, row.value]));
    expect(settings).toEqual({ "comment.separator": " ", "multi.separator": "/" });
  });

  it("round-trips JSON and boolean columns", async () => {
    const option = {
      id: "o1",
      field_id: "f1",
      value: "RAP FR",
      label: "Rap FR",
      color: "systemGreen",
      aliases: ["rap francais", "Rap Fr"],
      position: 2,
      archived: true,
      updated_at: ts(1),
      deleted_at: null,
    };
    const rule = {
      id: "r1",
      name: "Titre « remix »",
      enabled: false,
      position: 1,
      condition: { type: "title_contains", patterns: ["remix", "rmx"] },
      action: { field_id: "f1", option_id: "o1" },
      mode: "apply",
      updated_at: ts(1),
      deleted_at: null,
    };
    const view = {
      id: "v1",
      name: "À compléter",
      filters: { special: ["incomplete"], nested: { a: [1, 2.5, null, true] } },
      sort: { key: "artist", ascending: true },
      skip_complete: true,
      position: 0,
      builtin: false,
      updated_at: ts(1),
      deleted_at: null,
    };
    const settings = [
      { key: "s.string", value: "()", updated_at: ts(1), deleted_at: null },
      { key: "s.array", value: ["mp3", "wav"], updated_at: ts(1), deleted_at: null },
      { key: "s.object", value: { a: { b: false } }, updated_at: ts(1), deleted_at: null },
      { key: "s.number", value: 1.5, updated_at: ts(1), deleted_at: null },
      { key: "s.bool", value: true, updated_at: ts(1), deleted_at: null },
      { key: "s.null", value: null, updated_at: ts(1), deleted_at: null },
      { key: "s.json-looking", value: '{"not":"parsed"}', updated_at: ts(1), deleted_at: null },
    ];
    const f = field(ts(1), "Genre");
    const res = await push(ADMIN, { fields: [f], field_options: [option], rules: [rule], saved_views: [view], settings });

    const pulled = await pull(ADMIN, {
      fields: null,
      field_options: null,
      rules: null,
      saved_views: null,
      settings: null,
    });
    const withRev = <T extends object>(row: T) => ({ ...row, rev: res.rev });
    expect(pulled.tables.fields!.rows).toEqual([withRev(f)]);
    expect(pulled.tables.field_options!.rows).toEqual([withRev(option)]);
    expect(pulled.tables.rules!.rows).toEqual([withRev(rule)]);
    expect(pulled.tables.saved_views!.rows).toEqual([withRev(view)]);
    expect(pulled.tables.settings!.rows).toEqual(settings.map(withRev));

    // Storage form in D1: 0/1 integers and JSON text.
    const [rawOption] = await dbRows("SELECT archived, aliases FROM field_options");
    expect(rawOption).toEqual({ archived: 1, aliases: '["rap francais","Rap Fr"]' });
    const rawSettings = Object.fromEntries(
      (await dbRows<{ key: string; value: string | null }>("SELECT key, value FROM settings")).map((r) => [r.key, r.value]),
    );
    expect(rawSettings["s.string"]).toBe('"()"');
    expect(rawSettings["s.null"]).toBeNull();
  });

  it("applies column defaults for omitted optional keys", async () => {
    await push(ADMIN, {
      field_options: [{ id: "o1", field_id: "f1", value: "POP", updated_at: ts(1) }],
      saved_views: [{ id: "v1", name: "Vue", updated_at: ts(1) }],
    });
    const [option] = await pullAll(ADMIN, "field_options");
    expect(option).toMatchObject({ aliases: [], position: 0, archived: false, label: null, deleted_at: null });
    const [view] = await pullAll(ADMIN, "saved_views");
    expect(view).toMatchObject({ filters: {}, sort: {}, skip_complete: false, builtin: false });
  });

  it("rejects malformed configuration rows", async () => {
    const bad = (body: unknown) => call("POST", "/v1/sync/push", { token: ADMIN, body });
    await expectError(bad({ fields: [{ ...field(ts(1), "x"), required: 1 }] }), 400);
    await expectError(bad({ fields: [{ ...field(ts(1), "x"), updated_at: undefined }] }), 400);
    await expectError(bad({ rules: [{ id: "r", name: "n", condition: null, action: {}, updated_at: ts(1) }] }), 400);
    await expectError(bad({ settings: [{ value: 1, updated_at: ts(1) }] }), 400);
    await expectError(bad({ field_options: {} }), 400);
  });
});
