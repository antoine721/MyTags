"""In-memory double of the Worker API (docs/api.md), plugged into httpx with MockTransport."""

from __future__ import annotations

import hashlib
import json
import secrets
from datetime import UTC, datetime
from typing import Any

import httpx

ADMIN = "admin-secret"
TABLES = (
    "tracks",
    "fields",
    "field_options",
    "track_values",
    "rules",
    "saved_views",
    "settings",
    "changes",
    "apply_runs",
)
DEVICE_TABLES = TABLES[:7]


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class FakeWorker:
    def __init__(self) -> None:
        self.rev = 0
        self.rowid = 0
        self.tables: dict[str, dict[Any, dict[str, Any]]] = {t: {} for t in TABLES}
        self.rowids: dict[str, dict[Any, int]] = {t: {} for t in TABLES}
        self.blobs: dict[str, tuple[bytes, str]] = {}
        self.devices: dict[str, dict[str, Any]] = {}
        self.requests: list[tuple[str, str]] = []

    # -- helpers -----------------------------------------------------------------------------

    def _key(self, table: str, row: dict[str, Any]) -> Any:
        if table == "track_values":
            return (row["track_id"], row["field_id"])
        if table == "settings":
            return row["key"]
        return row["id"]

    def _write(self, table: str, row: dict[str, Any], rev: int) -> None:
        key = self._key(table, row)
        if key not in self.rowids[table]:
            self.rowid += 1
            self.rowids[table][key] = self.rowid
        row = {**row, "rev": rev}
        self.tables[table][key] = row

    def _next_rev(self) -> int:
        self.rev += 1
        return self.rev

    def _role(self, request: httpx.Request) -> tuple[str | None, str | None]:
        auth = request.headers.get("authorization", "")
        token = auth.removeprefix("Bearer ").strip()
        if token == ADMIN:
            return "admin", None
        digest = hashlib.sha256(token.encode()).hexdigest()
        for d in self.devices.values():
            if d["token_hash"] == digest and not d.get("revoked_at"):
                return "device", d["id"]
        return None, None

    # -- routing -----------------------------------------------------------------------------

    def handler(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        method = request.method
        self.requests.append((method, path))
        if path == "/v1/health":
            return httpx.Response(200, json={"ok": True, "time": _now()})
        role, device_id = self._role(request)
        if role is None:
            return httpx.Response(401, json={"error": "unauthorized", "message": "jeton invalide"})
        if path.startswith("/v1/admin/") and role != "admin":
            return httpx.Response(403, json={"error": "forbidden", "message": "admin"})
        body = json.loads(request.content) if request.content and method in ("POST",) else {}
        if path == "/v1/me":
            return httpx.Response(200, json={"role": role, "device_id": device_id})
        if path == "/v1/sync/pull":
            return self._pull(body, role)
        if path == "/v1/sync/push":
            return self._push(body, device_id or "mac")
        if path == "/v1/admin/tracks":
            rev = self._next_rev()
            for t in body["tracks"]:
                self._write("tracks", {"apply_status": "aucun", **t, "updated_at": _now()}, rev)
            return httpx.Response(200, json={"ok": True, "rev": rev})
        if path == "/v1/admin/tracks/patch":
            rev = self._next_rev()
            for p in body["patches"]:
                current = self.tables["tracks"].get(p["id"])
                if current is None:
                    continue
                self._write("tracks", {**current, **p, "updated_at": _now()}, rev)
            return httpx.Response(200, json={"ok": True, "rev": rev})
        if path == "/v1/admin/changes/mark":
            rev = self._next_rev()
            ids = set(body["track_ids"])
            from_status = body.get("from_status", "sent")
            for c in list(self.tables["changes"].values()):
                if c["track_id"] in ids and c["status"] == from_status:
                    self._write(
                        "changes",
                        {
                            **c,
                            "status": body["status"],
                            "apply_run_id": body.get("apply_run_id"),
                            "updated_at": _now(),
                        },
                        rev,
                    )
            return httpx.Response(200, json={"ok": True})
        if path == "/v1/admin/apply-runs":
            self._write("apply_runs", {**body["run"], "updated_at": _now()}, self._next_rev())
            return httpx.Response(200, json={"ok": True})
        if path == "/v1/admin/devices" and method == "POST":
            token = secrets.token_urlsafe(32)
            did = secrets.token_hex(8)
            self.devices[did] = {
                "id": did,
                "name": body["name"],
                "token_hash": hashlib.sha256(token.encode()).hexdigest(),
                "created_at": _now(),
                "revoked_at": None,
            }
            return httpx.Response(200, json={"device_id": did, "token": token})
        if path == "/v1/admin/devices" and method == "GET":
            return httpx.Response(
                200,
                json={
                    "devices": [
                        {k: v for k, v in d.items() if k != "token_hash"} for d in self.devices.values()
                    ]
                },
            )
        if path.startswith("/v1/admin/devices/") and method == "DELETE":
            self.devices[path.rsplit("/", 1)[1]]["revoked_at"] = _now()
            return httpx.Response(200, json={"ok": True})
        if path == "/v1/admin/config/reset":
            rev = self._next_rev()
            for table in ("fields", "field_options", "rules", "saved_views", "settings"):
                for row in body["config"].get(table, []):
                    self._write(table, {**row, "updated_at": _now()}, rev)
            return httpx.Response(200, json={"ok": True})
        if path.startswith("/v1/admin/blobs/"):
            key = path.removeprefix("/v1/admin/blobs/")
            if method == "PUT":
                self.blobs[key] = (request.content, request.headers.get("content-type", ""))
                return httpx.Response(200, json={"ok": True})
            if method == "HEAD":
                if key not in self.blobs:
                    return httpx.Response(404)
                return httpx.Response(200, headers={"content-length": str(len(self.blobs[key][0]))})
            if method == "DELETE":
                self.blobs.pop(key, None)
                return httpx.Response(200, json={"ok": True})
        if path.startswith("/v1/blobs/"):
            key = path.removeprefix("/v1/blobs/")
            if key not in self.blobs:
                return httpx.Response(404, json={"error": "not_found", "message": key})
            return httpx.Response(200, content=self.blobs[key][0])
        return httpx.Response(404, json={"error": "not_found", "message": path})

    def _pull(self, body: dict[str, Any], role: str) -> httpx.Response:
        limit = min(int(body.get("limit", 500)), 1000)
        out: dict[str, Any] = {}
        for table, cursor in body["cursors"].items():
            if role == "device" and table not in DEVICE_TABLES:
                return httpx.Response(403, json={"error": "forbidden", "message": table})
            rows = sorted(
                ((r["rev"], self.rowids[table][k], r) for k, r in self.tables[table].items()),
                key=lambda x: (x[0], x[1]),
            )
            after = [x for x in rows if (x[0], x[1]) > (cursor["rev"], cursor["rowid"])]
            page = after[:limit]
            out[table] = {
                "rows": [x[2] for x in page],
                "cursor": {"rev": page[-1][0], "rowid": page[-1][1]} if page else cursor,
                "has_more": len(after) > limit,
            }
        return httpx.Response(200, json={"tables": out, "server_rev": self.rev})

    def _push(self, body: dict[str, Any], device_id: str) -> httpx.Response:
        rev = self._next_rev()
        accepted = []
        for c in body.get("changes", []):
            accepted.append(c["id"])
            if c["id"] in self.tables["changes"]:
                continue
            self._write(
                "changes",
                {**c, "device_id": device_id, "status": "sent", "apply_run_id": None, "updated_at": _now()},
                rev,
            )
            key = (c["track_id"], c["field_id"])
            current = self.tables["track_values"].get(key)
            if current is not None and current["updated_at"] > c["created_at"]:
                continue
            nv = c.get("new_value")
            row = {
                "track_id": c["track_id"],
                "field_id": c["field_id"],
                "option_ids": (nv or {}).get("option_ids") or [],
                "rating": (nv or {}).get("rating"),
                "text_value": (nv or {}).get("text"),
                "state": "confirmed",
                "source": c.get("source", "user"),
                "updated_at": c["created_at"],
                "device_id": device_id,
                "deleted_at": c["created_at"] if nv is None else None,
            }
            self._write("track_values", row, rev)
        for table in ("fields", "field_options", "rules", "saved_views", "settings"):
            for row in body.get(table, []):
                key = self._key(table, row)
                current = self.tables[table].get(key)
                if current is None or current["updated_at"] <= row["updated_at"]:
                    self._write(table, row, rev)
        return httpx.Response(200, json={"accepted_changes": accepted, "rev": rev})


def make_api(worker: FakeWorker, token: str = ADMIN):
    from djtag.api import Api

    return Api("https://fake.local", token, transport=httpx.MockTransport(worker.handler))
