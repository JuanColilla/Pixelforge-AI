extends RefCounted
## Remote generation through the official PixelLab API v2. Needs the user's API token from
## their PixelLab account page; it is sent only to the API host. Request bodies follow
## https://api.pixellab.ai/v2/openapi.json and are built by pure static functions so they can
## be inspected (dry run) and validated against the schema without spending credits.

signal progress(text: String)

const Http := preload("../core/Http.gd")
const API_URL := "https://api.pixellab.ai/v2"
const NOT_CONNECTED_ERROR := "PixelLab is not connected (set a token in AI Studio settings)"
const POLL_INTERVAL_SEC := 3.0

const PIXFLUX_MIN_SIZE := 16
const PIXFLUX_MAX_SIZE := 400
const ROTATIONS_MAX_SIZE := 256
const ROTATE_MIN_SIZE := 16
const ROTATE_MAX_SIZE := 200
const ANIMATE_MAX_SIZE := 256
const ANIMATE_MIN_FRAMES := 4
const ANIMATE_MAX_FRAMES := 16
const ANIMATE_PIXEL_BUDGET := 524288
const INTERPOLATE_MIN_SIZE := 16
const INTERPOLATE_MAX_SIZE := 128
const DIRECTIONS := [
	"south", "south-east", "east", "north-east", "north", "north-west", "west", "south-west"
]
const CAMERA_VIEWS := ["side", "low top-down", "high top-down"]

var settings: RefCounted
var host: Node
var _cancelled := false
var _job_id := ""


func _init(settings_store: RefCounted, host_node: Node) -> void:
	settings = settings_store
	host = host_node


## Text to image for the generic engine path (pixflux).
func generate(request: Dictionary) -> Dictionary:
	var api_request := pixflux_request(
		request.prompt, request.size, request.remove_background, request.seed, request.palette
	)
	var result := await send(api_request)
	if result.has("error"):
		return result
	return {"image": result.images[0], "usage": result.usage}


## Sends a request built by one of the *_request functions. Waits for the background job
## when the API answers with one. Returns {"images": Array[Image], "keys": PackedStringArray,
## "usage": Dictionary} or {"error": String}.
func send(api_request: Dictionary) -> Dictionary:
	_cancelled = false
	_job_id = ""
	var headers := _headers()
	if headers.is_empty():
		return {"error": _missing_token_error()}
	var timeout := float(settings.get_value("generation_timeout_sec"))
	var response := await Http.request(
		host,
		api_url() + api_request.path,
		HTTPClient.METHOD_POST,
		headers,
		JSON.stringify(api_request.body),
		timeout
	)
	if response.has("error"):
		return {"error": "PixelLab: %s" % response.error}
	if response.code != 200 and response.code != 202:
		return {"error": http_error(response.code, Http.text(response))}
	var data: Variant = Http.json(response)
	if typeof(data) != TYPE_DICTIONARY:
		return {"error": "PixelLab returned a response that is not JSON"}
	var usage: Variant = data.get("usage")
	if data.has("background_job_id"):
		_job_id = str(data.background_job_id)
		var job := await _wait_for_job(headers, timeout)
		_job_id = ""
		if job.has("error"):
			return job
		data = job.last_response
		if job.usage != null:
			usage = job.usage
	var images := extract_images(data)
	if images.has("error"):
		return images
	images["usage"] = usage if typeof(usage) == TYPE_DICTIONARY else {}
	return images


func balance() -> Dictionary:
	var headers := _headers()
	if headers.is_empty():
		return {"error": _missing_token_error()}
	var response := await Http.request(host, api_url() + "/balance", HTTPClient.METHOD_GET, headers, "", 30.0)
	if response.has("error"):
		return {"error": "PixelLab: %s" % response.error}
	if response.code != 200:
		return {"error": http_error(response.code, Http.text(response))}
	var data: Variant = Http.json(response)
	if typeof(data) != TYPE_DICTIONARY:
		return {"error": "PixelLab returned a balance that is not JSON"}
	var credits: Dictionary = data.get("credits", {})
	var subscription: Dictionary = data.get("subscription", {})
	return {
		"usd": float(credits.get("usd", 0.0)),
		"generations": float(subscription.get("generations", 0.0)),
		"generations_total": float(subscription.get("total", 0.0)),
		"subscription": str(subscription.get("status", "none")),
		"plan": str(subscription.get("plan", "")) if subscription.get("plan") != null else "",
	}


func cancel() -> void:
	_cancelled = true
	if not _job_id.is_empty():
		var headers := _headers()
		if not headers.is_empty():
			Http.request(host, api_url() + "/background-jobs/" + _job_id, HTTPClient.METHOD_DELETE, headers)


## PIXELLAB_API_URL points the provider at another host (a local mock for tests). Only
## https, or plain http to the loopback interface, is accepted.
static func api_url() -> String:
	var override := OS.get_environment("PIXELLAB_API_URL").strip_edges().trim_suffix("/")
	if override.begins_with("https://"):
		return override
	if override.begins_with("http://127.0.0.1:") or override.begins_with("http://localhost:"):
		return override
	return API_URL


