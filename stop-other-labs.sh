#!/usr/bin/env bash
# stop-other-labs.sh — shared helper sourced by every lab's start.sh
#
# Usage (in start.sh, after computing _THIS_PROJECT):
#   source "$(cd "$(dirname "$0")/../../" && pwd)/stop-other-labs.sh"
#   stop_other_labs "$_THIS_PROJECT"
#
# Effect: finds any other running lab compose project and brings it down so
# only one lab runs at a time, matching the dashboard's single-lab constraint.

stop_other_labs() {
  local this="${1:-}"
  [[ -z "$this" ]] && return 0

  local others=""
  if command -v python3 >/dev/null 2>&1; then
    others=$(
      docker compose ls --all --format json 2>/dev/null \
      | python3 -c "
import json, re, sys
this = sys.argv[1]
try: data = json.load(sys.stdin)
except: sys.exit(0)
for p in data:
    name = p.get('Name', '').lower()
    if name == this or name == 'shared-ollama': continue
    if not re.match(r'^[0-9]+_lab', name): continue
    if 'running' not in p.get('Status', '').lower(): continue
    f = p.get('ConfigFiles', '').split(',')[0].strip()
    if f: print(f)
" "$this" 2>/dev/null || true
    )
  fi

  [[ -z "$others" ]] && return 0

  while IFS= read -r compose_file; do
    [[ -z "$compose_file" ]] && continue
    local lab_name
    lab_name="$(basename "$(dirname "$compose_file")")"
    echo "Stopping conflicting lab: $lab_name …"
    docker compose -f "$compose_file" down --remove-orphans 2>/dev/null || true
  done <<< "$others"
}
