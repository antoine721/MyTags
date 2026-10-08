# API du Worker `mytags-api`

Contrat entre le Worker Cloudflare (`backend/`), l'app iPhone (`ios/`) et l'outil Mac (`mac-cli/`). Le schéma des tables est dans `backend/migrations/0001_init.sql`.

## Généralités

- Tout passe en HTTPS, avec des corps JSON en UTF-8.
- Authentification : en-tête `Authorization: Bearer <jeton>`.
  - **Jeton administrateur** : secret `ADMIN_TOKEN` du Worker. Seul l'outil Mac l'utilise.
  - **Jeton d'appareil** : créé par `POST /v1/admin/devices`. Il donne accès à la synchronisation et à la lecture de l'audio et des covers. Le Worker n'en garde que l'empreinte SHA-256.
- Dates : ISO 8601 UTC avec millisecondes (`2026-10-08T12:00:00.000Z`). Les `updated_at` et `created_at` envoyés au Worker doivent avoir exactement ce format (sinon 400), car « la plus récente gagne » les compare comme du texte.
- Erreurs : `{"error": "<code>", "message": "<texte>"}`, avec un statut HTTP 400 (`bad_request`), 401 (`unauthorized`), 403 (`forbidden`), 404 (`not_found`), 405 (`method_not_allowed`, avec l'en-tête `Allow`), 409 (`conflict`), 413 (`payload_too_large`), 416 (`range_not_satisfiable`) ou 500 (`internal`).
- Chaque lot écrit en une fois doit tenir dans 2 Mo de JSON (limite d'un paramètre D1) ; au-delà, 413 : il faut envoyer moins de lignes par requête.
- Toute écriture incrémente le compteur `rev` une seule fois : toutes les lignes écrites par une même requête partagent le même `rev`.
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
- `limit` : 500 par défaut, 1 000 au maximum (une valeur plus grande est ramenée à 1 000), par table.
- Un curseur `null` ou `{}` vaut `{"rev": 0, "rowid": 0}` (depuis le début).

Réponse :

```json
{ "tables": {
    "tracks": { "rows": [ … ], "cursor": {"rev": 57, "rowid": 812}, "has_more": true },
    "fields": { "rows": [], "cursor": {"rev": 12, "rowid": 3}, "has_more": false } },
  "server_rev": 57 }
```

Pour chaque table, les lignes sont triées par `(rev, rowid)` et ne contiennent que celles strictement après le curseur. Chaque ligne contient toutes les colonnes de la table, `rev` compris. Les lignes supprimées logiquement (`deleted_at` non nul) sont incluses. Le client rappelle la route tant qu'une table renvoie `has_more`, avec le `cursor` renvoyé (le même que celui envoyé si la page est vide).

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

- 500 modifications au maximum, et 500 lignes de configuration au maximum par table (sinon 413). Toutes les clés sont facultatives ; un envoi vide renvoie le `rev` courant sans rien écrire.
- Clés obligatoires d'une modification : `id`, `track_id`, `field_id`, `created_at`, `new_value` (qui peut valoir `null`). `new_value` contient `option_ids` (liste, `[]` par défaut), `rating` (entier ou `null`) et `text` (texte ou `null`). `source` vaut `user` par défaut.
- Le `device_id` du corps est ignoré : le Worker enregistre l'appareil du jeton, ou `mac` pour le jeton administrateur.
- **Modifications** :
  - l'insertion est idempotente : un `id` déjà connu est ignoré, et ne modifie pas `track_values` une seconde fois ;
  - chaque nouvelle modification met à jour `track_values` pour `(track_id, field_id)` si son `created_at` est supérieur ou égal à celui de la ligne en place (la plus récente gagne ; à égalité, la dernière reçue) : `option_ids`, `rating`, `text_value` (← `text`), `source`, `state = confirmed`, `updated_at = created_at`, `device_id` ;
  - `new_value: null` supprime logiquement la ligne (`deleted_at = created_at`, `option_ids = []`, `rating` et `text_value` à `null`) : le morceau reprend alors la valeur de son fichier ;
  - les modifications plus anciennes du même couple, encore au statut `sent`, passent à `superseded` (leur `rev` et leur `updated_at` changent).
- **Configuration** : insertion ou remplacement de la ligne entière si son `updated_at` est supérieur ou égal à celui en place (`settings` : par `key`). Une colonne absente prend sa valeur par défaut du schéma.
- Réponse : `{"accepted_changes": ["uuid", …], "rev": 58}`. Une modification est acceptée dès qu'elle est enregistrée, même si une valeur plus récente l'emporte.

## Audio et covers

| Méthode | Chemin | Accès | Rôle |
| --- | --- | --- | --- |
| GET, HEAD | `/v1/blobs/audio/<track_id>.m4a` | Appareil ou admin | Fichier d'écoute. Gère `Range` (réponse 206) et `If-None-Match` (réponse 304) |
| GET, HEAD | `/v1/blobs/covers/<track_id>_600.jpg` ou `_150.jpg` | Appareil ou admin | Covers |
| PUT | `/v1/admin/blobs/<clé>` | Admin | Envoi d'un fichier ; `Content-Type` conservé ; renvoie `{"key", "size", "etag"}` |
| HEAD | `/v1/admin/blobs/<clé>` | Admin | Existence (200 ou 404) et taille (`Content-Length`) |
| DELETE | `/v1/admin/blobs/<clé>` | Admin | Suppression (idempotente) ; renvoie `{"key", "deleted": true}` |

- Clé : `audio/<nom>` ou `covers/<nom>`, le nom n'utilisant que `A-Z a-z 0-9 . _ -` (sinon 400).
- `Range` : une seule plage, `bytes=a-b`, `bytes=a-` ou `bytes=-n` → 206 avec `Content-Range` et `Content-Length` ; plage hors du fichier → 416 avec `Content-Range: bytes */<taille>` ; plusieurs plages ou syntaxe inconnue → fichier entier (200).
- En-têtes : `ETag`, `Accept-Ranges: bytes`, `Last-Modified`, `Cache-Control: private, max-age=86400` pour l'audio et `private, max-age=0, must-revalidate` pour les covers (une cover peut être remplacée sous la même clé).
- 409 si le fichier est remplacé pendant sa lecture : il suffit de réessayer.
- Un envoi sans `Content-Length` (transfert par morceaux) est accepté, mais mis en mémoire avant l'écriture.

## Administration (outil Mac)

| Méthode | Chemin | Corps | Rôle |
| --- | --- | --- | --- |
| POST | `/v1/admin/tracks` | `{"tracks": [ligne complète sans rev]}` (200 au maximum) | Insère ou remplace des morceaux ; renvoie `{"upserted": n, "rev": …}` |
| POST | `/v1/admin/tracks/patch` | `{"patches": [{"id": "…", …colonnes}]}` (500 au maximum) | Mise à jour partielle : chemin, Référence, statut d'application, suppression logique ; renvoie `{"updated": n, "rev": …}` |
| POST | `/v1/admin/changes/mark` | `{"track_ids": […], "status": "applied", "from_status": "sent", "apply_run_id": "…", "up_to_rev": 57}` (1 000 morceaux au maximum) | Passe les modifications de ces morceaux qui sont au statut `from_status` au statut `status` ; renvoie `{"updated": n, "rev": …}` |
| POST | `/v1/admin/apply-runs` | `{"run": {…}}` | Insère ou remplace une application ; renvoie `{"id": "…", "rev": …}` |
| POST | `/v1/admin/devices` | `{"name": "iPhone"}` | Crée un appareil ; renvoie 201 `{"device_id": "…", "name": "…", "token": "…", "created_at": "…"}` (le jeton n'est montré qu'une fois) |
| GET | `/v1/admin/devices` | — | `{"devices": [{"id", "name", "created_at", "last_seen_at", "revoked_at"}]}` (sans jeton) |
| DELETE | `/v1/admin/devices/<id>` | — | Révoque un appareil (idempotent) ; renvoie `{"device_id": "…", "revoked_at": "…"}` |
| POST | `/v1/admin/config/reset` | `{"config": …}` | Charge une configuration complète (champs, valeurs, règles, vues, réglages), au format de `shared/default-config.json` ; renvoie `{"rev": …}` |

- `tracks` et `apply-runs` : le Worker fixe `updated_at` (heure du serveur) et `rev` ; `apply_status` vaut `aucun` par défaut. Les colonnes absentes d'une ligne complète valent `null` (ou leur valeur par défaut).
- `tracks/patch` : seules les colonnes présentes changent (`null` efface une colonne facultative). `id` désigne le morceau ; `updated_at` et `rev` sont fixés par le Worker ; une colonne inconnue ou `null` sur une colonne obligatoire donne 400. Un `id` inconnu est ignoré.
- `changes/mark` : `status` et `from_status` valent `sent`, `applied` ou `superseded` ; `from_status` vaut `sent` par défaut (annulation : `"from_status": "applied", "status": "sent"`). `apply_run_id` n'est enregistré que si la clé est présente (`null` l'efface). `up_to_rev` (facultatif) limite aux modifications de `rev` inférieur ou égal : le Mac y met le `server_rev` de la synchronisation qui a servi à l'application, pour qu'une modification arrivée pendant l'application reste `sent`. Les lignes modifiées reçoivent un nouveau `rev` et `updated_at`.
- `devices` : la révocation est immédiate sur l'instance qui la reçoit ; les autres instances du Worker gardent en cache un jeton valide 60 s au plus.
- `config/reset` : les cinq listes sont obligatoires (une liste absente donne 400, pour ne pas tout supprimer par erreur). Les lignes fournies sont écrites avec `updated_at` = maintenant ; les lignes de ces tables absentes de la configuration sont supprimées logiquement (`deleted_at` = maintenant, nouveau `rev`).

## Limites et coûts

Avec le plan gratuit de Workers, une requête dispose de 10 ms de processeur au plus. Les routes ne font que du SQL groupé (une instruction par table et par lot, grâce à `json_each`) et de la copie de flux. Il n'y a aucun calcul lourd côté Worker.
