extends Panel

@export_category("Nodes - DONT CHANGE")
@export var defaultSkinButton: Button
@export var spawnButton: Button
@export var openFolderButton: Button
@export var refreshButton: Button
@export var openDBButton: Button
@export var expieDisplayWidget: ExpieWidget
@export var skinsButtonList: BoxContainer
@export var skinNameLabel: RichTextLabel

class SkinEntry:
	var name: String
	var path: String

var _root_path = "user://skin"
var skinsDirectoryArray: Array = []
var selectedSkin = null # can be SkinEntry or null

var skinButtons: Array[Button] = []

func _ready() -> void:
	spawnButton.pressed.connect(_on_spawn_button_press)
	defaultSkinButton.pressed.connect(_on_skin_button_press)
	openFolderButton.pressed.connect(_on_skin_folder_button_press)
	refreshButton.pressed.connect(_on_refresh_button_press)
	openDBButton.pressed.connect(_on_db_button_press)

	visibility_changed.connect(_update)
	gbData.SettingsChanged.connect(_markDefaultSkin)
	scan_for_skins()

	# Персонаж-игрок (PlayerManager): кнопка рядом со Spawn
	var playerButton := Button.new()
	playerButton.text = " Создать за игрока "
	spawnButton.get_parent().add_child(playerButton)
	spawnButton.get_parent().move_child(playerButton, spawnButton.get_index() + 1)
	playerButton.pressed.connect(_on_spawn_player_press)

	# Описание персонажа из паспорта - под превью, под кнопками Spawn
	_descLabel = RichTextLabel.new()
	_descLabel.bbcode_enabled = true
	_descLabel.fit_content = true
	_descLabel.scroll_active = false
	_descLabel.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_descLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# при 14 описание было еле видно (054.94)
	_descLabel.add_theme_font_size_override("normal_font_size", DESC_FONT_SIZE)
	_descLabel.add_theme_font_size_override("italics_font_size", DESC_FONT_SIZE)
	var displayBox: Node = spawnButton.get_parent().get_parent()
	displayBox.add_child(_descLabel)

## Базовый размер. Весь текст консоли (и этот тоже) terminalMain ещё
## умножает под экран: на 4K x1.5 -> 42. Описание в 2 раза крупнее обычного.
const DESC_FONT_SIZE := 28
var _descLabel: RichTextLabel

## "description" из character.json скина (папка игрока, потом встроенная).
func _skinDescription(skinName: String) -> String:
	for path in ["user://skin/%s/character.json" % skinName, "res://defaults/skins/%s/character.json" % skinName]:
		if FileAccess.file_exists(path):
			var data = JSON.parse_string(FileAccess.get_file_as_string(path))
			if data is Dictionary:
				return String(data.get("description", ""))
	return ""

## Стандартный Experiment и скин Expie - один и тот же персонаж ("Expie" -
## ласковое сокращение). Полная версия (раны, фразы, род, паспорт) живёт в
## папке скина Expie - кнопка "Experiment (Default)" спавнит именно её, а
## отдельная кнопка "Expie" в списке не показывается.
const EXPIE_SKIN := "Expie"

func _defaultSkinPath() -> String:
	var p := _root_path.path_join(EXPIE_SKIN).path_join("/")
	return p if DirAccess.dir_exists_absolute(p) else "res://assets/Body/"


## 054.998: "(по умолчанию)" - у того персонажа, который выбран в настройке
## "Персонаж по умолчанию" (defaultSkin). Раньше надпись была вшита в кнопку
## Experiment - наследство оригинала, где он и был по умолчанию.
const DEFAULT_MARK := " (по умолчанию)"

func _markDefaultSkin() -> void:
	var def := String(gbData.settings.get("defaultSkin", ""))
	defaultSkinButton.text = "Experiment" + (DEFAULT_MARK if def == EXPIE_SKIN else "")
	for i in skinButtons.size():
		if i < skinsDirectoryArray.size() and is_instance_valid(skinButtons[i]):
			var n: String = skinsDirectoryArray[i].name
			skinButtons[i].text = n + (DEFAULT_MARK if n == def else "")


