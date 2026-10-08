#!/usr/bin/env bash
# One-time (and re-runnable) Cloudflare setup of the MyTags backend:
# D1 database, R2 bucket, ADMIN_TOKEN secret, remote migrations, deploy.
#
# Usage (from anywhere):  bash backend/scripts/setup.sh
# Requires Node.js 22+ and a Cloudflare account with R2 enabled.
# The admin token is printed once and never written to disk.
set -euo pipefail

DB_NAME="mytags"
BUCKET_NAME="mytags-audio"
CONFIG="wrangler.jsonc"

cd "$(dirname "$0")/.."

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mErreur : %s\033[0m\n' "$*" >&2; exit 1; }

command -v node >/dev/null || fail "Node.js est introuvable. Installez-le (brew install node) puis relancez."
command -v openssl >/dev/null || fail "openssl est introuvable."

if [ ! -x node_modules/.bin/wrangler ]; then
  say "Installation des dépendances (npm ci)"
  npm ci
fi
wrangler() { node_modules/.bin/wrangler "$@"; }

# --- Cloudflare login --------------------------------------------------------
say "Vérification de la connexion à Cloudflare"
if ! wrangler whoami --json >/dev/null 2>&1; then
  echo "Pas encore connecté : le navigateur va s'ouvrir pour autoriser wrangler."
  wrangler login
  wrangler whoami --json >/dev/null 2>&1 || fail "La connexion à Cloudflare a échoué."
fi
echo "Connecté."

# --- D1 database -------------------------------------------------------------
d1_id() {
  wrangler d1 list --json 2>/dev/null | node -e '
    let input = "";
    process.stdin.on("data", (chunk) => (input += chunk));
    process.stdin.on("end", () => {
      const list = JSON.parse(input || "[]");
      const db = list.find((item) => item.name === process.argv[1]);
      if (db) console.log(db.uuid);
    });' "$DB_NAME"
}

say "Base D1 « $DB_NAME »"
DB_ID="$(d1_id)"
if [ -z "$DB_ID" ]; then
  echo "Création de la base…"
  wrangler d1 create "$DB_NAME" --update-config=false >/dev/null
  DB_ID="$(d1_id)"
  [ -n "$DB_ID" ] || fail "La base $DB_NAME n'apparaît pas après sa création."
else
  echo "Elle existe déjà."
fi
echo "Identifiant : $DB_ID"

# Write the id into wrangler.jsonc (replaces the REPLACE_WITH_D1_DATABASE_ID placeholder).
node -e '
  const fs = require("fs");
  const [file, id] = process.argv.slice(1);
  const text = fs.readFileSync(file, "utf8");
  const next = text.replace(/("database_id"\s*:\s*")[^"]*(")/, `$1${id}$2`);
  if (next !== text) {
    fs.writeFileSync(file, next);
    console.log(`${file} mis à jour (database_id).`);
  }' "$CONFIG" "$DB_ID"

# --- R2 bucket ---------------------------------------------------------------
say "Bucket R2 « $BUCKET_NAME »"
if wrangler r2 bucket info "$BUCKET_NAME" --json >/dev/null 2>&1; then
  echo "Il existe déjà."
else
  echo "Création du bucket…"
  wrangler r2 bucket create "$BUCKET_NAME" ||
    fail "Impossible de créer le bucket. Activez R2 dans le tableau de bord Cloudflare (R2 Object Storage, moyen de paiement demandé même pour l'offre gratuite), puis relancez ce script."
fi

# --- Database schema and Worker ----------------------------------------------
say "Migrations de la base (distante)"
wrangler d1 migrations apply "$DB_NAME" --remote

# Deploy before setting the secret: `secret put` needs an existing Worker.
# Without ADMIN_TOKEN every admin route refuses all tokens, so this is safe.
say "Déploiement du Worker"
DEPLOY_LOG="$(wrangler deploy 2>&1 | tee /dev/stderr)"
API_URL="$(printf '%s\n' "$DEPLOY_LOG" | grep -Eo 'https://[A-Za-z0-9.-]+\.workers\.dev' | head -n 1 || true)"

# --- ADMIN_TOKEN -------------------------------------------------------------
say "Jeton administrateur (secret ADMIN_TOKEN)"
NEW_TOKEN=""
if wrangler secret list --format json 2>/dev/null | grep -q '"ADMIN_TOKEN"'; then
  read -r -p "ADMIN_TOKEN est déjà défini. Le remplacer par un nouveau jeton ? [o/N] " answer
  case "$answer" in
    [oOyY]*) NEW_TOKEN="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')" ;;
    *) echo "Jeton conservé." ;;
  esac
else
  NEW_TOKEN="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
fi
if [ -n "$NEW_TOKEN" ]; then
  printf '%s' "$NEW_TOKEN" | wrangler secret put ADMIN_TOKEN >/dev/null
  echo "Secret enregistré dans Cloudflare."
fi

# --- Summary -----------------------------------------------------------------
say "Terminé"
if [ -n "$API_URL" ]; then
  echo "Adresse de l'API : $API_URL"
  curl -fsS "$API_URL/v1/health" >/dev/null 2>&1 && echo "Vérification : $API_URL/v1/health répond." || true
else
  echo "Adresse de l'API : voir la sortie de « wrangler deploy » ci-dessus (https://mytags-api.<sous-domaine>.workers.dev)."
  API_URL="https://mytags-api.<sous-domaine>.workers.dev"
fi
if [ -n "$NEW_TOKEN" ]; then
  cat <<EOF

Jeton administrateur (affiché une seule fois, il n'est enregistré nulle part) :

    $NEW_TOKEN

Étape suivante, sur ce Mac :

    djtag login --api $API_URL

puis collez le jeton quand il est demandé (il sera rangé dans le trousseau macOS).
EOF
  if [ -n "${answer:-}" ]; then
    echo "L'ancien jeton ne fonctionne plus : relancez « djtag login » avec le nouveau. Les jetons des iPhone ne changent pas."
  fi
else
  echo "Le jeton administrateur n'a pas changé (celui rangé par « djtag login » reste valable)."
fi
