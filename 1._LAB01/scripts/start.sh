#!/usr/bin/env bash
# start.sh — fast path. Bring the lab's containers back up.
#
# Assumes scripts/install.sh has already run (models pulled, images built,
# custom modelfiles created). The dashboard's INSTALL flow runs install.sh
# automatically. If you run start.sh on a lab that hasn't been installed yet,
# it'll fall back to running install.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

_ROOT="$(cd "$(dirname "$0")/../../" && pwd)"
_THIS_PROJECT="$(basename "$(cd "$(dirname "$0")/.." && pwd)")"; _THIS_PROJECT="${_THIS_PROJECT//./}"; _THIS_PROJECT="${_THIS_PROJECT,,}"

# Add GPU override only when NVIDIA hardware AND Docker's nvidia runtime
# are both present. See install.sh for the rationale.
if [[ -z "${HEBI_NO_GPU:-}" ]]; then
  HEBI_NO_GPU=1
  if (command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null) \
       || [[ -e /dev/nvidia0 ]]; then
    if docker info 2>/dev/null | grep -qE '^\s*Runtimes:.*nvidia'; then
      HEBI_NO_GPU=0
    fi
  fi
fi
COMPOSE_FILES=(-f docker-compose.yml)
[[ "$HEBI_NO_GPU" == "0" ]] && COMPOSE_FILES+=(-f docker-compose.gpu.yml)
if [[ -f "$_ROOT/stop-other-labs.sh" ]]; then source "$_ROOT/stop-other-labs.sh"; stop_other_labs "$_THIS_PROJECT"; fi

# Auto-install if no containers exist yet (someone ran start.sh without going
# through the dashboard). Detect by checking if the ollama container is known
# to docker compose for this project.
if ! docker compose ps -a --services 2>/dev/null | grep -qx ollama; then
  echo "No containers found for LAB01 — running install.sh first..."
  bash "$(dirname "$0")/install.sh"
fi

if [ ! -f .env ]; then cp .env.example .env; fi

# Use `compose up -d` (not `compose start`) so any config drift is picked up
# automatically: GPU/CPU mode flip (different compose file set), env var
# changes, image rebuilds, volume mount additions. compose computes a config
# hash and only recreates containers whose definition actually changed —
# unchanged services stay up. `compose start` would skip that diffing and
# silently keep a stale container, which we hit three times during testing
# (env vars, image rebuild, GPU enablement).
docker compose "${COMPOSE_FILES[@]}" up -d

# Brief wait for ollama to respond
for i in $(seq 1 15); do
  if docker exec ollama ollama list >/dev/null 2>&1; then break; fi
  sleep 1
done

echo "LAB01 is up — http://localhost:${WEBUI_PORT:-8081}"
