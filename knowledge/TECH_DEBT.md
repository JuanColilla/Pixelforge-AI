# Technical debt

- PixelLab: only the missing-token error has been exercised; a real generation and the exact
  shape of a 202 response (`background_job_id`) are still unconfirmed.
- PixelLab UI is shown even when no token is configured; it should stay hidden until one is.
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
