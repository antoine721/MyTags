# Outils et comptes à installer

Ce document liste tout ce qu'il faut préparer, dans l'ordre. Comptez environ une heure la première fois, import de la bibliothèque non compris.

## Coûts

| Poste | Coût |
| --- | --- |
| Compte Apple (gratuit) | 0 € — l'app se réinstalle depuis Xcode tous les 7 jours (décision 0003) |
| Cloudflare D1 + Workers | 0 € (offre gratuite) |
| Cloudflare R2, environ 15 Go d'audio d'écoute | environ 0,08 $ par mois (10 Go gratuits, puis 0,015 $/Go) |
| GitHub (dépôt privé, intégration continue) | 0 € dans le quota gratuit |

Une fois les 5 000 morceaux tagués, vous pouvez vider le stockage audio pour revenir à 0 € (voir `docs/backend.md`).

## 1. Comptes

1. **Identifiant Apple** : celui de l'iPhone suffit, sans abonnement Apple Developer.
2. **Cloudflare** : créer un compte gratuit sur dash.cloudflare.com, puis activer **R2** dans le tableau de bord (menu R2).
   - R2 demande d'enregistrer une carte bancaire, même dans l'offre gratuite.
   - Pour ne jamais rien payer, ne pas dépasser 10 Go stockés ; MyTags n'utilise de toute façon que des opérations gratuites.
3. **GitHub** : rien à faire, le dépôt `antoine721/MyTags` existe déjà.

## 2. Sur le Mac

Versions minimales : macOS 15.6 ou plus récent et Xcode 26.

```bash
# Homebrew (si absent) : https://brew.sh
brew install uv ffmpeg chromaprint gh node
npm install -g wrangler        # outil Cloudflare
xcode-select --install          # outils en ligne de commande, si Xcode vient d'être installé
```

| Outil | Sert à |
| --- | --- |
| Xcode 26 (App Store) | Compiler l'app et l'installer sur l'iPhone |
| uv | Lancer `djtag` (Python 3.12 géré automatiquement) |
| ffmpeg | Fichiers d'écoute AAC, forme d'onde, point de départ (encodeur Apple `aac_at`) |
| chromaprint (`fpcalc`) | Empreinte acoustique, pour reconnaître les fichiers déplacés |
| node + wrangler | Créer et déployer le backend Cloudflare |
| gh | Accès GitHub en ligne de commande (facultatif) |
| Claude Code | Piloter `djtag` (« applique mes tags du train ») |

## 3. Le dépôt et `djtag`

```bash
git clone https://github.com/antoine721/MyTags.git && cd MyTags
cd mac-cli && uv sync
uv run djtag init --music "/Users/<vous>/Music/DJ"   # un --music par dossier de musique
uv run djtag doctor
```

Astuce : `uv tool install --editable .` dans `mac-cli/` rend la commande `djtag` disponible partout.

## 4. Audit de la bibliothèque (lecture seule)

```bash
uv run djtag audit --fingerprints --summary ../docs/audit.md
```

- Le rapport complet reste dans `~/DJTag/reports/` ; seule une synthèse sans titres va dans `docs/audit.md`.
- Regardez en particulier :
  - le propriétaire POPM le plus fréquent, à régler avec `uv run djtag config set tags.popm_email '<valeur>'` ;
  - les COMMENT non conformes ;
  - les clés de note des M4A et FLAC.

## 5. Backend Cloudflare (une seule fois)

```bash
cd backend
npm ci
npx wrangler login
./scripts/setup.sh         # crée la base D1, le bucket R2, le jeton administrateur, déploie
```

Le script affiche l'adresse de l'API et le jeton administrateur. Puis :

```bash
cd ../mac-cli
uv run djtag login --api https://mytags-api.<votre-compte>.workers.dev   # colle le jeton (rangé dans le trousseau)
uv run djtag import --limit 50     # essai sur 50 morceaux
uv run djtag import                # puis tout : reprend où il s'est arrêté
```

Détails, coûts et restauration : `docs/backend.md`.

## 6. L'app sur l'iPhone

Voir `docs/ios.md` : ouvrir `ios/MyTags.xcodeproj`, choisir son équipe personnelle, brancher l'iPhone, lancer. Puis, sur le Mac :

```bash
uv run djtag pair     # affiche un QR code à scanner dans l'app
```

## 7. Claude Code

Dans le dossier du dépôt, `claude`, puis « applique mes tags du train ».

- La skill `.claude/skills/appliquer-tags` enchaîne les commandes de `djtag` et demande toujours votre accord avant d'écrire.
- Le garde-fou `.claude/hooks/guard_music.py` empêche toute autre commande de toucher aux dossiers de musique.

### Outils conseillés pour développer (facultatifs)

| Outil | Installation |
| --- | --- |
| XcodeBuildMCP | `claude mcp add XcodeBuildMCP -- npx -y xcodebuildmcp@latest mcp` |
| Xcode MCP d'Apple | Xcode › Réglages › Intelligence › activer « Xcode Tools », puis `claude mcp add --transport stdio xcode -s user -- xcrun mcpbridge` |
| Skills SwiftUI | `/plugin marketplace add AvdLee/SwiftUI-Agent-Skill` puis `/plugin install swiftui-expert@swiftui-expert-skill` |

## Versions utilisées par le projet

| Composant | Version |
| --- | --- |
| Python | 3.12 ou plus (mutagen 1.47, typer, httpx, Pillow) |
| Swift | 6.2 (Xcode 26), iOS 26 minimum |
| GRDB | 7.6 ou plus |
| Node | 22 ; wrangler 4.148, vitest 4 |
