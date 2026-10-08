# Installer l'app sur l'iPhone (compte Apple gratuit)

Ce document explique comment compiler l'app MyTags avec Xcode et l'installer sur votre iPhone, sans abonnement Apple Developer.

## Première installation

1. Sur l'iPhone, activer **Réglages › Confidentialité et sécurité › Mode développeur**, puis redémarrer quand l'iPhone le demande.
2. Sur le Mac, ouvrir `ios/MyTags.xcodeproj` dans Xcode 26.
3. Dans **Xcode › Réglages › Comptes**, ajouter votre identifiant Apple : une équipe « Personal Team » apparaît.
4. Ouvrir `ios/Config/Signing.xcconfig` et faire deux réglages :
   - `DEVELOPMENT_TEAM` : l'identifiant de votre équipe. On le trouve en sélectionnant la cible MyTags › Signing & Capabilities, en choisissant l'équipe, puis en recopiant son identifiant ; on peut aussi laisser vide et choisir l'équipe dans l'interface.
   - `APP_BUNDLE_ID` : un identifiant unique, par exemple `fr.<votre-nom>.mytags`.
5. Brancher l'iPhone (la première fois en câble), le choisir comme destination, puis ⌘R.
6. Sur l'iPhone, autoriser le développeur dans **Réglages › Général › VPN et gestion de l'appareil**.

## Toutes les semaines

Avec un compte gratuit, le certificat expire au bout de **7 jours** : l'app ne s'ouvre plus. Il suffit de la relancer depuis Xcode (⌘R), iPhone branché ou sur le même Wi-Fi.

- Vos tags, le cache audio et la file en cours sont conservés.
- Les modifications pas encore envoyées le sont aussi : elles partiront au prochain réseau.

## Connexion au cloud

Au premier lancement, l'app affiche un écran de connexion.

1. Sur le Mac, lancer `uv run djtag pair` : un QR code s'affiche.
2. Le scanner avec l'app. À défaut, copier le texte `mytags://pair?…`, l'envoyer sur l'iPhone (AirDrop, Notes), puis appuyer sur « Coller ».

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
| Bandeau « Annuler » | Tap, dans les 3 s | Revient au morceau, tags d'avant la validation |
| ⋯ | Tap | Passe rapide (un champ, gros boutons), passage automatique, point de départ, Préparer mon trajet |

Les AirPods et l'écran verrouillé passent au morceau suivant ou précédent.

## Hors ligne

- **Préparer mon trajet** (⋯ ou Bibliothèque) télécharge en Wi-Fi une vue ou la file. Le téléchargement continue en arrière-plan, même app fermée.
- Sans réseau, tout se tague normalement. Les modifications partent au retour du réseau ; un indicateur discret montre combien attendent.
