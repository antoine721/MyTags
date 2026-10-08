# Cahier des charges – Tagueur DJ

Oct 8, 2026 · @Antoine

## 0. Mode d'emploi pour l'IA qui réalise le projet

Ce document est la référence unique du projet : une app iPhone pour taguer environ 5 000 morceaux DJ dans le train, et un outil Mac qui écrit ces tags dans les fichiers lus par Serato.

**Méthode de travail**

1. Lire tout le document avant la moindre action.
2. Copier ce document dans le dépôt sous `docs/cahier-des-charges.md`. Il fait foi. Toute décision qui s'en écarte est notée dans `docs/decisions/` : une note par décision (contexte, choix, raison).
3. Suivre les phases de la section 18 dans l'ordre. Ne pas commencer une phase avant que les critères de validation de la précédente soient remplis et approuvés par l'utilisateur.
4. Au début de chaque phase, proposer un plan court (tâches, fichiers touchés, risques) et attendre l'accord de l'utilisateur.
5. Les points marqués **\[À CONFIRMER\]** se tranchent avec l'utilisateur. En attendant, appliquer l'hypothèse par défaut de la section 21 et le signaler.
6. Avancer par petites étapes vérifiables : une branche et une pull request par lot de travail, tests compris.
7. Tenir à jour `docs/avancement.md` : phase en cours, tâches faites, prochaines étapes, points bloquants.
8. En cas de doute sur un comportement attendu, poser la question plutôt que deviner.

**Règles absolues (non négociables)**

- **R1.** Ne jamais modifier, déplacer, renommer ou supprimer un fichier de la bibliothèque musicale sans commande explicite de l'utilisateur (« applique », « annule »).
- **R2.** Avant toute écriture dans un fichier audio : sauvegarde de ce fichier. Après l'écriture : vérification complète (section 12).
- **R3.** Ne modifier que les champs gérés par l'app (GENRE, GROUPING, COMMENT, note). Tous les autres tags, dont les données Serato (cue points, beatgrids, boucles, couleurs, aperçu), restent identiques à l'octet près.
- **R4.** Ne jamais écrire dans la vraie bibliothèque avant d'avoir validé l'écriture sur une copie.
- **R5.** Aucun secret (clé, mot de passe, jeton) et aucun fichier audio dans le dépôt.
- **R6.** Aucune écriture de tags si Serato DJ est ouvert.
- **R7.** Toute modification faite dans l'app est enregistrée sur le téléphone avant d'apparaître comme faite : zéro perte, même en cas de plantage.
- **R8.** Pas de texte inutile dans l'interface : pas d'aide permanente, pas de message de bienvenue, pas de confirmation superflue.

**Langues**

- Interface de l'app et documentation (`docs/`) : français.
- Code, noms de variables, commentaires de code et messages de commit : anglais.

## 1. Contexte, objectifs et indicateurs de réussite

L'objectif est de taguer environ 5 000 morceaux le plus vite possible depuis un iPhone, hors de chez soi, puis d'appliquer ces tags aux fichiers lus par Serato, uniquement sur commande.

**Contexte**

