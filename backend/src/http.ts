// HTTP helpers: JSON responses, typed errors and request body parsing.

/** Largest JSON request body accepted (bytes). Row-count limits apply first in practice. */
const MAX_JSON_BODY_BYTES = 8 * 1024 * 1024;

export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly headers: HeadersInit = {},
  ) {
    super(message);
  }
}

export const badRequest = (message: string) => new HttpError(400, "bad_request", message);
export const tooLarge = (message: string) => new HttpError(413, "payload_too_large", message);
export const notFound = (message = "Not found") => new HttpError(404, "not_found", message);

const JSON_HEADERS = { "content-type": "application/json; charset=utf-8" };

export function json(data: unknown, status = 200): Response {
  return jsonText(JSON.stringify(data), status);
}

/** Response from an already-serialized JSON string (avoids a parse/stringify round trip). */
export function jsonText(body: string, status = 200): Response {
  return new Response(body, { status, headers: JSON_HEADERS });
}

export function errorResponse(error: HttpError): Response {
  const headers = new Headers(error.headers);
  headers.set("content-type", JSON_HEADERS["content-type"]);
  return new Response(JSON.stringify({ error: error.code, message: error.message }), {
    status: error.status,
    headers,
  });
}

/** Current time as ISO 8601 UTC with milliseconds, the format used everywhere. */
export function nowIso(): string {
  return new Date().toISOString();
}

export type JsonObject = Record<string, unknown>;

export function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Parses the request body as a JSON object, or throws 400/413. */
export async function readJsonObject(request: Request): Promise<JsonObject> {
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_JSON_BODY_BYTES) throw tooLarge("Request body is too large");
  const text = await request.text();
  if (text.length > MAX_JSON_BODY_BYTES) throw tooLarge("Request body is too large");
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    throw badRequest("Request body is not valid JSON");
  }
  if (!isObject(body)) throw badRequest("Request body must be a JSON object");
  return body;
}
