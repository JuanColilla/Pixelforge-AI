extends RefCounted
## Local generation through a running ComfyUI server (Comfy Desktop or comfy-cli).
## Default graph: Z-Image Turbo. A custom API-format workflow can replace it for text to
## image; it may use the placeholders {{prompt}}, {{width}}, {{height}} and {{seed}}.
## Edit modes (img2img, inpaint) always use the built-in graph: the init image and mask are
## uploaded to ComfyUI's temp folder, encoded with the VAE and partially denoised.

const Http := preload("../core/Http.gd")
const POLL_INTERVAL_SEC := 1.0
## Longest side of the upscaled init image; region pixels become exact k×k blocks.
const EDIT_TARGET_SIDE := 1024
## Latent and patch sizes of Z-Image need sides in multiples of 16.
const EDIT_SIZE_STEP := 16
const UPLOAD_TYPE := "temp"
## ModelSamplingAuraFlow shift used by the Z-Image graph.
const SHIFT := 3.0
## Signal kept at strength 0 and the curve exponent: σ₀ = 1 − KEEP·(1 − strength)^EXPONENT.
## Calibrated on Z-Image Turbo: colors only start to change above σ₀ ≈ 0.98.
const STRENGTH_KEEP := 0.15
const STRENGTH_EXPONENT := 1.6

var settings: RefCounted
var host: Node
var _base_url := ""
var _prompt_id := ""
var _cancelled := false


func _init(settings_store: RefCounted, host_node: Node) -> void:
	settings = settings_store
	host = host_node


func generate(request: Dictionary) -> Dictionary:
	_begin()
	var generation_size := generation_size_for(request.size)
	var workflow: Variant = _build_workflow(styled_prompt(request), generation_size, _seed(request))
	if workflow is String:
		return {"error": workflow}
	return await _run_workflow(workflow)


## img2img (mask == null) or inpaint. [param init] is the region at canvas resolution with
## transparency already flattened; [param mask] is white where pixels may change. Returns
## the result cropped to the upscaled region, so each region pixel maps to one k×k block.
func edit(request: Dictionary, init: Image, mask: Image) -> Dictionary:
	_begin()
	if not str(settings.get_value("comfy_workflow_path")).strip_edges().is_empty():
		return {"error": "edit modes use the built-in Z-Image graph; clear the custom workflow setting"}
	var scale := edit_scale_for(init.get_size())
	var scaled_size := init.get_size() * scale
	var canvas_size := Vector2i(
		ceili(scaled_size.x / float(EDIT_SIZE_STEP)) * EDIT_SIZE_STEP,
		ceili(scaled_size.y / float(EDIT_SIZE_STEP)) * EDIT_SIZE_STEP
	)
	var job := "ai_studio_%d_%d" % [Time.get_ticks_msec(), randi() % 100000]
	var init_name: Variant = await _upload(
		_upscaled(init, scale, canvas_size, Color.WHITE), job + "_init.png"
	)
	if init_name is Dictionary:
		return init_name
	var mask_name: Variant = null
	if mask != null:
		mask_name = await _upload(_upscaled(mask, scale, canvas_size, Color.BLACK), job + "_mask.png")
		if mask_name is Dictionary:
			return mask_name
	var workflow := _z_image_turbo(styled_prompt(request), canvas_size, _seed(request))
	_add_edit_nodes(workflow, init_name, mask_name, float(request.strength))
	var result := await _run_workflow(workflow)
	if result.has("error"):
		return result
	var image: Image = result.image
	if image.get_size() != canvas_size:
		return {"error": "ComfyUI returned %s instead of %s" % [image.get_size(), canvas_size]}
	return {"image": image.get_region(Rect2i(Vector2i.ZERO, scaled_size))}


func cancel() -> void:
	_cancelled = true
	if not _prompt_id.is_empty():
		Http.request(host, _base_url + "/interrupt", HTTPClient.METHOD_POST)


