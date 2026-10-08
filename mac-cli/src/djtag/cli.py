"""`djtag` command line. Exit codes: 0 success, 1 error, 2 conflicts, 3 safety refusal."""

from __future__ import annotations

import os
from collections.abc import Callable
from pathlib import Path
from typing import Annotated, Any, NoReturn

import typer
from rich.progress import BarColumn, MofNCompleteColumn, Progress, TextColumn, TimeRemainingColumn
from rich.table import Table

from . import __version__
from . import settings as settings_mod
from .api import Api, ApiError
from .console import EXIT_CONFLICTS, EXIT_ERROR, EXIT_OK, EXIT_REFUSED, console, emit_json, err

app = typer.Typer(
    no_args_is_help=True,
    add_completion=False,
    help="MyTags — outil Mac : audit, import, aperçu, application.",
)
devices_app = typer.Typer(no_args_is_help=True, help="Appareils connectés (iPhone).")
config_app = typer.Typer(no_args_is_help=True, help="Réglages de djtag (~/.config/djtag/config.toml).")
app.add_typer(devices_app, name="devices")
app.add_typer(config_app, name="config")

JsonOpt = Annotated[bool, typer.Option("--json", help="Sortie JSON lisible par une IA.")]


def main() -> None:
    app()


def _settings() -> settings_mod.Settings:
    return settings_mod.load()


def _api(s: settings_mod.Settings) -> Api:
    return Api(s.api_url, settings_mod.admin_token())


def _workers(s: settings_mod.Settings) -> int:
    return s.workers or max(1, (os.cpu_count() or 2) - 1)


def _fail(message: str, code: int = EXIT_ERROR, as_json: bool = False) -> NoReturn:
    if as_json:
        emit_json({"ok": False, "error": message, "exit_code": code})
    else:
        err.print(f"[bold red]✗[/] {message}")
    raise typer.Exit(code)


def _progress() -> tuple[Progress, Callable[[str, int, int], None]]:
    progress = Progress(
        TextColumn("{task.description}"),
        BarColumn(),
        MofNCompleteColumn(),
        TimeRemainingColumn(),
        console=err,
        transient=True,
    )
    tasks: dict[str, Any] = {}

    def update(label: str, done: int, total: int) -> None:
        if label not in tasks:
            tasks[label] = progress.add_task(label, total=total)
        progress.update(tasks[label], completed=done, total=total)

    return progress, update


@app.command()
def version() -> None:
    """Version de djtag."""
    console.print(__version__)


@app.command()
def init(
    music: Annotated[
        list[Path] | None, typer.Option("--music", help="Dossier de musique (répétable).")
    ] = None,
) -> None:
    """Crée la configuration et le dossier de travail ~/DJTag."""
    s = _settings()
    if music:
        s.music_folders = [m.expanduser().resolve() for m in music]
    path = settings_mod.save(s)
    s.ensure_dirs()
    console.print(f"Configuration : {path}")
    console.print("Dossiers de musique : " + ", ".join(str(p) for p in s.music_folders))


@app.command()
def login(
    api_url: Annotated[
        str, typer.Option("--api", help="Adresse du Worker, ex. https://mytags-api.<compte>.workers.dev")
    ],
    token: Annotated[str | None, typer.Option(help="Jeton administrateur (sinon demandé).")] = None,
) -> None:
    """Enregistre l'adresse de l'API et le jeton administrateur (trousseau macOS)."""
    token = token or typer.prompt("Jeton administrateur", hide_input=True)
    try:
        with Api(api_url, token, timeout=20) as api:
            me = api.me()
            if me.get("role") != "admin":
                _fail("ce jeton n'est pas le jeton administrateur")
            rows = api.pull_all(("fields",))
            if not [r for r in rows["fields"] if not r.get("deleted_at")]:
                from .model.config import load_default_config_json

                api.reset_config(load_default_config_json())
                console.print("Configuration de départ des champs chargée dans le cloud.")
    except ApiError as exc:
        _fail(f"connexion impossible : {exc.message}")
    settings_mod.store_admin_token(token)
    s = _settings()
    s.api_url = api_url.rstrip("/")
    settings_mod.save(s)
    console.print("[green]✓[/] Connecté. Prochaine étape : `djtag pair` pour connecter l'iPhone.")


