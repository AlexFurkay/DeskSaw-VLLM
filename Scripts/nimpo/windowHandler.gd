extends Control

#window
# On any Control node

@export var Handle: Button
@export var Minimize: Button
@export var Exit: Button

@export var ConsoleN: Control
@export var SettingsN: Control
@export var StatN: Control
@export var SkinsN: Control
@export var ItemsN: Control
@export var ChatN: Control
var offset = Vector2.ZERO
var dragging = false

#border numbers that i stole from somewhere
var global_top_left: Vector2
var global_top_right: Vector2
var global_bottom_left: Vector2
var global_bottom_right: Vector2

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_on_tab_switch_item_selected(0)

	position = Vector2i(GlobalVariable.screenWidth / 2, GlobalVariable.screenHeight / 2)

	global_top_left = global_position
	global_top_right = global_position + Vector2(size.x, 0)
	global_bottom_left = global_position + Vector2(0, size.y)
	global_bottom_right = global_position + size

	GlobalVariable.TerminalOpenPressed.connect(showw)

func _process(_delta: float) -> void:
	if dragging:
		global_position = get_global_mouse_position() - offset

# SIGNAL FROM HANDLE
func _downDrag() -> void:
	if gbData.devMode:
		print("dragging")
	offset = get_global_mouse_position() - global_position
	dragging = true
	move_to_front()

# SIGNAL FROM HANDLE
func _upDrag() -> void:
	dragging = false


func showw() -> void:
	self.visible = true
	$ClickArea.enabled = self.visible
	print("enable")

func _hide(_t: bool) -> void:
	self.visible = false
	$ClickArea.enabled = self.visible


func _on_tab_switch_item_selected(index: int) -> void:
	ConsoleN.visible = false
	SettingsN.visible = false
	SkinsN.visible = false
	ItemsN.visible = false

	print(index)
	match index:
		0:
			ConsoleN.visible = true
			if gbData.devMode:
				print("Console")
		1:
			SettingsN.visible = true
			if gbData.devMode:
				print("Settings")
		2:
			SkinsN.visible = true
			if gbData.devMode:
				print("Skin Change")
		3:
			ItemsN.visible = true
			if gbData.devMode:
				print("Item Change")
