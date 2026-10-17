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
| `core/CanvasOps.gd` | Canvas reads/writes, layers, frames, undo. The only write path. |
| `core/PixelGrid.gd` | Text format: hex palette + base62 index rows (`.` = leave untouched). |
| `core/Pixelize.gd` | Fit, border flood-fill background removal, hard alpha, k-means / palette mapping. |
| `core/Generator.gd` | Normalizes requests, picks the engine, pixelizes, places results, variants. |
| `core/Http.gd` | Awaitable `HTTPRequest` (text or binary body, multipart); decodes PNG/JPEG/WebP by signature. |
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
`select_cel`, `new_project`, `undo`, `redo`, `select_rect`, `clear_selection`, `generate`,
`edit_image`, `inpaint`, `cancel`.

Every drawing operation goes through `CanvasOps.apply_ops`: each op (`pixels`, `line`, `rect`,
`fill`, `grid`, `clear`) is validated and compiled to a `Callable`, and the batch is applied to
a copy of the cel that is written once. An invalid op aborts the batch before anything is
drawn. `batch` exposes this to MCP: N operations in one call and one undo step.

`generate` accepts `variants` (1–4, consecutive seeds) and `preview` (returns a PNG contact
sheet). With `new_layer`, the first variant stays visible and the rest go to hidden layers.
Its `mode` also accepts `img2img` and `inpaint` (no variants). In `edit_image`/`inpaint`,
`x/y/width/height` select the region or the mask, not an output size.

`frame`/`layer` = -1 means the current cel; in `view_canvas`, `layer` = -1 blends all visible
layers.

## Engines

- **ComfyUI**: Z-Image Turbo graph in API format (8 steps, `res_multistep`, cfg 1). The render
  area follows the target: 512² up to 128 px, 768² up to 256 px, 1024² above. Benchmark on an
  Apple M5 Max: 13.4 s at 1024 px vs 3.3 s at 512 px; a batch of 4 at 512 px takes 15.2 s, so
  batching does not pay off on MPS. Output uses `PreviewImage` (ComfyUI's temp folder). The
  first generation after ComfyUI starts adds model loading (~60 s). A custom API-format
  workflow can replace the graph using `{{prompt}}`, `{{width}}`, `{{height}}` and `{{seed}}`.
- **Grok CLI**: `grok -p … --always-approve --output-format json --max-turns 8`, told to save
  the PNG in the job folder. About 30 s and USD 0.08 per image, mostly agent-loop overhead.
- **PixelLab**: `POST /v2/create-image-pixflux` (16–400 px, native pixel art); supports
  `color_image` to force a palette and polls `/background-jobs` on 202. Token from
  `PIXELLAB_API_TOKEN` or the settings.
- **Claude, pixels**: `--json-schema` returning palette + base62 rows, up to 128×128. A 16×16
  sprite takes about 17 s with `sonnet`.
- **Claude, agent**: temporary `--mcp-config` + `--allowedTools mcp__pixelorama`.

## Edit modes (img2img and inpaint)

Local, credit-free counterparts of hosted "edit image", "init image" and "inpainting" tools.
ComfyUI only, always with the built-in Z-Image graph (a custom workflow returns an error).

1. **Source**: the requested cel (`frame`/`layer`, -1 = current). The img2img region is the
   explicit rect, else the selection's bounds, else the whole cel. The inpaint mask is the
   explicit rect or the selection (`CanvasOps.selection_mask`, built with
   `Project.can_pixel_get_drawn`, so it honors `selection_offset` and tile mode). Inpaint crops
   the mask bounds plus the mask's own size of context on every side ("crop and stitch"): with
   the whole canvas as context the model painted background into small masks.
2. **Init image**: transparency is flattened onto white (VAEEncode ignores alpha), then scaled
   with nearest-neighbor by an integer `k = floor(1024 / longest side)`, anchored top-left on a
   canvas padded to multiples of 16 with white (the mask pads with black). Each canvas pixel is
   an exact k×k block; the result is cropped to `k·W × k·H` before pixelizing, so
   `Pixelize.fit` lands back on `W×H` without shifting a row. Edits keep 1024 px even for small
   sprites because the strength curve was calibrated at that scale.
3. **Upload**: multipart `POST /upload/image` with `type=temp` (keeps ComfyUI's `input/` clean);
   `LoadImage` / `LoadImageMask` (red channel) get the name as `"<file> [temp]"`.
4. **Graph**: `LoadImage → VAEEncode → [SetLatentNoiseMask] → SamplerCustom(ManualSigmas) →
   VAEDecode → PreviewImage`; with a mask, `DifferentialDiffusion` wraps the model.
5. **Strength**: KSampler's `denoise` is not used. With 8 steps it only has discrete start
   points (`int(8/denoise)` total steps): 0.9 already equals 1.0 and 0.88 starts at σ≈0.96,
   which Z-Image Turbo still treats as "keep the colors". `edit_sigmas` builds the shifted
   (shift 3) "simple" schedule starting at σ₀ = 1 − 0.15·(1 − strength)^1.6: 0.3 refines
   details, 0.6 restyles, 0.85 repaints colors keeping the shapes, 1 ignores the original.
   Calibrated on a 64×64 sprite (σ₀ 0.75 ≈ unchanged; colors change from σ₀ ≈ 0.98 up).
6. **Back to pixels**: `Pixelize.to_pixel_art` to the region size. Palette: the project's with
   `use_palette`, else the cel's own colors with `keep_palette` (default in edit modes, used
   when the cel has ≤ 64 colors), else k-means with `colors`. An unset `remove_background`
   means "the source has transparency".
7. **Write**: `_place_region` copies only masked pixels (or selected pixels in img2img) with one
   `CanvasOps.edit_cel`, so it is one undo step. Default target `current_cel`;
   `new_layer`/`new_frame` put the result in a new cel at the same position.

Measured on an Apple M5 Max with a 64×64 canvas (renders at 1024²): 12–20 s per edit, warm.

## Known limitations

- On macOS, Pixelorama only repaints while its window is visible. To watch Claude draw, keep
  the window visible next to your chat.
- `dist/AIStudio.zip` has not been tested against an official Pixelorama build.
- Engine errors are shown in English.
- Edit modes read a single cel: the model does not see other layers as context.
- The strength curve is calibrated for Z-Image Turbo; another model configured for ComfyUI may
  need other constants (`STRENGTH_KEEP`, `STRENGTH_EXPONENT`).
