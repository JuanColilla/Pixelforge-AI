extends RefCounted
## Text form of pixel art shared by the MCP bridge and Claude's pixel mode: a palette of hex
## colors plus rows of base62 palette indices. "." leaves a pixel untouched when painting.

const ALPHABET := "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
const SKIP := "."
const MAX_COLORS := 62


## Accepts "#rgb", "#rrggbb", "#rrggbbaa" (with or without "#") and Godot color names.
## Returns null when the value is not a color.
static func parse_color(value: Variant) -> Variant:
	if value is Color:
		return value
	if typeof(value) != TYPE_STRING:
		return null
	var text := (value as String).strip_edges()
	if Color.html_is_valid(text):
		return Color.html(text)
	var named := Color.from_string(text, Color(1, 0, 1, 0.5))
	if named == Color(1, 0, 1, 0.5):
		return null
	return named


static func to_hex(color: Color) -> String:
	return "#" + color.to_html(color.a < 1.0)


static func parse_palette(values: Array) -> Dictionary:
	if values.is_empty() or values.size() > MAX_COLORS:
		return {"error": "palette needs between 1 and %d colors" % MAX_COLORS}
	var palette := PackedColorArray()
	for value in values:
		var color: Variant = parse_color(value)
		if color == null:
			return {"error": "invalid color in palette: %s" % str(value)}
		palette.append(color)
	return {"palette": palette}


## Paints [param rows] onto [param image] with its top-left corner at [param origin].
## Pixels outside the image are clipped. Returns the number of pixels written.
static func paint(
	image: Image, origin: Vector2i, palette: PackedColorArray, rows: PackedStringArray
) -> int:
	var written := 0
	for row_index in rows.size():
		var row := rows[row_index]
		for column in row.length():
			var symbol := row[column]
			if symbol == SKIP or symbol == " ":
				continue
			var palette_index := ALPHABET.find(symbol)
			if palette_index < 0 or palette_index >= palette.size():
				continue
			var point := origin + Vector2i(column, row_index)
			if point.x < 0 or point.y < 0:
				continue
			if point.x >= image.get_width() or point.y >= image.get_height():
				continue
			image.set_pixelv(point, palette[palette_index])
			written += 1
	return written


## Encodes the pixels of [param rect] as a palette plus rows. Fully transparent pixels share
## one transparent palette entry.
static func encode(image: Image, rect: Rect2i) -> Dictionary:
	rect = rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	var palette: Array[String] = []
	var index_of := {}
	var rows := PackedStringArray()
	for y in range(rect.position.y, rect.end.y):
		var row := ""
		for x in range(rect.position.x, rect.end.x):
			var color := image.get_pixel(x, y)
			if color.a == 0.0:
				color = Color(0, 0, 0, 0)
			var key := color.to_rgba32()
			if not index_of.has(key):
				if palette.size() >= MAX_COLORS:
					return {
						"error":
						"region has more than %d colors; read a smaller area" % MAX_COLORS
					}
				index_of[key] = palette.size()
				palette.append(to_hex(color))
			row += ALPHABET[index_of[key]]
		rows.append(row)
	return {
		"x": rect.position.x,
		"y": rect.position.y,
		"width": rect.size.x,
		"height": rect.size.y,
		"palette": palette,
		"rows": rows,
	}
