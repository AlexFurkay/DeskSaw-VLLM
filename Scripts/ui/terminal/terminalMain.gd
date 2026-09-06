extends Panel

@export_category("Window")
@export var windowControl: WindowController

@export_category("Submenus")
@export var submenuButton: OptionButton
## Panels linked to the submenu picker options.
## Note that they have to be the same amount and in the same order as assigned to the SubmenuPîcker node.
@export var submenuPanels: Array[Node]

func _ready() -> void:
	# terminal things
	windowControl.shouldStoreResize = true

	# show first (console) window by default
	submenuButton.item_selected.connect(_on_submenu_picker_item_selected)
	_on_submenu_picker_item_selected(0)

	GlobalVariable.TerminalOpenPressed.connect(_on_terminal_open_press)
	CommandsGlobal.resizeCommandCalled.connect(_resize_console)
	if ( # added this stupid check because i broke things and got scared
		gbData.settings
		and gbData.settings.ConsoleSize
		and gbData.settings.ConsoleSize.x
		and gbData.settings.ConsoleSize.y
	):
		_resize_console(Vector2(gbData.settings.ConsoleSize.x,gbData.settings.ConsoleSize.y), false)
		print("%s: initial resize called properly!" % [name])
	
	CommandsGlobal.runInitialCommands.emit()

## Resizes the console using stored data variables
func _resize_console(v, force) -> void:
	windowControl.window_resize(v, force)

func _on_terminal_open_press(_is_native: bool) -> void:
	# is_native defines if it was called via an input (true)
	# or by clicking on an expie (false)
	# we currently don't do much with this information, but you
	# could add additional logic if you want.
	if _is_native:
		visible = !visible
	else:
		visible = true

func _on_submenu_picker_item_selected(index: int) -> void:
	for i in submenuPanels.size():
		if index == i:
			submenuPanels[i].show()
			continue
		submenuPanels[i].hide()
