# Modèle des tags : lecture, composition, statuts

Ce document est la référence des algorithmes partagés par l'outil Mac (`mac-cli/src/djtag/model/`) et par l'app (`ios/MyTagsKit/`). Les deux implémentations sont testées contre les mêmes cas, dans `shared/test-vectors/tag-model.json`. Ce fichier utilise des configurations simplifiées : l'identifiant d'une valeur y est `<clé du champ>:<value>`, et les valeurs attendues d'un champ multiple sont listées dans l'ordre `position`. Toute modification d'un algorithme se fait des deux côtés, avec un cas de test ajouté au fichier partagé.

## 1. Normalisation

- `norm(s)` : remplacer chaque suite d'espaces (espaces, tabulations, retours à la ligne) par une seule espace, retirer les espaces au début et à la fin, puis mettre en majuscules.
- Deux textes sont **équivalents** si leurs `norm` sont égaux. Les accents comptent : `É` ≠ `E`.
- Le séparateur du COMMENT est seulement « compacté » : chaque suite d'espaces devient une espace, sans retirer les espaces au début ni à la fin. Un séparateur `" "` reste donc `" "`.

## 2. Candidats d'un champ

Pour chaque champ, les textes reconnus sont, pour chaque valeur (y compris archivée, hors valeurs supprimées) :

- la `value` ;
- chacun des `aliases`.

Le `label` n'est jamais reconnu : il ne sert qu'à l'affichage.

## 3. Lecture de GENRE et GROUPING

- Tag absent ou vide (après `norm`) : aucune valeur.
- Champ à choix unique : la première valeur, dans l'ordre `position`, dont un candidat est équivalent au texte.
- Champ à choix multiple : le texte est découpé selon le séparateur multiple (réglage `multi.separator`, `/` par défaut). Chaque morceau doit correspondre à une valeur.
- Champ texte : le texte brut.
- Aucun candidat ne correspond : **valeur inconnue**. Le champ est considéré vide, et l'écran Taguer affiche « GENRE actuel : … ».

## 4. Lecture du COMMENT composé

Les entrées de l'algorithme sont :

- le texte du COMMENT ;
- les champs qui ciblent le COMMENT, triés par `target_slot` ;
- le séparateur ;
- le jeton de position vide (`()` par défaut).

Étapes :

1. Si le texte est absent ou vide après `norm`, résultat **incomplet**, toutes les positions vides.
2. `t = norm(texte)` et `sep = séparateur compacté`, en majuscules.
3. Exploration de toutes les façons de lire `t`. On parcourt les positions dans l'ordre. Pour chaque position, deux choix :
   - **lire la position** : un candidat du champ, ou le jeton vide, doit commencer exactement à la position courante. Il doit être suivi soit de la fin du texte, soit de `sep`. Pour un champ à choix multiple : une suite de candidats séparés par le séparateur multiple ;
   - **sauter la position** : elle est alors considérée absente.
