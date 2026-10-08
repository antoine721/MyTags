// Bearer token authentication: the admin token (secret ADMIN_TOKEN, used by
// the Mac CLI) or a device token (only its SHA-256 is stored in `devices`).

import { HttpError } from "./http";

export type Principal = { role: "admin" } | { role: "device"; deviceId: string };

/** Successful device lookups are reused for this long by the isolate. */
const DEVICE_CACHE_TTL_MS = 60_000;
/** devices.last_seen_at is written at most this often per device. */
const LAST_SEEN_INTERVAL_MS = 10 * 60_000;

interface CachedDevice {
  deviceId: string;
  expiresAt: number;
  /** Epoch ms of the last known last_seen_at write (0 if never). */
  lastSeenAt: number;
}

/** Keyed by token hash. Only valid, non-revoked devices are cached. */
const deviceCache = new Map<string, CachedDevice>();
let adminDigest: { token: string; digest: Uint8Array } | undefined;

function unauthorized(message: string): HttpError {
  return new HttpError(401, "unauthorized", message, { "www-authenticate": 'Bearer realm="mytags"' });
}

export async function authenticate(request: Request, env: Env, ctx: ExecutionContext): Promise<Principal> {
  const token = bearerToken(request);
  const digest = await sha256(token);
  if (await isAdminToken(digest, env.ADMIN_TOKEN)) return { role: "admin" };
  return { role: "device", deviceId: await findDevice(toHex(digest), env, ctx) };
}

function bearerToken(request: Request): string {
  const header = request.headers.get("authorization");
  if (header === null) throw unauthorized("Missing Authorization header");
  const token = /^Bearer\s+(\S+)\s*$/i.exec(header)?.[1];
  if (token === undefined) throw unauthorized("Authorization header must be 'Bearer <token>'");
  return token;
}

/** Constant-time comparison of SHA-256 digests (equal lengths, so no length leak). */
async function isAdminToken(digest: Uint8Array, adminToken: string | undefined): Promise<boolean> {
  if (!adminToken) return false;
  if (adminDigest?.token !== adminToken) {
    adminDigest = { token: adminToken, digest: await sha256(adminToken) };
  }
  return crypto.subtle.timingSafeEqual(digest, adminDigest.digest);
}

async function findDevice(tokenHash: string, env: Env, ctx: ExecutionContext): Promise<string> {
  const now = Date.now();
  let entry = deviceCache.get(tokenHash);
  if (entry === undefined || entry.expiresAt <= now) {
    const row = await env.DB.prepare(
      "SELECT id, last_seen_at, revoked_at FROM devices WHERE token_hash = ?1",
    )
      .bind(tokenHash)
      .first<{ id: string; last_seen_at: string | null; revoked_at: string | null }>();
    if (row === null || row.revoked_at !== null) {
      deviceCache.delete(tokenHash);
      throw unauthorized("Invalid or revoked token");
    }
    entry = {
      deviceId: row.id,
      expiresAt: now + DEVICE_CACHE_TTL_MS,
      lastSeenAt: row.last_seen_at === null ? 0 : Date.parse(row.last_seen_at),
    };
    deviceCache.set(tokenHash, entry);
  }
  if (now - entry.lastSeenAt >= LAST_SEEN_INTERVAL_MS) {
    entry.lastSeenAt = now;
    const update = env.DB.prepare("UPDATE devices SET last_seen_at = ?1 WHERE id = ?2")
      .bind(new Date(now).toISOString(), entry.deviceId)
      .run()
      .catch((error: unknown) => console.error("last_seen_at update failed", error));
    ctx.waitUntil(update);
  }
  return entry.deviceId;
}

/**
 * Drops a revoked device from this isolate's cache. Other isolates may still
 * accept its token until their cache entry expires (at most 60 s).
 */
export function forgetDevice(deviceId: string): void {
  for (const [hash, entry] of deviceCache) {
    if (entry.deviceId === deviceId) deviceCache.delete(hash);
  }
}

/** New device token: 32 random bytes, base64url without padding. */
export function newDeviceToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export async function tokenHash(token: string): Promise<string> {
  return toHex(await sha256(token));
}

async function sha256(text: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text)));
}

function toHex(bytes: Uint8Array): string {
  let hex = "";
  for (const byte of bytes) hex += byte.toString(16).padStart(2, "0");
  return hex;
}
