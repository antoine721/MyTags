# API du Worker `mytags-api`

Contrat entre le Worker Cloudflare (`backend/`), l'app iPhone (`ios/`) et l'outil Mac (`mac-cli/`). Le schéma des tables est dans `backend/migrations/0001_init.sql`.

## Généralités

- Tout passe en HTTPS, avec des corps JSON en UTF-8.
- Authentification : en-tête `Authorization: Bearer <jeton>`.
  - **Jeton administrateur** : secret `ADMIN_TOKEN` du Worker. Seul l'outil Mac l'utilise.
  - **Jeton d'appareil** : créé par `POST /v1/admin/devices`. Il donne accès à la synchronisation et à la lecture de l'audio et des covers. Le Worker n'en garde que l'empreinte SHA-256.
- Dates : ISO 8601 UTC avec millisecondes (`2026-10-08T12:00:00.000Z`).
- Erreurs : `{"error": "<code>", "message": "<texte>"}`, avec un statut HTTP 400, 401, 403, 404, 409, 413 ou 500.
- Colonnes JSON (`option_ids`, `aliases`, `condition`, `action`, `filters`, `sort`, `value`, `source_tags`, `baseline`, `old_value`, `new_value`) : elles sont échangées comme des objets JSON, jamais comme du texte.
- Booléens (`required`, `visible`, `archived`, `enabled`, `builtin`, `skip_complete`, `is_advance_trigger`, `artist_level`) : `true` ou `false`.

## Santé et identité

| Méthode | Chemin | Accès | Réponse |
| --- | --- | --- | --- |
| GET | `/v1/health` | Libre | `{"ok": true, "time": "…"}` |
| GET | `/v1/me` | Appareil ou admin | `{"role": "device" \| "admin", "device_id": "…" \| null}` |

## Synchronisation

### `POST /v1/sync/pull`

Corps de la requête :

```json
{ "cursors": { "tracks": {"rev": 0, "rowid": 0}, "fields": {"rev": 12, "rowid": 3} },
  "limit": 1000 }
```

- Seules les tables listées dans `cursors` sont renvoyées.
- Tables accessibles avec un jeton d'appareil : `tracks`, `fields`, `field_options`, `track_values`, `rules`, `saved_views`, `settings`.
- Le jeton administrateur donne en plus accès à `changes` et `apply_runs`.
- `limit` : 1 000 par défaut, 2 000 au maximum, par table.

Réponse :

```json
{ "tables": {
    "tracks": { "rows": [ … ], "cursor": {"rev": 57, "rowid": 812}, "has_more": true },
    "fields": { "rows": [], "cursor": {"rev": 12, "rowid": 3}, "has_more": false } },
  "server_rev": 57 }
```

Pour chaque table, les lignes sont triées par `(rev, rowid)` et ne contiennent que celles strictement après le curseur. Les lignes supprimées logiquement (`deleted_at` non nul) sont incluses. Le client rappelle la route tant qu'une table renvoie `has_more`.

### `POST /v1/sync/push`

```json
{ "device_id": "…",
  "changes": [
    { "id": "uuid", "track_id": "…", "field_id": "…",
      "old_value": {"option_ids": ["…"]},
      "new_value": {"option_ids": ["…"], "rating": null, "text": null},
      "source": "user", "created_at": "…" } ],
  "fields": [ {ligne complète} ], "field_options": [ … ], "rules": [ … ],
  "saved_views": [ … ], "settings": [ {"key": "…", "value": …, "updated_at": "…", "deleted_at": null} ] }
```

- 500 modifications au maximum, et 500 lignes de configuration au maximum par table.
- **Modifications** :
  - l'insertion est idempotente : un `id` déjà connu est ignoré ;
  - chaque modification met à jour `track_values` pour `(track_id, field_id)` si son `created_at` est supérieur ou égal à celui de la ligne en place (la plus récente gagne) ;
  - `new_value: null` supprime logiquement la ligne : le morceau reprend alors la valeur de son fichier ;
  - les modifications plus anciennes du même couple, encore au statut `sent`, passent à `superseded`.
- **Configuration** : insertion ou remplacement de la ligne entière si son `updated_at` est supérieur ou égal à celui en place.
- Réponse : `{"accepted_changes": ["uuid", …], "rev": 58}`. Une modification est acceptée dès qu'elle est enregistrée, même si une valeur plus récente l'emporte.

## Audio et covers

| Méthode | Chemin | Accès | Rôle |
| --- | --- | --- | --- |
| GET | `/v1/blobs/audio/<track_id>.m4a` | Appareil ou admin | Fichier d'écoute. Gère `Range` (réponse 206) et `If-None-Match` |
| GET | `/v1/blobs/covers/<track_id>_600.jpg` ou `_150.jpg` | Appareil ou admin | Covers |
| PUT | `/v1/admin/blobs/<clé>` | Admin | Envoi d'un fichier ; `Content-Type` conservé ; la clé doit commencer par `audio/` ou `covers/` |
| HEAD | `/v1/admin/blobs/<clé>` | Admin | Existence et taille |
| DELETE | `/v1/admin/blobs/<clé>` | Admin | Suppression |

## Administration (outil Mac)

| Méthode | Chemin | Corps | Rôle |
| --- | --- | --- | --- |
| POST | `/v1/admin/tracks` | `{"tracks": [ligne complète sans rev]}` (200 au maximum) | Insère ou remplace des morceaux |
| POST | `/v1/admin/tracks/patch` | `{"patches": [{"id": "…", …colonnes}]}` (500 au maximum) | Mise à jour partielle : chemin, Référence, statut d'application, suppression logique |
| POST | `/v1/admin/changes/mark` | `{"track_ids": […], "status": "applied", "apply_run_id": "…"}` | Passe les modifications `sent` de ces morceaux au statut donné |
| POST | `/v1/admin/apply-runs` | `{"run": {…}}` | Insère ou remplace une application |
| POST | `/v1/admin/devices` | `{"name": "iPhone"}` | Crée un appareil ; renvoie `{"device_id": "…", "token": "…"}` (le jeton n'est montré qu'une fois) |
| GET | `/v1/admin/devices` | — | Liste des appareils (sans jeton) |
| DELETE | `/v1/admin/devices/<id>` | — | Révoque un appareil |
| POST | `/v1/admin/config/reset` | `{"config": …}` | Charge une configuration complète (champs, valeurs, règles, vues, réglages), au format de `shared/default-config.json` |

## Limites et coûts

Avec le plan gratuit de Workers, une requête dispose de 10 ms de processeur au plus. Les routes ne font que du SQL groupé (une instruction par table et par lot, grâce à `json_each`) et de la copie de flux. Il n'y a aucun calcul lourd côté Worker.
