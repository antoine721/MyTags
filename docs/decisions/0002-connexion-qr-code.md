# 0002 — Connexion de l'iPhone par QR code (pas de « Se connecter avec Apple »)

**Date** : 8 octobre 2026 · **Statut** : accepté

## Contexte

Le cahier des charges (9.11, 13) prévoit « Se connecter avec Apple » via Supabase. Le backend retenu est Cloudflare (décision 0001), et l'utilisateur garde un compte Apple **gratuit** (décision 0003). Or « Se connecter avec Apple » exige une capacité réservée aux comptes payants.

## Choix

- Le Worker connaît un **jeton administrateur** (secret `ADMIN_TOKEN`), rangé côté Mac dans le trousseau macOS.
- `djtag pair` crée un appareil côté Worker, qui renvoie un **jeton d'appareil** aléatoire de 32 octets. Le Worker n'en garde que l'empreinte SHA-256.
- `djtag pair` affiche un **QR code** dans le terminal. Il contient l'adresse de l'API et le jeton : `mytags://pair?api=<url>&token=<jeton>`.
- Au premier lancement, l'app propose un seul écran : scanner le code. Si la caméra est indisponible, on peut coller le texte. Le jeton est rangé dans le trousseau de l'iPhone.
- `djtag devices` liste les appareils ; `djtag devices revoke <id>` coupe l'accès d'un appareil perdu.
- Le jeton d'appareil ne donne accès qu'à la synchronisation et à la lecture de l'audio, jamais aux routes d'administration.

## Raisons

- Aucune capacité payante n'est nécessaire.
- La connexion se fait en une seule fois et prend 5 secondes.
- Un seul utilisateur : un jeton par appareil, révocable, suffit.
