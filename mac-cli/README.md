# djtag

Outil Mac de MyTags. Voir `../CLAUDE.md` pour les commandes et `../docs/outils.md` pour l'installation.

```bash
uv sync
uv run djtag --help
uv run pytest -q          # nécessite ffmpeg et fpcalc
```

Test d'intégration avec le vrai Worker en local :

```bash
cd ../backend && npm run migrate:local && npx wrangler dev   # .dev.vars : ADMIN_TOKEN=...
MYTAGS_IT_URL=http://127.0.0.1:8787 MYTAGS_IT_TOKEN=... uv run pytest tests/test_integration_worker.py
```
