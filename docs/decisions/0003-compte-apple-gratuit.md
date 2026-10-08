# 0003 — Compte Apple gratuit : installation depuis Xcode, sans TestFlight

**Date** : 8 octobre 2026 · **Statut** : accepté par l'utilisateur

## Contexte

Le cahier des charges suppose un abonnement Apple Developer payant (TestFlight, capacités « Se connecter avec Apple »). L'utilisateur préfère éviter ce coût de 99 $/an.

## Choix

- L'app s'installe sur l'iPhone **depuis Xcode**, avec un compte Apple gratuit (« Personal Team »).
- Le profil d'installation gratuit **expire au bout de 7 jours**. Il suffit de relancer l'app depuis Xcode, iPhone branché ou sur le même Wi-Fi : environ 30 secondes par semaine. **Les données de l'app (tags, cache, file) sont conservées** lors d'une réinstallation par-dessus.
- L'app n'utilise **aucune capacité payante** : pas de « Se connecter avec Apple », pas d'iCloud, pas de notifications, pas d'App Groups.
- Capacités utilisées, toutes disponibles avec un compte gratuit :
  - mode d'arrière-plan « audio » (`UIBackgroundModes`) ;
  - téléchargements en arrière-plan (`URLSession` en arrière-plan) ;
  - trousseau (jeton) et caméra (scan du QR code).
- Pas de TestFlight. Le critère « Sessions sans plantage 99,5 % » se mesure avec les journaux de plantage de l'iPhone (Réglages › Confidentialité › Analyse), et non avec ceux de TestFlight.

## Conséquences

- L'identifiant de l'app (`PRODUCT_BUNDLE_IDENTIFIER`) et l'équipe de signature sont réglés dans un seul fichier, `ios/Config/Signing.xcconfig`.
- Le compte gratuit limite à 3 apps installées par appareil et à 10 identifiants d'app par semaine. Cela ne pose pas de problème ici.
- Si l'utilisateur prend plus tard le compte payant, il n'y a rien à changer dans le code : il suffit de changer d'équipe dans `Signing.xcconfig`.
