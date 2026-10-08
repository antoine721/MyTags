// mytags-api: the Cloudflare Worker behind the MyTags iPhone app and Mac CLI.
// Route table and error handling; the contract is docs/api.md.

import {
  handleApplyRunUpsert,
  handleChangesMark,
  handleConfigReset,
  handleDeviceCreate,
  handleDeviceList,
  handleDeviceRevoke,
  handleTracksPatch,
  handleTracksUpsert,
} from "./admin";
import { handleBlobDelete, handleBlobGet, handleBlobPut } from "./blobs";
import { HttpError, errorResponse, json, nowIso } from "./http";
import { dispatch, principalOf, type Route } from "./router";
import { handlePull, handlePush } from "./sync";

const routes: readonly Route[] = [
  { path: "/v1/health", access: "public", methods: { GET: () => json({ ok: true, time: nowIso() }) } },
  {
    path: "/v1/me",
    access: "token",
    methods: {
      GET: (context) => {
        const principal = principalOf(context);
        return json({
          role: principal.role,
          device_id: principal.role === "device" ? principal.deviceId : null,
        });
      },
    },
  },
  { path: "/v1/sync/pull", access: "token", methods: { POST: handlePull } },
  { path: "/v1/sync/push", access: "token", methods: { POST: handlePush } },
  { path: /^\/v1\/blobs\/(.+)$/, access: "token", methods: { GET: handleBlobGet, HEAD: handleBlobGet } },

  { path: "/v1/admin/tracks", access: "admin", methods: { POST: handleTracksUpsert } },
  { path: "/v1/admin/tracks/patch", access: "admin", methods: { POST: handleTracksPatch } },
  { path: "/v1/admin/changes/mark", access: "admin", methods: { POST: handleChangesMark } },
  { path: "/v1/admin/apply-runs", access: "admin", methods: { POST: handleApplyRunUpsert } },
  { path: "/v1/admin/devices", access: "admin", methods: { GET: handleDeviceList, POST: handleDeviceCreate } },
  { path: /^\/v1\/admin\/devices\/([^/]+)$/, access: "admin", methods: { DELETE: handleDeviceRevoke } },
  {
    path: /^\/v1\/admin\/blobs\/(.+)$/,
    access: "admin",
    methods: { PUT: handleBlobPut, HEAD: handleBlobGet, DELETE: handleBlobDelete },
  },
  { path: "/v1/admin/config/reset", access: "admin", methods: { POST: handleConfigReset } },
  // Unknown /v1/admin/* paths still require the admin token (403 for devices).
  { path: /^\/v1\/admin\//, access: "admin", methods: {} },
];

export default {
  async fetch(request, env, ctx): Promise<Response> {
    try {
      return await dispatch(routes, request, env, ctx);
    } catch (error) {
      if (error instanceof HttpError) return errorResponse(error);
      console.error("unhandled error", request.method, new URL(request.url).pathname, error);
      return errorResponse(new HttpError(500, "internal", "Internal server error"));
    }
  },
} satisfies ExportedHandler<Env>;
