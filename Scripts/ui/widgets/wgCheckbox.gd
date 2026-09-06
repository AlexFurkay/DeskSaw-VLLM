@tool
extends PanelContainer

@export_category("Settings")

## Text to be shown alongside the checkbox.
@export_multiline var label: String:
	set(new_label):
		label = new_label
		_update_label()
## Config. key to change when switching the checkbox.
@export var key: String
## If true, the value will be inverted (checked: false, unchecked: true)
@export var flipValue: bool
## If the key hasn't been created before, which should be it's default value?
@export var defaultValue: bool

@export_category("Nodes - DONT CHANGE")
@export var _checkbox: CheckBox
@export var _label: RichTextLabel

func _update_label() -> void:
	# this function is called before the label can ready up, which is
	# prettyy annoying. couldn't find a proper way to call this once.
	if not _label:
		return
	_label.text = label

func _update_state() -> void:
	var init_v = gbData.settings.get(key)
	if init_v == null:
		# if the key doesn't exist, create it!
		_init_variable(false)
		_checkbox.button_pressed = defaultValue
	elif !(init_v is bool):
		# if the key is not a boolean, fuss about it!
		push_error("Key '%s' is not a boolean! checkbox widgets are not made for these!" % [key])
		# for the sake of preventing confusion, we won't initiate the variable on
		# failure to load. instead, make sure you're not mixing up key types and widgets!
		###_init_variable(true)
	else:
		# update starting pressed state according to value
		var v: bool = !init_v if flipValue else init_v
		_checkbox.button_pressed = v

func _init_variable(save: bool = false) -> void:
	gbData.settings.set(key, defaultValue)
	if save:
		gbData.savetodisk(gbData.conPath, gbData.settings)

func refresh() -> void:
	_update_label()
	_update_state()

func _ready() -> void:
	if not Engine.is_editor_hint():
		refresh()
		_checkbox.toggled.connect(_on_check_box_toggled)
		GlobalVariable.dataNuked.connect(_read_refresh)

var _ignore_next_change: bool = false
func _read_refresh() -> void:
	# currently calling this when we nuke our config to
	# correctly display all values.
	_ignore_next_change = true
	refresh()

func _on_check_box_toggled(v: bool) -> void:
	if _ignore_next_change:
		_ignore_next_change = false
		return

	if flipValue:
		v = !v
	gbData.settings.set(key, v)
	print("Key '%s' [%s] set to '%s'" % [label, key, v])
	# save!
	gbData.savetodisk(gbData.conPath, gbData.settings)
	gbData.SettingsChanged.emit()
