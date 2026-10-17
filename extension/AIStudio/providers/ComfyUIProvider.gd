extends RefCounted
## Local generation through a running ComfyUI server (Comfy Desktop or comfy-cli).
## Default graph: Z-Image Turbo. A custom API-format workflow can replace it; it may use the
## placeholders {{prompt}}, {{width}}, {{height}} and {{seed}}.

const Http := preload("../core/Http.gd")
const POLL_INTERVAL_SEC := 1.0

var settings: RefCounted
var host: Node
var _base_url := ""
var _prompt_id := ""
var _cancelled := false


func _init(settings_store: RefCounted, host_node: Node) -> void:
	settings = settings_store
	host = host_node


func generate(request: Dictionary) -> Dictionary:
	_cancelled = false
	_prompt_id = ""
	_base_url = str(settings.get_value("comfy_url")).strip_edges().trim_suffix("/")
	var generation_size := generation_size_for(request.size)
	var noise_seed: int = request.seed if request.seed >= 0 else randi()
	var workflow: Variant = _build_workflow(styled_prompt(request), generation_size, noise_seed)
	if workflow is String:
		return {"error": workflow}

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


func cancel() -> void:
	_cancelled = true
	if not _prompt_id.is_empty():
		Http.request(host, _base_url + "/interrupt", HTTPClient.METHOD_POST)


static func styled_prompt(request: Dictionary) -> String:
	var prompt := (
		"pixel art, %s, clean pixel art sprite, flat colors, limited palette, crisp hard edges, no anti-aliasing"
		% request.prompt
	)
	if request.remove_background:
		prompt += ", single subject centered, isolated on a plain flat white background"
	return prompt


## About one megapixel with the target's aspect ratio, in multiples of 64.
static func generation_size_for(target: Vector2i) -> Vector2i:
	var aspect := float(target.x) / float(target.y)
	var width := sqrt(1024.0 * 1024.0 * aspect)
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
			"class_type": "ModelSamplingAuraFlow", "inputs": {"model": ["unet", 0], "shift": 3}
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
