extends Node
## Runs a generation request end to end: engine → pixelize → place on the canvas.
## Used by the panel and by the MCP bridge. Claude's agent mode may call back into image
## generation through the bridge while it runs, so the two kinds of work are tracked apart.

signal status_changed(text: String, busy: bool)

const ENGINE_LABELS := {
	"comfyui": "ComfyUI (local)",
	"grok": "Grok CLI",
	"pixellab": "PixelLab API",
	"claude_pixels": "Claude CLI: pixels",
	"claude_agent": "Claude CLI: agent",
}
const ENGINES := ["comfyui", "grok", "pixellab", "claude_pixels", "claude_agent"]
const TARGETS := ["new_layer", "current_cel", "new_frame"]

const Pixelize := preload("Pixelize.gd")
const ComfyUIProvider := preload("../providers/ComfyUIProvider.gd")
const PixelLabProvider := preload("../providers/PixelLabProvider.gd")
const GrokProvider := preload("../providers/GrokProvider.gd")
const ClaudeProvider := preload("../providers/ClaudeProvider.gd")

var settings: RefCounted
var canvas: RefCounted
var bridge_file := ""
var image_busy := false
var agent_busy := false

var _providers := {}


func setup(settings_store: RefCounted, canvas_ops: RefCounted) -> void:
	settings = settings_store
	canvas = canvas_ops
	_providers = {
		"comfyui": ComfyUIProvider.new(settings, self),
		"pixellab": PixelLabProvider.new(settings, self),
		"grok": GrokProvider.new(settings, self),
		"claude": ClaudeProvider.new(settings, self),
	}


## Fills defaults and validates a request coming from the panel or the bridge.
func normalize(raw: Dictionary) -> Dictionary:
	var info: Dictionary = canvas.project_info()
	var request := {
		"engine": str(raw.get("engine", "comfyui")),
		"prompt": str(raw.get("prompt", "")).strip_edges(),
		"size": Vector2i(int(raw.get("width", info.width)), int(raw.get("height", info.height))),
		"colors": clampi(int(raw.get("colors", 16)), 0, 62),
		"use_palette": bool(raw.get("use_palette", false)),
		"remove_background": bool(raw.get("remove_background", true)),
		"target": str(raw.get("target", "new_layer")),
		"seed": int(raw.get("seed", -1)),
		"frame": int(raw.get("frame", -1)),
		"layer": int(raw.get("layer", -1)),
	}
	request["palette"] = canvas.palette_colors() if request.use_palette else PackedColorArray()
	if not request.engine in ENGINES:
		return {"error": "unknown engine '%s' (use %s)" % [request.engine, ", ".join(ENGINES)]}
	if not request.target in TARGETS:
		return {"error": "unknown target '%s' (use %s)" % [request.target, ", ".join(TARGETS)]}
	if request.prompt.is_empty():
		return {"error": "the prompt is empty"}
	if request.size.x < 1 or request.size.y < 1 or request.size.x > 1024 or request.size.y > 1024:
		return {"error": "size must be between 1 and 1024"}
	return request


func generate(raw: Dictionary) -> Dictionary:
	var request := normalize(raw)
	if request.has("error"):
		return request
	var is_agent: bool = request.engine == "claude_agent"
	if (is_agent and agent_busy) or (not is_agent and image_busy):
		return {"error": "a %s is already running" % ("Claude agent" if is_agent else "generation")}
	if is_agent:
		agent_busy = true
	else:
		image_busy = true
	status_changed.emit(tr("Generating with %s…") % tr(ENGINE_LABELS[request.engine]), true)
	var started := Time.get_ticks_msec()
	var result: Dictionary
	if is_agent:
		result = await _run_agent(request)
		agent_busy = false
	else:
		result = await _run_image(request)
		image_busy = false
	result["seconds"] = snappedf((Time.get_ticks_msec() - started) / 1000.0, 0.1)
	if result.has("error"):
		status_changed.emit(tr("Error: %s") % result.error, is_busy())
	else:
		status_changed.emit(tr("Done in %s s") % result.seconds, is_busy())
	return result


func is_busy() -> bool:
	return image_busy or agent_busy


func cancel() -> void:
	for provider: RefCounted in _providers.values():
		provider.cancel()


func _run_image(request: Dictionary) -> Dictionary:
	var generated: Dictionary
	match request.engine:
		"comfyui":
			generated = await _providers.comfyui.generate(request)
		"pixellab":
			generated = await _providers.pixellab.generate(request)
		"grok":
			generated = await _providers.grok.generate(request)
		"claude_pixels":
			generated = await _providers.claude.generate_pixels(request)
	if generated.has("error"):
		return generated
	var image: Image = generated.image
	if request.engine != "claude_pixels":
		image = Pixelize.to_pixel_art(
			image,
			request.size,
			{
				"colors": request.colors,
				"palette": request.palette,
				"remove_background": request.remove_background,
			}
		)
	return _place(image, request)


func _run_agent(request: Dictionary) -> Dictionary:
	if bridge_file.is_empty():
		return {"error": "Claude agent mode needs the MCP bridge enabled"}
	return await _providers.claude.run_agent(request, bridge_file)


func _place(image: Image, request: Dictionary) -> Dictionary:
	var frame: int = request.frame
	var layer: int = request.layer
	match request.target:
		"new_layer":
			var added: Dictionary = canvas.add_layer("AI: " + request.prompt.left(24))
			layer = added.layer
		"new_frame":
			var added: Dictionary = canvas.add_frame(frame)
			frame = added.frame
	var written: Dictionary = canvas.write_cel(image, frame, layer)
	if written.has("error"):
		return written
	written["engine"] = request.engine
	written["width"] = image.get_width()
	written["height"] = image.get_height()
	return written
