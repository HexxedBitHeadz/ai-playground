#!/usr/bin/env bash
# shared/progress.sh — progress reporting for lab start scripts.
#
# Usage (in a lab's scripts/start.sh):
#
#   _ROOT="$(cd "$(dirname "$0")/../../" && pwd)"
#   source "$_ROOT/shared/progress.sh"
#   progress_init 5                                  # total phases
#   progress_phase 1 "Starting containers"           # step 1 of 5
#   progress_phase 2 "Waiting for Ollama"
#   progress_phase 3 "Pulling models"
#   progress_detail "tinyllama:1.1b"                 # sub-message, same step
#   progress_detail "llama3.2:1b"
#   progress_phase 4 "Building custom models"
#   progress_done                                    # clears progress file
#
# Writes JSON to .dashboard-progress in the current working directory (cwd
# should be the lab folder when start.sh runs). The dashboard reads this file
# in its /api/status poll and renders it under the BOOTING badge.

PROGRESS_FILE="${PROGRESS_FILE:-.dashboard-progress}"
PROGRESS_TOTAL=1
PROGRESS_STEP=0
PROGRESS_LABEL=""

progress_init() {
  PROGRESS_TOTAL="${1:-1}"
  PROGRESS_STEP=0
  PROGRESS_LABEL=""
  rm -f "$PROGRESS_FILE" 2>/dev/null || true
}

# progress_phase <step> <label>
progress_phase() {
  PROGRESS_STEP="$1"
  PROGRESS_LABEL="$2"
  _progress_write ""
}

# progress_detail <text> — sub-message within the current step
progress_detail() {
  _progress_write "$1"
}

progress_done() {
  rm -f "$PROGRESS_FILE" 2>/dev/null || true
}

_progress_write() {
  local detail="$1"
  # Python is the safest way to write JSON with arbitrary strings (no quote issues)
  PROGRESS_LABEL="$PROGRESS_LABEL" \
  PROGRESS_DETAIL="$detail" \
  PROGRESS_STEP="$PROGRESS_STEP" \
  PROGRESS_TOTAL="$PROGRESS_TOTAL" \
  python3 - "$PROGRESS_FILE" <<'PY'
import json, os, sys, time, tempfile
target = sys.argv[1]
payload = {
    "step":        int(os.environ.get("PROGRESS_STEP", "0")),
    "total_steps": int(os.environ.get("PROGRESS_TOTAL", "1")),
    "label":       os.environ.get("PROGRESS_LABEL", ""),
    "detail":      os.environ.get("PROGRESS_DETAIL", ""),
    "ts":          time.time(),
}
d = os.path.dirname(os.path.abspath(target)) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".dashboard-progress.")
with os.fdopen(fd, "w") as f:
    json.dump(payload, f)
os.replace(tmp, target)
PY
}

