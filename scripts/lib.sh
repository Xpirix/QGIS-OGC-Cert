#!/usr/bin/env bash
# Shared helpers for bootstrap.sh and run-suite.sh.

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

# pyogctest spawns TEAM Engine through the Docker SDK, so the runner needs the
# daemon socket. Its path differs between rootful Docker (/var/run/docker.sock)
# and rootless (/run/user/<uid>/docker.sock); ask the active context rather
# than guessing.
if [[ -z "${DOCKER_SOCK:-}" ]]; then
  _endpoint=$(docker context inspect -f '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
  case "$_endpoint" in
    unix://*) DOCKER_SOCK="${_endpoint#unix://}" ;;
    *)        DOCKER_SOCK="/var/run/docker.sock" ;;
  esac
  unset _endpoint
fi
export DOCKER_SOCK
[[ -S "$DOCKER_SOCK" ]] || warn "No Docker socket at $DOCKER_SOCK — set DOCKER_SOCK in .env"

# The runner writes into the bind-mounted ./data and ./reports, so it has to
# end up owning those files as the invoking user.
#
#   * rootful Docker: container root would write root-owned files, so pass
#     --user with the caller's uid/gid.
#   * rootless Docker: the caller is *already* mapped to container root, and
#     passing --user breaks writes instead of fixing them.
runner_user_args() {
  if docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q 'name=rootless'; then
    return 0
  fi
  printf '%s\n' "--user" "$(id -u):$(id -g)"
}

# Fetch test data using a stock Python image — no pyogctest, no Docker socket,
# no image build. Deliberately separate from runner(): a public deployment needs
# to stage its data but must never mount the daemon socket.
data_runner() {
  local user_args=()
  mapfile -t user_args < <(runner_user_args)
  docker run --rm "${user_args[@]}" \
    -v "$PWD":/work -w /work python:3.12-slim "$@"
}

# Run a command in the pyogctest runner container, building it on first use.
runner() {
  local user_args=()
  mapfile -t user_args < <(runner_user_args)
  if ! docker image inspect qgis-ogc-cert/runner:local >/dev/null 2>&1; then
    log "Building the pyogctest runner image (first run only)"
    docker compose --profile tools build runner
  fi
  docker compose --profile tools run --rm -T "${user_args[@]}" runner "$@"
}

# pyogctest names its TEAM Engine container `pyogctest` and starts it with
# remove=True. An interrupted run leaves that name taken, and the next run dies
# on the conflict — so clear it first.
clear_teamengine() {
  docker rm -f pyogctest >/dev/null 2>&1 || true
}