@app.command()
def doctor(as_json: JsonOpt = False) -> None:
    """Vérifie les outils, le cloud, l'espace disque et que Serato est fermé."""
    from .doctor import run_doctor

    checks = run_doctor(_settings())
    ok = all(c.ok for c in checks if c.blocking)
    if as_json:
        emit_json({"ok": ok, "checks": [c.__dict__ for c in checks]})
    else:
        table = Table(show_header=False, box=None)
        for c in checks:
            mark = "[green]✓[/]" if c.ok else ("[red]✗[/]" if c.blocking else "[yellow]![/]")
            table.add_row(mark, c.name, c.detail)
        console.print(table)
    raise typer.Exit(EXIT_OK if ok else EXIT_ERROR)


@app.command()
def audit(
    as_json: JsonOpt = False,
    fingerprints: Annotated[
        bool, typer.Option(help="Calculer les empreintes pour trouver les doublons (plus lent).")
    ] = False,
    summary: Annotated[
        Path | None, typer.Option(help="Écrire aussi la synthèse publique (ex. docs/audit.md).")
    ] = None,
    limit: Annotated[int | None, typer.Option(help="N'analyser que N fichiers.")] = None,
) -> None:
    """Analyse la bibliothèque en lecture seule et écrit un rapport dans ~/DJTag/reports."""
    import json

    from .audit import records_json, render_markdown, run_audit, summarize
    from .model.config import TagConfig
    from .scan import scan

    s = _settings()
    s.ensure_dirs()
    config = TagConfig.default()
    if s.api_url and settings_mod.admin_token():
        try:
            from .cloud import CloudState

            with _api(s) as api:
                rows = api.pull_all(("fields", "field_options", "rules", "settings"))
            config = CloudState.from_rows(rows).config
        except ApiError:
            pass
    files = list(scan(s.music_folders, s.exclude))
    if limit:
        files = files[:limit]
    progress, update = _progress()
    with progress:
        records = run_audit(
            files,
            config,
            s.tag_options,
            workers=_workers(s),
            with_fingerprints=fingerprints,
            progress=lambda d, t: update("Analyse", d, t),
        )
    result = summarize(records, config, s.music_folders)
    stamp = result["generated_at"].replace(":", "").replace("-", "")[:15]
    md = s.reports_dir / f"audit-{stamp}.md"
    md.write_text(render_markdown(result, public=False), encoding="utf-8")
    (s.reports_dir / f"audit-{stamp}.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8"
    )
    (s.reports_dir / f"audit-{stamp}-files.json").write_text(records_json(records), encoding="utf-8")
    if summary:
        summary.write_text(render_markdown(result, public=True), encoding="utf-8")
    if as_json:
        emit_json({"ok": True, "report": str(md), "summary": result})
        return
    console.print(f"{result['files']} fichiers analysés ({result['unreadable']} illisibles). Rapport : {md}")
    c = result["comment"]["status"]
    console.print(
        f"COMMENT : {c.get('conforme', 0)} conformes, {c.get('incomplet', 0)} incomplets, {c.get('non_conforme', 0)} non conformes."
    )
    owners = result["rating"]["popm_owners"]
    if owners:
        top = next(iter(owners))
        console.print(f"Propriétaire POPM le plus fréquent : {top!r} ({owners[top]} fichiers).")
        if not s.popm_email:
            console.print(f"  → pour écrire les notes : djtag config set tags.popm_email '{top}'")


