# Première installation, pas à pas

But : taguer de vrais morceaux sur l'iPhone, puis vérifier l'écriture des tags sur des **copies** (règle R4), sans toucher à la bibliothèque.

Durée : environ 1 h 30, dont la moitié de téléchargements qui tournent seuls. Les étapes 2 à 4 se font pendant que Xcode se télécharge.

Toutes les commandes se tapent dans le **Terminal** du Mac (Applications › Utilitaires › Terminal). Copiez-les ligne par ligne.

## 0. Vérifier avant de commencer (2 min)

| À vérifier | Où | Il faut |
| --- | --- | --- |
| Version de macOS | Menu Pomme › À propos de ce Mac | macOS 15.6 ou plus récent (exigé par Xcode 26) |
| Place libre sur le Mac | Réglages Système › Général › Stockage | 40 Go |
| Version d'iOS | iPhone : Réglages › Général › Informations | iOS 26 |
| Câble | — | Un câble qui relie l'iPhone au Mac |
| Carte bancaire | — | Demandée pour activer R2 chez Cloudflare (rien n'est débité dans l'offre gratuite) |

## 1. Lancer les téléchargements (5 min, puis ça tourne seul)

1. Sur le Mac, ouvrir l'**App Store**, chercher **Xcode**, cliquer sur **Obtenir**. Le téléchargement prend de 20 minutes à 1 heure.
2. Dans le Terminal, installer Homebrew s'il n'est pas déjà là (la commande `brew` répond) :

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

   À la fin, Homebrew affiche deux lignes « Next steps » à copier-coller : faites-le, puis fermez et rouvrez le Terminal.
3. Installer les outils :

   ```bash
   brew install uv ffmpeg chromaprint node git
   ```

## 2. Récupérer le projet (2 min)

```bash
cd ~
git clone https://github.com/antoine721/MyTags.git
cd ~/MyTags/mac-cli
uv sync
```

Le dépôt est privé : si `git clone` demande un identifiant, utilisez votre compte GitHub (mot de passe = un jeton créé sur github.com › Settings › Developer settings › Personal access tokens), ou installez GitHub Desktop et clonez `antoine721/MyTags` depuis l'application.

## 3. Le cloud Cloudflare (15 min)

1. Créer un compte gratuit sur [dash.cloudflare.com](https://dash.cloudflare.com) et valider l'adresse e-mail.
2. Dans le tableau de bord : **R2 Object Storage** › activer R2 (formulaire de paiement ; l'offre gratuite suffit).
3. Dans le tableau de bord : **Workers & Pages**. Si un sous-domaine `workers.dev` est demandé, en choisir un (par exemple votre prénom).
4. Dans le Terminal :

   ```bash
   cd ~/MyTags/backend
   bash scripts/setup.sh
   ```

   - Le navigateur s'ouvre pour autoriser l'accès à Cloudflare : accepter.
   - À la fin, le script affiche l'**adresse de l'API** (`https://mytags-api.<…>.workers.dev`) et un **jeton administrateur**, une seule fois. Gardez le Terminal ouvert pour l'étape suivante.
5. Connecter `djtag` au cloud :

   ```bash
   cd ~/MyTags/mac-cli
   uv run djtag login --api https://mytags-api.<…>.workers.dev
   ```

   Coller le jeton quand il est demandé : il est rangé dans le trousseau du Mac.

## 4. `djtag` et votre musique (15 min)

```bash
cd ~/MyTags/mac-cli
uv run djtag init --music "/chemin/vers/votre/musique"
uv run djtag doctor
```

- Le chemin s'obtient en glissant le dossier de musique depuis le Finder dans le Terminal.
- Plusieurs dossiers : répéter `--music "…"`.
- `doctor` doit afficher des coches vertes. Une ligne rouge dit quoi faire.

Puis l'audit, en **lecture seule** (rien n'est modifié) :

```bash
uv run djtag audit --summary ../docs/audit.md
```

À la fin, l'audit affiche le « propriétaire POPM le plus fréquent » et la commande à lancer pour que les notes (étoiles) s'écrivent comme Serato les lit, par exemple :

```bash
uv run djtag config set tags.popm_email '<valeur affichée>'
```

Lancez-la **avant** l'import. Si aucun propriétaire n'est affiché, passez : les notes resteront dans l'app sans être écrites dans les fichiers.

## 5. Importer 50 morceaux pour commencer (10 min)

```bash
uv run djtag import --limit 50
```

`djtag` lit les tags, prépare un fichier d'écoute léger et l'envoie dans le cloud. Vos fichiers ne sont pas modifiés. Le reste s'importera plus tard avec `uv run djtag import` (il reprend où il s'est arrêté).

## 6. L'app sur l'iPhone (20 min, une fois Xcode installé)

1. Ouvrir **Xcode** une première fois : accepter la licence et laisser installer les composants proposés.
2. **Xcode › Réglages… › Comptes** › bouton **+** › **Apple ID** : se connecter avec votre identifiant Apple.
3. Dans le Terminal :

   ```bash
   open ~/MyTags/ios/MyTags.xcodeproj
   ```

