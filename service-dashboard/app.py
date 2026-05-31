import json
import os
import re
import shutil
import subprocess
import threading
import time
from pathlib import Path
from typing import Optional

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.requests import Request

PLAYGROUND_ROOT = Path(__file__).parent.parent

# Set by run.sh based on the --lite flag. Used by the template to label the
# dashboard's mode badge accurately.
HEBI_LITE = os.environ.get("HEBI_LITE", "0") == "1"

# Folder-name pattern is "<N>._LAB<NN>". Sort by leading integer so the dashboard
# orders labs the way the filesystem does.
_LAB_FOLDER_RE = re.compile(r"^(\d+)\._LAB\d+$")


def _discover_labs() -> list[dict]:
    """Load lab definitions from <folder>/lab.json. Folder name is the slug.

    Only includes labs flagged "released": true. Unreleased labs stay on disk
    (so the author can keep editing them) but are invisible to the dashboard.
    """
    labs: list[tuple[int, dict]] = []
    for entry in PLAYGROUND_ROOT.iterdir():
        if not entry.is_dir():
            continue
        m = _LAB_FOLDER_RE.match(entry.name)
        if not m:
            continue
        manifest = entry / "lab.json"
        if not manifest.is_file():
            continue
        with manifest.open() as f:
            data = json.load(f)
        if not data.get("released", False):
            continue
        data["slug"] = entry.name
        labs.append((int(m.group(1)), data))
    labs.sort(key=lambda pair: pair[0])
    return [lab for _, lab in labs]


ALL_LABS = _discover_labs()
LAB_BY_ID = {lab["id"]: lab for lab in ALL_LABS}

# docker compose project name = slug lowercased with dots removed
# e.g. "1._LAB01" -> "1_lab01"
_PROJECT_NAMES = {lab["id"]: lab["slug"].lower().replace(".", "") for lab in ALL_LABS}

# Installed-labs registry. Lives outside the repo (gitignored) so a fresh clone
# always starts empty. install-lab.sh / uninstall-lab.sh edit this file.
_INSTALL_STATE = Path(__file__).parent / "state" / "installed-labs.json"


def installed_lab_ids() -> list[str]:
    """Read the installed-labs state file. Re-read each request so install
    actions take effect without restarting the dashboard."""
    if not _INSTALL_STATE.is_file():
        return []
    try:
        with _INSTALL_STATE.open() as f:
            data = json.load(f)
        return [lab_id for lab_id in data if lab_id in LAB_BY_ID]
    except Exception:
        return []


def installed_labs() -> list[dict]:
    """Discovered labs filtered by the installed-labs registry, in dashboard order."""
    ids = set(installed_lab_ids())
    return [lab for lab in ALL_LABS if lab["id"] in ids]


# In-memory state: id -> "starting" | "stopping" | "error" | None
_transitions: dict[str, Optional[str]] = {}
_lock = threading.Lock()

# Last error message per lab — populated when _run_install / _run_start /
# _run_stop hits an exception. Surfaced in /api/status so the UI can show
# the user WHY a tile is in FAULT instead of a generic red badge.
_lab_errors: dict[str, str] = {}

# Docker status cache — kept fresh by a background thread
_docker_cache: dict[str, bool] = {lab["id"]: False for lab in ALL_LABS}
_cache_lock = threading.Lock()


