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
## If the key hasn't been created before, which should be it's default value?
@export var defaultValue: String

@export_category("Nodes - DONT CHANGE")
@export var _textEdit: TextEdit
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
		_textEdit.text = defaultValue
	elif !(init_v is String):
		# if the key is not text, fuss about it!
		push_error("Key '%s' is not a string! input widgets are not made for these!" % [key])
		# for the sake of preventing confusion, we won't initiate the variable on
		# failure to load. instead, make sure you're not mixing up key types and widgets!
		###_init_variable(true)
	else:
		_textEdit.text = init_v

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
		_textEdit.text_changed.connect(_on_text_edit_changed)
		GlobalVariable.dataNuked.connect(_read_refresh)

var _ignore_next_change: bool = false
func _read_refresh() -> void:
	# currently calling this when we nuke our config to
	# correctly display all values.
	_ignore_next_change = true
	refresh()

func _on_text_edit_changed() -> void:
	if _ignore_next_change:
		_ignore_next_change = false
		return

	var v = _textEdit.text
	gbData.settings.set(key, v)
	print("Key '%s' [%s] set to '%s'" % [label, key, v])
	gbData.SettingsChanged.emit()
