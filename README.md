# MemPalace MCP Bridge for VS Code Copilot

Give [MemPalace](https://github.com/milla-jovovich/mempalace) a persistent local memory inside VS Code Copilot Chat.

This repo provides a plug-and-play bridge:

- one-command setup
- generated workspace MCP config
- automatic MCP server startup through VS Code
- full-stack verification with `verify.sh`
- a stable ChromaDB `0.6.x` line for existing palaces

---

## What you get

- Persistent memory inside Copilot Chat
- Fully local — no cloud, no API key, no Docker
- Auto-start — no terminal, VS Code handles everything
- Mine your own files — query your notes, docs, and decisions
- Built-in verification — `verify.sh` classifies the bridge as healthy, suspicious, or unsafe by checking the environment, the generated MCP config, real MCP startup, and palace manifest drift
- Palace safety checks — setup, update, verify, and runtime startup reject unsupported `chromadb` versions and keep the bridge on the supported `0.6.x` line
- Palace format safety gate — risky stable-path operations refuse palaces detected as `chroma_1_x` or `unknown`
- Palace manifest — setup writes `mempalace-bridge-manifest.json` into the palace root for version traceability
- Devcontainer integration — host palace mount shared across environments
- Safe ChromaDB `0.6.x` ↔ `1.x` reconstruction tooling — non-destructive and runtime-validated
- Reusable across environments with a shared palace

> **Compatibility status**
> This bridge targets ChromaDB `0.6.x` only (`chromadb>=0.6,<0.7`).
> ChromaDB `1.x` uses an incompatible storage format; non-`0.6.x` installs are rejected at startup.
> Palaces detected as `chroma_1_x` or `unknown` format are also rejected before any operation.
> `main` fails fast when the installed `chromadb` version is outside the `0.6.x` range.

This repository handles the **runtime and setup layer for VS Code Copilot Chat MCP integration**. For structured memory methodology, see [Memory Engineering](#memory-engineering).

---

## Who this is for

This repo is for you if:

- you want MemPalace working fast inside VS Code Copilot Chat
- you want a local setup with no manual MCP wiring
- you want a stable setup for existing palaces on Chroma `0.6.x`
- you prefer reproducibility over chasing the newest Chroma release

---

## Quickstart

```bash
# 1. Clone
git clone https://github.com/apajon/mempalace-mcp-bridge.git
cd mempalace-mcp-bridge

# 2. Setup (installs uv, mempalace, creates .venv, configures .mcp.json)
bash setup.sh

# 3. Open this folder in VS Code

code .

# 4. Verify
bash verify.sh
```

> **Important:** open the repository root folder in VS Code (`code .` from inside `mempalace-mcp-bridge/`). Opening a subfolder will prevent MCP from loading.

Then reload VS Code (`Ctrl+Shift+P` → **Developer: Reload Window**) if needed.

---

## MCP Configuration

The setup script generates `.mcp.json` automatically. To configure manually, create `.mcp.json` in your workspace:

```json
{
  "servers": {
    "mempalace": {
      "type": "stdio",
      "command": "/ABSOLUTE/PATH/TO/uv",
      "args": ["run", "--directory", "/ABSOLUTE/PATH/TO/mempalace-mcp-bridge", "python", "scripts/run_mcp_server.py"]
    }
  }
}
```

Replace paths with the output of `which uv` and the absolute path to this repo.
A ready-to-copy example is at [`examples/mcp/vscode.mcp.json`](examples/mcp/vscode.mcp.json).

See [docs/mcp_vscode.md](docs/mcp_vscode.md) for full details and troubleshooting.

---

## Update

```bash
git pull
bash update.sh
```

`update.sh` upgrades MemPalace, enforces the pinned ChromaDB line, checks `.mcp.json` paths, and runs `verify.sh`. It never touches `~/.mempalace/palace`.

See [docs/update_workflow.md](docs/update_workflow.md) for edge cases and what the script does step by step.

---

## Verify

```bash
bash verify.sh
```

Checks that the virtual environment, MemPalace, and MCP server are all healthy. Reports actionable errors if anything is broken.

---

## Test it in Copilot

```text
Open Copilot Chat and try:

"Remember that I like Python."

Restart VS Code, then ask:

"What do you remember about me?"
```

VS Code auto-starts the MemPalace MCP server when Copilot Chat opens.

---

## Use your own data

To mine your own notes after setup:

```bash
uv run --directory . mempalace mine /path/to/your/project
```

Then ask Copilot about anything in those files.

---

## Known limitations

- This bridge currently targets ChromaDB `0.6.x`, not ChromaDB `1.x`
- `main` hard-fails outside the supported `chromadb>=0.6,<0.7` range
- No migration to ChromaDB `1.x` is provided. Non-`0.6.x` palaces are blocked at startup.
- Experimental ChromaDB `1.x` investigation work exists outside this project's stable contract and is not part of the supported bridge workflow.
- Linux / WSL2 is the tested path today
- Copilot behavior remains probabilistic even with MemPalace as the preferred context source

---

## Devcontainer integration

For teams using VS Code devcontainers, the palace is mounted from the host so it persists across container rebuilds.

See [docs/devcontainer_integration.md](docs/devcontainer_integration.md) for the mount design and `.devcontainer` config.

---

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md).

---

## Why this exists

MemPalace is powerful, but not plug-and-play in real workflows.

Setting it up requires multiple manual steps and breaks the flow of using Copilot Chat.

That friction stops most users before they get any value.

This repo removes that friction.

---

## How it fits together

```text
VsCode Copilot Chat
  |
  v
MCP Server  <- launched automatically by Copilot via .mcp.json
  |
  v
MemPalace
  |
  v
Local Memory (palace)  <- ~/.mempalace/palace
```

`setup.sh` generates `.mcp.json` with the absolute path to your `uv` binary, so Copilot can start the server without any manual configuration.

If you already have a legacy `.vscode/mcp.json`, migrate it with:

```bash
jq '{servers: .servers}' .vscode/mcp.json > .mcp.json
```

The same setup step writes `mempalace-bridge-manifest.json` into the palace root. The file is intentionally small and easy to inspect manually: it records the bridge version, MemPalace version, ChromaDB version, Python version, storage backend and format, the supported compatibility line, and the creation timestamp. If a valid manifest already exists, setup preserves it. If the file exists but is malformed, setup replaces it with a fresh valid manifest.

---

## Memory Engineering

Advanced structured memory patterns — wings, rooms, retrieval order, persistence rules, deduplication — now live in a dedicated repository:

**[mempalace-memory-engineering](https://github.com/apajon/mempalace-memory-engineering)**

This includes:
- structured memory strategy for engineering workflows
- worked examples (two-wing / three-room setup)
- semantic deduplication reference

This repository focuses solely on MCP bridge setup and runtime integration. The methodology is not duplicated here.

---

## Documentation

### Setup & runtime

* Installation: [docs/installation.md](docs/installation.md)
* MCP / VS Code config: [docs/mcp_vscode.md](docs/mcp_vscode.md)
* Update workflow: [docs/update_workflow.md](docs/update_workflow.md)
* Devcontainer integration: [docs/devcontainer_integration.md](docs/devcontainer_integration.md)
* Troubleshooting: [docs/troubleshooting.md](docs/troubleshooting.md)

### Architecture & internals

* Architecture overview: [docs/architecture.md](docs/architecture.md)
* Error model: [docs/error_model.md](docs/error_model.md)
* Support matrix: [docs/support_matrix.md](docs/support_matrix.md)
* Limitations: [docs/limitations.md](docs/limitations.md)

### ChromaDB reconstruction (0.6.x → 1.x)

* CLI usage: [docs/cli_usage.md](docs/cli_usage.md)
* Palace format detection: [docs/palace_format_detection.md](docs/palace_format_detection.md)
* Reconstruction workflow: [docs/chromadb_reconstruction_workflow.md](docs/chromadb_reconstruction_workflow.md)
* Migration guide: [docs/chromadb_reconstruction_migration.md](docs/chromadb_reconstruction_migration.md)

### Compatibility

* Linux (tested on Ubuntu 24.04 via WSL2)
* VS Code with [GitHub Copilot Chat](https://marketplace.visualstudio.com/items?itemName=GitHub.copilot-chat)
* `curl` required (`setup.sh` uses it to install `uv`)
* ChromaDB `0.6.x` line pinned intentionally via `chromadb>=0.6,<0.7`

### Copilot context guidance

* Copilot is configured to use MemPalace as its primary context source via `.github/copilot-instructions.md`
* Query order: MemPalace project wing -> shared wings -> `docs/architecture.md` -> `README.md` -> workspace search
* This improves first-response relevance. It is not a strict guarantee - Copilot behavior is probabilistic

### Memory Engineering (external)

* Strategy, examples, deduplication: [mempalace-memory-engineering](https://github.com/apajon/mempalace-memory-engineering)

---

## Related

* MemPalace: [https://github.com/milla-jovovich/mempalace](https://github.com/milla-jovovich/mempalace)
* ChromaDB: [https://github.com/chroma-core/chroma](https://github.com/chroma-core/chroma)
* Memory Engineering: [https://github.com/apajon/mempalace-memory-engineering](https://github.com/apajon/mempalace-memory-engineering)

---
