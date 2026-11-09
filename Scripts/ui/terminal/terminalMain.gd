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
	_addPhrasesPanel()
	_addSupportPanel()
	_on_submenu_picker_item_selected(0)
	_buildSubmenuTabs()

	GlobalVariable.TerminalOpenPressed.connect(_on_terminal_open_press)
	CommandsGlobal.resizeCommandCalled.connect(_resize_console)
	if ( # added this stupid check because i broke things and got scared
		gbData.settings
		and gbData.settings.ConsoleSize
		and gbData.settings.ConsoleSize.x
		and gbData.settings.ConsoleSize.y
	):
		var startSize := Vector2(gbData.settings.ConsoleSize.x, gbData.settings.ConsoleSize.y)
		# размер по умолчанию (никто не растягивал) - под крупный текст
		if startSize.is_equal_approx(DEFAULT_CONSOLE_SIZE):
			startSize *= textScale()
		# и никогда не больше экрана (на 1080p окно, растянутое на 4K, не влезало)
		var screen := Vector2(GlobalVariable.screenWidth, GlobalVariable.screenHeight) * 0.9
		startSize = startSize.min(screen)
		_resize_console(startSize, false)
		print("%s: initial resize called properly!" % [name])

	# текст всех вкладок - под разрешение экрана; вкладки создают кнопки и на
	# ходу (список скинов, предметы), их ловим через node_added
	_scaleFontsUnder(self)
	get_tree().node_added.connect(_on_node_added)
	if windowControl and windowControl.CloseButton:
		_fitCloseButton(windowControl.CloseButton)

	# 04.11: окошки красных команд консоли (схема Alex) - справа от консоли, едут вместе с ней
	# (через preload, а не class_name: новые class_name не видны стенду до пересканирования редактором)
	var windows: Node = preload("res://Scripts/ui/commandWindows.gd").new()
	windows.name = "CommandWindows"
	add_child(windows)
	windows.setup(self)
	CommandsGlobal.commandWindows = windows

	CommandsGlobal.runInitialCommands.emit()


## 054.96: текст консоли был задан в пикселях - на 4K мелкий, на 1080p
## огромный. Множитель = 1.5 (крупнее, чем было, по просьбе) x высота экрана
## относительно 4K (2160): на 4K - 1.5, на 1440p - 1.0, на 1080p - 0.75.
const BASE_TEXT_SCALE := 1.5
const REFERENCE_SCREEN_HEIGHT := 2160.0
const DEFAULT_CONSOLE_SIZE := Vector2(580, 320)

## F2.5 (тестер, экран 1440x900: текст мелкий): ниже 1080p текст больше не уменьшается - на 900 px было x0,62
## F2.7 (тестер 1440x900: всё равно мелко): свой множитель в настройках - «Размер текста консоли» (0.5-3)
static func ownTextScale() -> float:
	var own := 1.0
	if gbData.settings.has("uiTextScale"):
		own = float(GlobalVariable.getNumFromString(str(gbData.settings["uiTextScale"])))
		own = 1.0 if own <= 0.0 else clampf(own, 0.5, 3.0) # пусто или 0 - обычный
	return own


static func textScale() -> float:
	return BASE_TEXT_SCALE * clampf(float(GlobalVariable.screenHeight) / REFERENCE_SCREEN_HEIGHT, 0.5, 2.0) * ownTextScale()


var _consoleViewNode: Node = null

func _consoleView() -> Node:
	if _consoleViewNode == null or not is_instance_valid(_consoleViewNode):
		_consoleViewNode = find_child("ConsoleView", true, false)
	return _consoleViewNode


