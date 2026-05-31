#!/usr/bin/env bash
# Run once before opening rag_test.ipynb in VS Code.
# Installs notebook dependencies into the repo-root venv that VS Code auto-selects.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
VENV="$REPO_ROOT/.venv"

if [ ! -d "$VENV" ]; then
  echo "No .venv found at $REPO_ROOT — creating one..."
  python3 -m venv "$VENV"
fi

"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet ipykernel requests

echo ""
echo "Done. Next steps in VS Code:"
echo "  1. Open rag_test.ipynb"
echo "  2. Click the kernel picker in the top-right of the notebook"
echo "  3. Choose: Python Environments → .venv (Python 3.x)"
