# Avancement

Mis à jour le 8 octobre 2026.

## Où on en est

Tout le code de la version 1 et des accélérateurs P2 est écrit et testé automatiquement. Les étapes suivantes demandent les vrais fichiers, le Mac et l'iPhone de l'utilisateur ; elles sont décrites plus bas, dans « Prochaines étapes ».

Écart de méthode : à la demande de l'utilisateur (« développe l'application complète »), toutes les phases ont été codées d'un trait au lieu d'être validées une par une. Les critères de validation de chaque phase restent à vérifier sur le matériel réel, dans l'ordre ci-dessous.

## Phases

| Phase | Code | Validation sur le matériel |
| --- | --- | --- |
| 0. Outils, comptes, dépôt | ✅ dépôt, CI (cli, backend, iOS sur macOS 26), `CLAUDE.md`, garde-fous | ⏳ installer les outils (`docs/outils.md`) |
| 1. Audit | ✅ `djtag doctor`, `djtag audit` | ⏳ lancer l'audit, trancher les questions de la section 21 |
| 2. Prototype de l'écran Taguer | ✅ écran Taguer complet + mode démo (données et audio générés) | ⏳ test chronométré sur 50 morceaux |
| 3. Cloud | ✅ Worker, D1, R2, `setup.sh`, 65 tests | ⏳ `backend/scripts/setup.sh` |
| 4. Import | ✅ `djtag import` (empreinte, AAC −14 LUFS, forme d'onde, point de départ, covers, reprise, parallèle) | ⏳ import de 50, réglage des points de départ, puis tout |
| 5. App v1 | ✅ base locale, synchro, lecture, cache, trajets, Bibliothèque, Réglages | ⏳ vrai trajet en train, mesures de la section 14 |
| 6. Application sur le Mac | ✅ `diff`, `apply`, `rollback`, `resolve`, skill `appliquer-tags` ; relecture par un agent séparé | ⏳ essai sur une copie de 20 morceaux, puis contrôle dans Serato |
| 7. Accélérateurs | ✅ règles, suggestions par artiste, mode Par artiste, Passe rapide, vues, sélection multiple, récapitulatif | ⏳ mesure des taps par morceau |
| 8. Finitions | ✅ icône, accessibilité de base (VoiceOver, grand texte, réduction des animations) | ⏳ Instruments, revue de design sur captures |

## Tests automatiques

| Partie | Tests |
| --- | --- |
| `djtag` (Python) | 170 : modèle partagé, écriture octet par octet des 5 formats, flux complet import → apply → rollback, conflits, fichiers déplacés, garde-fous, 25 tests de non-régression issus de la relecture ; 1 test d'intégration contre le vrai Worker |
| Backend | 65 (Miniflare) |
| MyTagsKit (Swift) | 98 tests, 195 cas, dont les 104 cas partagés avec Python |
| App iOS | compilation, tests unitaires (base locale, cache, bibliothèque) et parcours de tag automatisé sur simulateur (CI macOS) |

## Relecture du chemin d'écriture

Un agent séparé a relu `apply` et `rollback` en cherchant à les mettre en défaut. Il a trouvé 12 défauts réels, tous corrigés et couverts par `mac-cli/tests/test_write_path_regressions.py` :

- ID3v2.4 aux tailles de cadres non conformes (anciens iTunes) : lu correctement, refusé si ambigu ;
- vérification M4A étendue à toute la structure du fichier ;
- une interruption (Ctrl-C, coupure réseau) ne perd plus le suivi des fichiers déjà écrits ; un fichier déjà écrit est reconnu « déjà à jour » au lieu d'un faux conflit ;
- un fichier illisible, un nom très long ou un WAV mal formé n'arrête plus toute l'application ;
- Serato ouvert pendant l'application : arrêt avant le fichier suivant (R6) ;
- liens symboliques conservés ; l'annulation ne recrée jamais un fichier déplacé ni un dossier ;
- doublons de COMMENT fusionnés, compteur d'écoutes POPM conservé, POPM d'un autre logiciel : seule la note est sautée ;
- une seule application à la fois ; sauvegardes et manifeste vidés sur disque avant d'écrire.

## Prochaines étapes, dans l'ordre

1. Installer les outils (`docs/outils.md`, sections 1 à 3).
2. `uv run djtag audit --fingerprints --summary ../docs/audit.md`, puis régler `tags.popm_email`.
3. Répondre aux questions restantes de la section 21 (voir plus bas).
4. Backend : `backend/scripts/setup.sh`, puis `djtag login`.
5. Installer l'app (`docs/ios.md`), puis l'essayer en démo.
6. `djtag import --limit 50` : vérifier les covers et les points de départ sur 30 morceaux, puis `djtag import`.
7. `djtag pair`, puis taguer.
8. Première application sur une **copie** de 20 morceaux, contrôle dans Serato, puis le reste.

## Questions encore ouvertes (section 21)

| N° | Hypothèse appliquée | Comment trancher |
| --- | --- | --- |
| 1 | Serato 4 ou plus, confirmé par l'utilisateur. Note en POPM pour MP3/WAV/AIFF ; M4A et FLAC désactivés | Audit : clés et valeurs de note relevées |
| 2, 4 | Position vide écrite « () » | Modifiable dans Réglages › Format du COMMENT |
| 3 | Un seul attribut par morceau | Passer le champ Attribut en « Choix multiple » si besoin |
| 5 | Une seule couleur | — |
| 6 | Pays FR, US, UK ; Types EXTEND, REMIX, EDIT | Compléter après l'audit, dans Réglages |
| 7 | Obligatoires : Genre, Couleur, Pays, Type, Note | Réglages › Champs |
| 8 | Valeurs en majuscules | — |
| 9 | Pas de Mixed In Key dans le COMMENT | L'audit compte les COMMENT de type « 8A - Energy 6 » |
| 10 | Inconnu | Audit : structure des dossiers |
| 11 | Disque interne APFS (sauvegardes clonées) ; sur un disque externe, copies complètes | `djtag doctor` vérifie l'espace |
| 12 | iPhone sous iOS 26, confirmé | — |
| 13 | Mac récent avec Xcode 26, confirmé | — |
| 14 | App « MyTags », dépôt `antoine721/MyTags` | — |
| 15 | Cloudflare gratuit au lieu de Supabase (décision 0001) | — |
| 16 | Partie la plus forte ; AAC 96 kbps à −14 LUFS | Essai sur 30 morceaux |

## Points de vigilance

- Les tags des WAV dépendent du chunk ID3 (`id3 ` ou `ID3 `) : l'audit le confirmera avant toute écriture en masse.
- La note M4A/FLAC reste dans l'app tant que l'audit n'a pas montré ce qu'écrit Serato.
- Compte Apple gratuit : réinstaller l'app depuis Xcode chaque semaine (décision 0003).