@app.command("import")
def import_cmd(
    as_json: JsonOpt = False,
    limit: Annotated[int | None, typer.Option(help="N'importer que N fichiers (essai).")] = None,
    allow_mass_delete: Annotated[
        bool, typer.Option(help="Accepter de marquer beaucoup de fichiers supprimés.")
    ] = False,
) -> None:
    """Importe les nouveautés dans le cloud : tags, empreinte, audio d'écoute, covers, forme d'onde."""
    from .cloud import CloudState
    from .importer import ImportContext, ImportRefused, run_import
    from .state import ImportState

    s = _settings()
    s.ensure_dirs()
    state = ImportState(s.cache_dir / "state.sqlite")
    try:
        with _api(s) as api:
            cloud = CloudState.load(api)
            progress, update = _progress()
            ctx = ImportContext(s, api, cloud, state, _workers(s), update, limit, allow_mass_delete)
            with progress:
                report = run_import(ctx)
    except ImportRefused as exc:
        _fail(str(exc), EXIT_REFUSED, as_json)
    except ApiError as exc:
        _fail(f"cloud : {exc.message}", EXIT_ERROR, as_json)
    finally:
        state.close()
    if as_json:
        emit_json({"ok": not report.errors, "report": report.to_json()})
    else:
        console.print(
            f"{report.scanned} fichiers : {report.new} nouveaux, {report.updated} mis à jour, {report.moved} déplacés, "
            f"{report.restored} retrouvés, {report.deleted} supprimés, {report.unchanged} inchangés."
        )
        for folder in report.skipped_missing_folders:
            console.print(f"[yellow]![/] Dossier introuvable, ignoré : {folder}")
        for c in report.conflicts:
            console.print(f"[yellow]Conflit[/] {c['path']} ({c['tags']})")
        for e in report.errors:
            console.print(f"[red]Erreur[/] {e['path']} : {e['error']}")
    raise typer.Exit(EXIT_ERROR if report.errors else EXIT_OK)


@app.command()
def status(as_json: JsonOpt = False) -> None:
    """Résume les morceaux à appliquer, les conflits et les dernières applications."""
    from .cloud import CloudState
    from .plan import build_plan

    s = _settings()
    try:
        with _api(s) as api:
            cloud = CloudState.load(api)
    except ApiError as exc:
        _fail(f"cloud : {exc.message}", EXIT_ERROR, as_json)
    plan = build_plan(cloud, s)
    live = cloud.live_tracks()
    errors = [t for t in live if t.get("apply_status") == "erreur"]
    pending = sum(1 for c in cloud.changes if c.get("status") == "sent")
    runs = sorted(cloud.apply_runs, key=lambda r: r.get("started_at") or "", reverse=True)[:5]
    data = {
        "tracks": len(live),
        "to_apply": len(plan.items),
        "totals": plan.totals,
        "conflicts": len(plan.conflicts),
        "errors": len(errors),
        "changes_waiting": pending,
        "last_runs": runs,
        "warnings": plan.warnings,
    }
    if as_json:
        emit_json(data)
        return
    console.print(
        f"{data['tracks']} morceaux ; {data['to_apply']} à appliquer ; {data['conflicts']} conflits ; {data['errors']} erreurs."
    )
    for k, v in plan.totals.items():
        console.print(f"  {k} : {v}")
    for w in plan.warnings:
        console.print(f"[yellow]![/] {w}")
    for r in runs:
        console.print(
            f"  {r.get('started_at')} {r.get('mode')} — {r.get('tracks_written')} écrits, {r.get('conflicts')} conflits, "
            f"{r.get('errors')} erreurs (id {r.get('id')})"
        )


@app.command()
def diff(
    as_json: JsonOpt = False,
    markdown: Annotated[Path | None, typer.Option(help="Écrire l'aperçu en Markdown.")] = None,
    limit: Annotated[int | None, typer.Option()] = None,
    track: Annotated[list[str] | None, typer.Option(help="Identifiant de morceau (répétable).")] = None,
) -> None:
    """Montre l'avant / après de chaque morceau à appliquer."""
    from .cloud import CloudState
    from .plan import TAG_LABELS, build_plan, plan_markdown

    s = _settings()
    try:
        with _api(s) as api:
            cloud = CloudState.load(api)
    except ApiError as exc:
        _fail(f"cloud : {exc.message}", EXIT_ERROR, as_json)
    plan = build_plan(cloud, s, track_ids=track, limit=limit)
    if markdown:
        markdown.write_text(plan_markdown(plan), encoding="utf-8")
    if as_json:
        emit_json(plan.to_json())
        return
    table = Table("Morceau", "Tag", "Fichier", "Nouveau")
    for item in plan.items:
        first = True
        for c in item.changes:
            name = f"{item.artist or '?'} — {item.title or '?'}" if first else ""
            table.add_row(name, TAG_LABELS[c.tag], str(c.current or "(vide)"), str(c.new or "(vide)"))
            first = False
    console.print(table)
    console.print(
        f"{len(plan.items)} morceaux à appliquer : " + ", ".join(f"{k} {v}" for k, v in plan.totals.items())
    )
    for c in plan.conflicts:
        console.print(f"[yellow]Conflit[/] {c['path']} : {c['message']}")
    for w in plan.warnings:
        console.print(f"[yellow]![/] {w}")


