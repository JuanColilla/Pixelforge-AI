# AI Studio architecture

## Flow

```
AI Studio panel ─┐                         ┌─ ComfyUIProvider ── HTTP ── ComfyUI :8188
                 ├─ Generator.generate() ──┼─ GrokProvider ───── ProcessRunner ── grok -p
MCP ─ Bridge ────┘        │                ├─ PixelLabProvider ─ HTTPS ── api.pixellab.ai/v2
                          │                └─ ClaudeProvider ─── ProcessRunner ── claude -p
                          ▼
          SubjectMask ── ProcessRunner ── tools/subject-mask (Vision, Neural Engine)
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
| `core/Settings.gd` | `user://ai_studio/settings.cfg`; resolves executables, the MCP folder and the `subject-mask` helper by following the dev symlink to the repo. |
| `core/CanvasOps.gd` | Canvas reads/writes, layers, frames, undo. The only write path; `insert_frames` / `insert_layers` add a batch as one undo action. |
| `core/PixelGrid.gd` | Text format: hex palette + base62 index rows (`.` = leave untouched). |
| `core/Pixelize.gd` | Fit, background removal (border flood fill or Vision mask, chosen per image), hard alpha, k-means / palette mapping. |
| `core/SubjectMask.gd` | Runs `subject-mask` on the full-resolution render and returns the cut-out with alpha. |
| `core/Generator.gd` | Normalizes requests, picks the engine, pixelizes, places results, variants. `run_pixellab` runs the PixelLab tools (reads the cel, crops the region, places the frames). |
| `core/Http.gd` | Awaitable `HTTPRequest`; decodes PNG/JPEG/WebP by signature. |
| `core/Translations.gd` | Spanish strings for `tr()`. |
| `providers/*.gd` | One file per engine; each exposes `generate()` and `cancel()`. |
| `providers/ProcessRunner.gd` | `/bin/sh -c exec …` with output to files, PID polling, kill on cancel/timeout. |
| `bridge/BridgeServer.gd` | Token-protected JSON-lines TCP server. |
| `ui/StudioPanel.gd` | Dock tab, built in code. |
| `tools/subject-mask/` | Swift package (macOS 14+): `VNGenerateForegroundInstanceMaskRequest` → PNG with the mask as alpha. Built by `scripts/setup.sh`. |

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

## Background removal

With "Remove background" on and a render without alpha of its own (otherwise `source_alpha`):

1. `Generator._generate_image` (once per variant) hands the render, at the engine's resolution
   (512 px for sprites up to 128 px, up to 1024 px), to `SubjectMask`. It saves it under
   `user://ai_studio/jobs/mask-*/` and runs `subject-mask source.png masked.png` (60 s
   timeout). The helper pins the request's `main` compute stage to the Neural Engine when
   Vision supports it there, and writes the source with the mask of all foreground instances
   as alpha, uncropped and at full resolution. Exit codes: `0` plus one JSON line (`device`,
   `instances`, `vision_ms`, `total_ms`), `2` no subject, `1` error, `64` usage.
   `fix_alpha_edges()` runs before downscaling: Vision clears the background to transparent
   black, and Lanczos would bleed it into the outline.
2. `Pixelize.non_flat_background_ratio` measures, at 128 px and skipping the pixel ring next to
   the subject, how much of what Vision calls background is **not** the dominant border color.
   - ≤ 0.15 (`VISION_MIN_NON_FLAT`): flat background → border flood fill, as before. It is
     exact and keeps subject areas that share the background color (a white chest on a white
     background), which Vision drops.
   - > 0.15: gradient or scenic background → the Vision mask is used.
3. If the helper is missing or fails, flood fill runs and the result carries
   `background_note`. Cancelling during the cut-out cancels the whole generation.

Each variant in the `generate` result has `background`: `flood_fill`, `vision`,
`source_alpha` or `none` (the top level repeats the first variant's).

Measured on an Apple M5 Max (macOS 27) with 1024² Z-Image Turbo renders. The ratio is measured
at 128 px, so it does not depend on the render size:

| Sample | Background | Non-flat ratio | Result |
|---|---|---|---|
| Sitting fox | flat white | 0.065 | `flood_fill` |
| Knight with sword | flat white + shadow | 0.004 | `flood_fill` |
| Wizard before a gradient disc | sunset gradient | 0.326 | `vision` |
| Deer in a clearing | forest and grass | 0.462 | `vision` |

| Device (`--device`) | Vision | Whole process (incl. PNG) |
|---|---|---|
| `ane` (default) | 136–157 ms | 155–176 ms |
| `auto` (Vision decides) | 131–143 ms | 148–160 ms |
| `gpu` | 194–279 ms | 229–315 ms (with ComfyUI busy on the GPU) |
| `cpu` | not supported for the `main` stage; falls back to `auto` | — |

At 512 px renders the helper takes 117–139 ms of Vision and 129–150 ms overall; the ratio and
the rest of `Pixelize` add 20–30 ms of GDScript. Bridge generations took 4.3–5.3 s per sprite,
so the cut-out is about 3% of the total. The first run in a session took 230 ms of Vision.

Comparison at 64×64 and 16 colors in
[assets/background-removal-comparison.png](assets/background-removal-comparison.png); columns:
source · flood fill · Vision only · what `Pixelize` picks.

## Known limitations

- On macOS, Pixelorama only repaints while its window is visible. To watch Claude draw, keep
  the window visible next to your chat.
- `dist/AIStudio.zip` has not been tested against an official Pixelorama build.
- Engine errors are shown in English.
- With the Vision mask, thin outlines can lose a pixel (the mask edge falls mid-outline). If
  that matters, dilate the mask in the helper (`generateScaledMaskForImage` +
  `CIMorphologyMaximum`).
- Flat backgrounds keep the flood-fill behavior, including a drop shadow under the feet.
- Vision decides what is foreground: prominent scenery (trees next to a deer) can stay in the
  subject as one instance. Far less background remains than with flood fill.
- On small renders Vision sometimes finds no subject (the fox at 512 px, exit `2`); flood fill
  runs and `background_note` says so.
