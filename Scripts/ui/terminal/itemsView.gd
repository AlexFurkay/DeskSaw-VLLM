extends Panel

@export_category("Nodes - DO NOT CHANGE")
@export var itemContainer: Container
@export var buttonScene: PackedScene
@export var root: Panel
@export var wikiButton: Button
@export var wikiButtonClose: Button

class ItemEntry:
	var name: String
	var icon: Texture
	var scene_path: String
	var customId := "" # пользовательский предмет (CustomItems)
var itemList: Array[ItemEntry] = []

var _itemsPath = "res://scenes/objects/"

func  _ready() -> void:
	root.resized.connect(_recalculate_columns)
	if wikiButton:
		wikiButton.pressed.connect(_on_wiki_button_press)
	if wikiButton and wikiButtonClose:
		wikiButtonClose.pressed.connect(_on_wiki_close_button_press)
	_recalculate_columns()
	_buildCustomUi()
	_refresh()
	# 054.999: свои PNG, положенные в папку руками, появляются при следующем открытии вкладки
	visibility_changed.connect(func():
		if is_visible_in_tree():
			CustomItems.reload()
			_refresh()
			_describeNext())

func _refresh() -> void:
	_generate_item_list()
	_generate_buttons()

## Walk through our item path and generate a list with all the items to be spawned.
func _generate_item_list() -> void:
	itemList.clear()
	var dacc = DirAccess.open(_itemsPath)
	if dacc == null:
		push_error("provided item path '%s' is not accessible." % [_itemsPath])
		return

	# pass through the items path and add any entry to the items list
	for item in dacc.get_files():
		if !item.ends_with(".tscn"): # only focus scene files
			continue
		var entry = ItemEntry.new()
		entry.name = item.get_basename()
		entry.scene_path = _itemsPath.path_join(item)
		entry.icon = _get_scene_texture(entry.scene_path)
		itemList.append(entry)
	for e in CustomItems.all():
		var entry = ItemEntry.new()
		entry.name = "★ " + String(e["name"])
		entry.customId = String(e["id"])
		entry.icon = CustomItems.icon(entry.customId)
		itemList.append(entry)

## Get the main scene's item texture.
func _get_scene_texture(scene_path: String) -> Texture:
	# instance and walk through the scene until we find a Sprite2D, then
	# yank its texture for our own purposes
	var instance = load(scene_path).instantiate()
	for i in instance.get_children():
		if i is Sprite2D:
			var tex: Texture = i.texture
			instance.free() # экземпляр нужен только ради картинки - раньше не удалялся
			return tex
	instance.free()
	push_error("sprite2d node not found on scene '%s'" % [scene_path])
	return Texture.new()

## Русские названия на карточках (054.98). Внутри игры и в командах
## spawn / clear_items предметы по-прежнему зовутся по имени файла.
const ITEM_RU_NAMES := {
	"banana": "банан", "bandage": "бинт", "beret": "берет", "bread": "хлеб",
	"burger": "бургер", "chair": "стул", "containercrate": "ящик",
	"fentanyl": "фентанил", "geofruit": "геофрукт", "glasses": "очки",
	"hat": "шляпа", "juicedobry": "сок «Добрый»", "medcrate": "мед. ящик",
	"medkit": "аптечка", "nightstand": "тумбочка", "pizzaslice": "пицца",
	"sawblade": "пила", "syringe": "шприц", "yellowflesh": "жёлтая плоть",
}

## Clear and regenerate interactable buttons for all available items.
## '_generate_item_list' should have been called at this point.
func _generate_buttons() -> void:
	# remove all items if any exist
	for child in itemContainer.get_children():
		child.queue_free()
	# get all our known items and implement them
	for item_entry in itemList:
		var btn = buttonScene.instantiate()
		itemContainer.add_child(btn)
		btn.name = "%sItemWidget" % [item_entry.name]
		btn.owner = itemContainer
		btn.itemName = Lang.t(ITEM_RU_NAMES.get(item_entry.name, item_entry.name))
		btn.itemIcon = item_entry.icon
		# mind you, this' like that because of the referenced scene's anatomy
		btn.find_child("Button").pressed.connect(_on_item_button_press.bind(item_entry))

