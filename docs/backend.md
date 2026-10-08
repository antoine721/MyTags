# Backend Cloudflare

Le backend de MyTags tient en trois services Cloudflare, tous gratuits pour cet usage (décision 0001) :

| Rôle | Service | Nom |
| --- | --- | --- |
| API | Worker (TypeScript, dossier `backend/`) | `mytags-api` |
| Base de données | D1 (SQLite) | `mytags` |
| Audio et covers | R2, bucket privé | `mytags-audio` |

L'iPhone et le Mac ne parlent qu'au Worker, en HTTPS, avec un jeton (décision 0002). Le Worker n'a qu'un secret, le **jeton administrateur** (`ADMIN_TOKEN`), utilisé par `djtag`. Les iPhone reçoivent chacun leur propre jeton avec `djtag pair`. Les routes sont décrites dans [`api.md`](api.md).

## Mise en place (une seule fois)

1. **Compte Cloudflare** : créez un compte gratuit sur <https://dash.cloudflare.com/sign-up>.
2. **Activer R2** : dans le tableau de bord, menu *R2 Object Storage*, activez R2. Cloudflare demande un moyen de paiement, même pour l'offre gratuite ; rien n'est facturé tant que vous restez sous 10 Go.
3. **Node.js 22 ou plus** sur le Mac : `brew install node`.
4. **wrangler** (l'outil en ligne de commande de Cloudflare) est installé avec le projet : `cd backend && npm ci`, puis `npx wrangler …`. Vous pouvez aussi l'installer pour tout le Mac avec `npm i -g wrangler`.
5. **Connexion** : `npx wrangler login` (le navigateur s'ouvre pour autoriser wrangler).
6. **Installation** : depuis la racine du dépôt,

   ```sh
   bash backend/scripts/setup.sh
   ```

   Le script :
   - vérifie la connexion (`wrangler whoami`) ;
   - crée la base D1 `mytags` si elle n'existe pas et écrit son identifiant dans `backend/wrangler.jsonc` (cet identifiant n'est pas un secret : vous pouvez le committer) ;
   - crée le bucket R2 `mytags-audio` s'il n'existe pas ;
   - applique les migrations de la base, puis déploie le Worker ;
   - crée le jeton administrateur s'il n'existe pas encore (il demande avant d'en changer) et l'enregistre comme secret du Worker ;
   - affiche l'adresse de l'API (`https://mytags-api.<sous-domaine>.workers.dev`) et le jeton.

7. **Connecter le Mac** : `djtag login --api <adresse>`, puis collez le jeton. Il est rangé dans le trousseau macOS. Le jeton n'est écrit dans aucun fichier : s'il est perdu, relancez le script et acceptez de le remplacer.

Le script peut être relancé sans risque : il ne recrée que ce qui manque.

**Mettre à jour le Worker** après une modification du code : `cd backend && npm run migrate:remote && npm run deploy`.

## Coûts

Pour une bibliothèque d'environ 5 000 morceaux, tout reste dans les offres gratuites, sauf le stockage R2 au-delà de 10 Go.

| Service | Offre gratuite | Au-delà |
| --- | --- | --- |
| D1 | 5 Go stockés ; 5 millions de lignes lues et 100 000 lignes écrites par jour | Les requêtes échouent jusqu'au lendemain (0 h UTC) : rien n'est facturé |
| Workers | 100 000 requêtes par jour ; 10 ms de processeur par requête | Idem |
| R2 | 10 Go stockés ; 1 million d'écritures et 10 millions de lectures par mois ; sortie de données toujours gratuite | 0,015 $ par Go et par mois |

Exemple : 15 Go d'audio et de covers coûtent environ 0,08 $ par mois. L'import de 5 000 morceaux écrit environ 5 000 lignes, et chaque écriture est groupée (une instruction SQL par table et par lot).

## Restaurer la base à une date passée

D1 garde l'historique de la base (Time Travel) : 7 jours avec l'offre gratuite, 30 jours avec l'offre payante.

```sh
cd backend
npx wrangler d1 time-travel info mytags --timestamp=2026-10-08T12:00:00Z     # vérifier le point choisi
npx wrangler d1 time-travel restore mytags --timestamp=2026-10-08T12:00:00Z  # restaurer
```

L'heure est en UTC. La restauration remplace toute la base, y compris les appareils et le compteur de révisions. Ensuite, refaites une synchronisation complète sur l'iPhone et sur le Mac : leurs repères de synchronisation sont plus récents que la base restaurée.

Pour garder un historique plus long, exportez la base en SQL (c'est ce que fait `djtag backup-db`) :

```sh
npx wrangler d1 export mytags --remote --output=mytags-$(date +%F).sql
```

## Vider le bucket audio (arrêter tous les coûts)

Une fois la bibliothèque taguée, l'audio d'écoute n'est plus utile. Le supprimer ramène le coût à 0 ; la base, les tags et les covers sont conservés (les covers tiennent largement dans les 10 Go gratuits).

```sh
cd backend
# Supprime tous les fichiers audio/ au bout d'un jour (règle de cycle de vie R2).
npx wrangler r2 bucket lifecycle add mytags-audio vider-audio audio/ --expire-days 1
```

Cloudflare supprime les fichiers dans les 24 heures qui suivent. Pour tout effacer, covers comprises, omettez `audio/`. Retirez ensuite la règle (`npx wrangler r2 bucket lifecycle remove mytags-audio --name vider-audio`) avant de réimporter de l'audio, sinon les nouveaux fichiers seront supprimés à leur tour. Une fois le bucket vide, vous pouvez aussi le supprimer : `npx wrangler r2 bucket delete mytags-audio`. La même opération existe dans le tableau de bord : *R2* → `mytags-audio` → *Settings* → *Object lifecycle rules*.

## Développement local et tests

Tout tourne sur le Mac, sans compte Cloudflare (Miniflare simule D1 et R2) :

```sh
cd backend
npm ci
npm test               # tests automatiques (Vitest, dans le moteur des Workers)
npm run typecheck      # vérification TypeScript
npm run migrate:local  # crée la base locale
echo 'ADMIN_TOKEN=dev-token' > .dev.vars   # jeton local (fichier ignoré par git)
npm run dev            # API sur http://localhost:8787
```

Exemple : `curl -H 'Authorization: Bearer dev-token' http://localhost:8787/v1/me`.

Organisation du code (`backend/src/`) : `index.ts` (routes), `router.ts`, `auth.ts` (jetons), `sync.ts` (`pull` et `push`), `admin.ts` (routes du Mac), `blobs.ts` (R2), `tables.ts` (description des colonnes), `json.ts` et `db.ts` (SQL groupé avec `json_each`, révisions), `validate.ts`. Le schéma est dans `backend/migrations/`.
