#!/usr/bin/env bash
# verify.sh
# Verifies the MemPalace MCP bridge end-to-end and classifies the result as:
#   - supported and healthy
#   - supported but suspicious
#   - unsupported / unsafe

# Note: -e is intentionally omitted. This script must continue running even when
# individual checks fail so that all diagnostics are shown in one pass.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PYTHON="$REPO_ROOT/.venv/bin/python"
MCP_CONFIG="$REPO_ROOT/.mcp.json"
LEGACY_MCP_CONFIG="$REPO_ROOT/.vscode/mcp.json"
CANONICAL_LINK="${HOME}/.local/share/mempalace-mcp-bridge"
PYTHON_PIN_FILE="$REPO_ROOT/.python-version"
SUPPORTED_CHROMA_LINE="0.6.x"

PASS=0
WARN=0
FAIL=0

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }
detail() { echo "       $*"; }

resolve_uv_path() {
    if command -v uv &>/dev/null; then
        command -v uv
        return 0
    fi

    for candidate in "$HOME/.cargo/bin/uv" "$HOME/.local/bin/uv"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

EXPECTED_PYTHON_LINE=""
if [ -f "$PYTHON_PIN_FILE" ]; then
    EXPECTED_PYTHON_LINE="$(tr -d '[:space:]' < "$PYTHON_PIN_FILE")"
fi

EXPECTED_UV=""
if EXPECTED_UV="$(resolve_uv_path)"; then
    :
fi

echo "════════════════════════════════════════"
echo " MemPalace MCP Bridge — Verify"
echo "════════════════════════════════════════"
echo ""

# ─── 1. uv available ────────────────────────────────────────────────────────────

if [ -n "$EXPECTED_UV" ]; then
    pass "uv found: $EXPECTED_UV ($("$EXPECTED_UV" --version 2>/dev/null))"
else
    fail "uv not found in PATH"
    detail "Run: bash setup.sh"
fi

# ─── 2. Virtual environment present ─────────────────────────────────────────────

if [ -f "$VENV_PYTHON" ]; then
    pass "Virtual environment found at .venv/"
else
    fail "Virtual environment missing at .venv/"
    detail "Run: bash setup.sh"
fi

# ─── 3. Python version supported ────────────────────────────────────────────────

ACTIVE_PYTHON_VERSION=""
ACTIVE_PYTHON_MM=""
if [ -f "$VENV_PYTHON" ]; then
    PYTHON_INFO="$("$VENV_PYTHON" - <<'PYEOF' 2>/dev/null || true
import platform
import sys

print(platform.python_version())
print(f"{sys.version_info.major}.{sys.version_info.minor}")
PYEOF
)"
    readarray -t PYTHON_LINES <<< "$PYTHON_INFO"
    ACTIVE_PYTHON_VERSION="${PYTHON_LINES[0]:-}"
    ACTIVE_PYTHON_MM="${PYTHON_LINES[1]:-}"

    if [ -n "$ACTIVE_PYTHON_VERSION" ] && [ -n "$ACTIVE_PYTHON_MM" ]; then
        if [ -n "$EXPECTED_PYTHON_LINE" ]; then
            if [ "$ACTIVE_PYTHON_MM" = "$EXPECTED_PYTHON_LINE" ]; then
                pass "Python $ACTIVE_PYTHON_VERSION in .venv is on the tested $EXPECTED_PYTHON_LINE line"
            elif [ "${ACTIVE_PYTHON_MM%.*}" = "${EXPECTED_PYTHON_LINE%.*}" ] && [ "${ACTIVE_PYTHON_MM#*.}" -gt "${EXPECTED_PYTHON_LINE#*.}" ]; then
                warn "Python $ACTIVE_PYTHON_VERSION is newer than the pinned $EXPECTED_PYTHON_LINE line"
                detail "This may work, but this bridge is currently tested on Python $EXPECTED_PYTHON_LINE."
            else
                fail "Python $ACTIVE_PYTHON_VERSION is below the required $EXPECTED_PYTHON_LINE line"
                detail "Run: bash setup.sh"
            fi
        else
            pass "Python $ACTIVE_PYTHON_VERSION detected in .venv"
        fi
    else
        fail "Could not determine the Python version inside .venv"
        detail "Run: bash setup.sh"
    fi
fi

# ─── 4. MemPalace package supported ─────────────────────────────────────────────

