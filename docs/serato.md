# Serato DJ Pro : correspondances et relecture des tags

Ce document dit où chaque champ est écrit dans les fichiers, quelles données Serato restent intactes, et comment faire relire les tags par Serato.

## Où chaque champ est écrit

| Champ | MP3, WAV, AIFF (ID3) | M4A | FLAC |
| --- | --- | --- | --- |
| Genre | TCON | ©gen (l'atome numérique `gnre` est retiré s'il existe) | GENRE |
| Couleur | TIT1 (GROUPING) | ©grp | GROUPING |
| Pays, Type, Attribut | COMM, description vide (COMMENT composé) | ©cmt | COMMENT |
| Note | POPM, avec le propriétaire relevé à l'audit : 1, 64, 128, 196, 255 | `----:com.apple.iTunes:RATE` (désactivé par défaut) | RATING (désactivé par défaut) |

Pour M4A et FLAC, la note n'est écrite qu'après confirmation par l'audit.

- Réglage partagé `rating.write_formats` (par défaut : `mp3`, `wav`, `aiff`).
- Côté Mac, réglages `tags.mp4_rating_key` et `tags.generic_rating_scale`, avec `djtag config set`.

## Données préservées octet par octet

`djtag apply` ne réécrit que les cadres gérés. Avant de remplacer l'original, il vérifie sur une copie que tout le reste est identique :

- tous les autres cadres ID3 (GEOB Serato Markers2, BeatGrid, Overview, Autotags, Offsets, cover, Mixed In Key…), dans le même ordre ;
- l'ID3v1 en fin de fichier ;
- les autres atomes `ilst` des M4A (dont `----:com.serato.dj:*`) ;
- les autres commentaires Vorbis et blocs FLAC (SERATO_*, images) ;
- la partie audio, comparée par somme de contrôle.

Sinon, le fichier n'est pas modifié et passe en Erreur. Les tags qui utilisent la désynchronisation, un en-tête étendu ou des cadres gérés compressés sont refusés.

## Faire relire les tags par Serato

Serato garde les tags dans sa propre base. Après chaque `djtag apply` :

1. Ouvrir Serato DJ Pro (4.0 ou plus).
2. Sélectionner les morceaux modifiés. Le plus simple : trier la bibliothèque par date de modification, ou glisser dans un crate temporaire les fichiers listés dans le rapport `~/DJTag/reports/apply-<id>.md`.
3. Clic droit › **Re-Scan File Info** (« Relire les infos du fichier »).
4. Vérifier sur 2 ou 3 morceaux : cue points, boucles, beatgrid et couleur de piste intacts ; GENRE, GROUPING, COMMENT et note à jour.

Pour Serato DJ Pro 3 : panneau **Files** › bouton **Rescan ID3 Tags** sur le dossier concerné.

La procédure exacte sera confirmée lors du premier essai réel, sur une copie de 20 morceaux (phase 6), puis complétée ici.

## Interdits

- Ne jamais écrire pendant que Serato est ouvert : `djtag apply` refuse, avec le code 3.
- Ne jamais modifier le dossier `_Serato_` (base et crates).
