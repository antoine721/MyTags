"""`djtag doctor`: tools, configuration, cloud access, disk space and Serato state."""

from __future__ import annotations

import os
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

from . import audio, serato
from . import fingerprint as fp
from .api import Api, ApiError
from .settings import Settings, admin_token, config_path, work_dir


@dataclass
class Check:
    name: str
    ok: bool
    detail: str
    blocking: bool = True


def run_doctor(settings: Settings) -> list[Check]:
    checks: list[Check] = []
    checks.append(Check("Python", sys.version_info >= (3, 12), sys.version.split()[0]))
    has_ffmpeg = audio.ffmpeg_available()
    encoder = audio.pick_encoder("auto") if has_ffmpeg else "-"
    checks.append(Check("ffmpeg", has_ffmpeg, f"encodeur {encoder}" if has_ffmpeg else "brew install ffmpeg"))
    checks.append(
        Check("fpcalc (Chromaprint)", fp.available(), "ok" if fp.available() else "brew install chromaprint")
    )
    cfg = config_path()
    checks.append(Check("Configuration", cfg.exists(), str(cfg) if cfg.exists() else "lancer `djtag init`"))
    for folder in settings.music_folders:
        checks.append(_folder_check(folder.expanduser()))
    checks.append(
        Check(
            "Propriétaire POPM",
            bool(settings.popm_email),
            settings.popm_email or "inconnu : voir l'audit (notes non écrites)",
            blocking=False,
        )
    )
    token = admin_token()
    if not settings.api_url or not token:
        checks.append(
            Check("Cloud", False, "lancer `djtag login --api <url>` (normal avant la mise en place du cloud)")
        )
    else:
        try:
            with Api(settings.api_url, token, timeout=15) as api:
                me = api.me()
            ok = me.get("role") == "admin"
            checks.append(Check("Cloud", ok, settings.api_url if ok else "jeton non administrateur"))
        except ApiError as exc:
            checks.append(Check("Cloud", False, exc.message))
    home = work_dir()
    home.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(home).free
    checks.append(Check("Espace disque (~/DJTag)", free > 5e9, f"{free / 1e9:.0f} Go libres"))
    running = serato.is_running()
    checks.append(
        Check(
            "Serato DJ fermé",
            not running,
            "ouvert : le fermer avant apply" if running else "fermé",
            blocking=False,
        )
    )
    leftovers = _leftover_temp_files(settings)
    checks.append(
        Check(
            "Fichiers temporaires",
            not leftovers,
            f"{len(leftovers)} à supprimer" if leftovers else "aucun",
            blocking=False,
        )
    )
    return checks


def _leftover_temp_files(settings: Settings) -> list[Path]:
    found: list[Path] = []
    for folder in settings.music_folders:
        root = folder.expanduser()
        if root.exists():
            found.extend(root.rglob("*.djtag-tmp*"))
    return found


def _folder_check(folder: Path) -> Check:
    if not folder.exists():
        return Check(f"Dossier {folder}", False, "introuvable (disque débranché ?)")
    try:
        next(os.scandir(folder), None)
    except PermissionError:
        # macOS privacy: without this, every scan silently finds nothing.
        return Check(
            f"Dossier {folder}",
            False,
            "lecture refusée : Réglages Système › Confidentialité et sécurité › Fichiers et dossiers "
            "(ou Accès complet au disque) › autoriser Terminal",
        )
    return Check(f"Dossier {folder}", True, "lisible")
