extends RefCounted
## Canvas operations shared by the panel and the MCP bridge. Every pixel write goes through
## Pixelorama's own cel replacement, so each operation is one step in the undo history.
## Methods return a Dictionary; failures carry an "error" key.

const PixelGrid := preload("PixelGrid.gd")
## Mirrors Global.LayerTypes. Autoloads are reached through the API so scripts also compile
## outside a running Pixelorama (godot --check-only).
const LAYER_TYPE_NAMES := ["pixel", "group", "3d", "tilemap", "audio"]
const GROUP_LAYER := 1

var api: Node


func _init(extensions_api: Node) -> void:
	api = extensions_api


func project() -> Project:
	return api.project.current_project


func project_info() -> Dictionary:
	var current := project()
	var layers: Array[Dictionary] = []
	for i in current.layers.size():
		var layer: BaseLayer = current.layers[i]
		layers.append(
			{
				"index": i,
				"name": layer.name,
				"type": LAYER_TYPE_NAMES[layer.get_layer_type()],
				"visible": layer.visible,
				"locked": layer.locked,
			}
		)
	var palette: Array[String] = []
	for color in palette_colors():
		palette.append(PixelGrid.to_hex(color))
	return {
		"name": current.name,
		"width": current.size.x,
		"height": current.size.y,
		"frames": current.frames.size(),
		"layers": layers,
		"current_frame": current.current_frame,
		"current_layer": current.current_layer,
		"palette": palette,
	}


func palette_colors() -> PackedColorArray:
	var colors := PackedColorArray()
	var palette: Palette = api.palette.autoload().current_palette
	if palette == null:
		return colors
	var data := palette.get_color_data()
	var indices := data.keys()
	indices.sort()
	for index: int in indices:
		colors.append(data[index].color)
	return colors


## Resolves -1 to the current frame/layer and validates the indices.
func resolve_cel(frame: int, layer: int) -> Dictionary:
	var current := project()
	frame = current.current_frame if frame < 0 else frame
	layer = current.current_layer if layer < 0 else layer
	if frame >= current.frames.size():
		return {"error": "frame %d does not exist (project has %d)" % [frame, current.frames.size()]}
	if layer >= current.layers.size():
		return {"error": "layer %d does not exist (project has %d)" % [layer, current.layers.size()]}
	return {"frame": frame, "layer": layer}


func cel_image(frame: int, layer: int) -> Image:
	var cel: BaseCel = project().frames[frame].cels[layer]
	var image := Image.new()
	image.copy_from(cel.get_image())
	image.convert(Image.FORMAT_RGBA8)
	return image


## Blends every visible pixel layer of [param frame], bottom to top.
func composite_image(frame: int) -> Image:
	var current := project()
	var result := Image.create_empty(current.size.x, current.size.y, false, Image.FORMAT_RGBA8)
	for layer_index in current.layers.size():
		var layer: BaseLayer = current.layers[layer_index]
		if not layer.is_visible_in_hierarchy():
			continue
		if layer.get_layer_type() == GROUP_LAYER:
			continue
		var image := cel_image(frame, layer_index)
		result.blend_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i.ZERO)
	return result


func render_png(frame: int, layer: int, scale: int) -> Dictionary:
	var target := resolve_cel(frame, maxi(layer, 0))
	if target.has("error"):
		return target
	var image := composite_image(target.frame) if layer < 0 else cel_image(target.frame, target.layer)
	scale = clampi(scale, 1, 32)
	if scale > 1:
		image.resize(image.get_width() * scale, image.get_height() * scale, Image.INTERPOLATE_NEAREST)
	return {
		"png_base64": Marshalls.raw_to_base64(image.save_png_to_buffer()),
		"width": image.get_width(),
		"height": image.get_height(),
		"scale": scale,
		"frame": target.frame,
		"layer": layer,
	}


func read_pixels(frame: int, layer: int, rect: Rect2i) -> Dictionary:
	var target := resolve_cel(frame, layer)
	if target.has("error"):
		return target
	if rect.size.x <= 0 or rect.size.y <= 0:
		rect = Rect2i(Vector2i.ZERO, project().size)
	var result := PixelGrid.encode(cel_image(target.frame, target.layer), rect)
	result["frame"] = target.frame
	result["layer"] = target.layer
	return result


## Replaces the whole cel with [param image] (one undo step). The image is cropped or padded
## to the project size.
func write_cel(image: Image, frame: int, layer: int) -> Dictionary:
	var target := resolve_cel(frame, layer)
	if target.has("error"):
		return target
	var current := project()
	var cel: BaseCel = current.frames[target.frame].cels[target.layer]
	if cel.get_class_name() != "PixelCel":
		return {"error": "layer %d is not a pixel layer" % target.layer}
	if current.layers[target.layer].is_locked_in_hierarchy():
		return {"error": "layer %d is locked" % target.layer}
	if image.get_size() != current.size:
		var sized := Image.create_empty(current.size.x, current.size.y, false, Image.FORMAT_RGBA8)
		sized.blit_rect(image, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i.ZERO)
		image = sized
	api.project.set_pixelcel_image(image, target.frame, target.layer)
	return {"frame": target.frame, "layer": target.layer}


