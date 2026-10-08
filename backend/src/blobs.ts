// Audio and cover files in R2. Devices read them (GET/HEAD /v1/blobs/<key>);
// the Mac CLI writes them (PUT/HEAD/DELETE /v1/admin/blobs/<key>).

import { HttpError, badRequest, json, notFound } from "./http";
import type { RequestContext } from "./router";

const KEY_PATTERN = /^(audio|covers)\/[A-Za-z0-9._-]+$/;

type ByteRange = { offset: number; length: number };

function blobKey(params: string[]): string {
  const key = params[0] ?? "";
  if (!KEY_PATTERN.test(key)) {
    throw badRequest("Blob key must look like audio/<name> or covers/<name>, with only A-Z a-z 0-9 . _ -");
  }
  return key;
}

/** Covers are replaced in place when the artwork changes; audio files are not. */
function cacheControl(key: string): string {
  return key.startsWith("covers/") ? "private, max-age=0, must-revalidate" : "private, max-age=86400";
}

function objectHeaders(object: R2Object, key: string): Headers {
  const headers = new Headers();
  object.writeHttpMetadata(headers);
  if (!headers.has("content-type")) headers.set("content-type", "application/octet-stream");
  headers.set("etag", object.httpEtag);
  headers.set("last-modified", object.uploaded.toUTCString());
  headers.set("accept-ranges", "bytes");
  headers.set("cache-control", cacheControl(key));
  return headers;
}

/**
 * Parses a single `bytes=` range against the object size. Returns undefined
 * when the header must be ignored (syntax not supported, e.g. multiple ranges),
 * which means serving the whole object.
 */
export function parseRange(header: string, size: number): ByteRange | "unsatisfiable" | undefined {
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (match === null) return undefined;
  const [, startText = "", endText = ""] = match;
  if (startText === "") {
    if (endText === "") return undefined;
    const suffix = Number(endText);
    if (suffix === 0 || size === 0) return "unsatisfiable";
    const length = Math.min(suffix, size);
    return { offset: size - length, length };
  }
  const start = Number(startText);
  const end = endText === "" ? size - 1 : Number(endText);
  if (end < start && endText !== "") return undefined;
  if (start >= size) return "unsatisfiable";
  return { offset: start, length: Math.min(end, size - 1) - start + 1 };
}

function etagMatches(ifNoneMatch: string, etag: string): boolean {
  if (ifNoneMatch.trim() === "*") return true;
  return ifNoneMatch.split(",").some((tag) => tag.trim().replace(/^W\//, "") === etag);
}

/** GET and HEAD of a blob, with Range (206/416) and If-None-Match (304) support. */
export async function handleBlobGet({ request, env, params }: RequestContext): Promise<Response> {
  const key = blobKey(params);
  const rangeHeader = request.headers.get("range");
  const ifNoneMatch = request.headers.get("if-none-match");
  const isHead = request.method === "HEAD";

  if (rangeHeader === null && ifNoneMatch === null && !isHead) {
    const object = await env.BUCKET.get(key);
    if (object === null) throw notFound(`No blob ${key}`);
    const headers = objectHeaders(object, key);
    headers.set("content-length", String(object.size));
    return new Response(object.body, { headers });
  }

  // Conditional or partial request: the size and ETag are needed first.
  // The second attempt covers an object replaced between head() and get().
  for (let attempt = 0; attempt < 2; attempt++) {
    const head = await env.BUCKET.head(key);
    if (head === null) throw notFound(`No blob ${key}`);
    const headers = objectHeaders(head, key);
    if (ifNoneMatch !== null && etagMatches(ifNoneMatch, head.httpEtag)) {
      return new Response(null, { status: 304, headers });
    }
    const range = rangeHeader === null ? undefined : parseRange(rangeHeader, head.size);
    if (range === "unsatisfiable") {
      throw new HttpError(416, "range_not_satisfiable", `Range not satisfiable for ${head.size} bytes`, {
        "content-range": `bytes */${head.size}`,
      });
    }
    const status = range === undefined ? 200 : 206;
    headers.set("content-length", String(range?.length ?? head.size));
    if (range !== undefined) {
      headers.set("content-range", `bytes ${range.offset}-${range.offset + range.length - 1}/${head.size}`);
    }
    if (isHead) return new Response(null, { status, headers });

    const object = await env.BUCKET.get(key, {
      ...(range === undefined ? {} : { range }),
      onlyIf: { etagMatches: head.etag },
    });
    if (object === null) throw notFound(`No blob ${key}`);
    if ("body" in object) return new Response(object.body, { status, headers });
  }
  throw new HttpError(409, "conflict", `Blob ${key} is being replaced; retry`);
}

/** PUT /v1/admin/blobs/<key>: stores the body, keeping the request's Content-Type. */
export async function handleBlobPut({ request, env, params }: RequestContext): Promise<Response> {
  const key = blobKey(params);
  const contentType = request.headers.get("content-type") ?? "application/octet-stream";
  // R2 streams need a known length; without Content-Length (chunked upload) buffer the body.
  const body = request.headers.has("content-length") ? request.body : await request.arrayBuffer();
  const object = await env.BUCKET.put(key, body, { httpMetadata: { contentType } });
  if (object === null) throw new Error(`R2 put of ${key} returned no object`);
  return json({ key, size: object.size, etag: object.httpEtag });
}

/** DELETE /v1/admin/blobs/<key>: idempotent. */
export async function handleBlobDelete({ env, params }: RequestContext): Promise<Response> {
  const key = blobKey(params);
  await env.BUCKET.delete(key);
  return json({ key, deleted: true });
}