func _scaleFont(c: Control) -> void:
	if c.has_meta("fontScaled"):
		return
	c.set_meta("fontScaled", true)
	var k := textScale()
	# 05.11: текст самой консоли раньше не масштабировался вовсе - на мелких экранах не
	# уменьшаем его относительно прежнего, меняет только настройка «Размер текста консоли»
	var cv := _consoleView()
	if cv and cv.is_ancestor_of(c):
		k = maxf(k, ownTextScale())
	# вместе с текстом растут и заданные минимальные размеры (карточки во
	# вкладке Items были 180x40 - крупный текст переносился и давал ползунки)
	if c.custom_minimum_size != Vector2.ZERO:
		c.custom_minimum_size = (c.custom_minimum_size * k).round()
	if c is Button or c is Label or c is LineEdit or c is TextEdit:
		c.add_theme_font_size_override("font_size", maxi(6, int(round(c.get_theme_font_size("font_size") * k))))
	elif c is RichTextLabel:
		for key in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size", "mono_font_size"]:
			c.add_theme_font_size_override(key, maxi(6, int(round(c.get_theme_font_size(key) * k))))
	# 054.999: все крестики "X" (второй - в карточке предмета, вкладка Items) -
	# та же беда, что у крестика закрытия в 054.995
	if c is Button and c.text == "X" and c.clip_text:
		_fitCloseButton(c)


## 054.995: вкладка «Фразы» - последние фразы всех персонажей (и игрока) с
## временем. Фраза над головой быстро исчезает, пользователи просили лог.
var _phrasesLabel: RichTextLabel

## Пустая вкладка консоли - копия оформления первой (Консоль); возвращает отступ, куда класть содержимое
func _newTabPanel(panelName: String) -> MarginContainer:
	var model: Control = submenuPanels[0] as Control
	var panel := Panel.new()
	panel.name = panelName
	panel.theme = model.theme
	panel.add_theme_stylebox_override("panel", model.get_theme_stylebox("panel"))
	model.get_parent().add_child(panel)
	panel.anchor_left = model.anchor_left
	panel.anchor_top = model.anchor_top
	panel.anchor_right = model.anchor_right
	panel.anchor_bottom = model.anchor_bottom
	panel.offset_left = model.offset_left
	panel.offset_top = model.offset_top
	panel.offset_right = model.offset_right
	panel.offset_bottom = model.offset_bottom
	panel.size_flags_horizontal = model.size_flags_horizontal
	panel.size_flags_vertical = model.size_flags_vertical
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 12)
	panel.add_child(margin)
	return margin


func _addTab(margin: MarginContainer, title: String) -> void:
	var panel: Control = margin.get_parent()
	submenuPanels.append(panel)
	submenuButton.add_item(title)
	panel.hide()


func _addPhrasesPanel() -> void:
	if submenuPanels.is_empty():
		return
	var margin := _newTabPanel("PhrasesView")
	_phrasesLabel = RichTextLabel.new()
	_phrasesLabel.bbcode_enabled = true
	_phrasesLabel.scroll_following = true
	_phrasesLabel.selection_enabled = true # можно выделить и скопировать
	_phrasesLabel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_phrasesLabel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(_phrasesLabel)
	_phrasesLabel.text = Lang.t("[color=gray]Здесь появляются последние %d фраз всех персонажей.[/color]\n") % GlobalVariable.PHRASE_LOG_MAX + "\n".join(GlobalVariable.phraseLog)
	GlobalVariable.phraseLogged.connect(_onPhraseLogged)
	_addTab(margin, Lang.t("Фразы"))


## 05.11 (просьба англоязычных зрителей): вкладка «Спасибо» - куда можно поддержать автора.
## Номера/ссылки Alex вписывает сам в res://defaults/support.txt («язык | подпись | номер»).
## Ничего не вписано (или не для этого языка) - вкладки нет.
const SUPPORT_FILE := "res://defaults/support.txt"

static func supportEntries() -> Array:
	var out: Array = []
	var f := FileAccess.open(SUPPORT_FILE, FileAccess.READ)
	if f == null:
		return out
	var lang := "en" if Lang.isEn() else "ru"
	for raw in f.get_as_text().split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var parts := line.split("|")
		if parts.size() < 3:
			continue
		var who := parts[0].strip_edges().to_lower()
		var value := "|".join(parts.slice(2)).strip_edges()
		if value.is_empty() or not (who == lang or who == "all"):
			continue
		out.append({"label": parts[1].strip_edges(), "value": value})
	return out


