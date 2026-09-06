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
@export var defaultValue: float

@export_category("Slider Behavior")
@export var sliderMinimum: float = 0.0
@export var sliderMaximum: float = 1.0
@export var sliderStep: float = 0.01

@export_category("Value Behavior")
@export_enum("float","int","percentage") var valueType = "float"

@export_category("Hardcoded")
## Value change triggers an update in volume.
@export var updateVolume: bool = false

@export_category("Nodes - DONT CHANGE")
@export var _slider: Slider
@export var _label: RichTextLabel
@export var _val_label: RichTextLabel

func _update_label() -> void:
	# this function is called before the label can ready up, which is
	# prettyy annoying. couldn't find a proper way to call this once.
	if not _label:
		return
	_label.text = label

func _update_value() -> void:
	var v = _slider.value
	match valueType:
		"int":
			v = roundi(v)
			_val_label.text = "%s" % [v]
		"percentage":
			v = int(v / sliderMaximum * 100)
			_val_label.text = "%s" % [v] + "%"
		_:
			v = snapped(v, 0.01)
			_val_label.text = "%s" % [v]


func _update_state() -> void:
	_slider.step = sliderStep

	var init_v = gbData.settings.get(key)
	if init_v == null:
		# if the key doesn't exist, create it!
		_init_variable(false)
		_slider.value = defaultValue
	elif !(init_v is float or init_v is int):
		# if the key is not a number, fuss about it!
		push_error("Key '%s' is not a number! slider widgets are not made for these!" % [key])
		# for the sake of preventing confusion, we won't initiate the variable on
		# failure to load. instead, make sure you're not mixing up key types and widgets!
		###_init_variable(true)
	else:
		# update starting pressed state according to value
		_slider.value = init_v

	_slider.min_value = sliderMinimum
	_slider.max_value = sliderMaximum

func _init_variable(save: bool = false) -> void:
	gbData.settings.set(key, defaultValue)
	if save:
		gbData.savetodisk(gbData.conPath, gbData.settings)

func refresh() -> void:
	_update_label()
	_update_state()
	_update_value()

func _ready() -> void:
	if not Engine.is_editor_hint():
		refresh()
		_slider.value_changed.connect(_on_slider_changed)
		GlobalVariable.dataNuked.connect(_read_refresh)

var _ignore_next_change: bool = false
func _read_refresh() -> void:
	# currently calling this when we nuke our config to
	# correctly display all values.
	_ignore_next_change = true
	refresh()

func _on_slider_changed(v) -> void:
	_update_value()

	if _ignore_next_change:
		_ignore_next_change = false
		return

	# clamp value to their proper types
	match valueType:
		"int":
			v = roundi(v)
		_:
			v = snapped(v, 0.01) # prevent math goobering

	gbData.settings.set(key, v)
	print("Key '%s' [%s] set to '%s'" % [label, key, v])
	# save!
	gbData.savetodisk(gbData.conPath, gbData.settings)
	gbData.SettingsChanged.emit()

	if updateVolume:
		_update_volume()

func _update_volume() -> void:
	# really ugly way of doing things! mimics previous volume slider 
	# FIXME: actually connect "soundVolume" to AudioManager.
	# 		 maybe make it update via a signal?
	AudioManager.soundMult = gbData.settings.get("soundVolume", 1.0)
