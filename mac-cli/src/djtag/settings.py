"""User configuration (~/.config/djtag/config.toml), working folders and secrets (Keychain)."""

from __future__ import annotations

import os
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .tags import TagOptions
from .tags.flac import FlacKeys

KEYRING_SERVICE = "djtag"
KEYRING_ADMIN_TOKEN = "admin-token"
DEFAULT_EXCLUDES = ("_Serato_", "_Serato_Backup", ".Trashes", ".Spotlight-V100")


def config_path() -> Path:
    return Path(os.environ.get("DJTAG_CONFIG", "~/.config/djtag/config.toml")).expanduser()


def work_dir() -> Path:
    return Path(os.environ.get("DJTAG_HOME", "~/DJTag")).expanduser()


@dataclass
class Settings:
    music_folders: list[Path] = field(default_factory=lambda: [Path("~/Music").expanduser()])
    exclude: list[str] = field(default_factory=lambda: list(DEFAULT_EXCLUDES))
    api_url: str = ""
    aac_bitrate: str = "96k"
    loudness_lufs: float = -14.0
    encoder: str = "auto"  # auto | aac_at | aac
    workers: int = 0  # 0 = one per CPU core
    popm_email: str | None = None
    comm_language: str = "eng"
    wav_id3_chunk: str = "id3 "
    mp4_rating_key: str = "----:com.apple.iTunes:RATE"
    generic_rating_scale: int = 100
    flac_keys: FlacKeys = field(default_factory=FlacKeys)
    keep_backups: int = 10

    @property
    def tag_options(self) -> TagOptions:
        return TagOptions(
            popm_email=self.popm_email or None,
            comm_language=self.comm_language,
            wav_id3_chunk=self.wav_id3_chunk,
            mp4_rating_key=self.mp4_rating_key,
            generic_rating_scale=self.generic_rating_scale,
            flac_keys=self.flac_keys,
        )

    @property
    def backups_dir(self) -> Path:
        return work_dir() / "backups"

    @property
    def reports_dir(self) -> Path:
        return work_dir() / "reports"

    @property
    def logs_dir(self) -> Path:
        return work_dir() / "logs"

    @property
    def cache_dir(self) -> Path:
        return work_dir() / "cache"

    def ensure_dirs(self) -> None:
        for d in (self.backups_dir, self.reports_dir, self.logs_dir, self.cache_dir):
            d.mkdir(parents=True, exist_ok=True)


def _canonical(folder: Path) -> Path:
    """One spelling per folder (symlinks, `..`), so a file always has the same path in the catalogue."""
    try:
        return folder.expanduser().resolve()
    except OSError:
        return folder.expanduser()


def load(path: Path | None = None) -> Settings:
    path = path or config_path()
    s = Settings()
    if not path.exists():
        return s
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    lib = data.get("library", {})
    if "folders" in lib:
        s.music_folders = [_canonical(Path(p)) for p in lib["folders"]]
    s.exclude = list(lib.get("exclude", s.exclude))
    s.api_url = str(data.get("api", {}).get("url", s.api_url)).rstrip("/")
    audio = data.get("audio", {})
    s.aac_bitrate = str(audio.get("bitrate", s.aac_bitrate))
    s.loudness_lufs = float(audio.get("loudness_lufs", s.loudness_lufs))
    s.encoder = str(audio.get("encoder", s.encoder))
    s.workers = int(data.get("import", {}).get("workers", s.workers))
    tags = data.get("tags", {})
    s.popm_email = tags.get("popm_email") or None
    s.comm_language = str(tags.get("comm_language", s.comm_language))
    s.wav_id3_chunk = str(tags.get("wav_id3_chunk", s.wav_id3_chunk))
    s.mp4_rating_key = str(tags.get("mp4_rating_key", s.mp4_rating_key))
    s.generic_rating_scale = int(tags.get("generic_rating_scale", s.generic_rating_scale))
    flac = tags.get("flac", {})
    s.flac_keys = FlacKeys(
        genre=flac.get("genre", "GENRE"),
        grouping=flac.get("grouping", "GROUPING"),
        comment=flac.get("comment", "COMMENT"),
        rating=flac.get("rating", "RATING"),
    )
    s.keep_backups = int(data.get("backups", {}).get("keep", s.keep_backups))
    return s


def _toml_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, (list, tuple)):
        return "[" + ", ".join(_toml_value(v) for v in value) + "]"
    text = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{text}"'


def save(s: Settings, path: Path | None = None) -> Path:
    path = path or config_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    sections: dict[str, dict[str, Any]] = {
        "library": {"folders": [str(p) for p in s.music_folders], "exclude": s.exclude},
        "api": {"url": s.api_url},
        "audio": {"bitrate": s.aac_bitrate, "loudness_lufs": s.loudness_lufs, "encoder": s.encoder},
        "import": {"workers": s.workers},
        "tags": {
            "popm_email": s.popm_email or "",
            "comm_language": s.comm_language,
            "wav_id3_chunk": s.wav_id3_chunk,
            "mp4_rating_key": s.mp4_rating_key,
            "generic_rating_scale": s.generic_rating_scale,
        },
        "tags.flac": {
            "genre": s.flac_keys.genre,
            "grouping": s.flac_keys.grouping,
            "comment": s.flac_keys.comment,
            "rating": s.flac_keys.rating,
        },
        "backups": {"keep": s.keep_backups},
    }
    lines = ["# djtag configuration — see docs/outils.md", ""]
    for name, values in sections.items():
        lines.append(f"[{name}]")
        lines.extend(f"{k} = {_toml_value(v)}" for k, v in values.items())
        lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


# -- secrets --------------------------------------------------------------------------------------


def admin_token() -> str | None:
    env = os.environ.get("DJTAG_ADMIN_TOKEN")
    if env:
        return env
    try:
        import keyring

        return keyring.get_password(KEYRING_SERVICE, KEYRING_ADMIN_TOKEN)
    except Exception:
        return None


def store_admin_token(token: str) -> None:
    import keyring

    keyring.set_password(KEYRING_SERVICE, KEYRING_ADMIN_TOKEN, token)
