extends Node
## Runs a generation request end to end: engine → pixelize → place on the canvas.
## Modes: txt2img (any engine), img2img and inpaint (ComfyUI only; they start from the
## pixels of a cel instead of noise). Used by the panel and by the MCP bridge. Claude's agent
## mode may call back into image generation through the bridge while it runs, so the two
## kinds of work are tracked apart.

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
const MODES := ["txt2img", "img2img", "inpaint"]
const DEFAULT_STRENGTH := {"txt2img": 1.0, "img2img": 0.6, "inpaint": 1.0}
const MAX_EDIT_SIDE := 1024
## Source cels with more colors than this are not treated as a fixed palette.
const MAX_SOURCE_PALETTE := 64
const MAX_VARIANTS := 4
const PREVIEW_SIDE := 192
const PREVIEW_GAP := 4

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
	var mode := str(raw.get("mode", "txt2img"))
	var editing := mode != "txt2img"
	var request := {
		"mode": mode,
		"engine": str(raw.get("engine", "comfyui")),
		"prompt": str(raw.get("prompt", "")).strip_edges(),
		"size": Vector2i(int(raw.get("width", info.width)), int(raw.get("height", info.height))),
		"colors": clampi(int(raw.get("colors", 16)), 0, 62),
		"use_palette": bool(raw.get("use_palette", false)),
		"remove_background": raw.get("remove_background", null if editing else true),
		"target": str(raw.get("target", "current_cel" if editing else "new_layer")),
		"strength": clampf(float(raw.get("strength", DEFAULT_STRENGTH.get(mode, 1.0))), 0.05, 1.0),
		"keep_palette": bool(raw.get("keep_palette", editing)),
		"rect": _parse_rect(raw.get("rect")),
		"seed": int(raw.get("seed", -1)),
		"frame": int(raw.get("frame", -1)),
		"layer": int(raw.get("layer", -1)),
		"variants": int(raw.get("variants", 1)),
		"preview": bool(raw.get("preview", false)),
	}
	request["palette"] = canvas.palette_colors() if request.use_palette else PackedColorArray()
	if not mode in MODES:
		return {"error": "unknown mode '%s' (use %s)" % [mode, ", ".join(MODES)]}
	if editing and request.engine != "comfyui":
		return {"error": "%s only works with the comfyui engine" % mode}
	if request.remove_background != null:
		request.remove_background = bool(request.remove_background)
	if not request.engine in ENGINES:
		return {"error": "unknown engine '%s' (use %s)" % [request.engine, ", ".join(ENGINES)]}
	if not request.target in TARGETS:
		return {"error": "unknown target '%s' (use %s)" % [request.target, ", ".join(TARGETS)]}
	if request.prompt.is_empty():
		return {"error": "the prompt is empty"}
	if not editing and (request.size.x < 1 or request.size.y < 1 or request.size.x > 1024 or request.size.y > 1024):
		return {"error": "size must be between 1 and 1024"}
	if editing and request.variants != 1:
		return {"error": "variants are only available for txt2img"}
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


## Generates [code]variants[/code] images with consecutive seeds. With new_layer, only the
## first variant stays visible; the others are hidden layers to compare and pick from.
func _run_image(request: Dictionary) -> Dictionary:
	if request.mode != "txt2img":
		return await _run_edit(request)
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
	var image := Pixelize.to_pixel_art(
		generated.image,
		request.size,
		{
			"colors": request.colors,
			"palette": request.palette,
			"remove_background": request.remove_background,
		}
	)
	return {"image": image}


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


## img2img: the region (explicit rect, selection bounds or whole cel) is the init image.
## inpaint: the init image is the mask bounds plus context on every side (crop and stitch:
## the masked area gets more of the model's resolution and the prompt describes the crop)
## and only masked pixels may change. With a selection, only selected pixels are written
## back in both modes.
func _run_edit(request: Dictionary) -> Dictionary:
	var source: Dictionary
	if request.target == "current_cel":
		source = canvas.resolve_writable_cel(request.frame, request.layer)
	else:
		source = canvas.resolve_cel(request.frame, request.layer)
	if source.has("error"):
		return source
	var cel: Image = canvas.cel_image(source.frame, source.layer)
	var bounds := Rect2i(Vector2i.ZERO, cel.get_size())
	var mask: Image = canvas.selection_mask()
	if request.rect != null:
		mask = Image.create_empty(bounds.size.x, bounds.size.y, false, Image.FORMAT_LA8)
		mask.fill_rect(request.rect, Color.WHITE)
	var region := bounds
	if request.mode == "inpaint":
		if mask == null or mask.get_used_rect().size == Vector2i.ZERO:
			return {"error": "inpaint needs a selection or a rect inside the canvas"}
		var masked := mask.get_used_rect()
		region = masked.grow(maxi(masked.size.x, masked.size.y)).intersection(bounds)
	elif mask != null:
		region = mask.get_used_rect()
		if region.size == Vector2i.ZERO:
			return {"error": "the rect or selection is outside the canvas"}
	if region.size.x > MAX_EDIT_SIDE or region.size.y > MAX_EDIT_SIDE:
		return {"error": "%s works on areas up to %d px per side" % [request.mode, MAX_EDIT_SIDE]}

	var init := cel.get_region(region)
	if request.remove_background == null:
		request.remove_background = Pixelize.has_transparency(init)
	var noise_mask: Image = mask.get_region(region) if request.mode == "inpaint" else null
	var generated: Dictionary = await _providers.comfyui.edit(
		request, Pixelize.flatten(init, Color.WHITE), noise_mask
	)
	if generated.has("error"):
		return generated
	var palette: PackedColorArray = request.palette
	if palette.is_empty() and request.keep_palette:
		palette = Pixelize.opaque_colors(cel, MAX_SOURCE_PALETTE)
	var image := Pixelize.to_pixel_art(
		generated.image,
		region.size,
		{"colors": request.colors, "palette": palette, "remove_background": request.remove_background}
	)
	return _place_region(image, region.position, mask, request, source)


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


## Writes [param image] at [param origin], only where [param mask] is set (everywhere when
## null), into the cel chosen by the request target. One undo step.
func _place_region(
	image: Image, origin: Vector2i, mask: Image, request: Dictionary, source: Dictionary
) -> Dictionary:
	var frame: int = source.frame
	var layer: int = source.layer
	match request.target:
		"new_layer":
			var added: Dictionary = canvas.add_layer("AI: " + request.prompt.left(24))
			layer = added.layer
		"new_frame":
			var added: Dictionary = canvas.add_frame(frame)
			frame = added.frame
	var written: Dictionary = canvas.edit_cel(
		frame,
		layer,
		func(cel: Image) -> int:
			var count := 0
			for y in image.get_height():
				for x in image.get_width():
					var point := origin + Vector2i(x, y)
					if mask == null or mask.get_pixelv(point).a > 0.0:
						cel.set_pixelv(point, image.get_pixel(x, y))
						count += 1
			return count
	)
	if written.has("error"):
		return written
	written["engine"] = request.engine
	written["mode"] = request.mode
	written["strength"] = request.strength
	written["region"] = {"x": origin.x, "y": origin.y, "width": image.get_width(), "height": image.get_height()}
	return written


static func _parse_rect(value: Variant) -> Variant:
	if typeof(value) != TYPE_DICTIONARY:
		return null
	var rect := Rect2i(
		int(value.get("x", 0)), int(value.get("y", 0)), int(value.get("width", 0)), int(value.get("height", 0))
	)
	return rect if rect.size.x > 0 and rect.size.y > 0 else null
