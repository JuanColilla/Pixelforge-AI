extends RefCounted
## Remote generation through the Grok CLI's image_gen tool (xAI Imagine), run headless.
## Grok saves the result into a private job folder, which is then loaded and pixelized.

const Http := preload("../core/Http.gd")
const ProcessRunner := preload("ProcessRunner.gd")
const ComfyUIProvider := preload("ComfyUIProvider.gd")

var settings: RefCounted
var host: Node
var _runner := ProcessRunner.new()


func _init(settings_store: RefCounted, host_node: Node) -> void:
	settings = settings_store
	host = host_node


func generate(request: Dictionary) -> Dictionary:
	var grok: String = settings.resolve_executable("grok_path", ["grok"])
	if grok.is_empty():
		return {"error": "Grok CLI not found; set its path in AI Studio settings"}
	var work_dir: String = settings.job_dir("grok")
	var output_path := work_dir.path_join("image.png")
	var prompt := (
		"Use the image_gen tool to generate exactly one image: %s. "
		+ "Then save the generated image as a PNG file at this absolute path: %s . "
		+ "Do not create any other files and do not edit the image. Reply with only the path."
	) % [ComfyUIProvider.styled_prompt(request), output_path]
	var arguments := PackedStringArray(
		[
			"-p",
			prompt,
			"--always-approve",
			"--output-format",
			"json",
			"--no-subagents",
			"--no-plan",
			"--disable-web-search",
			"--max-turns",
			"8",
			"--cwd",
			work_dir,
		]
	)
	var result := await _runner.run(
		host, grok, arguments, work_dir, float(settings.get_value("generation_timeout_sec"))
	)
	if result.has("error"):
		return {"error": "Grok: %s" % result.error}
	if not FileAccess.file_exists(output_path):
		var details := str(result.stderr).strip_edges()
		if details.is_empty():
			details = str(result.stdout).left(400)
		return {"error": "Grok did not produce an image (exit %d): %s" % [result.exit_code, details]}
	var image := Http.decode_image(FileAccess.get_file_as_bytes(output_path))
	if image == null:
		return {"error": "Grok produced an unreadable image"}
	return {"image": image}


func cancel() -> void:
	_runner.cancel()
