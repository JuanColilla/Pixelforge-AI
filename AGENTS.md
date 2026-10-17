# AGENTS.md — Pixelforge AI

Guide for AI coding agents (Claude Code, Codex, Grok, Cursor…) working on this repository.
`CLAUDE.md` only points here. Human-facing docs live in `README.md`.

Pixelforge AI is an AI-assisted pixel-art editor: upstream **Pixelorama** (MIT, Godot 4.7) plus
the **AI Studio** extension, which generates sprites with several engines and exposes the
canvas to assistants through MCP. It talks only to public APIs; no third-party proprietary code.

## Stack

- Pixelorama `v1.2.3`, cloned into `Pixelorama/` by `scripts/setup.sh` (git-ignored, local
  branch `ai-studio`, patched with `patches/pixelorama-load-aistudio.patch`).
- Godot `4.7.x`.
- GDScript extension in `extension/AIStudio/`, symlinked to `Pixelorama/src/Extensions/AIStudio`.
- MCP server in Python ≥ 3.11 with `mcp` 2.x (`MCPServer`, not the v1 `FastMCP`), run with `uv`.
- Engines: ComfyUI (local, Z-Image Turbo by default), Grok CLI (`image_gen`), PixelLab API v2,
  Claude CLI (pixel mode via `--json-schema`, agent mode via MCP).

## Commands

```bash
scripts/setup.sh          # clone + patch Pixelorama, symlink, import assets, uv sync
scripts/run.sh            # run Pixelorama from source with the extension
scripts/package.sh        # dist/AIStudio.zip for a stock Pixelorama build
scripts/register-mcp.sh   # register pixelorama-mcp with Claude Code and/or Grok (user scope)
godot --headless --path Pixelorama --quit-after 300   # load check without a window
```

## Architecture

Details in `knowledge/architecture.md`. In short:

- `core/Generator.gd` orchestrates engine → `Pixelize.gd` → `CanvasOps.gd` (layer/cel/frame).
- `core/CanvasOps.gd` is the only write path to the canvas. Drawing ops are compiled and
  applied as one batch through `ExtensionsApi.project.set_pixelcel_image`: one undo step each.
- `bridge/BridgeServer.gd`: JSON-lines over TCP on `127.0.0.1:47821`; random token in
  `<Pixelorama user dir>/ai_studio/bridge.json` (owner-only permissions).
- `mcp/src/pixelorama_mcp/server.py`: thin MCP (stdio) → bridge translator.

### Invariants

- INV-1: the bridge listens on `127.0.0.1` only and checks the token on every request.
- INV-2: no canvas write bypasses `CanvasOps.write_cel`, so undo history stays complete.
- INV-3: extension nodes use `PROCESS_MODE_ALWAYS`; Pixelorama pauses the scene tree when
  unfocused and the bridge must keep answering.
- INV-4: external CLIs run through `ProcessRunner` (non-blocking, cancellable, with timeout);
  never `OS.execute` on the main thread.
- INV-5: secrets (PixelLab token, bridge token) live only in `user://ai_studio/`, never in the
  repo or in logs.

## Verification

- `godot --check-only -s` does not register autoloads or compile Pixelorama's classes, so it
  reports false errors for scripts that use them. Run Pixelorama headless
  (`--quit-after N`) and read the log instead.
- Run only one Pixelorama instance at a time: instances share the user dir and the bridge port.
- Do not kill Pixelorama with `pkill`: it leaves `.running` and `extensions/Monitoring.ini`
  behind, and the next launch flags the extension as faulty. On macOS quit with
  `osascript -e 'quit app "Godot"'`.
- macOS does not repaint a fully covered Godot window; bridge changes still apply.

## Conventions

- GDScript: never `await` a ternary of two coroutines; use `if/else` with `await` per branch.
- Reach Pixelorama autoloads through `ExtensionsApi` where possible.
- UI text goes through `tr()`; Spanish strings live in `core/Translations.gd`. Engine error
  messages stay in English because MCP clients receive them verbatim.
- The UI lives inside Pixelorama: use its controls and theme only.
- Document complex changes in `knowledge/`; track debt in `knowledge/TECH_DEBT.md`.