MEMPALACE_VERSION=""
if [ -f "$VENV_PYTHON" ]; then
    MEMPALACE_RESULT="$("$VENV_PYTHON" - <<'PYEOF' 2>/dev/null || true
import importlib.metadata
import sys

try:
    import mempalace  # noqa: F401
except Exception as exc:
    print(f"IMPORT_ERROR\t{exc}")
    raise SystemExit(0)

try:
    version = importlib.metadata.version("mempalace")
except Exception as exc:
    print(f"VERSION_ERROR\t{exc}")
    raise SystemExit(0)

parts = []
for piece in version.split("."):
    if piece.isdigit():
        parts.append(int(piece))
    else:
        break
while len(parts) < 3:
    parts.append(0)

if tuple(parts[:3]) < (3, 0, 0):
    print(f"UNSUPPORTED\t{version}")
else:
    print(f"OK\t{version}")
PYEOF
)"
    IFS=$'\t' read -r MEMPALACE_STATE MEMPALACE_VALUE <<< "$MEMPALACE_RESULT"

    case "$MEMPALACE_STATE" in
        OK)
            MEMPALACE_VERSION="$MEMPALACE_VALUE"
            pass "mempalace $MEMPALACE_VERSION is importable"
            ;;
        UNSUPPORTED)
            MEMPALACE_VERSION="$MEMPALACE_VALUE"
            fail "mempalace $MEMPALACE_VERSION is too old for this bridge"
            detail "Run: bash update.sh"
            ;;
        IMPORT_ERROR)
            fail "mempalace is not importable from .venv"
            detail "Reason: $MEMPALACE_VALUE"
            detail "Run: bash setup.sh"
            ;;
        VERSION_ERROR)
            fail "mempalace is importable but its version could not be read"
            detail "Reason: $MEMPALACE_VALUE"
            detail "Run: bash setup.sh"
            ;;
        *)
            fail "Could not determine the installed MemPalace version"
            detail "Run: bash setup.sh"
            ;;
    esac
fi

# ─── 5. ChromaDB version supported ──────────────────────────────────────────────

CHROMADB_VERSION=""
if [ -f "$VENV_PYTHON" ]; then
    CHROMA_RESULT="$("$VENV_PYTHON" - <<'PYEOF' 2>/dev/null || true
import importlib.metadata
import re

try:
    version = importlib.metadata.version("chromadb")
except importlib.metadata.PackageNotFoundError:
    print("MISSING\tchromadb is not installed in .venv")
    raise SystemExit(0)
except Exception as exc:
    print(f"ERROR\t{exc}")
    raise SystemExit(0)

if re.fullmatch(r"0\.6(?:\.\d+)?", version):
    print(f"OK\t{version}")
else:
    print(f"UNSUPPORTED\t{version}")
PYEOF
)"
    IFS=$'\t' read -r CHROMA_STATE CHROMA_VALUE <<< "$CHROMA_RESULT"

    case "$CHROMA_STATE" in
        OK)
            CHROMADB_VERSION="$CHROMA_VALUE"
            pass "chromadb $CHROMADB_VERSION is on the supported $SUPPORTED_CHROMA_LINE line"
            ;;
        UNSUPPORTED)
            CHROMADB_VERSION="$CHROMA_VALUE"
            fail "chromadb $CHROMADB_VERSION is outside the supported $SUPPORTED_CHROMA_LINE line"
            detail "Run: bash update.sh"
            ;;
        MISSING)
            fail "$CHROMA_VALUE"
            detail "Run: bash setup.sh"
            ;;
        ERROR)
            fail "Could not read the installed chromadb version"
            detail "Reason: $CHROMA_VALUE"
            detail "Run: bash setup.sh"
            ;;
        *)
            fail "Could not determine the installed chromadb version"
            detail "Run: bash setup.sh"
            ;;
    esac
fi

# ─── 6. mempalace CLI responds ──────────────────────────────────────────────────

if [ -f "$VENV_PYTHON" ]; then
    if [ -n "$EXPECTED_UV" ] && "$EXPECTED_UV" run --python "$VENV_PYTHON" mempalace --help &>/dev/null; then
        pass "mempalace CLI responds"
    elif [ -x "$REPO_ROOT/.venv/bin/mempalace" ] && "$REPO_ROOT/.venv/bin/mempalace" --help &>/dev/null; then
        pass "mempalace CLI responds"
    else
        fail "mempalace CLI did not respond"
        detail "Run: bash setup.sh"
    fi
