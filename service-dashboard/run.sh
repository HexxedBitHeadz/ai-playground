#!/usr/bin/env bash
# run.sh — launch the HeBi AI Playground dashboard.
# See ../README.md for the full setup guide.

set -euo pipefail
cd "$(dirname "$0")"

# ── Args ─────────────────────────────────────────────────────────────────────
HEBI_LITE=0
for arg in "$@"; do
  case "$arg" in
    --lite)
      HEBI_LITE=1 ;;
    -h|--help)
      cat <<EOF
Usage: ./run.sh [--lite]

Launches the HeBi AI Playground dashboard at http://localhost:9000.

Options:
  --lite    Pull only small models (tinyllama:1.1b, llama3.2:1b) on first
            lab start. ~2 GB instead of ~30 GB. Good for trying out the
            dashboard quickly or on a machine without a GPU.

See ../README.md for the full setup guide.
EOF
      exit 0 ;;
    *)
      echo "Unknown argument: $arg (use --help for usage)" >&2
      exit 2 ;;
  esac
done
export HEBI_LITE

# ── Colors (only if stdout is a tty) ──────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_YEL=$'\033[0;33m'; C_GRN=$'\033[0;32m'
  C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_YEL=''; C_GRN=''; C_DIM=''; C_BOLD=''; C_OFF=''
fi
say()  { echo "${C_DIM}→${C_OFF} $*"; }
warn() { echo "${C_YEL}⚠ $*${C_OFF}" >&2; }
err()  { echo "${C_RED}✗ $*${C_OFF}" >&2; }
ok()   { echo "${C_GRN}✓${C_OFF} $*"; }

# ── Preflight ────────────────────────────────────────────────────────────────
say "Preflight checks..."

# OS family
case "$(uname -s)" in
  Linux*) ;;
  Darwin*)
    err "macOS is not currently supported. The labs assume a systemd-managed ollama service and Linux container conventions."
    err "Use a Linux VM or WSL2 for now. See README.md for the support matrix."
    exit 1 ;;
  *)
    err "Unsupported OS: $(uname -s). Linux or WSL2 required."
    exit 1 ;;
esac

# curl — used by the ollama installer path below and by the dashboard's
# health probes. Ubuntu 24.04 ships with it; minimal containers and some
# stripped distros don't.
if ! command -v curl &>/dev/null; then
  err "curl not found. Install with: sudo apt install -y curl"
  exit 1
fi

# Python
if ! command -v python3 &>/dev/null; then
  err "python3 not found. Install with: sudo apt install python3 python3-venv"
  exit 1
fi
PYTHON_VERSION="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
PYTHON_MAJOR="$(echo "$PYTHON_VERSION" | cut -d. -f1)"
PYTHON_MINOR="$(echo "$PYTHON_VERSION" | cut -d. -f2)"
if (( PYTHON_MAJOR < 3 )) || (( PYTHON_MAJOR == 3 && PYTHON_MINOR < 9 )); then
  err "Python 3.9+ required (found $PYTHON_VERSION)."
  exit 1
fi
# Debian/Ubuntu split: 'import venv' works (stdlib) but 'python3 -m venv'
# also needs the bundled pip wheels from the 'python3-venv' apt package.
# The only reliable check is to actually try creating a venv. ~200ms cost,
# catches the failure where we'd otherwise hit "ensurepip is not available"
# minutes later in the script.
_venv_test="$(mktemp -d)/_venv_probe"
if ! python3 -m venv "$_venv_test" &>/dev/null; then
  rm -rf "$(dirname "$_venv_test")"
  warn "python3 is installed but 'python3 -m venv' is not functional."
  warn "Cold-start gotcha: Debian/Ubuntu split venv's pip bundle into the"
  warn "'python3-venv' package. python3 imports venv fine, but venv can't"
  warn "create a working environment without the bundled wheels."
  if command -v apt-get &>/dev/null; then
    warn "About to: sudo apt-get install -y python3-venv"
    read -r -p "Proceed? [y/N] " ans
    if [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; then
      sudo apt-get install -y python3-venv
      # Verify the install actually fixed it
      _venv_test2="$(mktemp -d)/_venv_probe2"
      if ! python3 -m venv "$_venv_test2" &>/dev/null; then
        rm -rf "$(dirname "$_venv_test2")"
        err "Install completed but 'python3 -m venv' still fails. Run:"
        err "  python3 -m venv /tmp/test"
        err "and check the error manually."
        exit 1
      fi
      rm -rf "$(dirname "$_venv_test2")"
    else
      err "Aborted. Install python3-venv manually and re-run."
      exit 1
    fi
  else
    err "Install the venv module via your package manager (e.g. python3-venv on Debian/Ubuntu)."
    exit 1
  fi
else
  rm -rf "$(dirname "$_venv_test")"
fi

# Docker — auto-detect and offer to install/start. Three cases:
#
#   (a) docker not installed   → offer to apt-install docker.io + compose
#   (b) docker installed, no daemon, user not in docker group
#         → tell them to relogin (group membership doesn't update mid-session)
#   (c) docker installed, daemon down, user in docker group
#         → offer sudo systemctl start docker
#
# In each case the user can say no, and we continue with a warning — the
# dashboard itself runs without docker, just [INSTALL]/[LAUNCH] will fault
# until Docker is reachable.
_is_wsl=0
grep -qi microsoft /proc/version 2>/dev/null && _is_wsl=1

_have_systemd() {
  command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]
}
_user_in_docker_group() {
  id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker
}

