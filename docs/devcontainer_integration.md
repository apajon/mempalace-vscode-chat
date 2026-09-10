# MemPalace devcontainer integration

This guide explains how to make MemPalace available inside a VS Code devcontainer, with the palace shared between the host and the container.

---

## Design principle: host as source of truth

Containers are ephemeral execution environments — they do not own data. The palace must persist independently from the container lifecycle.

Mounting the palace from the host ensures consistency across:

- local tools
- devcontainers
- multiple projects

> **Warning:** without this, each environment may initialise its own palace, creating multiple independent stores that silently diverge.

---

## Design rationale

| Element | Host side | Container side |
|---|---|---|
| **MCP bridge** (`mempalace-mcp-bridge`) | `$HOME/.local/share/mempalace-mcp-bridge` (symlink to the real clone) | mounted read-only at `/opt/mempalace-mcp-bridge` |
| **Palace** (`~/.mempalace`) | `~/.mempalace` | `~/.mempalace` of the container user |

**The bridge is not cloned inside the container.** Keeping it on the host and mounting it at a fixed path (`/opt/mempalace-mcp-bridge`) means scripts, MCP config, and hooks always reference the same location regardless of where each developer stores the repo on their machine.

The host-side source is the **canonical bridge path** `$HOME/.local/share/mempalace-mcp-bridge`, which `setup.sh` creates as a symlink to the real clone (see [canonical_link.md](canonical_link.md)). The real clone may live anywhere; the devcontainer never needs to know where.

**A shared palace is used** so that everything the agent stores inside the container is immediately visible on the host, and vice versa. The bind mount ensures both environments point to the same data without copying or syncing.

**`MEMPALACE_PALACE_PATH` is set explicitly** in the MCP config to override any `config.json` that may have been inherited from another machine. This eliminates path/config inconsistencies caused by environment-specific differences in home directory layout or previous initializations.

> The bridge is mounted **read-only** at `/opt/mempalace-mcp-bridge`. Nothing is written back to the host repo.

---

## Prerequisites (host)

> The bridge may be cloned anywhere. The only requirement is that the normal
> bridge install has been run once, which creates the canonical symlink at
> `$HOME/.local/share/mempalace-mcp-bridge`.

1. Clone the `mempalace-mcp-bridge` repo wherever you like:

   ```bash
   git clone https://github.com/apajon/mempalace-mcp-bridge.git ~/git/mempalace-mcp-bridge
   # ...or any other location
   ```

2. Run the normal bridge install once. This creates the canonical symlink
   `$HOME/.local/share/mempalace-mcp-bridge` pointing at the real clone:

   ```bash
   bash ~/git/mempalace-mcp-bridge/setup.sh   # or the path where you cloned it
   ```

3. Make sure `uv` is available in the devcontainer Docker image.

---

## Step 1 — Prepare the host mount point (initializeCommand)

In `devcontainer.json`, add an `initializeCommand` that prepares the host-side directory before Docker creates the container:

```json
"initializeCommand": "mkdir -p ${HOME:-$(echo ~)}/.local/share || true"
```

This does two things:

- creates the expected host directory if it does not exist yet;
- tolerates cases where `HOME` is empty because VS Code's `userEnvProbe` timed out or the shell startup was incomplete.

The `|| true` prevents spurious devcontainer failures if the host shell environment is only partially initialised.

---

## Step 2 — Mount the bridge and the palace

In `devcontainer.json`, add the following mounts:

```json
"mounts": [
  "source=${localEnv:HOME}/.local/share/mempalace-mcp-bridge,target=/opt/mempalace-mcp-bridge,type=bind,consistency=cached,readonly",
  "source=${localEnv:HOME}/.mempalace,target=/home/<container-user>/.mempalace,type=bind"
]
```

> The bridge mount source is the canonical symlink created by `setup.sh`;
> Docker resolves the symlink and mounts the real clone.
>
> Replace `<container-user>` with the username inside the container (`dev`, `vscode`, `user`, etc.).
> Check with `whoami` in a devcontainer terminal.
>
> If `${localEnv:HOME}` is unreliable on your platform, replace it with an explicit absolute host path.

---

## Step 3 — Install dependencies and check the palace (post-create)

In `post-create.sh`, add the following block. It installs the bridge dependencies and runs the health check to detect and fix any ChromaDB incompatibilities:

