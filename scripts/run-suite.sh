#!/usr/bin/env bash
#
# Runs an OGC Executable Test Suite against the compose stack.
#
#   ./scripts/run-suite.sh wms130 | ogcapif | all
#
# pyogctest drives TEAM Engine: it pulls, starts and removes the ETS container
# itself, so the only services we bring up are QGIS Server and nginx.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[[ -f .env ]] && source .env
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

HTTP_PORT="${HTTP_PORT:-8089}"
TE_PORT="${TE_PORT:-8081}"
OGCAPI_ROOT="${OGCAPI_ROOT:-/wfs3}"
OGC_PUBLIC_HOST="${OGC_PUBLIC_HOST:-nginx}"
QGIS_VERSION_SLUG="${QGIS_VERSION_SLUG:-ltr}"
NETWORK="ogc-cert"

BASE_HOST="http://localhost:${HTTP_PORT}"

# Endpoint paths follow the QGIS.org reference-server convention and are derived
# from the same variable nginx templates them with, so local and public URLs
# cannot drift apart.
WMS130_PATH="qgisserver_${QGIS_VERSION_SLUG}_teamengine"
OGCAPIF_PATH="certification_ogcapif_qgisserver_${QGIS_VERSION_SLUG}"

suite_path() {
  case "$1" in
    wms130)  printf '%s\n' "$WMS130_PATH" ;;
    ogcapif) printf '%s\n' "$OGCAPIF_PATH" ;;
    *)       die "No endpoint path defined for suite '$1'" ;;
  esac
}

[[ -f data/teamengine_wms_130.qgs ]] || die "Test data missing — run 'make bootstrap' first."

# Wait for an endpoint to answer, rather than sleeping and hoping. QGIS Server
# is slow on the first request (Xvfb startup + project load).
#
# Note QGIS Server returns HTTP 200 for OGC ServiceExceptions, so match on
# expected *content*, never on the status code.
wait_for() {
  local url="$1" expect="$2" name="$3" tries="${4:-60}" body
  log "Waiting for $name"
  for ((i = 1; i <= tries; i++)); do
    # Deliberately not `curl ... | grep -q`: under `set -o pipefail` grep exits
    # on first match, curl takes SIGPIPE, and the pipeline reports failure for
    # a perfectly good response. Match against a captured body instead.
    if body=$(curl -sf --max-time 15 "$url" 2>/dev/null) \
       && [[ "$body" == *"$expect"* ]]; then
      log "$name is up"
      return 0
    fi
    sleep 2
  done
  warn "Last response from $url:"
  printf '%s\n' "${body:-<no response>}" | head -20 >&2
  die "$name never became ready (expected to find '$expect')"
}

start_stack() {
  log "Starting stack (QGIS_TAG=${QGIS_TAG:-ltr})"
  docker compose up -d qgis-server nginx
}

# Run a suite and file its report.
#
# pyogctest's -x writes `teamengine.xml` into its working directory (/work, the
# project root) and ignores -o; -o only takes effect with `-f html`, which
# would replace the readable console output. So keep the prompt format and
# relocate the XML ourselves — including when the suite fails, since a red run
# is exactly when you want the report.
run_suite() {
  local suite="$1"; shift
  local outdir="reports/$suite" rc=0
  mkdir -p "$outdir"
  clear_teamengine
  rm -f teamengine.xml
  runner pyogctest -n "$NETWORK" -p "$TE_PORT" -s "$suite" -v -x "$@" \
    -u "http://${OGC_PUBLIC_HOST}/$(suite_path "$suite")" || rc=$?
  if [[ -f teamengine.xml ]]; then
    mv -f teamengine.xml "$outdir/teamengine.xml"
    log "report: $outdir/teamengine.xml"
  else
    warn "pyogctest produced no XML report"
  fi
  return "$rc"
}

run_wms130() {
  start_stack
  wait_for "${BASE_HOST}/${WMS130_PATH}?SERVICE=WMS&REQUEST=GetCapabilities" \
           "WMS_Capabilities" "WMS 1.3.0 endpoint"
  wait_for "${BASE_HOST}/wms13/metadata/Streams.xml" "<" "MetadataURL documents" 10
  log "Running WMS 1.3.0 suite"
  run_suite wms130
}

run_ogcapif() {
  start_stack
  wait_for "${BASE_HOST}/${OGCAPIF_PATH}${OGCAPI_ROOT}/conformance?f=json" \
           "conformsTo" "OGC API Features endpoint"
  log "Running OGC API Features 1.0 suite"
  run_suite ogcapif --ogcapi-root "$OGCAPI_ROOT"
}

case "${1:-all}" in
  wms130)  run_wms130 ;;
  ogcapif) run_ogcapif ;;
  all)
    # Run both even if the first is red, so one failure doesn't hide the other.
    rc=0
    for s in wms130 ogcapif; do
      log "--- suite: $s ---"
      "$0" "$s" || { warn "suite $s reported failures"; rc=1; }
    done
    exit "$rc"
    ;;
  *) die "Unknown suite '${1}'. Use: wms130 | ogcapif | all" ;;
esac
