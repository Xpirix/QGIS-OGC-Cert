#!/usr/bin/env bash
#
# Deploy (or redeploy) the public certification + demo server.
#
#   ./deploy/deploy.sh
#
# Idempotent: safe to re-run to pick up a new QGIS_TAG or config change.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# The runner mounts the Docker socket. Refuse outright rather than trusting
# whoever is at the keyboard to remember.
for arg in "$@"; do
  if [[ "$arg" == "--profile" || "$arg" == *"tools"* ]]; then
    printf '\033[1;31mERR\033[0m Refusing: the `tools` profile mounts the Docker socket and must never run on a public host.\n' >&2
    exit 1
  fi
done

# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

[[ -f .env ]] || die "No .env — copy deploy/.env.prod.example to .env and edit it."
# shellcheck disable=SC1091
source .env

: "${SITE_ADDRESS:?set SITE_ADDRESS in .env}"
: "${ACME_EMAIL:?set ACME_EMAIL in .env}"
: "${OGC_PUBLIC_HOST:?set OGC_PUBLIC_HOST in .env (the public hostname)}"

COMPOSE=(docker compose -f docker-compose.yml -f deploy/docker-compose.prod.yml)
SERVICES=(qgis-server nginx caddy)

log "Deploying ${SITE_ADDRESS} (QGIS_TAG=${QGIS_TAG:-ltr}, slug=${QGIS_VERSION_SLUG:-ltr})"

# Staged with a stock Python image — no Docker socket, no runner image.
log "Staging test data"
./scripts/bootstrap.sh

log "Pulling images"
"${COMPOSE[@]}" pull --quiet "${SERVICES[@]}" || warn "pull failed; using local images"

log "Starting services: ${SERVICES[*]}"
"${COMPOSE[@]}" up -d --remove-orphans "${SERVICES[@]}"

log "Waiting for the edge to answer"
for _ in $(seq 1 30); do
  if curl -skf --max-time 10 "https://${SITE_ADDRESS}/endpoints.json" >/dev/null 2>&1; then
    log "Live: https://${SITE_ADDRESS}/"
    curl -sk "https://${SITE_ADDRESS}/endpoints.json"; echo
    exit 0
  fi
  sleep 4
done

warn "No answer yet from https://${SITE_ADDRESS}/ after ~2 minutes."
warn "Certificate issuance can take a moment on first run. Check:"
warn "  ${COMPOSE[*]} logs caddy"
exit 1