@app.command()
def apply(
    as_json: JsonOpt = False,
    yes: Annotated[bool, typer.Option("--yes", help="Ne pas demander de confirmation.")] = False,
    dry_run: Annotated[bool, typer.Option("--dry-run", help="Tout faire sauf écrire.")] = False,
    limit: Annotated[int | None, typer.Option()] = None,
    track: Annotated[list[str] | None, typer.Option(help="Identifiant de morceau (répétable).")] = None,
    copy_to: Annotated[
        Path | None,
        typer.Option(
            "--copy-to",
            help="Essai (règle R4) : écrire sur des copies dans ce dossier, hors de la bibliothèque. "
            "Rien ne change dans la bibliothèque ni dans le cloud.",
        ),
    ] = None,
) -> None:
    """Écrit les tags dans les fichiers, avec sauvegarde et vérification."""
    from .apply import SERATO_RESCAN, ApplyContext, ApplyRefused, run_apply, run_trial
    from .cloud import CloudState
    from .plan import build_plan
    from .state import ImportState

    s = _settings()
    state = ImportState(s.cache_dir / "state.sqlite")
    try:
        with _api(s) as api:
            cloud = CloudState.load(api)
            plan = build_plan(cloud, s, track_ids=track, limit=limit)
            if not plan.items:
                if as_json:
                    emit_json(
                        {
                            "ok": True,
                            "written": 0,
                            "conflicts": len(plan.conflicts),
                            "message": "rien à appliquer",
                        }
                    )
                else:
                    console.print("Rien à appliquer.")
                raise typer.Exit(EXIT_CONFLICTS if plan.conflicts else EXIT_OK)
            if copy_to is not None:
                progress, update = _progress()
                ctx = ApplyContext(s, api, cloud, state, plan, False, lambda d, t: update("Copies", d, t))
                with progress:
                    trial = run_trial(ctx, copy_to)
                _trial_summary(trial, as_json)
            if not yes and not dry_run:
                console.print(
                    f"{len(plan.items)} morceaux vont être écrits : "
                    + ", ".join(f"{k} {v}" for k, v in plan.totals.items())
                )
                if not typer.confirm("Appliquer ?", default=False):
                    raise typer.Exit(EXIT_OK)
            progress, update = _progress()
            ctx = ApplyContext(s, api, cloud, state, plan, dry_run, lambda d, t: update("Écriture", d, t))
            with progress:
                run = run_apply(ctx)
    except ApplyRefused as exc:
        _fail(str(exc), EXIT_REFUSED, as_json)
    except ApiError as exc:
        _fail(f"cloud : {exc.message}", EXIT_ERROR, as_json)
    finally:
        state.close()
    code = (
        EXIT_REFUSED
        if run.stopped
        else EXIT_ERROR
        if run.count("error")
        else EXIT_CONFLICTS
        if run.count("conflict") or plan.conflicts
        else EXIT_OK
    )
    if as_json:
        emit_json({"ok": code == EXIT_OK, **run.to_json(), "serato_rescan": SERATO_RESCAN})
    else:
        if run.stopped:
            console.print(f"[red]{run.stopped}[/]")
        console.print(
            f"Application {run.run_id} : {run.count('written')} écrits, {run.count('conflict')} conflits, "
            f"{run.count('error')} erreurs"
            + (f", {run.count('already')} déjà à jour" if run.count("already") else "")
            + (f", {run.count('skipped')} non traités" if run.count("skipped") else "")
            + (f", {run.count('dry_run')} simulés" if dry_run else "")
            + "."
        )
        console.print(f"Rapport : {run.report_md}")
        if run.count("written"):
            console.print(SERATO_RESCAN)
    raise typer.Exit(code)