def _docker_available() -> tuple[bool, str]:
    """Check whether the Docker daemon is responsive. Returns (ok, error_msg).
    If ok is False, error_msg is a one-paragraph user-facing explanation
    suitable for the FAULT UI."""
    try:
        result = subprocess.run(
            ["docker", "info"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return True, ""
        stderr = (result.stderr or "").strip()
        # Detect WSL specifically — the fix is "start Docker Desktop on Windows"
        is_wsl = False
        try:
            with open("/proc/version") as f:
                is_wsl = "microsoft" in f.read().lower()
        except Exception:
            pass
        msg = (
            "Docker daemon is not responding. The install can't build images "
            "or pull models until Docker is running.\n\n"
        )
        if is_wsl:
            msg += (
                "You're on WSL. Open Docker Desktop on the Windows host, then "
                "Settings → Resources → WSL Integration → toggle THIS distro on. "
                "Once Docker Desktop is running, click [ DISMISS ] on this tile "
                "and then [ INSTALL ] again."
            )
        else:
            msg += (
                "On Linux: sudo systemctl start docker. On Docker Desktop "
                "(macOS / Windows): start Docker Desktop. Then click "
                "[ DISMISS ] and [ INSTALL ] again."
            )
        if stderr:
            msg += f"\n\nRaw error from `docker info`:\n{stderr[:500]}"
        return False, msg
    except FileNotFoundError:
        return False, (
            "`docker` command not found. Install Docker Engine (Linux) or "
            "Docker Desktop (WSL2 / macOS), then click [ DISMISS ] and "
            "[ INSTALL ] again."
        )
    except subprocess.TimeoutExpired:
        return False, (
            "Docker daemon is unresponsive (`docker info` timed out after 5s). "
            "Restart Docker, then click [ DISMISS ] and [ INSTALL ] again."
        )
    except Exception as e:
        return False, f"Unexpected error checking Docker: {e}"


def _refresh_docker_cache() -> None:
    """Single `docker compose ls` call — gives running project names reliably.

    A project is considered "running" only when ALL its services are up.
    `compose ls` reports partial states like "running(1), exited(1)" when one
    container failed (e.g. ollama can't bind 11434 because something else owns
    the port). Treating those as ONLINE would mask the failure — the dashboard
    would say green while the lab is half-broken."""
    bad_states = ("exited", "restarting", "dead", "paused", "created")
    try:
        result = subprocess.run(
            ["docker", "compose", "ls", "--all", "--format", "json"],
            capture_output=True, text=True, timeout=10,
        )
        projects = json.loads(result.stdout or "[]")
        running = set()
        for p in projects:
            status_str = p.get("Status", "").lower()
            if "running" in status_str and not any(s in status_str for s in bad_states):
                running.add(p["Name"].lower())
        cache = {
            lab["id"]: _PROJECT_NAMES[lab["id"]] in running
            for lab in ALL_LABS
        }
        with _cache_lock:
            _docker_cache.update(cache)
    except Exception:
        pass


def _cache_loop() -> None:
    """Background thread: refresh docker state every 8 seconds."""
    while True:
        _refresh_docker_cache()
        time.sleep(8)


# Seed cache and start docker-state refresher at module import. Fine for
# single-process uvicorn (the normal case here); surprising if you grep for
# thread creation expecting it inside a startup handler.
_refresh_docker_cache()
threading.Thread(target=_cache_loop, daemon=True).start()


app = FastAPI(title="Hexxed BitHeadz AI Security Labs")
templates = Jinja2Templates(directory=str(Path(__file__).parent / "templates"))

branding_dir = PLAYGROUND_ROOT / "shared" / "branding"
if branding_dir.exists():
    app.mount("/static/branding", StaticFiles(directory=str(branding_dir)), name="branding")


def _compose_dir(lab: dict) -> Path:
    return PLAYGROUND_ROOT / lab["slug"]


def get_lab_status(lab: dict) -> str:
    with _lock:
        transition = _transitions.get(lab["id"])
    # If containers are already up, report ONLINE even if the start script
    # is still running post-startup tasks (model checks, egress rules, etc.)
    if transition == "starting":
        with _cache_lock:
            if _docker_cache.get(lab["id"], False):
                return "running"
        return "starting"
    # During install we always report "installing" — never "running" even if a
    # container is briefly up. install.sh ends with `docker compose stop`, so
    # the steady state after install is "stopped".
    if transition == "installing":
        return "installing"
    if transition == "error":
        # Sticky until the user dismisses. Previously we auto-cleared if any
        # container happened to be up, but that masked partial failures: e.g.
        # chroma starts, ollama fails to bind 11434, start.sh exits non-zero,
        # we set "error" — then auto-clear would flip to "running" the moment
        # _docker_cache saw chroma up. User would see ONLINE on a broken lab.
        # The cache fix above already excludes partial projects, but keeping
        # the error sticky belt-and-suspenders the failure into being visible.
        return "error"
    if transition:
        return transition
    with _cache_lock:
        return "running" if _docker_cache.get(lab["id"], False) else "stopped"


def _run_lab_subprocess(lab: dict, cmd: list[str], log_name: str,
                        timeout: int | None = None) -> None:
    """Run cmd in lab_dir, capturing stdout+stderr to logs/<log_name>.

    timeout=None (the default) lets the process run as long as it needs.
    A wall-clock cap can't tell "slow but progressing" from "deadlocked",
    so we let model pulls and image builds take their natural time. The
    TERMINATE button is the user's manual kill switch (it tears down
    containers, which makes any in-flight `docker exec` from install.sh
    fail and the script exit). Pass a number only for quick ops where a
    hang is genuinely abnormal (e.g. `docker compose down`)."""
    lab_dir = _compose_dir(lab)
    log_dir = lab_dir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / log_name
    with log_path.open("w") as log_file:
        log_file.write(f"=== {time.strftime('%Y-%m-%d %H:%M:%S')} {' '.join(cmd)} ===\n")
        log_file.flush()
        subprocess.run(
            cmd,
            cwd=str(lab_dir),
            timeout=timeout,
            check=True,
            stdout=log_file,
            stderr=subprocess.STDOUT,
        )


def _set_error(lab_id: str, message: str) -> None:
    """Mark a lab as errored and record the human-readable explanation so the
    UI can render it next to the FAULT badge instead of leaving the user
    guessing."""
    with _lock:
        _transitions[lab_id] = "error"
        _lab_errors[lab_id] = message


def _failure_log_hint(lab: dict, primary: str) -> str:
    """Build the 'see logs/…' hint for a FAULT message.

    install.sh redirects its `docker compose` output into logs/install.log
    (`>>logs/install.log 2>&1`) so the LIVE OUTPUT pane can tail it cleanly.
    That means the actual cause of most failures (compose errors, model-pull
    errors, GPU runtime errors) lives in install.log — NOT in the dashboard's
    own captured log. If install.log exists with content, point at it first."""
    install_log = _compose_dir(lab) / "logs" / "install.log"
    if install_log.is_file() and install_log.stat().st_size > 0:
        return (
            f"See logs/install.log for the docker compose output "
            f"(usually the actual cause) — or logs/{primary} for the "
            f"script's own output."
        )
    return f"See logs/{primary} for the captured output."


def _run_start(lab_id: str) -> None:
    lab = LAB_BY_ID[lab_id]
    script = _compose_dir(lab) / "scripts" / "start.sh"

    ok, docker_err = _docker_available()
    if not ok:
        _set_error(lab_id, docker_err)
        return

    try:
        # No timeout: start.sh may transitively run install.sh for a fresh
        # lab and pull tens of GB of model weights. Cap is the TERMINATE
        # button. See _run_lab_subprocess docstring.
        _run_lab_subprocess(lab, ["bash", str(script)], "dashboard-start.log")
        # Force cache refresh before clearing transition so next poll sees ONLINE
        _refresh_docker_cache()
        with _lock:
            _transitions.pop(lab_id, None)
            _lab_errors.pop(lab_id, None)
    except subprocess.CalledProcessError as e:
        _set_error(lab_id,
                   f"start.sh exited with code {e.returncode}. " +
                   _failure_log_hint(lab, "dashboard-start.log"))
    except Exception as e:
        _set_error(lab_id, f"Start failed: {e}")


def _run_install(lab_id: str) -> None:
    """Run the lab's one-time install.sh (heavy: pull models, build images, etc.).

    Fallback: if a lab doesn't ship a dedicated install.sh, we run start.sh
    instead — the older mixed pattern where start.sh does both setup and launch.
    Preserves backwards-compat for labs that haven't been refactored to the
    install/start split yet.
    """
    lab = LAB_BY_ID[lab_id]
    lab_dir = _compose_dir(lab)
    install_script = lab_dir / "scripts" / "install.sh"
    start_script = lab_dir / "scripts" / "start.sh"
    if install_script.is_file():
        script = install_script
    elif start_script.is_file():
        script = start_script
    else:
        _set_error(lab_id, f"No install.sh or start.sh found in {lab_dir}/scripts/")
        return

    # Pre-check Docker before kicking off install.sh — its first step is
    # `docker compose up -d` which fails opaquely if the daemon is down.
    # Fail fast with a clear user-facing explanation instead.
    ok, docker_err = _docker_available()
    if not ok:
        _set_error(lab_id, docker_err)
        return

    try:
        # No timeout: pulls of large model weights can take hours on slow
        # connections. TERMINATE is the user's kill switch.
        _run_lab_subprocess(lab, ["bash", str(script)], "dashboard-install.log")
        _refresh_docker_cache()
        with _lock:
            _transitions.pop(lab_id, None)
            _lab_errors.pop(lab_id, None)
    except subprocess.CalledProcessError as e:
        _set_error(lab_id,
                   f"install.sh exited with code {e.returncode}. " +
                   _failure_log_hint(lab, "dashboard-install.log"))
    except Exception as e:
        _set_error(lab_id, f"Install failed: {e}")


def _run_stop(lab_id: str) -> None:
    """Stop lab, remove volumes, and wipe session data. Ollama model weights are preserved."""
    lab = LAB_BY_ID[lab_id]
    lab_dir = _compose_dir(lab)
    try:
        _run_lab_subprocess(
            lab,
            ["docker", "compose", "down", "-v", "--remove-orphans"],
            "dashboard-stop.log",
            120,
        )
        # Clean up any leftover progress file (in case start.sh died mid-flight)
        progress_file = lab_dir / ".dashboard-progress"
        if progress_file.exists():
            progress_file.unlink()
        logs_dir = lab_dir / "logs"
        if logs_dir.exists():
            shutil.rmtree(logs_dir)
        data_dir = lab_dir / "data"
        if data_dir.exists():
            for child in data_dir.iterdir():
                if child.name == "ollama":
                    continue
                if child.is_dir():
                    shutil.rmtree(child)
                else:
                    child.unlink()
        _refresh_docker_cache()
        with _lock:
            _transitions.pop(lab_id, None)
            _lab_errors.pop(lab_id, None)
    except Exception as e:
        _set_error(lab_id, f"Stop failed: {e}")


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    installed_ids = set(installed_lab_ids())
    labs = [dict(lab, installed=(lab["id"] in installed_ids)) for lab in ALL_LABS]
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "labs": labs,
            "any_installed": len(installed_ids) > 0,
            "any_released": len(ALL_LABS) > 0,
            "installed_count": len(installed_ids),
            "hebi_lite": HEBI_LITE,
        },
    )


