#!/usr/bin/env bash
# install.sh — one-time setup for LAB01.
#
# Heavy lifting that happens when the user clicks INSTALL on the dashboard:
#   1. Bootstrap (.env from template, dir perms)
#   2. Start the ollama container alone, just long enough to pull model weights
#   3. Pull base models (HEBI_LITE=1 limits to a small subset)
#   4. Build custom hebi-* modelfiles (skipped in lite mode)
#   5. Stop the ollama container — install leaves NOTHING running
#
# After this, scripts/start.sh is fast (just docker compose start) because all
# models, images, and customs are pre-built.
set -euo pipefail
cd "$(dirname "$0")/.."

_ROOT="$(cd "$(dirname "$0")/../../" && pwd)"
source "$_ROOT/shared/progress.sh"
progress_init 4

# Add GPU override only when a working NVIDIA adapter is present AND Docker
# has the nvidia container runtime registered. CPU is the default in
# docker-compose.yml — additive overrides are reliable, while the inverse
# (declare GPU in base, "remove" in cpu.yml) does not work because Compose
# deep-merges dicts. HEBI_NO_GPU may already be set by run.sh; if not (e.g.
# install.sh run by hand), detect locally. WSL2 + Docker Engine commonly
# has nvidia-smi working (Windows driver shim) but no nvidia-container-
# toolkit installed — adding the GPU compose file in that state makes
# `compose up` fail with "could not select device driver nvidia".
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

# 1. Bootstrap .env + writable dirs
progress_phase 1 "Bootstrapping"
if [ ! -f .env ]; then
  cp .env.example .env
fi
set -a
source .env
set +a
if [[ "${HEBI_LITE:-0}" == "1" ]]; then
  OLLAMA_MODELS="tinyllama:1.1b,llama3.2:1b"
  progress_detail "LITE mode — only tinyllama:1.1b, llama3.2:1b"
fi
mkdir -p logs data/ollama data/chroma 2>/dev/null || true
chmod 777 logs data data/ollama data/chroma 2>/dev/null || true

# 2. Bring ollama up (and chroma/webui — webui is the python helper for byte-progress pulls).
# --build forces a rebuild of webui/chroma images so code changes pulled via
# `git pull` actually land in the running containers. Without it, `docker
# compose up` would reuse cached images and silently run stale code — e.g.
# the model-allowlist fix that wouldn't take effect until a manual rebuild.
progress_phase 2 "Building images"
progress_detail "docker compose build + create"
docker compose "${COMPOSE_FILES[@]}" up -d --build ollama chroma webui >>logs/install.log 2>&1

progress_detail "waiting for ollama to be ready"
for i in $(seq 1 30); do
  if docker exec ollama ollama list >/dev/null 2>&1; then break; fi
  sleep 2
done

# 3. Pull models with live byte progress
if [[ -n "${OLLAMA_MODELS:-}" ]]; then
  progress_phase 3 "Pulling models"
  EXISTING=$(docker exec ollama ollama list 2>/dev/null | awk 'NR>1 {print $1}' | sort)
  IFS=',' read -ra MODELS <<< "$OLLAMA_MODELS"
  for model in "${MODELS[@]}"; do
    model="${model// /}"
    if echo "$EXISTING" | grep -qx "$model"; then
      progress_detail "$model — already pulled"
    else
      progress_pull "$model" || echo "Warning: could not pull $model"
    fi
  done
fi

# 4. Build custom hebi-* modelfiles whose FROM base is actually present.
# Dynamic check (instead of a hard "skip in lite mode") means HEBI_LITE
# readers get the lite-friendly customs built on llama3.2:1b / tinyllama,
# and full-mode readers get those plus the heavier ones (qwen2.5-coder,
# etc.) on the same code path.
#
# We also keep a tiny sidecar of "name:sha256" pairs at .modelfile-hashes
# so the loop can detect when a modelfile was edited and rebuild only
# the ones that actually changed. Previously, editing a .modelfile and
# re-running install.sh silently no-op'd because "${name}:latest" already
# existed in ollama — the only fix was a manual `ollama rm` first. Now
# editing → re-running install → new content lands.
if [[ -d "./modelfiles" ]]; then
  progress_phase 4 "Building custom models"
  EXISTING=$(docker exec ollama ollama list 2>/dev/null | awk 'NR>1 {print $1}' | sort)
  HASH_FILE="./.modelfile-hashes"
  [[ -f "$HASH_FILE" ]] || touch "$HASH_FILE"
  for modelfile in ./modelfiles/*.modelfile; do
    [ -f "$modelfile" ] || continue
    name=$(basename "$modelfile" .modelfile)
    # Pull the FROM line's base model name; skip if we don't have it on disk.
    base="$(awk '/^FROM[[:space:]]/ {print $2; exit}' "$modelfile")"
    if [[ -n "$base" ]] && ! echo "$EXISTING" | grep -qx "$base"; then
      progress_detail "$name — skipped (base $base not pulled)"
      continue
    fi
    current_hash="$(sha256sum "$modelfile" | awk '{print $1}')"
    recorded_hash="$(grep "^${name}:" "$HASH_FILE" 2>/dev/null | cut -d: -f2- || true)"
    exists_in_ollama=0
    echo "$EXISTING" | grep -qx "${name}:latest" && exists_in_ollama=1
    if (( exists_in_ollama == 1 )) && [[ "$current_hash" == "$recorded_hash" ]]; then
      progress_detail "$name (unchanged)"
      continue
    fi
    if (( exists_in_ollama == 1 )); then
      progress_detail "$name (modelfile changed — rebuilding)"
    else
      progress_detail "$name (building)"
    fi
    docker exec -i ollama sh -c "cat > /tmp/Modelfile.build" < "$modelfile"
    docker exec ollama ollama create "$name" -f /tmp/Modelfile.build
    docker exec ollama rm -f /tmp/Modelfile.build
    # Update the sidecar: remove any prior entry for $name, append the new hash.
    sed -i "/^${name}:/d" "$HASH_FILE"
    echo "${name}:${current_hash}" >> "$HASH_FILE"
  done
fi

# 5. Stop containers — install leaves the lab "installed but not running"
docker compose stop >/dev/null 2>&1

progress_done
echo "LAB01 install complete — click LAUNCH to start the lab."