## Reads the cel, lets [param edit] change it and writes it back as one undo step.
## [param edit] returns the number of pixels touched.
func edit_cel(frame: int, layer: int, edit: Callable) -> Dictionary:
	var target := resolve_cel(frame, layer)
	if target.has("error"):
		return target
	var image := cel_image(target.frame, target.layer)
	var touched: int = edit.call(image)
	var written := write_cel(image, target.frame, target.layer)
	if written.has("error"):
		return written
	written["pixels"] = touched
	return written


func set_pixels(frame: int, layer: int, pixels: Array) -> Dictionary:
	var parsed: Array[Array] = []
	for entry in pixels:
		if typeof(entry) != TYPE_DICTIONARY:
			return {"error": "each pixel must be an object {x, y, color}"}
		var color: Variant = PixelGrid.parse_color(entry.get("color"))
		if color == null:
			return {"error": "invalid color: %s" % str(entry.get("color"))}
		parsed.append([Vector2i(int(entry.get("x", 0)), int(entry.get("y", 0))), color])
	return edit_cel(
		frame,
		layer,
		func(image: Image) -> int:
			var count := 0
			for pixel in parsed:
				if Rect2i(Vector2i.ZERO, image.get_size()).has_point(pixel[0]):
					image.set_pixelv(pixel[0], pixel[1])
					count += 1
			return count
	)


func draw_line(frame: int, layer: int, from: Vector2i, to: Vector2i, color: Color) -> Dictionary:
	return edit_cel(
		frame,
		layer,
		func(image: Image) -> int:
			var count := 0
			for point in Geometry2D.bresenham_line(from, to):
				if Rect2i(Vector2i.ZERO, image.get_size()).has_point(point):
					image.set_pixelv(point, color)
					count += 1
			return count
	)


func draw_rect(frame: int, layer: int, rect: Rect2i, color: Color, filled: bool) -> Dictionary:
	return edit_cel(
		frame,
		layer,
		func(image: Image) -> int:
			var area := rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
			var count := 0
			for y in range(area.position.y, area.end.y):
				for x in range(area.position.x, area.end.x):
					var on_border := (
						x == rect.position.x
						or y == rect.position.y
						or x == rect.end.x - 1
						or y == rect.end.y - 1
					)
					if filled or on_border:
						image.set_pixel(x, y, color)
						count += 1
			return count
	)


## Contiguous bucket fill replacing the exact color found at [param start].
func flood_fill(frame: int, layer: int, start: Vector2i, color: Color) -> Dictionary:
	return edit_cel(
		frame,
		layer,
		func(image: Image) -> int:
			var bounds := Rect2i(Vector2i.ZERO, image.get_size())
			if not bounds.has_point(start):
				return 0
			var original := image.get_pixelv(start)
			if original == color:
				return 0
			var count := 0
			var stack: Array[Vector2i] = [start]
			while not stack.is_empty():
				var point: Vector2i = stack.pop_back()
				if not bounds.has_point(point) or image.get_pixelv(point) != original:
					continue
				image.set_pixelv(point, color)
				count += 1
				stack.append(point + Vector2i.RIGHT)
				stack.append(point + Vector2i.LEFT)
				stack.append(point + Vector2i.DOWN)
				stack.append(point + Vector2i.UP)
			return count
	)


func paint_grid(
	frame: int, layer: int, origin: Vector2i, palette: PackedColorArray, rows: PackedStringArray
) -> Dictionary:
	return edit_cel(
		frame, layer, func(image: Image) -> int: return PixelGrid.paint(image, origin, palette, rows)
	)


func clear_cel(frame: int, layer: int) -> Dictionary:
	return edit_cel(
		frame,
		layer,
		func(image: Image) -> int:
			image.fill(Color(0, 0, 0, 0))
			return image.get_width() * image.get_height()
	)


## Adds a pixel layer above the current one, selects it and returns its index.
func add_layer(layer_name: String) -> Dictionary:
	var current := project()
	var above := current.current_layer
	api.project.add_new_layer(above, layer_name)
	api.project.select_cels([[current.current_frame, above + 1]])
	return {"layer": above + 1, "layers": current.layers.size()}


func add_frame(after_frame: int) -> Dictionary:
	var current := project()
	after_frame = current.current_frame if after_frame < 0 else after_frame
	if after_frame >= current.frames.size():
		return {"error": "frame %d does not exist" % after_frame}
	api.project.add_new_frame(after_frame)
	return {"frame": after_frame + 1, "frames": current.frames.size()}


func select_cel(frame: int, layer: int) -> Dictionary:
	var target := resolve_cel(frame, layer)
	if target.has("error"):
		return target
	api.project.select_cels([[target.frame, target.layer]])
	return target


func new_project(width: int, height: int, project_name: String) -> Dictionary:
	if width < 1 or height < 1 or width > 4096 or height > 4096:
		return {"error": "size must be between 1 and 4096"}
	api.project.new_project([], project_name, Vector2(width, height))
	var tabs: TabBar = api.general.get_global().tabs
	tabs.current_tab = tabs.get_tab_count() - 1
	return project_info()


func undo() -> Dictionary:
	project().commit_undo()
	return {"action": project().undo_redo.get_current_action_name()}


func redo() -> Dictionary:
	project().commit_redo()
	return {"action": project().undo_redo.get_current_action_name()}
