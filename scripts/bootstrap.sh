#!/usr/bin/env bash
#
# Fetches everything the suites need. Idempotent: safe to re-run.
#
#   * the WMS 1.3.0 CITE dataset + project, unpacked by pyogctest itself
#   * world.qgs from QGIS-Training-Data, for OGC API Features
#
# Docker is the only prerequisite — no host Python, no virtualenv.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[[ -f .env ]] && source .env
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

# Host the TEAM Engine container uses to reach nginx; baked into the WMS
# project's MetadataURLs and advertised by QGIS Server as SERVER_NAME.
OGC_PUBLIC_HOST="${OGC_PUBLIC_HOST:-nginx}"
# Scheme the MetadataURLs are published with. https on a TLS deployment, or
# GetCapabilities advertises mixed schemes and the documents only resolve via
# a redirect.
OGC_PUBLIC_SCHEME="${OGC_PUBLIC_SCHEME:-http}"

mkdir -p data reports

log "Fetching test data (checksum-verified)"
data_runner python3 scripts/fetch_data.py "$OGC_PUBLIC_HOST" "$OGC_PUBLIC_SCHEME"

log "Bootstrap complete. Next: make up && make wms130"
