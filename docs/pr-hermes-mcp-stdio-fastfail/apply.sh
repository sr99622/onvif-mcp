#!/usr/bin/env bash
# Re-apply the stdio-MCP fast-fail fix to a Hermes git checkout.
# Idempotent: safe to run after any fresh install or `hermes update`.
#
# Usage:
#   ./apply.sh                          # target ~/.hermes/hermes-agent
#   HERMES_SRC=/path/to/checkout ./apply.sh   # override the source dir
set -euo pipefail

PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH="$PATCH_DIR/fix_stdio_children_dead.patch"
SRC="${HERMES_SRC:-$HOME/.hermes/hermes-agent}"

if [ ! -f "$SRC/tools/mcp_tool.py" ]; then
  echo "ERROR: $SRC/tools/mcp_tool.py not found — is Hermes installed here?" >&2
  exit 1
fi

# Already patched? Detect via the fix's marker comment.
if grep -q "every tracked child has exited" "$SRC/tools/mcp_tool.py"; then
  echo "Already applied — nothing to do."
  exit 0
fi

echo "Applying: $PATCH"
echo "Targeting: $SRC"

applied=""
if [ -d "$SRC/.git" ]; then
  if git -C "$SRC" apply --check "$PATCH" >/dev/null 2>&1; then
    git -C "$SRC" apply "$PATCH" && applied="clean"
  elif git -C "$SRC" apply -3 --whitespace=nowarn "$PATCH" 2>/dev/null; then
    applied="3-way (upstream context drifted)"
  fi
else
  if ( cd "$SRC" && patch -p1 < "$PATCH" ); then
    applied="patch(1)"
  fi
fi

if [ -z "$applied" ]; then
  echo "" >&2
  echo "ERROR: patch did not apply cleanly — upstream probably rewrote these lines." >&2
  echo "Open $SRC/tools/mcp_tool.py, find _stdio_children_dead(), and apply the" >&2
  echo "change by hand (see fix_stdio_children_dead.patch for the exact hunk)." >&2
  exit 1
fi

echo "Applied ($applied). Verifying the fix is present:"
grep -n "every tracked child has exited\|don't fast-fail" "$SRC/tools/mcp_tool.py" || true
