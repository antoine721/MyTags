# Installer l'app sur l'iPhone (compte Apple gratuit)

Ce document explique comment compiler l'app MyTags avec Xcode et l'installer sur votre iPhone, sans abonnement Apple Developer.

## Première installation

Le détail, avec les captures d'écran à attendre et les erreurs fréquentes : `docs/premiere-installation.md`, étape 7.

1. Ouvrir Xcode une fois (licence, composants iOS), puis **Xcode › Réglages › Comptes** › **+** › Apple ID.
2. Ouvrir `ios/MyTags.xcodeproj` et attendre la fin de « Resolving packages ».
3. Brancher l'iPhone, le déverrouiller, **Se fier**, puis le choisir comme destination en haut de Xcode.
4. Sur l'iPhone : **Réglages › Confidentialité et sécurité › Mode développeur** › activer › redémarrer. L'option n'apparaît qu'après l'étape 3.
5. Cible **MyTags** › **Signing & Capabilities** › **Team** : « *Votre nom* (Personal Team) ». Rien d'autre à régler.
6. **⌘R**. Sur l'iPhone, autoriser le développeur dans **Réglages › Général › VPN et gestion de l'appareil**, puis **⌘R** à nouveau.

Si Xcode refuse l'identifiant de l'app, remplacer `APP_BUNDLE_ID` dans `ios/Config/Signing.xcconfig` par un identifiant à vous (par exemple `fr.votreprenom.mytags`).

## Toutes les semaines

Avec un compte gratuit, le certificat expire au bout de **7 jours** : l'app ne s'ouvre plus. Il suffit de la relancer depuis Xcode (⌘R), iPhone branché ou sur le même Wi-Fi.

- Vos tags, le cache audio et la file en cours sont conservés.
- Les modifications pas encore envoyées le sont aussi : elles partiront au prochain réseau.

## Connexion au cloud

Au premier lancement, l'app affiche un écran de connexion.

1. Sur le Mac, lancer `uv run djtag pair` : le QR code s'affiche dans le Terminal et en image.
2. Le scanner avec l'app (autoriser la caméra). À défaut, copier le texte `mytags://pair?…`, l'envoyer sur l'iPhone (AirDrop, Notes), puis appuyer sur « Coller ».

Le catalogue se télécharge (quelques Mo), puis les miniatures en Wi-Fi.

## Démonstration

« Essayer avec des données de démonstration » charge 48 morceaux inventés, avec des boucles de batterie générées sur le téléphone. Cela permet d'essayer l'écran Taguer avant d'avoir le cloud. Pour en sortir : Réglages › Quitter la démonstration.

## Utilisation

| Où | Geste | Effet |
| --- | --- | --- |
| Cover | Tap | Lecture / pause |
| Cover | Double tap à gauche / à droite | −15 s / +15 s |
| Cover | Glisser à gauche / à droite | Morceau suivant / précédent |
| En-tête ou cover | Glisser vers le bas | Fermer |
| Pastille | Tap | Choisir ; un tap sur la valeur choisie l'enlève ; un tap sur une suggestion (contour pointillé) la confirme |
| Étoiles | Tap | Note ; valide le morceau et passe au suivant si tous les champs obligatoires sont remplis |
| Libellé d'un champ | Appui long | Ajouter une valeur |
| Ligne des étoiles | Appui long | Effacer la note |
| Bandeau « Annuler » | Tap, dans les 3 s (10 s avec VoiceOver) | Revient au morceau, tags d'avant la validation |
| ⋯ | Tap | Passe rapide (un champ, gros boutons), Actualité, passage automatique, point de départ, Préparer mon trajet |
| Actualité : pochette | Glisser à gauche / à droite | `ARCHIVE` (plus d'actualité) / d'actualité, puis morceau suivant ; tap = lecture / pause |

Les AirPods et l'écran verrouillé passent au morceau suivant ou précédent.

## Tri « Actualité »

Bibliothèque › ⋯ › **Trier l'actualité** (ou ⋯ › **Actualité** sur l'écran Taguer) passe en revue la liste affichée, un morceau à la fois, comme Tinder :

- à gauche (ou bouton boîte d'archive) : plus d'actualité, `ARCHIVE` est ajouté à la fin du COMMENT ;
- à droite (ou bouton ✓) : d'actualité, rien n'est ajouté (un `ARCHIVE` déjà présent est retiré) ;
- les morceaux déjà triés sont sautés ; « Annuler » revient au morceau.

Comme les autres tags, c'est écrit dans les fichiers par `djtag apply` sur le Mac. Dans Serato, les crates « 🎶 GENRE 🎶 » excluent les COMMENT contenant ARCHIVE, et « 📦 ARCHIVE 📦 » les regroupe.

## Hors ligne

- **Préparer mon trajet** (⋯ ou Bibliothèque) télécharge en Wi-Fi une vue ou la file. Le téléchargement continue en arrière-plan, même app fermée.
- Sans réseau, tout se tague normalement. Les modifications partent au retour du réseau ; un indicateur discret montre combien attendent.
