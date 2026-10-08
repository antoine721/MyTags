# 0001 — Backend : Cloudflare (D1 + Workers + R2) au lieu de Supabase

**Date** : 8 octobre 2026 · **Statut** : accepté par l'utilisateur

## Contexte

Le cahier des charges (sections 5 et 13) prévoit Supabase (Postgres, connexion Apple, fonction `sign-urls`) et Cloudflare R2 pour l'audio.

L'utilisateur précise que l'usage sera **intense pendant quelques mois** (environ 5 000 morceaux à taguer), puis **occasionnel ou nul** : taguer 50 nouveaux morceaux sur l'ordinateur lui convient. Il faut donc :

- aucun coût fixe mensuel ;
- aucun service qui tombe en panne après quelques semaines sans usage ;
- le moins de comptes et de secrets possible.

Le plan gratuit de Supabase met le projet en pause après environ une semaine sans activité. Il faut alors le réactiver à la main, et ce plan n'a pas de sauvegarde. Le plan Pro coûte 25 $/mois, disproportionné pour un usage temporaire.

## Choix

Tout chez Cloudflare :

| Rôle | Service |
| --- | --- |
| Base de données | D1 (SQLite), base `mytags` |
| API | Un Worker `mytags-api` (TypeScript), dans `backend/` |
| Audio et covers | R2, bucket privé `mytags-audio`, accessible uniquement par le Worker |

- L'iPhone et le Mac ne parlent qu'au Worker, en HTTPS, avec un jeton.
- L'audio est servi par le Worker avec les requêtes de plage (`Range`). Les URLs signées de la fonction `sign-urls` disparaissent : le jeton de l'appareil suffit.
- Le Mac envoie l'audio au Worker, qui l'écrit dans R2. Il n'y a donc pas de clé d'accès R2 à créer.

## Raisons

- **Coût** : 0 $/mois. D1 gratuit (5 Go, 5 millions de lignes lues et 100 000 écrites par jour), Workers gratuit (100 000 requêtes par jour), R2 à 10 Go gratuits puis 0,015 $/Go et par mois. Pour environ 15 Go, cela fait environ 0,08 $/mois, sans frais de sortie de données.
- **Jamais en pause**, même après des mois sans usage.
- **Sauvegardes incluses** : D1 Time Travel permet de restaurer la base à une date passée. `djtag backup-db` reste prévu.
- **Un seul compte, un seul outil** (`wrangler`) et un seul secret à ranger (le jeton administrateur).
- **Testable sans cloud** : le Worker et D1 tournent en local (Miniflare), donc toute l'API est couverte par des tests automatiques.
- Même moteur (SQLite) sur le téléphone et dans le cloud.

## Conséquences

- L'API est écrite à la main : environ 600 lignes, testées.
- Pas de sécurité au niveau des lignes : un seul utilisateur, et chaque requête est authentifiée par un jeton.
- La limite gratuite de 100 000 lignes écrites par jour suffit. L'import de 5 000 morceaux écrit environ 5 000 lignes, plus les index. Les écritures sont groupées : une requête SQL par lot, grâce à `json_each`.
- Une fois le stock tagué, l'utilisateur peut vider le bucket audio. Le coût tombe alors à 0 et la base est conservée.