# Request builders. Each returns {"path", "body"} or {"error"}.


static func pixflux_request(
	description: String, size: Vector2i, no_background: bool, seed: int, palette: PackedColorArray
) -> Dictionary:
	var body := {
		"description": description,
		"image_size":
		{
			"width": clampi(size.x, PIXFLUX_MIN_SIZE, PIXFLUX_MAX_SIZE),
			"height": clampi(size.y, PIXFLUX_MIN_SIZE, PIXFLUX_MAX_SIZE),
		},
		"no_background": no_background,
	}
	if seed >= 0:
		body["seed"] = seed
	if not palette.is_empty():
		body["color_image"] = base64_image(_palette_image(palette))
	return {"path": "/create-image-pixflux", "body": body}


static func rotations_request(image: Image, description: String, no_background: bool, seed: int) -> Dictionary:
	if image.get_width() > ROTATIONS_MAX_SIZE or image.get_height() > ROTATIONS_MAX_SIZE:
		return {"error": "8 rotations accept at most %d×%d px" % [ROTATIONS_MAX_SIZE, ROTATIONS_MAX_SIZE]}
	var body := {"first_frame": base64_image(image), "no_background": no_background}
	if not description.is_empty():
		body["description"] = description.left(2000)
	if seed >= 0:
		body["seed"] = seed
	return {"path": "/generate-8-rotations-v3", "body": body}


static func rotate_request(
	image: Image,
	from_direction: String,
	to_direction: String,
	from_view: String,
	to_view: String,
	seed: int,
	palette: PackedColorArray
) -> Dictionary:
	var size := image.get_size()
	if size.x < ROTATE_MIN_SIZE or size.y < ROTATE_MIN_SIZE or size.x > ROTATE_MAX_SIZE or size.y > ROTATE_MAX_SIZE:
		return {"error": "rotate accepts %d to %d px per side" % [ROTATE_MIN_SIZE, ROTATE_MAX_SIZE]}
	for direction in [from_direction, to_direction]:
		if not direction in DIRECTIONS:
			return {"error": "unknown direction '%s' (use %s)" % [direction, ", ".join(DIRECTIONS)]}
	for view in [from_view, to_view]:
		if not view in CAMERA_VIEWS:
			return {"error": "unknown view '%s' (use %s)" % [view, ", ".join(CAMERA_VIEWS)]}
	var body := {
		"image_size": {"width": size.x, "height": size.y},
		"from_image": base64_image(image),
		"from_direction": from_direction,
		"to_direction": to_direction,
		"from_view": from_view,
		"to_view": to_view,
	}
	if seed >= 0:
		body["seed"] = seed
	if not palette.is_empty():
		body["color_image"] = base64_image(_palette_image(palette))
	return {"path": "/rotate", "body": body}


static func animate_request(
	image: Image, action: String, frame_count: int, no_background: bool, seed: int
) -> Dictionary:
	var size := image.get_size()
	if size.x > ANIMATE_MAX_SIZE or size.y > ANIMATE_MAX_SIZE:
		return {"error": "animate accepts at most %d×%d px" % [ANIMATE_MAX_SIZE, ANIMATE_MAX_SIZE]}
	if action.is_empty():
		return {"error": "describe the action to animate"}
	if frame_count < ANIMATE_MIN_FRAMES or frame_count > ANIMATE_MAX_FRAMES or frame_count % 2 != 0:
		return {"error": "frame_count must be even, from %d to %d" % [ANIMATE_MIN_FRAMES, ANIMATE_MAX_FRAMES]}
	if size.x * size.y * frame_count > ANIMATE_PIXEL_BUDGET:
		return {
			"error":
			"width × height × frame_count must be at most %d (%d×%d×%d)"
			% [ANIMATE_PIXEL_BUDGET, size.x, size.y, frame_count]
		}
	var body := {
		"first_frame": base64_image(image),
		"action": action.left(1000),
		"frame_count": frame_count,
		"no_background": no_background,
	}
	if seed >= 0:
		body["seed"] = seed
	return {"path": "/animate-with-text-v3", "body": body}


static func interpolate_request(
	start: Image, end: Image, action: String, no_background: bool, seed: int, palette: PackedColorArray
) -> Dictionary:
	var size := start.get_size()
	if end.get_size() != size:
		return {"error": "both keyframes must have the same size"}
	if (
		size.x < INTERPOLATE_MIN_SIZE
		or size.y < INTERPOLATE_MIN_SIZE
		or size.x > INTERPOLATE_MAX_SIZE
		or size.y > INTERPOLATE_MAX_SIZE
	):
		return {"error": "interpolation accepts %d to %d px per side" % [INTERPOLATE_MIN_SIZE, INTERPOLATE_MAX_SIZE]}
	if action.is_empty():
		return {"error": "describe the transition"}
	var frame_size := {"width": size.x, "height": size.y}
	var body := {
		"start_image": {"image": base64_image(start), "size": frame_size},
		"end_image": {"image": base64_image(end), "size": frame_size.duplicate()},
		"action": action.left(500),
		"image_size": frame_size.duplicate(),
		"no_background": no_background,
	}
	if seed >= 0:
		body["seed"] = seed
	if palette.size() >= 2:
		var colors: Array[String] = []
		for color in palette.slice(0, 256):
			colors.append("#" + color.to_html(false))
		body["target_palette"] = {"colors": colors}
	return {"path": "/interpolation-v2", "body": body}


