extends RefCounted
## Remote generation through the official PixelLab API v2 (pixflux). Needs the user's API
## token from their PixelLab account page; it is sent only to api.pixellab.ai.

const Http := preload("../core/Http.gd")
const API_URL := "https://api.pixellab.ai/v2"
const MIN_SIZE := 16
const MAX_SIZE := 400
const POLL_INTERVAL_SEC := 2.0

var settings: RefCounted
var host: Node
var _cancelled := false


func _init(settings_store: RefCounted, host_node: Node) -> void:
	settings = settings_store
	host = host_node


func generate(request: Dictionary) -> Dictionary:
	_cancelled = false
	var token: String = settings.pixellab_token()
	if token.is_empty():
		return {"error": "set your PixelLab API token in AI Studio settings (or PIXELLAB_API_TOKEN)"}
	var size: Vector2i = request.size
	var body := {
		"description": request.prompt,
		"image_size":
		{"width": clampi(size.x, MIN_SIZE, MAX_SIZE), "height": clampi(size.y, MIN_SIZE, MAX_SIZE)},
		"no_background": request.remove_background,
	}
	if request.seed >= 0:
		body["seed"] = request.seed
	var palette: PackedColorArray = request.palette
	if not palette.is_empty():
		body["color_image"] = {"type": "base64", "base64": _palette_png_base64(palette), "format": "png"}
	var headers := PackedStringArray(
		["Content-Type: application/json", "Authorization: Bearer " + token]
	)
	var timeout := float(settings.get_value("generation_timeout_sec"))
	var response := await Http.request(
		host, API_URL + "/create-image-pixflux", HTTPClient.METHOD_POST, headers, JSON.stringify(body), timeout
	)
	if response.has("error"):
		return {"error": "PixelLab: %s" % response.error}
	var data: Variant = Http.json(response)
	if response.code == 202 and typeof(data) == TYPE_DICTIONARY:
		var job_id := str(data.get("background_job_id", data.get("id", "")))
		if job_id.is_empty():
			return {"error": "PixelLab accepted the job without an id"}
		data = await _wait_for_job(job_id, headers, timeout)
		if data.has("error"):
			return data
	elif response.code != 200:
		return {"error": _http_error(response.code, Http.text(response))}
	var encoded := _find_base64_image(data)
	if encoded.is_empty():
		return {"error": "PixelLab response has no image"}
	var image := Http.decode_image(Marshalls.base64_to_raw(encoded))
	if image == null:
		return {"error": "PixelLab returned an unreadable image"}
	return {"image": image}


func cancel() -> void:
	_cancelled = true


func _wait_for_job(job_id: String, headers: PackedStringArray, timeout: float) -> Dictionary:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if _cancelled:
			Http.request(host, API_URL + "/background-jobs/" + job_id, HTTPClient.METHOD_DELETE, headers)
			return {"error": "cancelled"}
		await host.get_tree().create_timer(POLL_INTERVAL_SEC).timeout
		var response := await Http.request(host, API_URL + "/background-jobs/" + job_id, HTTPClient.METHOD_GET, headers)
		if response.has("error") or response.code != 200:
			continue
		var job: Variant = Http.json(response)
		if typeof(job) != TYPE_DICTIONARY:
			continue
		match str(job.get("status", "")):
			"completed":
				return job.get("last_response", {})
			"failed":
				return {"error": "PixelLab job failed"}
	return {"error": "PixelLab timed out"}


static func _http_error(code: int, body: String) -> String:
	match code:
		401:
			return "PixelLab rejected the API token (401)"
		402:
			return "PixelLab: not enough credits (402)"
		422:
			return "PixelLab: invalid request (422) %s" % body
		429:
			return "PixelLab: rate limited, try again shortly (429)"
	return "PixelLab error %d: %s" % [code, body]


## Finds the first {"base64": "..."} image anywhere in a response.
static func _find_base64_image(value: Variant) -> String:
	if typeof(value) == TYPE_DICTIONARY:
		if typeof(value.get("base64")) == TYPE_STRING:
			return value.base64
		for key in value:
			var found := _find_base64_image(value[key])
			if not found.is_empty():
				return found
	elif typeof(value) == TYPE_ARRAY:
		for item in value:
			var found := _find_base64_image(item)
			if not found.is_empty():
				return found
	return ""


static func _palette_png_base64(palette: PackedColorArray) -> String:
	var image := Image.create_empty(palette.size(), 1, false, Image.FORMAT_RGBA8)
	for i in palette.size():
		image.set_pixel(i, 0, Color(palette[i], 1.0))
	return Marshalls.raw_to_base64(image.save_png_to_buffer())