## Integer upscale so the longest side reaches about EDIT_TARGET_SIDE.
static func edit_scale_for(region: Vector2i) -> int:
	return maxi(1, floori(float(EDIT_TARGET_SIDE) / maxi(region.x, region.y)))


static func styled_prompt(request: Dictionary) -> String:
	var prompt := (
		"pixel art, %s, clean pixel art sprite, flat colors, limited palette, crisp hard edges, no anti-aliasing"
		% request.prompt
	)
	if request.get("mode", "") == "inpaint":
		prompt += ", seamlessly matching the surrounding artwork"
	elif request.remove_background:
		prompt += ", single subject centered, isolated on a plain flat white background"
	return prompt


## Generation area scales with the target: a 64 px sprite gains nothing from a megapixel
## render, and 512 px is about 4x faster than 1024 px (3.3 s vs 13.4 s, M5 Max). Keeps the
## target's aspect ratio, in multiples of 64.
static func generation_size_for(target: Vector2i) -> Vector2i:
	var longest := maxi(target.x, target.y)
	var side := 512.0 if longest <= 128 else (768.0 if longest <= 256 else 1024.0)
	var aspect := float(target.x) / float(target.y)
	var width := sqrt(side * side * aspect)
	return Vector2i(maxi(256, snappedi(width, 64)), maxi(256, snappedi(width / aspect, 64)))


func _build_workflow(prompt: String, size: Vector2i, noise_seed: int) -> Variant:
	var custom_path := str(settings.get_value("comfy_workflow_path")).strip_edges()
	if custom_path.is_empty():
		return _z_image_turbo(prompt, size, noise_seed)
	if not FileAccess.file_exists(custom_path):
		return "custom workflow not found: %s" % custom_path
	var text := FileAccess.get_file_as_string(custom_path)
	text = text.replace('"{{prompt}}"', JSON.stringify(prompt))
	for key: String in ["width", "height", "seed"]:
		var value := str({"width": size.x, "height": size.y, "seed": noise_seed}[key])
		text = text.replace('"{{%s}}"' % key, value).replace("{{%s}}" % key, value)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return "custom workflow is not valid API-format JSON: %s" % custom_path
	return parsed


func _z_image_turbo(prompt: String, size: Vector2i, noise_seed: int) -> Dictionary:
	return {
		"unet": {
			"class_type": "UNETLoader",
			"inputs": {"unet_name": settings.get_value("comfy_unet"), "weight_dtype": "default"},
		},
		"clip": {
			"class_type": "CLIPLoader",
			"inputs":
			{"clip_name": settings.get_value("comfy_clip"), "type": "lumina2", "device": "default"},
		},
		"vae": {"class_type": "VAELoader", "inputs": {"vae_name": settings.get_value("comfy_vae")}},
		"sampling": {
			"class_type": "ModelSamplingAuraFlow", "inputs": {"model": ["unet", 0], "shift": SHIFT}
		},
		"positive": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["clip", 0]}},
		"negative": {"class_type": "ConditioningZeroOut", "inputs": {"conditioning": ["positive", 0]}},
		"latent": {
			"class_type": "EmptySD3LatentImage",
			"inputs": {"width": size.x, "height": size.y, "batch_size": 1},
		},
		"sampler": {
			"class_type": "KSampler",
			"inputs":
			{
				"seed": noise_seed,
				"steps": int(settings.get_value("comfy_steps")),
				"cfg": 1.0,
				"sampler_name": "res_multistep",
				"scheduler": "simple",
				"denoise": 1.0,
				"model": ["sampling", 0],
				"positive": ["positive", 0],
				"negative": ["negative", 0],
				"latent_image": ["latent", 0],
			},
		},
		"decode": {"class_type": "VAEDecode", "inputs": {"samples": ["sampler", 0], "vae": ["vae", 0]}},
		# PreviewImage writes to ComfyUI's temp folder, so the user's output folder stays clean.
		"preview": {"class_type": "PreviewImage", "inputs": {"images": ["decode", 0]}},
	}


