# 0005 — Modèle de valeurs : valeurs du fichier déduites de la Référence, journal comme seul canal d'écriture

**Date** : 8 octobre 2026 · **Statut** : accepté

## Contexte

La section 6 prévoit une table `track_values` qui contient toutes les valeurs de tous les morceaux, y compris celles lues dans les fichiers à l'import et les suggestions. Pour 5 000 morceaux et 6 champs, cela représente environ 30 000 lignes à écrire dès l'import. C'est proche de la limite gratuite de D1 (100 000 lignes écrites par jour, index compris).

## Choix

1. **Valeurs du fichier.** Elles ne sont pas stockées ligne par ligne : le téléphone et le Mac les **déduisent de la Référence** (`tracks.baseline`), avec le même algorithme de lecture, décrit dans `docs/modele-tags.md`. Des cas de test partagés garantissent que Python et Swift donnent le même résultat. Une valeur déduite du fichier compte comme **confirmée** (source `file`).
2. **`track_values` ne contient que les valeurs posées depuis l'app** : choix de l'utilisateur, suggestions validées, règles en mode « appliquer ».
3. **Les suggestions ne sont jamais envoyées au cloud.** Elles sont recalculées à la volée sur le téléphone : valeur par défaut, règles, artiste, titre.
4. **À la validation d'un morceau**, toutes ses valeurs (suggestions et valeurs du fichier) sont écrites dans `track_values`, avec leur source. Le morceau est ainsi normalisé : par exemple, « fr extend sexy » devient « FR EXTEND SEXY » à la prochaine application, comme le demande l'annexe B.
5. **Un morceau jamais touché dans l'app n'est jamais écrit** dans son fichier.
6. **Le journal (`changes`) est le seul canal d'écriture** des valeurs vers le cloud. Le téléphone envoie des modifications. Le Worker les enregistre et met à jour `track_values` dans la même transaction : la plus récente gagne, champ par champ. Le Mac utilise le même canal, par exemple pour `resolve --keep-file`.
7. **Synchronisation par numéro de révision.** Chaque ligne synchronisée porte un `rev`, compteur global du serveur incrémenté à chaque écriture, dans la même transaction. Le téléphone tire ce qui a changé avec le curseur `(rev, rowid)` de chaque table. Ce curseur évite tout problème d'horloge entre appareils.
8. **Les jetons de suppression logique** (`deleted_at`) sont conservés pour toutes les tables synchronisées.

## Raisons

- Environ 5 000 lignes écrites à l'import au lieu de 35 000.
- Renommer une valeur reste simple. L'ancienne valeur est ajoutée aux alias. Les morceaux qui l'utilisent deviennent « à appliquer », car la composition donne le nouveau texte, différent de la Référence.
- Le cloud ne contient que ce que l'utilisateur a décidé : une suggestion ne peut pas être écrite par erreur.