```bash
MEMPALACE_DIR=/opt/mempalace-mcp-bridge
MEMPALACE_VENV=/home/<container-user>/.venv/mempalace-mcp-bridge

if [ -f "$MEMPALACE_DIR/pyproject.toml" ]; then
    echo 'MemPalace: installing dependencies...'
    UV_PROJECT_ENVIRONMENT="$MEMPALACE_VENV" uv sync --directory "$MEMPALACE_DIR" --quiet
    echo 'MemPalace: checking palace health...'
    bash "$MEMPALACE_DIR/scripts/check_palace_health.sh" || true
    echo 'MemPalace: ready'
else
    echo 'MemPalace: not available, skipping (run bash setup.sh on the host to create the canonical bridge link, then rebuild the container to enable it)'
fi
```

> Because the bridge is mounted `:ro`, `uv sync` must **not** try to create `.venv/` inside `/opt/mempalace-mcp-bridge`. `UV_PROJECT_ENVIRONMENT` redirects the environment to a writable path owned by the container user.
>
> `check_palace_health.sh` silently fixes ChromaDB incompatibilities
> (see [troubleshooting.md#chromadb-version-incompatibility](troubleshooting.md#chromadb-version-incompatibility)).

---

## Step 4 — Configure the MCP server in VS Code

In `.mcp.json` at the devcontainer workspace root:

```json
{
  "mcpServers": {
    "mempalace": {
      "type": "stdio",
      "command": "/home/<container-user>/.local/bin/uv",
       "args": [
         "run",
         "--directory", "/opt/mempalace-mcp-bridge",
         "python", "scripts/run_mcp_server.py"
       ],
      "env": {
        "MEMPALACE_PALACE_PATH": "/home/<container-user>/.mempalace/palace"
      }
    }
  }
}
```

**Why `MEMPALACE_PALACE_PATH`?**
Without this variable, the MCP server looks for the palace in the current container user's home directory. The variable makes it explicit and takes priority over any `config.json` inherited from another machine.
Configuration priority: `MEMPALACE_PALACE_PATH` > `~/.mempalace/config.json` > default.

VS Code Copilot will start the MCP server automatically when the chat is opened.

---

## Summary of files to modify

| File | Change |
|---|---|
| `devcontainer.json` | Robust `initializeCommand` + readonly mount from `${localEnv:HOME}/.local/share/mempalace-mcp-bridge` (the canonical bridge path) |
| `post-create.sh` | Conditional block: `UV_PROJECT_ENVIRONMENT=... uv sync` + `check_palace_health.sh` |
| `.mcp.json` | MCP server config with `env.MEMPALACE_PALACE_PATH` |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `initializeCommand` fails because `HOME` is empty | `userEnvProbe` timed out or shell startup did not fully initialise the environment | Use `mkdir -p ${HOME:-$(echo ~)}/.local/share || true` so the command still resolves a host home directory |
| `MemPalace: not available, skipping` | Empty mount — `pyproject.toml` missing | Verify that `$HOME/.local/share/mempalace-mcp-bridge` exists on the host and resolves to the real clone, and that the mount points to it |
| Bridge mount is empty in the container | `$HOME/.local/share/mempalace-mcp-bridge` is missing on the host or mounted from the wrong absolute path | Run `bash setup.sh` in the real clone to create the canonical symlink, or replace the mount source with the correct absolute host path |
| `uv sync` fails with a write or permission error under `/opt/mempalace-mcp-bridge` | The bridge repo is mounted read-only | Set `UV_PROJECT_ENVIRONMENT=/home/<container-user>/.venv/mempalace-mcp-bridge` before `uv sync` |
| `"No palace found"` in MCP tools | Palace not mounted or `MEMPALACE_PALACE_PATH` missing/incorrect | Check the `~/.mempalace` bind mount and the `env.MEMPALACE_PALACE_PATH` key in `.mcp.json` |
| Palace present on host but empty in container | Incorrect `<container-user>` in the mount or in `MEMPALACE_PALACE_PATH` | Run `whoami` inside the container and fix both occurrences of `<container-user>` |
| MCP server does not start | Incorrect `uv` path in `.mcp.json` | Check with `which uv` in a devcontainer terminal and fix the `command` key |
| `uv: command not found` in container | `uv` missing from the Docker image | Add `RUN pip install uv` to the Dockerfile or via an `onCreateCommand` |