4. Une lecture est **valide** si elle consomme tout le texte.
5. Parmi les lectures valides, on garde la meilleure selon ces critères, dans l'ordre :
   1. le plus grand nombre de positions lues ;
   2. à égalité, la position lue la plus tôt (comparaison position par position : « lue » l'emporte sur « sautée ») ;
   3. à égalité, le candidat le plus long à la première position où les lectures diffèrent.
6. Résultat :
   - **conforme** : toutes les positions sont lues. Le jeton vide compte comme lu.
   - **incomplet** : au moins une position est sautée.
   - **non conforme** : aucune lecture valide (mot inconnu ou en trop).
7. Pour une position lue avec le jeton vide :
   - si le champ possède une valeur dont un candidat est équivalent au jeton (par exemple l'Attribut « () »), la position prend cette valeur ;
   - sinon, la position est vide mais **explicitement** vide.

Un COMMENT non conforme ne donne aucune valeur. Il est conservé tel quel tant que l'utilisateur ne modifie aucune des positions.

## 5. Composition du COMMENT

- Positions : de 1 jusqu'au plus grand `target_slot` des champs qui ciblent le COMMENT. Une position sans champ s'écrit avec le jeton vide.
- Texte d'une position :
  - choix unique : la `value` de la valeur, exactement telle qu'elle est définie ;
  - choix multiple : les `value` triées selon `position` et jointes par le séparateur multiple ;
  - aucune valeur : le jeton vide.
- Le COMMENT est la jonction des positions par le séparateur, sans autre transformation.

## 6. Valeurs d'un morceau

Pour un morceau et un champ, la **valeur effective** se détermine ainsi :

1. Une ligne `track_values` existe et n'est pas supprimée : on prend sa valeur, confirmée, avec sa source (`user`, `default`, `rule`, `artist`, `title`, `file`). Une ligne avec une liste vide signifie « vidé volontairement ».
2. Sinon, si le fichier en donne une (sections 3 et 4, appliquées à la Référence) : valeur confirmée, de source `file`.
3. Sinon (sur le téléphone seulement) : une suggestion (section 9).
4. Sinon : vide.

La note se lit dans `baseline.rating`, un entier de 1 à 5 ou `null`.

## 7. Tags cibles et « à appliquer »

Pour un morceau, le **tag cible** de chaque tag géré se calcule ainsi :

| Tag | Règle |
| --- | --- |
| GENRE, GROUPING | Si le champ qui le cible n'a pas de ligne `track_values` : identique à la Référence. Sinon : choix unique → `value` ; choix multiple → jonction ; texte → texte ; vide → absent (`null`). |
| RATING | Comme ci-dessus, avec la note entière. Si le format du fichier n'est pas dans le réglage `rating.write_formats` : identique à la Référence. |
| COMMENT | Si aucun champ du COMMENT n'a de ligne `track_values` : identique à la Référence. Sinon : composition (section 5), où chaque position prend la valeur de sa ligne si elle existe. À défaut, elle prend la valeur lue dans la Référence si le COMMENT de la Référence n'est pas non conforme. Sinon, elle est vide. |

Un morceau est **à appliquer** si au moins un tag cible diffère de la Référence. Comparaison exacte des textes, mais `null` et `""` sont équivalents.

## 8. Complétude

- **Incomplet** : au moins un champ obligatoire et visible n'a pas de valeur confirmée (étapes 1 ou 2 de la section 6).
- **Non tagué** : aucun champ n'a de valeur confirmée.
- **Validable** (pour la validation sur le téléphone) : chaque champ obligatoire a une valeur confirmée ou suggérée.

## 9. Suggestions (téléphone)

Pour chaque champ sans valeur confirmée, sauf la note, la première source qui propose une valeur l'emporte :

1. **Règles actives**, dans l'ordre. Une condition `field_equals` porte sur la valeur effective, confirmée ou suggérée par une règle précédente. Une condition `title_contains` porte sur le titre (section 10). Une règle en mode « appliquer » est écrite comme valeur confirmée (source `rule`) dès qu'une action de l'utilisateur sur le morceau rend sa condition vraie, et au plus tard à la validation.
2. **Artiste**, pour les champs marqués « par artiste ». On regarde la valeur confirmée la plus fréquente parmi les autres morceaux du même artiste principal (section 11). Elle est suggérée si elle concerne au moins la moitié de ces morceaux.
3. **Valeur par défaut** du champ.

## 10. Recherche d'un motif dans le titre

- Le titre et le motif sont découpés en mots. Un mot est une suite de lettres ou de chiffres Unicode ; tout le reste sépare les mots.
- La comparaison ignore la casse.
- Le motif est reconnu si sa suite de mots apparaît telle quelle, consécutivement, dans celle du titre. Ainsi « edit » ne reconnaît pas « edition », et « radio edit » reconnaît « (Radio Edit) ».

## 11. Artiste principal

L'artiste principal est le texte avant le premier de ces séparateurs, sans tenir compte de la casse : ` feat. `, ` feat `, ` ft. `, ` ft `, ` featuring `, ` & `, `, `, ` x `, ` vs. `, ` vs `. On retire ensuite les espaces au début et à la fin.

Si le résultat est vide, l'artiste principal est l'artiste complet. Les règles seront affinées après l'audit.

## 12. Statut d'un morceau (téléphone)

Le premier cas qui s'applique l'emporte :

1. **Modifié** : au moins une modification locale n'est pas encore envoyée.
2. **Conflit** ou **Erreur** : `apply_status` vaut `conflit` ou `erreur`.
3. **Envoyé** : le morceau est à appliquer (section 7).
4. **Appliqué** : `apply_status` vaut `applique`.
5. Aucun statut.

## 13. Note : correspondance avec les fichiers

| Format | Emplacement | Lecture vers étoiles | Écriture |
| --- | --- | --- | --- |
| MP3, WAV, AIFF | POPM (propriétaire relevé à l'audit) | 0 → aucune ; 1–31 → 1 ; 32–95 → 2 ; 96–159 → 3 ; 160–223 → 4 ; 224–255 → 5 | 1, 64, 128, 196, 255 |
| M4A | Atome libre `----:com.apple.iTunes:RATE` (à confirmer par l'audit) | 0 → aucune ; 1–5 tel quel ; 6–100 → partie entière de (valeur + 10) ÷ 20, bornée entre 1 et 5 ; plus de 100 → comme POPM | Désactivée tant que l'audit n'a pas confirmé |
| FLAC | Commentaire Vorbis `RATING` (à confirmer par l'audit) | Comme M4A | Désactivée tant que l'audit n'a pas confirmé |