func _begin() -> void:
	_cancelled = false
	_prompt_id = ""
	_base_url = str(settings.get_value("comfy_url")).strip_edges().trim_suffix("/")


func _seed(request: Dictionary) -> int:
	return request.seed if request.seed >= 0 else randi()


func _run_workflow(workflow: Dictionary) -> Dictionary:
	if _cancelled:
		return {"error": "cancelled"}
	var submit := await Http.request(
		host,
		_base_url + "/prompt",
		HTTPClient.METHOD_POST,
		["Content-Type: application/json"],
		JSON.stringify({"prompt": workflow, "client_id": "pixelorama-ai-studio"})
	)
	if submit.has("error"):
		return {"error": "ComfyUI is not reachable at %s (%s)" % [_base_url, submit.error]}
	if submit.code != 200:
		return {"error": "ComfyUI rejected the workflow (HTTP %d): %s" % [submit.code, Http.text(submit)]}
	var submitted: Variant = Http.json(submit)
	if typeof(submitted) != TYPE_DICTIONARY or not submitted.has("prompt_id"):
		return {"error": "unexpected ComfyUI response: %s" % Http.text(submit)}
	_prompt_id = submitted.prompt_id

	var deadline := Time.get_ticks_msec() + int(settings.get_value("generation_timeout_sec")) * 1000
	while true:
		if _cancelled:
			return {"error": "cancelled"}
		if Time.get_ticks_msec() > deadline:
			return {"error": "ComfyUI timed out"}
		await host.get_tree().create_timer(POLL_INTERVAL_SEC).timeout
		var history := await Http.request(host, _base_url + "/history/" + _prompt_id)
		if history.has("error") or history.code != 200:
			continue
		var data: Variant = Http.json(history)
		if typeof(data) != TYPE_DICTIONARY or not data.has(_prompt_id):
			continue
		var entry: Dictionary = data[_prompt_id]
		var status: Dictionary = entry.get("status", {})
		if status.get("status_str", "") == "error":
			return {"error": "ComfyUI failed: %s" % _error_message(status)}
		return await _download_first_image(entry.get("outputs", {}))
	return {"error": "unreachable"}


## Uploads a PNG to ComfyUI's temp folder and returns the name LoadImage expects, or an
## error Dictionary.
func _upload(image: Image, filename: String) -> Variant:
	var form := Http.multipart(
		{"type": UPLOAD_TYPE, "overwrite": "true"},
		{"image": {"filename": filename, "type": "image/png", "bytes": image.save_png_to_buffer()}}
	)
	var response := await Http.request(
		host, _base_url + "/upload/image", HTTPClient.METHOD_POST, [form.content_type], form.body
	)
	if response.has("error"):
		return {"error": "ComfyUI is not reachable at %s (%s)" % [_base_url, response.error]}
	var uploaded: Variant = Http.json(response)
	if response.code != 200 or typeof(uploaded) != TYPE_DICTIONARY or not uploaded.has("name"):
		return {"error": "ComfyUI rejected the upload (HTTP %d): %s" % [response.code, Http.text(response)]}
	var name := str(uploaded.name)
	if not str(uploaded.get("subfolder", "")).is_empty():
		name = str(uploaded.subfolder).path_join(name)
	return "%s [%s]" % [name, uploaded.get("type", UPLOAD_TYPE)]


## Nearest-neighbor upscale by [param scale], anchored top-left on a canvas of
## [param canvas_size] padded with [param padding]. Alpha is dropped (VAEEncode ignores it).
static func _upscaled(image: Image, scale: int, canvas_size: Vector2i, padding: Color) -> Image:
	var scaled := Image.new()
	scaled.copy_from(image)
	scaled.convert(Image.FORMAT_RGB8)
	scaled.resize(image.get_width() * scale, image.get_height() * scale, Image.INTERPOLATE_NEAREST)
	var canvas := Image.create_empty(canvas_size.x, canvas_size.y, false, Image.FORMAT_RGB8)
	canvas.fill(padding)
	canvas.blit_rect(scaled, Rect2i(Vector2i.ZERO, scaled.get_size()), Vector2i.ZERO)
	return canvas


