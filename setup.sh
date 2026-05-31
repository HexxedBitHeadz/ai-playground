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
echo "Done. Edit any .env files as needed before launching labs."
