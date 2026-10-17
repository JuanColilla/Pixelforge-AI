extends ScrollContainer
## The "AI Studio" dock: prompt, engine, output options and settings.

const Generator := preload("../core/Generator.gd")
const TARGET_LABELS := {
	"new_layer": "New layer",
	"current_cel": "Current cel",
	"new_frame": "New frame",
}
const TEXT_SETTINGS := [
	["comfy_url", "ComfyUI URL", false],
	["comfy_workflow_path", "Custom workflow (API JSON)", false],
	["pixellab_token", "PixelLab API token", true],
	["grok_path", "Grok CLI path", false],
	["claude_path", "Claude CLI path", false],
	["claude_model", "Claude model", false],
	["uv_path", "uv path", false],
	["mcp_dir", "pixelorama-mcp folder", false],
]

var settings: RefCounted
var canvas: RefCounted
var generator: Node
var bridge: Node

var _engine: OptionButton
var _prompt: TextEdit
var _width: SpinBox
var _height: SpinBox
var _colors: SpinBox
var _use_palette: CheckBox
var _remove_background: CheckBox
var _target: OptionButton
var _seed: SpinBox
var _generate: Button
var _cancel: Button
var _status: Label
var _bridge_status: Label
var _settings_box: VBoxContainer
var _setting_fields := {}
var _bridge_port: SpinBox
var _bridge_enabled: CheckBox
var _size_dependent: Array[Control] = []


func setup(settings_store: RefCounted, canvas_ops: RefCounted, generator_node: Node, bridge_node: Node) -> void:
	settings = settings_store
	canvas = canvas_ops
	generator = generator_node
	bridge = bridge_node
	name = "AI Studio"


func _ready() -> void:
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	custom_minimum_size = Vector2(240, 0)
	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 6)
	add_child(root)

	_engine = OptionButton.new()
	for key: String in Generator.ENGINE_LABELS:
		_engine.add_item(tr(Generator.ENGINE_LABELS[key]))
		_engine.set_item_metadata(_engine.item_count - 1, key)
	_engine.item_selected.connect(_on_engine_selected)
	root.add_child(_labeled(tr("Engine"), _engine))

	_prompt = TextEdit.new()
	_prompt.placeholder_text = tr("Describe the sprite, tile or scene…")
	_prompt.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_prompt.custom_minimum_size = Vector2(0, 90)
	root.add_child(_prompt)

	var size_row := HBoxContainer.new()
	_width = _spin(1, 1024, 64)
	_height = _spin(1, 1024, 64)
	var canvas_size := Button.new()
	canvas_size.text = tr("Canvas")
	canvas_size.tooltip_text = tr("Use the current canvas size")
	canvas_size.pressed.connect(_use_canvas_size)
	size_row.add_child(_width)
	size_row.add_child(_text_label("×"))
	size_row.add_child(_height)
	size_row.add_child(canvas_size)
	var size_container := _labeled(tr("Size"), size_row)
	root.add_child(size_container)

	_colors = _spin(0, 62, 16)
	_colors.tooltip_text = tr("Maximum colors after quantization (0 keeps all colors)")
	var colors_container := _labeled(tr("Colors"), _colors)
	root.add_child(colors_container)

	_use_palette = CheckBox.new()
	_use_palette.text = tr("Use current palette")
	root.add_child(_use_palette)

	_remove_background = CheckBox.new()
	_remove_background.text = tr("Remove background")
	_remove_background.button_pressed = true
	root.add_child(_remove_background)

	_target = OptionButton.new()
	for key: String in TARGET_LABELS:
		_target.add_item(tr(TARGET_LABELS[key]))
		_target.set_item_metadata(_target.item_count - 1, key)
	var target_container := _labeled(tr("Place in"), _target)
	root.add_child(target_container)

	_seed = _spin(-1, 2147483647, -1)
	_seed.tooltip_text = tr("-1 picks a random seed")
	var seed_container := _labeled(tr("Seed"), _seed)
	root.add_child(seed_container)

	_size_dependent = [
		size_container, colors_container, _use_palette, _remove_background, target_container, seed_container
	]

	var actions := HBoxContainer.new()
	_generate = Button.new()
	_generate.text = tr("Generate")
	_generate.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_generate.pressed.connect(_on_generate_pressed)
	_cancel = Button.new()
	_cancel.text = tr("Cancel")
	_cancel.disabled = true
	_cancel.pressed.connect(generator.cancel)
	actions.add_child(_generate)
	actions.add_child(_cancel)
	root.add_child(actions)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_status)

	root.add_child(HSeparator.new())
	var settings_toggle := Button.new()
	settings_toggle.text = tr("Settings")
	settings_toggle.toggle_mode = true
	settings_toggle.toggled.connect(func(on: bool) -> void: _settings_box.visible = on)
	root.add_child(settings_toggle)
	_settings_box = _build_settings()
	_settings_box.visible = false
	root.add_child(_settings_box)

	_bridge_status = Label.new()
	_bridge_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bridge_status.modulate = Color(1, 1, 1, 0.7)
	root.add_child(_bridge_status)

	generator.status_changed.connect(_on_status_changed)
	bridge.state_changed.connect(func(_listening: bool, message: String) -> void: _bridge_status.text = message)
	_bridge_status.text = (
		tr("MCP bridge listening on 127.0.0.1:%d") % bridge.port
		if bridge.is_listening()
		else tr("MCP bridge off")
	)
	_use_canvas_size.call_deferred()


