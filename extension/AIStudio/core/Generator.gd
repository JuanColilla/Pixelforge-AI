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
const MAX_VARIANTS := 4
const PREVIEW_SIDE := 192
const PREVIEW_GAP := 4

const Pixelize := preload("Pixelize.gd")
const SubjectMask := preload("SubjectMask.gd")
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
var _subject_mask: RefCounted


func setup(settings_store: RefCounted, canvas_ops: RefCounted) -> void:
	settings = settings_store
	canvas = canvas_ops
	_providers = {
		"comfyui": ComfyUIProvider.new(settings, self),
		"pixellab": PixelLabProvider.new(settings, self),
		"grok": GrokProvider.new(settings, self),
		"claude": ClaudeProvider.new(settings, self),
	}
	_subject_mask = SubjectMask.new(settings, self)


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
		"variants": int(raw.get("variants", 1)),
		"preview": bool(raw.get("preview", false)),
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
	if request.variants < 1 or request.variants > MAX_VARIANTS:
		return {"error": "variants must be between 1 and %d" % MAX_VARIANTS}
	if request.variants > 1 and request.target == "current_cel":
		return {"error": "variants need target new_layer or new_frame"}
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
	_subject_mask.cancel()


## Generates [code]variants[/code] images with consecutive seeds. With new_layer, only the
## first variant stays visible; the others are hidden layers to compare and pick from.
func _run_image(request: Dictionary) -> Dictionary:
	var base_seed: int = request.seed if request.seed >= 0 else randi() % 1_000_000_000
	var placed: Array[Dictionary] = []
	var images: Array[Image] = []
	for index in request.variants:
		if request.variants > 1:
			status_changed.emit(
				tr("Generating with %s…") % tr(ENGINE_LABELS[request.engine])
				+ " (%d/%d)" % [index + 1, request.variants],
				true
			)
		var variant := request.duplicate()
		variant.seed = base_seed + index
		var generated := await _generate_image(variant)
		if generated.has("error"):
			if placed.is_empty():
				return generated
			return _summary(request, placed, images, "variant %d failed: %s" % [index + 1, generated.error])
		var suffix := "" if request.variants == 1 else " #%d" % (index + 1)
		var written := _place(generated.image, variant, suffix)
		if written.has("error"):
			return written if placed.is_empty() else _summary(request, placed, images, written.error)
		written["seed"] = variant.seed
		for key in ["background", "background_note"]:
			if generated.has(key):
				written[key] = generated[key]
		placed.append(written)
		images.append(generated.image)
	if request.target == "new_layer":
		for index in range(1, placed.size()):
			canvas.set_layer_visible(placed[index].layer, false)
		canvas.select_cel(placed[0].frame, placed[0].layer)
	return _summary(request, placed, images, "")


func _generate_image(request: Dictionary) -> Dictionary:
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
	if generated.has("error") or request.engine == "claude_pixels":
		return generated
	var image: Image = generated.image
	var options := {"colors": request.colors, "palette": request.palette}
	var result := {"background": "none"}
	if request.remove_background:
		if image.detect_alpha() != Image.ALPHA_NONE:
			result.background = "source_alpha"
		else:
			options["remove_background"] = true
			var lifted: Dictionary = await _subject_mask.lift(image)
			if lifted.has("cancelled"):
				return {"error": "cancelled"}
			if lifted.has("image"):
				options["subject"] = lifted.image
			else:
				result["background_note"] = lifted.error
	var pixelized := Pixelize.to_pixel_art(image, request.size, options)
	result["image"] = pixelized.image
	if options.has("remove_background"):
		result.background = pixelized.background
	return result


func _summary(request: Dictionary, placed: Array[Dictionary], images: Array[Image], warning: String) -> Dictionary:
	var result := placed[0].duplicate()
	result["engine"] = request.engine
	result["width"] = images[0].get_width()
	result["height"] = images[0].get_height()
	result["variants"] = placed
	if not warning.is_empty():
		result["warning"] = warning
	if request.preview:
		result["preview_png_base64"] = Marshalls.raw_to_base64(contact_sheet(images).save_png_to_buffer())
	return result


## Places the images side by side, scaled up with nearest-neighbor so a sprite is ~192 px.
static func contact_sheet(images: Array[Image]) -> Image:
	var size := images[0].get_size()
	var scale := maxi(1, PREVIEW_SIDE / maxi(size.x, size.y))
	var cell := size * scale
	var sheet := Image.create_empty(
		cell.x * images.size() + PREVIEW_GAP * (images.size() - 1), cell.y, false, Image.FORMAT_RGBA8
	)
	for index in images.size():
		var scaled := Image.new()
		scaled.copy_from(images[index])
		scaled.convert(Image.FORMAT_RGBA8)
		scaled.resize(cell.x, cell.y, Image.INTERPOLATE_NEAREST)
		sheet.blit_rect(scaled, Rect2i(Vector2i.ZERO, cell), Vector2i(index * (cell.x + PREVIEW_GAP), 0))
	return sheet


func _run_agent(request: Dictionary) -> Dictionary:
	if bridge_file.is_empty():
		return {"error": "Claude agent mode needs the MCP bridge enabled"}
	return await _providers.claude.run_agent(request, bridge_file)


func _place(image: Image, request: Dictionary, name_suffix: String) -> Dictionary:
	var frame: int = request.frame
	var layer: int = request.layer
	match request.target:
		"new_layer":
			var added: Dictionary = canvas.add_layer("AI: " + request.prompt.left(24) + name_suffix)
			layer = added.layer
		"new_frame":
			var added: Dictionary = canvas.add_frame(frame)
			frame = added.frame
	var written: Dictionary = canvas.write_cel(image, frame, layer)
	if written.has("error"):
		return written
	return written
