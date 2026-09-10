# Architecture Overview

This document explains how MemPalace fits into the local development stack when used with an MCP-compatible chat client.

---

## What MemPalace is (and is not)

**MemPalace is a local memory layer**, not a chatbot and not an LLM.

It:
- Mines text files (Markdown, code, notes) into a local vector store
- Exposes a MCP server so that chat clients can query that memory during conversations
- Runs entirely on your machine — no data leaves your environment
- Requires no API key

It does not:
- Replace or augment the LLM itself
- Provide a chat interface
- Automatically appear in every chat session — it must be configured as a MCP server

---

## Data flow

```
Source files (Markdown, code, notes)
        │
        ▼
 mempalace mine <path>
        │
        ▼
Local vector store (~/.mempalace/ or configured path)
        │
        ▼
 python scripts/run_mcp_server.py ◄── guarded launcher started by MCP client
        │
        ▼
MCP client (VS Code / Copilot Chat / other)
        │
        ▼
 User sends a message in chat
        │
        ▼
 MCP tool call: mempalace.search(query)
        │
        ▼
 Retrieved memory snippets injected into LLM context
        │
        ▼
 LLM produces response enriched with local memory
```

---

## Components

| Component | Role |
|---|---|
| `uv` | Python environment and package manager |
| `mempalace` CLI | Indexes files into local memory |
| `scripts/run_mcp_server.py` | Enforces the supported ChromaDB line, then starts the MCP server |
| `scripts/link_bridge.sh` | Maintains the canonical symlink `$HOME/.local/share/mempalace-mcp-bridge` |
| `mempalace.mcp_server` | Exposes memory as MCP tools |
| MCP client | Launches the server, sends tool calls |
| LLM (remote) | Generates responses using memory context |

---

## Auto-start sequence

1. User opens a chat session in the MCP-compatible client
2. Client reads `.mcp.json` (or equivalent config)
3. Client launches `uv run --directory $HOME/.local/share/mempalace-mcp-bridge python scripts/run_mcp_server.py` as a subprocess (the canonical bridge path — a symlink to the real clone)
4. Server starts in stdio mode and waits for MCP protocol messages
5. When the user asks a question, the client may call `mempalace` tools
6. Tools return relevant memory chunks
7. These chunks are included in the LLM prompt
8. LLM responds with context-aware output
9. When the session ends, the server process is killed and will be restarted next time

---

## Local data storage

MemPalace stores its indexed data locally. Default location:

```
~/.mempalace/
```

The contents are not versioned (excluded by `.gitignore`). If you delete this directory, you need to re-run `mempalace mine`.

During initialization, the bridge writes `mempalace-bridge-manifest.json` into the palace root. This is a narrow safety artifact, not a general config layer: it captures creation-time versions plus the storage compatibility line so future tooling can identify bridge-created palaces and reason about older storage more safely.

### Bridge path vs palace path

The bridge repository may be cloned anywhere. Installation exposes a stable
canonical path — `$HOME/.local/share/mempalace-mcp-bridge` — as a symlink to
the real clone. The palace remains host-owned under `~/.mempalace` and is never
stored inside, or tied to, the repository location. See
[canonical_link.md](canonical_link.md).

---

## Copilot context strategy

**Problem:** Copilot may rely on opaque internal context, especially on first interaction with a repository.

**Solution:**

- `.github/copilot-instructions.md` — global instructions that bias context selection toward MemPalace
- `.github/instructions/mempalace-mcp-bridge.instructions.md` — scoped instructions providing project-specific conventions and memory structure

**Limitation:** Behavior is probabilistic. Instructions steer context selection but do not enforce it strictly.

---

## Why uv?

`uv` is used instead of `pip` + `venv` because:
- It creates reproducible environments faster
- It handles Python version pinning via `.python-version`
- It supports `uv run` to execute commands inside the environment without activating it
- It is the recommended approach for isolated Python tooling on Linux developer workstations
