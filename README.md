# MyTags

Taguer ~5 000 morceaux DJ depuis l'iPhone (dans le train, hors ligne), puis écrire les tags dans les
fichiers lus par Serato DJ — uniquement sur commande, depuis le Mac, avec sauvegarde et vérification.

| Brique | Rôle |
| --- | --- |
| `ios/` | App iPhone (SwiftUI, iOS 26) : écoute en continu, tag en un tap, hors ligne |
| `backend/` | Cloudflare Worker + D1 + R2 : catalogue, tags, audio d'écoute (0 €/mois) |
| `mac-cli/` | `djtag` : audit, import, aperçu, application, annulation |
| `.claude/` | Skill « appliquer-tags » et garde-fous pour Claude Code |

## En bref

1. **Mettre en place** : `docs/premiere-installation.md`, pas à pas (détails dans `docs/outils.md`).
2. **Importer** : `uv run djtag audit`, puis `uv run djtag import` (depuis `mac-cli/`).
3. **Taguer** : dans l'app, la vue « À compléter », une note valide le morceau et passe au suivant.
4. **Essayer sur des copies** (règle R4) : `uv run djtag apply --copy-to ~/Desktop/MyTags-essai --limit 20`,
   puis contrôle dans Serato.
5. **Appliquer** : dans Claude Code, « applique mes tags du train » — ou `uv run djtag diff`, puis
   `uv run djtag apply`.
6. **Annuler** : `uv run djtag rollback <id-application>`.

## Documentation

- `docs/cahier-des-charges.md` — la référence
- `docs/avancement.md` — où en est le projet
- `docs/decisions/` — écarts au cahier des charges
- `docs/modele-tags.md`, `docs/api.md` — algorithmes et contrat d'API
- `docs/ios.md`, `docs/backend.md`, `docs/serato.md`