def _read_progress(lab: dict) -> Optional[dict]:
    """Read .dashboard-progress from the lab folder. Returns None if absent/invalid."""
    pf = _compose_dir(lab) / ".dashboard-progress"
    if not pf.is_file():
        return None
    try:
        with pf.open() as f:
            return json.load(f)
    except Exception:
        return None


def _read_live_log_tail(lab: dict, max_bytes: int = 3000) -> Optional[str]:
    """Return the tail of logs/install.log so the UI can stream a small
    terminal-style pane while phase 2 (docker compose build) is running.

    install.sh routes its docker output here via `>>logs/install.log 2>&1`.
    Returns the last `max_bytes` of UTF-8 content with progress carriage-
    return spam stripped so the panel doesn't fill with overwritten lines."""
    log_path = _compose_dir(lab) / "logs" / "install.log"
    if not log_path.is_file():
        return None
    try:
        size = log_path.stat().st_size
        with log_path.open("rb") as f:
            if size > max_bytes:
                f.seek(size - max_bytes)
            data = f.read()
        text = data.decode("utf-8", errors="replace")
        # Docker progress lines use \r to overwrite — collapse so the panel
        # shows the latest state of each line instead of stacked rewrites.
        text = "\n".join(line.split("\r")[-1] for line in text.splitlines())
        return text or None
    except Exception:
        return None


