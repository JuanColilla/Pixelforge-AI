extends RefCounted
## Background removal with Apple Vision subject lifting, through the tools/subject-mask helper.
## Runs on the full-resolution generated image so the mask is computed before downscaling.

const Http := preload("Http.gd")
const ProcessRunner := preload("../providers/ProcessRunner.gd")
const TIMEOUT_SEC := 60.0

var settings: RefCounted
var host: Node
var _runner := ProcessRunner.new()


func _init(settings_store: RefCounted, host_node: Node) -> void:
	settings = settings_store
	host = host_node


## Returns {"image": Image} with the background cleared to alpha, {"error": String} or
## {"cancelled": true}.
func lift(source: Image) -> Dictionary:
	var helper: String = settings.resolve_subject_mask()
	if helper.is_empty():
		return {"error": "subject-mask helper not found"}
	var work_dir: String = settings.job_dir("mask")
	var input_path := work_dir.path_join("source.png")
	var output_path := work_dir.path_join("masked.png")
	if source.save_png(input_path) != OK:
		return {"error": "could not write the image for subject-mask"}
	var result := await _runner.run(
		host, helper, PackedStringArray([input_path, output_path]), work_dir, TIMEOUT_SEC
	)
	if result.has("error"):
		if result.error == "cancelled":
			return {"cancelled": true}
		return {"error": "subject-mask: %s" % result.error}
	if result.exit_code != 0 or not FileAccess.file_exists(output_path):
		return {
			"error":
			"subject-mask failed (exit %d): %s" % [result.exit_code, str(result.stderr).strip_edges()]
		}
	var image := Http.decode_image(FileAccess.get_file_as_bytes(output_path))
	if image == null:
		return {"error": "subject-mask produced an unreadable image"}
	image.convert(Image.FORMAT_RGBA8)
	# Vision clears the background to transparent black; without this, downscaling bleeds a
	# dark fringe into the sprite's outline.
	image.fix_alpha_edges()
	return {"image": image}


func cancel() -> void:
	_runner.cancel()
