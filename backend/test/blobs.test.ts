import { beforeEach, describe, expect, it } from "vitest";
import { ADMIN, admin, call, createDevice, expectError, expectJson, resetBucket, resetDb } from "./helpers";

beforeEach(async () => {
  await resetDb();
  await resetBucket();
});

const AUDIO = "audio/track-1.m4a";
const bytes = Uint8Array.from({ length: 100 }, (_, i) => i);

async function upload(key = AUDIO, body: Uint8Array = bytes, contentType = "audio/mp4") {
  return expectJson(call("PUT", `/v1/admin/blobs/${key}`, { token: ADMIN, body, headers: { "content-type": contentType } }), 200);
}

async function get(token: string, key: string, headers: Record<string, string> = {}) {
  return call("GET", `/v1/blobs/${key}`, { token, headers });
}

describe("admin blobs", () => {
  it("stores, inspects and deletes a blob", async () => {
    const put = await upload();
    expect(put).toMatchObject({ key: AUDIO, size: 100 });
    expect(put.etag).toMatch(/^".+"$/);

    const head = await admin("HEAD", `/v1/admin/blobs/${AUDIO}`);
    expect(head.status).toBe(200);
    expect(head.headers.get("content-length")).toBe("100");
    expect(head.headers.get("content-type")).toBe("audio/mp4");
    expect(head.headers.get("etag")).toBe(put.etag);

    expect(await expectJson(admin("DELETE", `/v1/admin/blobs/${AUDIO}`), 200)).toEqual({ key: AUDIO, deleted: true });
    expect((await admin("HEAD", `/v1/admin/blobs/${AUDIO}`)).status).toBe(404);
    await expectError(get(ADMIN, AUDIO), 404, "not_found");
    // Deleting again is fine.
    await expectJson(admin("DELETE", `/v1/admin/blobs/${AUDIO}`), 200);
  });

  it("accepts a body without Content-Length", async () => {
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(bytes.slice(0, 40));
        controller.enqueue(bytes.slice(40));
        controller.close();
      },
    });
    const put = await expectJson(call("PUT", `/v1/admin/blobs/${AUDIO}`, { token: ADMIN, body: stream }), 200);
    expect(put.size).toBe(100);
    const res = await get(ADMIN, AUDIO);
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(bytes);
    expect(res.headers.get("content-type")).toBe("application/octet-stream");
  });

  it("validates keys", async () => {
    for (const key of ["videos/x.mp4", "audio/", "audio/a%20b.m4a", "audio/sub/x.m4a", "x.m4a", "covers/a b.jpg"]) {
      await expectError(call("PUT", `/v1/admin/blobs/${key}`, { token: ADMIN, body: "x" }), 400, "bad_request");
    }
    expect((await admin("HEAD", "/v1/admin/blobs/other/x")).status).toBe(400);
    await expectError(admin("DELETE", "/v1/admin/blobs/other/x"), 400);
    await expectError(get(ADMIN, "other/x.m4a"), 400);
  });
});

