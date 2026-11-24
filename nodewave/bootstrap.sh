#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  echo ".env already exists. Remove or back it up before re-running bootstrap." >&2
  exit 1
fi

read -rp "Enter public Supabase domain (e.g. supabase.nodewave.net): " DOMAIN
if [ -z "$DOMAIN" ]; then
  echo "Domain is required for Caddy TLS provisioning." >&2
  exit 1
fi

cp .env.example .env

# Append Nodewave overrides (Compose uses the last definition of duplicate keys)
cat .env.nodewave.example >> .env
sed -i.bak "s|supabase.example.com|${DOMAIN}|g" .env
rm -f .env.bak

# Generate secrets & JWT/JWK keys via upstream utility if present
if [ -x ./utils/generate-keys.sh ]; then
  ./utils/generate-keys.sh
elif [ -f ./utils/generate-keys.sh ]; then
  sh ./utils/generate-keys.sh
fi

# Record synced tag so upstream update.sh tracks the exact baseline
UPSTREAM_TAG=$(cat .upstream-version)
printf "ref=%s\n" "$UPSTREAM_TAG" > .supabase-version

echo "Bootstrap complete for https://${DOMAIN} (upstream ${UPSTREAM_TAG})."
echo "Review SMTP settings in .env, then run: sh run.sh start"