@app.get("/api/status")
async def api_status():
    result = {}
    for lab in installed_labs():
        lab_id = lab["id"]
        entry = {"status": get_lab_status(lab)}
        # Include progress whenever start.sh is still writing to the file. It
        # may keep working after status flips to "running" (e.g., building
        # custom modelfiles after containers are healthy) — surface that.
        progress = _read_progress(lab)
        if progress:
            entry["progress"] = progress
            # While progress is active, also stream the tail of install.log
            # so the UI can render a small live-output pane under the
            # progress bar. Best signal a reader has during the slow
            # phase-2 docker image builds.
            tail = _read_live_log_tail(lab)
            if tail:
                entry["live_log"] = tail
        # Surface the last error message so the UI can show WHY a tile is in
        # FAULT instead of just a red badge.
        if entry["status"] == "error":
            err = _lab_errors.get(lab_id)
            if err:
                entry["error_message"] = err
            # Tell the UI which log files exist so it can render the matching
            # buttons. install.log = docker compose output (usually the actual
            # cause). dashboard-install.log / dashboard-start.log = the
            # script's own wrapped stdout.
            logs_dir = _compose_dir(lab) / "logs"
            if (logs_dir / "install.log").is_file():
                entry["has_compose_log"] = True
            if (logs_dir / "dashboard-install.log").is_file():
                entry["has_install_log"] = True
            if (logs_dir / "dashboard-start.log").is_file():
                entry["has_start_log"] = True
        result[lab_id] = entry
    return result


