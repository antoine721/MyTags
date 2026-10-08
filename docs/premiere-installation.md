# Première installation, pas à pas

But : taguer de vrais morceaux sur l'iPhone, puis vérifier l'écriture des tags sur des **copies** (règle R4), sans toucher à la bibliothèque.

Durée : environ 1 h 30, dont la moitié de téléchargements qui tournent seuls. Les étapes 2 à 5 se font pendant que Xcode se télécharge.

Les commandes se tapent dans le **Terminal** du Mac (Applications › Utilitaires › Terminal), une ligne à la fois.

## 0. Vérifier avant de commencer (2 min)

| À vérifier | Où | Il faut |
| --- | --- | --- |
| Version de macOS | Menu Pomme › À propos de ce Mac | macOS 15.6 ou plus récent (exigé par Xcode 26) |
| Place libre | Réglages Système › Général › Stockage | 40 Go |
| Version d'iOS | iPhone : Réglages › Général › Informations | iOS 26 |
| Câble | — | Un câble qui relie l'iPhone au Mac |
| Carte bancaire | — | Demandée pour activer R2 chez Cloudflare (rien n'est débité dans l'offre gratuite) |
| Compte GitHub | — | Celui qui a accès au dépôt `antoine721/MyTags` |

## 1. Lancer le téléchargement de Xcode (2 min, puis ça tourne seul)

Sur le Mac : **App Store** › chercher **Xcode** › **Obtenir**. Comptez 20 minutes à 1 heure.

## 2. Les outils (10 min)