static func base64_image(image: Image) -> Dictionary:
	return {"type": "base64", "base64": Marshalls.raw_to_base64(image.save_png_to_buffer()), "format": "png"}


## Pulls the images out of a finished response: "images" (list, or map keyed by direction)
## first, then a single "image", then any base64 image found in the payload, in order.
static func extract_images(data: Variant) -> Dictionary:
	var entries: Array = []
	if typeof(data) == TYPE_DICTIONARY and data.has("images"):
		var images: Variant = data.images
		if typeof(images) == TYPE_DICTIONARY:
			for key in images:
				entries.append([str(key), images[key]])
		elif typeof(images) == TYPE_ARRAY:
			for item in images:
				entries.append(["", item])
	elif typeof(data) == TYPE_DICTIONARY and typeof(data.get("image")) == TYPE_DICTIONARY:
		entries.append(["", data.image])
	else:
		for encoded in _find_base64_images(data):
			entries.append(["", {"base64": encoded}])
	var result := {"images": [] as Array[Image], "keys": PackedStringArray()}
	for entry: Array in entries:
		var value: Variant = entry[1]
		var encoded: String = value.get("base64", "") if typeof(value) == TYPE_DICTIONARY else str(value)
		var image := Http.decode_image(Marshalls.base64_to_raw(_strip_data_url(encoded)))
		if image == null:
			return {"error": "PixelLab returned an unreadable image"}
		image.convert(Image.FORMAT_RGBA8)
		result.images.append(image)
		result.keys.append(entry[0])
	if result.images.is_empty():
		return {"error": "PixelLab response has no image"}
	return result


static func http_error(code: int, body: String) -> String:
	match code:
		401:
			return "PixelLab rejected the API token (401)"
		402:
			return "PixelLab: not enough credits (402)"
		422:
			return "PixelLab: invalid request (422) %s" % body
		429:
			return "PixelLab: too many requests or concurrent jobs, try again shortly (429)"
	return "PixelLab error %d: %s" % [code, body]


func _headers() -> PackedStringArray:
	var token: String = settings.pixellab_token()
	if token.is_empty():
		return PackedStringArray()
	return PackedStringArray(["Content-Type: application/json", "Authorization: Bearer " + token])


static func _missing_token_error() -> String:
	return NOT_CONNECTED_ERROR


## Polls /background-jobs until the job finishes. Transport errors, 429 and 5xx are retried;
## any other HTTP error ends the wait.
func _wait_for_job(headers: PackedStringArray, timeout: float) -> Dictionary:
	var url := api_url() + "/background-jobs/" + _job_id
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await host.get_tree().create_timer(POLL_INTERVAL_SEC).timeout
		if _cancelled:
			return {"error": "cancelled"}
		var response := await Http.request(host, url, HTTPClient.METHOD_GET, headers, "", 30.0)
		if response.has("error") or response.code == 429 or response.code >= 500:
			continue
		if response.code != 200:
			return {"error": http_error(response.code, Http.text(response))}
		var job: Variant = Http.json(response)
		if typeof(job) != TYPE_DICTIONARY:
			continue
		var last: Variant = job.get("last_response")
		if typeof(last) != TYPE_DICTIONARY:
			last = {}
		match str(job.get("status", "")):
			"completed":
				return {"last_response": last, "usage": job.get("usage")}
			"failed":
				return {"error": "PixelLab job failed: %s" % str(last.get("detail", "no detail"))}
			_:
				_report_queue(last)
	return {"error": "PixelLab timed out"}


func _report_queue(last: Dictionary) -> void:
	if last.get("queue_position") != null:
		progress.emit("PixelLab queue position %s" % str(last.queue_position))
	elif last.get("estimated_wait_seconds") != null:
		progress.emit("PixelLab: about %s s left" % str(last.estimated_wait_seconds))


static func _strip_data_url(encoded: String) -> String:
	if encoded.begins_with("data:"):
		return encoded.get_slice(",", 1)
	return encoded


static func _find_base64_images(value: Variant) -> PackedStringArray:
	var found := PackedStringArray()
	if typeof(value) == TYPE_DICTIONARY:
		if typeof(value.get("base64")) == TYPE_STRING:
			found.append(value.base64)
			return found
		for key in value:
			found.append_array(_find_base64_images(value[key]))
	elif typeof(value) == TYPE_ARRAY:
		for item in value:
			found.append_array(_find_base64_images(item))
	return found


static func _palette_image(palette: PackedColorArray) -> Image:
	var image := Image.create_empty(palette.size(), 1, false, Image.FORMAT_RGBA8)
	for i in palette.size():
		image.set_pixel(i, 0, Color(palette[i], 1.0))
	return image
