extends Node
## AI Studio entry point: wires settings, canvas operations, the generator, the MCP bridge
## and the dock panel, and removes everything again when the extension is disabled.

const Settings := preload("core/Settings.gd")
const CanvasOps := preload("core/CanvasOps.gd")
const Generator := preload("core/Generator.gd")
const BridgeServer := preload("bridge/BridgeServer.gd")
const StudioPanel := preload("ui/StudioPanel.gd")
const Translations := preload("core/Translations.gd")

var api: Node
var settings: RefCounted
var canvas: RefCounted
var generator: Node
var bridge: Node
var panel: Control
var translation: Translation


func _enter_tree() -> void:
	api = get_node_or_null("/root/ExtensionsApi")
	if api == null:
		push_error("AI Studio: ExtensionsApi not found")
		return
	# Pixelorama pauses the scene tree while unfocused; the bridge and running generations
	# must keep working while the user is in another app (e.g. talking to Claude).
	process_mode = Node.PROCESS_MODE_ALWAYS
	translation = Translations.spanish()
	TranslationServer.add_translation(translation)
	settings = Settings.new()
	canvas = CanvasOps.new(api)

	generator = Generator.new()
	generator.name = "Generator"
	generator.setup(settings, canvas)
	add_child(generator)

	bridge = BridgeServer.new()
	bridge.name = "Bridge"
	bridge.setup(settings, canvas, generator)
	add_child(bridge)
	if bool(settings.get_value("bridge_enabled")) and bridge.start() == OK:
		generator.bridge_file = bridge.info_file_path()
	bridge.state_changed.connect(
		func(listening: bool, _message: String) -> void:
			generator.bridge_file = bridge.info_file_path() if listening else ""
	)

	panel = StudioPanel.new()
	panel.setup(settings, canvas, generator, bridge)
	_add_panel()


## Saved layouts don't know the panel, so the first time it is unhidden and brought to the
## front of its tab group; afterwards the user's own layout decides where it lives.
func _add_panel() -> void:
	await api.panel.add_node_as_tab(panel)
	if bool(settings.get_value("panel_introduced")):
		return
	var dockable: DockableContainer = api.general.get_global().control.find_child("DockableContainer")
	dockable.set_control_hidden(panel, false)
	var tab: DockableLayoutPanel = api.panel._find_tab_with_node(panel.name, dockable)
	if tab:
		tab.current_tab = tab.find_name(panel.name)
	settings.set_value("panel_introduced", true)
	settings.save()


func _exit_tree() -> void:
	if generator:
		generator.cancel()
	if api and is_instance_valid(panel):
		api.panel.remove_node_from_tab(panel)
	if translation:
		TranslationServer.remove_translation(translation)