if ! command -v docker &>/dev/null; then
  warn "docker not found."
  warn "About to install Docker Engine from the standard Ubuntu apt repo:"
  warn "  sudo apt-get install -y docker.io docker-compose-v2"
  warn "  sudo usermod -aG docker $USER"
  warn "  sudo systemctl enable --now docker     (or service docker start)"
  warn ""
  warn "After install, you'll need to exit + reopen this shell so the new"
  warn "'docker' group membership takes effect."
  read -r -p "Proceed? [y/N] " ans
  if [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; then
    say "Installing Docker Engine..."
    if ! sudo apt-get install -y docker.io docker-compose-v2; then
      err "apt-get install failed. Try 'sudo apt-get update' first, or install Docker manually."
      exit 1
    fi
    sudo usermod -aG docker "$USER" || true
    if _have_systemd; then
      sudo systemctl enable --now docker || warn "systemctl enable failed; trying service"
    fi
    # Fallback path for distros without systemd (older WSL configs, etc.)
    if ! sudo docker info &>/dev/null; then
      sudo service docker start 2>/dev/null || true
      sleep 2
    fi
    if ! sudo docker info &>/dev/null; then
      err "Docker installed but daemon won't start. Check 'systemctl status docker'"
      err "or 'sudo service docker status' for hints."
      exit 1
    fi
    ok "Docker Engine installed and daemon is running."
    echo ""
    warn "ONE MORE STEP: your current shell isn't in the 'docker' group yet."
    warn "Group membership only applies to NEW shells. Exit and reopen:"
    if (( _is_wsl )); then
      warn "  exit                          # close this WSL shell"
      warn "  (open a new WSL terminal)"
    else
      warn "  exit                          # then start a new shell"
    fi
    warn "Then re-run:"
    warn "  cd ~/$(basename "$(cd .. && pwd)")/service-dashboard && ./run.sh"
    exit 0
  else
    warn "Aborted Docker install. The dashboard will start, but no lab can launch."
    warn "Continuing anyway in 3s — Ctrl-C to abort."
    sleep 3
  fi
elif ! docker info &>/dev/null; then
  if ! _user_in_docker_group; then
    warn "Docker is installed but you're not in the 'docker' group in THIS shell."
    warn "Group membership only updates in NEW shells. Exit and reopen:"
    if (( _is_wsl )); then
      warn "  exit                          # close this WSL shell"
      warn "  (open a new WSL terminal)"
    fi
    warn "Then re-run this script. If you're already in the docker group in"
    warn "other shells, run 'id -nG' to confirm and check 'sudo systemctl status docker'."
    exit 1
  fi
  warn "Docker is installed but the daemon isn't responding."
  if _have_systemd; then
    warn "About to: sudo systemctl start docker"
  else
    warn "About to: sudo service docker start"
  fi
  read -r -p "Proceed? [y/N] " ans
  if [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; then
    if _have_systemd; then
      sudo systemctl start docker || sudo service docker start || true
    else
      sudo service docker start || true
    fi
    sleep 2
    if ! docker info &>/dev/null; then
      err "Docker daemon still not responding. Check 'systemctl status docker'"
      err "or 'journalctl -u docker' for the root cause."
      exit 1
    fi
    ok "Docker daemon is now running."
  else
    warn "Aborted. The dashboard will start, but [INSTALL] / [LAUNCH] will fault"
    warn "until Docker is reachable. Continuing anyway in 3s."
    sleep 3
  fi
fi

# Disk space — LAB01 pulls ~30 GB in standard mode, ~2 GB in --lite mode
PLAYGROUND_ROOT="$(cd .. && pwd)"
FREE_GB="$(df -BG --output=avail "$PLAYGROUND_ROOT" | tail -1 | tr -dc '0-9')"
if (( HEBI_LITE == 1 )); then
  _PULL_SIZE="~2 GB"; _DISK_THRESHOLD=5
else
  _PULL_SIZE="~30 GB"; _DISK_THRESHOLD=40
fi
if [[ -n "$FREE_GB" ]] && (( FREE_GB < _DISK_THRESHOLD )); then
  warn "Only ${FREE_GB} GB free on this volume. LAB 01 pulls ${_PULL_SIZE} of model weights on first launch."
  warn "Consider freeing space before starting any lab. Continuing in 3s..."
  sleep 3
fi

# NVIDIA GPU detection — informational, not fatal. Gate on the Docker
# *runtime* and not just the hardware: on WSL2 + Docker Engine, the Windows
# NVIDIA driver shims nvidia-smi into the distro automatically, but the
# nvidia-container-toolkit (which Docker needs to pass GPUs into containers)
# is a separate apt install. If we trusted nvidia-smi alone we'd attach
# docker-compose.gpu.yml and `compose up` would fail with "could not select
# device driver nvidia".
GPU_HARDWARE_PRESENT=0
if (command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null) || [[ -e /dev/nvidia0 ]]; then
  GPU_HARDWARE_PRESENT=1
fi

_docker_has_nvidia_runtime() {
  docker info 2>/dev/null | grep -qE '^\s*Runtimes:.*nvidia'
}

GPU_AVAILABLE=0
if (( GPU_HARDWARE_PRESENT == 1 )) && _docker_has_nvidia_runtime; then
  GPU_AVAILABLE=1
fi

# Hardware present but Docker can't use it — offer to install the toolkit.
# Same pattern as the Docker auto-install above: tell the user exactly what
# we'd run, ask, then do it. Declining keeps the previous CPU-fallback path.
if (( GPU_HARDWARE_PRESENT == 1 && GPU_AVAILABLE == 0 )); then
  warn "NVIDIA hardware detected (nvidia-smi works) but Docker has no"
  warn "'nvidia' container runtime registered. To use the GPU we need to"
  warn "install nvidia-container-toolkit:"
  warn "  1. Add NVIDIA's apt repo (signed)"
  warn "  2. sudo apt install -y nvidia-container-toolkit"
  warn "  3. sudo nvidia-ctk runtime configure --runtime=docker"
  warn "  4. restart docker"
  read -r -p "Install GPU support now? Declining keeps CPU mode. [y/N] " ans
  if [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]; then
    say "Installing nvidia-container-toolkit..."
    _install_ok=1
    # 1. Add NVIDIA's apt repo. Use the canonical 'stable/deb' channel.
    if ! curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
         | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg; then
      err "Couldn't fetch NVIDIA's gpg key. Check network / DNS."
      _install_ok=0
    fi
    if (( _install_ok == 1 )); then
      curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null \
        || { err "Couldn't write apt source list."; _install_ok=0; }
    fi
    if (( _install_ok == 1 )); then
      sudo apt-get update -qq || warn "apt-get update reported errors; continuing."
      if ! sudo apt-get install -y nvidia-container-toolkit; then
        err "apt-get install nvidia-container-toolkit failed."
        _install_ok=0
      fi
    fi
    if (( _install_ok == 1 )); then
      sudo nvidia-ctk runtime configure --runtime=docker \
        || { err "nvidia-ctk runtime configure failed."; _install_ok=0; }
    fi
    if (( _install_ok == 1 )); then
      if _have_systemd; then
        sudo systemctl restart docker || warn "systemctl restart docker failed; trying service."
      fi
      sudo service docker restart 2>/dev/null || true
      sleep 2
    fi
    # Verify.
    if (( _install_ok == 1 )) && _docker_has_nvidia_runtime; then
      ok "nvidia-container-toolkit installed and Docker's nvidia runtime is registered."
      GPU_AVAILABLE=1
    else
      warn "Install ran but Docker still doesn't list the nvidia runtime."
      warn "Falling back to CPU. Run 'docker info | grep -i runtime' to debug."
    fi
    unset _install_ok
  fi
fi

export HEBI_NO_GPU=$(( 1 - GPU_AVAILABLE ))

if (( GPU_AVAILABLE == 0 )); then
  if (( GPU_HARDWARE_PRESENT == 1 )); then
    warn "Running on CPU despite having NVIDIA hardware. Re-run setup and"
    warn "accept the GPU install prompt to enable GPU mode later."
  else
    warn "No NVIDIA GPU detected — labs will run on CPU (10-100× slower)."
  fi
  warn "Strongly recommended: run with --lite to limit pulls to small models:"
  warn "      ./run.sh --lite"
fi

_summary="Linux, Python $PYTHON_VERSION"
[[ -n ${FREE_GB:-} ]] && _summary="$_summary, ${FREE_GB} GB free"
(( GPU_AVAILABLE == 1 )) && _summary="$_summary, NVIDIA GPU" || _summary="$_summary, CPU only"
(( HEBI_LITE == 1 ))    && _summary="$_summary, LITE mode"
ok "Preflight OK ($_summary)"

# ── Ollama install (binary only — daemon runs in lab containers) ─────────────
# Each lab's docker-compose spins up its own ollama container on port 11434.
# A host-side ollama daemon (systemd or our own background `ollama serve`)
# would compete for the same port and the container's `up -d` would fail
# with "address already in use". So: install the binary if missing so users
# have the CLI for sanity checks, then immediately stop+disable the systemd
# unit the installer auto-enables.
if ! command -v ollama &>/dev/null; then
  warn "Ollama not found — about to install it from https://ollama.com/install.sh"
  warn "This will:"
  warn "  1. Run 'sudo apt-get install -y zstd' (if apt-get is available)"
  warn "  2. Pipe the official Ollama install script into 'sh'"
  warn "  3. Stop + disable the systemd ollama service the installer enables"
  warn "     (the lab containers provide ollama; a host daemon would fight"
  warn "     them for port 11434)"
  read -r -p "Proceed? [y/N] " ans
  if [[ "${ans,,}" != "y" && "${ans,,}" != "yes" ]]; then
    err "Aborted. Install Ollama manually and re-run."
    exit 1
  fi
  if command -v apt-get &>/dev/null; then
    sudo apt-get install -y zstd &>/dev/null || warn "zstd install failed; Ollama install may still work."
  else
    warn "apt-get not available — skipping zstd. If Ollama install fails, install zstd via your package manager."
  fi
  curl -fsSL https://ollama.com/install.sh | sh
fi

# Ensure no host-side ollama daemon is fighting the lab containers for
# port 11434. Disabling on every run is idempotent and protects against
# the systemd service getting re-enabled by an update or manual action.
if systemctl list-unit-files ollama.service &>/dev/null 2>&1; then
  if systemctl is-active ollama &>/dev/null || systemctl is-enabled ollama &>/dev/null; then
    say "Stopping + disabling host-side ollama systemd unit (lab containers provide ollama on 11434)..."
    sudo systemctl stop ollama 2>/dev/null || true
    sudo systemctl disable ollama 2>/dev/null || true
  fi
fi
# Also kill any stray foreground `ollama serve` (e.g. left over from an
# older run.sh that started one in the background).
if pgrep -x ollama &>/dev/null; then
  say "Killing stray ollama processes..."
  pkill -x ollama 2>/dev/null || true
  sleep 1
fi
if curl -sf --max-time 2 http://localhost:11434/api/version >/dev/null 2>&1; then
  # The lab's own ollama container also listens on 11434 — that's expected
  # when a lab is already up. Only warn if NO lab ollama container is running,
  # which means some unknown host process is squatting and the lab won't be
  # able to bind. Avoid command -v / docker calls failing the script under
  # set -u by guarding their absence.
  if command -v docker >/dev/null 2>&1 && \
     docker ps --format '{{.Names}}' 2>/dev/null | grep -qx ollama; then
    : # lab's ollama container owns 11434 — desired state, no warning
  else
    warn "Something is still listening on port 11434 after our cleanup."
    warn "Run 'sudo lsof -i :11434' to find it. The lab container needs that port."
  fi
fi

# ── Python venv + deps ───────────────────────────────────────────────────────
if [[ ! -f .venv/bin/activate ]]; then
  [[ -d .venv ]] && rm -rf .venv
  say "Creating virtual environment..."
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q -r requirements.txt

# ── Free port 9000 if a stale dashboard is still bound ───────────────────────
# Tries fuser first (psmisc — usually present), falls back to lsof. If neither
# is installed, uvicorn's own bind error will tell the user clearly enough.
if command -v fuser &>/dev/null && fuser 9000/tcp &>/dev/null; then
  warn "Port 9000 in use — stopping the existing process..."
  fuser -k 9000/tcp 2>/dev/null || true
  sleep 0.5
elif command -v lsof &>/dev/null && lsof -ti:9000 &>/dev/null; then
  warn "Port 9000 in use — stopping the existing process..."
  kill "$(lsof -ti:9000)" 2>/dev/null || true
  sleep 0.5
fi

# ── Launch ───────────────────────────────────────────────────────────────────
echo ""
echo "${C_BOLD}================================================${C_OFF}"
echo "${C_BOLD}  Hexxed BitHeadz — AI Security Lab Dashboard${C_OFF}"
echo "  ${C_GRN}http://localhost:9000${C_OFF}"
echo "${C_BOLD}================================================${C_OFF}"
echo ""

# Bind to all interfaces so a Windows browser can reach the dashboard via
# the WSL distro's IP under WSL2 mirrored networking (where Windows
# localhost ↔ WSL localhost forwarding is unreliable). 127.0.0.1-only
# bind made the page show ERR_CONNECTION_RESET in some setups.
exec uvicorn app:app --host 0.0.0.0 --port 9000 --no-access-log
