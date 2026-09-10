#!/usr/bin/env bash
# tests/test_link_bridge.sh
#
# Exercises scripts/link_bridge.sh against a temporary HOME. Never touches the
# developer's real HOME, real clone, or palace data.
#
# Covers the canonical-link contract:
#   A. arbitrary clone path, canonical link absent  -> symlink created
#   B. installer run twice                          -> idempotent success
#   C. symlink points to old clone                  -> updated, old clone intact
#   D. broken symlink                               -> repaired
#   E. canonical path is a real directory           -> fatal, directory untouched
#   F. canonical path is a regular file             -> fatal, file untouched
#   G. invoked outside the repository cwd           -> real repo detected
#   H. --unlink removes the owned symlink only      -> clone and palace intact
#   I. --unlink refuses to delete a real directory

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINK_SCRIPT="$REPO_ROOT/scripts/link_bridge.sh"

PASS=0
FAIL=0

pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"
FAKE_REPO="$TMP/repos/mempalace-mcp-bridge"
OLD_REPO="$TMP/repos/old-mempalace-mcp-bridge"

mkdir -p "$FAKE_HOME"
mkdir -p "$FAKE_REPO/scripts" "$OLD_REPO"
cp "$LINK_SCRIPT" "$FAKE_REPO/scripts/link_bridge.sh"
printf 'name = "mempalace-mcp-bridge"\n' > "$FAKE_REPO/pyproject.toml"
printf 'name = "old-clone"\n' > "$OLD_REPO/pyproject.toml"

LINK="$FAKE_HOME/.local/share/mempalace-mcp-bridge"
EXPECTED_TARGET="$(cd "$FAKE_REPO" && pwd -P)"
OLD_TARGET="$(cd "$OLD_REPO" && pwd -P)"

# Runs the link script with a temporary HOME, from an arbitrary working
# directory (defaults to $TMP so we are never in the fake repo).
run_installer() {
    (cd "${2:-$TMP}" && HOME="$FAKE_HOME" bash "$FAKE_REPO/scripts/link_bridge.sh" "${1:-}")
}

echo "== A: absent canonical link -> symlink created =="
rm -rf "$FAKE_HOME/.local"
if run_installer "" >/dev/null 2>&1; then pass "installer exits 0"; else fail "installer exits 0"; fi
if [ -L "$LINK" ]; then pass "canonical path is a symlink"; else fail "canonical path is a symlink"; fi
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$EXPECTED_TARGET" ]; then
    pass "symlink points to the real clone"
else
    fail "symlink points to the real clone (got '$(readlink "$LINK" 2>/dev/null || true)', want '$EXPECTED_TARGET')"
fi

echo "== B: run twice -> idempotent success =="
if run_installer "" >/dev/null 2>&1; then pass "second run exits 0"; else fail "second run exits 0"; fi
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$EXPECTED_TARGET" ]; then
    pass "symlink unchanged and still correct"
else
    fail "symlink unchanged and still correct"
fi

echo "== C: symlink to old clone -> updated, old clone untouched =="
rm -f "$LINK"
mkdir -p "$FAKE_HOME/.local/share"
ln -s "$OLD_TARGET" "$LINK"
OUT_C="$(run_installer "" 2>&1)"
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$EXPECTED_TARGET" ]; then
    pass "symlink updated to current clone"
else
    fail "symlink updated to current clone"
fi
if [ -d "$OLD_REPO" ] && [ -f "$OLD_REPO/pyproject.toml" ]; then
    pass "old clone left untouched"
else
    fail "old clone left untouched"
fi
if printf '%s' "$OUT_C" | grep -q "old target: $OLD_TARGET"; then
    pass "old target reported"
else
    fail "old target reported"
fi

echo "== D: broken symlink -> repaired =="
rm -f "$LINK"
ln -s "$TMP/does-not-exist" "$LINK"
if run_installer "" >/dev/null 2>&1; then pass "repair run exits 0"; else fail "repair run exits 0"; fi
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$EXPECTED_TARGET" ]; then
    pass "broken symlink repaired"
else
    fail "broken symlink repaired"
fi

echo "== E: real directory -> fatal, untouched =="
rm -f "$LINK"
mkdir -p "$LINK"
touch "$LINK/keep.txt"
if run_installer "" >/dev/null 2>&1; then fail "real directory causes fatal error"; else pass "real directory causes fatal error"; fi
if [ -d "$LINK" ] && [ ! -L "$LINK" ] && [ -f "$LINK/keep.txt" ]; then
    pass "directory untouched"
else
    fail "directory untouched"
fi

echo "== F: regular file -> fatal, untouched =="
rm -rf "$LINK"
printf 'sentinel' > "$LINK"
if run_installer "" >/dev/null 2>&1; then fail "regular file causes fatal error"; else pass "regular file causes fatal error"; fi
if [ -f "$LINK" ] && [ ! -L "$LINK" ] && [ "$(cat "$LINK")" = "sentinel" ]; then
    pass "file untouched"
else
    fail "file untouched"
fi

echo "== G: invoked outside repository cwd -> real repo detected =="
rm -rf "$FAKE_HOME/.local"
(cd /tmp && HOME="$FAKE_HOME" bash "$FAKE_REPO/scripts/link_bridge.sh") >/dev/null 2>&1
if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$EXPECTED_TARGET" ]; then
    pass "installer detects the real repo from outside its cwd"
else
    fail "installer detects the real repo from outside its cwd"
fi

echo "== H: --unlink removes the owned symlink only =="
rm -rf "$FAKE_HOME/.local"
run_installer "" >/dev/null 2>&1
if run_installer "--unlink" >/dev/null 2>&1; then pass "--unlink exits 0 on an owned symlink"; else fail "--unlink exits 0 on an owned symlink"; fi
if [ ! -e "$LINK" ] && [ ! -L "$LINK" ]; then pass "--unlink removed the symlink"; else fail "--unlink removed the symlink"; fi
if [ -d "$FAKE_REPO" ] && [ -f "$FAKE_REPO/pyproject.toml" ]; then pass "real clone preserved"; else fail "real clone preserved"; fi
if [ ! -e "$FAKE_HOME/.mempalace" ]; then pass "palace path untouched"; else fail "palace path untouched"; fi

echo "== I: --unlink refuses a real directory =="
rm -rf "$FAKE_HOME/.local"
mkdir -p "$LINK"
if run_installer "--unlink" >/dev/null 2>&1; then fail "--unlink refuses a real directory"; else pass "--unlink refuses a real directory"; fi
if [ -d "$LINK" ] && [ ! -L "$LINK" ]; then pass "real directory untouched"; else fail "real directory untouched"; fi

echo ""
echo "─────────────────────────────────────────"
echo " $PASS passed, $FAIL failed."
echo "─────────────────────────────────────────"

[ "$FAIL" -eq 0 ]
