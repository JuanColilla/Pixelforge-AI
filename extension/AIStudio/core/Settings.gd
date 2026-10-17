extends RefCounted
## Persistent AI Studio settings, stored in Pixelorama's user data folder (never in the project).

const DIR := "user://ai_studio"
const PATH := DIR + "/settings.cfg"
const SECTION := "ai_studio"
const EXTENSION_RES_DIR := "res://src/Extensions/AIStudio"

const DEFAULTS := {
	"comfy_url": "http://127.0.0.1:8188",
	"comfy_workflow_path": "",
	"comfy_unet": "z_image_turbo_bf16.safetensors",
	"comfy_clip": "qwen_3_4b.safetensors",
	"comfy_vae": "ae.safetensors",
	"comfy_steps": 8,
	"pixellab_token": "",
	"grok_path": "",
	"claude_path": "",
	"claude_model": "sonnet",
	"uv_path": "",
	"mcp_dir": "",
	"bridge_enabled": true,
	"bridge_port": 47821,
	"generation_timeout_sec": 600,
	"panel_introduced": false,
}

var _config := ConfigFile.new()


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(DIR)
	_config.load(PATH)


func get_value(key: String) -> Variant:
	return _config.get_value(SECTION, key, DEFAULTS.get(key))


func set_value(key: String, value: Variant) -> void:
	_config.set_value(SECTION, key, value)


func save() -> void:
	_config.save(PATH)
	FileAccess.set_unix_permissions(
		ProjectSettings.globalize_path(PATH),
		FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER
	)


func pixellab_token() -> String:
	var from_env := OS.get_environment("PIXELLAB_API_TOKEN").strip_edges()
	if not from_env.is_empty():
		return from_env
	return str(get_value("pixellab_token")).strip_edges()


## PixelLab is optional: without a token none of its UI, tools or network calls exist.
func pixellab_connected() -> bool:
	return not pixellab_token().is_empty()


## Returns the configured executable, or the first match in the usual install folders.
## Apps launched from Finder get a minimal PATH, so the folders are probed explicitly.
func resolve_executable(key: String, names: PackedStringArray) -> String:
	var configured := str(get_value(key))
	if not configured.is_empty():
		return configured
	var home := OS.get_environment("HOME")
	var folders := [
		home.path_join(".local/bin"),
		home.path_join(".grok/bin"),
		home.path_join(".cargo/bin"),
		"/opt/homebrew/bin",
		"/usr/local/bin",
		"/usr/bin",
	]
	for folder: String in folders:
		for executable_name in names:
			var candidate := folder.path_join(executable_name)
			if FileAccess.file_exists(candidate):
				return candidate
	return ""


## The MCP server lives next to the extension sources in the repository. In development the
## extension folder is a symlink into the repo, so the repo root is found by following it.
func resolve_mcp_dir() -> String:
	var configured := str(get_value("mcp_dir"))
	if not configured.is_empty():
		return configured
	var extension_dir := ProjectSettings.globalize_path(EXTENSION_RES_DIR)
	var parent := extension_dir.get_base_dir()
	var dir := DirAccess.open(parent)
	if dir == null or not dir.is_link(extension_dir.get_file()):
		return ""
	var target := dir.read_link(extension_dir.get_file())
	if target.is_relative_path():
		target = parent.path_join(target).simplify_path()
	var candidate := target.get_base_dir().get_base_dir().path_join("mcp")
	return candidate if DirAccess.dir_exists_absolute(candidate) else ""


func job_dir(prefix: String) -> String:
	var name := "%s-%d-%d" % [prefix, int(Time.get_unix_time_from_system()), randi() % 100000]
	var path := ProjectSettings.globalize_path(DIR.path_join("jobs").path_join(name))
	DirAccess.make_dir_recursive_absolute(path)
	return path