- **Utilisateur** : DJ qui mixe uniquement sur Serato DJ.
- **Bibliothèque** : environ 5 000 morceaux de formats variés, en qualité MP3 au minimum (MP3, M4A/AAC, WAV, AIFF, FLAC possibles ; l'audit de la phase 1 le confirmera).
- **Matériel** : un Mac (bibliothèque, Serato, Xcode, Claude Code) et un iPhone.
- **Usage principal** : dans le train. Le réseau coupe souvent (tunnels, zones blanches). L'utilisateur est souvent debout, avec une seule main libre et des écouteurs (AirPods).
- **Comptes** : abonnement Apple Developer payant ; un cloud payant est accepté si nécessaire.
- **Situation actuelle** : le tag se fait sur l'ordinateur, ce qui est lent et oblige à être à son bureau.

**Objectifs**

1. Taguer depuis l'iPhone en écoutant les morceaux entiers, sans stocker toute la bibliothèque sur le téléphone (streaming et cache limité, comme Spotify ou Deezer).
2. Remplir les tags le plus vite possible : chaque seconde compte. Repère : 1 seconde gagnée par morceau = 1 h 23 gagnée sur 5 000 morceaux.
3. Ne modifier les fichiers que sur ordre de l'utilisateur, depuis le Mac, de façon sûre et réversible.
4. Offrir une app simple, agréable et très soignée, au niveau d'exigence d'une app Apple.

**Indicateurs de réussite** (mesurés par l'app, section 9)

| Indicateur | Cible |
| --- | --- |
| Taps par morceau en mode Complet, après pré-remplissage | 3 en moyenne au maximum |
| Délai entre la validation et le morceau suivant (déjà préchargé) | 150 ms au maximum |
| Modifications perdues | 0 |
| Fichiers abîmés ou données Serato altérées | 0 |
| Tags modifiables sans réseau | 100 % des champs |
| Ouverture de l'app jusqu'à l'écran Taguer utilisable | 1,5 s au maximum |

## 2. Expression des besoins

L'utilisateur a 49 besoins, numérotés pour être cités dans le code, les tickets et les tests. Priorité P1 = indispensable en version 1, P2 = accélérateurs juste après, P3 = plus tard.

| ID | Thème | Besoin | Priorité |
| --- | --- | --- | --- |
| B-01 | Écoute | Écouter chaque morceau en entier sur l'iPhone, en streaming, sans stocker toute la bibliothèque | P1 |
| B-02 | Écoute | Démarrer la lecture au cœur du morceau ; réglable : début, 25 %, partie la plus forte | P1 |
| B-03 | Écoute | Voir la forme d'onde et sauter à n'importe quel point d'un tap | P1 |
| B-04 | Écoute | Reculer ou avancer de 15 s par double tap à gauche ou à droite de la cover | P1 |
| B-05 | Écoute | Passer au morceau suivant ou précédent par swipe sur la cover, par boutons et depuis les écouteurs | P1 |
| B-06 | Écoute | Lecture en arrière-plan et contrôles sur l'écran verrouillé | P1 |
| B-07 | Écoute | Continuer d'écouter dans les zones sans réseau grâce au préchargement | P1 |
| B-08 | Écoute | Volume homogène d'un morceau à l'autre, sans réglage manuel | P1 |
| B-10 | Taguer | Tout voir sur un seul écran, sans scroller : cover, titre, artiste, BPM, tonalité, durée, barre d'écoute et tous les champs | P1 |
| B-11 | Taguer | Taguer par pastilles, en un tap : Genre, Couleur (GROUPING), Pays, Type, Attribut, Note de 1 à 5 | P1 |
| B-12 | Taguer | Modifier séparément les trois parties du COMMENT (Pays, Type, Attribut), recomposées automatiquement | P1 |
| B-13 | Taguer | Valider avec la note et passer automatiquement au morceau suivant (désactivable) | P1 |
| B-14 | Taguer | Annuler la dernière action pendant 3 s, et revenir au morceau précédent avec ses tags intacts | P1 |
| B-15 | Taguer | Être prévenu quand un champ obligatoire manque, sans fenêtre bloquante | P1 |
| B-16 | Taguer | Ajouter une nouvelle valeur à un champ sans quitter l'écran | P1 |
| B-17 | Taguer | Distinguer d'un coup d'œil les valeurs suggérées des valeurs confirmées | P1 |
| B-20 | Vitesse | Reprendre les tags déjà présents dans les fichiers et ne présenter que ce qui manque | P1 |
| B-21 | Vitesse | Déduire le Type du titre (Extended, Remix, Edit…) | P1 |
| B-22 | Vitesse | Règles automatiques réglables (ex. Genre RAP FR → Pays FR) | P2 |
| B-23 | Vitesse | Suggestions selon l'artiste, d'après ses morceaux déjà tagués | P2 |
| B-24 | Vitesse | Valeur par défaut par champ (ex. Attribut « () ») | P1 |
| B-25 | Vitesse | Mode « Par artiste » : taguer d'un coup tous les morceaux d'un artiste, sans écouter | P2 |
| B-26 | Vitesse | Mode « Passe rapide » : un seul champ, gros boutons, un tap = morceau suivant | P2 |
| B-27 | Vitesse | Récapitulatif de session : morceaux tagués, temps et taps moyens par morceau | P2 |
| B-28 | Vitesse | Écran toujours allumé pendant une session | P1 |
| B-30 | Bibliothèque | Liste fluide des 5 000 morceaux, avec recherche par titre et artiste | P1 |
| B-31 | Bibliothèque | Filtres par champ : « ou » dans un même champ, « et » entre champs ; note minimale | P1 |
| B-32 | Bibliothèque | Filtres spéciaux : non tagués, incomplets, commentaire non conforme, modifiés non appliqués | P1 |
| B-33 | Bibliothèque | Tri par artiste, titre, BPM, date d'ajout, note | P1 |
| B-34 | Bibliothèque | Ouvrir un morceau depuis une liste filtrée : suivant et précédent restent dans ce filtre | P1 |
| B-35 | Bibliothèque | Vues enregistrées (filtre + tri nommés) | P2 |
| B-36 | Bibliothèque | Sélection multiple et modification groupée | P2 |
| B-37 | Bibliothèque | Mini-lecteur pendant la navigation | P1 |
| B-40 | Réglages | Créer, renommer, supprimer et réordonner les champs et leurs valeurs | P1 |
| B-41 | Réglages | Choisir le type d'un champ et l'endroit où il est écrit dans le fichier | P1 |
| B-42 | Réglages | Choisir les champs visibles, leur ordre, les champs obligatoires et les valeurs par défaut | P1 |
| B-43 | Réglages | Renommer ou supprimer une valeur en voyant combien de morceaux sont touchés | P1 |
| B-44 | Réglages | Régler la lecture et le cache : point de départ, taille du cache, préchargement, passage automatique | P1 |
| B-50 | Hors ligne | Taguer sans réseau, avec envoi automatique au retour du réseau | P1 |
| B-51 | Hors ligne | « Préparer mon trajet » : télécharger une vue ou un nombre de morceaux en Wi-Fi | P1 |
| B-52 | Hors ligne | Voir le statut de chaque morceau : modifié, envoyé, appliqué | P1 |
| B-53 | Hors ligne | En zone blanche, passer au prochain morceau disponible | P1 |
| B-60 | Mac | Importer la bibliothèque dans le cloud, puis seulement les nouveautés | P1 |
| B-61 | Mac | Voir ce qui va changer avant d'appliquer (aperçu avant / après) | P1 |
| B-62 | Mac | Appliquer les changements sur commande, via une IA (Claude Code) ou une commande | P1 |
| B-63 | Mac | Annuler une application et retrouver les fichiers d'avant | P1 |
| B-64 | Mac | Garder intactes toutes les données Serato | P1 |
| B-65 | Mac | Être averti si un tag a été modifié dans Serato depuis l'import (conflit) | P1 |
| B-70 | Plus tard | Version Mac de l'app, avec raccourcis clavier | P3 |

## 3. Périmètre

La version 1 couvre l'app iPhone, l'outil Mac, le cloud et l'intégration avec Claude Code ; tout ce qui touche au mixage ou aux cue points en est exclu.

**Inclus**

- App iPhone native (SwiftUI), installée via Xcode puis TestFlight, sans publication sur l'App Store.
- Outil Mac en ligne de commande (`djtag`) : audit, import, aperçu, application, annulation.
- Cloud : base de données, stockage audio privé, connexion de l'utilisateur.
- Intégration Claude Code : `CLAUDE.md`, skill « appliquer-tags », règles de sécurité.
- Dépôt GitHub privé, intégration continue, tests automatiques.

**Exclu de la version 1**

- Publication publique sur l'App Store, version Android, interface optimisée pour iPad.
- Modification des cue points, beatgrids, boucles ou couleurs de piste Serato.
- Création ou modification de crates Serato (piste pour plus tard).
- Lecture DJ (mixage, pitch, synchronisation).
- Détection automatique du genre par analyse audio (piste pour plus tard).
- Plusieurs utilisateurs.
- Toute écriture dans les fichiers sans commande explicite.
- Toute modification du son des fichiers d'origine : seuls leurs tags changent.

## 4. Glossaire

Ces termes ont un sens précis dans tout le document et doivent être repris tels quels dans le code et l'interface.

| Terme | Définition |
| --- | --- |
| Morceau | Un fichier audio de la bibliothèque, repéré par un identifiant stable (UUID) qui survit aux déplacements et renommages |
| Bibliothèque | Les dossiers musicaux du Mac scannés par l'outil `djtag` |
| Champ | Une catégorie de tag : Genre, Couleur, Pays, Type, Attribut, Note |
| Valeur | Un choix possible d'un champ, par exemple SHATTA |
| Cible | L'endroit du fichier où un champ est écrit : GENRE, GROUPING, une position du COMMENT, ou la note |
| COMMENT composé | Le tag COMMENT du fichier, formé de trois positions séparées par un espace : PAYS TYPE ATTRIBUT |
| Conforme | Un COMMENT existant que l'outil sait découper sans ambiguïté en ses trois positions |
| Suggestion | Une valeur proposée automatiquement (valeur par défaut, règle, artiste, titre), affichée en style léger et pas encore confirmée |
| Valeur confirmée | Une valeur choisie par l'utilisateur, ou une suggestion qu'il a validée ; seules ces valeurs sont écrites dans les fichiers |
| Validation | L'action qui confirme toutes les suggestions du morceau ; par défaut, mettre la note |
| Modification | Le changement d'une valeur d'un champ pour un morceau, enregistré dans le journal |
| Journal | La liste des modifications, d'abord sur le téléphone, puis dans le cloud |
| Statut | L'état d'un morceau : Modifié (sur le téléphone), Envoyé (dans le cloud), Appliqué (écrit dans le fichier), Conflit, Erreur |
| File | La liste ordonnée et figée de morceaux que parcourent suivant et précédent |
| Vue | Un filtre et un tri enregistrés sous un nom |
| Session | Une période de tag continue, utilisée pour les mesures |
| Point de départ | La position où la lecture d'un morceau commence |
| Préchargement | Le téléchargement en avance des morceaux suivants de la file |
| Cache | L'espace audio local, plafonné, vidé automatiquement des morceaux les plus anciens |
| Trajet préparé | Des morceaux téléchargés volontairement pour l'écoute hors ligne, gardés à part du cache |
| Référence | Les valeurs des tags gérés telles qu'elles sont dans le fichier, relevées à l'import ou après la dernière application ; elles servent à détecter les conflits |
| Application | Une exécution de « appliquer » sur le Mac, avec son identifiant, sa sauvegarde et son rapport |
| Données Serato | Les informations que Serato range dans les tags des fichiers (cue points, beatgrid, boucles, couleur, aperçu), à préserver à l'octet près |

## 5. Architecture générale et flux de données

Trois blocs échangent des données — l'iPhone, le cloud et le Mac — mais seul l'outil Mac écrit dans les fichiers musicaux, et seulement sur commande.

&#91;embedded content: architecture · 3 blocs, 7 composants\]

Le Mac envoie le catalogue et l'audio vers le cloud ; l'iPhone écoute en streaming et renvoie les tags ; l'outil `djtag` ne les écrit dans les fichiers que lorsque l'utilisateur le demande.

**Composants**

| Composant | Technologie | Rôle |
| --- | --- | --- |
| App iPhone | Swift 6, SwiftUI, AVFoundation, GRDB (SQLite) | Écoute, tag, filtres, fonctionnement hors ligne |
| Base de données | Supabase : Postgres, connexion avec Apple, sécurité au niveau des lignes | Catalogue, tags, journal, configuration, statuts |
| Fonction `sign-urls` | Supabase Edge Function | URLs d'accès à l'audio, signées et valables 1 h |
| Stockage audio | Cloudflare R2, bucket privé | Fichiers AAC d'écoute et covers |
| Outil `djtag` | Python, mutagen, ffmpeg, Chromaprint | Audit, import, aperçu, application, annulation |
| Claude Code | Skill `appliquer-tags`, `CLAUDE.md` | Pilote `djtag` à la demande de l'utilisateur |
| Serato DJ Pro | Logiciel de l'utilisateur | Relit les tags des fichiers ; jamais modifié directement |

**Flux de données**

1. **Import** (Mac vers cloud) : `djtag import` lit les fichiers, envoie le catalogue à Supabase et l'audio à R2.
2. **Synchronisation** (cloud vers iPhone) : l'app télécharge le catalogue et la configuration, puis les miniatures.
3. **Écoute** (cloud vers iPhone) : l'app obtient des URLs signées et lit l'audio en streaming, avec préchargement et cache.
4. **Tag** (iPhone) : chaque modification est enregistrée sur le téléphone, puis envoyée à Supabase.
5. **Application** (cloud vers Mac, sur commande) : `djtag diff` puis `djtag apply` écrivent les tags dans les fichiers.
6. **Relecture** (Mac) : Serato relit les tags des fichiers modifiés.

## 6. Modèle de données et configuration des champs

Aucun champ n'est codé en dur : les champs et leurs valeurs viennent d'une configuration modifiable dans l'app, synchronisée dans le cloud et lue par l'outil Mac.

**Principes**

- Le cloud (Postgres) est la référence partagée. Le téléphone en garde une copie complète en SQLite (GRDB.swift recommandé) pour tout faire sans réseau.
- Chaque table synchronisée a un `id` (UUID), un `updated_at` et un `deleted_at` (suppression logique, jamais physique).
- Les identifiants sont créés par l'appareil qui écrit, pour que les écritures hors ligne puissent être renvoyées sans doublon.
- Le schéma ci-dessous est la cible. Les noms peuvent être ajustés, à condition de le noter dans `docs/decisions/`.

**Table `tracks`** — un morceau

| Colonne | Type | Rôle |
| --- | --- | --- |
| id | uuid | Identifiant stable |
| file\_path | text | Chemin absolu du fichier sur le Mac |
| file\_format | text | mp3, m4a, wav, aiff, flac |
| file\_size, file\_mtime | bigint, timestamptz | Détection des fichiers modifiés |
| fingerprint | text | Empreinte acoustique (Chromaprint), pour retrouver un fichier déplacé ou renommé |
| title, artist, album | text | Infos affichées |
| bpm | numeric | BPM lu dans le fichier |
| musical\_key | text | Tonalité lue dans le fichier |
| duration\_ms | int | Durée |
| added\_at | timestamptz | Date d'ajout du fichier |
| start\_ms | int | Point de départ calculé (partie la plus forte) |
| waveform | bytea | Forme d'onde réduite : environ 600 valeurs sur 1 octet |
| audio\_key, cover\_key | text | Emplacement de l'AAC et des covers dans le stockage |
| source\_tags | jsonb | Valeurs brutes lues à l'import (GENRE, GROUPING, COMMENT, note) |
| baseline | jsonb | Référence : valeurs actuelles des tags gérés dans le fichier |
| comment\_status | text | conforme, incomplet, non\_conforme |
| apply\_status | text | aucun, a\_appliquer, applique, conflit, erreur |
| apply\_message | text | Détail d'un conflit ou d'une erreur |
| updated\_at, deleted\_at | timestamptz | Synchronisation et suppression logique |

**Table `fields`** — un champ

| Colonne | Type | Rôle |
| --- | --- | --- |
| id | uuid | Identifiant |
| key | text | Clé stable : genre, couleur, pays, type, attribut, note |
| name | text | Nom affiché |
| kind | text | single, multi, rating, text |
| target\_tag | text | GENRE, GROUPING, COMMENT ou RATING |
| target\_slot | int | Position dans le COMMENT (1, 2 ou 3) ; vide sinon |
| required | bool | Obligatoire pour valider un morceau |
| visible | bool | Affiché sur l'écran Taguer |
| position | int | Ordre d'affichage |
| default\_option\_id | uuid | Valeur par défaut, proposée comme suggestion |
| is\_advance\_trigger | bool | Ce champ valide le morceau et passe au suivant (un seul champ à la fois) |
| artist\_level | bool | Proposé dans le mode « Par artiste » |

**Table `field_options`** — une valeur d'un champ

| Colonne | Type | Rôle |
| --- | --- | --- |
| id, field\_id | uuid | Identifiants |
| value | text | Texte écrit dans le fichier, par exemple RAP FR |
| label | text | Texte affiché ; par défaut égal à `value` |
| color | text | Couleur système, pour le champ Couleur |
| aliases | text\[\] | Variantes reconnues à l'import, par exemple « Rap Fr » ou « RAPFR » |
| position | int | Ordre d'affichage |
| archived | bool | Valeur retirée mais gardée pour l'historique |

**Table `track_values`** — l'état d'un champ pour un morceau (clé : `track_id` + `field_id`)

| Colonne | Type | Rôle |
| --- | --- | --- |
| option\_ids | uuid\[\] | Valeur ou valeurs choisies ; vide = aucune |
| rating | int | Note de 1 à 5, pour le champ Note |
| text\_value | text | Pour un champ texte |
| state | text | confirmed ou suggested |
| source | text | user, file, default, rule, artist, title |
| updated\_at, device\_id | timestamptz, text | Dernière modification et appareil |

**Autres tables**

| Table | Contenu |
| --- | --- |
| `changes` | Journal : id créé sur le téléphone, track\_id, field\_id, ancienne et nouvelle valeur, horodatage, appareil, statut (pending, sent, applied, superseded), apply\_run\_id |
| `apply_runs` | Une exécution sur le Mac : début, fin, mode (dry\_run, apply, rollback), nombre de morceaux écrits, conflits, erreurs, chemin de la sauvegarde et du rapport |
| `rules` | Règles automatiques : nom, actif, ordre, condition, action, mode (suggérer ou appliquer) |
| `saved_views` | Vues enregistrées : nom, filtres, tri, ordre |
| `settings` | Réglages partagés : séparateur du COMMENT, jeton de position vide |
| `sessions` | Local au téléphone : début, fin, morceaux validés, temps total, taps |

Les réglages propres au téléphone (cache, lecture, vibrations, écran allumé) restent en local et ne sont pas synchronisés.

**Règles de calcul**

- Un morceau est **à appliquer** quand ses valeurs confirmées, recomposées en tags (section 7), diffèrent de sa Référence.
- Un morceau est **incomplet** quand au moins un champ obligatoire n'a pas de valeur confirmée.
- Un morceau est **non tagué** quand aucun champ n'a de valeur confirmée.
- Seules les valeurs confirmées sont écrites dans les fichiers. Une suggestion n'est jamais écrite.
- Renommer une valeur rend « à appliquer » tous les morceaux qui l'utilisent. L'app affiche leur nombre avant de confirmer.

**COMMENT composé**

- **Composition** : les valeurs des positions 1, 2 et 3, jointes par le séparateur (une espace par défaut), écrites exactement comme définies dans les réglages.
- **Position vide** : écrite « () » **\[À CONFIRMER\]**, questions 2 et 4 de la section 21.
- **Lecture d'un COMMENT existant** : chaque position est reconnue en la comparant aux valeurs et alias de son champ, sans tenir compte de la casse ni des espaces en trop. Ne jamais se contenter de découper le texte sur les espaces : une valeur pourra un jour contenir une espace.
- **Résultat de la lecture** : conforme (trois positions reconnues), incomplet (positions manquantes, aucun mot inconnu) ou non conforme (mot inconnu ou en trop).
- **COMMENT non conforme** : gardé tel quel, affiché sur l'écran Taguer, et remplacé seulement si l'utilisateur modifie l'une des trois positions. Exemples en section 22.

## 7. Correspondance avec les tags des fichiers et Serato

Chaque champ s'écrit dans un tag standard que Serato DJ Pro lit et affiche. L'audit de la phase 1 confirme chaque correspondance sur les vrais fichiers avant toute écriture.

**Où écrire chaque champ**

| Champ | MP3, WAV, AIFF (ID3) | M4A (MP4) | FLAC (Vorbis) |
| --- | --- | --- | --- |
| Genre | TCON | ©gen | GENRE |
| Couleur | TIT1 (GROUPING) | ©grp | GROUPING |
| Pays, Type, Attribut | COMM (COMMENT composé) | ©cmt | COMMENT |
| Note | POPM : 1, 64, 128, 196, 255 pour 1 à 5 étoiles | RATE | RATING |

Les cases M4A et FLAC, le COMMENT et la note dans les WAV restent à confirmer par l'audit. L'outil reproduit exactement ce qu'il trouve dans les fichiers déjà modifiés par Serato.

**La note dans Serato**

- Serato DJ Pro gère les notes de morceaux depuis la version 4.0, dans une colonne Note ([notes de version 4.0.0](https://serato.com/dj/pro/downloads/4.0.0)).
- D'après des tests publiés en décembre 2025, Serato écrit la note dans POPM pour les MP3 et WAV, dans RATE pour les M4A et dans RATING pour les FLAC ([forum Mp3tag](https://community.mp3tag.de/t/serato-4-0-now-supports-song-ratings/70326)). Les mêmes tests indiquent que le GROUPING des MP3 va dans TIT1.
- Le cadre POPM porte un propriétaire (champ « email »). L'outil réutilise celui que Serato a déjà écrit dans les fichiers, relevé à l'audit, et ne crée jamais un second cadre POPM.
- Le tag `TXXX:Serato Rating Emoji` (émoji choisi pour la note) n'est jamais modifié.
- **\[À CONFIRMER\]** la version de Serato DJ Pro installée sur le Mac (4.0 ou plus pour la note).

**Données Serato à préserver à l'octet près**

| Format | Données Serato |
| --- | --- |
| MP3, AIFF | Cadres GEOB : Serato Overview, Serato Analysis, Serato Autotags, Serato Markers\_, Serato Markers2, Serato BeatGrid, Serato Offsets\_ (MP3 seulement) |
| FLAC | Commentaires Vorbis SERATO\_ANALYSIS, SERATO\_AUTOGAIN, SERATO\_BEATGRID, SERATO\_MARKERS\_V2, SERATO\_OVERVIEW, SERATO\_RELVOL, SERATO\_VIDEO\_ASSOC |
| M4A | Atomes libres `----:com.serato.dj:*` (markers, markersv2, beatgrid, overview, autgain, relvol, analysisVersion, videoassociation) |
| WAV | À relever à l'audit (chunk ID3 probable) |

Source : [documentation serato-tags](https://github.com/Holzhaus/serato-tags/blob/main/docs/fileformats.md). Sont aussi préservés : la cover, les tags d'autres logiciels (par exemple Mixed In Key) et tout cadre inconnu.

**Règles d'écriture**

- Ne lire et réécrire que les cadres gérés ; tous les autres restent intacts, dans le même ordre si la bibliothèque le permet.
- Ne jamais changer la version ID3 d'un fichier (2.3 reste 2.3, 2.4 reste 2.4), ni l'encodage du texte sans nécessité.
- Ne jamais écrire dans le dossier `_Serato_` (base de données et crates de Serato).
- Ne jamais écrire pendant que Serato est ouvert (règle R6).
- Bibliothèque recommandée : mutagen (Python), qui couvre les cinq formats.

**Faire relire les tags par Serato**

Serato garde les tags dans sa propre base. Après une application, il faut lui faire relire les fichiers modifiés. Selon les tests cités plus haut, la version 4 propose un clic droit « Re-Scan File Info » ; les versions précédentes ont un bouton « Rescan ID3 Tags » dans le panneau Files. La procédure exacte est validée en phase 6 et décrite dans `docs/serato.md`.

L'outil serato-tools sait modifier directement la base de Serato pour éviter cette relecture ([serato-tools](https://pypi.org/project/serato-tools/)). C'est exclu de la version 1, car trop risqué pour la bibliothèque de l'utilisateur.

## 8. App iOS : principes d'expérience utilisateur

La vitesse de remplissage passe avant tout le reste : chaque choix d'interface se juge au temps et au nombre de gestes qu'il coûte par morceau.

1. **U-01 Ne pas avoir à taguer.** Ce qui peut être déduit (tags existants, titre, artiste, règles, valeurs par défaut) est pré-rempli en suggestion.
2. **U-02 Une main, au pouce.** Toutes les commandes de tag sont dans la moitié basse de l'écran. La cover et les infos sont en haut : on les regarde, on ne les touche pas, sauf pour les gestes de lecture.
3. **U-03 Positions fixes.** Les valeurs ne bougent jamais d'un morceau à l'autre. Aucun réordonnancement automatique, même selon la fréquence d'usage, pour que le pouce y aille sans regarder.
4. **U-04 Un tap par décision.** Sur un champ à choix unique, un tap remplace la valeur précédente. Aucun champ n'oblige à ouvrir une liste.
5. **U-05 Rien qui interrompt.** Pas de fenêtre de confirmation, pas de bouton « enregistrer », pas de clavier, pas d'indicateur de chargement bloquant pendant le tag.
6. **U-06 Retour immédiat.** Un tap change l'affichage dès l'image suivante, avec une vibration distincte selon l'action.
7. **U-07 Tout est réversible.** Chaque action s'annule ; revenir au morceau précédent le montre tel qu'on l'a laissé.
8. **U-08 Suggestion et confirmation se distinguent au premier coup d'œil.** Une suggestion n'est jamais écrite dans un fichier tant qu'elle n'est pas validée.
9. **U-09 Sobriété.** Pas de texte d'aide permanent ni de décoration. Libellés courts, en majuscules pour les champs, comme dans les tags.
10. **U-10 Hors ligne d'abord.** Rien dans le tag ne dépend du réseau ; l'absence de réseau se signale discrètement, sans bloquer.
11. **U-11 Mesurer.** L'app mesure temps et taps par morceau (section 9) pour que chaque amélioration se prouve en secondes gagnées.
12. **U-12 Accessible.** Libellés VoiceOver sur chaque commande, respect du réglage « Réduire les animations », contrastes suffisants. L'écran Taguer peut défiler seulement si la taille du texte système est très grande ; c'est la seule exception à « sans scroller ».

## 9. App iOS : écrans et fonctionnalités

L'app a trois écrans : la Bibliothèque (écran d'accueil), l'écran Taguer (plein écran, au-dessus de la Bibliothèque) et les Réglages.

### 9.1 Navigation

- La Bibliothèque est l'écran d'accueil. L'écran Taguer s'ouvre en plein écran par-dessus, comme le lecteur d'Apple Musique, et se ferme en glissant vers le bas.
- Les Réglages s'ouvrent depuis la barre d'outils de la Bibliothèque.
- Pas de barre d'onglets : l'écran Taguer a besoin de toute la hauteur.
- Au lancement, si une session était en cours, l'app rouvre directement l'écran Taguer sur le dernier morceau de la file.

### 9.2 Écran Taguer (mode Complet)

```
┌───────────────────────────────┐
│ ⌄   Shatta à trier  312/1240 ⋯│
│ ┌────────┐  Titre du morceau  │
│ │        │  Artiste           │
│ │ COVER  │ 128 BPM · 8A · 3:42│
│ │        │  ● Modifié         │
│ └────────┘                    │
│ ▁▃▅▇▅▃▂▅▇▆▃▁▂▅▇▅▃  1:12 / 3:42│
│      ⏮        ▶        ⏭      │
├───────────────────────────────┤
│ GENRE   RAP FR  RAP US  POP   │
│         BOUYON SHATTA ZOUKOMPA│
│ COULEUR  ●   ●   ●   ●   ●    │
│ PAYS    FR   US   UK          │
│ TYPE    EXTEND  REMIX  EDIT   │
│ ATTRIB. NICHE  SEXY  TIKTOK   │
│         ELECTROPOP  AFRO      │
│         SINGALONG  ()         │
│ NOTE    ★  ★  ★  ★  ☆         │
└───────────────────────────────┘
```

**Budget de hauteur** (iPhone 6,1 pouces : 393 × 852 points, environ 759 points utiles)

| Zone | Hauteur |
| --- | --- |
| En-tête | 44 pt |
| Cover et infos | 112 pt |
| Forme d'onde et temps | 48 pt |
| Commandes de lecture | 52 pt |
| Espacements du haut | 24 pt |
| Panneau de tags (configuration de départ) | environ 440 pt sur 479 disponibles |

Si la configuration dépasse ce budget, l'écran passe en mode compact (cover 88 pt, pastilles 34 pt) et les Réglages l'indiquent au moment de l'ajout de la valeur.

**En-tête**

- Chevron à gauche : ferme l'écran.
- Au centre : nom de la file et position (« 312 / 1 240 ») ; un tap ouvre un menu pour changer de vue.
- Bouton « ⋯ » : mode Complet ou Passe rapide, passage automatique, point de départ, Préparer mon trajet.

**Bloc morceau**

- Cover de 112 pt à gauche, coins arrondis.
- À droite : titre (17 pt, semi-gras, 2 lignes maximum), artiste (15 pt, couleur secondaire), puis BPM · tonalité · durée (13 pt, chiffres à chasse fixe).
- Une ligne de statut discrète : Modifié, Envoyé, Appliqué, Conflit, ou « COMMENT actuel : … » si le COMMENT existant est non conforme.
- Une icône signale un morceau dont l'audio n'est pas disponible hors ligne.

**Gestes sur la cover**

- Tap : lecture ou pause.
- Double tap sur la moitié gauche ou droite : recule ou avance de 15 s (réglable).
- Glissement horizontal : morceau précédent ou suivant. Le contenu suit le doigt, revient avec un ressort, et le geste peut s'annuler en cours. Seuil : 30 % de la largeur ou une vitesse de plus de 500 pt/s.
- Glissement vers le bas sur l'en-tête ou la cover : ferme l'écran.

**Barre d'écoute**

- Forme d'onde sur toute la largeur ; la partie déjà lue est colorée.
- Un repère marque le point de départ.
- Un tap saute à l'endroit touché ; un glissement déplace la lecture, avec une petite vibration au passage du point de départ.
- Temps écoulé et durée totale à droite.

**Commandes de lecture** : précédent, lecture/pause (plus grand), suivant. « Précédent » va toujours au morceau précédent, jamais au début du morceau en cours.

**Panneau de tags**

- Une ligne par champ visible, dans l'ordre des réglages. Libellé à gauche : 11 pt, majuscules, couleur secondaire, largeur fixe de 60 pt.
- Pastilles de 38 pt de haut, avec une zone tactile de 44 pt. Retour à la ligne automatique, 3 lignes maximum par champ.
- **États** : vide (fond gris système) ; suggérée (contour, fond transparent) ; confirmée (fond plein de la couleur du texte principal, texte inversé).
- **Couleur** : ronds de 34 pt de la couleur elle-même. Confirmée = anneau extérieur et coche ; suggérée = anneau pointillé.
- **Choix unique** : un tap sur une autre valeur la remplace ; un tap sur la valeur confirmée l'enlève ; un tap sur une suggestion la confirme.
- **Choix multiple** : un tap ajoute ou enlève la valeur.
- **Note** : cinq étoiles de 40 pt ; un tap sur l'étoile n donne la note n ; un appui long sur la ligne efface la note.
- **Ajouter une valeur** : appui long sur le libellé du champ, petit champ texte en surimpression. C'est la seule exception à « pas de clavier ».

**Validation et passage au suivant**

- Le champ déclencheur (par défaut la Note) valide le morceau.
- Si tous les champs obligatoires ont une valeur, confirmée ou suggérée : les suggestions deviennent confirmées, vibration de succès, passage au morceau suivant en 150 ms au plus, bandeau « Annuler » pendant 3 s.
- Sinon : la note est enregistrée, les lignes manquantes clignotent deux fois (300 ms), vibration d'erreur, et l'app ne passe pas au suivant.
- Passage automatique désactivé : la note valide sans avancer ; on avance par swipe ou bouton.
- Quitter un morceau sans le valider garde les valeurs confirmées. Les suggestions restent des suggestions et ne sont pas écrites.
- « Annuler » rétablit l'état d'avant la validation et revient sur ce morceau.

**File**

- La file est figée à l'ouverture : c'est une liste d'identifiants. Un morceau validé ne disparaît pas de la file pendant la session, même s'il ne correspond plus au filtre.
- Option « Sauter les morceaux déjà complets », activée par défaut dans la vue « À compléter ».
- En fin de file : « Fin de la file », un bouton « Choisir une autre vue » et le récapitulatif de session.

### 9.3 Mode Passe rapide

- Choisi depuis « ⋯ », pour un seul champ (par exemple Couleur).
- Le haut de l'écran ne change pas (cover, forme d'onde, lecture). En bas : une grille de gros boutons de 64 pt de haut, sur 2 ou 3 colonnes, une par valeur.
- Un tap confirme la valeur et passe immédiatement au morceau suivant, avec le bandeau « Annuler ».
- File par défaut : les morceaux de la vue courante où ce champ est vide.

### 9.4 Mode Par artiste

- Onglet « Artistes » de la Bibliothèque : nom, nombre de morceaux, nombre de morceaux incomplets. Tri par défaut : le plus de morceaux incomplets en premier.
- L'artiste principal est le texte avant « feat. », « ft. », « featuring », « & » ou « , ». Les règles exactes se fixent après l'audit.
- Un tap sur un artiste ouvre une feuille avec les pastilles des champs marqués « par artiste » (par défaut Pays et Genre) et la liste compacte de ses morceaux ; un tap sur un morceau en lance l'écoute.
- Un tap sur une valeur l'applique à tous les morceaux de l'artiste qui n'ont pas encore de valeur confirmée pour ce champ.
- Option « Remplacer aussi les valeurs existantes », avec le nombre de morceaux touchés. L'ensemble forme une seule action annulable.

### 9.5 Bibliothèque

- **Recherche** : titre, artiste, album ; sans tenir compte des accents ni de la casse ; résultat en 50 ms au plus.
- **Onglets** : Morceaux | Artistes.
- **Filtres** : un bouton avec le nombre de filtres actifs ouvre une feuille. Pour chaque champ, des pastilles à sélection multiple (« ou ») et une option « vide ». Aussi : note minimale, BPM minimum et maximum, tonalité, statut, non tagués, incomplets, COMMENT non conforme, disponibles hors ligne, suggestions acceptées. Entre champs différents : « et ».
- Les filtres actifs restent visibles en pastilles supprimables sous la recherche, avec le nombre de résultats.
- **Tri** : artiste, titre, BPM, date d'ajout, note.
- **Ligne** : cover de 44 pt, titre, artiste, résumé des tags (point de couleur, genre, étoiles), statut ; 60 pt de haut.
- **Tap** sur une ligne : ouvre l'écran Taguer sur ce morceau, avec pour file la liste affichée.
- **Appui long** : menu Lire, Taguer, Télécharger pour hors ligne, Voir l'artiste.
- **Sélection multiple** : actions « Définir… » (un champ et une valeur pour toute la sélection) et « Télécharger ».
- **Vues enregistrées** : bouton « Enregistrer la vue » dans la feuille de filtres ; vues affichées en haut de la Bibliothèque. Vues créées d'office : À compléter, Non tagués, À appliquer, COMMENT à vérifier.
- **Mini-lecteur** en bas : cover, titre, lecture/pause, suivant ; un tap ouvre l'écran Taguer.
- **Synchronisation** : un indicateur discret (« 12 en attente d'envoi ») quand le réseau manque.

### 9.6 Réglages

- **Champs** : liste réordonnable. Pour chaque champ : nom, type, cible (GENRE, GROUPING, position 1 à 3 du COMMENT, Note), obligatoire, visible, valeur par défaut, déclencheur de validation, proposé « par artiste ».
- **Valeurs d'un champ** : ajouter, renommer, supprimer, réordonner, couleur, libellé affiché, alias. Renommer ou supprimer affiche le nombre de morceaux touchés ; supprimer propose de remplacer par une autre valeur ou de vider.
- **Format du COMMENT** : séparateur, jeton de position vide, aperçu avec un exemple.
- **Règles** : « Si \[champ\] = \[valeur\], alors suggérer ou appliquer \[champ\] = \[valeur\] » et « Si le titre contient \[motif\], alors … ». Activer, désactiver, ordonner, tester sur 20 morceaux avec aperçu.
- **Lecture** : point de départ (début, 25 %, partie la plus forte), durée du saut par double tap (10, 15 ou 30 s), passage automatique, sauter les morceaux indisponibles hors ligne.
- **Hors ligne et cache** : taille maximale (500 Mo, 1, 2 ou 5 Go), nombre de morceaux préchargés (5, 10 ou 20), Préparer mon trajet, espace utilisé, vider le cache.
- **Retours** : vibrations ; écran toujours allumé pendant une session.
- **Compte et synchronisation** : état, dernière synchronisation, modifications en attente, forcer la synchronisation, déconnexion.
- **Statistiques** : dernières sessions, export CSV.

### 9.7 Préparer mon trajet

- Une feuille : choisir une vue (ou la file courante) et un nombre de morceaux (25, 50, 100 ou tous). Elle affiche la taille estimée et l'espace libre.
- Le téléchargement continue en arrière-plan, même app fermée. La progression est visible et les lignes concernées portent une icône « disponible hors ligne ».
- Ces morceaux restent hors du cache automatique jusqu'à ce que l'utilisateur les retire, ou après 14 jours sans écoute (réglable).

### 9.8 Statuts dans l'interface

- Chaque ligne et l'écran Taguer montrent le statut du morceau : Modifié (pas encore envoyé), Envoyé (en attente d'application sur le Mac), Appliqué, Conflit, Erreur.
- Les statuts utilisent des symboles (SF Symbols), jamais des couleurs qui pourraient se confondre avec celles du GROUPING.
- Un filtre regroupe conflits et erreurs ; le détail affiche le message de l'outil Mac.

### 9.9 Sans réseau

- Un morceau sans audio disponible reste taguable. La barre d'écoute affiche « Audio indisponible hors ligne ».
- Si l'option est active, l'app passe d'elle-même au prochain morceau disponible de la file.
- Les modifications s'accumulent et partent au retour du réseau.

### 9.10 Mesures et récapitulatif de session

- Une session commence à la première lecture ou au premier tag, et se termine après 10 min sans action ou à la fermeture de l'écran Taguer.
- Mesures par morceau : temps passé, nombre de taps de tag, validé ou sauté, suggestions acceptées ou valeurs choisies à la main.
- À la fermeture de l'écran Taguer, si au moins 5 morceaux ont été validés : morceaux validés, temps moyen par morceau, taps moyens, comparaison avec la session précédente.
- Les mesures restent sur le téléphone ; elles s'exportent en CSV depuis les Réglages.

### 9.11 Premier lancement et états vides

- Connexion en un écran, avec « Se connecter avec Apple ».
- Premier chargement du catalogue avec progression. L'écran Taguer est utilisable dès que les premiers morceaux de la vue « À compléter » sont prêts.
- Liste vide après un filtre : « Aucun morceau » et un bouton « Effacer les filtres ».
- Erreur réseau : jamais de message bloquant, seulement l'indicateur discret de la Bibliothèque.

## 10. App iOS : lecture audio, streaming, préchargement et cache

La musique est lue en streaming depuis le cloud, comme sur Spotify ; l'app précharge les morceaux suivants et garde un cache plafonné pour traverser les zones sans réseau.

**Fichiers d'écoute** (préparés par l'outil Mac, section 12)

- Un fichier par morceau : AAC 96 kbps, stéréo, 44,1 kHz, en M4A avec l'index en tête de fichier (« faststart ») pour pouvoir sauter dans le morceau avant la fin du téléchargement.
- Volume homogène : normalisation à −14 LUFS intégrés (B-08). Les fichiers d'origine ne changent pas.
- Covers en deux tailles : 600 px pour l'écran Taguer, 150 px pour la liste.
- Poids : environ 2,9 Mo pour un morceau de 4 min, environ 14 Go pour 5 000 morceaux.

**Lecture**

- AVFoundation ; le morceau suivant est préparé à l'avance pour un enchaînement instantané (par exemple avec AVQueuePlayer).
- Session audio en catégorie « playback », mode d'arrière-plan « audio » activé.
- Écran verrouillé et Centre de contrôle : titre, artiste, cover, durée, position ; commandes lecture, pause, suivant, précédent, déplacement. Les AirPods passent au suivant ou au précédent.
- Appel ou Siri : pause, puis reprise si la lecture était en cours et que le système l'autorise. Écouteurs débranchés : pause.
- Point de départ : la position est réglée avant de lancer la lecture.
- Fondu d'entrée de 80 ms au démarrage et après chaque saut, pour éviter les clics. Pas de fondu enchaîné entre morceaux.

**Ordre de recherche d'un morceau**

1. Fichier local (trajet préparé ou cache) : lecture immédiate.
2. Sinon, streaming par URL signée, en lecture progressive : seuls les passages écoutés sont téléchargés.
3. Sinon, sans réseau : « Audio indisponible hors ligne », et saut au morceau suivant disponible si l'option est active.

Objectif : ne jamais télécharger deux fois le même morceau, en réutilisant pour le cache les données reçues en streaming. La solution technique est libre et doit être décrite dans `docs/decisions/`.

**Préchargement**

- Pendant la lecture, télécharger en entier les morceaux suivants de la file (10 par défaut) et garder les 2 précédents.
- Ordre de priorité : le morceau en cours s'il n'est pas local, puis le suivant, puis le suivant encore.
- En mode « données réduites » ou sur un réseau signalé comme coûteux : 2 morceaux seulement.
- Changement de file : annuler les préchargements devenus inutiles.
- Les miniatures de 150 px arrivent avec le catalogue ; les grandes covers arrivent avec le préchargement audio.

**Cache**

- Deux espaces séparés : le cache automatique, plafonné, qui efface d'abord les morceaux écoutés il y a le plus longtemps ; et les trajets préparés, épinglés et comptés à part.
- Emplacement : un dossier qu'iOS ne vide pas de lui-même (Application Support), exclu de la sauvegarde iCloud.
- Taille par défaut du cache automatique : 1 Go, soit environ 340 morceaux.

**URLs signées**

- Demandées par lots de 20 morceaux à la fonction `sign-urls` (section 13), valables 1 h.
- Une URL expirée est renouvelée sans interrompre la lecture.

**Forme d'onde** : elle arrive avec le catalogue (colonne `waveform`). Elle s'affiche donc sans réseau, même pour un morceau pas encore téléchargé.

## 11. Synchronisation et statuts des modifications

Le téléphone est le seul à modifier les tags ; le Mac lit les modifications, les applique et renvoie un statut, ce qui évite presque tous les conflits.

**Qui écrit quoi**

| Donnée | Écrite par | Lue par |
| --- | --- | --- |
| Catalogue : infos, audio, covers, Référence | Mac (import et application) | Téléphone |
| Valeurs des tags (`track_values`) | Téléphone | Mac |
| Journal (`changes`) | Téléphone ; le Mac ne change que le statut | Les deux |
| Configuration : champs, valeurs, règles, vues | Téléphone (Réglages) | Mac et téléphone |
| Statut d'application et Référence | Mac | Téléphone |

**Écriture locale**

- L'interface se met à jour immédiatement. L'écriture dans la base locale et dans le journal suit dans les 100 ms, en une seule transaction.
- Une modification affichée ne peut pas être perdue, même si l'app plante juste après (R7).

**Envoi**

- Déclencheurs : retour du réseau, passage de l'app en arrière-plan, toutes les 30 s pendant une session si des modifications attendent, et à la demande.
- Envoi par lots de 500 modifications au plus. Chaque modification porte un identifiant créé sur le téléphone, donc un renvoi ne crée jamais de doublon.
- Plusieurs modifications du même champ d'un même morceau peuvent être regroupées avant l'envoi ; la dernière l'emporte.
- Le téléphone affiche « Envoyé » dès que le cloud a confirmé la réception. Le calcul de ce qui est « à appliquer » est fait par le Mac au moment de l'aperçu.

**Réception**

- Le téléphone récupère tout ce qui a changé depuis son dernier passage (repère `updated_at`), par pages de 1 000 lignes : catalogue, configuration, statuts.
- Premier lancement : le catalogue complet (quelques Mo, formes d'onde comprises), puis les miniatures de covers en tâche de fond.
- Rafraîchissement : à l'ouverture de l'app, au retour du réseau, et en tirant la liste vers le bas.

**Statuts d'un morceau**

1. **Modifié** : une modification locale n'est pas encore envoyée.
2. **Envoyé** : le cloud l'a reçue ; elle n'est pas encore appliquée.
3. **Appliqué** : le Mac a écrit le fichier et mis à jour la Référence.
4. **Conflit** : le fichier a changé sur le Mac depuis la Référence, par exemple dans Serato ; rien n'a été écrit.
5. **Erreur** : l'écriture a échoué et le fichier a été restauré ; le message est affiché.

Un morceau appliqué puis modifié de nouveau repasse à « Modifié ».

**Conflits**

- **Entre appareils** : un seul appareil modifie les tags en version 1. Si une version Mac de l'app arrive, la modification la plus récente l'emporte, champ par champ.
- **Avec le fichier** : si un tag géré du fichier ne correspond plus à la Référence, le Mac ne l'écrit pas et marque le morceau en Conflit. Deux sorties possibles, sur commande explicite : garder la valeur du fichier (elle devient la valeur du morceau) ou imposer celle de l'app.
- **À l'import** : si un tag a changé dans le fichier et qu'aucune modification n'attend pour ce champ, la valeur du fichier devient la valeur du morceau (source « file ») et la nouvelle Référence. Si une modification attend, c'est un Conflit.

**Configuration**

- Une modification des Réglages se synchronise comme les tags. Le Mac compose toujours les tags avec la configuration la plus récente.
- Renommer une valeur rend « à appliquer » tous les morceaux qui l'utilisent ; l'app en affiche le nombre avant de confirmer.

## 12. Outil Mac : import, aperçu, application, annulation

L'outil `djtag` est une commande en ligne sur le Mac ; seules ses commandes `apply` et `rollback` touchent aux fichiers, toujours avec sauvegarde et vérification.

**Technique**

- Python 3.12 ou plus, projet géré avec uv.
- Dépendances : mutagen (tags), ffmpeg (conversion et analyse, via Homebrew), Chromaprint `fpcalc` (empreinte), boto3 (stockage R2 par l'API S3), un client Supabase ou Postgres, typer (commandes), rich (affichage).
- Configuration dans `~/.config/djtag/config.toml` : dossiers de musique, exclusions, qualité AAC, stockage, projet Supabase.
- Secrets dans le trousseau macOS, jamais dans le dépôt ni dans un fichier en clair.
- Dossier de travail `~/DJTag/` : `backups/`, `reports/`, `logs/`, `cache/`.
- Chaque commande accepte `--json` pour une sortie lisible par une IA. Codes de sortie : 0 succès, 1 erreur, 2 conflits, 3 refus de sécurité (par exemple Serato ouvert).

**Commandes**

| Commande | Rôle | Écrit dans les fichiers audio |
| --- | --- | --- |
| `djtag doctor` | Vérifie les outils, l'accès au cloud, l'espace disque, et que Serato est fermé | Non |
| `djtag audit` | Analyse la bibliothèque en lecture seule et écrit un rapport | Non |
| `djtag import` | Importe les nouveautés : tags, empreinte, AAC, covers, forme d'onde, point de départ, envoi au cloud | Non |
| `djtag status` | Résume les morceaux à appliquer, les conflits, les dernières applications | Non |
| `djtag diff` | Montre l'avant / après, morceau par morceau | Non |
| `djtag apply` | Écrit les tags, avec sauvegarde et vérification | Oui |
| `djtag rollback <id>` | Restaure les fichiers d'une application | Oui |
| `djtag resolve <morceau> --keep-file` ou `--keep-app` | Tranche un conflit dans la base | Non |
| `djtag backup-db` | Exporte la base cloud en JSON sur le Mac | Non |
| `djtag prune-backups` | Supprime les vieilles sauvegardes (garde les 10 dernières applications) | Non |

**`audit`** produit un rapport contenant :

- le nombre de fichiers par format, la taille totale, la répartition des durées ;
- les valeurs distinctes de GENRE, GROUPING et COMMENT, avec leur nombre ;
- la part de COMMENT conformes, incomplets et non conformes, avec 30 exemples de non conformes ;
- l'emplacement de la note (POPM et son propriétaire, RATE, RATING) et les versions ID3 ;
- la présence des données Serato par format, et les traces d'autres logiciels (par exemple Mixed In Key dans le COMMENT) ;
- les doublons probables (même empreinte) et les fichiers illisibles ;
- le nombre d'artistes et la structure des dossiers (premier niveau, nombre de morceaux) ;
- une estimation de l'espace cloud et du temps d'import.

Le rapport détaillé reste sur le Mac. Seule une synthèse chiffrée, sans titres de morceaux, va dans `docs/audit.md`.

**`import`**, dans l'ordre :

1. Parcourir les dossiers et ignorer les fichiers inchangés (taille et date de modification identiques).
2. Lire les tags, découper le COMMENT (section 6), remplir `source_tags`, la Référence et les valeurs (source « file »).
3. Calculer l'empreinte. Un fichier déplacé ou renommé (même empreinte, même durée à 1 s près) garde son identifiant ; seul son chemin change.
4. Convertir en AAC 96 kbps normalisé à −14 LUFS, avec l'index en tête de fichier. Sur Mac, l'encodeur AudioToolbox de ffmpeg (`aac_at`) est préféré.
5. Calculer la forme d'onde (environ 600 valeurs) et le point de départ : début de la première zone où l'énergie moyenne sur 4 s atteint 90 % du maximum du morceau, moins 2 s. Jamais dans les 10 derniers pour cent ; à défaut, 25 % de la durée. Réglage final sur 30 vrais morceaux, avec l'utilisateur.
6. Extraire la cover (dans les tags, sinon `cover.jpg` ou `folder.jpg` du dossier), en 600 et 150 px.
7. Envoyer l'audio et les covers au stockage, puis mettre à jour la base.
8. Travailler en parallèle (un processus par cœur), reprendre là où l'import s'est arrêté, afficher la progression et le temps restant. Relancé sans nouveauté, l'import ne fait rien.
9. Marquer les fichiers disparus comme supprimés ; leurs données sont gardées 30 jours.

**`diff`**

- Pour chaque morceau à appliquer : le chemin, puis pour chaque tag (GENRE, GROUPING, COMMENT, note) la valeur actuelle du fichier et la nouvelle.
- Les conflits sont listés à part, avec un total par type de changement.
- Sorties : tableau dans le terminal, Markdown, JSON.

**`apply`**, dans l'ordre :

1. Refuser si Serato DJ est ouvert (code 3), si l'espace disque manque pour les sauvegardes, ou si le cloud est inaccessible.
2. Sans l'option `--yes`, afficher le résumé du `diff` et demander confirmation.
3. Pour chaque morceau : relire le fichier, vérifier que l'empreinte correspond, comparer les tags gérés à la Référence. En cas de différence : Conflit, et passer au suivant.
4. Copier le fichier dans `~/DJTag/backups/<id-application>/` (copie clonée APFS quand c'est possible, quasi instantanée), avec un manifeste : chemin et empreinte SHA-256.
5. Écrire seulement les tags gérés, sans changer la version ID3 ni le reste des tags.
6. Vérifier : les tags gérés relus égalent la cible ; tous les autres cadres sont identiques octet par octet, données Serato comprises ; la partie audio a la même somme de contrôle.
7. Si la vérification échoue : restaurer aussitôt le fichier depuis la sauvegarde et marquer Erreur.
8. Si elle réussit : mettre à jour la Référence, le statut « appliqué » et le journal dans le cloud.
9. Écrire le rapport `~/DJTag/reports/<id>.md` et `.json`, puis rappeler la procédure de relecture dans Serato.

Options : `--dry-run` (tout sauf l'écriture), `--limit N`, `--track <id>`, `--yes`. Relancer `apply` sans nouvelle modification ne change rien.

**`rollback`**

- Restaure les fichiers d'une application depuis sa sauvegarde, après contrôle des empreintes ; possible pour un seul morceau.
- Remet ces morceaux à « à appliquer » et note l'annulation dans le journal.
- Refuse si Serato est ouvert.

**Pilotage par une IA**

- `CLAUDE.md` à la racine du dépôt décrit l'outil, ses commandes et les règles R1 à R8.
- La skill `.claude/skills/appliquer-tags/SKILL.md` enchaîne : `doctor`, `status`, `diff` (résumé montré à l'utilisateur), confirmation explicite de l'utilisateur, `apply --yes`, rapport, rappel de la relecture dans Serato.
- En cas de conflits, la skill les liste et demande à l'utilisateur quoi faire, morceau par morceau ou en bloc.
- Phrase type de l'utilisateur : « applique mes tags du train ».
- Garde-fou : une règle de Claude Code refuse toute commande qui vise les dossiers de musique, sauf `djtag` (section 16).

## 13. Cloud : base de données, stockage audio, sécurité, coûts

Supabase porte la base de données et la connexion, Cloudflare R2 stocke l'audio ; le stockage coûte moins de 0,10 $ par mois, et Supabase Pro (25 $ par mois) est recommandé une fois l'app utilisée au quotidien.

**Supabase**

- Postgres : tables de la section 6, migrations versionnées dans `backend/supabase/migrations/`.
- Connexion : « Se connecter avec Apple », un seul utilisateur. Sécurité au niveau des lignes (RLS) sur toutes les tables : chaque ligne n'est accessible qu'à son propriétaire.
- Fonction `sign-urls` : reçoit des identifiants de morceaux, vérifie l'utilisateur et renvoie des URLs R2 signées valables 1 h. Les clés R2 sont rangées dans les secrets de Supabase.
- L'outil Mac utilise une clé de service rangée dans le trousseau du Mac, jamais dans l'app ni dans le dépôt.
- Le plan gratuit met le projet en pause après une semaine d'inactivité et n'a pas de sauvegarde automatique ; le plan Pro, à partir de 25 $ par mois, ne se met jamais en pause et garde des sauvegardes quotidiennes pendant 7 jours ([tarifs Supabase](https://supabase.com/pricing)).
- **Recommandation** : plan gratuit pendant le développement, plan Pro dès l'usage quotidien, pour que la synchronisation ne soit jamais bloquée. Dans tous les cas, `djtag backup-db` exporte la base chaque semaine sur le Mac.

**Cloudflare R2**

- Bucket privé `djtag-audio`, sans aucun accès public ; lecture uniquement par URLs signées.
- Organisation : `audio/<track_id>.m4a`, `covers/<track_id>_600.jpg`, `covers/<track_id>_150.jpg`.
- Les fichiers des morceaux supprimés sont effacés au bout de 30 jours (règle de cycle de vie).
- Deux clés d'accès : une en écriture pour le Mac, une en lecture seule pour la fonction `sign-urls`.

**Sécurité**

- L'audio est la musique personnelle de l'utilisateur : stockage privé, jamais partagé ni rendu public.
- L'app ne contient que la clé publique de Supabase, prévue pour être embarquée.
- Toutes les communications passent en HTTPS.

**Coûts estimés** (tarifs consultés le 8 octobre 2026)

| Poste | Volume | Coût |
| --- | --- | --- |
| Apple Developer Program | 1 abonnement | 99 USD par an, ou l'équivalent en monnaie locale ([Apple](https://developer.apple.com/support/compare-memberships)) |
| R2, stockage | Environ 15 Go (audio et covers) | 10 Go gratuits, puis 0,015 $ par Go et par mois : environ 0,08 $ par mois |
| R2, lectures et téléchargements | Moins de 10 millions de lectures par mois | 0 $ : sortie de données gratuite, 10 millions de lectures gratuites par mois |
| R2, envois | Environ 15 000 fichiers à l'import | 0 $ : 1 million d'écritures gratuites par mois |
| Supabase | Base de quelques dizaines de Mo | 0 $ en gratuit, 25 $ par mois en Pro |

Tarifs R2 : [documentation Cloudflare](https://developers.cloudflare.com/r2/pricing/).

## 14. Exigences de performance et de fiabilité

Chaque cible ci-dessous est mesurée sur un iPhone réel en phase 8 ; une cible manquée bloque la livraison de la version 1.

| Mesure | Cible | Comment mesurer |
| --- | --- | --- |
| Retour visuel d'un tap | Image suivante : 16 ms à 60 Hz, 8 ms à 120 Hz | Instruments, Animation Hitches |
| Passage au morceau suivant préchargé (image et son) | 150 ms au plus | Mesure intégrée à l'app |
| Démarrage d'un morceau en cache | 300 ms au plus | Mesure intégrée à l'app |
| Démarrage d'un morceau en streaming, en 4G | 2 s au plus | Network Link Conditioner, profil 4G |
| Ouverture de l'app jusqu'à l'écran Taguer utilisable | 1,5 s au plus | Instruments, App Launch |
| Filtre ou recherche sur 5 000 morceaux | 50 ms au plus | Test de performance automatisé |
| Défilement de la liste | Aucune saccade, 120 images/s sur écran ProMotion | Instruments, Animation Hitches |
| Écriture locale d'une modification | 100 ms au plus, et survit à un plantage | Test automatisé |
| Envoi après le retour du réseau | 10 s au plus | Test manuel en mode avion |
| Données mobiles | Environ 3 Mo par morceau écouté en entier | Réglages iOS, données cellulaires |
| Modifications perdues | 0 | Tests de plantage pendant l'écriture |
| Fichiers abîmés, données Serato modifiées | 0 | Vérification automatique de `apply` et tests |
| `apply` relancé sans nouvelle modification | Aucune écriture | Test automatisé |
| Sessions sans plantage | 99,5 % au moins | Rapports de plantage TestFlight |

La batterie est surveillée pendant une session de 2 h (écoute, tag, écran allumé) : aucun travail inutile en arrière-plan, aucune animation qui tourne sans raison.

## 15. Design visuel, animations et retours haptiques

Le design suit les principes d'Apple et la skill apple-design d'Emil Kowalski, appliqués en SwiftUI natif : sobre, physique et immédiatement réactif.

**Références**

- Apple Human Interface Guidelines.
- Skill `apple-design` d'emilkowalski/skills : principes d'interface et de mouvement fluide tirés des conférences WWDC, rédigés pour le web. On applique ses principes (retour immédiat, gestes interruptibles, ressorts, retenue, typographie) avec leurs équivalents SwiftUI.
- Skill `emil-design-eng` du même dépôt, pour les finitions.
- Version minimale d'iOS : iOS 26 **\[À CONFIRMER\]**, pour profiter des matériaux système (Liquid Glass) dans les barres d'outils et le mini-lecteur.

**Couleurs**

- L'app suit le thème du système, clair ou sombre.
- Les seules couleurs vives de l'app sont celles du champ Couleur. Les sélections, la partie lue de la forme d'onde et les boutons utilisent la couleur du texte principal. Ainsi, aucune couleur d'interface ne se confond avec un tag.
- VERT, JAUNE, ROUGE, BLEU et VIOLET utilisent les couleurs système correspondantes, qui s'adaptent au mode sombre.

**Typographie** (SF Pro, police du système)

| Élément | Style |
| --- | --- |
| Titre du morceau | 17 pt, semi-gras |
| Artiste | 15 pt, couleur secondaire |
| BPM, tonalité, durée | 13 pt, chiffres à chasse fixe |
| Libellés des champs | 11 pt, semi-gras, majuscules, couleur secondaire |
| Pastilles | 15 pt, semi-gras |

La taille de texte du système est respectée ; au-delà d'un certain seuil, l'écran Taguer passe en mode compact puis défilant (U-12).

**Formes et espacements**

- Pastilles en forme de gélule ; cover aux coins arrondis de 10 pt.
- Zone tactile de 44 × 44 pt au minimum ; espacement de base de 8 pt.
- Icônes : SF Symbols uniquement.

**Animations**

- Uniquement des ressorts, toujours interruptibles : un geste en cours peut être repris ou inversé à tout moment.
- Durées courtes, de 150 à 300 ms. Aucune animation ne retarde une action.
- Pastille : léger rétrécissement (environ 0,96) au toucher, retour au relâcher ; le changement d'état est immédiat.
- Changement de morceau : la cover et les infos glissent horizontalement en suivant le doigt. Le panneau de tags reste immobile, seuls ses états changent par un fondu de 120 ms : les positions ne bougent jamais.
- Champ manquant : deux clignotements de la ligne, 300 ms en tout.
- Bandeau « Annuler » : entre par le bas avec un ressort, sort en fondu.
- Avec « Réduire les animations », les glissements deviennent des fondus.

**Retours haptiques** (désactivables)

| Action | Retour |
| --- | --- |
| Choisir ou retirer une valeur | Sélection, léger |
| Valider et passer au suivant | Succès |
| Champ obligatoire manquant | Erreur |
| Passage sur le point de départ en glissant | Sélection, léger |
| Annuler | Impact léger |

**Revue de design** : avant chaque livraison d'interface, capture de chaque écran en clair et en sombre, en texte normal et en grand texte, puis revue selon les principes apple-design et la skill SwiftUI (section 17).

## 16. Dépôt GitHub et organisation du projet

Un seul dépôt privé, `M``y``T``a``g``s``D``J`, contient l'app, l'outil Mac, le backend et la documentation ; Claude Code le crée en phase 0 avec l'outil `gh`.

**Création du dépôt**

1. Vérifier la connexion GitHub de l'utilisateur : `gh auth status`.
2. Créer le dépôt privé : ` gh repo create  ``MyTagsDJ``  --private `. Nom **\[À CONFIRMER\]**.
3. Créer l'arborescence ci-dessous, `README.md`, `CLAUDE.md`, `.gitignore`, et copier ce document dans `docs/cahier-des-charges.md`.
4. Protéger la branche `main` : pull request et intégration continue verte obligatoires.
5. Créer avec `gh` un jalon par phase de la section 18 et un ticket par tâche.
6. Créer les étiquettes : ios, mac-cli, backend, design, docs, bug.

**Arborescence**

```
MyTagsDJ/
├── CLAUDE.md                  règles et commandes pour l'IA
├── README.md
├── CHANGELOG.md
├── docs/
│   ├── cahier-des-charges.md
│   ├── avancement.md
│   ├── audit.md               synthèse chiffrée de l'audit
│   ├── serato.md              correspondances et procédure de relecture
│   └── decisions/             une note par décision
├── ios/
│   ├── DJTagger.xcodeproj
│   ├── DJTagger/
│   │   ├── App/
│   │   ├── Features/          Tag, Library, Settings, QuickPass, Artists
│   │   ├── Audio/             lecture, préchargement, cache
│   │   ├── Data/              base locale, modèles, requêtes
│   │   ├── Sync/              journal, envoi, réception
│   │   └── DesignSystem/      couleurs, typographie, pastilles, haptique
│   ├── DJTaggerTests/
│   └── DJTaggerUITests/
├── mac-cli/
│   ├── pyproject.toml
│   ├── src/djtag/             cli, scan, tags/, comment, audio, fingerprint,
│   │                          storage, db, apply, backup, serato
│   └── tests/fixtures/        fichiers de test synthétiques
├── backend/supabase/          config, migrations/, functions/sign-urls/
├── .claude/
│   ├── settings.json          permissions et garde-fous
│   └── skills/appliquer-tags/SKILL.md
├── .github/workflows/         ci-cli.yml, ci-ios.yml
├── .gitignore
└── .env.example
```

**Règles du dépôt**

- `.gitignore` : tous les formats audio (mp3, m4a, aac, wav, aif, aiff, flac, ogg), `.env`, données Xcode personnelles, `DerivedData`, sauvegardes et rapports.
- Fichiers de test : sons synthétiques générés par script, jamais de vraie musique. On y ajoute des données Serato copiées d'un vrai fichier : ce sont des métadonnées, pas de la musique.
- Branches `feat/…` et `fix/…`, messages de commit conventionnels (`feat:`, `fix:`, `docs:`, `test:`), fusion par squash.
- Versions taguées `ios-v0.x.y` et `cli-v0.x.y`, avec `CHANGELOG.md` à jour.
- Projet Xcode avec dossiers synchronisés, pour limiter les conflits dans le fichier projet. Swift 6 avec vérification stricte de la concurrence.
- Dépendances Swift par Swift Package Manager (par exemple GRDB et le client Supabase pour Swift).

**Intégration continue (GitHub Actions)**

- `ci-cli.yml`, à chaque push : ruff (style), pyright (types), pytest.
- `ci-ios.yml`, à chaque pull request vers `main` : build et tests sur simulateur, sur un runner macOS. Ces minutes coûtent plus cher, d'où un déclenchement limité aux pull requests.
- Aucun secret en intégration continue : les tests remplacent le cloud par des doublures.

**Garde-fous Claude Code** (`.claude/settings.json`)

- Règles de permission qui interdisent toute suppression, tout déplacement et toute écriture dans les dossiers de musique et dans le dossier `_Serato_`.
- Un hook avant chaque commande shell bloque toute commande qui mentionne un dossier de musique, sauf si elle commence par `MyTagsDJ`.
- `MyTagsDJ` `apply` et `MyTagsDJ` `rollback` demandent toujours la confirmation de l'utilisateur.

## 17. Skills, MCP et outils pour Claude Code

Deux serveurs MCP donnent à Claude Code des yeux sur Xcode, et quatre familles de skills lui apportent l'exigence SwiftUI et design ; tout s'installe en phase 0.

**Serveurs MCP**

| Outil | Sert à | Installation | Quand |
| --- | --- | --- | --- |
| [XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP) (Sentry) | Compiler, lancer et tester l'app sur simulateur et sur iPhone ; journaux, captures d'écran, interactions | `brew tap getsentry/xcodebuildmcp` puis `brew install xcodebuildmcp` ; ajout à Claude Code : `claude mcp add XcodeBuildMCP -- npx -y xcodebuildmcp@latest mcp` ; `xcodebuildmcp init` installe ses skills. Requiert macOS 14.5 et Xcode 16 au minimum | Toutes les phases iOS |
| Xcode MCP d'Apple (`xcrun mcpbridge`) | Recherche dans la documentation Apple et les vidéos WWDC, exécution de code Swift, rendu des aperçus SwiftUI, diagnostics | Xcode 26.3 ou plus. Dans Xcode : Réglages > Intelligence > Model Context Protocol, activer « Xcode Tools » ; Xcode doit être ouvert sur le projet. Puis `claude mcp add --transport stdio xcode -s user -- xcrun mcpbridge` | Phases 2, 5, 7, 8 |
| [Supabase MCP](https://supabase.com/docs/guides/ai-tools/mcp) | Schéma, migrations, requêtes, journaux et fonctions du projet Supabase | `claude mcp add --scope project --transport http supabase "https://mcp.supabase.com/mcp?project_ref=<id>"`, puis authentification avec `/mcp` dans Claude Code. Toujours limité au projet ; `read_only=true` hors travail sur le schéma. Outil de développement, jamais exposé dans l'app | Phases 3 à 6 |

**Skills**

| Skill | Sert à | Installation |
| --- | --- | --- |
| [emilkowalski/skills](https://github.com/emilkowalski/skills) : `apple-design`, `emil-design-eng`, `write-swift`, `break-ui`, `review-animations` | Principes Apple de design et de mouvement ; finitions ; Swift moderne (Swift 6, Swift Testing) ; test de l'interface avec des données extrêmes (titres très longs, listes vides) ; revue des animations. Plusieurs sont rédigées pour le web : on applique les principes, pas le code | `npx skills@latest add emilkowalski/skills` |
| [SwiftUI Expert](https://github.com/AvdLee/SwiftUI-Agent-Skill) (Antoine van der Lee) | Gestion d'état, performance, listes, feuilles, animations, Liquid Glass, accessibilité, analyse de traces Instruments | `/plugin marketplace add AvdLee/SwiftUI-Agent-Skill` puis `/plugin install swiftui-expert@swiftui-expert-skill` ; ou déclaration dans `.claude/settings.json` du dépôt |
| [Swift Concurrency Expert](https://github.com/AvdLee/Swift-Concurrency-Agent-Skill) et [Swift Testing Expert](https://github.com/AvdLee/Swift-Testing-Agent-Skill) | Concurrence Swift 6 sans erreurs ; tests avec Swift Testing | Selon le README de chaque dépôt |
| [Dimillian/Skills](https://github.com/Dimillian/Skills) (Thomas Ricouard) | `swiftui-ui-patterns`, `swiftui-performance-audit`, `swiftui-view-refactor`, `swiftui-liquid-glass`, `ios-debugger-agent` (via XcodeBuildMCP), `review-swarm`, `bug-hunt-swarm` | Écrites pour Codex, au même format : copier les dossiers choisis dans `.claude/skills/` |
| `skill-creator` (Anthropic) | Écrire la skill du projet `appliquer-tags` | Dépôt `anthropics/skills` |

**Outils en ligne de commande** (Homebrew ou npm) : `gh`, `uv`, `ffmpeg`, `chromaprint`, la CLI Supabase, `wrangler` (Cloudflare, pour créer le bucket R2).

**Références techniques** (lecture seule) : documentation de mutagen, [serato-tags](https://github.com/Holzhaus/serato-tags), [serato-tools](https://pypi.org/project/serato-tools/) pour reconnaître les données Serato pendant l'audit, Apple Human Interface Guidelines.

**Règles d'usage**

- Lire le `SKILL.md` de chaque skill avant de l'installer ; ne rien installer d'une source inconnue.
- Installer au niveau du projet quand c'est possible, pour que la configuration soit versionnée.
- Vérifier chaque outil en phase 0 : par exemple, compiler et lancer une app vide sur simulateur avec XcodeBuildMCP.
- Lister les outils installés et leur version dans `docs/outils.md`.
- Avant chaque pull request d'interface : revue par SwiftUI Expert et selon les principes apple-design. Avant chaque pull request sur `djtag apply` : revue par un agent séparé, qui n'a pas écrit le code.

## 18. Plan de réalisation par phases

Neuf phases, de la préparation aux finitions ; chacune se termine par des critères de validation que l'utilisateur approuve avant la suivante.

### Phase 0 — Préparation : outils, comptes, dépôt

- [ ] Vérifier ou installer : Xcode (dernière version), Homebrew, `gh`, `uv`, Python 3.12, `ffmpeg`, `chromaprint`, CLI Supabase, `wrangler`.
- [ ] Créer le dépôt GitHub privé et son arborescence (section 16), avec `CLAUDE.md` et ce cahier des charges.
- [ ] Installer et tester les MCP et skills de la section 17.
- [ ] Comptes : Apple Developer (inscription active), projet Supabase, R2 activé chez Cloudflare.
- [ ] Identifiant d'app iOS avec les capacités « Audio en arrière-plan » et « Se connecter avec Apple ».
- [ ] Ranger les secrets : trousseau du Mac, secrets Supabase, `.env.example` sans valeur réelle.

**Validation** : une app vide se lance sur l'iPhone de l'utilisateur ; l'intégration continue est verte ; tous les outils répondent.

### Phase 1 — Audit de la bibliothèque, en lecture seule

- [ ] Squelette de `djtag` avec `doctor` et `audit`.
- [ ] Lecture des tags des cinq formats.
- [ ] Rapport d'audit (section 12) et synthèse dans `docs/audit.md`.
- [ ] Relever l'emplacement réel de la note, le format réel du COMMENT, les valeurs existantes et les données Serato présentes.
- [ ] Trancher avec l'utilisateur les questions de la section 21 ; mettre à jour la configuration de départ (section 22).

**Validation** : l'utilisateur valide le rapport et les réponses ; la correspondance de la section 7 est confirmée sur ses vrais fichiers.

### Phase 2 — Prototype de l'écran Taguer

- [ ] App SwiftUI minimale avec des données factices et quelques fichiers audio fournis par l'utilisateur, non versionnés.
- [ ] Écran Taguer complet : mise en page, pastilles et leurs états, gestes, vibrations, validation, champ manquant, Annuler.
- [ ] Mesures de temps et de taps actives.
- [ ] Installation sur l'iPhone, test chronométré sur 50 morceaux, ajustements.

**Validation** : l'utilisateur tague 50 morceaux et valide l'ergonomie ; ces mesures servent de référence pour la suite.

### Phase 3 — Cloud

- [ ] Migrations Supabase (section 6), sécurité au niveau des lignes, connexion avec Apple.
- [ ] Fonction `sign-urls`.
- [ ] Bucket R2 privé, clés d'accès, règle de cycle de vie.
- [ ] Chargement de la configuration de départ des champs (section 22).

**Validation** : tests d'intégration verts ; un fichier test se lit sur l'iPhone par URL signée, y compris en sautant au milieu.

### Phase 4 — Import depuis le Mac

- [ ] Lecture des tags vers les champs, dont le découpage du COMMENT, avec ses tests.
- [ ] Empreinte, conversion AAC normalisée, covers, forme d'onde, point de départ, et suggestion du Type d'après le titre (B-21).
- [ ] Envoi au stockage, mise à jour de la base, import incrémental, reprise après erreur, travail en parallèle.
- [ ] Import d'essai sur 50 morceaux, vérification des points de départ et des covers avec l'utilisateur, puis import complet.

**Validation** : 100 % des morceaux importés, ou listés en erreur avec leur raison ; un second import ne fait rien ; les points de départ conviennent sur 30 morceaux.

### Phase 5 — App version 1

- [ ] Base locale, synchronisation du catalogue, connexion.
- [ ] Lecture : streaming, préchargement, cache, hors ligne, écran verrouillé, AirPods.
- [ ] Écran Taguer branché sur les vraies données.
- [ ] Bibliothèque : liste, recherche, filtres, tri, file, mini-lecteur.
- [ ] Réglages : champs, valeurs, format du COMMENT, lecture, cache.
- [ ] Journal des modifications, envoi, statuts.
- [ ] Préparer mon trajet.
- [ ] Distribution TestFlight interne.

**Validation** : un vrai trajet en train, avec passages en mode avion, sans perte ni blocage ; cibles de la section 14 mesurées.

### Phase 6 — Application des tags sur le Mac

- [ ] `status`, `diff`, `apply`, `rollback`, `resolve` ; refus si Serato est ouvert ; sauvegardes ; vérifications.
- [ ] Tests automatiques sur des fichiers de test de chaque format, avec données Serato.
- [ ] Essai sur une copie de 20 vrais morceaux, puis contrôle dans Serato : cue points, boucles, beatgrid, couleurs intacts ; nouveaux tags visibles.
- [ ] Procédure de relecture dans Serato décrite dans `docs/serato.md`.
- [ ] Skill `appliquer-tags`, `CLAUDE.md`, garde-fous de la section 16.
- [ ] Premier passage réel sur 50 morceaux, contrôle dans Serato, puis le reste.

**Validation** : données Serato intactes sur l'échantillon ; `rollback` testé ; « applique mes tags du train » fonctionne de bout en bout via Claude Code.

### Phase 7 — Accélérateurs

- [ ] Règles automatiques et leur éditeur ; les motifs du titre de la phase 4 y deviennent des règles modifiables.
- [ ] Suggestions par artiste.
- [ ] Mode Par artiste.
- [ ] Mode Passe rapide.
- [ ] Vues enregistrées et sélection multiple.
- [ ] Récapitulatif de session.

**Validation** : 3 taps par morceau au plus en moyenne sur une vraie session ; gain de temps mesuré par rapport à la référence de la phase 2.

### Phase 8 — Finitions et qualité

- [ ] Revue du design et des animations, accessibilité (VoiceOver, réduction des animations, contrastes, grand texte).
- [ ] Audit de performance avec Instruments : lancement, saccades, blocages, mémoire.
- [ ] Icône de l'app et écran de lancement.
- [ ] README court : importer, taguer, appliquer, annuler.
- [ ] Export hebdomadaire de la base (`djtag backup-db`) automatisé sur le Mac.

**Validation** : toutes les cibles de la section 14 atteintes ; aucun bug bloquant ouvert.

### Plus tard

- Version Mac de l'app, avec raccourcis clavier (B-70).
- Création de crates Serato à partir des vues.
- Suggestion de genre par analyse audio.

## 19. Tests et contrôle qualité

Le code qui touche aux fichiers de l'utilisateur a la couverture de tests la plus forte ; aucune tâche n'est terminée sans tests verts et sans preuve visible du résultat.

**Tests automatiques**

| Partie | Ce qui est testé | Outil |
| --- | --- | --- |
| COMMENT | Composition, lecture, cas conformes, incomplets, non conformes ; aller-retour lecture puis écriture identique | pytest avec Hypothesis, et Swift Testing |
| Outil Mac, écriture | Pour chaque format : tags gérés changés, autres cadres identiques octet par octet, audio identique, version ID3 conservée | pytest, fichiers de test synthétiques avec données Serato |
| Outil Mac, sécurité | Refus si Serato est ouvert ; conflit détecté ; restauration après une vérification ratée ; `rollback` qui rend un fichier identique ; `apply` relancé sans effet | pytest |
| Outil Mac, import | Fichier déplacé ou renommé reconnu ; import relancé sans travail ; reprise après interruption | pytest |
| Règles et suggestions | Ordre des règles, suggestion contre valeur confirmée, valeurs par défaut | Swift Testing |
| Filtres et file | Logique « ou » et « et », filtres spéciaux, file figée, saut des morceaux complets | Swift Testing |
| Synchronisation | Renvoi sans doublon, regroupement des modifications, reprise après perte de réseau, survie à un plantage | Swift Testing |
| Cache | Plafond respecté, ordre d'effacement, trajets épinglés | Swift Testing |
| Cloud | Migrations, sécurité au niveau des lignes, fonction `sign-urls` | Supabase en local |
| Parcours de tag | Choisir des valeurs, noter, passer au suivant, champ manquant, Annuler | XCUITest |
| Performance | Filtre et recherche sur 5 000 morceaux | Tests de performance XCTest |

**Tests manuels**

1. **Train simulé** : Network Link Conditioner (3G, réseau très dégradé, coupure totale) et bascules en mode avion pendant une session de 50 morceaux.
2. **Contrôle dans Serato** sur une copie : cue points, boucles, beatgrid, couleurs et aperçu identiques avant et après ; nouveaux GENRE, GROUPING, COMMENT et note visibles après relecture.
3. **Session chronométrée** de 50 morceaux, comparée à la référence de la phase 2.
4. **Accessibilité** : parcours complet avec VoiceOver, grand texte, réduction des animations.

**Définition de « terminé »** pour chaque tâche

- Tests ajoutés ou mis à jour, tous verts en local et en intégration continue.
- Aucun avertissement de compilation, concurrence stricte de Swift 6 comprise.
- Pour une tâche d'interface : captures d'écran du simulateur jointes à la pull request (clair, sombre, grand texte).
- `docs/avancement.md` à jour ; décision notée dans `docs/decisions/` si le cahier des charges a été ajusté.
- Revue par un agent séparé pour toute modification de `apply`, `rollback`, de la synchronisation ou de l'écriture locale.

## 20. Risques et parades

Le risque principal est d'abîmer les données Serato de 5 000 morceaux ; il est couvert par quatre barrières successives : écriture minimale, vérification, sauvegarde, essai sur copie.

| Risque | Effet | Parade |
| --- | --- | --- |
| Écriture qui abîme les données Serato | Perte de cue points, boucles, beatgrids | N'écrire que les tags gérés ; vérification octet par octet ; sauvegarde avant écriture ; essai sur copie ; `rollback` |
| Serato ouvert pendant l'application, ou qui garde l'ancien tag en mémoire | Changements écrasés ou invisibles | Refus si Serato est ouvert ; procédure de relecture documentée et rappelée après chaque application |
| COMMENT existants hétérogènes (anciens formats, autres logiciels) | Mauvais découpage, valeurs perdues | Audit ; lecture stricte par valeurs connues ; statut « non conforme » ; jamais de remplacement silencieux |
| Note stockée ailleurs que prévu, ou version de Serato sans notes | Note invisible dans Serato | Décision en phase 1 (section 21) ; la note reste dans l'app tant que l'emplacement n'est pas validé |
| Fichiers déplacés ou renommés | Tags écrits au mauvais endroit, doublons | Empreinte acoustique et durée ; jamais d'écriture si l'empreinte ne correspond pas |
| Tags des WAV mal pris en charge | Tags non lus par Serato | Audit sur les WAV ; test dans Serato avant toute écriture en masse |
| Réseau du train | Lecture coupée, attente | Préchargement, trajets préparés, passage automatique au prochain morceau disponible |
| Projet Supabase gratuit mis en pause | Synchronisation bloquée | Passage au plan Pro dès l'usage quotidien ; export hebdomadaire de la base |
| Perte de la base cloud | Travail de tag perdu | Copie complète sur le téléphone ; export hebdomadaire sur le Mac ; sauvegardes Supabase en plan Pro |
| Suggestions fausses validées trop vite | Mauvais tags en masse | Style distinct des suggestions ; validation explicite ; source de chaque valeur enregistrée ; vue « suggestions acceptées » pour relecture |
| Volume très différent d'un morceau à l'autre | Réglages incessants, fatigue | Normalisation à −14 LUFS des fichiers d'écoute |
| Audio personnel dans un cloud | Fuite de fichiers | Bucket privé, URLs signées d'1 h, aucun lien public |
| Écran Taguer trop chargé si des valeurs s'ajoutent | Plus de « sans scroller » | Budget de hauteur, mode compact, avertissement dans les Réglages, libellés courts possibles |

## 21. Questions ouvertes et hypothèses par défaut

Seize points restent à trancher ; en attendant, l'IA applique l'hypothèse par défaut et le signale. Les questions 1 à 9 bloquent la phase 2 et se règlent pendant l'audit de la phase 1.

| N° | Question | Hypothèse par défaut | Tranchée par |
| --- | --- | --- | --- |
| 1 | Où est stockée la note de 1 à 5 aujourd'hui ? Serato DJ Pro est-il en version 4 ou plus ? | Serato 4 ou plus ; note écrite comme Serato l'écrit (POPM, RATE, RATING) | Audit et utilisateur |
| 2 | L'attribut vide s'écrit-il littéralement « () » ? | Oui, en position 3 | Utilisateur |
| 3 | Un morceau peut-il avoir plusieurs attributs ? | Non, un seul. Si oui : séparateur à définir, par exemple « SEXY/TIKTOK » | Utilisateur |
| 4 | Un Pays ou un Type vide s'écrit-il aussi « () » ? | Oui, pour garder toujours trois positions | Utilisateur |
| 5 | Une seule couleur (GROUPING) par morceau ? | Oui | Utilisateur |
| 6 | Listes complètes des Pays et des Types | Pays : FR, US, UK. Types : EXTEND, REMIX, EDIT. Complétées par les valeurs trouvées à l'audit | Audit et utilisateur |
| 7 | Champs obligatoires pour valider | Genre, Couleur, Pays, Type, Note ; Attribut a « () » par défaut | Utilisateur |
| 8 | Valeurs écrites exactement comme listées, en majuscules (« RAP FR ») ? | Oui | Utilisateur |
| 9 | Le COMMENT contient-il aujourd'hui d'autres informations (par exemple Mixed In Key) ? | Non | Audit |
| 10 | Morceaux rangés par dossiers de genre ou d'artiste ? | Inconnu ; utile pour pré-remplir | Audit |
| 11 | Où sont les dossiers de musique : disque interne ou externe, quel système de fichiers ? | Disque interne APFS. Sur un disque externe non APFS, les sauvegardes sont des copies complètes : prévoir l'espace | Utilisateur |
| 12 | Modèle d'iPhone et version d'iOS | iPhone de 6,1 pouces, iOS 26 minimum | Utilisateur |
| 13 | Versions de macOS et d'Xcode | Xcode 26.3 ou plus, pour le MCP d'Apple | Utilisateur |
| 14 | Nom de l'app et du dépôt | « DJ Tagger », dépôt `dj-tagger` | Utilisateur |
| 15 | Supabase Pro dès le départ ? | Gratuit pendant le développement, Pro dès l'usage quotidien | Utilisateur |
| 16 | Point de départ et qualité d'écoute par défaut | Partie la plus forte ; AAC 96 kbps normalisé | Tests des phases 4 et 5 |

## 22. Annexes

Ces annexes donnent la configuration de départ et les exemples de référence pour les tests ; elles sont mises à jour après l'audit de la phase 1.

### A. Configuration de départ des champs

À charger dans la base en phase 3. Les valeurs suivies de « … » dans la discussion (pays, types) seront complétées après l'audit.

```json
{
  "comment": { "separator": " ", "empty_token": "()" },
  "fields": [
    { "key": "genre", "name": "Genre", "kind": "single",
      "target": { "tag": "GENRE" }, "required": true, "visible": true,
      "artist_level": true,
      "options": ["RAP FR", "RAP US", "POP", "BOUYON", "SHATTA", "ZOUKOMPA"] },
    { "key": "couleur", "name": "Couleur", "kind": "single",
      "target": { "tag": "GROUPING" }, "required": true, "visible": true,
      "options": [
        { "value": "VERT", "color": "systemGreen" },
        { "value": "JAUNE", "color": "systemYellow" },
        { "value": "ROUGE", "color": "systemRed" },
        { "value": "BLEU", "color": "systemBlue" },
        { "value": "VIOLET", "color": "systemPurple" } ] },
    { "key": "pays", "name": "Pays", "kind": "single",
      "target": { "tag": "COMMENT", "slot": 1 }, "required": true, "visible": true,
      "artist_level": true,
      "options": ["FR", "US", "UK"] },
    { "key": "type", "name": "Type", "kind": "single",
      "target": { "tag": "COMMENT", "slot": 2 }, "required": true, "visible": true,
      "options": ["EXTEND", "REMIX", "EDIT"] },
    { "key": "attribut", "name": "Attribut", "kind": "single",
      "target": { "tag": "COMMENT", "slot": 3 }, "required": false, "visible": true,
      "default": "()",
      "options": ["NICHE", "SEXY", "TIKTOK", "ELECTROPOP", "AFRO", "SINGALONG", "()"] },
    { "key": "note", "name": "Note", "kind": "rating", "min": 1, "max": 5,
      "target": { "tag": "RATING" }, "required": true, "visible": true,
      "is_advance_trigger": true }
  ]
}
```

### B. Exemples de lecture du COMMENT

| COMMENT dans le fichier | Pays | Type | Attribut | Résultat |
| --- | --- | --- | --- | --- |
| FR EXTEND SEXY | FR | EXTEND | SEXY | Conforme |
| US REMIX () | US | REMIX | () | Conforme |
| fr extend sexy | FR | EXTEND | SEXY | Conforme ; réécrit en majuscules à la prochaine application |
| FR EXTEND | FR | EXTEND | vide | Incomplet ; « () » proposé en suggestion |
| UK EDIT TIKTOK BONUS | — | — | — | Non conforme (mot en trop) ; gardé tel quel |
| 8A - Energy 6 | — | — | — | Non conforme (autre logiciel) ; gardé tel quel |
| (vide) | vide | vide | vide | Incomplet |

### C. Règles de départ

| Condition | Action | Mode |
| --- | --- | --- |
| Le titre contient « extended » ou « extend » | Type = EXTEND | Suggérer |
| Le titre contient « remix » ou « rmx » | Type = REMIX | Suggérer |
| Le titre contient « edit » | Type = EDIT | Suggérer |
| Genre = RAP FR | Pays = FR | Suggérer |
| Genre = RAP US | Pays = US | Suggérer |

Les motifs du titre ignorent la casse et ne reconnaissent que des mots entiers (« edit » ne doit pas reconnaître « edition »).

### D. Volumes estimés

| Élément | Par morceau | Pour 5 000 morceaux |
| --- | --- | --- |
| Audio AAC 96 kbps (4 min en moyenne) | Environ 2,9 Mo | Environ 14 Go |
| Covers 600 px et 150 px | Environ 60 Ko | Environ 300 Mo |
| Forme d'onde | 600 octets | Environ 3 Mo |
| Ligne de catalogue et tags | Environ 2 Ko | Environ 10 Mo |
| Données mobiles par écoute complète | Environ 3 Mo | — |

## Sources

Pages consultées le 8 octobre 2026.

- [Serato DJ Pro 4.0.0, notes de version](https://serato.com/dj/pro/downloads/4.0.0)
- [Forum Mp3tag : les notes dans Serato 4.0](https://community.mp3tag.de/t/serato-4-0-now-supports-song-ratings/70326)
- [serato-tags : formats de fichiers](https://github.com/Holzhaus/serato-tags/blob/main/docs/fileformats.md)
- [serato-tools](https://pypi.org/project/serato-tools/)
- [Cloudflare R2 : tarifs](https://developers.cloudflare.com/r2/pricing/)
- [Supabase : tarifs](https://supabase.com/pricing)
- [Supabase : serveur MCP](https://supabase.com/docs/guides/ai-tools/mcp)
- [Apple : choisir une adhésion](https://developer.apple.com/support/compare-memberships)
- [XcodeBuildMCP](https://github.com/getsentry/XcodeBuildMCP)
- [Xcode MCP (`xcrun mcpbridge`), documentation Cursor](https://cursor.com/docs/integrations/xcode)
- [emilkowalski/skills](https://github.com/emilkowalski/skills)
- [SwiftUI Expert Skill](https://github.com/AvdLee/SwiftUI-Agent-Skill)
- [Dimillian/Skills](https://github.com/Dimillian/Skills)
