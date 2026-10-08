# 0006 — Écriture ID3 par remplacement de cadres bruts ; ID3v1 intact ; note écrite d'abord en ID3 seulement

**Date** : 8 octobre 2026 · **Statut** : accepté

## Contexte

La règle R3 exige que tous les tags non gérés restent identiques à l'octet près. mutagen relit chaque cadre ID3 et le réécrit à partir de sa propre représentation. Pour les cadres inhabituels, il peut réencoder, convertir la version 2.3 en 2.4 au chargement, ou modifier l'ordre des cadres.

## Choix

- **ID3 (MP3, WAV, AIFF)** : `djtag` utilise son propre lecteur et écrivain de cadres bruts (`djtag/tags/id3raw.py`).
  - Les cadres non gérés sont recopiés **octet par octet, dans le même ordre**.
  - Seuls TCON, TIT1, COMM (sans description) et POPM sont remplacés ou ajoutés. Si un fichier contient deux cadres pour le même tag (par exemple deux COMM sans description), ils sont fusionnés en un seul, avec la nouvelle valeur.
  - En ID3v2.4, la taille des cadres est lue des deux façons (entier « syncsafe » de la norme, entier simple des anciens iTunes). Si une seule lecture tombe juste, elle est retenue ; si les deux tombent juste avec des cadres différents, le fichier est refusé.
  - La version (2.3 ou 2.4) et les drapeaux de l'en-tête sont conservés.
  - Le remplissage (padding) est réutilisé quand la place suffit. Le fichier garde alors sa taille et l'audio n'est pas déplacé.
  - Les tags utilisant la désynchronisation globale, un en-tête étendu, la compression ou le chiffrement sont **refusés** (statut Erreur, message explicite). L'audit indique combien de fichiers sont concernés.
- **ID3v1** (128 octets en fin de fichier) : laissé **strictement intact**. Serato lit l'ID3v2, et ID3v1 ne sait de toute façon pas représenter un genre comme SHATTA.
- **MP4 (M4A) et FLAC** : écriture avec mutagen, puis vérification. Les atomes `ilst` et les commentaires Vorbis non gérés doivent être identiques à l'octet près. Les autres blocs FLAC et les données audio doivent avoir la même somme de contrôle. En M4A, tous les atomes hors tags sont comparés, et les tables de positions des blocs audio (`stco`, `co64`) le sont en position relative aux données audio : un tag qui grandit les décale toutes, une écriture fautive non. Sinon, le fichier est restauré et marqué Erreur.
- **Note (Serato 4 ou plus)** :
  - écrite dans POPM pour MP3, WAV et AIFF (valeurs 1, 64, 128, 196, 255) ;
  - pour M4A et FLAC, l'emplacement et l'échelle exacts ne sont pas documentés de source sûre. L'écriture de la note y est donc **désactivée par défaut** (réglage partagé `rating.write_formats`) jusqu'à ce que l'audit montre ce que Serato écrit réellement ;
  - le propriétaire du cadre POPM est celui relevé à l'audit (réglage `rating.popm_email`). L'outil ne crée jamais un second cadre POPM. Si un fichier contient seulement un POPM d'un autre logiciel, la note n'est pas écrite et le rapport le signale ; les autres tags du fichier sont écrits normalement ;
  - effacer la note garde le cadre POPM (note 0) quand il contient un compteur d'écoutes, qui n'est pas géré par l'outil.

## Raisons

- La garantie « octet près » ne dépend plus de la fidélité de mutagen pour les formats où Serato range le plus de données (GEOB en MP3 et AIFF).
- La vérification après écriture (section 12) contrôle cette garantie pour tous les formats.