def _trial_summary(run: Any, as_json: bool) -> NoReturn:
    from .apply import TRIAL_CHECK

    code = EXIT_ERROR if run.count("error") else EXIT_CONFLICTS if run.count("conflict") else EXIT_OK
    if as_json:
        emit_json({"ok": code == EXIT_OK, **run.to_json(), "serato_check": TRIAL_CHECK})
    else:
        console.print(
            f"Essai : {run.count('written')} copies écrites et vérifiées dans {run.backup_dir}, "
            f"{run.count('conflict')} conflits, {run.count('error')} erreurs."
        )
        console.print(f"Rapport : {run.report_md}")
        if run.count("written"):
            console.print(TRIAL_CHECK)
    raise typer.Exit(code)


@app.command()
def rollback(
    run_id: Annotated[str, typer.Argument(help="Identifiant de l'application à annuler.")],
    as_json: JsonOpt = False,
    track: Annotated[list[str] | None, typer.Option(help="N'annuler que ces morceaux.")] = None,
    force: Annotated[
        bool, typer.Option(help="Écraser aussi les fichiers modifiés depuis l'application.")
    ] = False,
    yes: Annotated[bool, typer.Option("--yes")] = False,
) -> None:
    """Restaure les fichiers d'une application depuis sa sauvegarde."""
    from .apply import ApplyRefused, RollbackContext, run_rollback
    from .state import ImportState

    s = _settings()
    if not yes and not typer.confirm(f"Restaurer les fichiers de l'application {run_id} ?", default=False):
        raise typer.Exit(EXIT_OK)
    state = ImportState(s.cache_dir / "state.sqlite")
    try:
        with _api(s) as api:
            run = run_rollback(RollbackContext(s, api, state, run_id, set(track) if track else None, force))
    except ApplyRefused as exc:
        _fail(str(exc), EXIT_REFUSED, as_json)
    except ApiError as exc:
        _fail(f"cloud : {exc.message}", EXIT_ERROR, as_json)
    finally:
        state.close()
    if as_json:
        emit_json(run.to_json())
    else:
        console.print(
            f"{run.count('written')} fichiers restaurés, {run.count('error')} erreurs. Rapport : {run.report_md}"
        )
    if run.stopped and not as_json:
        console.print(f"[red]{run.stopped}[/]")
    raise typer.Exit(EXIT_REFUSED if run.stopped else EXIT_ERROR if run.count("error") else EXIT_OK)


@app.command()
def resolve(
    tracks: Annotated[
        list[str] | None, typer.Argument(help="Identifiants des morceaux (vide avec --all).")
    ] = None,
    keep_file: Annotated[bool, typer.Option("--keep-file", help="Garder la valeur du fichier.")] = False,
    keep_app: Annotated[bool, typer.Option("--keep-app", help="Imposer la valeur de l'app.")] = False,
    all_conflicts: Annotated[bool, typer.Option("--all", help="Tous les conflits.")] = False,
    as_json: JsonOpt = False,
) -> None:
    """Tranche un conflit dans la base (n'écrit aucun fichier audio)."""
    from .cloud import CloudState
    from .resolve import resolve as do_resolve

    if keep_file == keep_app:
        _fail("choisir --keep-file ou --keep-app", EXIT_ERROR, as_json)
    s = _settings()
    try:
        with _api(s) as api:
            cloud = CloudState.load(api)
            ids = list(tracks or [])
            if all_conflicts:
                ids += [t["id"] for t in cloud.live_tracks() if t.get("apply_status") == "conflit"]
            result = do_resolve(s, api, cloud, ids, "file" if keep_file else "app")
    except ApiError as exc:
        _fail(f"cloud : {exc.message}", EXIT_ERROR, as_json)
    if as_json:
        emit_json(result.__dict__)
    else:
        console.print(f"{len(result.resolved)} conflits tranchés, {len(result.errors)} erreurs.")
        for e in result.errors:
            console.print(f"[red]Erreur[/] {e['track_id']} : {e['error']}")


