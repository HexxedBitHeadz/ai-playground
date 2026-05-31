#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose stop ollama chroma webui

echo "Stack stopped."