## Swaps the empty latent for the encoded init image and samples from [method edit_sigmas]
## instead of KSampler's denoise (with 8 steps it only offers a few coarse start points, and
## all of them keep the init colors). With a mask, only the masked latent area is denoised
## (SetLatentNoiseMask) and DifferentialDiffusion blends its border.
static func _add_edit_nodes(workflow: Dictionary, init_name: String, mask_name: Variant, strength: float) -> void:
	var ksampler: Dictionary = workflow.sampler.inputs
	workflow.erase("latent")
	workflow["init"] = {"class_type": "LoadImage", "inputs": {"image": init_name}}
	workflow["encode"] = {"class_type": "VAEEncode", "inputs": {"pixels": ["init", 0], "vae": ["vae", 0]}}
	workflow["sigmas"] = {
		"class_type": "ManualSigmas", "inputs": {"sigmas": edit_sigmas(strength, int(ksampler.steps))}
	}
	workflow["sampler_select"] = {
		"class_type": "KSamplerSelect", "inputs": {"sampler_name": ksampler.sampler_name}
	}
	var model: Array = ksampler.model
	var latent := ["encode", 0]
	if mask_name != null:
		workflow["mask"] = {"class_type": "LoadImageMask", "inputs": {"image": mask_name, "channel": "red"}}
		workflow["noise_mask"] = {
			"class_type": "SetLatentNoiseMask", "inputs": {"samples": ["encode", 0], "mask": ["mask", 0]}
		}
		workflow["differential"] = {
			"class_type": "DifferentialDiffusion", "inputs": {"model": model, "strength": 1.0}
		}
		model = ["differential", 0]
		latent = ["noise_mask", 0]
	workflow["sampler"] = {
		"class_type": "SamplerCustom",
		"inputs":
		{
			"model": model,
			"add_noise": true,
			"noise_seed": ksampler.seed,
			"cfg": ksampler.cfg,
			"positive": ksampler.positive,
			"negative": ksampler.negative,
			"sampler": ["sampler_select", 0],
			"sigmas": ["sigmas", 0],
			"latent_image": latent,
		},
	}


## The shifted "simple" schedule of the full generation, started at σ₀ instead of 1.
static func edit_sigmas(strength: float, steps: int) -> String:
	var start_sigma := 1.0 - STRENGTH_KEEP * pow(1.0 - clampf(strength, 0.0, 1.0), STRENGTH_EXPONENT)
	var start_t := start_sigma / (SHIFT - (SHIFT - 1.0) * start_sigma)
	var sigmas := PackedStringArray()
	for i in steps + 1:
		var t := start_t * (1.0 - float(i) / steps)
		sigmas.append("%.5f" % (SHIFT * t / (1.0 + (SHIFT - 1.0) * t)))
	return ", ".join(sigmas)


func _download_first_image(outputs: Dictionary) -> Dictionary:
	for node_id: String in outputs:
		for info: Dictionary in outputs[node_id].get("images", []):
			var query := "filename=%s&subfolder=%s&type=%s" % [
				str(info.get("filename", "")).uri_encode(),
				str(info.get("subfolder", "")).uri_encode(),
				str(info.get("type", "output")).uri_encode(),
			]
			var view := await Http.request(host, _base_url + "/view?" + query)
			if view.has("error") or view.code != 200:
				return {"error": "could not download the ComfyUI result"}
			var image := Http.decode_image(view.body)
			if image == null:
				return {"error": "ComfyUI returned an unreadable image"}
			return {"image": image}
	return {"error": "the workflow finished without an image output"}


static func _error_message(status: Dictionary) -> String:
	for message: Array in status.get("messages", []):
		if message.size() >= 2 and message[0] == "execution_error":
			var details: Dictionary = message[1]
			return "%s: %s" % [details.get("node_type", "node"), details.get("exception_message", "")]
	return "unknown error"