1. Installer Homebrew, si la commande `brew` n'existe pas encore :

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```

   À la fin, Homebrew affiche « Next steps » avec deux lignes à copier-coller : le faire, puis fermer et rouvrir le Terminal.
2. Installer les outils :

   ```bash
   brew install uv ffmpeg chromaprint node gh
   ```

## 3. Récupérer le projet (3 min)

Le dépôt est privé : on passe par l'outil GitHub `gh`.

```bash
gh auth login
```

Répondre : **GitHub.com** › **HTTPS** › **Yes** (authentifier Git) › **Login with a web browser**, puis valider le code dans le navigateur.

```bash
gh repo clone antoine721/MyTags ~/MyTags
cd ~/MyTags/mac-cli
uv sync
```

`uv sync` installe tout seul la bonne version de Python (3.13).

## 4. Le cloud Cloudflare (15 min)

1. Créer un compte gratuit sur [dash.cloudflare.com](https://dash.cloudflare.com) et valider l'adresse e-mail.
2. Tableau de bord › **R2 Object Storage** › activer R2 (formulaire de paiement ; l'offre gratuite suffit).
3. Tableau de bord › **Workers & Pages** : si un **sous-domaine `workers.dev`** est demandé, en choisir un (par exemple votre prénom). Sans lui, l'étape suivante s'arrête.
4. Dans le Terminal :

   ```bash
   cd ~/MyTags/backend
   bash scripts/setup.sh
   ```

   - Le navigateur s'ouvre pour autoriser l'accès à Cloudflare : accepter.
   - Si wrangler demande de confirmer les migrations : taper `y`, puis Entrée.
   - Le script attend que l'adresse réponde (une nouvelle adresse peut prendre quelques minutes).
   - À la fin, il affiche l'**adresse de l'API**, un **jeton administrateur** (une seule fois) et la commande suivante à copier.
5. Lancer la commande affichée, du type :

   ```bash
   cd ~/MyTags/mac-cli && uv run djtag login --api https://mytags-api.<…>.workers.dev
   ```

   Coller le jeton quand il est demandé (rien ne s'affiche pendant la saisie, c'est normal), puis Entrée. Il est rangé dans le trousseau du Mac.

## 5. `djtag` et votre musique (15 min)

```bash
cd ~/MyTags/mac-cli
uv run djtag init --music "/chemin/vers/votre/musique"
uv run djtag doctor
```

- Pour le chemin : taper `uv run djtag init --music ` puis glisser le dossier de musique depuis le Finder dans le Terminal.
- Plusieurs dossiers : répéter `--music "…"`.
- Si macOS demande si le Terminal peut accéder au dossier Musique : **Autoriser**.
- `doctor` doit afficher des coches vertes. Une ligne rouge dit quoi faire (par exemple, autoriser Terminal dans Réglages Système › Confidentialité et sécurité).

Puis l'audit, en **lecture seule** (rien n'est modifié) :

```bash
uv run djtag audit --summary ../docs/audit.md
```

À la fin, l'audit affiche le « propriétaire POPM le plus fréquent » et la commande à lancer pour que les notes (étoiles) s'écrivent comme Serato les lit :

```bash
uv run djtag config set tags.popm_email '<valeur affichée>'
```

Lancez-la **avant** l'import. Si aucun propriétaire n'est affiché, passez : les notes resteront dans l'app sans être écrites dans les fichiers.

## 6. Importer 50 morceaux pour commencer (10 min)

```bash
uv run djtag import --limit 50
```

`djtag` lit les tags, prépare un fichier d'écoute léger et l'envoie dans le cloud. Vos fichiers ne sont pas modifiés. Le reste s'importera plus tard avec `uv run djtag import` (il reprend où il s'est arrêté).

## 7. L'app sur l'iPhone (20 min, une fois Xcode installé)

1. Ouvrir **Xcode** une fois : accepter la licence ; s'il propose des composants (dont **iOS**), les cocher et installer.
2. **Xcode › Réglages… › Comptes** › **+** › **Apple ID** : se connecter avec votre identifiant Apple.
3. Ouvrir le projet :

   ```bash
   open ~/MyTags/ios/MyTags.xcodeproj
   ```

   Attendre la fin de « Resolving packages » en haut de la fenêtre. Si Xcode propose « Update to recommended settings », ignorer.
4. Brancher l'iPhone, le déverrouiller, toucher **Se fier** et entrer le code.
5. En haut de la fenêtre Xcode, choisir votre **iPhone** comme destination.
6. Sur l'iPhone : **Réglages › Confidentialité et sécurité › Mode développeur** › activer › redémarrer › **Activer**. L'option n'apparaît qu'après les étapes 4 et 5.
7. Dans Xcode, colonne de gauche : cliquer sur **MyTags** (icône bleue tout en haut) › cible **MyTags** › onglet **Signing & Capabilities** › **Team** : choisir « *Votre nom* (Personal Team) ».
8. **⌘R** (ou le bouton ▶). La première fois, Xcode prépare l'iPhone quelques minutes.
9. L'iPhone affiche « Développeur non approuvé » : **Réglages › Général › VPN et gestion de l'appareil** › votre identifiant › **Faire confiance**. Puis **⌘R** à nouveau.

L'app s'ouvre sur l'écran de connexion. Vous pouvez d'abord **Essayer avec des données de démonstration** pour prendre l'écran Taguer en main, puis en sortir par Réglages › Quitter la démonstration.

Avec un compte Apple gratuit, l'app cesse de s'ouvrir au bout de 7 jours : rebrancher l'iPhone et refaire **⌘R** (vos tags sont conservés).

## 8. Connecter l'app au cloud (2 min)

```bash
cd ~/MyTags/mac-cli
uv run djtag pair
```

Une image du QR code s'ouvre sur l'écran du Mac. Dans l'app, sur l'écran de connexion, autoriser la caméra et viser le code. Les 50 morceaux apparaissent.

À défaut : envoyer à l'iPhone la ligne `mytags://pair?…` affichée dans le Terminal (AirDrop ou Notes), la copier, puis toucher **Coller** dans l'app.

## 9. Taguer vite

