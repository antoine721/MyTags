# Changelog

## Non publié

### Ajouté
- `djtag` (cli-v0.1.0) : doctor, audit, import (empreintes, AAC −14 LUFS, forme d'onde, point de départ,
  covers, fichiers déplacés, suppressions logiques), status, diff, apply (sauvegarde, écriture sur copie
  vérifiée, remplacement atomique), rollback, resolve, pair, devices, backup-db, prune-backups.
- Backend Cloudflare : Worker (synchronisation par révisions, journal idempotent, jetons d'appareil,
  audio par plages), migrations D1.
- App iOS (ios-v0.1.0) : écran Taguer, Passe rapide, Bibliothèque (recherche, filtres, vues, artistes,
  sélection multiple, mini-lecteur), Réglages (champs, valeurs, règles, COMMENT, lecture, cache,
  statistiques), lecture locale avec préchargement, trajets hors ligne, appairage par QR code, démo.
- MyTagsKit : modèle des tags partagé, testé contre les mêmes cas que Python.
- Intégration Claude Code : `CLAUDE.md`, skill `appliquer-tags`, garde-fous.
