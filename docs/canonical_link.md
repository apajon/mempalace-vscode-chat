# Canonical bridge path — location-independent installation

This document explains how the MemPalace MCP bridge can be cloned **anywhere**
while still exposing a single, stable path that every consumer can rely on.

---

## The two locations

The bridge repository and the palace data are separate concerns and live in
separate places.

| Concern | Path | Owner |
|---|---|---|
| **Real bridge clone** | anywhere (e.g. `~/git/mempalace-mcp-bridge`, `~/dev/tools/…`, `/mnt/data/repos/…`) | you |
| **Canonical bridge path** | `$HOME/.local/share/mempalace-mcp-bridge` | the installer |
| **Palace** (persistent data) | `$HOME/.mempalace` (normally `$HOME/.mempalace/palace`) | host |

---

## The canonical path is a symlink, not a clone location

The canonical path is **not** a required clone location. You may clone the
repository anywhere you like:

```
REAL CLONE
/any/path/mempalace-mcp-bridge
          │
          │ install (setup.sh)
          ▼
$HOME/.local/share/mempalace-mcp-bridge
          │
          └── symlink → /any/path/mempalace-mcp-bridge
```

Running the normal bridge install **once** creates the symlink. From then on,
consumers reference only the canonical path and never the real clone path.

The distinction matters:

- **Real clone** — where you ran `git clone`. This path is your private choice
  and may differ from machine to machine.
- **Canonical path** — an *access symlink* created by installation. It is
  stable across machines (`$HOME/.local/share/mempalace-mcp-bridge`).

---

## Installation responsibility

The bridge installer (`setup.sh`) is responsible for creating and maintaining
the canonical symlink via `scripts/link_bridge.sh`. Consumers must never need
to create it themselves.

Safe, idempotent semantics:

| State of canonical path | Behaviour |
|---|---|
| absent | create the symlink |
| symlink to this repo | success — no destructive action |
| broken symlink | replace with the current repo target |
| symlink to another clone | report old target, re-point to this repo, report new target (the old clone is **never** deleted) |
| real directory or regular file | **stop** with a clear error — nothing is overwritten, renamed, or removed |

The symlink target is an absolute, normalized path (the physical repository
root), so:

```bash
readlink    "$HOME/.local/share/mempalace-mcp-bridge"
readlink -f "$HOME/.local/share/mempalace-mcp-bridge"
```

both resolve to the actual clone.

---

## Classic workspace contract

After running the bridge install once, the stable paths are:

```
Bridge:  $HOME/.local/share/mempalace-mcp-bridge
Palace:  $HOME/.mempalace/palace
```

Workspace / MCP integrations use the canonical path and never the real clone
path. Example conceptual MCP execution:

```bash
uv run \
    --directory "$HOME/.local/share/mempalace-mcp-bridge" \
    python -m mempalace.mcp_server
```

with:

```
MEMPALACE_PALACE_PATH=$HOME/.mempalace/palace
```

(`setup.sh` generates the concrete `.mcp.json` for the current machine; the
repository ships a ready-to-adapt template at `examples/mcp/vscode.mcp.json`.)

---

## Palace ownership

The palace remains host-owned and shared:

```
$HOME/.mempalace
```

The installer may ensure expected directories exist, but it must **never**:

- relocate palace data,
- delete palace data,
- initialise a second palace inside the repository,
- replace existing palace contents.

Bridge code and palace data remain separate.

---

## Uninstall semantics

There is no full uninstaller, and none is required: the only installation
artifact outside the clone is the canonical symlink.

`scripts/link_bridge.sh --unlink` removes `$HOME/.local/share/mempalace-mcp-bridge`
**only** when it is a symlink. It never deletes:

- the actual Git clone,
- `$HOME/.mempalace`,
- palace data.

If the canonical path is a real directory or file, `--unlink` refuses to act.
