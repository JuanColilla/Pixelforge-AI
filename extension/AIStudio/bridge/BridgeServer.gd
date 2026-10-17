extends Node
## Local JSON-lines bridge for pixelorama-mcp. Listens on 127.0.0.1 only; every request must
## carry the random token written to bridge.json (owner-only permissions) at startup.
## Request:  {"id": 1, "token": "...", "method": "draw_pixels", "params": {...}}\n
## Response: {"id": 1, "result": {...}}\n  or  {"id": 1, "error": "..."}\n

signal state_changed(listening: bool, message: String)

const Http := preload("../core/Http.gd")
const INFO_PATH := "user://ai_studio/bridge.json"
const MAX_BUFFER_BYTES := 32 * 1024 * 1024
const NEWLINE := 10
const SINGLE_OPS := {
	"draw_pixels": "pixels",
	"draw_line": "line",
	"draw_rect": "rect",
	"fill": "fill",
	"paint_grid": "grid",
	"clear_cel": "clear",
}

var settings: RefCounted
var canvas: RefCounted
var generator: Node
var port := 0

var _server := TCPServer.new()
var _clients: Array[Dictionary] = []
var _token := ""


func setup(settings_store: RefCounted, canvas_ops: RefCounted, generator_node: Node) -> void:
	settings = settings_store
	canvas = canvas_ops
	generator = generator_node


func start() -> Error:
	stop()
	port = int(settings.get_value("bridge_port"))
	var error := _server.listen(port, "127.0.0.1")
	if error != OK:
		state_changed.emit(false, tr("Bridge could not listen on port %d (%s)") % [port, error_string(error)])
		return error
	_token = Crypto.new().generate_random_bytes(24).hex_encode()
	var file := FileAccess.open(INFO_PATH, FileAccess.WRITE)
	file.store_string(
		JSON.stringify(
			{"host": "127.0.0.1", "port": port, "token": _token, "pid": OS.get_process_id()}, "\t"
		)
	)
	file.close()
	FileAccess.set_unix_permissions(
		info_file_path(), FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER
	)
	state_changed.emit(true, tr("MCP bridge listening on 127.0.0.1:%d") % port)
	return OK


func stop() -> void:
	for client in _clients:
		(client.peer as StreamPeerTCP).disconnect_from_host()
	_clients.clear()
	if _server.is_listening():
		_server.stop()
		if FileAccess.file_exists(INFO_PATH):
			DirAccess.remove_absolute(info_file_path())
		state_changed.emit(false, tr("MCP bridge stopped"))


func is_listening() -> bool:
	return _server.is_listening()


func info_file_path() -> String:
	return ProjectSettings.globalize_path(INFO_PATH)


func _exit_tree() -> void:
	stop()


func _process(_delta: float) -> void:
	if not _server.is_listening():
		return
	while _server.is_connection_available():
		_clients.append({"peer": _server.take_connection(), "buffer": PackedByteArray()})
	for client in _clients.duplicate():
		var peer: StreamPeerTCP = client.peer
		peer.poll()
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTING:
			continue
		if status != StreamPeerTCP.STATUS_CONNECTED:
			_clients.erase(client)
			continue
		var available := peer.get_available_bytes()
		if available <= 0:
			continue
		var chunk: Array = peer.get_data(available)
		if chunk[0] != OK:
			continue
		var buffer: PackedByteArray = client.buffer
		buffer.append_array(chunk[1])
		if buffer.size() > MAX_BUFFER_BYTES:
			peer.disconnect_from_host()
			_clients.erase(client)
			continue
		var newline := buffer.find(NEWLINE)
		while newline >= 0:
			_handle(peer, buffer.slice(0, newline).get_string_from_utf8())
			buffer = buffer.slice(newline + 1)
			newline = buffer.find(NEWLINE)
		client.buffer = buffer


func _handle(peer: StreamPeerTCP, line: String) -> void:
	var request: Variant = JSON.parse_string(line)
	if typeof(request) != TYPE_DICTIONARY:
		_send(peer, {"id": null, "error": "invalid JSON request"})
		return
	var id: Variant = request.get("id")
	if str(request.get("token", "")) != _token:
		_send(peer, {"id": id, "error": "invalid bridge token"})
		return
	var params: Variant = request.get("params", {})
	if typeof(params) != TYPE_DICTIONARY:
		params = {}
	var result: Dictionary = await _dispatch(str(request.get("method", "")), params)
	if result.has("error"):
		_send(peer, {"id": id, "error": str(result.error)})
	else:
		_send(peer, {"id": id, "result": result})


func _send(peer: StreamPeerTCP, payload: Dictionary) -> void:
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data((JSON.stringify(payload) + "\n").to_utf8_buffer())


func _dispatch(method: String, p: Dictionary) -> Dictionary:
	var frame := int(p.get("frame", -1))
	var layer := int(p.get("layer", -1))
	match method:
		"ping":
			return {"pong": true, "busy": generator.is_busy()}
		"get_project_info":
			return canvas.project_info()
		"view_canvas":
			return canvas.render_png(frame, layer, int(p.get("scale", 1)))
		"read_pixels":
			var rect := Rect2i(
				int(p.get("x", 0)), int(p.get("y", 0)), int(p.get("width", 0)), int(p.get("height", 0))
			)
			return canvas.read_pixels(frame, layer, rect)
		"draw_pixels", "draw_line", "draw_rect", "fill", "paint_grid", "clear_cel":
			var op := p.duplicate()
			op["op"] = SINGLE_OPS[method]
			return canvas.apply_ops(frame, layer, [op])
		"batch":
			var ops: Variant = p.get("ops", [])
			if typeof(ops) != TYPE_ARRAY:
				return {"error": "ops must be a list"}
			return canvas.apply_ops(frame, layer, ops)
		"set_image":
			var image := Http.decode_image(Marshalls.base64_to_raw(str(p.get("png_base64", ""))))
			if image == null:
				return {"error": "png_base64 is not a valid PNG/JPEG/WebP image"}
			image.convert(Image.FORMAT_RGBA8)
			return canvas.write_cel(image, frame, layer)
		"add_layer":
			return canvas.add_layer(str(p.get("name", "Layer")))
		"add_frame":
			return canvas.add_frame(int(p.get("after", -1)))
		"select_cel":
			return canvas.select_cel(frame, layer)
		"new_project":
			return canvas.new_project(
				int(p.get("width", 64)), int(p.get("height", 64)), str(p.get("name", "untitled"))
			)
		"undo":
			return canvas.undo()
		"redo":
			return canvas.redo()
		"select_rect":
			return canvas.select_rect(
				Rect2i(int(p.get("x", 0)), int(p.get("y", 0)), int(p.get("width", 0)), int(p.get("height", 0)))
			)
		"clear_selection":
			return canvas.clear_selection()
		"generate":
			return await generator.generate(p)
		"edit_image", "inpaint":
			# x/y/width/height pick the region (img2img) or mask (inpaint), not an output size.
			p["rect"] = {
				"x": p.get("x", 0), "y": p.get("y", 0), "width": p.get("width", 0), "height": p.get("height", 0)
			}
			p.erase("width")
			p.erase("height")
			p["mode"] = "img2img" if method == "edit_image" else "inpaint"
			return await generator.generate(p)
		"cancel":
			generator.cancel()
			return {"cancelled": true}
	return {"error": "unknown method '%s'" % method}
