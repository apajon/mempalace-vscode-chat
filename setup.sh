#!/usr/bin/env bash
# setup.sh
# One-command setup: installs MemPalace, initializes the palace,
# mines sample data, and writes .mcp.json with the correct uv path.
# Safe to re-run (idempotent).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL_LINK="${HOME}/.local/share/mempalace-mcp-bridge"

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
fail()  { echo "[ERROR] $*" >&2; exit 1; }

echo "════════════════════════════════════════"
echo " MemPalace MCP Bridge — Setup"
echo "════════════════════════════════════════"
echo ""

# ─── Canonical bridge link ──────────────────────────────────────────────────
# Expose this clone under the stable, location-independent path
# $HOME/.local/share/mempalace-mcp-bridge so consumers never need to know
# where the repo actually lives.

info "Creating canonical bridge link..."
bash "$REPO_ROOT/scripts/link_bridge.sh"

# ─── 1. Bootstrap (uv + MemPalace) ───────────────────────────────────────────

info "Step 1/4 — Installing dependencies..."
bash "$REPO_ROOT/scripts/bootstrap.sh"

# ─── 2. Initialize palace ─────────────────────────────────────────────────────

info "Step 2/4 — Initializing MemPalace..."
bash "$REPO_ROOT/scripts/init_palace.sh"

# ─── 2b. Palace health check ──────────────────────────────────────────────────
# Detects and auto-repairs ChromaDB config_json_str incompatibilities that can
# occur after a ChromaDB upgrade. Safe to run on a brand-new palace (no-op).

HEALTH_EXIT=0
bash "$REPO_ROOT/scripts/check_palace_health.sh" || HEALTH_EXIT=$?
# exit 2 means no palace yet (normal here) — not an error
if [ "$HEALTH_EXIT" -eq 1 ]; then
    echo "[ERROR] Palace health check failed — aborting setup." >&2
    exit 1
fi

# ─── 3. Mine sample notes ─────────────────────────────────────────────────────

info "Step 3/4 — Mining sample notes..."
bash "$REPO_ROOT/scripts/mine_sample_data.sh"

# ─── 4. Generate .mcp.json ───────────────────────────────────────────────────

info "Step 4/4 — Generating workspace MCP config..."

UV_PATH="$(command -v uv 2>/dev/null || true)"
if [ -z "$UV_PATH" ]; then
    # Try common install locations after bootstrap
    for candidate in "$HOME/.cargo/bin/uv" "$HOME/.local/bin/uv"; do
        if [ -x "$candidate" ]; then
            UV_PATH="$candidate"
            break
        fi
    done
fi
[ -n "$UV_PATH" ] || fail "uv not found after bootstrap — cannot write MCP config."

MCP_CONFIG="$REPO_ROOT/.mcp.json"

# Only regenerate if the config is missing, has placeholder paths, or the
# stored paths no longer match this machine (e.g. repo moved, uv reinstalled).
_needs_regen=true
if [ -f "$MCP_CONFIG" ] && ! grep -q "ABSOLUTE/PATH" "$MCP_CONFIG" 2>/dev/null; then
    VENV_PYTHON="$REPO_ROOT/.venv/bin/python"
    EXPECTED_ARGS_JSON='["run", "--directory", "'"$CANONICAL_LINK"'", "python", "scripts/run_mcp_server.py"]'
    _stored_dir=$("$VENV_PYTHON" -c "
import json
try:
    with open('$MCP_CONFIG') as f:
        cfg = json.load(f)
    args = cfg['servers']['mempalace'].get('args', [])
    idx = args.index('--directory') if '--directory' in args else -1
    print(args[idx + 1] if idx >= 0 else '')
except Exception:
    print('')
" 2>/dev/null || true)
    _stored_uv=$("$VENV_PYTHON" -c "
import json
try:
    with open('$MCP_CONFIG') as f:
        cfg = json.load(f)
    print(cfg['servers']['mempalace'].get('command', ''))
except Exception:
    print('')
" 2>/dev/null || true)
    _stored_args=$("$VENV_PYTHON" -c "
import json
try:
    with open('$MCP_CONFIG') as f:
        cfg = json.load(f)
    print(json.dumps(cfg['servers']['mempalace'].get('args', [])))
except Exception:
    print('')
" 2>/dev/null || true)

    if [ "$_stored_dir" = "$CANONICAL_LINK" ] && [ "$_stored_uv" = "$UV_PATH" ] && [ "$_stored_args" = "$EXPECTED_ARGS_JSON" ]; then
        _needs_regen=false
    fi
fi

if [ "$_needs_regen" = true ]; then
    cat > "$MCP_CONFIG" <<EOF
{
  "servers": {
    "mempalace": {
      "type": "stdio",
      "command": "$UV_PATH",
      "args": ["run", "--directory", "$CANONICAL_LINK", "python", "scripts/run_mcp_server.py"]
    }
  }
}
EOF
    # --directory points at the canonical symlink, so uv resolves the same
    # project root (and .venv) regardless of where VS Code launches the server.
    ok "MCP config written to $MCP_CONFIG"
else
    ok "MCP config already up to date — not modified ($MCP_CONFIG)"
fi

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════"
echo " Setup complete!"
echo "════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  1. Open this folder in VS Code"
echo "  2. Open Copilot Chat (Ctrl+Alt+I)"
echo "  3. Ask: \"What architecture decisions have I documented?\""
echo ""
echo "To verify everything works:"
echo "  bash verify.sh"
echo ""
echo "To run the MCP server manually (fallback):"
echo "  bash run.sh"
