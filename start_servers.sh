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
OPAL_COMPOSE_DIR="${OPAL_COMPOSE_DIR:-/Users/tcadman/Library/CloudStorage/GoogleDrive-timcadman@gmail.com/Mi unidad/Work/repos/testing/opal-localhost}"
ARMADILLO_DIR="${ARMADILLO_DIR:-/Users/tcadman/git-repos/ds-molgenis/molgenis-service-armadillo}"
ARMA_PORT="${ARMA_PORT:-8081}"

wait_for() {  # name url
  local name="$1" url="$2" i
  printf 'Waiting for %s (%s) ' "$name" "$url"
  for i in $(seq 1 60); do
    if curl -fsS -o /dev/null "$url" 2>/dev/null; then echo " ready"; return 0; fi
    printf '.'; sleep 5
  done
  echo " TIMEOUT"; return 1
}

# --- Opal -------------------------------------------------------------------
echo "== Starting Opal =="
docker compose -f "$OPAL_COMPOSE_DIR/docker-compose.yml" up -d

# --- Armadillo --------------------------------------------------------------
echo "== Starting Armadillo on port $ARMA_PORT =="
(
  cd "$ARMADILLO_DIR"
  SERVER_PORT="$ARMA_PORT" ./gradlew run > "/tmp/armadillo-$ARMA_PORT.log" 2>&1 &
  echo "$!" > "/tmp/armadillo-$ARMA_PORT.pid"
)
echo "Armadillo PID: $(cat "/tmp/armadillo-$ARMA_PORT.pid")  (log: /tmp/armadillo-$ARMA_PORT.log)"

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
  kill \$(cat /tmp/armadillo-$ARMA_PORT.pid)
EOF
