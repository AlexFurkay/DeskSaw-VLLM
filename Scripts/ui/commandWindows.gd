extends Node

## 04.11 (схема Alex, «юзер-френдли» консоль): красные команды консоли открывают окошко
## справа от консоли, выровненное по её верхнему краю (нет места справа - слева). Окошко -
## ребёнок консоли: ездит вместе с ней, текст растёт тем же множителем (terminalMain), прячется
## вместе с ней и ничего не закрывает. Одно окошко за раз. Вид - как у формы «свой предмет».
## Окошки делают то же, что команды (CommandsGlobal), и пишут в консоль, что сделано; набирать
## команды руками можно по-прежнему.


const TerminalMain := preload("res://Scripts/ui/terminal/terminalMain.gd")
const WIDTH := 462.0 # до масштаба текста; 05.11 (Alex: модели не влезают) - в 1.4 раза шире (было 330)
const GAP := 6.0

const TITLES := {
	"ai_creativity": "Креативность ИИ",
	"ai_repetition_guard": "Защита от повторов",
	"ban_words": "Запрещённые слова",
	"change_player_mode": "Клавиши режима игрока",
	"clear_items": "Убрать с экрана",
	"despawn_pet": "Убрать персонажа",
	"model_manager": "Модели ИИ",
	"pet_size": "Размер персонажей",
	"resize_console": "Размер консоли",
	"set_monitor": "Монитор",
}
const HINTS := {
	"ai_creativity": "Выше - ответы смелее и неожиданнее, ниже - спокойнее и предсказуемее. У каждой модели своё стандартное значение.",
	"ai_repetition_guard": "Выше - ИИ реже повторяет одни и те же слова и фразы. Если слишком высоко, речь становится странной.",
	"ban_words": "Слова и фразы, которые ИИ никогда не скажет. Впиши слово и нажми галочку, а чтобы удалить - впиши номер из списка.",
	"change_player_mode": "Сочетание клавиш, которым ты входишь в управление своим персонажем и выходишь из него. Нажми «Записать» и потом нужные клавиши - или впиши вручную, например Ctrl+Shift+K.",
	"clear_items": "Нажми на строку - это уберётся с экрана.",
	"despawn_pet": "Нажми «Убрать» - персонаж уйдёт со стола вместе со своим состоянием.",
	"model_manager": "Скачанные модели: выбрать, удалить или скачать новую. Игре подходят только модели со зрением и без режима размышлений.",
	"pet_size": "Размер новых персонажей и предметов (по умолчанию 4). Те, что уже на экране, не меняются.",
	"resize_console": "Ширина и высота консоли в пикселях. Можно и просто потянуть уголок консоли справа снизу.",
	"set_monitor": "На каком мониторе живут персонажи. Выбор запоминается.",
}

var _terminal: Control
var _win: PanelContainer
var _wc: WindowController
var _cmd := ""
var _body: VBoxContainer
var _capturing := false
var _keyField: LineEdit
var _captureBtn: Button
## 05.11 (Alex): уголок справа снизу - тянешь, окошко меняет размер; размер общий для всех
## окошек и запоминается (настройка cmdWindowSize, в пикселях экрана). Ноль - по умолчанию.
var _grip: Button
var _gripDrag := false
var _gripOffset := Vector2.ZERO


func setup(terminal: Control) -> void:
	_terminal = terminal


func isOpen(cmd: String = "") -> bool:
	return _win != null and is_instance_valid(_win) and _win.visible and (cmd == "" or cmd == _cmd)


func close() -> void:
	_capturing = false
	if _wc != null and is_instance_valid(_wc):
		_wc.enabled = false # снять «зону щелчка» с прозрачного окна, иначе место окошка перестало бы пропускать клики
	if _win != null and is_instance_valid(_win):
		_win.queue_free()
	if _grip != null and is_instance_valid(_grip):
		_grip.queue_free()
	_grip = null
	_gripDrag = false
	_win = null
	_wc = null
	_cmd = ""