func _on_item_button_press(item: ItemEntry) -> void:
	if _mode != "":
		var mode := _mode
		_setMode("")
		if item.customId == "":
			_hint.text = Lang.t("Встроенные предметы менять и удалять нельзя - только свои (со звёздочкой).")
		elif mode == "edit":
			_openForm(item.customId)
		else:
			_openDelete(item.customId)
		return
	if item.customId != "":
		var body: RigidBody2D = CustomItems.build(item.customId)
		if body == null:
			_hint.text = Lang.t("Не получилось открыть картинку предмета - проверь файл в папке.")
			return
		body.position = _spawnPos() # ДО add_child: Rapier не переносит уже добавленное тело - оно оставалось в (0,0)
		get_tree().current_scene.add_child(body)
		body.owner = get_tree().current_scene
		GlobalVariable.itemGiven(body) # 055.005: подарок, если персонаж ждал
		return
	# TODO: directly connect this to the command, maybe?
	var scene = load(item.scene_path)
	var instance = scene.instantiate()
	instance.position = _spawnPos() # ДО add_child (см. выше) - раньше все предметы падали в левый верхний угол
	get_tree().current_scene.add_child(instance)
	instance.owner = get_tree().current_scene
	instance.set_meta("itemName", item.name) # было item (объект ItemEntry) - код, ждущий строку, на этом падал
	GlobalVariable.itemGiven(instance) # 055.005: подарок, если персонаж ждал

## 054.9991: около курсора, но не у самого края экрана (CustomItems.spawnPosition).
func _spawnPos() -> Vector2:
	return CommandsGlobal.itemSpawnPosition()

## Recalculate item list columns using our root width
func _recalculate_columns() -> void:
	# (sort of) compensate for margin, how many times root fits into widget width
	# карточка 180 px растёт вместе с текстом консоли (terminalMain.textScale)
	var cardWidth: float = 180.0 * preload("res://Scripts/ui/terminal/terminalMain.gd").textScale()
	itemContainer.columns = maxi(1, int(round((root.size.x - 132) / cardWidth)))

# wiki stuff
# i feel like this should be it's own node scene but i felt way too lazy tbh.

func _on_wiki_button_press() -> void:
	OS.shell_open("https://casualtiesunknown.miraheze.org/wiki/")

func _on_wiki_close_button_press() -> void:
	wikiButton.hide()

# ---------------- 054.999: пользовательские предметы ----------------
# Кнопки над сеткой: Добавить / Изменить / Удалить / Открыть папку. "Изменить"
# и "Удалить" включают режим: следующий щелчок по своему предмету (★) открывает
# форму вместо появления предмета. Форма - панель поверх вкладки (не окно:
# окно игры прозрачное, отдельные окна в нём ведут себя капризно).

var _mode := ""
var _hint: Label
var _form: PanelContainer
var _fields: VBoxContainer
var _formTitle: Label
var _formError: Label
var _nameEdit: LineEdit
var _descEdit: LineEdit
var _foodCheck: CheckBox
var _tasteSpin: SpinBox
var _tasteRow: VBoxContainer
var _preview: TextureRect
var _pngLabel: Label
var _saveButton: Button
var _editId := ""
var _pickedPng := ""
var _deleting := false
var _fileDialog: FileDialog


