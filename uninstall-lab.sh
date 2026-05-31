#!/usr/bin/env bash
# uninstall-lab.sh — remove a lab from the dashboard.
#
# Usage:  ./uninstall-lab.sh <NN>
# Example: ./uninstall-lab.sh 01
#
# This only hides the lab from the dashboard. It does NOT:
#   - delete the lab folder
#   - delete pulled model weights
#   - stop running containers (run ./stop-all.sh first if the lab is active)
#
# Idempotent: re-running on an already-uninstalled lab prints a notice and exits 0.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <NN>" >&2
  exit 1
fi

# Accept any of: 01, 1, lab01, LAB01, lab1, LAB1 — normalize to a 2-digit number.
NN_RAW="$1"
NN_CLEAN="${NN_RAW,,}"
NN_CLEAN="${NN_CLEAN#lab}"
if ! [[ "$NN_CLEAN" =~ ^[0-9]+$ ]]; then
  echo "Error: argument must be a lab number (got '$NN_RAW')." >&2
  echo "Examples: $0 01    or    $0 lab01    or    $0 1" >&2
  exit 1
fi

NN=$(printf "%02d" "$NN_CLEAN")
N_INT=$((10#$NN))
LAB_ID="lab${NN}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$ROOT/service-dashboard/state/installed-labs.json"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "[skip] No labs are installed (state file does not exist)."
  exit 0
fi

python3 - "$STATE_FILE" "$LAB_ID" <<'PY'
import json, os, sys, tempfile

state_file, lab_id = sys.argv[1], sys.argv[2]
with open(state_file) as f:
    labs = json.load(f)
if lab_id not in labs:
    print(f"[skip] {lab_id} is not installed.")
    sys.exit(0)
labs = [x for x in labs if x != lab_id]
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(state_file), prefix=".installed-labs.")
with os.fdopen(fd, "w") as f:
    json.dump(labs, f, indent=2)
    f.write("\n")
os.replace(tmp, state_file)
print(f"[uninstalled] {lab_id}")
PY

echo ""
echo "✓ LAB ${NN} is uninstalled. Refresh the dashboard to confirm."
echo "  Files and pulled models are untouched. To free disk space:"
echo "    cd ${N_INT}._LAB${NN} && ./scripts/teardown.sh"
