#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# nullglob: empty match disappears instead of yielding the literal pattern.
# Guards against a future state where no */.env.example files exist.
shopt -s nullglob

echo "Initializing .env files from .env.example templates..."
echo ""

for example in */.env.example; do
  dir="$(dirname "$example")"
  env_file="$dir/.env"
  if [ -f "$env_file" ]; then
    echo "  [skip] $dir/.env already exists"
  else
    sed 's/\r//' "$example" > "$env_file"
    echo "  [created] $dir/.env"
  fi
done

echo ""

# Create the shared ollama-models named Docker volume. Every lab mounts
# this volume into its ollama container, so model weights pulled by one
# lab are reused by every other lab — pull the ~38 GB once, use forever.
# Idempotent: docker volume create no-ops if the volume already exists.
if command -v docker >/dev/null 2>&1; then
  if docker volume inspect hebi-ollama-models >/dev/null 2>&1; then
    echo "  [skip] hebi-ollama-models volume already exists"
  else
    if docker volume create hebi-ollama-models >/dev/null 2>&1; then
      echo "  [created] hebi-ollama-models volume (shared across labs)"
    else
      echo "  [warn] couldn't create hebi-ollama-models volume — install.sh will retry"
    fi
  fi
else
  echo "  [warn] docker not found yet — install.sh will create the volume when you launch a lab"
fi

echo ""
echo "Done. Edit any .env files as needed before launching labs."