4. Dans la colonne de gauche, cliquer sur **MyTags** (l'icône bleue tout en haut), puis la cible **MyTags** › onglet **Signing & Capabilities** › **Team** : choisir « *Votre nom* (Personal Team) ».
5. Brancher l'iPhone au Mac. Sur l'iPhone : **Se fier à cet ordinateur** › code.
6. En haut de la fenêtre Xcode, choisir votre **iPhone** comme destination (à la place d'un simulateur).
7. Sur l'iPhone : **Réglages › Confidentialité et sécurité › Mode développeur** › activer › redémarrer › confirmer **Activer**. L'option n'apparaît qu'après avoir branché l'iPhone à Xcode.
8. Dans Xcode : **⌘R** (ou le bouton ▶). La première fois, Xcode prépare l'iPhone quelques minutes.
9. Si l'iPhone affiche « Développeur non approuvé » : **Réglages › Général › VPN et gestion de l'appareil** › votre identifiant › **Faire confiance**. Puis **⌘R** à nouveau.

L'app s'ouvre sur l'écran de connexion. Vous pouvez d'abord **Essayer avec des données de démonstration** pour prendre l'écran Taguer en main, puis en sortir par Réglages › Quitter la démonstration.

Avec un compte Apple gratuit, l'app cesse de s'ouvrir au bout de 7 jours : rebrancher l'iPhone et refaire **⌘R** (vos tags sont conservés).

## 7. Connecter l'app au cloud (2 min)

Sur le Mac :

```bash
cd ~/MyTags/mac-cli
uv run djtag pair
```

Un QR code s'affiche. Dans l'app, sur l'écran de connexion, le viser avec l'appareil photo (autoriser l'accès à la caméra). Les 50 morceaux apparaissent.

## 8. Taguer vite

- Ouvrir la vue **À compléter** : seuls les morceaux à finir défilent.
- Un tap sur une pastille choisit la valeur ; un second tap l'enlève.
- **La note valide le morceau et passe au suivant**, qui démarre tout seul. Si un champ obligatoire manque, il clignote.
- « Annuler » apparaît 3 secondes après chaque validation.
- Sur la pochette : tap = lecture/pause ; double tap à gauche ou à droite = −15 s / +15 s ; glisser = morceau suivant ou précédent.
- Pour aller encore plus vite sur un seul champ : **⋯ › Passe rapide** (gros boutons, un tap = valeur + morceau suivant).
- Avant le train : **⋯ › Préparer mon trajet**, en Wi-Fi, pour écouter hors ligne.

## 9. Vérifier l'écriture sur des copies (10 min, règle R4)

Quelques morceaux tagués suffisent. Sur le Mac, **Serato DJ fermé** :

```bash
cd ~/MyTags/mac-cli
uv run djtag diff
uv run djtag apply --copy-to ~/Desktop/MyTags-essai --limit 20
```

- `diff` montre ce qui serait écrit.
- `--copy-to` écrit les tags dans des **copies** placées dans `~/Desktop/MyTags-essai`. La bibliothèque et le cloud ne changent pas.
- Ouvrir Serato DJ, glisser le dossier `MyTags-essai` dans la bibliothèque, et comparer chaque copie à son original : cue points, boucles, beatgrid, couleurs, aperçu identiques ; nouveaux GENRE, GROUPING (couleur), COMMENT et note visibles.

Si tout est bon, la vraie écriture se fera ensuite, quand vous le demanderez : dans Claude Code, « applique mes tags du train » (sauvegarde automatique, annulable).

## Si ça bloque

| Message | Solution |
| --- | --- |
| Xcode : « Failed to register bundle identifier » ou « not available » | Ouvrir `ios/Config/Signing.xcconfig`, remplacer `fr.antoine721.mytags` par un identifiant à vous (par exemple `fr.votreprenom.mytags`), puis ⌘R |
| Xcode : « No Account for Team » | Refaire l'étape 6.2, puis choisir à nouveau la Team (6.4) |
| Xcode : « Developer Mode disabled » | Étape 6.7 |
| iPhone : « Développeur non approuvé » | Étape 6.9 |
| L'app ne s'ouvre plus après une semaine | Rebrancher l'iPhone, ⌘R dans Xcode |
| `setup.sh` : impossible de créer le bucket | Activer R2 (étape 3.2), puis relancer `bash scripts/setup.sh` |
| `djtag doctor` : fpcalc ou ffmpeg introuvable | `brew install chromaprint ffmpeg` |
| `djtag apply` : « Serato DJ est ouvert » | Quitter Serato DJ, relancer la commande |
| L'app n'a pas de son sur un morceau | Il se télécharge : le son démarre dès qu'il est là ; hors ligne, préparer le trajet avant |

Pour tout le reste : ouvrir Claude Code dans `~/MyTags` et décrire ce qui se passe.
