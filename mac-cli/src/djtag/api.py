"""Client for the `mytags-api` Worker (docs/api.md)."""

from __future__ import annotations

import time
from collections.abc import Iterable, Iterator, Sequence
from pathlib import Path
from typing import Any

import httpx

SYNCED_TABLES = ("tracks", "fields", "field_options", "track_values", "rules", "saved_views", "settings")
ADMIN_TABLES = (*SYNCED_TABLES, "changes", "apply_runs")


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(f"{status} {code}: {message}")
        self.status = status
        self.code = code
        self.message = message


class Api:
    def __init__(
        self,
        base_url: str,
        token: str | None,
        *,
        timeout: float = 60,
        transport: httpx.BaseTransport | None = None,
    ):
        if not base_url:
            raise ApiError(
                0, "not_configured", "adresse de l'API inconnue : lancer `djtag login --api <url>`"
            )
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        self.client = httpx.Client(
            base_url=base_url.rstrip("/"), headers=headers, timeout=timeout, transport=transport
        )

    def close(self) -> None:
        self.client.close()

    def __enter__(self) -> Api:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # -- transport ----------------------------------------------------------------------------

    def _request(self, method: str, path: str, *, retries: int = 3, **kwargs: Any) -> httpx.Response:
        delay = 1.0
        for attempt in range(retries + 1):
            try:
                response = self.client.request(method, path, **kwargs)
            except httpx.TransportError as exc:
                if attempt == retries:
                    raise ApiError(0, "network", str(exc)) from exc
            else:
                if response.status_code < 500 or attempt == retries:
                    return self._check(response)
            time.sleep(delay)
            delay *= 2
        raise AssertionError("unreachable")

    @staticmethod
    def _check(response: httpx.Response) -> httpx.Response:
        if response.status_code >= 400:
            try:
                body = response.json()
                code, message = body.get("error", "error"), body.get("message", response.text)
            except ValueError:
                code, message = "error", response.text
            raise ApiError(response.status_code, code, message)
        return response

    def _json(self, method: str, path: str, body: Any | None = None) -> Any:
        response = self._request(method, path, json=body) if body is not None else self._request(method, path)
        return response.json() if response.content else None

    # -- identity -----------------------------------------------------------------------------

    def health(self) -> dict[str, Any]:
        return self._json("GET", "/v1/health")

    def me(self) -> dict[str, Any]:
        return self._json("GET", "/v1/me")

    # -- sync ---------------------------------------------------------------------------------

    def pull(self, cursors: dict[str, dict[str, int]], limit: int = 1000) -> dict[str, Any]:
        return self._json("POST", "/v1/sync/pull", {"cursors": cursors, "limit": limit})

    def pull_all(self, tables: Sequence[str] = ADMIN_TABLES) -> dict[str, list[dict[str, Any]]]:
        """Every row of the given tables (soft-deleted rows included)."""
        cursors = {t: {"rev": 0, "rowid": 0} for t in tables}
        rows: dict[str, list[dict[str, Any]]] = {t: [] for t in tables}
        pending = set(tables)
        while pending:
            result = self.pull({t: cursors[t] for t in pending})
            for table, page in result["tables"].items():
                rows[table].extend(page["rows"])
                cursors[table] = page["cursor"]
                if not page["has_more"]:
                    pending.discard(table)
        return rows

    def push(
        self, changes: Sequence[dict[str, Any]] = (), **config_rows: Sequence[dict[str, Any]]
    ) -> dict[str, Any]:
        accepted: list[str] = []
        result: dict[str, Any] = {}
        changes = list(changes)
        for batch in _batches(changes, 500) if changes else [[]]:
            body: dict[str, Any] = {"device_id": "mac", "changes": batch}
            if not accepted:
                body.update({k: list(v) for k, v in config_rows.items()})
            result = self._json("POST", "/v1/sync/push", body)
            accepted.extend(result.get("accepted_changes", []))
        result["accepted_changes"] = accepted
        return result

    # -- admin --------------------------------------------------------------------------------

    def upsert_tracks(self, tracks: Sequence[dict[str, Any]]) -> None:
        for batch in _batches(tracks, 200):
            self._json("POST", "/v1/admin/tracks", {"tracks": batch})

    def patch_tracks(self, patches: Sequence[dict[str, Any]]) -> None:
        for batch in _batches(patches, 500):
            self._json("POST", "/v1/admin/tracks/patch", {"patches": batch})

    def mark_changes(
        self, track_ids: Sequence[str], status: str, apply_run_id: str | None, from_status: str = "sent"
    ) -> None:
        for batch in _batches(track_ids, 500):
            body = {
                "track_ids": batch,
                "status": status,
                "apply_run_id": apply_run_id,
                "from_status": from_status,
            }
            self._json("POST", "/v1/admin/changes/mark", body)

    def upsert_apply_run(self, run: dict[str, Any]) -> None:
        self._json("POST", "/v1/admin/apply-runs", {"run": run})

    def create_device(self, name: str) -> dict[str, Any]:
        return self._json("POST", "/v1/admin/devices", {"name": name})

    def list_devices(self) -> list[dict[str, Any]]:
        result = self._json("GET", "/v1/admin/devices")
        return result.get("devices", result) if isinstance(result, dict) else result

    def revoke_device(self, device_id: str) -> None:
        self._json("DELETE", f"/v1/admin/devices/{device_id}")

    def reset_config(self, config: dict[str, Any]) -> None:
        self._json("POST", "/v1/admin/config/reset", {"config": config})

    # -- blobs --------------------------------------------------------------------------------

    def put_blob(self, key: str, source: Path | bytes, content_type: str) -> None:
        data = source.read_bytes() if isinstance(source, Path) else source
        self._request("PUT", f"/v1/admin/blobs/{key}", content=data, headers={"Content-Type": content_type})

    def head_blob(self, key: str) -> int | None:
        try:
            response = self._request("HEAD", f"/v1/admin/blobs/{key}")
        except ApiError as exc:
            if exc.status == 404:
                return None
            raise
        length = response.headers.get("content-length")
        return int(length) if length is not None else 0

    def delete_blob(self, key: str) -> None:
        try:
            self._request("DELETE", f"/v1/admin/blobs/{key}")
        except ApiError as exc:
            if exc.status != 404:
                raise


def _batches(items: Iterable[Any], size: int) -> Iterator[list[Any]]:
    batch: list[Any] = []
    for item in items:
        batch.append(item)
        if len(batch) == size:
            yield batch
            batch = []
    if batch:
        yield batch
