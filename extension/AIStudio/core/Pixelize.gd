extends RefCounted
## Turns arbitrary generated images into canvas-sized pixel art: fit, background removal,
## hard alpha and color quantization (to the active palette or to k-means clusters).

const LUMA := Vector3(0.299, 0.587, 0.114)
const MAX_TRAINING_SAMPLES := 4096
const TRANSPARENT := Color(0, 0, 0, 0)


static func to_pixel_art(source: Image, size: Vector2i, options: Dictionary) -> Image:
	var image := Image.new()
	image.copy_from(source)
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RGBA8)
	image = fit(image, size)
	if options.get("remove_background", false):
		remove_border_background(image, float(options.get("background_tolerance", 0.12)))
	binarize_alpha(image)
	var palette: PackedColorArray = options.get("palette", PackedColorArray())
	var max_colors := int(options.get("colors", 0))
	if not palette.is_empty():
		map_to_palette(image, palette)
	elif max_colors > 0:
		map_to_palette(image, kmeans_palette(image, max_colors))
	return image


## Scales [param image] to fit inside [param size] keeping its aspect ratio, centered on a
## transparent canvas of exactly that size.
static func fit(image: Image, size: Vector2i) -> Image:
	var scale := minf(float(size.x) / image.get_width(), float(size.y) / image.get_height())
	var scaled := Vector2i(
		maxi(1, roundi(image.get_width() * scale)), maxi(1, roundi(image.get_height() * scale))
	)
	if scaled != image.get_size():
		var interpolation := Image.INTERPOLATE_LANCZOS if scale < 1.0 else Image.INTERPOLATE_NEAREST
		image.resize(scaled.x, scaled.y, interpolation)
	if scaled == size:
		return image
	var canvas := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	canvas.blit_rect(image, Rect2i(Vector2i.ZERO, scaled), (size - scaled) / 2)
	return canvas


## Flood-fills from the image border, clearing every connected pixel close to the dominant
## border color. Generators rarely return true alpha, but they do return flat backgrounds.
static func remove_border_background(image: Image, tolerance: float) -> void:
	var width := image.get_width()
	var height := image.get_height()
	var background := dominant_border_color(image)
	if background.a == 0.0:
		return
	var visited := PackedByteArray()
	visited.resize(width * height)
	var stack: Array[Vector2i] = []
	for x in width:
		stack.append(Vector2i(x, 0))
		stack.append(Vector2i(x, height - 1))
	for y in height:
		stack.append(Vector2i(0, y))
		stack.append(Vector2i(width - 1, y))
	while not stack.is_empty():
		var point: Vector2i = stack.pop_back()
		if point.x < 0 or point.y < 0 or point.x >= width or point.y >= height:
			continue
		var index := point.y * width + point.x
		if visited[index]:
			continue
		visited[index] = 1
		var color := image.get_pixelv(point)
		if color.a > 0.0 and color_distance(color, background) > tolerance:
			continue
		image.set_pixelv(point, TRANSPARENT)
		stack.append(point + Vector2i.RIGHT)
		stack.append(point + Vector2i.LEFT)
		stack.append(point + Vector2i.DOWN)
		stack.append(point + Vector2i.UP)


static func dominant_border_color(image: Image) -> Color:
	var width := image.get_width()
	var height := image.get_height()
	var counts := {}
	var samples := {}
	var border: Array[Vector2i] = []
	for x in width:
		border.append(Vector2i(x, 0))
		border.append(Vector2i(x, height - 1))
	for y in range(1, height - 1):
		border.append(Vector2i(0, y))
		border.append(Vector2i(width - 1, y))
	for point in border:
		var color := image.get_pixelv(point)
		if color.a < 0.5:
			continue
		var key := Vector3i(color.r8 >> 3, color.g8 >> 3, color.b8 >> 3)
		counts[key] = counts.get(key, 0) + 1
		samples[key] = color
	var best_key: Variant = null
	for key: Vector3i in counts:
		if best_key == null or counts[key] > counts[best_key]:
			best_key = key
	return TRANSPARENT if best_key == null else samples[best_key]


static func binarize_alpha(image: Image) -> void:
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			if color.a < 0.5:
				image.set_pixel(x, y, TRANSPARENT)
			elif color.a < 1.0:
				color.a = 1.0
				image.set_pixel(x, y, color)


## Deterministic k-means over the opaque pixels (seeded by luminance spread, trained on a
## bounded subsample so large canvases stay responsive).
static func kmeans_palette(image: Image, k: int, iterations := 10) -> PackedColorArray:
	var samples: Array[Vector3] = []
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			if color.a > 0.0:
				samples.append(Vector3(color.r, color.g, color.b))
	if samples.is_empty():
		return PackedColorArray()
	if samples.size() > MAX_TRAINING_SAMPLES:
		var stride := float(samples.size()) / MAX_TRAINING_SAMPLES
		var reduced: Array[Vector3] = []
		for i in MAX_TRAINING_SAMPLES:
			reduced.append(samples[int(i * stride)])
		samples = reduced
	k = mini(k, samples.size())
	var by_luma := samples.duplicate()
	by_luma.sort_custom(func(a: Vector3, b: Vector3) -> bool: return a.dot(LUMA) < b.dot(LUMA))
	var centers: Array[Vector3] = []
	for i in k:
		centers.append(by_luma[int((i + 0.5) * by_luma.size() / k)])
	for _iteration in iterations:
		var sums: Array[Vector3] = []
		sums.resize(k)
		sums.fill(Vector3.ZERO)
		var counts := PackedInt32Array()
		counts.resize(k)
		for sample in samples:
			var nearest := _nearest_center(centers, sample)
			sums[nearest] += sample
			counts[nearest] += 1
		for i in k:
			if counts[i] > 0:
				centers[i] = sums[i] / counts[i]
	var palette := PackedColorArray()
	for center in centers:
		var color := Color(center.x, center.y, center.z)
		if not palette.has(color):
			palette.append(color)
	return palette


static func map_to_palette(image: Image, palette: PackedColorArray) -> void:
	var opaque := PackedColorArray()
	for color in palette:
		if color.a > 0.0:
			opaque.append(Color(color, 1.0))
	if opaque.is_empty():
		return
	var cache := {}
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			if color.a == 0.0:
				continue
			var key := color.to_rgba32()
			if not cache.has(key):
				cache[key] = _nearest_color(opaque, color)
			image.set_pixel(x, y, cache[key])


static func color_distance(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()


static func _nearest_center(centers: Array[Vector3], sample: Vector3) -> int:
	var best := 0
	var best_distance := INF
	for i in centers.size():
		var distance := centers[i].distance_squared_to(sample)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best


static func _nearest_color(palette: PackedColorArray, color: Color) -> Color:
	var best := palette[0]
	var best_distance := INF
	for candidate in palette:
		var distance := color_distance(candidate, color)
		if distance < best_distance:
			best_distance = distance
			best = candidate
	return best
