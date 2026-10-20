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
## 054.998: вместо текстового поля - выпадающий список папок персонажей
## (user://skin). Для "скина по умолчанию": имя папки нельзя ввести с ошибкой.
@export var choicesFromSkins: bool = false

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
	elif init_v is int or init_v is float:
		# старые версии сохраняли интервалы числом - поле оставалось пустым
		var num: float = float(init_v)
		_textEdit.text = str(int(num)) if is_equal_approx(num, roundf(num)) else str(num)
		gbData.settings.set(key, _textEdit.text)
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

## 054.9992: в "Игровом режиме" поля интервалов серые и показывают "x2";
## при выключении - снова сохранённые значения (их режим не трогает).
const PACE_KEYS := ["minDialogueTime", "maxDialogueTime", "llmMinInterval", "llmMaxInterval", "petTalkMin", "petTalkMax"]

func _applyGameMode() -> void:
	if not PACE_KEYS.has(key):
		return
	var on: bool = gbData.settings.get("gameMode", false)
	if on and _textEdit.editable:
		_textEdit.editable = false
		_textEdit.modulate = Color(1, 1, 1, 0.45)
		_textEdit.text = "x2"
	elif not on and not _textEdit.editable:
		_textEdit.editable = true
		_textEdit.modulate = Color(1, 1, 1, 1)
		_textEdit.text = str(gbData.settings.get(key, defaultValue))

func _ready() -> void:
	if not Engine.is_editor_hint():
		refresh()
		_textEdit.text_changed.connect(_on_text_edit_changed)
		gbData.SettingsChanged.connect(_applyGameMode)
		_applyGameMode()
		GlobalVariable.dataNuked.connect(_read_refresh)
		if choicesFromSkins:
			_setupSkinChoices()


var _choices: OptionButton

func _setupSkinChoices() -> void:
	_textEdit.visible = false
	_choices = OptionButton.new()
	_choices.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_textEdit.get_parent().add_child(_choices)
	_textEdit.get_parent().move_child(_choices, _textEdit.get_index())
	_fillSkinChoices()
	_choices.item_selected.connect(_on_choice_selected)
	# новые папки скинов могли появиться после запуска - список при каждом открытии
	_choices.get_popup().about_to_popup.connect(_fillSkinChoices)


func _fillSkinChoices() -> void:
	var current := String(gbData.settings.get(key, defaultValue))
	_choices.clear()
	var names: Array = []
	var dir := DirAccess.open("user://skin")
	if dir:
		for d in dir.get_directories():
			if d != "Body" and d != "Default":
				names.append(d)
	names.sort()
	if not names.has(current):
		names.push_front(current) # чужое/старое значение не теряем молча
	for n in names:
		_choices.add_item(n)
	_choices.select(names.find(current))
	# список - отдельное окно, общий масштаб текста консоли его не задевает
	_choices.get_popup().add_theme_font_size_override("font_size", maxi(6, int(round(_choices.get_theme_font_size("font_size")))))


func _on_choice_selected(index: int) -> void:
	_textEdit.text = _choices.get_item_text(index) # дальше как при ручном вводе

var _ignore_next_change: bool = false
func _read_refresh() -> void:
	# currently calling this when we nuke our config to
	# correctly display all values.
	_ignore_next_change = true
	refresh()
	if _choices:
		_fillSkinChoices()

func _on_text_edit_changed() -> void:
	if _ignore_next_change:
		_ignore_next_change = false
		return

	if not _textEdit.editable:
		return # "x2" игрового режима - не значение, в настройки не пишем
	var v = _textEdit.text
	gbData.settings.set(key, v)
	print("Key '%s' [%s] set to '%s'" % [label, key, v])
	gbData.SettingsChanged.emit()