fi

# ─── 7. Sample notes present ────────────────────────────────────────────────────

NOTES_DIR="$REPO_ROOT/examples/sample_notes"
if [ -d "$NOTES_DIR" ] && ls "$NOTES_DIR"/*.md &>/dev/null; then
    NOTE_COUNT=$(ls "$NOTES_DIR"/*.md | wc -l)
    pass "Sample notes found in examples/sample_notes/ ($NOTE_COUNT files)"
else
    fail "Sample notes missing in $NOTES_DIR"
fi

# ─── 8. Workspace MCP config integrity ─────────────────────────────────────────

MCP_CONFIG_OK=false
MCP_COMMAND=""
MCP_ARGS_JSON=""
MCP_PARSE_ERROR=""
MCP_TYPE=""

if [ ! -f "$MCP_CONFIG" ]; then
    fail "Workspace MCP config missing at $MCP_CONFIG"
    detail "Run: bash setup.sh"
    if [ -f "$LEGACY_MCP_CONFIG" ]; then
        detail "Or migrate the legacy config: jq '{servers: .servers}' .vscode/mcp.json > .mcp.json"
    fi
elif grep -q "ABSOLUTE/PATH" "$MCP_CONFIG" 2>/dev/null; then
    fail "Workspace MCP config still contains placeholder paths"
    detail "Run: bash setup.sh"
elif [ ! -f "$VENV_PYTHON" ]; then
    fail "Workspace MCP config could not be validated because .venv is missing"
else
    MCP_INFO="$("$VENV_PYTHON" - <<PYEOF 2>/dev/null || true
import json
from pathlib import Path

config_path = Path(r"$MCP_CONFIG")
expected_args = ["run", "--directory", r"$CANONICAL_LINK", "python", "scripts/run_mcp_server.py"]

try:
    with config_path.open("r", encoding="utf-8") as handle:
        cfg = json.load(handle)
except Exception as exc:
    print(f"parse_error\t{exc}")
    raise SystemExit(0)

mcp_servers = cfg.get("servers")
if not isinstance(mcp_servers, dict):
    print("parse_error\tmissing 'servers' object")
    raise SystemExit(0)

server = mcp_servers.get("mempalace")
if not isinstance(server, dict):
    print("parse_error\tmissing 'servers.mempalace' object")
    raise SystemExit(0)

print(f"type\t{server.get('type', '')}")
print(f"command\t{server.get('command', '')}")
print(f"args_json\t{json.dumps(server.get('args', []))}")
print(f"expected_args_json\t{json.dumps(expected_args)}")
PYEOF
)"
    while IFS=$'\t' read -r key value; do
        case "$key" in
            parse_error) MCP_PARSE_ERROR="$value" ;;
            type) MCP_TYPE="$value" ;;
            command) MCP_COMMAND="$value" ;;
            args_json) MCP_ARGS_JSON="$value" ;;
            expected_args_json) EXPECTED_ARGS_JSON="$value" ;;
        esac
    done <<< "$MCP_INFO"

    if [ -n "$MCP_PARSE_ERROR" ]; then
        fail "Workspace MCP config is invalid"
        detail "Reason: $MCP_PARSE_ERROR"
        detail "Run: bash setup.sh"
    elif [ "$MCP_TYPE" != "stdio" ]; then
        fail "Workspace MCP config must use a stdio server"
        detail "Run: bash setup.sh"
    elif [ -z "$MCP_COMMAND" ]; then
        fail "Workspace MCP config is missing the launch command"
        detail "Run: bash setup.sh"
    elif [[ "$MCP_COMMAND" != /* ]]; then
        fail "Workspace MCP config must use an absolute uv path"
        detail "Current command: $MCP_COMMAND"
        detail "Run: bash setup.sh"
    elif [ ! -x "$MCP_COMMAND" ]; then
        fail "Workspace MCP config points to a missing or non-executable uv binary"
        detail "Current command: $MCP_COMMAND"
        detail "Run: bash setup.sh"
    elif [ "$MCP_ARGS_JSON" != "$EXPECTED_ARGS_JSON" ]; then
        fail "Workspace MCP config does not use the guarded launcher command"
        detail "Expected: uv run --directory $CANONICAL_LINK python scripts/run_mcp_server.py"
        detail "Run: bash setup.sh"
    else
        pass "Workspace MCP config points to the guarded launcher ($MCP_CONFIG)"
        MCP_CONFIG_OK=true

        if [ -n "$EXPECTED_UV" ] && [ "$MCP_COMMAND" != "$EXPECTED_UV" ]; then
            warn "Workspace MCP config uses a different uv path than the active shell"
            detail "Config: $MCP_COMMAND"
            detail "Shell:  $EXPECTED_UV"
            detail "If this drift is unintended, run: bash setup.sh"
        fi
    fi
fi

# ─── 8b. Canonical bridge link ────────────────────────────────────────────────

REPO_ROOT_PHYS="$(cd "$REPO_ROOT" && pwd -P)"

if [ -L "$CANONICAL_LINK" ]; then
    LINK_TARGET="$(readlink -f "$CANONICAL_LINK" 2>/dev/null || readlink "$CANONICAL_LINK" 2>/dev/null || true)"
    if [ "$LINK_TARGET" = "$REPO_ROOT_PHYS" ]; then
        pass "Canonical bridge link resolves to this repository ($CANONICAL_LINK -> $LINK_TARGET)"
    else
        fail "Canonical bridge link points elsewhere ($CANONICAL_LINK -> ${LINK_TARGET:-<broken>})"
        detail "Run: bash setup.sh"
    fi
elif [ -e "$CANONICAL_LINK" ]; then
    fail "Canonical bridge path exists but is not a symlink: $CANONICAL_LINK"
    detail "Remove or rename it manually, then run: bash setup.sh"
else
    fail "Canonical bridge link is missing: $CANONICAL_LINK"
    detail "Run: bash setup.sh"
fi

# ─── 9. MCP server startup (exact workspace command) ──────────────────────────

if [ "$MCP_CONFIG_OK" = true ]; then
    MCP_LAUNCH_LOG="$TMPDIR/mcp-launch.log"
    "${MCP_COMMAND}" run --directory "$CANONICAL_LINK" python scripts/run_mcp_server.py < <(sleep 5) >"$MCP_LAUNCH_LOG" 2>&1 &
    SERVER_PID=$!
    sleep 2

    if kill -0 "$SERVER_PID" 2>/dev/null; then
        pass "MCP server starts and stays alive with the exact workspace launch command"
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null || true
    else
        fail "MCP server exited immediately when launched from .mcp.json"
        STARTUP_DIAG="$(grep -v '^[[:space:]]*$' "$MCP_LAUNCH_LOG" | head -n 3 || true)"
        if [ -n "$STARTUP_DIAG" ]; then
            while IFS= read -r line; do
                detail "$line"
            done <<< "$STARTUP_DIAG"
        fi
        detail "Run: bash run.sh"
    fi
fi

# ─── 10. Palace health (read-only) ──────────────────────────────────────────────

PALACE_PATH=""
MANIFEST_PATH=""
PALACE_INFO_READY=false
PALACE_SAFE=true

if [ -f "$VENV_PYTHON" ] && [ -n "$MEMPALACE_VERSION" ]; then
    PALACE_FACTS="$("$VENV_PYTHON" - <<'PYEOF' 2>/dev/null || true
from pathlib import Path

from mempalace.config import MempalaceConfig

cfg = MempalaceConfig()
palace_path = Path(cfg.palace_path)
print(f"palace_path\t{palace_path}")
print(f"manifest_path\t{palace_path / 'mempalace-bridge-manifest.json'}")
print(f"collection_name\t{cfg.collection_name}")
PYEOF
)"
    while IFS=$'\t' read -r key value; do
        case "$key" in
            palace_path) PALACE_PATH="$value" ;;
            manifest_path) MANIFEST_PATH="$value" ;;
            collection_name) ACTIVE_COLLECTION_NAME="$value" ;;
        esac
    done <<< "$PALACE_FACTS"

    if [ -n "$PALACE_PATH" ] && [ -n "$MANIFEST_PATH" ]; then
        PALACE_INFO_READY=true
    fi

    if [ "$PALACE_INFO_READY" = true ] && [ -f "$PALACE_PATH/chroma.sqlite3" ]; then
        PALACE_SAFETY_RESULT="$("$VENV_PYTHON" - <<PYEOF 2>/dev/null || true
import sys
from pathlib import Path

sys.path.insert(0, str(Path(r"$REPO_ROOT") / "scripts"))

from palace_safety_gate import evaluate_palace_safety  # type: ignore

result = evaluate_palace_safety(Path(r"$PALACE_PATH"), "read")
print(f"allowed\t{1 if result.allowed else 0}")
print(f"classification\t{result.classification}")
print(f"message\t{result.message}")
PYEOF
)"
        PALACE_SAFETY_ALLOWED=""
        PALACE_SAFETY_CLASS=""
        PALACE_SAFETY_MESSAGE=""
        while IFS=$'\t' read -r key value; do
            case "$key" in
                allowed) PALACE_SAFETY_ALLOWED="$value" ;;
                classification) PALACE_SAFETY_CLASS="$value" ;;
                message) PALACE_SAFETY_MESSAGE="$value" ;;
            esac
        done <<< "$PALACE_SAFETY_RESULT"

        if [ "$PALACE_SAFETY_ALLOWED" = "1" ]; then
            pass "Palace format is safe for the stable path ($PALACE_SAFETY_CLASS)"
        else
            PALACE_SAFE=false
            fail "Palace format is unsafe for the stable path ($PALACE_SAFETY_CLASS)"
            detail "$PALACE_SAFETY_MESSAGE"
            detail "Palace health and manifest trust checks were skipped to avoid opening it with the wrong stack."
        fi
    fi

    HEALTH_EXIT=0
    if [ "$PALACE_SAFE" = true ]; then
        HEALTH_OUTPUT=$(bash "$REPO_ROOT/scripts/check_palace_health.sh" --read-only 2>&1) || HEALTH_EXIT=$?
    fi

    if [ "$PALACE_SAFE" != true ]; then
        :
    elif [ "$HEALTH_EXIT" -eq 0 ]; then
        DRAWER_COUNT=$(echo "$HEALTH_OUTPUT" | grep -oE '[0-9]+ drawers' | grep -oE '[0-9]+' || true)
        pass "Palace is readable${DRAWER_COUNT:+ ($DRAWER_COUNT drawers)}"
    elif [ "$HEALTH_EXIT" -eq 2 ]; then
        warn "Palace is not initialized yet"
        detail "Manifest and palace drift checks were skipped because no palace database exists yet."
    else
        fail "Palace is not safely readable"
        while IFS= read -r line; do
            [ -n "$line" ] && detail "$line"
        done <<< "$HEALTH_OUTPUT"
    fi
fi

# ─── 11. Palace manifest integrity and drift ────────────────────────────────────

if [ "$PALACE_INFO_READY" = true ] && [ "$PALACE_SAFE" = true ]; then
    MANIFEST_RESULT="$("$VENV_PYTHON" - <<PYEOF 2>/dev/null || true
import importlib.metadata
import json
import platform
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(r"$REPO_ROOT") / "scripts"))

from palace_manifest import (  # type: ignore
    BRIDGE_NAME,
    COMPATIBILITY_LINE,
    STORAGE_BACKEND,
    STORAGE_FORMAT,
    validate_manifest,
)

manifest_path = Path(r"$MANIFEST_PATH")
active_python = platform.python_version()
active_mempalace = importlib.metadata.version("mempalace")
active_chromadb = importlib.metadata.version("chromadb")
active_collection_name = r"${ACTIVE_COLLECTION_NAME:-}"

if not manifest_path.exists():
    print("state\tmissing")
    raise SystemExit(0)

try:
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
except Exception as exc:
    print("state\tinvalid")
    print(f"issue\tmanifest is not readable JSON: {exc}")
    raise SystemExit(0)

validation_error = validate_manifest(data)
if validation_error is not None:
    print("state\tinvalid")
    print(f"issue\tmanifest schema is invalid: {validation_error}")
    raise SystemExit(0)

fatal_issues = []
warning_issues = []

if data.get("bridge") != BRIDGE_NAME:
    fatal_issues.append(f"manifest bridge={data.get('bridge')!r} does not match {BRIDGE_NAME!r}")

if data.get("storage_backend") != STORAGE_BACKEND:
    fatal_issues.append(
        f"manifest storage_backend={data.get('storage_backend')!r} does not match {STORAGE_BACKEND!r}"
    )

if data.get("storage_format") != STORAGE_FORMAT:
    fatal_issues.append(
        f"manifest storage_format={data.get('storage_format')!r} does not match {STORAGE_FORMAT!r}"
    )

if data.get("compatibility_line") != COMPATIBILITY_LINE:
    fatal_issues.append(
        f"manifest compatibility_line={data.get('compatibility_line')!r} does not match {COMPATIBILITY_LINE!r}"
    )

manifest_chromadb = str(data.get("chromadb_version", ""))
if not re.fullmatch(r"0\.6(?:\.\d+)?", manifest_chromadb):
    fatal_issues.append(f"manifest records chromadb_version={manifest_chromadb!r}, outside the supported 0.6.x line")

if data.get("python_version") != active_python:
    warning_issues.append(f"manifest python_version={data.get('python_version')} but active environment uses {active_python}")

if data.get("mempalace_version") != active_mempalace:
    warning_issues.append(
        f"manifest mempalace_version={data.get('mempalace_version')} but active environment uses {active_mempalace}"
    )

if manifest_chromadb != active_chromadb:
    warning_issues.append(f"manifest chromadb_version={manifest_chromadb} but active environment uses {active_chromadb}")

manifest_collection = data.get("collection_name")
if manifest_collection and active_collection_name and manifest_collection != active_collection_name:
    warning_issues.append(
        f"manifest collection_name={manifest_collection!r} but active environment uses {active_collection_name!r}"
    )

if fatal_issues:
    print("state\tfatal")
    for issue in fatal_issues:
        print(f"issue\t{issue}")
elif warning_issues:
    print("state\twarning")
    for issue in warning_issues:
        print(f"issue\t{issue}")
else:
    print("state\tok")
PYEOF
)"
    MANIFEST_STATE=""
    MANIFEST_ISSUES=()
    while IFS=$'\t' read -r key value; do
        case "$key" in
            state) MANIFEST_STATE="$value" ;;
            issue) MANIFEST_ISSUES+=("$value") ;;
        esac
    done <<< "$MANIFEST_RESULT"

    case "$MANIFEST_STATE" in
        ok)
            pass "Palace manifest exists and matches the active environment ($MANIFEST_PATH)"
            ;;
        missing)
            warn "Palace manifest is missing"
            detail "Expected: $MANIFEST_PATH"
            detail "If this palace should be bridge-managed, run: bash setup.sh"
            ;;
        invalid)
            warn "Palace manifest exists but is invalid"
            for issue in "${MANIFEST_ISSUES[@]}"; do
                detail "$issue"
            done
            detail "Re-run: bash setup.sh"
            ;;
        warning)
            warn "Palace manifest does not match the active environment"
            for issue in "${MANIFEST_ISSUES[@]}"; do
                detail "$issue"
            done
            ;;
        fatal)
            fail "Palace manifest declares incompatible metadata"
            for issue in "${MANIFEST_ISSUES[@]}"; do
                detail "$issue"
            done
            detail "Do not trust this palace with the current bridge until the mismatch is resolved."
            ;;
        *)
            warn "Palace manifest could not be evaluated"
            detail "Expected: $MANIFEST_PATH"
            ;;
    esac
fi

# ─── 12. Palace path not inside container filesystem ────────────────────────────

PALACE_PATH="${PALACE_PATH:-${MEMPALACE_PALACE_PATH:-$HOME/.mempalace/palace}}"
PALACE_ABS="${PALACE_PATH/#\~/$HOME}"

_in_container=false
for _prefix in /workspace /workspaces /app /opt "$REPO_ROOT"; do
    case "$PALACE_ABS" in
        "$_prefix" | "$_prefix"/*) _in_container=true; break ;;
    esac
done

if [ "$_in_container" = true ]; then
    fail "Palace path is inside a container-local filesystem ($PALACE_ABS)"
    detail "Data stored here is easy to lose on rebuild or container restart."
    detail "Use host-backed storage instead (for example: ~/.mempalace/palace)."
else
    pass "Palace path is outside container-local filesystems ($PALACE_ABS)"
fi

# ─── Summary ────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════"
if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo " Result: SUPPORTED and healthy"
    echo " $PASS checks passed."
elif [ "$FAIL" -eq 0 ]; then
    echo " Result: SUPPORTED but suspicious"
    echo " $PASS passed, $WARN warning(s)."
else
    echo " Result: UNSUPPORTED or unsafe"
    echo " $PASS passed, $WARN warning(s), $FAIL failure(s)."
    echo " Resolve the failures above before relying on this bridge."
fi
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ]
