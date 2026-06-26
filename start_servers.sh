#!/usr/bin/env bash
# ==============================================================================
# Start both DataSHIELD backends for the localhost benchmark:
#   - Opal       (docker compose)              -> http://localhost:8080
#   - Armadillo  (Spring Boot via gradlew)     -> http://localhost:8081
#
# Run this yourself (Docker is not available to the agent):
#   bash start_servers.sh
#
# Stop again with:
#   docker compose -f "$OPAL_COMPOSE_DIR/docker-compose.yml" down
#   kill the gradlew process (PID printed below, or: pkill -f 'gradlew run')
# ==============================================================================
set -euo pipefail

# --- Paths (override via env if your layout differs) ------------------------
# Defaults are $HOME-relative so the script is portable across machines/users;
# the Armadillo checkout is auto-detected among common locations.
OPAL_COMPOSE_DIR="${OPAL_COMPOSE_DIR:-$HOME/git-repos/opal-docker}"
if [ -z "${ARMADILLO_DIR:-}" ]; then
  for d in "$HOME/git-repos/molgenis/molgenis-service-armadillo" \
           "$HOME/git-repos/ds-molgenis/molgenis-service-armadillo"; do
    [ -d "$d" ] && ARMADILLO_DIR="$d" && break
  done
  ARMADILLO_DIR="${ARMADILLO_DIR:-$HOME/git-repos/molgenis/molgenis-service-armadillo}"
fi
ARMA_PORT="${ARMA_PORT:-8081}"
OPAL_PORT="${OPAL_PORT:-8080}"

wait_for() {  # name url
  local name="$1" url="$2" i
  printf 'Waiting for %s (%s) ' "$name" "$url"
  for i in $(seq 1 60); do
    if curl -fsS -o /dev/null "$url" 2>/dev/null; then echo " ready"; return 0; fi
    printf '.'; sleep 5
  done
  echo " TIMEOUT"; return 1
}

# Free a TCP port before we start a server on it: kill any HOST process already
# listening on it (e.g. a stray `gradlew run` Armadillo squatting on Opal's port,
# which we hit in practice). Docker-PUBLISHED ports are owned by Docker's own
# proxy (com.docker.backend / docker-proxy / vpnkit) -- those are NEVER killed
# (that would kill Docker Desktop); docker compose manages them, so a conflicting
# *container* must be stopped by hand. Needs lsof (preinstalled on macOS).
free_port() {  # port label
  local port="$1" label="$2" pid comm killed=0
  listeners() { lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $2, $1}' | sort -u; }
  is_docker() { case "$1" in com.docke*|docker*|vpnkit*|Docker*) return 0;; *) return 1;; esac; }
  while read -r pid comm; do
    [ -z "$pid" ] && continue
    if is_docker "$comm"; then
      echo "  $label port $port held by Docker ($comm pid $pid); leaving it for compose"
    else
      echo "  $label port $port in use by $comm (pid $pid); stopping it"
      kill "$pid" 2>/dev/null || true; killed=1
    fi
  done < <(listeners)
  [ "$killed" = 1 ] || return 0
  sleep 2
  while read -r pid comm; do                      # SIGKILL any non-Docker survivors
    [ -z "$pid" ] && continue
    is_docker "$comm" && continue
    echo "  $label port $port still held by $comm (pid $pid); SIGKILL"
    kill -9 "$pid" 2>/dev/null || true
  done < <(listeners)
}

# --- Opal -------------------------------------------------------------------
echo "== Starting Opal =="
free_port "$OPAL_PORT" "Opal"        # clear a stray host process off Opal's port
docker compose -f "$OPAL_COMPOSE_DIR/docker-compose.yml" up -d

# --- Armadillo --------------------------------------------------------------
# Logs/pid go to $LOG_DIR (defaults to $TMPDIR, falling back to /tmp) so the
# script works under restricted-/tmp sandboxes too.
LOG_DIR="${ARMA_LOG_DIR:-${TMPDIR:-/tmp}}"
echo "== Starting Armadillo on port $ARMA_PORT =="
free_port "$ARMA_PORT" "Armadillo"   # restart cleanly if one is already running
(
  cd "$ARMADILLO_DIR"
  SERVER_PORT="$ARMA_PORT" ./gradlew run > "$LOG_DIR/armadillo-$ARMA_PORT.log" 2>&1 &
  echo "$!" > "$LOG_DIR/armadillo-$ARMA_PORT.pid"
)
echo "Armadillo PID: $(cat "$LOG_DIR/armadillo-$ARMA_PORT.pid")  (log: $LOG_DIR/armadillo-$ARMA_PORT.log)"

# --- Readiness --------------------------------------------------------------
wait_for "Opal"      "http://localhost:8080"
wait_for "Armadillo" "http://localhost:$ARMA_PORT/actuator/health" \
  || wait_for "Armadillo" "http://localhost:$ARMA_PORT"

cat <<EOF

Both servers are up.
  Opal:      http://localhost:8080      (administrator / datashield_test&)
  Armadillo: http://localhost:$ARMA_PORT      (admin / admin)

Next:
  Rscript setup.R     # upload data + save workspaces (once)
  Rscript bench.R     # run the benchmark

Stop:
  docker compose -f "$OPAL_COMPOSE_DIR/docker-compose.yml" down
  kill \$(cat $LOG_DIR/armadillo-$ARMA_PORT.pid)
EOF