func _build_settings() -> VBoxContainer:
	var box := VBoxContainer.new()
	for entry: Array in TEXT_SETTINGS:
		var field := LineEdit.new()
		field.text = str(settings.get_value(entry[0]))
		field.secret = entry[2]
		field.placeholder_text = tr("auto") if entry[0].ends_with("_path") or entry[0] == "mcp_dir" else ""
		_setting_fields[entry[0]] = field
		box.add_child(_labeled(tr(entry[1]), field, true))
	_bridge_enabled = CheckBox.new()
	_bridge_enabled.text = tr("Enable MCP bridge")
	_bridge_enabled.button_pressed = bool(settings.get_value("bridge_enabled"))
	box.add_child(_bridge_enabled)
	_bridge_port = _spin(1024, 65535, int(settings.get_value("bridge_port")))
	box.add_child(_labeled(tr("Bridge port"), _bridge_port))
	var save := Button.new()
	save.text = tr("Save settings")
	save.pressed.connect(_on_save_settings)
	box.add_child(save)
	return box


func _on_save_settings() -> void:
	for key: String in _setting_fields:
		settings.set_value(key, (_setting_fields[key] as LineEdit).text.strip_edges())
	var port_changed := int(_bridge_port.value) != int(settings.get_value("bridge_port"))
	var enabled_changed := _bridge_enabled.button_pressed != bool(settings.get_value("bridge_enabled"))
	settings.set_value("bridge_port", int(_bridge_port.value))
	settings.set_value("bridge_enabled", _bridge_enabled.button_pressed)
	settings.save()
	if port_changed or enabled_changed:
		if _bridge_enabled.button_pressed:
			bridge.start()
		else:
			bridge.stop()
	_status.text = tr("Settings saved")


func _on_generate_pressed() -> void:
	var request := {
		"engine": _engine.get_item_metadata(_engine.selected),
		"prompt": _prompt.text,
		"width": int(_width.value),
		"height": int(_height.value),
		"colors": int(_colors.value),
		"use_palette": _use_palette.button_pressed,
		"remove_background": _remove_background.button_pressed,
		"target": _target.get_item_metadata(_target.selected),
		"seed": int(_seed.value),
	}
	var result: Dictionary = await generator.generate(request)
	if result.has("message"):
		_status.text = str(result.message)


func _on_status_changed(text: String, busy: bool) -> void:
	_status.text = text
	_generate.disabled = busy
	_cancel.disabled = not busy


func _on_engine_selected(index: int) -> void:
	var is_agent: bool = _engine.get_item_metadata(index) == "claude_agent"
	for control in _size_dependent:
		control.visible = not is_agent


func _use_canvas_size() -> void:
	var info: Dictionary = canvas.project_info()
	_width.value = info.width
	_height.value = info.height


func _labeled(text: String, control: Control, stacked := false) -> Control:
	var container: BoxContainer = VBoxContainer.new() if stacked else HBoxContainer.new()
	var label := _text_label(text)
	if not stacked:
		label.custom_minimum_size = Vector2(70, 0)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(label)
	container.add_child(control)
	return container


func _text_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


func _spin(min_value: float, max_value: float, value: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.value = value
	spin.allow_greater = false
	return spin
