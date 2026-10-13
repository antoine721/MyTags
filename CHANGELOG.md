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
- `djtag apply --copy-to <dossier>` : essai sur des copies hors de la bibliothèque (règle R4).
- Guide pas à pas : `docs/premiere-installation.md`.
- Tri « Actualité » à la Tinder (Bibliothèque › ⋯ › Trier l'actualité, ou ⋯ › Actualité sur l'écran
  Taguer) : glisser à gauche ajoute `ARCHIVE` au COMMENT, à droite garde le morceau ; boutons et
  « Annuler » équivalents. Les crates Serato GENRE excluent les COMMENT contenant ARCHIVE.
- Modèle des tags : champs **mot-clé** du COMMENT (champ à choix unique ciblant le COMMENT sans
  position), reconnus n'importe où et ajoutés à la fin, sans toucher au reste du COMMENT
  (`docs/modele-tags.md`, section 4 bis). Nouveau champ « Actualité » (valeur `ARCHIVE`, masqué de
  l'écran Taguer) dans la configuration par défaut ; l'app le crée s'il manque.

### Modifié (relecture avant la première installation)
- Écran Taguer : bouton « Taguer » en un tap depuis la vue en cours ; ouverture sur « À compléter » (dernière
  vue retenue) ; validation automatique dès que le dernier champ obligatoire manquant est rempli ; taps sur
  les étoiles ignorés 300 ms après un passage automatique ; bandeau « Annuler » sans place réservée.
- Lecture : un téléchargement à la fois (le morceau en cours d'abord) ; plus de saut automatique en fin de
  morceau (reprise au point de départ) ; plus de « clic » au changement de morceau ; démo jouable.
- Connexion : demande d'accès à la caméra, nouvel essai possible après un échec, erreurs affichées ;
  passage de la démo au vrai catalogue sans mélange.
- Synchronisation : un envoi refusé ne bloque plus le reste (lots de 500, rangées refusées isolées et
  gardées) ; plus de faux « hors ligne » durable ; une rangée illisible ne bloque plus la réception ;
  la déconnexion garde les modifications non envoyées ; la valeur gagnante d'un conflit revient sur
  tous les appareils.

### Corrigé
- Plantage probable à l'affichage de la pochette sur l'écran verrouillé.
- `uv sync` sur un Mac neuf (Python 3.13 fixé), `djtag --help` (click 8.1.8), QR code inversé sur un
  Terminal clair.
