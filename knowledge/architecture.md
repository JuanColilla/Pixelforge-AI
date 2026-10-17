# AI Studio architecture

## Flow

```
AI Studio panel ─┐                         ┌─ ComfyUIProvider ── HTTP ── ComfyUI :8188
                 ├─ Generator.generate() ──┼─ GrokProvider ───── ProcessRunner ── grok -p
MCP ─ Bridge ────┘        │                ├─ PixelLabProvider ─ HTTPS ── api.pixellab.ai/v2
                          │                └─ ClaudeProvider ─── ProcessRunner ── claude -p
                          ▼
                   Pixelize.to_pixel_art ──► CanvasOps.write_cel ──► set_pixelcel_image (undo)
```

Claude's agent mode closes the loop: `claude -p --mcp-config` launches `pixelorama-mcp`, which
talks to the bridge and draws with the same `CanvasOps`. That is why `Generator` tracks
`agent_busy` apart from `image_busy`: a running agent may request image generations.

## Files

| File | Responsibility |
|---|---|
| `Main.gd` | Wires everything, registers the translation and the dock tab; tears it all down when disabled. |
| `core/Settings.gd` | `user://ai_studio/settings.cfg`; resolves executables and the MCP folder by following the dev symlink. |
| `core/CanvasOps.gd` | Canvas reads/writes, layers, frames, undo. The only write path; `insert_frames` / `insert_layers` add a batch as one undo action. |
| `core/PixelGrid.gd` | Text format: hex palette + base62 index rows (`.` = leave untouched). |
| `core/Pixelize.gd` | Fit, border flood-fill background removal, hard alpha, k-means / palette mapping. |
| `core/Generator.gd` | Normalizes requests, picks the engine, pixelizes, places results, variants. `run_pixellab` runs the PixelLab tools (reads the cel, crops the region, places the frames). |
| `core/Http.gd` | Awaitable `HTTPRequest`; decodes PNG/JPEG/WebP by signature. |
| `core/Translations.gd` | Spanish strings for `tr()`. |
| `providers/*.gd` | One file per engine; each exposes `generate()` and `cancel()`. |
| `providers/ProcessRunner.gd` | `/bin/sh -c exec …` with output to files, PID polling, kill on cancel/timeout. |
| `bridge/BridgeServer.gd` | Token-protected JSON-lines TCP server. |
| `ui/StudioPanel.gd` | Dock tab, built in code. |

## Bridge protocol

One JSON line per request and per response:

```json
{"id": 1, "token": "<bridge.json>", "method": "paint_grid", "params": {"x": 0, "y": 0, "palette": ["#00000000", "#ffcc00"], "rows": ["0110"]}}
{"id": 1, "result": {"frame": 0, "layer": 1, "pixels": 2}}
```

Methods: `ping`, `get_project_info`, `view_canvas`, `read_pixels`, `draw_pixels`, `draw_line`,
`draw_rect`, `fill`, `paint_grid`, `clear_cel`, `batch`, `set_image`, `add_layer`, `add_frame`,
`select_cel`, `new_project`, `undo`, `redo`, `generate`, `pixellab_tool`, `pixellab_balance`,
`cancel`.

Every drawing operation goes through `CanvasOps.apply_ops`: each op (`pixels`, `line`, `rect`,
`fill`, `grid`, `clear`) is validated and compiled to a `Callable`, and the batch is applied to
a copy of the cel that is written once. An invalid op aborts the batch before anything is
drawn. `batch` exposes this to MCP: N operations in one call and one undo step.

`generate` accepts `variants` (1–4, consecutive seeds) and `preview` (returns a PNG contact
sheet). With `new_layer`, the first variant stays visible and the rest go to hidden layers.

`frame`/`layer` = -1 means the current cel; in `view_canvas`, `layer` = -1 blends all visible
layers.

`pixellab_tool` takes `tool` (`rotations`, `rotate`, `animate`, `interpolate`); with `dry_run`
it returns the API request and the balance without spending credits. Without a PixelLab token
both PixelLab methods fail at once, with no network request.

## Engines

- **ComfyUI**: Z-Image Turbo graph in API format (8 steps, `res_multistep`, cfg 1). The render
  area follows the target: 512² up to 128 px, 768² up to 256 px, 1024² above. Benchmark on an
  Apple M5 Max: 13.4 s at 1024 px vs 3.3 s at 512 px; a batch of 4 at 512 px takes 15.2 s, so
  batching does not pay off on MPS. Output uses `PreviewImage` (ComfyUI's temp folder). The
  first generation after ComfyUI starts adds model loading (~60 s). A custom API-format
  workflow can replace the graph using `{{prompt}}`, `{{width}}`, `{{height}}` and `{{seed}}`.
- **Grok CLI**: `grok -p … --always-approve --output-format json --max-turns 8`, told to save
  the PNG in the job folder. About 30 s and USD 0.08 per image, mostly agent-loop overhead.
- **PixelLab**: `POST /v2/create-image-pixflux` (16–400 px, native pixel art) for text to
  image; supports `color_image` to force a palette. Four more tools start from the sprite on
  the canvas: 8 rotations, rotate, animate with text and interpolate (see
  [pixellab-api.md](pixellab-api.md)). Token from `PIXELLAB_API_TOKEN` or the settings; without
  one, PixelLab is hidden from the panel. Not yet run with a real token.
- **Claude, pixels**: `--json-schema` returning palette + base62 rows, up to 128×128. A 16×16
  sprite takes about 17 s with `sonnet`.
- **Claude, agent**: temporary `--mcp-config` + `--allowedTools mcp__pixelorama`.

## Known limitations

- On macOS, Pixelorama only repaints while its window is visible. To watch Claude draw, keep
  the window visible next to your chat.
- `dist/AIStudio.zip` has not been tested against an official Pixelorama build.
- Engine errors are shown in English.