func _addSupportPanel() -> void:
	if submenuPanels.is_empty():
		return
	var entries := supportEntries()
	if entries.is_empty():
		return
	var margin := _newTabPanel("SupportView")
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 10)
	scroll.add_child(box)
	var intro := Label.new()
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	intro.text = Lang.t("Если игра тебе нравится и хочется сказать спасибо - вот куда можно. Игра бесплатная и такой останется, это только по желанию. Спасибо, что играешь!")
	box.add_child(intro)
	for e in entries:
		var title := Label.new()
		title.text = e.label
		title.modulate = Color(0.75, 0.75, 0.75)
		box.add_child(title)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var value := LineEdit.new()
		value.text = e.value
		value.editable = false # можно выделить, но не испортить
		value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(value)
		var copy := Button.new()
		copy.text = Lang.t("Скопировать")
		copy.focus_mode = Control.FOCUS_NONE
		copy.pressed.connect(_copySupport.bind(copy, e.value))
		row.add_child(copy)
		box.add_child(row)
	_addTab(margin, Lang.t("Спасибо"))


func _copySupport(btn: Button, value: String) -> void:
	DisplayServer.clipboard_set(value)
	btn.text = Lang.t("Скопировано")
	get_tree().create_timer(2.0).timeout.connect(func():
		if is_instance_valid(btn):
			btn.text = Lang.t("Скопировать"))


func _onPhraseLogged(line: String) -> void:
	if _phrasesLabel.get_paragraph_count() > GlobalVariable.PHRASE_LOG_MAX + 20:
		# в долгой сессии вкладка не растёт бесконечно - пересобираем из журнала
		_phrasesLabel.text = "\n".join(GlobalVariable.phraseLog)
	else:
		_phrasesLabel.append_text("\n" + line)


## 054.995: крестик закрытия - кнопка фиксированного размера 27x28 с обрезкой
## текста; после увеличения шрифта "X" перестал влезать и пропал. Растим кнопку
## вместе с текстом и отключаем обрезку.
func _fitCloseButton(close: Button) -> void:
	close.clip_text = false
	close.autowrap_mode = TextServer.AUTOWRAP_OFF
	close.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	var side: float = round(28.0 * textScale())
	close.offset_left = close.offset_right - side
	close.offset_top = -side / 2.0
	close.offset_bottom = side / 2.0


func _scaleFontsUnder(node: Node) -> void:
	# 05.11: true - и внутренние узлы: вывод и строка ввода консоли (godot-console) добавлены
	# как внутренние, их не было в get_children() - текст консоли не менялся от настройки (Alex)
	for child in node.get_children(node.name == "ConsoleView"):
		if child is Control:
			_scaleFont(child)
		_scaleFontsUnder(child)


func _on_node_added(node: Node) -> void:
	if node is Control and is_ancestor_of(node):
		# после _ready самого узла - он мог выставить свой размер
		_scaleFont.call_deferred(node)

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

## Вместо выпадающего списка в заголовке - кнопки-вкладки Console /
## Settings / Skins / Items, как вкладки внутри Settings (Behavior, Audio...).
## Сам список остаётся в сцене (на него ссылаются экспорт-поля), просто скрыт.
func _buildSubmenuTabs() -> void:
	var bar := HBoxContainer.new()
	bar.theme = submenuButton.theme
	bar.add_theme_constant_override("separation", 4)
	var group := ButtonGroup.new()
	for i in submenuPanels.size():
		var btn := Button.new()
		btn.text = submenuButton.get_item_text(i) if i < submenuButton.item_count else str(i)
		btn.toggle_mode = true
		btn.button_group = group
		btn.focus_mode = Control.FOCUS_NONE
		btn.custom_minimum_size = Vector2(70, 0)
		btn.button_pressed = i == 0
		btn.pressed.connect(_on_submenu_picker_item_selected.bind(i))
		bar.add_child(btn)
	submenuButton.get_parent().add_child(bar)
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.grow_vertical = Control.GROW_DIRECTION_BOTH
	bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE)
	submenuButton.hide()


func _on_submenu_picker_item_selected(index: int) -> void:
	for i in submenuPanels.size():
		if index == i:
			submenuPanels[i].show()
			continue
		submenuPanels[i].hide()
