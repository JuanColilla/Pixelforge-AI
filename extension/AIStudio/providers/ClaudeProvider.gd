extends RefCounted
## Claude CLI has no image model, so it works in two ways:
## - pixels: Claude returns the sprite itself as structured JSON (palette + base62 rows).
## - agent: Claude drives Pixelorama through the pixelorama-mcp tools and draws directly.

const PixelGrid := preload("../core/PixelGrid.gd")
const ProcessRunner := preload("ProcessRunner.gd")

const MAX_PIXEL_SIDE := 128
const PIXEL_SCHEMA := {
	"type": "object",
	"properties":
	{
		"palette": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 62},
		"rows": {"type": "array", "items": {"type": "string"}},
	},
	"required": ["palette", "rows"],
}

var settings: RefCounted
var host: Node
var _runner := ProcessRunner.new()


func _init(settings_store: RefCounted, host_node: Node) -> void:
	settings = settings_store
	host = host_node


func generate_pixels(request: Dictionary) -> Dictionary:
	var size: Vector2i = request.size
	if size.x > MAX_PIXEL_SIDE or size.y > MAX_PIXEL_SIDE:
		return {
			"error":
			"Claude pixel mode draws up to %d×%d; use another engine for larger canvases"
			% [MAX_PIXEL_SIDE, MAX_PIXEL_SIDE]
		}
	var claude: String = settings.resolve_executable("claude_path", ["claude"])
	if claude.is_empty():
		return {"error": "Claude CLI not found; set its path in AI Studio settings"}
	var work_dir: String = settings.job_dir("claude")
	var arguments := PackedStringArray(
		[
			"-p",
			_pixel_prompt(request),
			"--output-format",
			"json",
			"--json-schema",
			JSON.stringify(PIXEL_SCHEMA),
			"--model",
			str(settings.get_value("claude_model")),
			"--strict-mcp-config",
			"--no-session-persistence",
		]
	)
	var result := await _runner.run(
		host, claude, arguments, work_dir, float(settings.get_value("generation_timeout_sec"))
	)
	var data := _parse_cli_result(result)
	if data.has("error"):
		return data
	var output: Variant = data.get("structured_output")
	if typeof(output) != TYPE_DICTIONARY:
		return {"error": "Claude did not return structured pixel data"}
	var palette := PixelGrid.parse_palette(output.get("palette", []))
	if palette.has("error"):
		return {"error": "Claude: %s" % palette.error}
	var image := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	PixelGrid.paint(image, Vector2i.ZERO, palette.palette, PackedStringArray(output.get("rows", [])))
	return {"image": image}


func run_agent(request: Dictionary, bridge_file: String) -> Dictionary:
	var claude: String = settings.resolve_executable("claude_path", ["claude"])
	var uv: String = settings.resolve_executable("uv_path", ["uv"])
	var mcp_dir: String = settings.resolve_mcp_dir()
	if claude.is_empty() or uv.is_empty() or mcp_dir.is_empty():
		return {"error": "agent mode needs Claude CLI, uv and the MCP folder (see AI Studio settings)"}
	var work_dir: String = settings.job_dir("claude-agent")
	var config_path := work_dir.path_join("mcp.json")
	var config := {
		"mcpServers":
		{
			"pixelorama":
			{
				"command": uv,
				"args": ["run", "--quiet", "--directory", mcp_dir, "pixelorama-mcp"],
				"env": {"PIXELORAMA_BRIDGE_FILE": bridge_file},
			}
		}
	}
	var file := FileAccess.open(config_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(config, "\t"))
	file.close()
	var prompt := (
		"You are a pixel artist working inside the Pixelorama editor through the `pixelorama` "
		+ "MCP tools. Task: %s\n\n"
		+ "Start with get_project_info and view_canvas. Draw on a new layer unless the task says "
		+ "otherwise. Group drawing into few batch calls (grid for shapes, then lines and pixels "
		+ "for details); each batch is one undo step. Look at your "
		+ "work with view_canvas after each major step and fix what looks wrong. Finish with a "
		+ "short summary of what you drew."
	) % request.prompt
	var arguments := PackedStringArray(
		[
			"-p",
			prompt,
			"--output-format",
			"json",
			"--model",
			str(settings.get_value("claude_model")),
			"--mcp-config",
			config_path,
			"--strict-mcp-config",
			"--allowedTools",
			"mcp__pixelorama",
			"--no-session-persistence",
		]
	)
	var result := await _runner.run(
		host, claude, arguments, work_dir, float(settings.get_value("generation_timeout_sec"))
	)
	var data := _parse_cli_result(result)
	if data.has("error"):
		return data
	return {"message": str(data.get("result", ""))}


func cancel() -> void:
	_runner.cancel()


func _pixel_prompt(request: Dictionary) -> String:
	var size: Vector2i = request.size
	var max_colors: int = request.colors if request.colors > 0 else 16
	var lines := PackedStringArray(
		[
			"You are an expert pixel artist. Draw: %s" % request.prompt,
			"",
			"Canvas: exactly %d pixels wide and %d pixels tall." % [size.x, size.y],
			"Return JSON with:",
			"- palette: at most %d colors as hex RRGGBBAA strings." % (max_colors + 1),
			'  palette[0] must be "00000000" (transparent background).',
			"- rows: exactly %d strings, each exactly %d characters long." % [size.y, size.x],
			"  Each character is a palette index in base62: 0-9, then a-z (10-35), then A-Z (36-61).",
			"",
			"Pixel-art rules: readable silhouette that fills most of the canvas, 1px darker",
			"outline, light from the top-left, 2-4 shades per material, no anti-aliasing,",
			"no orphan pixels, transparent background around the subject.",
		]
	)
	var palette: PackedColorArray = request.palette
	if not palette.is_empty():
		var hex := PackedStringArray()
		for color in palette:
			hex.append(Color(color, 1.0).to_html(false))
		lines.append("Use only these colors (plus transparent): %s" % ", ".join(hex))
	return "\n".join(lines)


static func _parse_cli_result(result: Dictionary) -> Dictionary:
	if result.has("error"):
		return {"error": "Claude: %s" % result.error}
	var data: Variant = JSON.parse_string(str(result.stdout))
	if typeof(data) != TYPE_DICTIONARY:
		var details := str(result.stderr).strip_edges()
		if details.is_empty():
			details = str(result.stdout).left(400)
		return {"error": "Claude CLI failed (exit %d): %s" % [result.exit_code, details]}
	if data.get("is_error", false):
		return {"error": "Claude: %s" % str(data.get("result", "unknown error")).left(400)}
	return data