func open(cmd: String) -> void:
	if isOpen(cmd): # второй щелчок по той же команде - закрыть
		close()
		return
	close()
	_cmd = cmd
	_win = PanelContainer.new()
	_win.name = "CommandWindow"
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.09, 0.09, 0.1, 1.0) # как форма «свой предмет»
	bg.set_border_width_all(2)
	bg.border_color = Color(0.85, 0.85, 0.85, 1.0)
	_win.add_theme_stylebox_override("panel", bg)
	_win.custom_minimum_size = Vector2(WIDTH, 0)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	_win.add_child(margin)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	margin.add_child(col)

	var head := HBoxContainer.new()
	var title := Label.new()
	title.text = Lang.t(TITLES.get(cmd, cmd))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 20)
	head.add_child(title)
	var x := Button.new()
	x.text = " X "
	x.focus_mode = Control.FOCUS_NONE
	head.add_child(x)
	col.add_child(head)

	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 6)
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_body)

	col.add_child(HSeparator.new())
	var hint := Label.new()
	hint.text = Lang.t(HINTS[cmd]) if HINTS.has(cmd) else Console.get_command_description(cmd)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.7)
	col.add_child(hint)

	_terminal.add_child(_win)
	_wc = WindowController.new()
	_wc.CloseButton = x
	_win.add_child(_wc)
	_build()
	_addGrip()
	_place()


func _userSize() -> Vector2:
	var v = gbData.settings.get("cmdWindowSize")
	if v is Dictionary and v.has("x") and v.has("y"):
		return Vector2(float(v["x"]), float(v["y"]))
	return Vector2.ZERO


func _addGrip() -> void:
	_grip = Button.new()
	_grip.name = "CommandWindowGrip"
	_grip.focus_mode = Control.FOCUS_NONE
	_grip.flat = true
	_grip.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	var s := maxi(2, int(round(2.0 * TerminalMain.textScale())))
	var img := Image.create(7 * s, 7 * s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in 7: # уголок из точек, как у консоли
		for x in 7:
			if x + y >= 6 and (x + y) % 2 == 0:
				img.fill_rect(Rect2i(x * s, y * s, s, s), Color(0.85, 0.85, 0.85, 1))
	_grip.icon = ImageTexture.create_from_image(img)
	_grip.set_meta("fontScaled", true) # размер уже под масштаб
	_grip.button_down.connect(func():
		_gripDrag = true
		_gripOffset = _win.size - _win.get_local_mouse_position())
	_grip.button_up.connect(func():
		_gripDrag = false
		gbData.settings.set("cmdWindowSize", {"x": _win.size.x, "y": _win.size.y})
		gbData.savetodisk(gbData.conPath, gbData.settings))
	_terminal.add_child(_grip)


func _build() -> void:
	for c in _body.get_children():
		c.queue_free()
	match _cmd:
		"ai_creativity":
			_stepper(func(): return LLMManager.creativity, "ai_creativity", 0.05, 0.0, 1.5, "%.2f", 0)
		"ai_repetition_guard":
			_stepper(func(): return LLMManager.repetitionGuard, "ai_repetition_guard", 0.05, 1.0, 2.0, "%.2f", 1)
		"pet_size":
			_stepper(func(): return float(gbData.settings.get("petScale", 4.0)), "pet_size", 0.5, 1.0, 10.0, "%.1f", -1, 4.0)
		"ban_words":
			_buildBanwords()
		"change_player_mode":
			_buildKeys()
		"clear_items":
			_buildClear()
		"despawn_pet":
			_buildDespawn()
		"model_manager":
			_buildModels()
		"resize_console":
			_buildResize()
		"set_monitor":
			_buildMonitors()


## Окошко - справа от консоли по её верхнему краю; справа край экрана - слева; не ниже экрана.
func _place() -> void:
	if _win == null or not is_instance_valid(_win):
		return
	# сам по себе контейнер только растёт: при первом кадре перенос текста не знает ширины
	# и вытягивает окно в высоту - каждый раз подгоняем под содержимое
	var view := _terminal.get_viewport_rect().size
	if _gripDrag and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_grip.button_up.emit() # отпустили за пределами окна - не залипать
	if _gripDrag:
		var want := _win.get_local_mouse_position() + _gripOffset
		gbData.settings.set("cmdWindowSize", {"x": want.x, "y": want.y})
	# 05.11 (Alex): по умолчанию шириной WIDTH и высотой с консоль; уголком - свой размер
	var us := _userSize()
	var w0 := WIDTH * TerminalMain.textScale()
	_win.custom_minimum_size = Vector2(
		clampf(us.x if us.x > 0.0 else w0, w0 * 0.6, view.x * 0.9),
		clampf(us.y if us.y > 0.0 else _terminal.size.y, 150.0, view.y))
	_win.reset_size()
	var tpos := _terminal.global_position
	var w := _win.size.x
	var x := _terminal.size.x + GAP
	if tpos.x + x + w > view.x and tpos.x - GAP - w >= 0.0:
		x = -GAP - w
	var y := 0.0
	if tpos.y + _win.size.y > view.y:
		y = view.y - _win.size.y - tpos.y
	if tpos.y + y < 0.0:
		y = -tpos.y
	_win.position = Vector2(x, y)
	if _grip != null and is_instance_valid(_grip):
		_grip.reset_size()
		_grip.position = _win.position + _win.size - _grip.size


func _process(_delta: float) -> void:
	if _win == null:
		return
	if not is_instance_valid(_win) or not _win.visible or not _terminal.is_visible_in_tree():
		close() # закрыли крестиком или спрятали консоль
		return
	_place()


# ---------------- общие кусочки ----------------

func _row() -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 6)
	_body.add_child(r)
	return r


