#!/usr/bin/env bash
# stop-all.sh — stop or teardown every lab in this repo.
#
# Auto-discovers labs by globbing N._LAB*/ folders — works whether you have
# just LAB 01 installed or you've extended the playground with new-lab.sh.
#
# Usage:
#   ./stop-all.sh            # stop containers, keep data
#   ./stop-all.sh --teardown # remove containers, volumes, and local data

set -uo pipefail
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TEARDOWN=false
if [[ "${1:-}" == "--teardown" ]]; then
  TEARDOWN=true
fi

LABS=()
for d in "$SCRIPT_DIR"/[0-9]*._LAB*/; do
  LABS+=("$(basename "$d")")
done

if [[ ${#LABS[@]} -eq 0 ]]; then
  echo "No labs found in $SCRIPT_DIR — nothing to do."
  exit 0
fi

if $TEARDOWN; then
  echo "=== Tearing down all labs (containers + volumes + data) ==="
  SCRIPT_NAME="teardown.sh"
else
  echo "=== Stopping all labs (containers only, data preserved) ==="
  SCRIPT_NAME="stop.sh"
fi
echo ""

PASSED=0
FAILED=0
SKIPPED=0

for lab in "${LABS[@]}"; do
  lab_dir="$SCRIPT_DIR/$lab"
  script="$lab_dir/scripts/$SCRIPT_NAME"

  if [[ ! -d "$lab_dir" ]]; then
    echo "  [SKIP] $lab — directory not found"
    ((SKIPPED++))
    continue
  fi

  if [[ ! -f "$script" ]]; then
    echo "  [SKIP] $lab — $SCRIPT_NAME not found"
    ((SKIPPED++))
    continue
  fi

  printf "  %-12s ... " "$lab"
  if timeout 60 bash -c "cd '$lab_dir' && bash 'scripts/$SCRIPT_NAME'" > /dev/null 2>&1; then
    echo "done"
    ((PASSED++))
  else
    code=$?
    if [[ $code -eq 124 ]]; then
      echo "TIMED OUT after 60s"
    else
      echo "FAILED (exit $code)"
    fi
    ((FAILED++))
  fi
done

echo ""
echo "=== Complete: $PASSED done, $FAILED failed, $SKIPPED skipped ==="
