# Technical debt

- PixelLab: no tool has run with a real token yet (pixflux, rotations, rotate, animate,
  interpolate); they are tested against a mock that validates requests with the public OpenAPI
  schema (`scripts/test-pixellab.sh`). Still to confirm with the real API: the order and shape
  of the 8 images from `generate-8-rotations-v3` (list or map by direction), whether
  `animate-with-text-v3` returns the input frame, and where `interpolation-v2` puts its frames
  and whether they include the keyframes.
- PixelLab publishes no up-front price for rotations, rotate, animate or interpolate
  (`/pro-flash/cost` only covers the Pro Flash family). The balance is shown before a run and
  the billed `usage` after it.
- `dist/AIStudio.zip` is untested in an official Pixelorama build. Packaged installs need the
  MCP folder set by hand in the settings.
- Grok: agent-loop overhead dominates the cost per image (~265k tokens). Restrict tools with
  `--tools` once the internal tool IDs are confirmed (`image_gen` plus the shell tool).
- Background removal: the `VISION_MIN_NON_FLAT` threshold (0.15) comes from four samples;
  revisit it if noisy flat backgrounds or soft gradients land on the wrong side.
- `subject-mask` only resolves in development (dev symlink to the repo); with
  `dist/AIStudio.zip` set its path by hand or flood fill is used.
- No automated GDScript tests (GUT or gdUnit). Verification today means running Pixelorama
  headless and talking to the bridge.
- `user://ai_studio/jobs/<id>/` keeps one folder per Grok/Claude/cut-out run (with stdout;
  cut-outs hold two renders as PNG) and is never pruned.
- `scripts/register-mcp.sh` does not cover Claude Desktop: its config is user-curated JSON and
  is edited by hand (see README).
- Variants with `new_frame` are inserted after the current frame, so they end up in reverse
  order.
- Pixelorama on native Metal (`--rendering-method mobile --rendering-driver metal`) starts
  without errors on Godot 4.7; effect shaders and large-canvas performance still need a visual
  comparison before switching the default renderer.
- `CanvasOps.selection_mask` calls `can_pixel_get_drawn` for every canvas pixel on the main
  thread: instant up to 256², noticeable at 1024², a stall at 4096². Shortcut: copy
  `selection_map` when `selection_offset` is zero, the sizes match and tile mode is off.
- Edit modes: the strength curve and the inpaint context crop were calibrated on a single 64×64
  sprite; large opaque scenes and tiles are untested.