func _label(text: String, parent: Control = null, expand := false) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if expand else TextServer.AUTOWRAP_OFF
	if expand:
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	(parent if parent != null else _body).add_child(l)
	return l


func _button(text: String, parent: Control, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	_outline(b)
	b.pressed.connect(action)
	parent.add_child(b)
	return b


## 05.11 (Alex, F2.8: «галочки и Выбрать нужно обводить, иначе непонятно, что они нажимные»):
## рамка у кнопок окошек; под мышью - светлее, нажата - фон.
func _outline(b: Button) -> void:
	for st in [["normal", 0.55, 0.0], ["hover", 0.95, 0.08], ["pressed", 0.95, 0.22], ["disabled", 0.3, 0.0]]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1, 1, 1, st[2])
		sb.set_border_width_all(2)
		sb.border_color = Color(st[1], st[1], st[1], 1.0)
		sb.content_margin_left = 8
		sb.content_margin_right = 8
		sb.content_margin_top = 2
		sb.content_margin_bottom = 2
		b.add_theme_stylebox_override(st[0], sb)


## Кнопка-галочка из схемы Alex (в шрифте консоли нет ✓ - рисуем пикселями).
func _checkButton(parent: Control, action: Callable) -> Button:
	var b := _button("", parent, action)
	b.icon = _checkIcon()
	b.custom_minimum_size = Vector2(30, 30)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return b


static var _checkTex: Texture2D
func _checkIcon() -> Texture2D:
	if _checkTex == null:
		var rows := [
			"..........",
			".........#",
			"........##",
			".......##.",
			"#.....##..",
			"##...##...",
			".##.##....",
			"..###.....",
			"...#......",
			"..........",
		]
		var s := maxi(2, int(round(2.0 * TerminalMain.textScale())))
		var img := Image.create(10 * s, 10 * s, false, Image.FORMAT_RGBA8)
		img.fill(Color(0, 0, 0, 0))
		for y in rows.size():
			for x in String(rows[y]).length():
				if String(rows[y])[x] == "#":
					img.fill_rect(Rect2i(x * s, y * s, s, s), Color(1, 1, 1, 1))
		_checkTex = ImageTexture.create_from_image(img)
	return _checkTex


func _field(placeholder: String, parent: Control) -> LineEdit:
	var f := LineEdit.new()
	f.placeholder_text = placeholder
	f.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(f)
	return f


func _scroll(minHeight: float) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, minHeight)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_child(sc)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	sc.add_child(list)
	return list


# ---------------- < значение > ----------------

## presetIndex: 0 - креативность, 1 - защита от повторов из пресета модели; -1 - нет пресета.
func _stepper(getter: Callable, command: String, step: float, lo: float, hi: float, fmt: String, presetIndex: int, defaultValue: float = -1.0) -> void:
	var r := _row()
	r.alignment = BoxContainer.ALIGNMENT_CENTER
	var value := Label.new()
	value.custom_minimum_size = Vector2(80, 0)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.add_theme_font_size_override("font_size", 26)
	var setTo := func(v: float):
		v = clampf(snappedf(v, step), lo, hi)
		Console.execute("%s %s" % [command, fmt % v])
		value.text = fmt % float(getter.call())
	_button("  <  ", r, func(): setTo.call(float(getter.call()) - step))
	value.text = fmt % float(getter.call())
	r.add_child(value)
	_button("  >  ", r, func(): setTo.call(float(getter.call()) + step))
	var std := defaultValue
	if presetIndex >= 0 and LLMManager.MODEL_PRESETS.has(LLMManager.modelName):
		std = float(LLMManager.MODEL_PRESETS[LLMManager.modelName][presetIndex])
	if std >= 0.0:
		var r2 := _row()
		r2.alignment = BoxContainer.ALIGNMENT_CENTER
		_button(Lang.t("Как стандартно (%s)") % (fmt % std), r2, func(): setTo.call(std))


