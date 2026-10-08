"""`djtag audit`: read-only analysis of the library (spec section 12).

The detailed report (with paths and titles) stays in ~/DJTag/reports. Only a numeric
summary without track titles is meant for docs/audit.md.
"""

from __future__ import annotations

import json
import re
from collections import Counter, defaultdict
from collections.abc import Callable, Iterable
from concurrent.futures import ProcessPoolExecutor
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any

from . import fingerprint as fp
from .info import read_info
from .model.comment import NON_CONFORME, parse_comment
from .model.config import TagConfig
from .model.text import primary_artist
from .model.values import match_text
from .scan import ScannedFile, now_iso
from .tags import TagOptions, read_managed

MIK_COMMENT = re.compile(r"^\s*(\d{1,2}[AB]|[A-G][b#]?m?)\s*(-|/)\s*(energy\s*\d+|\d+)", re.IGNORECASE)
DURATION_BUCKETS = [
    (0, 120, "< 2 min"),
    (120, 240, "2–4 min"),
    (240, 360, "4–6 min"),
    (360, 480, "6–8 min"),
    (480, 10**9, "> 8 min"),
]


@dataclass
class FileRecord:
    path: str
    format: str
    size: int
    duration_ms: int | None = None
    bitrate: int | None = None
    title: str | None = None
    artist: str | None = None
    genre: str | None = None
    grouping: str | None = None
    comment: str | None = None
    rating: int | None = None
    rating_raw: int | None = None
    issues: list[str] = field(default_factory=list)
    details: dict[str, Any] = field(default_factory=dict)
    fingerprint: str | None = None
    error: str | None = None


def inspect_file(args: tuple[str, str, int, TagOptions, bool]) -> FileRecord:
    path, fmt, size, opts, with_fingerprint = args
    rec = FileRecord(path, fmt, size)
    try:
        info = read_info(Path(path), fmt)
        rec.duration_ms, rec.bitrate, rec.title, rec.artist = (
            info.duration_ms,
            info.bitrate,
            info.title,
            info.artist,
        )
        tags = read_managed(path, fmt, opts)
        rec.genre, rec.grouping, rec.comment = tags.genre, tags.grouping, tags.comment
        rec.rating, rec.rating_raw, rec.issues, rec.details = (
            tags.rating,
            tags.rating_raw,
            tags.issues,
            tags.details,
        )
        if with_fingerprint:
            f = fp.compute(Path(path))
            rec.fingerprint = f.digest if f else None
    except Exception as exc:  # unreadable files are part of the report
        rec.error = f"{type(exc).__name__}: {exc}"
    return rec


def run_audit(
    files: list[ScannedFile],
    config: TagConfig,
    opts: TagOptions,
    *,
    workers: int,
    with_fingerprints: bool,
    progress: Callable[[int, int], None] | None = None,
) -> list[FileRecord]:
    jobs = [(str(f.path), f.format, f.size, opts, with_fingerprints) for f in files]
    records: list[FileRecord] = []
    if workers <= 1:
        for i, job in enumerate(jobs, 1):
            records.append(inspect_file(job))
            if progress:
                progress(i, len(jobs))
        return records
    with ProcessPoolExecutor(max_workers=workers) as pool:
        for i, rec in enumerate(pool.map(inspect_file, jobs, chunksize=16), 1):
            records.append(rec)
            if progress:
                progress(i, len(jobs))
    return records