describe("GET /v1/blobs/<key>", () => {
  it("serves the whole file to a device", async () => {
    const { token } = await createDevice();
    const { etag } = await upload();
    const res = await get(token, AUDIO);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("audio/mp4");
    expect(res.headers.get("content-length")).toBe("100");
    expect(res.headers.get("accept-ranges")).toBe("bytes");
    expect(res.headers.get("etag")).toBe(etag);
    expect(res.headers.get("cache-control")).toBe("private, max-age=86400");
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(bytes);
  });

  it("uses a revalidating cache policy for covers", async () => {
    await upload("covers/t1_600.jpg", bytes.slice(0, 10), "image/jpeg");
    const res = await get(ADMIN, "covers/t1_600.jpg");
    expect(res.headers.get("cache-control")).toBe("private, max-age=0, must-revalidate");
    expect(res.headers.get("content-type")).toBe("image/jpeg");
    await res.arrayBuffer();
  });

  it("serves byte ranges", async () => {
    await upload();
    const cases: [string, number, number][] = [
      ["bytes=0-9", 0, 9],
      ["bytes=90-", 90, 99],
      ["bytes=-5", 95, 99],
      ["bytes=50-50", 50, 50],
      ["bytes=95-1000", 95, 99],
      ["bytes=-500", 0, 99],
    ];
    for (const [range, start, end] of cases) {
      const res = await get(ADMIN, AUDIO, { range });
      expect(res.status, range).toBe(206);
      expect(res.headers.get("content-range"), range).toBe(`bytes ${start}-${end}/100`);
      expect(res.headers.get("content-length"), range).toBe(String(end - start + 1));
      expect(res.headers.get("accept-ranges")).toBe("bytes");
      expect(new Uint8Array(await res.arrayBuffer()), range).toEqual(bytes.slice(start, end + 1));
    }
  });

  it("returns 416 for unsatisfiable ranges", async () => {
    await upload();
    for (const range of ["bytes=100-", "bytes=200-300", "bytes=-0"]) {
      const res = await get(ADMIN, AUDIO, { range });
      expect(res.headers.get("content-range"), range).toBe("bytes */100");
      await expectError(res, 416, "range_not_satisfiable");
    }
  });

  it("ignores ranges it does not support", async () => {
    await upload();
    for (const range of ["bytes=5-2", "bytes=0-1,5-6", "items=0-1", "bytes=-"]) {
      const res = await get(ADMIN, AUDIO, { range });
      expect(res.status, range).toBe(200);
      expect((await res.arrayBuffer()).byteLength).toBe(100);
    }
  });

  it("answers 304 to a matching If-None-Match", async () => {
    const { etag } = await upload();
    const notModified = await get(ADMIN, AUDIO, { "if-none-match": etag });
    expect(notModified.status).toBe(304);
    expect(notModified.headers.get("etag")).toBe(etag);
    expect(await notModified.text()).toBe("");
    expect((await get(ADMIN, AUDIO, { "if-none-match": `W/${etag}`, range: "bytes=0-1" })).status).toBe(304);
    expect((await get(ADMIN, AUDIO, { "if-none-match": `"other", ${etag}` })).status).toBe(304);

    const changed = await get(ADMIN, AUDIO, { "if-none-match": '"stale"' });
    expect(changed.status).toBe(200);
    expect((await changed.arrayBuffer()).byteLength).toBe(100);
    const ranged = await get(ADMIN, AUDIO, { "if-none-match": '"stale"', range: "bytes=0-3" });
    expect(ranged.status).toBe(206);
    expect(new Uint8Array(await ranged.arrayBuffer())).toEqual(bytes.slice(0, 4));
  });

  it("honours a matching If-Range (ETag or Last-Modified) with 206", async () => {
    const { etag } = await upload();
    const byEtag = await get(ADMIN, AUDIO, { range: "bytes=10-19", "if-range": etag });
    expect(byEtag.status).toBe(206);
    expect(byEtag.headers.get("content-range")).toBe("bytes 10-19/100");
    expect(new Uint8Array(await byEtag.arrayBuffer())).toEqual(bytes.slice(10, 20));

    const lastModified = (await call("HEAD", `/v1/blobs/${AUDIO}`, { token: ADMIN })).headers.get("last-modified")!;
    const byDate = await get(ADMIN, AUDIO, { range: "bytes=10-19", "if-range": lastModified });
    expect(byDate.status).toBe(206);
    expect(new Uint8Array(await byDate.arrayBuffer())).toEqual(bytes.slice(10, 20));
  });

  it("ignores Range and serves the whole new file when If-Range is stale", async () => {
    const { etag: oldEtag } = await upload();
    const replaced = Uint8Array.from({ length: 120 }, (_, i) => 255 - i);
    const { etag: newEtag } = await upload(AUDIO, replaced);
    expect(newEtag).not.toBe(oldEtag);

    for (const ifRange of [oldEtag, `W/${newEtag}`, "Thu, 01 Jan 2026 00:00:00 GMT", "garbage"]) {
      const res = await get(ADMIN, AUDIO, { range: "bytes=10-19", "if-range": ifRange });
      expect(res.status, ifRange).toBe(200);
      expect(res.headers.get("content-range"), ifRange).toBeNull();
      expect(res.headers.get("content-length"), ifRange).toBe("120");
      expect(res.headers.get("etag"), ifRange).toBe(newEtag);
      expect(new Uint8Array(await res.arrayBuffer()), ifRange).toEqual(replaced);
    }
    // An otherwise unsatisfiable range is ignored too.
    const big = await get(ADMIN, AUDIO, { range: "bytes=500-", "if-range": oldEtag });
    expect(big.status).toBe(200);
    expect((await big.arrayBuffer()).byteLength).toBe(120);
    const head = await call("HEAD", `/v1/blobs/${AUDIO}`, { token: ADMIN, headers: { range: "bytes=0-9", "if-range": oldEtag } });
    expect(head.status).toBe(200);
    expect(head.headers.get("content-length")).toBe("120");
  });

  it("supports HEAD for devices", async () => {
    const { token } = await createDevice();
    await upload();
    const res = await call("HEAD", `/v1/blobs/${AUDIO}`, { token });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-length")).toBe("100");
    const ranged = await call("HEAD", `/v1/blobs/${AUDIO}`, { token, headers: { range: "bytes=0-9" } });
    expect(ranged.status).toBe(206);
    expect(ranged.headers.get("content-range")).toBe("bytes 0-9/100");
  });

  it("returns 404 for a missing blob and 401 without a token", async () => {
    await expectError(get(ADMIN, "audio/missing.m4a"), 404, "not_found");
    await expectError(get(ADMIN, "audio/missing.m4a", { range: "bytes=0-1" }), 404);
    await expectError(call("GET", `/v1/blobs/${AUDIO}`), 401);
  });
});
