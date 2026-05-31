#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

docker compose down --volumes --remove-orphans

rm -rf data logs

echo "Stack torn down and local data removed."