def summarize(records: list[FileRecord], config: TagConfig, music_folders: Iterable[Path]) -> dict[str, Any]:
    ok = [r for r in records if r.error is None]
    by_format = Counter(r.format for r in records)
    size_by_format: Counter[str] = Counter()
    for r in records:
        size_by_format[r.format] += r.size
    durations = Counter()
    total_seconds = 0.0
    for r in ok:
        seconds = (r.duration_ms or 0) / 1000
        total_seconds += seconds
        for low, high, label in DURATION_BUCKETS:
            if low <= seconds < high:
                durations[label] += 1
                break

    genres = Counter((r.genre or "").strip() for r in ok)
    groupings = Counter((r.grouping or "").strip() for r in ok)
    comments = Counter((r.comment or "").strip() for r in ok)
    comment_status = Counter()
    non_conforming: list[str] = []
    mik_like = 0
    for r in ok:
        status = parse_comment(r.comment, config).status
        comment_status[status] += 1
        if status == NON_CONFORME and r.comment and len(non_conforming) < 30:
            non_conforming.append(r.comment)
        if r.comment and MIK_COMMENT.match(r.comment):
            mik_like += 1

    genre_field = config.field_for_tag("GENRE")
    grouping_field = config.field_for_tag("GROUPING")
    unknown_genres = Counter(
        g for g in genres.elements() if g and genre_field and match_text(genre_field, g, config) is None
    )
    unknown_groupings = Counter(
        g
        for g in groupings.elements()
        if g and grouping_field and match_text(grouping_field, g, config) is None
    )

    id3_versions = Counter(
        r.details.get("id3_version") or "aucun" for r in ok if r.format in ("mp3", "wav", "aiff")
    )
    popm_owners = Counter(e for r in ok for e in r.details.get("popm_emails", []))
    popm_values = Counter(
        r.rating_raw for r in ok if r.format in ("mp3", "wav", "aiff") and r.rating_raw is not None
    )
    comm_frames = Counter(len(r.details.get("comm", [])) for r in ok if r.format in ("mp3", "wav", "aiff"))
    mp4_keys = Counter(k for r in ok for k in r.details.get("freeform_keys", []))
    flac_keys = Counter(k for r in ok for k in r.details.get("vorbis_keys", []))
    rating_like_mp4 = {k: v for k, v in mp4_keys.items() if "rat" in k.lower()}
    rating_like_flac = {k: v for k, v in flac_keys.items() if "RAT" in k}
    generic_rating_values = Counter(
        r.rating_raw for r in ok if r.format in ("m4a", "flac") and r.rating_raw is not None
    )

    serato_presence: dict[str, Counter[str]] = defaultdict(Counter)
    for r in ok:
        markers: list[str] = []
        if r.format in ("mp3", "wav", "aiff"):
            markers = [d for d in r.details.get("geob", []) if d.startswith("Serato")]
        elif r.format == "m4a":
            markers = [k for k in r.details.get("freeform_keys", []) if "com.serato" in k]
        elif r.format == "flac":
            markers = [k for k in r.details.get("vorbis_keys", []) if k.startswith("SERATO")]
        serato_presence[r.format]["avec données Serato" if markers else "sans données Serato"] += 1
        for m in markers:
            serato_presence[r.format][m] += 1

    issues = Counter(i for r in ok for i in r.issues)
    errors = [r for r in records if r.error is not None]

    duplicates: list[list[str]] = []
    if any(r.fingerprint for r in ok):
        groups: dict[str, list[FileRecord]] = defaultdict(list)
        for r in ok:
            if r.fingerprint:
                groups[r.fingerprint].append(r)
        duplicates = [[r.path for r in g] for g in groups.values() if len(g) > 1]
    else:
        groups2: dict[tuple[str, str, int], list[FileRecord]] = defaultdict(list)
        for r in ok:
            if r.title and r.artist and r.duration_ms:
                groups2[(r.artist.lower(), r.title.lower(), r.duration_ms // 1000)].append(r)
        duplicates = [[r.path for r in g] for g in groups2.values() if len(g) > 1]

    artists = Counter(primary_artist(r.artist) for r in ok if r.artist)
    folders = Counter()
    roots = [p.expanduser() for p in music_folders]
    for r in records:
        path = Path(r.path)
        for root in roots:
            try:
                rel = path.relative_to(root)
            except ValueError:
                continue
            folders[rel.parts[0] if len(rel.parts) > 1 else "(racine)"] += 1
            break

    audio_bytes = total_seconds * 96_000 / 8 * 1.03
    cover_bytes = len(ok) * 60_000
    return {
        "generated_at": now_iso(),
        "files": len(records),
        "readable": len(ok),
        "unreadable": len(errors),
        "by_format": dict(by_format.most_common()),
        "size_bytes_by_format": dict(size_by_format.most_common()),
        "total_size_bytes": sum(size_by_format.values()),
        "durations": {label: durations[label] for _, _, label in DURATION_BUCKETS},
        "total_hours": round(total_seconds / 3600, 1),
        "genre": {
            "distinct": len(genres),
            "values": dict(genres.most_common()),
            "unknown": dict(unknown_genres.most_common()),
        },
        "grouping": {
            "distinct": len(groupings),
            "values": dict(groupings.most_common()),
            "unknown": dict(unknown_groupings.most_common()),
        },
        "comment": {
            "distinct": len(comments),
            "status": dict(comment_status),
            "top_values": dict(comments.most_common(40)),
            "non_conforming_examples": non_conforming,
            "mixed_in_key_like": mik_like,
        },
        "rating": {
            "popm_owners": dict(popm_owners.most_common()),
            "popm_values": {str(k): v for k, v in sorted(popm_values.items())},
            "mp4_rating_like_keys": rating_like_mp4,
            "flac_rating_like_keys": rating_like_flac,
            "m4a_flac_values": {str(k): v for k, v in sorted(generic_rating_values.items())},
        },
        "id3_versions": dict(id3_versions),
        "comm_frames_per_file": {str(k): v for k, v in sorted(comm_frames.items())},
        "mp4_freeform_keys": dict(mp4_keys.most_common()),
        "flac_keys": dict(flac_keys.most_common()),
        "serato": {fmt: dict(c) for fmt, c in serato_presence.items()},
        "issues": dict(issues.most_common()),
        "errors": [{"path": r.path, "error": r.error} for r in errors[:200]],
        "duplicates": duplicates[:200],
        "duplicate_groups": len(duplicates),
        "artists": len(artists),
        "top_artists_track_counts": sorted(artists.values(), reverse=True)[:20],
        "folders": dict(folders.most_common()),
        "estimate": {
            "cloud_gb": round((audio_bytes + cover_bytes) / 1e9, 1),
            "r2_monthly_usd": round(max(0.0, (audio_bytes + cover_bytes) / 1e9 - 10) * 0.015, 2),
            "import_hours_cpu": round(total_seconds / 40 / 3600, 1),
        },
    }


def render_markdown(summary: dict[str, Any], *, public: bool) -> str:
    """Markdown report. `public` omits paths, examples and folder names (for docs/audit.md)."""
    s = summary
    lines = [
        "# Audit de la bibliothèque",
        "",
        f"Généré le {s['generated_at']}.",
        "",
        "## Fichiers",
        "",
        f"- {s['files']} fichiers, dont {s['unreadable']} illisibles ; {s['total_hours']} h de musique ;"
        f" {s['total_size_bytes'] / 1e9:.1f} Go.",
        "",
        "| Format | Fichiers | Taille (Go) |",
        "| --- | --- | --- |",
    ]
    for fmt, count in s["by_format"].items():
        lines.append(f"| {fmt} | {count} | {s['size_bytes_by_format'].get(fmt, 0) / 1e9:.1f} |")
    lines += ["", "| Durée | Fichiers |", "| --- | --- |"]
    lines += [f"| {k} | {v} |" for k, v in s["durations"].items()]

    def table(title: str, values: dict[str, int], limit: int = 40) -> list[str]:
        out = ["", f"### {title}", "", "| Valeur | Morceaux |", "| --- | --- |"]
        for value, count in list(values.items())[:limit]:
            out.append(f"| {value or '(vide)'} | {count} |")
        return out

    lines += ["", "## GENRE"]
    lines += ["", f"{s['genre']['distinct']} valeurs distinctes."]
    lines += table("Valeurs", s["genre"]["values"])
    lines += table("Valeurs non reconnues par la configuration", s["genre"]["unknown"])
    lines += ["", "## GROUPING (Couleur)", "", f"{s['grouping']['distinct']} valeurs distinctes."]
    lines += table("Valeurs", s["grouping"]["values"])
    c = s["comment"]
    lines += [
        "",
        "## COMMENT",
        "",
        f"- Conformes : {c['status'].get('conforme', 0)} ; incomplets : {c['status'].get('incomplet', 0)} ;"
        f" non conformes : {c['status'].get('non_conforme', 0)}.",
        f"- COMMENT ressemblant à une notation Mixed In Key : {c['mixed_in_key_like']}.",
    ]
    lines += table("Valeurs les plus fréquentes", c["top_values"], 40)
    if not public and c["non_conforming_examples"]:
        lines += ["", "### Exemples non conformes", ""]
        lines += [f"- `{e}`" for e in c["non_conforming_examples"]]
    r = s["rating"]
    lines += ["", "## Note", "", "| Propriétaire POPM | Fichiers |", "| --- | --- |"]
    lines += [f"| {k or '(vide)'} | {v} |" for k, v in r["popm_owners"].items()] or ["| (aucun) | 0 |"]
    lines += ["", "| Valeur POPM | Fichiers |", "| --- | --- |"]
    lines += [f"| {k} | {v} |" for k, v in r["popm_values"].items()]
    lines += ["", f"- Clés M4A ressemblant à une note : {r['mp4_rating_like_keys'] or 'aucune'}"]
    lines += [f"- Clés FLAC ressemblant à une note : {r['flac_rating_like_keys'] or 'aucune'}"]
    lines += [f"- Valeurs de note M4A/FLAC : {r['m4a_flac_values'] or 'aucune'}"]
    lines += [
        "",
        "## ID3",
        "",
        f"- Versions : {s['id3_versions']}",
        f"- Cadres COMM par fichier : {s['comm_frames_per_file']}",
    ]
    lines += ["", "## Données Serato", ""]
    for fmt, counts in s["serato"].items():
        lines.append(f"- **{fmt}** : " + ", ".join(f"{k} {v}" for k, v in counts.items()))
    lines += ["", "## Anomalies", ""]
    lines += [f"- {k} : {v}" for k, v in s["issues"].items()] or ["- aucune"]
    lines += [
        "",
        f"- Groupes de doublons probables : {s['duplicate_groups']}",
        f"- Artistes (principaux) : {s['artists']}",
    ]
    if not public:
        lines += ["", "## Dossiers (premier niveau)", ""]
        lines += [f"- {k} : {v}" for k, v in s["folders"].items()]
        if s["errors"]:
            lines += ["", "## Fichiers illisibles", ""]
            lines += [f"- `{e['path']}` : {e['error']}" for e in s["errors"]]
        if s["duplicates"]:
            lines += ["", "## Doublons probables", ""]
            for group in s["duplicates"][:50]:
                lines.append("- " + " | ".join(f"`{p}`" for p in group))
    e = s["estimate"]
    lines += [
        "",
        "## Estimations",
        "",
        f"- Espace cloud (AAC 96 kbps + covers) : environ {e['cloud_gb']} Go, soit environ {e['r2_monthly_usd']} $ par mois sur R2.",
        f"- Conversion : environ {e['import_hours_cpu']} h de calcul sur un cœur (à diviser par le nombre de cœurs).",
        "",
    ]
    return "\n".join(lines)


def records_json(records: list[FileRecord]) -> str:
    return json.dumps([asdict(r) for r in records], ensure_ascii=False, indent=1)
