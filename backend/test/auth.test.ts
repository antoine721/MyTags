import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ADMIN, admin, call, createDevice, dbRows, expectError, expectJson, resetDb } from "./helpers";

beforeEach(resetDb);
afterEach(() => {
  vi.useRealTimers();
});

describe("public and identity routes", () => {
  it("serves /v1/health without a token", async () => {
    const body = await expectJson(call("GET", "/v1/health"), 200);
    expect(body.ok).toBe(true);
    expect(body.time).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
  });

  it("identifies the admin token", async () => {
    expect(await expectJson(admin("GET", "/v1/me"), 200)).toEqual({ role: "admin", device_id: null });
  });

  it("identifies a device token", async () => {
    const device = await createDevice();
    const me = await expectJson(call("GET", "/v1/me", { token: device.token }), 200);
    expect(me).toEqual({ role: "device", device_id: device.device_id });
  });
});

describe("rejected credentials", () => {
  it("returns 401 without Authorization header", async () => {
    const res = await call("GET", "/v1/me");
    expect(res.headers.get("www-authenticate")).toContain("Bearer");
    await expectError(res, 401, "unauthorized");
  });

  it("returns 401 for a non-Bearer header", async () => {
    await expectError(call("GET", "/v1/me", { headers: { authorization: `Basic ${btoa("a:b")}` } }), 401);
  });

  it("returns 401 for an unknown token", async () => {
    await expectError(call("GET", "/v1/me", { token: "not-a-real-token" }), 401, "unauthorized");
    await expectError(call("POST", "/v1/sync/pull", { token: `${ADMIN}x`, body: { cursors: {} } }), 401);
  });

  it("forbids admin routes to devices", async () => {
    const { token } = await createDevice();
    await expectError(call("POST", "/v1/admin/tracks", { token, body: { tracks: [] } }), 403, "forbidden");
    await expectError(call("GET", "/v1/admin/devices", { token }), 403, "forbidden");
    await expectError(call("POST", "/v1/admin/config/reset", { token, body: {} }), 403);
    await expectError(call("PUT", "/v1/admin/blobs/audio/x.m4a", { token, body: "abc" }), 403);
    await expectError(call("DELETE", "/v1/admin/blobs/audio/x.m4a", { token }), 403);
    await expectError(call("GET", "/v1/admin/unknown", { token }), 403);
  });

  it("forbids admin-only tables to devices in pull", async () => {
    const { token } = await createDevice();
    const cursors = { changes: { rev: 0, rowid: 0 } };
    await expectError(call("POST", "/v1/sync/pull", { token, body: { cursors } }), 403, "forbidden");
    await expectError(call("POST", "/v1/sync/pull", { token, body: { cursors: { apply_runs: null } } }), 403);
    await expectJson(admin("POST", "/v1/sync/pull", { cursors }), 200);
  });
});

describe("routing errors", () => {
  it("returns 404 for unknown routes", async () => {
    await expectError(call("GET", "/nope"), 404, "not_found");
    await expectError(admin("GET", "/v1/admin/unknown"), 404, "not_found");
  });

  it("returns 405 for a wrong method", async () => {
    const res = await admin("GET", "/v1/sync/pull");
    expect(res.headers.get("allow")).toBe("POST");
    await expectError(res, 405, "method_not_allowed");
    await expectError(admin("POST", "/v1/admin/devices/abc"), 405);
  });

  it("returns 400 for invalid JSON bodies", async () => {
    await expectError(admin("POST", "/v1/sync/push", "{not json"), 400, "bad_request");
    await expectError(admin("POST", "/v1/sync/push", "[1, 2]"), 400, "bad_request");
  });
});

describe("devices", () => {
  it("creates, lists, uses and revokes a device", async () => {
    const created = await createDevice("iPhone de test");
    expect(created.token).toMatch(/^[A-Za-z0-9_-]{43}$/);

    const stored = await dbRows<{ token_hash: string }>("SELECT token_hash FROM devices");
    expect(stored[0]!.token_hash).toMatch(/^[0-9a-f]{64}$/);
    expect(stored[0]!.token_hash).not.toContain(created.token);

    const list = await expectJson(admin("GET", "/v1/admin/devices"), 200);
    expect(list.devices).toHaveLength(1);
    expect(list.devices[0]).toMatchObject({ id: created.device_id, name: "iPhone de test", revoked_at: null });
    expect(list.devices[0]).not.toHaveProperty("token_hash");
    expect(JSON.stringify(list)).not.toContain(created.token);

    await expectJson(call("POST", "/v1/sync/pull", { token: created.token, body: { cursors: {} } }), 200);

    const revoked = await expectJson(admin("DELETE", `/v1/admin/devices/${created.device_id}`), 200);
    expect(revoked.device_id).toBe(created.device_id);
    expect(typeof revoked.revoked_at).toBe("string");
    await expectError(call("GET", "/v1/me", { token: created.token }), 401, "unauthorized");

    // Revoking again keeps the first revocation time.
    const again = await expectJson(admin("DELETE", `/v1/admin/devices/${created.device_id}`), 200);
    expect(again.revoked_at).toBe(revoked.revoked_at);
  });

  it("returns 404 when revoking an unknown device", async () => {
    await expectError(admin("DELETE", "/v1/admin/devices/does-not-exist"), 404, "not_found");
  });

  it("validates the device name", async () => {
    await expectError(admin("POST", "/v1/admin/devices", {}), 400);
    await expectError(admin("POST", "/v1/admin/devices", { name: "x".repeat(101) }), 400);
  });

  it("writes last_seen_at once per 10 minutes", async () => {
    const { token, device_id } = await createDevice();
    await expectJson(call("GET", "/v1/me", { token }), 200);
    const lastSeen = async () => {
      // The update runs in waitUntil(): poll until it lands.
      for (let i = 0; i < 50; i++) {
        const [row] = await dbRows<{ last_seen_at: string | null }>(
          "SELECT last_seen_at FROM devices WHERE id = ?1",
          device_id,
        );
        if (row?.last_seen_at) return row.last_seen_at;
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      return null;
    };
    const first = await lastSeen();
    expect(first).not.toBeNull();
    await env.DB.prepare("UPDATE devices SET last_seen_at = '2000-01-01T00:00:00.000Z'").run();
    await expectJson(call("GET", "/v1/me", { token }), 200);
    await new Promise((resolve) => setTimeout(resolve, 50));
    // Seen less than 10 minutes ago (cached): no new write.
    expect(await lastSeen()).toBe("2000-01-01T00:00:00.000Z");
  });

  it("caches device lookups for 60 seconds", async () => {
    vi.useFakeTimers({ toFake: ["Date"] });
    const { token, device_id } = await createDevice();
    await expectJson(call("GET", "/v1/me", { token }), 200);
    // Revoked behind the Worker's back (as another isolate would): the cache still accepts it...
    await env.DB.prepare("UPDATE devices SET revoked_at = ?1 WHERE id = ?2").bind(new Date().toISOString(), device_id).run();
    await expectJson(call("GET", "/v1/me", { token }), 200);
    // ...until the entry expires.
    vi.setSystemTime(Date.now() + 61_000);
    await expectError(call("GET", "/v1/me", { token }), 401);
  });
});
