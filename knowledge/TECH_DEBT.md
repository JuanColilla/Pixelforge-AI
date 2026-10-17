# Technical debt

- PixelLab: only the missing-token error has been exercised; a real generation and the exact
  shape of a 202 response (`background_job_id`) are still unconfirmed.
- PixelLab UI is shown even when no token is configured; it should stay hidden until one is.
- `dist/AIStudio.zip` is untested in an official Pixelorama build. Packaged installs need the
  MCP folder set by hand in the settings.
- Grok: agent-loop overhead dominates the cost per image (~265k tokens). Restrict tools with
  `--tools` once the internal tool IDs are confirmed (`image_gen` plus the shell tool).
- Pixelize: background removal is a border flood fill with a fixed tolerance (0.12); it fails
  on gradient backgrounds.
- No automated GDScript tests (GUT or gdUnit). Verification today means running Pixelorama
  headless and talking to the bridge.
- `user://ai_studio/jobs/<id>/` keeps one folder per Grok/Claude run (with stdout) and is never
  pruned.
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
