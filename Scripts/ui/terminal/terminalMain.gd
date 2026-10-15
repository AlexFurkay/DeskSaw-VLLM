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

	CommandsGlobal.runInitialCommands.emit()


## 054.96: текст консоли был задан в пикселях - на 4K мелкий, на 1080p
## огромный. Множитель = 1.5 (крупнее, чем было, по просьбе) x высота экрана
## относительно 4K (2160): на 4K - 1.5, на 1440p - 1.0, на 1080p - 0.75.
const BASE_TEXT_SCALE := 1.5
const REFERENCE_SCREEN_HEIGHT := 2160.0
const DEFAULT_CONSOLE_SIZE := Vector2(580, 320)

static func textScale() -> float:
	return BASE_TEXT_SCALE * clampf(float(GlobalVariable.screenHeight) / REFERENCE_SCREEN_HEIGHT, 0.4, 2.0)


func _scaleFont(c: Control) -> void:
	if c.has_meta("fontScaled"):
		return
	c.set_meta("fontScaled", true)
	var k := textScale()
	if c is Button or c is Label or c is LineEdit or c is TextEdit:
		c.add_theme_font_size_override("font_size", maxi(6, int(round(c.get_theme_font_size("font_size") * k))))
	elif c is RichTextLabel:
		for key in ["normal_font_size", "bold_font_size", "italics_font_size", "bold_italics_font_size", "mono_font_size"]:
			c.add_theme_font_size_override(key, maxi(6, int(round(c.get_theme_font_size(key) * k))))


func _scaleFontsUnder(node: Node) -> void:
	for child in node.get_children():
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
