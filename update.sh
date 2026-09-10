#!/usr/bin/env bash
# update.sh
# Updates MemPalace MCP Bridge to the latest version.
# Safe to run at any time — does NOT delete or overwrite user data.
#
# What it does:
#   1. Pulls the latest commits from this repo
#   2. Upgrades MemPalace inside the existing .venv
#   3. Re-checks that .mcp.json still has correct paths
#      (regenerates it if the repo was moved or paths changed)
#   4. Runs verify.sh to confirm everything is healthy
#
# What it does NOT do:
#   - Never touches ~/.mempalace/palace (your notes and memories)
#   - Never deletes .venv and reinstalls from scratch
#   - Never overwrites .mcp.json unless the paths inside are wrong

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANONICAL_LINK="${HOME}/.local/share/mempalace-mcp-bridge"

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
warn()  { echo "[WARN]  $*"; }
fail()  { echo "[ERROR] $*" >&2; exit 1; }

echo "════════════════════════════════════════"
echo " MemPalace MCP Bridge — Update"
echo "════════════════════════════════════════"
echo ""

# ─── Canonical bridge link ──────────────────────────────────────────────────

info "Ensuring canonical bridge link..."
bash "$REPO_ROOT/scripts/link_bridge.sh"

# ─── 1. Pull latest changes from this repo ────────────────────────────────────

info "Step 1/4 — Pulling latest changes from git..."

if [ ! -d "$REPO_ROOT/.git" ]; then
    fail "Not a git repository. Clone the repo properly before running update.sh."
fi

# Check for uncommitted local changes to tracked files (staged or unstaged)
if ! git -C "$REPO_ROOT" diff-index --quiet HEAD 2>/dev/null; then
    warn "You have uncommitted local changes. They will NOT be overwritten."
    warn "Proceeding with git pull (merge/rebase may conflict on modified files)."
fi

if git -C "$REPO_ROOT" pull --ff-only 2>/dev/null; then
    ok "Repository updated"
elif git -C "$REPO_ROOT" pull 2>/dev/null; then
    ok "Repository updated (non-fast-forward merge)"
else
    warn "git pull failed or is not applicable (detached HEAD / no remote?)."
    warn "Skipping git pull — continuing with local files."
fi

# ─── 2. Upgrade MemPalace inside the existing .venv ──────────────────────────

info "Step 2/4 — Upgrading MemPalace..."

VENV_PYTHON="$REPO_ROOT/.venv/bin/python"

if [ ! -f "$VENV_PYTHON" ]; then
    fail ".venv not found at $REPO_ROOT/.venv — run: bash setup.sh first."
fi

if ! command -v uv &>/dev/null; then
    # Try common install locations
    for candidate in "$HOME/.cargo/bin/uv" "$HOME/.local/bin/uv"; do
        if [ -x "$candidate" ]; then
            export PATH="$(dirname "$candidate"):$PATH"
            break
        fi
    done
fi

if ! command -v uv &>/dev/null; then
    fail "uv not found. Run: bash setup.sh to restore the environment."
fi

uv pip install --upgrade --python "$VENV_PYTHON" "mempalace>=3.0.0" "chromadb>=0.6,<0.7"
bash "$REPO_ROOT/scripts/check_chromadb_version.sh"
ok "MemPalace upgraded"

# ─── 2b. Palace health check after upgrade ───────────────────────────────────
# ChromaDB upgrades can introduce config_json_str format changes that break
# palace access. Detect and auto-repair before the verify step.

info "Checking palace health after upgrade..."
HEALTH_EXIT=0
bash "$REPO_ROOT/scripts/check_palace_health.sh" || HEALTH_EXIT=$?
if [ "$HEALTH_EXIT" -eq 1 ]; then
    echo "[ERROR] Palace health check failed. See docs/troubleshooting.md#chromadb-version-incompatibility" >&2
    exit 1
fi

# ─── 3. Revalidate .mcp.json ────────────────────────────────────────────────
#
# The config embeds absolute paths (uv binary + canonical bridge link).
# If the canonical link or uv path changed, those paths are stale.
# Detect that and regenerate rather than silently leaving a broken config.

info "Step 3/4 — Checking .mcp.json..."

MCP_CONFIG="$REPO_ROOT/.mcp.json"
LEGACY_MCP_CONFIG="$REPO_ROOT/.vscode/mcp.json"
NEEDS_REGEN=false