- L'app s'ouvre sur la vue **À compléter** (seuls les morceaux à finir) ; le bouton **Taguer**, en bas à droite, lance l'écran Taguer en un tap.
- Un tap sur une pastille choisit la valeur ; un second tap l'enlève.
- **La note valide le morceau et passe au suivant**, qui démarre tout seul. Si un champ obligatoire manque, il clignote : dès que vous le remplissez, le morceau se valide sans retoucher la note.
- En fin de morceau, la lecture reprend au point de départ : rien ne change de morceau sans vous.
- « Annuler » apparaît 3 secondes après chaque validation.
- Sur la pochette : tap = lecture/pause ; double tap à gauche ou à droite = −15 s / +15 s ; glisser = morceau suivant ou précédent.
- Une valeur manque (par exemple un Type « ORIGINAL » pour les morceaux qui ne sont ni EXTEND, ni REMIX, ni EDIT) : **appui long sur le nom du champ** › Ajouter. Les champs obligatoires et leurs valeurs se règlent dans Réglages › Champs et valeurs.
- Un seul champ à remplir sur beaucoup de morceaux : **⋯ › Passe rapide** (un tap = valeur + morceau suivant).
- Avant le train : **⋯ › Préparer mon trajet**, en Wi-Fi, pour écouter hors ligne.

## 10. Vérifier l'écriture sur des copies (10 min, règle R4)

Quelques morceaux tagués suffisent. Sur le Mac, **Serato DJ fermé** :

```bash
cd ~/MyTags/mac-cli
uv run djtag diff
uv run djtag apply --copy-to ~/Desktop/MyTags-essai --limit 20
```

- `diff` montre ce qui serait écrit.
- `--copy-to` écrit les tags dans des **copies**, dans un nouveau dossier `~/Desktop/MyTags-essai/essai-…`. La bibliothèque et le cloud ne changent pas.
- Dans Serato DJ : créer un crate « Essai MyTags », y glisser ce dossier, et comparer chaque copie à son original (colonne Location pour les distinguer) : cue points, boucles, beatgrid, couleurs, aperçu identiques ; nouveaux GENRE, GROUPING (couleur), COMMENT et note visibles.
- Ensuite, retirer les copies de Serato, puis supprimer le dossier.

Si tout est bon, la vraie écriture se fera quand vous le demanderez : dans Claude Code, « applique mes tags du train » (sauvegarde automatique, annulable).

## Mettre à jour le projet plus tard

```bash
cd ~/MyTags && git pull
```

Si Git refuse à cause de `project.pbxproj` (modifié quand vous avez choisi la Team) : `git stash && git pull && git stash pop`.

## Si ça bloque

| Message | Solution |
| --- | --- |
| Xcode : « Failed to register bundle identifier » ou « not available » | Ouvrir `ios/Config/Signing.xcconfig`, remplacer `fr.antoine721.mytags` par un identifiant à vous (par exemple `fr.votreprenom.mytags`), puis ⌘R |
| Xcode : « No Account for Team » | Refaire l'étape 7.2, puis choisir à nouveau la Team (7.7) |
| Xcode : « Developer Mode disabled » | Étape 7.6 |
| iPhone : « Développeur non approuvé » | Étape 7.9 |
| L'app ne s'ouvre plus après une semaine | Rebrancher l'iPhone, ⌘R dans Xcode |
| `setup.sh` : sous-domaine `workers.dev` manquant | Étape 4.3, puis relancer `bash scripts/setup.sh` |
| `setup.sh` : impossible de créer le bucket | Activer R2 (étape 4.2), puis relancer le script |
| `djtag login` : connexion impossible | Attendre quelques minutes (adresse toute neuve), puis relancer |
| `djtag doctor` : lecture refusée sur le dossier de musique | Réglages Système › Confidentialité et sécurité › Fichiers et dossiers › autoriser Terminal |
| `djtag doctor` : fpcalc ou ffmpeg introuvable | `brew install chromaprint ffmpeg` |
| `djtag apply` : « Serato DJ est ouvert » | Quitter Serato DJ, relancer la commande |
| La caméra ne s'ouvre pas au moment de connecter l'app | Utiliser **Coller** (étape 8), ou viser le QR code avec l'app Appareil photo de l'iPhone |
| Pas de son sur un morceau | Il se télécharge : le son démarre dès qu'il est là ; avant le train, préparer le trajet en Wi-Fi |

Pour tout le reste : ouvrir Claude Code dans `~/MyTags` et décrire ce qui se passe.
