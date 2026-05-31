#!/usr/bin/env bash
# install-lab.sh — register a lab with the dashboard.
#
# Usage:  ./install-lab.sh <NN>
# Example: ./install-lab.sh 01
#
# After running, refresh the dashboard at http://localhost:9000 — the lab tile
# will appear. This only registers the lab for display; it does NOT pull model
# weights or build containers. That happens when you click LAUNCH in the UI
# (or run the lab's scripts/start.sh directly).
#
# Idempotent: re-running with a lab already installed prints a notice and exits 0.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <NN>" >&2
  echo "Example: $0 01" >&2
  exit 1
fi

# Accept any of: 01, 1, lab01, LAB01, lab1, LAB1 — normalize to a 2-digit number.
NN_RAW="$1"
NN_CLEAN="${NN_RAW,,}"        # lowercase
NN_CLEAN="${NN_CLEAN#lab}"    # strip "lab" prefix if present
if ! [[ "$NN_CLEAN" =~ ^[0-9]+$ ]]; then
  echo "Error: argument must be a lab number (got '$NN_RAW')." >&2
  echo "Examples: $0 01    or    $0 lab01    or    $0 1" >&2
  exit 1
fi

NN=$(printf "%02d" "$NN_CLEAN")
N_INT=$((10#$NN))
LAB_ID="lab${NN}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$ROOT/${N_INT}._LAB${NN}"
STATE_FILE="$ROOT/service-dashboard/state/installed-labs.json"

# Verify the lab actually exists on disk
if [[ ! -d "$LAB_DIR" ]]; then
  echo "Error: lab folder not found at $LAB_DIR" >&2
  echo "Have you pulled the latest from the repo?" >&2
  exit 1
fi
if [[ ! -f "$LAB_DIR/lab.json" ]]; then
  echo "Error: $LAB_DIR/lab.json is missing." >&2
  exit 1
fi

# Initialize state dir + file
mkdir -p "$(dirname "$STATE_FILE")"
[[ -f "$STATE_FILE" ]] || echo "[]" > "$STATE_FILE"

# Add lab_id idempotently (atomic write via temp file + rename)
python3 - "$STATE_FILE" "$LAB_ID" <<'PY'
import json, os, sys, tempfile

state_file, lab_id = sys.argv[1], sys.argv[2]
with open(state_file) as f:
    labs = json.load(f)
if lab_id in labs:
    print(f"[skip] {lab_id} is already installed.")
    sys.exit(0)
labs.append(lab_id)
labs.sort()
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(state_file), prefix=".installed-labs.")
with os.fdopen(fd, "w") as f:
    json.dump(labs, f, indent=2)
    f.write("\n")
os.replace(tmp, state_file)
print(f"[installed] {lab_id}")
PY

# Read back the lab title for the success message
LAB_TITLE=$(python3 -c "import json; print(json.load(open('$LAB_DIR/lab.json')).get('title','?'))")
echo ""
echo "✓ LAB ${NN} (${LAB_TITLE}) is now installed."
echo "  Refresh http://localhost:9000 to see it on the dashboard."
echo "  Click [ LAUNCH ] on its tile to start it (first launch pulls model weights)."