if [ ! -f "$MCP_CONFIG" ] && [ -f "$LEGACY_MCP_CONFIG" ]; then
    info "Legacy MCP config found at .vscode/mcp.json — migrating to .mcp.json."
    if "$VENV_PYTHON" - <<PYEOF >/dev/null 2>&1
import json
from pathlib import Path

legacy_path = Path(r"$LEGACY_MCP_CONFIG")
target_path = Path(r"$MCP_CONFIG")

with legacy_path.open("r", encoding="utf-8") as handle:
    cfg = json.load(handle)

servers = cfg.pop("servers", None)
if not isinstance(servers, dict):
    raise SystemExit(1)

cfg["mcpServers"] = servers

with target_path.open("w", encoding="utf-8") as handle:
    json.dump(cfg, handle, indent=2)
    handle.write("\n")
PYEOF
    then
        ok "Legacy MCP config migrated to $MCP_CONFIG"
    else
        warn "Legacy MCP config could not be migrated cleanly — will regenerate .mcp.json."
        NEEDS_REGEN=true
    fi
fi

if [ ! -f "$MCP_CONFIG" ]; then
    info "MCP config not found — will generate."
    NEEDS_REGEN=true
elif grep -q "ABSOLUTE/PATH" "$MCP_CONFIG" 2>/dev/null; then
    warn "MCP config still has placeholder paths — will regenerate."
    NEEDS_REGEN=true
else
    # Extract the --directory value from the existing config and compare to $REPO_ROOT
    STORED_DIR=$("$VENV_PYTHON" -c "
import json, sys
try:
    with open('$MCP_CONFIG') as f:
        cfg = json.load(f)
    args = cfg['mcpServers']['mempalace'].get('args', [])
    idx = args.index('--directory') if '--directory' in args else -1
    print(args[idx + 1] if idx >= 0 else '')
except Exception:
    print('')
" 2>/dev/null || true)

    if [ "$STORED_DIR" != "$CANONICAL_LINK" ]; then
        warn "MCP config points to '$STORED_DIR' but the canonical bridge path is '$CANONICAL_LINK'."
        warn "Regenerating .mcp.json with correct paths."
        NEEDS_REGEN=true
    else
        # Also verify the uv command path stored in the config actually exists
        STORED_UV=$("$VENV_PYTHON" -c "
import json
try:
    with open('$MCP_CONFIG') as f:
        cfg = json.load(f)
    print(cfg['mcpServers']['mempalace'].get('command', ''))
except Exception:
    print('')
" 2>/dev/null || true)
        STORED_ARGS=$("$VENV_PYTHON" -c "
import json
try:
    with open('$MCP_CONFIG') as f:
        cfg = json.load(f)
    print(json.dumps(cfg['mcpServers']['mempalace'].get('args', [])))
except Exception:
    print('')
" 2>/dev/null || true)
        EXPECTED_ARGS_JSON='["run", "--directory", "'"$CANONICAL_LINK"'", "python", "scripts/run_mcp_server.py"]'

        if [ -n "$STORED_UV" ] && [ ! -x "$STORED_UV" ]; then
            warn "uv path in MCP config ('$STORED_UV') no longer exists — will regenerate."
            NEEDS_REGEN=true
        elif [ "$STORED_ARGS" != "$EXPECTED_ARGS_JSON" ]; then
            warn "MCP config uses an outdated startup command — will regenerate."
            NEEDS_REGEN=true
        fi
    fi
fi

if [ "$NEEDS_REGEN" = true ]; then
    UV_PATH="$(command -v uv 2>/dev/null || true)"
    [ -n "$UV_PATH" ] || fail "uv not found — cannot regenerate MCP config."

    cat > "$MCP_CONFIG" <<EOF
{
  "mcpServers": {
    "mempalace": {
      "type": "stdio",
      "command": "$UV_PATH",
      "args": ["run", "--directory", "$CANONICAL_LINK", "python", "scripts/run_mcp_server.py"]
    }
  }
}
EOF
    ok "MCP config regenerated at $MCP_CONFIG"
else
    ok "MCP config is up to date — not modified"
fi

# ─── 4. Verify the full stack ─────────────────────────────────────────────────

info "Step 4/4 — Verifying the full stack..."
echo ""
bash "$REPO_ROOT/verify.sh"

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════"
echo " Update complete!"
echo "════════════════════════════════════════"
echo ""
echo "Your notes and memories in ~/.mempalace/palace are untouched."
echo ""
echo "Reload VS Code window (Ctrl+Shift+P → 'Developer: Reload Window')"
echo "for the updated MCP server to take effect."
echo ""
