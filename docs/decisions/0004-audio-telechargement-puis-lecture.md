# 0004 — Audio : téléchargement complet puis lecture locale, avec préchargement

**Date** : 8 octobre 2026 · **Statut** : accepté

## Contexte

La section 10 demande de « ne jamais télécharger deux fois le même morceau, en réutilisant pour le cache les données reçues en streaming ». Elle laisse la solution technique libre.

## Choix

- Le lecteur ne lit **que des fichiers locaux**. Un morceau qui n'est pas encore local est téléchargé en entier (environ 3 Mo), en priorité maximale, puis lu.
- Le téléchargement passe par `URLSession`. Une fois terminé, le fichier rejoint directement le cache : **un morceau n'est jamais téléchargé deux fois**.
- Le **préchargement** télécharge le morceau en cours et les 10 suivants de la file. Il réduit à 2 en mode « données réduites » ou sur un réseau coûteux. Il garde les 2 précédents et annule ce qui n'est plus utile quand la file change.
- Pendant un téléchargement à froid, le bouton lecture affiche un anneau de progression discret, sans rien bloquer : on peut taguer pendant ce temps.
- « Préparer mon trajet » utilise une session `URLSession` d'arrière-plan, qui continue même app fermée.

## Raisons

- Le point de départ par défaut est la partie la plus forte, souvent au milieu du morceau. Un streaming progressif devrait de toute façon attendre l'arrivée de la moitié du fichier : il ne ferait presque rien gagner.
- Avec le préchargement, le morceau suivant est presque toujours déjà local. Le passage au suivant se fait sous les 150 ms visés.
- Lire un fichier local avec `AVPlayer` est la solution la plus fiable. Un chargeur de ressources personnalisé (`AVAssetResourceLoaderDelegate`) est réputé fragile, et il serait impossible à éprouver sans iPhone pendant le développement.
- Coût : un démarrage à froid prend environ 1 à 3 s en 4G pour 3 Mo, contre une cible de 2 s. C'est mesuré en phase 5. Si c'est trop lent, on ajoutera une lecture progressive pour les morceaux démarrés au début.
