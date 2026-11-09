class_name WindowController
extends Node

#note this doesnt support wayland as of the time im writing this so i will get onto that

@onready var root: Control = self.get_parent()

@export_category("Window")
@export var TitleBar: Button
@export var CloseButton: Button
@export var ResizeButton: Button

@export_category("Size Limits")
@export var enableMinimumWindowSize: bool = true
@export var minimumWindowSize = Vector2.ZERO
@export var enableMaximumWindowSize: bool = false
@export var maximumWindowSize = Vector2.INF

@onready var _min = minimumWindowSize if enableMinimumWindowSize else Vector2.ZERO
@onready var _max = maximumWindowSize if enableMaximumWindowSize else Vector2.INF

@export_category("Behavior")
## If 'true', the root will be destroyed when closed.
## If 'false', it will instead be hidden and not interactable with.
@export var killOnClose: bool = false

#### clickArea.gd
var _use_x11_input_regions: bool = false
var _input_region_id: int = 0

var shouldStoreResize: bool = false

var enabled: bool = true:
	set(value):
		enabled = value
		root.visible = value
		_sync_contribution()

# clickthrough
var cur: bool = false
var contributing: bool = false

# controller
var _is_dragging_window: bool = false
var _is_resizing_window: bool = false
## Vector taken from the user's cursor to properly position the window.
var _cursor_offset: Vector2 = Vector2(0, 0)

func window_drag() -> void:
	root.global_position = root.get_global_mouse_position() - _cursor_offset

func window_resize(size_target = null, force: bool = false) -> void:
	# note: so this works but i want the size to offset the position
	# of where the user clicked the resize button so it doesnt snap on
	# resize, but im like way too stupid to figure that out right now
	if size_target == null or !size_target is Vector2:
		size_target = root.get_local_mouse_position() - _cursor_offset

	if force:
		root.size = size_target
	else:
		# clamping to prevent comically small or big windows
		root.size = Vector2(
			min(max(size_target.x, _min.x), _max.x),
			min(max(size_target.y, _min.y), _max.y)
		)

func _can_alter_window() -> bool:
	return !_is_dragging_window && !_is_resizing_window

func _ready() -> void:
	_use_x11_input_regions = TransparentWindow.UsesInputRegions()
	_input_region_id = get_instance_id()
	# link root window visibility to our contribution enabled logic
	root.visibility_changed.connect(_update_enabled)
	_update_enabled()

	# make sure our starting size fits within our boundaries
	window_resize(root.size)
	# link window buttons' calls to our window functions
	if TitleBar:
		TitleBar.button_down.connect(_on_title_bar_button_down)
		TitleBar.button_up.connect(_on_title_bar_button_up)
	if ResizeButton:
		ResizeButton.button_down.connect(_on_resize_button_down)
		ResizeButton.button_up.connect(_on_resize_button_up)
	if CloseButton:
		CloseButton.pressed.connect(_on_close_pressed)

func _update_enabled() -> void:
	enabled = root.visible

func _process(_delta: float) -> void:
	####clickthrough.gd
	if _use_x11_input_regions:
		TransparentWindow.SetInputRect(
			_input_region_id,
			root.get_global_rect().grow(2.0),
			enabled and root.is_visible_in_tree()
		)
	else:
		var mouse_pos: Vector2 = root.get_global_mouse_position()
		var inside: bool = (
			mouse_pos.x >= root.global_position.x and
			mouse_pos.x <= root.global_position.x + root.size.x and
			mouse_pos.y >= root.global_position.y and
			mouse_pos.y <= root.global_position.y + root.size.y
		)
		change(inside)

	if _is_dragging_window: window_drag()
	if _is_resizing_window: window_resize()
# window passthrough logic

func change(t: bool) -> void:
	if t == cur:
		return
	cur = t
	if gbData.devMode:
		print(t)
	_sync_contribution()

func _sync_contribution() -> void:
	var should_contribute: bool = cur and enabled
	if should_contribute == contributing:
		return
	contributing = should_contribute
	GlobalVariable.clickZoneSum += 1 if contributing else -1
	if gbData.devMode:
		print(GlobalVariable.clickZoneSum)
	TransparentWindow.SetClickThrough(GlobalVariable.clickZoneSum <= 0)

# drag window when holding onto the titlebar
func _on_title_bar_button_down() -> void:
	if !_can_alter_window():
		return
	_is_dragging_window = true
	root.move_to_front()

	_cursor_offset = root.get_global_mouse_position() - root.global_position

func _on_title_bar_button_up() -> void:
	_is_dragging_window = false

# resize window when holding onto the resize button
func _on_resize_button_down() -> void:
	if !_can_alter_window():
		return
	_is_resizing_window = true
	root.move_to_front()
	var lmpos = root.get_local_mouse_position()
	_cursor_offset = lmpos - root.size

func _on_resize_button_up() -> void:
	_is_resizing_window = false
	# if told to, save new size to our config, pronto!
	if shouldStoreResize:
		gbData.settings.ConsoleSize.x = root.size.x
		gbData.settings.ConsoleSize.y = root.size.y
		gbData.savetodisk("user://CONFIG.json", gbData.settings)

func _on_close_pressed() -> void:
	enabled = false
	# stop the project if the root node is us (which means we're testing a window scene!)
	if get_tree().current_scene == root:
		get_tree().quit()
	elif killOnClose:
		root.queue_free()
