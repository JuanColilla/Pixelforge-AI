extends ScrollContainer
## The "AI Studio" dock: prompt, engine, output options and settings.

const Generator := preload("../core/Generator.gd")
const PixelLabProvider := preload("../providers/PixelLabProvider.gd")
const TARGET_LABELS := {
	"new_layer": "New layer",
	"current_cel": "Current cel",
	"new_frame": "New frame",
}
const DIRECTION_LABELS := {
	"south": "South",
	"south-east": "South-east",
	"east": "East",
	"north-east": "North-east",
	"north": "North",
	"north-west": "North-west",
	"west": "West",
	"south-west": "South-west",
}
const VIEW_LABELS := {"side": "Side view", "low top-down": "Low top-down", "high top-down": "High top-down"}
const PLACEMENT_LABELS := {"frames": "New frames", "layers": "New layer per direction"}
const TOOL_HINTS := {
	"rotations": "Subject hint (optional)",
	"animate": "Action, e.g. walking",
	"interpolate": "Transition, e.g. powering up",
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
	["subject_mask_path", "Subject mask helper path", false],
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
var _variants: SpinBox
var _generate: Button
var _cancel: Button
var _status: Label
var _bridge_status: Label
var _settings_box: VBoxContainer
var _setting_fields := {}
var _bridge_port: SpinBox
var _bridge_enabled: CheckBox
var _size_dependent: Array[Control] = []
var _pixellab_box: VBoxContainer
var _pixellab_separator: HSeparator
var _tool: OptionButton
var _tool_text: LineEdit
var _frame_count: SpinBox
var _from_direction: OptionButton
var _to_direction: OptionButton
var _view: OptionButton
var _end_frame: SpinBox
var _placement: OptionButton
var _tool_merged: CheckBox
var _tool_remove_background: CheckBox
var _balance: Label
var _run_tool: Button
var _confirm: ConfirmationDialog
var _tool_rows := {}
var _pending_tool := {}


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

	_variants = _spin(1, Generator.MAX_VARIANTS, 1)
	_variants.tooltip_text = tr("Extra variants use the next seeds and land on hidden layers")
	var variants_container := _labeled(tr("Variants"), _variants)
	root.add_child(variants_container)

	_size_dependent = [
		size_container,
		colors_container,
		_use_palette,
		_remove_background,
		target_container,
		seed_container,
		variants_container,
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

	_pixellab_separator = HSeparator.new()
	root.add_child(_pixellab_separator)
	_pixellab_box = _build_pixellab_tools()
	root.add_child(_pixellab_box)

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
	_apply_pixellab_connection()
	_use_canvas_size.call_deferred()


## PixelLab tools that work on the sprite already in the canvas (rotations, animation,
## in-betweens). They spend credits, so each run is confirmed with the current balance.
func _build_pixellab_tools() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_tool = OptionButton.new()
	for key: String in Generator.PIXELLAB_TOOL_LABELS:
		_tool.add_item(tr(Generator.PIXELLAB_TOOL_LABELS[key]))
		_tool.set_item_metadata(_tool.item_count - 1, key)
	_tool.item_selected.connect(func(_index: int) -> void: _update_tool_rows())
	box.add_child(_labeled(tr("Tool"), _tool))

	_tool_text = LineEdit.new()
	box.add_child(_tool_text)

	_frame_count = _spin(PixelLabProvider.ANIMATE_MIN_FRAMES, PixelLabProvider.ANIMATE_MAX_FRAMES, 8)
	_frame_count.step = 2
	var frame_count_row := _labeled(tr("Frames"), _frame_count)
	box.add_child(frame_count_row)

	_from_direction = _options(DIRECTION_LABELS, "south")
	var from_row := _labeled(tr("Facing"), _from_direction)
	box.add_child(from_row)
	_to_direction = _options(DIRECTION_LABELS, "east")
	var to_row := _labeled(tr("Rotate to"), _to_direction)
	box.add_child(to_row)
	_view = _options(VIEW_LABELS, "side")
	var view_row := _labeled(tr("View"), _view)
	box.add_child(view_row)

	_end_frame = _spin(0, 9999, 0)
	_end_frame.tooltip_text = tr("Frame number of the end keyframe; 0 uses the next frame")
	var end_row := _labeled(tr("End frame"), _end_frame)
	box.add_child(end_row)

	_placement = _options(PLACEMENT_LABELS, "frames")
	var placement_row := _labeled(tr("Place in"), _placement)
	box.add_child(placement_row)

	_tool_merged = CheckBox.new()
	_tool_merged.text = tr("Use all visible layers")
	box.add_child(_tool_merged)
	_tool_remove_background = CheckBox.new()
	_tool_remove_background.text = tr("Remove background")
	_tool_remove_background.button_pressed = true
	box.add_child(_tool_remove_background)

	_tool_rows = {
		"rotations": [_tool_text, placement_row, _tool_remove_background],
		"rotate": [from_row, to_row, view_row],
		"animate": [_tool_text, frame_count_row, _tool_remove_background],
		"interpolate": [_tool_text, end_row, _tool_remove_background],
	}

	var actions := HBoxContainer.new()
	_run_tool = Button.new()
	_run_tool.text = tr("Run on current cel")
	_run_tool.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_run_tool.pressed.connect(_on_run_tool_pressed)
	var refresh := Button.new()
	refresh.text = tr("Balance")
	refresh.tooltip_text = tr("Check the PixelLab balance")
	refresh.pressed.connect(_refresh_balance)
	actions.add_child(_run_tool)
	actions.add_child(refresh)
	box.add_child(actions)

	_balance = Label.new()
	_balance.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_balance.modulate = Color(1, 1, 1, 0.7)
	box.add_child(_balance)

	_confirm = ConfirmationDialog.new()
	_confirm.title = tr("PixelLab")
	_confirm.ok_button_text = tr("Run")
	_confirm.confirmed.connect(_on_tool_confirmed)
	add_child(_confirm)
	_update_tool_rows()
	return box


## Without a PixelLab token the panel shows nothing of PixelLab except the token setting.
func _apply_pixellab_connection() -> void:
	var connected: bool = settings.pixellab_connected()
	_pixellab_separator.visible = connected
	_pixellab_box.visible = connected
	if not connected:
		_balance.text = ""
		_pending_tool = {}
		_confirm.hide()
	var selected := ""
	if _engine.item_count > 0:
		selected = _engine.get_item_metadata(_engine.selected)
	_engine.clear()
	for key: String in generator.available_engines():
		_engine.add_item(tr(Generator.ENGINE_LABELS[key]))
		_engine.set_item_metadata(_engine.item_count - 1, key)
		if key == selected:
			_engine.select(_engine.item_count - 1)
	_on_engine_selected(_engine.selected)


func _update_tool_rows() -> void:
	var tool: String = _tool.get_item_metadata(_tool.selected)
	var shown: Array = _tool_rows[tool]
	for rows: Array in _tool_rows.values():
		for control: Control in rows:
			control.visible = control in shown
	_tool_text.placeholder_text = tr(TOOL_HINTS.get(tool, ""))


func _tool_request() -> Dictionary:
	var tool: String = _tool.get_item_metadata(_tool.selected)
	var view: String = _view.get_item_metadata(_view.selected)
	var request := {
		"tool": tool,
		"description": _tool_text.text,
		"frame_count": int(_frame_count.value),
		"from_direction": _from_direction.get_item_metadata(_from_direction.selected),
		"to_direction": _to_direction.get_item_metadata(_to_direction.selected),
		"from_view": view,
		"to_view": view,
		"placement": _placement.get_item_metadata(_placement.selected),
		"merged": _tool_merged.button_pressed,
		"remove_background": _tool_remove_background.button_pressed,
	}
	if int(_end_frame.value) > 0:
		request["end_frame"] = int(_end_frame.value) - 1
	return request


func _on_run_tool_pressed() -> void:
	var request := _tool_request()
	var plan: Dictionary = generator.prepare_pixellab(request)
	if plan.has("error"):
		_status.text = tr("Error: %s") % plan.error
		return
	_run_tool.disabled = true
	_status.text = tr("Checking the PixelLab balance…")
	var balance: Dictionary = await generator.pixellab_balance()
	_run_tool.disabled = generator.is_busy()
	if balance.has("error"):
		_status.text = tr("Error: %s") % balance.error
		return
	_balance.text = _balance_text(balance)
	_status.text = ""
	_pending_tool = request
	var region: Rect2i = plan.region
	_confirm.dialog_text = (
		tr("%s on frame %d, %d×%d px.")
		% [tr(Generator.PIXELLAB_TOOL_LABELS[plan.tool]), plan.frame + 1, region.size.x, region.size.y]
		+ "\n"
		+ _balance.text
		+ "\n"
		+ tr("The cost is shown when it finishes.")
	)
	_confirm.popup_centered()


func _on_tool_confirmed() -> void:
	if _pending_tool.is_empty():
		return
	var request := _pending_tool
	_pending_tool = {}
	await generator.run_pixellab(request)
	_refresh_balance()


func _refresh_balance() -> void:
	var balance: Dictionary = await generator.pixellab_balance()
	_balance.text = tr("Error: %s") % balance.error if balance.has("error") else _balance_text(balance)


func _balance_text(balance: Dictionary) -> String:
	return tr("Balance: $%.2f, %d of %d generations") % [
		balance.usd, int(balance.generations), int(balance.generations_total)
	]


func _options(labels: Dictionary, selected: String) -> OptionButton:
	var options := OptionButton.new()
	for key: String in labels:
		options.add_item(tr(labels[key]))
		options.set_item_metadata(options.item_count - 1, key)
		if key == selected:
			options.select(options.item_count - 1)
	return options


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
	_apply_pixellab_connection()
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
		"variants": int(_variants.value),
	}
	var result: Dictionary = await generator.generate(request)
	if result.has("message"):
		_status.text = str(result.message)


func _on_status_changed(text: String, busy: bool) -> void:
	_status.text = text
	_generate.disabled = busy
	_run_tool.disabled = busy
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