# progress_pull <model>
#
# Pull an Ollama model with live byte-level progress. Streams the JSON pull
# events from Ollama's HTTP API and updates the .dashboard-progress detail
# line at most ~2× per second with the current bytes/total/percent/rate.
#
# Implementation note: we can't reliably reach Ollama from the host because
#   (a) Docker bridge IPs (172.x.x.x) aren't routed from the host on most setups
#   (b) The host's published port (11434) may be hijacked by a system Ollama
#       daemon that started before docker did
# So we run the HTTP request from INSIDE a helper container on the lab's docker
# network (default: webui — it's python:3.12-slim, has urllib in stdlib, and
# resolves "ollama" via docker DNS). Override with OLLAMA_HELPER_CONTAINER if
# the lab doesn't have a webui service.
#
# Returns non-zero if the pull request fails or Ollama emits an error event.
progress_pull() {
  local model="$1"
  local helper="${OLLAMA_HELPER_CONTAINER:-webui}"
  PROGRESS_FILE="$PROGRESS_FILE" \
  PROGRESS_STEP="$PROGRESS_STEP" \
  PROGRESS_TOTAL="$PROGRESS_TOTAL" \
  PROGRESS_LABEL="$PROGRESS_LABEL" \
  MODEL_NAME="$model" \
  HELPER_CONTAINER="$helper" \
  python3 -u - <<'PY'
import json, os, subprocess, sys, tempfile, time

state_file = os.environ["PROGRESS_FILE"]
model      = os.environ["MODEL_NAME"]
helper     = os.environ["HELPER_CONTAINER"]

def fmt_bytes(n):
    if n is None or n <= 0: return "0 B"
    units = ["B", "KB", "MB", "GB"]
    i = 0
    while n >= 1024 and i < len(units) - 1:
        n /= 1024.0
        i += 1
    if units[i] == "B":   return f"{int(n)} B"
    if units[i] == "KB":  return f"{n:.0f} KB"
    return f"{n:.2f} {units[i]}"

def write_detail(detail):
    payload = {
        "step":        int(os.environ.get("PROGRESS_STEP", "0")),
        "total_steps": int(os.environ.get("PROGRESS_TOTAL", "1")),
        "label":       os.environ.get("PROGRESS_LABEL", ""),
        "detail":      detail,
        "ts":          time.time(),
    }
    d = os.path.dirname(os.path.abspath(state_file)) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".dashboard-progress.")
    with os.fdopen(fd, "w") as f:
        json.dump(payload, f)
    os.replace(tmp, state_file)

write_detail(f"{model} — connecting...")

# Script that runs inside the helper container and streams JSON lines to stdout
inner = f'''
import json, sys, urllib.request
req = urllib.request.Request(
    "http://ollama:11434/api/pull",
    data=json.dumps({{"model": "{model}", "stream": True}}).encode(),
    headers={{"Content-Type": "application/json"}},
    method="POST",
)
with urllib.request.urlopen(req, timeout=600) as resp:
    for raw in resp:
        sys.stdout.write(raw.decode())
        sys.stdout.flush()
'''

proc = subprocess.Popen(
    ["docker", "exec", "-i", helper, "python3", "-u", "-c", inner],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)

UPDATE_INTERVAL = 0.5
last_bytes = 0
last_t     = time.time()
ema_bps    = 0.0
EMA_ALPHA  = 0.3
last_write = 0.0
saw_terminal = False

for raw in proc.stdout:
    try:
        msg = json.loads(raw)
    except Exception:
        continue
    now = time.time()
    status    = msg.get("status", "")
    total     = msg.get("total", 0) or 0
    completed = msg.get("completed", 0) or 0
    err       = msg.get("error")
    if err:
        write_detail(f"{model} — error: {err}")
        proc.terminate()
        sys.exit(1)
    is_terminal = "success" in status.lower()
    if not is_terminal and (now - last_write) < UPDATE_INTERVAL:
        continue
    last_write = now
    if total > 0 and completed > 0:
        pct = 100.0 * completed / total
        dt  = max(0.001, now - last_t)
        inst_bps = (completed - last_bytes) / dt
        ema_bps  = ema_bps * (1 - EMA_ALPHA) + inst_bps * EMA_ALPHA if ema_bps else inst_bps
        last_bytes = completed
        last_t     = now
        write_detail(
            f"{model} — {fmt_bytes(completed)} / {fmt_bytes(total)} "
            f"({pct:.0f}%) @ {fmt_bytes(ema_bps)}/s"
        )
    else:
        write_detail(f"{model} — {status or 'starting...'}")
    if is_terminal:
        saw_terminal = True
        write_detail(f"{model} — complete ({fmt_bytes(total) if total else 'done'})")
        break

proc.wait(timeout=5)
if not saw_terminal and proc.returncode != 0:
    stderr = (proc.stderr.read() or "").strip()[:200]
    write_detail(f"{model} — exited: {stderr or 'unknown error'}")
    sys.exit(proc.returncode or 1)
PY
}
