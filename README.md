# Pixelforge AI

An AI-assisted pixel-art editor. Pixelforge AI runs [Pixelorama](https://github.com/Orama-Interactive/Pixelorama)
(the open-source pixel-art editor built with Godot) with **AI Studio**, an extension that:

- generates sprites from a prompt with the engine you choose, pixelizes them to your canvas and
  places them on a new layer, cel or frame, with undo;
- lets AI assistants (Claude Code, Claude Desktop, Grok CLI or any MCP client) see and draw on
  the canvas through a local MCP server.

Nothing runs in the cloud unless you pick a remote engine. The default engine is a local
ComfyUI.

## Engines

| Engine | Where it runs | What you need |
|---|---|---|
| ComfyUI (default) | Your machine | ComfyUI with Z-Image Turbo (see below). Free. |
| Grok CLI | xAI | [Grok CLI](https://x.ai) signed in. Uses its `image_gen` tool. |
| PixelLab API | pixellab.ai | Your own PixelLab API token. Native pixel-art models. |
| Claude CLI: pixels | Anthropic | [Claude Code](https://claude.com/claude-code). Claude draws small sprites (≤128 px) pixel by pixel. |
| Claude CLI: agent | Anthropic | Claude Code. Claude edits the canvas with the MCP tools to fulfil your request. |

Generated images are fitted to the canvas, the background is removed and colors are quantized
to N colors or to the active palette. Flat backgrounds are flood-filled from the border; for
gradient or scenic backgrounds a small Swift helper uses Apple's Vision subject lifting on the
Neural Engine (macOS 14+). You can generate up to four variants with consecutive
seeds; extra variants go to hidden layers so you can compare and keep one.

With a PixelLab token set, the tab also offers four tools that start from the sprite already on
the canvas: 8 directional rotations, a single rotation, a text-driven animation and in-between
frames for two keyframes. Results land as new frames (or layers) in one undo step. Without a
token, none of the PixelLab options appear.

## Requirements

- macOS (tested on Apple Silicon). Linux should work but is untested.
- [Godot 4.7.x](https://godotengine.org) (`brew install --cask godot` on macOS)
- [uv](https://docs.astral.sh/uv/) and git
- Optional, per engine: ComfyUI, Grok CLI, Claude Code, a PixelLab API token
- Optional: Xcode or the Swift toolchain, so `scripts/setup.sh` can build the Vision
  background-removal helper (without it, only flat backgrounds are removed)

## Quick start

```bash
git clone https://github.com/JuanColilla/Pixelforge-AI.git
cd Pixelforge-AI
scripts/setup.sh   # clones Pixelorama v1.2.3, patches it, installs the MCP server
scripts/run.sh     # opens Pixelorama with the AI Studio tab
```

Open the **AI Studio** tab (next to Tools), write a prompt, pick an engine and press
**Generate**. Engine paths, the ComfyUI URL and the PixelLab token are under **Settings** in
the same tab. Settings are stored in Pixelorama's user folder, never in the repository.

### ComfyUI models

The default graph uses Z-Image Turbo. Put these files in your ComfyUI `models/` folders:

| Folder | File |
|---|---|
| `diffusion_models/` | `z_image_turbo_bf16.safetensors` |
| `text_encoders/` | `qwen_3_4b.safetensors` |
| `vae/` | `ae.safetensors` |

They are published at [Comfy-Org/z_image_turbo](https://huggingface.co/Comfy-Org/z_image_turbo).
The default URL is `http://127.0.0.1:8188`. You can also point AI Studio at your own
API-format workflow that uses the placeholders `{{prompt}}`, `{{width}}`, `{{height}}` and
`{{seed}}`.

On an Apple M5 Max a 64 px sprite takes about 3 s (rendered at 512 px). Small canvases are
rendered at 512 px, medium ones at 768 px and large ones at 1024 px.

## Drawing with an AI assistant (MCP)

While Pixelorama is open, AI Studio runs a local bridge (127.0.0.1 only, random token per
session). The `pixelorama-mcp` server in `mcp/` exposes it to MCP clients.

Register it with Claude Code and/or Grok CLI:

```bash
scripts/register-mcp.sh          # both, if installed
scripts/register-mcp.sh claude   # only Claude Code
```

For Claude Desktop, add this to `claude_desktop_config.json` (Settings → Developer → Edit
Config), using absolute paths, then restart Claude Desktop:

```json
{
  "mcpServers": {
    "pixelorama": {
      "command": "/absolute/path/to/uv",
      "args": ["run", "--quiet", "--directory", "/absolute/path/to/Pixelforge-AI/mcp", "pixelorama-mcp"]
    }
  }
}
```

Tools: `get_project_info`, `view_canvas`, `read_pixels`, `paint_grid`, `draw_pixels`,
`draw_line`, `draw_rect`, `fill`, `clear_cel`, `batch` (many ops in one call and one undo
step), `add_layer`, `add_frame`, `select_cel`, `new_project`, `undo`, `redo` and
`generate_image` (returns a preview image of every variant). With a PixelLab token:
`pixellab_rotations`, `pixellab_rotate`, `pixellab_animate`, `pixellab_interpolate` and
`pixellab_balance`.

Tip: keep the Pixelorama window visible next to your chat. macOS does not repaint a fully
covered window, although the changes still apply.

## Using a stock Pixelorama

`scripts/package.sh` builds `dist/AIStudio.zip`, which can be installed in an official
Pixelorama 1.2.x build from Preferences → Extensions. In that mode, set the
`pixelorama-mcp folder` in AI Studio settings to use Claude's agent mode, and the
`Subject mask helper path` for Vision background removal. This path is not
tested yet.

## Privacy and security

- The bridge listens on `127.0.0.1` only and requires a random token stored with owner-only
  permissions in Pixelorama's user folder.
- ComfyUI runs locally. The other engines send your prompt (and, for some tools, your sprite)
  to their provider under that provider's terms.
- Your PixelLab token is read from `PIXELLAB_API_TOKEN` or the settings file in your user
  folder, and is only sent to `api.pixellab.ai`.

## Project layout

```
extension/AIStudio/   GDScript extension (UI, engines, pixelization, bridge)
mcp/                  pixelorama-mcp server (Python, MCP SDK 2.x)
patches/              the one-line hook that loads the extension in Pixelorama
scripts/              setup, run, package, MCP registration and the PixelLab test run
tests/pixellab/       mock PixelLab API and bridge tests used by scripts/test-pixellab.sh
tools/subject-mask/   Swift helper for Vision background removal (macOS 14+)
knowledge/            architecture notes and technical debt
```

Contributors and coding agents: start with [AGENTS.md](AGENTS.md) and
[knowledge/architecture.md](knowledge/architecture.md).

## License

Pixelforge AI is released under the [MIT License](LICENSE), the same license as Pixelorama.
Third-party components and their licenses are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Pixelforge AI is an independent project. It is not affiliated with or endorsed by Orama
Interactive, the Godot Foundation, PixelLab, xAI, Anthropic or Comfy Org. Product names are
trademarks of their respective owners.