# ---------------- запрещённые слова ----------------

func _buildBanwords() -> void:
	var add := _row()
	_label(Lang.t("Добавить:"), add)
	var addField := _field(Lang.t("введи слово"), add)
	var doAdd := func():
		CommandsGlobal.banwordAdd(addField.text)
		addField.text = ""
		_build.call_deferred()
	addField.text_submitted.connect(func(_t): doAdd.call())
	_checkButton(add, doAdd)
	var del := _row()
	_label(Lang.t("Удалить:"), del)
	var delField := _field(Lang.t("введи цифру из списка"), del)
	var err := Label.new()
	err.modulate = Color(1, 0.45, 0.45)
	var doDel := func():
		var t := delField.text.strip_edges()
		if not t.is_valid_int() or not CommandsGlobal.banwordRemove(int(t)):
			err.text = Lang.t("Нет слова под таким номером.")
			return
		_build.call_deferred()
	delField.text_submitted.connect(func(_t): doDel.call())
	_checkButton(del, doDel)
	_body.add_child(err)
	_label(Lang.t("Список:"))
	var words := CommandsGlobal.banwordsList()
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 110)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_body.add_child(sc)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 16)
	sc.add_child(grid)
	if words.is_empty():
		_label(Lang.t("(пусто)"), grid)
	for i in words.size():
		var l := _label("%d. %s" % [i + 1, words[i]], grid, true)
		l.custom_minimum_size = Vector2(130, 0)


# ---------------- клавиши режима игрока ----------------

func _buildKeys() -> void:
	_label(Lang.t("Сейчас: %s") % PlayerManager.currentKeys())
	var r := _row()
	_keyField = _field(Lang.t("например Ctrl+Shift+K"), r)
	var save := func():
		var combo := _keyField.text.strip_edges().replace(" ", "")
		if combo == "":
			return
		_capturing = false
		Console.execute("change_player_mode " + combo)
		_build.call_deferred()
	_keyField.text_submitted.connect(func(_t): save.call())
	_checkButton(r, save)
	var r2 := _row()
	_captureBtn = _button(Lang.t("Записать нажатием"), r2, func():
		_capturing = true
		_captureBtn.text = Lang.t("Нажми сочетание клавиш..."))


func _input(event: InputEvent) -> void:
	if not _capturing or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k := event as InputEventKey
	var key := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
	if key in [KEY_CTRL, KEY_ALT, KEY_SHIFT, KEY_META]:
		return # ждём обычную клавишу вместе с ними
	if key == KEY_ESCAPE:
		_capturing = false
		_captureBtn.text = Lang.t("Записать нажатием")
		get_viewport().set_input_as_handled()
		return
	var parts: Array = []
	if k.ctrl_pressed:
		parts.append("Ctrl")
	if k.alt_pressed:
		parts.append("Alt")
	if k.shift_pressed:
		parts.append("Shift")
	if k.meta_pressed:
		parts.append("Win")
	parts.append(OS.get_keycode_string(key))
	_keyField.text = "+".join(parts)
	_capturing = false
	_captureBtn.text = Lang.t("Записать нажатием")
	get_viewport().set_input_as_handled()


# ---------------- убрать с экрана ----------------

func _buildClear() -> void:
	var list := _scroll(180)
	for e in CommandsGlobal.clearMenuEntries():
		var entry: Dictionary = e
		var b := _button(String(entry["label"]), list, func():
			CommandsGlobal.clearMenuApply(entry)
			await get_tree().process_frame # queue_free - в конце кадра
			_build())
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT


func _buildDespawn() -> void:
	var pets := CommandsGlobal.despawnList()
	if pets.is_empty():
		_label(Lang.t("Персонажей на экране нет."))
		return
	var list := _scroll(160)
	for p in pets:
		var pet = p
		var r := HBoxContainer.new()
		list.add_child(r)
		_label(PlayerManager.displayNameFor(pet._skinTag()) + (Lang.t(" (игрок)") if pet.isPlayer else ""), r, true)
		_button(Lang.t("Убрать"), r, func():
			CommandsGlobal.despawnOne(pet)
			await get_tree().process_frame
			_build())


