extends RefCounted
## Awaitable HTTP helper. Each call owns a temporary HTTPRequest child of [param host].

const BODY_LIMIT := 64 * 1024 * 1024


static func request(
	host: Node,
	url: String,
	method := HTTPClient.METHOD_GET,
	headers := PackedStringArray(),
	body := "",
	timeout := 60.0
) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = timeout
	http.use_threads = true
	http.body_size_limit = BODY_LIMIT
	host.add_child(http)
	var error := http.request(url, headers, method, body)
	if error != OK:
		http.queue_free()
		return {"error": "could not start request to %s (%s)" % [url, error_string(error)]}
	var response: Array = await http.request_completed
	http.queue_free()
	var result: int = response[0]
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"error": "request to %s failed (%s)" % [url, _result_text(result)]}
	return {"code": response[1], "body": response[3]}


static func json(response: Dictionary) -> Variant:
	var body: PackedByteArray = response.get("body", PackedByteArray())
	return JSON.parse_string(body.get_string_from_utf8())


static func text(response: Dictionary, limit := 600) -> String:
	var body: PackedByteArray = response.get("body", PackedByteArray())
	return body.get_string_from_utf8().left(limit)


## Decodes PNG, JPEG or WebP bytes by sniffing the signature instead of trusting extensions.
static func decode_image(bytes: PackedByteArray) -> Image:
	if bytes.size() < 12:
		return null
	var image := Image.new()
	var error := ERR_FILE_UNRECOGNIZED
	if bytes[0] == 0x89 and bytes[1] == 0x50:
		error = image.load_png_from_buffer(bytes)
	elif bytes[0] == 0xFF and bytes[1] == 0xD8:
		error = image.load_jpg_from_buffer(bytes)
	elif bytes.slice(0, 4).get_string_from_ascii() == "RIFF":
		error = image.load_webp_from_buffer(bytes)
	return image if error == OK else null


static func _result_text(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE:
			return "cannot connect"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "connection error"
		HTTPRequest.RESULT_TIMEOUT:
			return "timed out"
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			return "response too large"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS handshake failed"
	return "error %d" % result
