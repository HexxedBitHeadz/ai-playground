# HeBi AI Playground

A hands-on collection of offensive and defensive AI security labs by Hexxed BitHeadz. Each lab is a self-contained scenario that runs locally against open-weight LLMs. **No external API calls. No paid services.** Tested on Windows host with Ubuntu WSL.

A web dashboard lets you start and stop labs and links you to each lab's WebUI.

---

## Quick start

```bash
sudo apt update
git clone https://github.com/HexxedBitHeadz/ai-playground && cd ai-playground
./setup.sh                          # creates .env files from templates
./install-lab.sh 01                 # registers LAB 01 with the dashboard
cd service-dashboard
./run.sh                            # starts the dashboard at http://localhost:9000
```

Open **http://localhost:9000** — you'll see LAB 01 as a tile. Click `[ INSTALL ]` to pull its models and build its images, then `[ LAUNCH ]` to start it.

**First-time note:** A full LAB 01 install pulls roughly **~38 GB of model weights** (Llama, Mistral, Qwen, Gemma, Phi, qwen-coder). Plan for a 30–60 minute first launch. See `--lite` mode below if you want a faster spin.

### Lite mode (try it in 5 minutes)

If you want a quick spin without committing to ~38 GB:

```bash
cd service-dashboard
./run.sh --lite       # pulls only tinyllama:1.1b + llama3.2:1b (~2 GB total)
```

Smaller models mean some attack techniques work less reliably, but the dashboard, the workflow, and most prompt-injection demos all function. Drop the flag later to pull the full set.

### Windows + WSL2 quick reference

If you're driving the lab box from Windows over WSL2:

```bash
wsl --set-default Ubuntu-24.04           # pick the right WSL distro (PowerShell)
wsl -d Ubuntu-24.04                      # drop into it
cd ~/hebi-ai-playground/service-dashboard
./run.sh
```

Or hop onto the lab box from another machine on the LAN:

```bash
ssh <user>@<lab-host>
cd ~/hebi-ai-playground/service-dashboard && ./run.sh
```

---

## Requirements

| | Required | Recommended |
|---|---|---|
| **OS** | Linux or WSL2 | Ubuntu 22.04+ / WSL2 |
| **Docker** | Yes — `run.sh` offers to install Docker Engine for you if missing | Docker Engine inside WSL (no Docker Desktop required) |
| **Python** | 3.9+ | 3.10+ |
| **GPU** | None (CPU mode works) | NVIDIA with 16 GB+ VRAM |
| **Disk** | 5 GB free for lite mode, 40 GB for the full pull | 80 GB if you plan to add more labs later |
| **RAM** | 16 GB | 32 GB |

> **macOS / Windows native:** not currently supported. The lab scripts use Linux conventions (bash, systemd ollama). On Windows, use WSL2. macOS support is a known gap.

---

## How the repo is organized

```
hebi-ai-playground/
├── service-dashboard/    # Web UI for starting/stopping labs (http://localhost:9000)
├── 1._LAB01/             # Prompt Injection — builds hebi-codegen, pulls base models
├── shared/               # Branding + templates shared across labs
├── setup.sh              # First-time setup — creates .env files
├── install-lab.sh        # Register a lab with the dashboard
├── uninstall-lab.sh      # Remove a lab from the dashboard
├── new-lab.sh            # Scaffold a new lab folder for contributions or extensions
├── stop-all.sh           # Stop every running lab
└── stop-other-labs.sh    # Helper used by each lab's start.sh
```

Each lab folder is self-contained: it owns its `docker-compose.yml`, scripts, modelfiles, and README.

---

## CPU-only mode (no GPU)

CPU is the default — the dashboard's scripts detect the absence of an NVIDIA adapter and skip GPU reservation automatically. You don't need to do anything special. If you do have a GPU and want to enable hardware acceleration explicitly when running a lab by hand:

```bash
cd 1._LAB01
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
```

CPU inference works but is **much** slower — expect 30–120 seconds per response for 7B+ models. For trying things out, use `tinyllama:1.1b` or `llama3.2:1b` (the lite-mode default).

> **Tip:** combine with `./run.sh --lite` so only the small models get pulled in the first place. The dashboard's preflight will also tell you if it doesn't detect an NVIDIA GPU.

---

## Companion tools

**[PromptSlinger](https://github.com/HexxedBitHeadz/PromptSlinger)** — a Burp Suite extension for AI/LLM endpoint testing, built on the Montoya API. Designed for the same kind of internal-lab and CTF scenarios this playground simulates. Features:

- Send & inject with auto-detection of message fields
- Encoding modifiers (Base64, ROT13, leetspeak, etc.) for filter evasion
- Multi-turn conversation tracking
- Categorized payload library (recon, jailbreak, prompt extraction)
- Crescendo (multi-step) attack sequences
- History viewer with a built-in credential scanner

You don't need PromptSlinger to use the labs — every lab has a WebUI you can attack directly. But once you're past the basics, intercepting the WebUI ↔ Ollama traffic with Burp + PromptSlinger gives you a much sharper toolkit.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `docker: command not found` | `run.sh` will offer to install Docker Engine for you. Or install manually: `sudo apt install -y docker.io docker-compose-v2 && sudo usermod -aG docker $USER && sudo systemctl enable --now docker` then exit + reopen the shell. |
| `python3: command not found` | `sudo apt install python3 python3-venv` (Ubuntu/WSL) |
| LAB01 stuck "INSTALLING" for >30 min | First pull is large; check `1._LAB01/logs/install.log` or restart with `./run.sh --lite` for a ~2 GB subset |
| Lab fails with "no NVIDIA device" | Shouldn't happen — CPU is the default. If it does, ensure you're not manually adding `-f docker-compose.gpu.yml` |
| Port already in use | `fuser -k 9000/tcp` (or replace 9000 with the offending port) |
| Models took up too much disk | `docker exec ollama ollama rm <model>` or wipe `1._LAB01/data/ollama/` |

---

## Stopping everything

```bash
./stop-all.sh        # stop every running lab
```

Or stop just the dashboard process if no labs are running: `Ctrl-C` in the `run.sh` terminal.

---

## Licence and use

These labs simulate attacks against AI systems in a controlled, local environment. They are intended for security education, defensive research, and CTF-style training. Do not point the attack scripts or modelfiles at systems you don't own.