@app.command()
def pair(name: Annotated[str, typer.Option(help="Nom de l'appareil.")] = "iPhone") -> None:
    """Connecte un iPhone : affiche un QR code à scanner dans l'app."""
    import urllib.parse

    import segno

    s = _settings()
    try:
        with _api(s) as api:
            device = api.create_device(name)
    except ApiError as exc:
        _fail(f"cloud : {exc.message}")
    payload = "mytags://pair?" + urllib.parse.urlencode({"api": s.api_url, "token": device["token"]})
    qr = segno.make(payload, error="m")
    qr.terminal(compact=True)
    console.print("Scanner ce code dans l'app MyTags (ou coller le texte ci-dessous).")
    console.print(payload, soft_wrap=True)


@devices_app.command("list")
def devices_list(as_json: JsonOpt = False) -> None:
    """Liste les appareils connectés."""
    s = _settings()
    with _api(s) as api:
        devices = api.list_devices()
    if as_json:
        emit_json(devices)
        return
    for d in devices:
        state = "révoqué" if d.get("revoked_at") else "actif"
        console.print(f"{d['id']}  {d['name']}  {state}  vu {d.get('last_seen_at') or 'jamais'}")


@devices_app.command("revoke")
def devices_revoke(device_id: str) -> None:
    """Coupe l'accès d'un appareil (perdu, remplacé)."""
    s = _settings()
    with _api(s) as api:
        api.revoke_device(device_id)
    console.print("Appareil révoqué.")


@app.command("backup-db")
def backup_db() -> None:
    """Exporte la base cloud en JSON compressé dans ~/DJTag/backups/db."""
    from .maintenance import backup_db as do_backup

    s = _settings()
    s.ensure_dirs()
    with _api(s) as api:
        path = do_backup(s, api)
    console.print(f"Base exportée : {path}")


@app.command("prune-backups")
def prune_backups(
    keep: Annotated[int | None, typer.Option(help="Nombre d'applications à garder (10 par défaut).")] = None,
) -> None:
    """Supprime les vieilles sauvegardes d'application (garde les plus récentes)."""
    from .maintenance import prune_backups as do_prune

    removed = do_prune(_settings(), keep)
    console.print(f"{len(removed)} sauvegardes supprimées.")


CONFIG_KEYS = {
    "tags.popm_email": "popm_email",
    "tags.comm_language": "comm_language",
    "tags.wav_id3_chunk": "wav_id3_chunk",
    "tags.mp4_rating_key": "mp4_rating_key",
    "tags.generic_rating_scale": "generic_rating_scale",
    "audio.bitrate": "aac_bitrate",
    "audio.loudness_lufs": "loudness_lufs",
    "audio.encoder": "encoder",
    "import.workers": "workers",
    "backups.keep": "keep_backups",
}


@config_app.command("show")
def config_show() -> None:
    """Affiche la configuration."""
    s = _settings()
    console.print(f"Fichier : {settings_mod.config_path()}")
    console.print(f"Musique : {', '.join(str(p) for p in s.music_folders)}")
    console.print(f"API : {s.api_url or '(non connecté)'}")
    for key, attr in CONFIG_KEYS.items():
        console.print(f"{key} = {getattr(s, attr)!r}")


@config_app.command("set")
def config_set(key: str, value: str) -> None:
    """Change un réglage, ex. `djtag config set tags.popm_email 'xxx'`."""
    if key not in CONFIG_KEYS:
        _fail("clé inconnue ; clés possibles : " + ", ".join(CONFIG_KEYS))
    s = _settings()
    attr = CONFIG_KEYS[key]
    current = getattr(s, attr)
    converted: Any = value
    if isinstance(current, bool):
        converted = value.lower() in ("1", "true", "oui", "yes")
    elif isinstance(current, int):
        converted = int(value)
    elif isinstance(current, float):
        converted = float(value)
    setattr(s, attr, converted)
    settings_mod.save(s)
    console.print(f"{key} = {converted!r}")


if __name__ == "__main__":
    main()
