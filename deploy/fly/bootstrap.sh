#!/usr/bin/env bash
# One-time setup of the hosted demo on Fly.io: the three apps on a private network of
# their own, the database volume, the secrets and the first deploy of the database.
# Running it again is safe: it skips what exists and never replaces a secret.
#
#   deploy/fly/bootstrap.sh                        # region dfw, organization personal
#   FLY_REGION=mad FLY_ORG=acme deploy/fly/bootstrap.sh
#
# Needs flyctl signed in and openssl. The region must match primary_region in
# fly.toml, db.fly.toml and mocks.fly.toml.
set -euo pipefail

cd "$(dirname "$0")"

org="${FLY_ORG:-personal}"
region="${FLY_REGION:-dfw}"
app="fides-demo"
db_app="fides-demo-db"
mocks_app="fides-demo-mocks"
# Apps on a network of their own see nothing else in the organization, and nothing
# else sees them; a network can only be set when the app is created
network="fides-demo"

app_exists() {
  fly apps list --org "$org" --json | grep -qi "\"name\": *\"$1\""
}

has_secret() {
  fly secrets list --app "$1" --json | grep -qi "\"name\": *\"$2\""
}

app_exists "$db_app" || fly apps create "$db_app" --org "$org" --network "$network"
app_exists "$app" || fly apps create "$app" --org "$org" --network "$network"
app_exists "$mocks_app" || fly apps create "$mocks_app" --org "$org" --network "$network"

if ! fly volumes list --app "$db_app" --json | grep -qi '"name": *"pgdata"'; then
  fly volumes create pgdata --app "$db_app" --region "$region" --size 1 --yes
fi

if has_secret "$db_app" POSTGRES_PASSWORD; then
  has_secret "$app" DATABASE_URL ||
    echo "WARNING: $db_app already has a password but $app has no DATABASE_URL; set it by hand." >&2
else
  db_password="$(openssl rand -hex 16)"
  fly secrets set --app "$db_app" --stage POSTGRES_PASSWORD="$db_password"
  fly secrets set --app "$app" --stage \
    DATABASE_URL="ecto://fides:${db_password}@${db_app}.internal:5432/fides"
fi

if ! has_secret "$app" SECRET_KEY_BASE; then
  fly secrets set --app "$app" --stage \
    SECRET_KEY_BASE="$(openssl rand -base64 64 | tr -d '\n')" \
    FIDES_ENCRYPTION_KEY="$(openssl rand -base64 32)" \
    FIDES_BLIND_INDEX_KEY="$(openssl rand -base64 32)" \
    FIDES_STAFF_TOKEN_KEY="$(openssl rand -base64 32)" \
    FIDES_DEMO_TOTP_SEED="${FIDES_DEMO_TOTP_SEED:-fides development totp seed}"
fi

# The providers' webhooks and the deliveries to the receiver are signed with secrets
# both apps share
if ! has_secret "$app" FIDES_PROVIDER_WEBHOOK_SECRET; then
  provider_secret="$(openssl rand -hex 24)"
  receiver_secret="$(openssl rand -hex 24)"
  fly secrets set --app "$app" --stage \
    FIDES_PROVIDER_WEBHOOK_SECRET="$provider_secret" \
    FIDES_WEBHOOK_RECEIVER_SECRET="$receiver_secret"
  fly secrets set --app "$mocks_app" --stage \
    MOCKS_WEBHOOK_SECRET="$provider_secret" \
    MOCKS_RECEIVER_SECRET="$receiver_secret"
fi

fly deploy --config db.fly.toml --app "$db_app" --ha=false

cat <<MESSAGE

The database is up. Now save a deploy token per app as the FLY_API_TOKEN and
FLY_MOCKS_API_TOKEN secrets of the GitHub repository; each one may only manage
its app:

  fly tokens create deploy --app $app --expiry 8760h | tr -d '\\n' | gh secret set FLY_API_TOKEN
  fly tokens create deploy --app $mocks_app --expiry 8760h | tr -d '\\n' | gh secret set FLY_MOCKS_API_TOKEN

Then merge to main, or run the Release workflow by hand, to deploy $app and $mocks_app.
MESSAGE