# ---------------- модели ----------------

var _deleteArmed := ""

func _buildModels() -> void:
	var wait := _label(Lang.t("Спрашиваю у Ollama список моделей..."))
	var forCmd := _cmd
	CommandsGlobal.fetchModelRows(func(rows: Array, ok: bool):
		if not isOpen(forCmd) or not is_instance_valid(wait):
			return
		wait.queue_free()
		if not ok:
			_label(Lang.t("Ollama не ответила - проверь, что она запущена (значок в трее)."), null, true)
			return
		var list := _scroll(170)
		if rows.is_empty():
			_label(Lang.t("(пока ни одной)"), list)
		for row in rows:
			var m: Dictionary = row
			if list.get_child_count() > 0:
				list.add_child(HSeparator.new())
			var box := VBoxContainer.new()
			list.add_child(box)
			var top := HBoxContainer.new()
			box.add_child(top)
			var nameLbl := _label(String(m["name"]) + ("  " + Lang.t("<- сейчас") if m["current"] else ""), top, true)
			if m["current"]:
				nameLbl.modulate = Color(0.5, 0.85, 1.0)
			_label(String(m["size"]), top)
			# 05.11 (Alex, Screenshot_4: непонятно, к какой модели кнопки): кнопки - в строке
			# «подходит» этой же модели, между моделями черта
			var acts := HBoxContainer.new()
			box.add_child(acts)
			var info := _label(Lang.t("подходит") if String(m["problem"]) == "" else Lang.t("не подходит: %s") % m["problem"], acts, true)
			info.modulate = Color(0.6, 1, 0.6) if String(m["problem"]) == "" else Color(1, 0.5, 0.5)
			if not m["current"] and String(m["problem"]) == "":
				_button(Lang.t("Выбрать"), acts, func():
					CommandsGlobal.modelSelect(String(m["name"]))
					_build())
			if not m["current"]:
				var holder: Array = [null] # лямбда запоминает переменные при создании - кнопку отдаём через массив
				holder[0] = _button(Lang.t("Удалить"), acts, func():
					if _deleteArmed != String(m["name"]):
						_deleteArmed = String(m["name"])
						(holder[0] as Button).text = Lang.t("Точно удалить?")
						return
					_deleteArmed = ""
					await CommandsGlobal.modelDelete(String(m["name"]))
					_build())
		var dl := _row()
		_label(Lang.t("Скачать:"), dl)
		var f := _field(Lang.t("имя модели"), dl)
		var go := func():
			CommandsGlobal.modelDownload(f.text)
			f.text = ""
		f.text_submitted.connect(func(_t): go.call())
		_checkButton(dl, go)
		var have := rows.map(func(r): return String(r["name"]))
		for rec in CommandsGlobal.RECOMMENDED_MODELS:
			if not have.has(rec):
				var r3 := _row()
				_button(Lang.t("Скачать %s") % rec, r3, func(): CommandsGlobal.modelDownload(rec)))


# ---------------- размер консоли ----------------

func _buildResize() -> void:
	var r := _row()
	_label(Lang.t("Ширина:"), r)
	var w := _field("", r)
	w.text = str(int(round(_terminal.size.x)))
	_label(Lang.t("Высота:"), r)
	var h := _field("", r)
	h.text = str(int(round(_terminal.size.y)))
	var apply := func():
		if w.text.strip_edges().is_valid_int() and h.text.strip_edges().is_valid_int():
			Console.execute("resize_console %s %s" % [w.text.strip_edges(), h.text.strip_edges()])
	w.text_submitted.connect(func(_t): apply.call())
	h.text_submitted.connect(func(_t): apply.call())
	_checkButton(r, apply)


# ---------------- монитор ----------------

func _buildMonitors() -> void:
	var count := DisplayServer.get_screen_count()
	var current := int(gbData.settings.get("defaultMonitor", 0))
	var primary := DisplayServer.get_primary_screen()
	for i in count:
		var n := i
		var size := DisplayServer.screen_get_size(i)
		var text := Lang.t("Монитор %d") % (i + 1) + "  %dx%d" % [size.x, size.y]
		if i == primary:
			text += Lang.t(" - основной")
		if i == current:
			text += Lang.t("  <- сейчас")
		var r := _row()
		var b := _button(text, r, func():
			Console.execute("set_monitor %d" % n)
			_build.call_deferred())
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.disabled = i == current
