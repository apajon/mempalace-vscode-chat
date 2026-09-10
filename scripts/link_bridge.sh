#!/usr/bin/env bash
# scripts/link_bridge.sh
#
# Exposes the MemPalace MCP bridge under a stable, location-independent path:
#
#     $HOME/.local/share/mempalace-mcp-bridge   ->   <real clone>
#
# The bridge may be cloned anywhere. This script owns the canonical symlink so
# that consumers (classic workspaces, VS Code MCP, devcontainers, scripts, and
# future integrations) never need to know the real clone location.
#
# Safe and idempotent behaviour:
#   - canonical path absent            -> create the symlink
#   - symlink to the current repo      -> success, no destructive action
#   - broken symlink                   -> replace with the current repo target
#   - symlink to another clone         -> report old target, re-point to this
#                                         repo, report new target (the old
#                                         clone is NEVER deleted)
#   - real directory or regular file   -> fatal error, object left untouched
#
# The Palace itself is a separate concern and is never touched here. Persistent
# user data remains host-owned under $HOME/.mempalace.
#
# Usage:
#   bash scripts/link_bridge.sh            # ensure the canonical symlink
#   bash scripts/link_bridge.sh --status   # report the current state
#   bash scripts/link_bridge.sh --unlink   # remove the canonical symlink ONLY
#
# The real repository root is derived from THIS script's own location, not from
# the caller's working directory, so it works from anywhere:
#
#     cd /tmp
#     /somewhere/mempalace-mcp-bridge/scripts/link_bridge.sh

set -euo pipefail

# ─── Locate the real repository root ──────────────────────────────────────────
# Derive it from the installer's own path (BASH_SOURCE), never from $PWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# Belt-and-braces cross-check against the Git repository root when available.
if git -C "$REPO_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
    GIT_ROOT="$(cd "$(git -C "$REPO_ROOT" rev-parse --show-toplevel)" && pwd -P)"
    if [ "$GIT_ROOT" != "$REPO_ROOT" ]; then
        echo "[WARN]  Installer root ($REPO_ROOT) differs from Git root ($GIT_ROOT)." >&2
        echo "[WARN]  Using installer root: $REPO_ROOT" >&2
    fi
fi

CANONICAL_PARENT="${HOME}/.local/share"
CANONICAL_LINK="${CANONICAL_PARENT}/mempalace-mcp-bridge"

info() { echo "[INFO]  $*"; }
ok()   { echo "[OK]    $*"; }
warn() { echo "[WARN]  $*"; }
fail() {
    local line
    for line in "$@"; do
        echo "[ERROR] $line" >&2
    done
    exit 1
}

# Best-effort physical resolution of a path (resolves symlinked parents).
resolve_physical() {
    local path="$1"
    if command -v readlink >/dev/null 2>&1 && readlink -f "$path" >/dev/null 2>&1; then
        readlink -f "$path"
        return 0
    fi
    if [ -d "$path" ]; then
        (cd "$path" && pwd -P) 2>/dev/null || echo "$path"
        return 0
    fi
    echo "$path"
}

# True when the canonical path is a symlink whose target resolves to this repo.
is_symlink_to_this_repo() {
    [ -L "$CANONICAL_LINK" ] || return 1
    local raw resolved
    raw="$(readlink "$CANONICAL_LINK" 2>/dev/null || true)"
    resolved="$(resolve_physical "$CANONICAL_LINK" 2>/dev/null || true)"
    [ "$raw" = "$REPO_ROOT" ] || [ "$resolved" = "$REPO_ROOT" ]
}

ensure_canonical_link() {
    # Canonical path absent (neither a file nor a symlink) -> create.
    if [ ! -e "$CANONICAL_LINK" ] && [ ! -L "$CANONICAL_LINK" ]; then
        info "Canonical link absent — creating it."
        mkdir -p "$CANONICAL_PARENT"
        ln -s "$REPO_ROOT" "$CANONICAL_LINK"
        ok "Created canonical link: $CANONICAL_LINK -> $REPO_ROOT"
        return 0
    fi

    if [ -L "$CANONICAL_LINK" ]; then
        if is_symlink_to_this_repo; then
            ok "Canonical link already points to this repository: $CANONICAL_LINK -> $REPO_ROOT"
            return 0
        fi

        local old_target
        old_target="$(readlink "$CANONICAL_LINK" 2>/dev/null || true)"
        if [ -e "$CANONICAL_LINK" ]; then
            warn "Canonical link points to another clone:"
            warn "  old target: $old_target"
        else
            warn "Canonical link is broken (target no longer exists):"
            warn "  stale target: $old_target"
        fi

        # Replace the symlink. The previous clone (if any) is left untouched.
        rm "$CANONICAL_LINK"
        mkdir -p "$CANONICAL_PARENT"
        ln -s "$REPO_ROOT" "$CANONICAL_LINK"
        ok "Updated canonical link: $CANONICAL_LINK -> $REPO_ROOT"
        return 0
    fi

    # Exists but is NOT a symlink: a real directory or regular file.
    if [ -d "$CANONICAL_LINK" ]; then
        fail "Canonical path '$CANONICAL_LINK' is a real directory." \
             "Refusing to modify it. Remove or rename it manually, then re-run setup."
    else
        fail "Canonical path '$CANONICAL_LINK' is a regular file." \
             "Refusing to modify it. Remove or rename it manually, then re-run setup."
    fi
}

status_canonical() {
    if [ ! -e "$CANONICAL_LINK" ] && [ ! -L "$CANONICAL_LINK" ]; then
        info "Canonical link: ABSENT ($CANONICAL_LINK)"
        return 0
    fi

    if [ -L "$CANONICAL_LINK" ]; then
        local raw resolved
        raw="$(readlink "$CANONICAL_LINK" 2>/dev/null || true)"
        resolved="$(resolve_physical "$CANONICAL_LINK" 2>/dev/null || true)"
        info "Canonical link: $CANONICAL_LINK"
        info "  target (raw):      ${raw:-<unreadable>}"
        info "  target (resolved): ${resolved:-<broken>}"
        if is_symlink_to_this_repo; then
            ok "Points to this repository ($REPO_ROOT)"
        else
            warn "Does NOT point to this repository ($REPO_ROOT)"
        fi
        return 0
    fi

    warn "Canonical path is a real filesystem object (not a symlink): $CANONICAL_LINK"
    return 1
}

unlink_canonical() {
    if [ ! -e "$CANONICAL_LINK" ] && [ ! -L "$CANONICAL_LINK" ]; then
        ok "Canonical link is already absent ($CANONICAL_LINK)"
        return 0
    fi

    if [ -L "$CANONICAL_LINK" ]; then
        local target
        target="$(readlink "$CANONICAL_LINK" 2>/dev/null || true)"
        rm "$CANONICAL_LINK"
        ok "Removed canonical symlink ($CANONICAL_LINK -> ${target:-<broken>})"
        ok "The real clone at $REPO_ROOT was NOT touched."
        ok "Palace data under $HOME/.mempalace was NOT touched."
        return 0
    fi

    fail "Canonical path '$CANONICAL_LINK' is not a symlink." \
         "Refusing to delete it. It may be a real directory or file — remove it manually if you are sure."
}

case "${1:-}" in
    --status) status_canonical ;;
    --unlink) unlink_canonical ;;
    ""|--link) ensure_canonical_link ;;
    *)
        echo "Usage: $0 [--link|--status|--unlink]" >&2
        exit 2
        ;;
esac