# Whitelist of log files the UI is allowed to fetch. Anything not in here
# is rejected — keeps the endpoint from turning into a generic file reader.
_VIEWABLE_LOGS = {
    "install":           "install.log",
    "dashboard-install": "dashboard-install.log",
    "dashboard-start":   "dashboard-start.log",
}


def _read_capped_log(path: Path) -> tuple[str, str]:
    if not path.is_file():
        return f"(no log yet at {path.name})", str(path)
    content = path.read_text(errors="replace")
    if len(content) > 200_000:
        content = "...[truncated to last 200 KB]...\n" + content[-200_000:]
    return content, str(path)


@app.get("/api/labs/{lab_id}/log/{name}")
async def view_log(lab_id: str, name: str):
    """Tail of one of the lab's log files. `name` must be in the whitelist
    above. Surfaced from the FAULT state UI so users can see WHY something
    failed without dropping into a terminal — and we can route them to the
    right file (install.log carries docker compose errors; the dashboard-*
    logs carry the script's own wrapped stdout)."""
    if lab_id not in LAB_BY_ID:
        raise HTTPException(status_code=404, detail="Lab not found")
    if name not in _VIEWABLE_LOGS:
        raise HTTPException(status_code=400, detail=f"Unknown log: {name}")
    lab = LAB_BY_ID[lab_id]
    log_path = _compose_dir(lab) / "logs" / _VIEWABLE_LOGS[name]
    try:
        content, file_str = _read_capped_log(log_path)
        return {"log": content, "log_file": file_str}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/labs/{lab_id}/install-log")
async def install_log(lab_id: str):
    """Back-compat shim — older UI builds and external scripts may still
    hit this path. Returns the same content as /log/dashboard-install."""
    return await view_log(lab_id, "dashboard-install")


@app.post("/api/labs/{lab_id}/start")
async def start_lab(lab_id: str):
    if lab_id not in LAB_BY_ID:
        raise HTTPException(status_code=404, detail="Lab not found")

    for lab in ALL_LABS:
        status = get_lab_status(lab)
        if lab["id"] != lab_id and status in ("running", "starting"):
            raise HTTPException(
                status_code=409,
                detail=f"{lab['name']} is already active. Stop it before starting another lab.",
            )

    with _lock:
        current = _transitions.get(lab_id)
        # Refuse start while install is still running — otherwise a click
        # on [LAUNCH] mid-install overrides the installing transition with
        # "starting", and the lab gets reported ONLINE while phase-3 model
        # pulls are still in flight. Containers were brought up by install.sh
        # phase 2 so they're technically running, but the model dropdown is
        # incomplete and the user can hit a 400 on any in-flight model.
        if current in ("starting", "stopping", "installing"):
            raise HTTPException(status_code=409, detail=f"Lab is already {current}")
        _transitions[lab_id] = "starting"

    threading.Thread(target=_run_start, args=(lab_id,), daemon=True).start()
    return {"status": "starting"}