func _buildCustomUi() -> void:
	var scroll := itemContainer.get_parent()
	var vbox := scroll.get_parent()
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	for b in [[Lang.t("Добавить свой предмет"), func(): _openForm("")],
			[Lang.t("Изменить свой"), func(): _setMode("edit")],
			[Lang.t("Удалить свой"), func(): _setMode("delete")],
			[Lang.t("Открыть папку"), func(): OS.shell_open(CustomItems.folder())],
			[Lang.t("Обновить"), _reloadItems]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.pressed.connect(b[1])
		bar.add_child(btn)
	vbox.add_child(bar)
	vbox.move_child(bar, scroll.get_index())
	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_hint)
	vbox.move_child(_hint, scroll.get_index())

	_form = PanelContainer.new()
	_form.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# непрозрачный фон - иначе сквозь форму видны карточки предметов (скрин Alex)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.09, 0.09, 0.1, 1.0)
	_form.add_theme_stylebox_override("panel", bg)
	_form.hide()
	add_child(_form)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	_form.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	margin.add_child(col)
	_formTitle = Label.new()
	col.add_child(_formTitle)

	_fields = VBoxContainer.new()
	_fields.add_theme_constant_override("separation", 6)
	col.add_child(_fields)
	var pngRow := HBoxContainer.new()
	var pick := Button.new()
	pick.text = Lang.t("Выбрать картинку (PNG)")
	pick.pressed.connect(_pickPng)
	pngRow.add_child(pick)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(64, 64)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	pngRow.add_child(_preview)
	_pngLabel = Label.new()
	_pngLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pngLabel.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	pngRow.add_child(_pngLabel)
	_fields.add_child(pngRow)
	_fields.add_child(_label(Lang.t("Название:")))
	_nameEdit = LineEdit.new()
	_nameEdit.max_length = 40
	_fields.add_child(_nameEdit)
	_fields.add_child(_label(Lang.t("Что это - описание для персонажей (о нём они и будут говорить):")))
	_descEdit = LineEdit.new()
	_descEdit.placeholder_text = DESC_PLACEHOLDER
	_descEdit.max_length = 160
	_fields.add_child(_descEdit)
	_foodCheck = CheckBox.new()
	_foodCheck.text = Lang.t("Это еда")
	_foodCheck.toggled.connect(func(on: bool): _tasteRow.visible = on)
	_fields.add_child(_foodCheck)
	_tasteRow = VBoxContainer.new() # подпись НАД полем: в одной строке она переносилась по буквам
	_tasteRow.add_child(_label(Lang.t("Вкус для всех персонажей (0 - есть не станут, 10 - объедение):")))
	_tasteSpin = SpinBox.new()
	_tasteSpin.min_value = 0
	_tasteSpin.max_value = 10
	_tasteSpin.step = 1
	_tasteSpin.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_tasteRow.add_child(_tasteSpin)
	_fields.add_child(_tasteRow)
	var info := _label(Lang.t("PNG, JPG или WEBP (GIF не подходит), лучше с прозрачным фоном. Можно и просто положить много картинок в папку и нажать «Обновить» - компьютер сам назовёт и опишет каждую. Взять предмет можно за любую видимую часть картинки. Размер на экране - как у картинки, только в пиксельном стиле; иконки из одной игры сохраняют пропорции между собой. Слишком большие картинки уменьшатся сами."))
	info.modulate = Color(1, 1, 1, 0.7)
	_fields.add_child(info)

	_formError = _label("")
	_formError.modulate = Color(1, 0.45, 0.45)
	col.add_child(_formError)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	_saveButton = Button.new()
	_saveButton.pressed.connect(_onFormSave)
	buttons.add_child(_saveButton)
	var cancel := Button.new()
	cancel.text = Lang.t("Отмена")
	cancel.pressed.connect(func(): _form.hide())
	buttons.add_child(cancel)
	col.add_child(buttons)


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _setMode(mode: String) -> void:
	_mode = mode
	match mode:
		"edit":
			_hint.text = Lang.t("Щёлкни по своему предмету (со звёздочкой), чтобы изменить его.")
		"delete":
			_hint.text = Lang.t("Щёлкни по своему предмету (со звёздочкой), чтобы удалить его.")
		_:
			_hint.text = ""


func _openForm(id: String) -> void:
	_setMode("")
	_editId = id
	_deleting = false
	_pickedPng = ""
	_fields.show()
	_formError.text = ""
	var e := CustomItems.entry(CustomItems.KEY_PREFIX + id) if id != "" else {}
	_formTitle.text = Lang.t("Изменить предмет") if id != "" else Lang.t("Новый предмет")
	_saveButton.text = Lang.t("Сохранить")
	_nameEdit.text = String(e.get("name", ""))
	_descEdit.text = String(e.get("description", ""))
	_descEdit.placeholder_text = DESCRIBING_TEXT if CustomItems.describing.has(id) else DESC_PLACEHOLDER
	_foodCheck.button_pressed = bool(e.get("food", false))
	_tasteRow.visible = _foodCheck.button_pressed
	_tasteSpin.value = int(e.get("taste", 5))
	_preview.texture = CustomItems.icon(id) if id != "" else null
	_pngLabel.text = "" if id != "" else Lang.t("картинка не выбрана")
	_form.show()


func _openDelete(id: String) -> void:
	_editId = id
	_deleting = true
	_fields.hide()
	_formError.text = ""
	_formTitle.text = Lang.t("Удалить «%s»? Картинка и описание пропадут из папки.") % String(CustomItems.entry(CustomItems.KEY_PREFIX + id).get("name", id))
	_saveButton.text = Lang.t("Удалить")
	_form.show()


