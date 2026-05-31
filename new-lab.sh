#!/usr/bin/env bash
# new-lab.sh — scaffold a new lab folder that the dashboard will auto-discover.
#
# Usage:  ./new-lab.sh <NN> "<Title>"
# Example: ./new-lab.sh 10 "Pickle Deserialization RCE"
#
# Creates <NN>._LAB<NN>/ with lab.json, docker-compose.yml, .env.example,
# scripts/{bootstrap,start,stop,teardown}.sh, and a README skeleton.
# Port defaults to 80<NN> (e.g. lab10 -> 8090). Edit lab.json to customize
# difficulty, topic, and description.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <NN> \"<Title>\"" >&2
  echo "Example: $0 10 \"Pickle Deserialization RCE\"" >&2
  exit 1
fi

NN_RAW="$1"
TITLE="$2"

# Normalize NN: accept "10" or "010", store as zero-padded two-digit string.
if ! [[ "$NN_RAW" =~ ^[0-9]+$ ]]; then
  echo "Error: first arg must be a number (got '$NN_RAW')." >&2
  exit 1
fi
NN=$(printf "%02d" "$NN_RAW")
N_INT=$((10#$NN))

ROOT="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$ROOT/${N_INT}._LAB${NN}"
LAB_ID="lab${NN}"
PORT=$((8000 + N_INT))   # lab10 -> 8090; lab12 -> 8092; keeps existing labs 81-89

if [[ -e "$LAB_DIR" ]]; then
  echo "Error: $LAB_DIR already exists." >&2
  exit 1
fi

# Refuse to clash with a port already claimed by an existing lab.json.
for existing in "$ROOT"/*._LAB*/lab.json; do
  [[ -f "$existing" ]] || continue
  taken=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('port',''))" "$existing")
  if [[ "$taken" == "$PORT" ]]; then
    echo "Error: port $PORT already used by $existing — edit lab.json after creation." >&2
    exit 1
  fi
done

echo "Scaffolding $LAB_DIR on port $PORT..."

mkdir -p "$LAB_DIR/scripts" "$LAB_DIR/docker/webui" "$LAB_DIR/modelfiles"

cat > "$LAB_DIR/modelfiles/.gitkeep" <<EOF
# Drop *.modelfile files here. Each lab owns the custom Ollama modelfiles it demos.
# Naming: <name>.modelfile  -> built as <name>:lab${NN} into the shared Ollama data dir.
# Auto-built by scripts/start.sh on first launch.
EOF

cat > "$LAB_DIR/lab.json" <<EOF
{
  "id": "${LAB_ID}",
  "name": "LAB ${NN}",
  "title": "${TITLE}",
  "description": "TODO: one-paragraph blurb shown on the dashboard tile.",
  "difficulty": "Beginner",
  "topic": "TODO",
  "port": ${PORT},
  "released": false
}
EOF

cat > "$LAB_DIR/.env.example" <<EOF
WEBUI_PORT=${PORT}
LOG_DIR=./logs
EOF

cat > "$LAB_DIR/docker-compose.yml" <<EOF
services:
  webui:
    build:
      context: ./docker/webui
      dockerfile: Dockerfile
    container_name: webui-${LAB_ID}
    restart: unless-stopped
    ports:
      - "\${WEBUI_PORT}:8080"
    environment:
      WEBUI_LOG_DIR: /logs
    volumes:
      - \${LOG_DIR}:/logs
      - ../shared/branding:/app/static/branding:ro
      - ../shared/templates:/app/templates/shared:ro
    healthcheck:
      test: ["CMD-SHELL", "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:8080/', timeout=5)\""]
      interval: 15s
      timeout: 5s
      retries: 5
EOF

cat > "$LAB_DIR/docker/webui/Dockerfile" <<'EOF'
# TODO: replace this stub with the actual webui image for this lab.
FROM python:3.11-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi uvicorn jinja2
COPY app.py /app/app.py
EXPOSE 8080
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

cat > "$LAB_DIR/docker/webui/app.py" <<EOF
from fastapi import FastAPI
from fastapi.responses import HTMLResponse

app = FastAPI(title="LAB ${NN} — ${TITLE}")


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return "<h1>LAB ${NN} — ${TITLE}</h1><p>Replace this stub with the lab UI.</p>"
EOF

cat > "$LAB_DIR/scripts/install.sh" <<EOF
#!/usr/bin/env bash
# install.sh — one-time setup for LAB ${NN}.
#
# Heavy lifting fired by the dashboard's INSTALL button:
#   1. Bootstrap .env + dir permissions
#   2. Build container images and bring services up (so they can pull models)
#   3. Pull any Ollama models the lab needs (delete this block if not using Ollama)
#   4. Build custom hebi-* modelfiles (delete if N/A)
#   5. Stop containers — install leaves the lab "installed but not running"
#
# After this, scripts/start.sh is fast (docker compose start) because everything
# is pre-built. Progress reporting drives the dashboard's progress block.
set -euo pipefail
cd "\$(dirname "\$0")/.."

_ROOT="\$(cd "\$(dirname "\$0")/../../" && pwd)"
source "\$_ROOT/shared/progress.sh"
progress_init 4

# 1. Bootstrap
progress_phase 1 "Bootstrapping"
[ -f .env ] || cp .env.example .env
set -a; source .env; set +a
mkdir -p logs 2>/dev/null || true
chmod 777 logs 2>/dev/null || true

# 2. Build images + start services
progress_phase 2 "Building images"
progress_detail "docker compose build + create"
docker compose up -d >/dev/null 2>&1

# 3. (Optional) Pull Ollama models with live byte-progress.
# Uncomment and fill in if this lab has an ollama service:
# progress_phase 3 "Pulling models"
# for model in tinyllama:1.1b llama3.2:1b; do
#   if docker exec ollama-lab${NN} ollama list 2>/dev/null | grep -qx "\$model"; then
#     progress_detail "\$model — already pulled"
#   else
#     OLLAMA_CONTAINER=ollama-lab${NN} progress_pull "\$model" || true
#   fi
# done

# 4. (Optional) Build custom Ollama modelfiles.
if compgen -G "modelfiles/*.modelfile" > /dev/null; then
  progress_phase 4 "Building custom models"
  for mf in modelfiles/*.modelfile; do
    model_name="\$(basename "\$mf" .modelfile):lab${NN}"
    if docker exec ollama-lab${NN} ollama list 2>/dev/null | grep -q "^\${model_name}"; then
      progress_detail "\$model_name (already built)"
    else
      progress_detail "\$model_name (building)"
      docker cp "\$mf" ollama-lab${NN}:/tmp/modelfile.tmp
      docker exec ollama-lab${NN} ollama create "\$model_name" -f /tmp/modelfile.tmp
    fi
  done
fi

# 5. Stop — install leaves the lab "installed but not running"
docker compose stop >/dev/null 2>&1

progress_done
echo "LAB ${NN} install complete — click LAUNCH to start the lab."
EOF

cat > "$LAB_DIR/scripts/start.sh" <<EOF
#!/usr/bin/env bash
# start.sh — fast path. Bring the lab's containers back up.
#
# Assumes scripts/install.sh has already run (images built, models pulled).
# If you run start.sh on a never-installed lab, it falls back to install.sh.
set -euo pipefail
cd "\$(dirname "\$0")/.."

_ROOT="\$(cd "\$(dirname "\$0")/../../" && pwd)"
_THIS_PROJECT="\$(basename "\$(cd "\$(dirname "\$0")/.." && pwd)")"; _THIS_PROJECT="\${_THIS_PROJECT//./}"; _THIS_PROJECT="\${_THIS_PROJECT,,}"
if [[ -f "\$_ROOT/stop-other-labs.sh" ]]; then source "\$_ROOT/stop-other-labs.sh"; stop_other_labs "\$_THIS_PROJECT"; fi

# Auto-install if no containers exist yet (someone ran start.sh without going
# through the dashboard INSTALL).
if ! docker compose ps -a --services 2>/dev/null | grep -qx webui; then
  echo "No containers found for LAB ${NN} — running install.sh first..."
  bash "\$(dirname "\$0")/install.sh"
fi

[ -f .env ] || cp .env.example .env

# Bring stopped containers back up — fast, no rebuild.
docker compose start 2>/dev/null || docker compose up -d

echo "LAB ${NN} is up — http://localhost:\${WEBUI_PORT:-${PORT}}"
EOF

cat > "$LAB_DIR/scripts/stop.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "\$(dirname "\$0")/.."

docker compose down 2>/dev/null || true

echo "LAB${NN} stopped."
EOF

cat > "$LAB_DIR/scripts/teardown.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "\$(dirname "\$0")/.."

docker compose down --volumes --remove-orphans

rm -rf logs

echo "LAB${NN} torn down."
EOF

chmod +x "$LAB_DIR/scripts/"*.sh

cat > "$LAB_DIR/README.md" <<EOF
# Lab ${NN} — ${TITLE}

TODO: one-paragraph overview of what the student will learn.

---

## Architecture

| Service | Port | Role |
|---------|------|------|
| **WebUI** | ${PORT} | TODO |

---

## Quick Start

\`\`\`bash
./scripts/install.sh   # first time only — pulls models, builds images
./scripts/start.sh     # launch (fast — install state is reused)
\`\`\`

Open **http://localhost:${PORT}**.

---

## Lab Steps

TODO

---

## Defenses

TODO
EOF

echo ""
echo "Done. Next:"
echo "  1. Edit ${LAB_DIR}/lab.json (description, difficulty, topic)"
echo "  2. Replace ${LAB_DIR}/docker/webui/ with the real lab image"
echo "  3. Customize scripts/install.sh — the heavy one-time setup (model pulls,"
echo "     image builds). Progress reporting helpers are already wired in;"
echo "     uncomment the Ollama pull block if this lab uses Ollama."
echo "  4. scripts/start.sh is intentionally tiny — assumes install.sh already ran."
echo "  5. The lab is created with \"released\": false — it WON'T appear on the dashboard"
echo "     yet. Iterate freely. When ready for its blog post, flip the flag and push."