@app.post("/api/labs/{lab_id}/stop")
async def stop_lab(lab_id: str):
    if lab_id not in LAB_BY_ID:
        raise HTTPException(status_code=404, detail="Lab not found")

    with _lock:
        current = _transitions.get(lab_id)
        if current == "stopping":
            raise HTTPException(status_code=409, detail="Lab is already stopping")
        _transitions[lab_id] = "stopping"

    threading.Thread(target=_run_stop, args=(lab_id,), daemon=True).start()
    return {"status": "stopping"}



@app.get("/api/labs/{lab_id}/ready")
async def lab_ready(lab_id: str):
    """Probe the lab's HTTP endpoint server-side. Returns {ready: bool}."""
    if lab_id not in LAB_BY_ID:
        raise HTTPException(status_code=404, detail="Lab not found")
    port = LAB_BY_ID[lab_id]["port"]
    try:
        async with httpx.AsyncClient(timeout=3.0, follow_redirects=True) as client:
            r = await client.get(f"http://localhost:{port}/")
            return {"ready": r.status_code < 500}
    except Exception:
        return {"ready": False}


@app.post("/api/labs/{lab_id}/clear-error")
async def clear_error(lab_id: str):
    if lab_id not in LAB_BY_ID:
        raise HTTPException(status_code=404, detail="Lab not found")
    with _lock:
        if _transitions.get(lab_id) == "error":
            _transitions.pop(lab_id, None)
        _lab_errors.pop(lab_id, None)
    return {"status": "cleared"}


def _write_installed(ids: list[str]) -> None:
    """Atomic write of the installed-labs registry. Removes the file if empty."""
    _INSTALL_STATE.parent.mkdir(parents=True, exist_ok=True)
    if not ids:
        if _INSTALL_STATE.exists():
            _INSTALL_STATE.unlink()
        return
    tmp = _INSTALL_STATE.with_suffix(".tmp")
    with tmp.open("w") as f:
        json.dump(sorted(ids), f, indent=2)
        f.write("\n")
    tmp.replace(_INSTALL_STATE)


@app.post("/api/labs/{lab_id}/install")
async def install_lab(lab_id: str):
    if lab_id not in LAB_BY_ID:
        raise HTTPException(status_code=404, detail="Lab not found")

    # Refuse concurrent installs (one heavy job at a time)
    for lab in ALL_LABS:
        with _lock:
            t = _transitions.get(lab["id"])
        if t == "installing" and lab["id"] != lab_id:
            raise HTTPException(
                status_code=409,
                detail=f"{lab['name']} is currently installing. Wait for it to finish.",
            )

    # Add to registry immediately so the tile transitions visually
    ids = installed_lab_ids()
    if lab_id not in ids:
        ids.append(lab_id)
        _write_installed(ids)

    # If already installed AND no heavy work likely needed, just return —
    # frontend will reload and show LAUNCH. Otherwise spawn the install thread.
    with _lock:
        current = _transitions.get(lab_id)
        if current in ("installing", "starting", "stopping"):
            raise HTTPException(status_code=409, detail=f"Lab is currently {current}")
        _transitions[lab_id] = "installing"

    threading.Thread(target=_run_install, args=(lab_id,), daemon=True).start()
    return {"status": "installing", "lab_id": lab_id}


@app.post("/api/labs/{lab_id}/uninstall")
async def uninstall_lab_api(lab_id: str):
    if lab_id not in LAB_BY_ID:
        raise HTTPException(status_code=404, detail="Lab not found")
    # Refuse to uninstall a running lab — that would orphan its containers
    with _cache_lock:
        if _docker_cache.get(lab_id, False):
            raise HTTPException(
                status_code=409,
                detail="Lab is currently running. Stop it before uninstalling.",
            )
    ids = installed_lab_ids()
    if lab_id in ids:
        ids = [x for x in ids if x != lab_id]
        _write_installed(ids)
    return {"status": "uninstalled", "lab_id": lab_id}