func _pickPng() -> void:
	if _fileDialog == null:
		_fileDialog = FileDialog.new()
		_fileDialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_fileDialog.access = FileDialog.ACCESS_FILESYSTEM
		_fileDialog.filters = PackedStringArray([Lang.t("*.png ; Картинка PNG")])
		_fileDialog.use_native_dialog = true
		_fileDialog.file_selected.connect(_onPngPicked)
		add_child(_fileDialog)
	_fileDialog.popup_centered_ratio(0.6)


func _onPngPicked(path: String) -> void:
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		_formError.text = Lang.t("Это не похоже на PNG-картинку.")
		return
	_pickedPng = path
	_preview.texture = ImageTexture.create_from_image(img)
	_pngLabel.text = path.get_file()
	if _nameEdit.text.strip_edges() == "":
		_nameEdit.text = path.get_file().get_basename()


func _onFormSave() -> void:
	if _deleting:
		CustomItems.remove(_editId)
		# 054.9991: и все его копии с рабочего стола
		for n in get_tree().current_scene.get_children():
			if String(n.get_meta("itemName", "")) == CustomItems.KEY_PREFIX + _editId:
				n.queue_free()
		_form.hide()
		_refresh()
		return
	var name := _nameEdit.text.strip_edges()
	if _editId == "" and _pickedPng == "":
		_formError.text = Lang.t("Выбери картинку.")
		return
	if name == "":
		_formError.text = Lang.t("Напиши название.")
		return
	var id := CustomItems.save(_editId, name, _descEdit.text.strip_edges(), _foodCheck.button_pressed, int(_tasteSpin.value), _pickedPng)
	if id == "":
		_formError.text = Lang.t("Не получилось прочитать картинку.")
		return
	_form.hide()
	_hint.text = Lang.t("Готово. Щёлкни по «★ %s», чтобы предмет появился у курсора.") % name
	_refresh()
	_describeNext() # описание пустое - его напишет компьютер


# ---------------- 054.9991: ИИ-описание предметов ----------------
# Пустое описание (PNG положили в папку руками или не заполнили поле) пишет
# компьютер: самая большая установленная модель со зрением смотрит на картинку
# и называет предмет до 10 слов (решение Alex). По одному предмету за раз.
var DESC_PLACEHOLDER: String = Lang.t("например: плюшевый заяц с оторванным ухом")
var DESCRIBING_TEXT: String = Lang.t("Компьютер создаёт описание, подожди немного, потом его можно будет изменить")
var _describingNow := false

func _describeNext() -> void:
	if _describingNow or not is_instance_valid(LLMManager):
		return
	for e in CustomItems.all():
		var id := String(e["id"])
		if not CustomItems.needsDescription(id):
			continue
		CustomItems.describeTried[id] = true
		CustomItems.describing[id] = true
		_describingNow = true
		_hint.text = Lang.t("Компьютер описывает «%s»...") % String(e["name"])
		if _form.visible and _editId == id:
			_descEdit.placeholder_text = DESCRIBING_TEXT
		var autoName: bool = String(e["name"]) == id # положили в папку руками - имя тоже придумает компьютер
		LLMManager.describeItemImage(CustomItems.imagePath(id), autoName, func(desc: String, newName: String):
			CustomItems.describing.erase(id)
			_describingNow = false
			var cur := CustomItems.entry(CustomItems.KEY_PREFIX + id)
			if desc != "" and not cur.is_empty() and String(cur["description"]).strip_edges() == "":
				CustomItems.save(id, newName if newName != "" else String(cur["name"]), desc, bool(cur["food"]), int(cur["taste"]), "")
				if _form.visible and _editId == id and _descEdit.text.strip_edges() == "":
					_descEdit.text = desc
				_hint.text = "«%s»: %s" % [String(cur["name"]), desc]
			elif desc == "":
				_hint.text = Lang.t("Не получилось описать «%s» - напиши описание сам (кнопка «Изменить свой»).") % String(cur.get("name", id))
			if _form.visible and _editId == id:
				_descEdit.placeholder_text = DESC_PLACEHOLDER
			_describeNext())
		return


## 054.9992: кнопка "Обновить" - перечитать папку (положил картинки - нажал)
func _reloadItems() -> void:
	CustomItems.reload()
	_refresh()
	_describeNext()