func _update() -> void:
	if !visible:
		return
	_markDefaultSkin()
	# refresh expie display
	skinNameLabel.text = get_skin_name()
	GlobalVariable.userSkinPath = (
		_defaultSkinPath() if selectedSkin == null
		else selectedSkin.path
	)
	expieDisplayWidget.ApplyTextures(GlobalVariable.userSkinPath)
	if _descLabel:
		var desc := _skinDescription(EXPIE_SKIN if selectedSkin == null else selectedSkin.name)
		_descLabel.text = desc if desc != "" else "[i]Описания нет - его можно добавить полем \"description\" в character.json скина.[/i]"

func get_skin_name() -> String:
	return "Experiment" if selectedSkin == null else selectedSkin.name

## 054.998: раньше тут была своя копия спавна, и она записывала в сохранение
## не того персонажа: Experiment из этого меню сохранялся как скин из
## настройки "по умолчанию" (после перезапуска с сохранением персонажей
## превращался в Вояджер), а размер был всегда 4 вместо настройки petScale.
## Теперь - общий спавн, как у команды spawn_pet.
func spawnExpie(petId: String = ""):
	CommandsGlobal.spawnExpie(petId)


## Look for all available user skins and store them.
func scan_for_skins() -> void:
	skinsDirectoryArray = []
	var dirac = DirAccess.open(_root_path)
	if !dirac:
		push_warning("skins folder not found?")
		return

	var directories = dirac.get_directories()

	for directory_name in directories:
		# ignore the built-in Default/Body folder specifically - it's
		# already shown as the hardcoded "Experiment (Default)" entry above.
		# NOT the same as gbData.settings.defaultSkin - that setting is now
		# user-configurable and can legitimately point at a real custom
		# character (e.g. VoyagerAlt), which should still show up here.
		if directory_name == "Default" or directory_name == "Body" or directory_name == EXPIE_SKIN:
			continue # Expie = "Experiment (Default)" сверху
		# register otherwise.
		var _skin = SkinEntry.new()
		_skin.name = directory_name
		_skin.path = _root_path.path_join(directory_name).path_join("/")
		skinsDirectoryArray.append(_skin)

	print("scanned for skins. found %s" % [len(skinsDirectoryArray)])
	regenerate_buttons()

## Create buttons for our custom skins.
func regenerate_buttons() -> void:
	for b in skinButtons: # remove existing ones
		b.queue_free()
	skinButtons.clear()
	# generate buttons using skin data.
	for skin in skinsDirectoryArray:
		var btn = Button.new()
		skinsButtonList.add_child(btn)
		btn.owner = skinsButtonList
		btn.text = skin.name
		btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		btn.pressed.connect(_on_skin_button_press.bind(skin))
		skinButtons.append(btn)
	_markDefaultSkin()

## Select a skin when pressing on a skin button.
func _on_skin_button_press(skin_entry = null) -> void:
	if skin_entry is SkinEntry:
		print("pressed on %s @ '%s'!" % [skin_entry.name, skin_entry.path])
	else:
		print("pressed default!")
	selectedSkin = skin_entry
	_update()

# buton

func _on_spawn_button_press() -> void:
	GlobalVariable.userSkinPath = (
		_defaultSkinPath() if selectedSkin == null
		else selectedSkin.path
	)
	spawnExpie()

func _on_spawn_player_press() -> void:
	var path: String = _defaultSkinPath() if selectedSkin == null else selectedSkin.path
	var skinName: String = ("Body" if path.begins_with("res://") else EXPIE_SKIN) if selectedSkin == null else selectedSkin.name
	PlayerManager.spawnPlayer(path, skinName)


func _on_skin_folder_button_press() -> void:
	OS.shell_open(ProjectSettings.globalize_path("user://skin"))

func _on_refresh_button_press() -> void:
	scan_for_skins()

func _on_db_button_press() -> void:
	OS.shell_open("https://skin.cat-bot.de/")
