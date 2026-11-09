extends Node

signal toggleDebugText
signal resizeCommandCalled(size: Vector2, force: bool)

signal runInitialCommands
var has_run_commands: bool = false

"""
    ###

    there was a bunch of bullshit planning on how i would go about this and there ended up being an addon that did literally
    everything i was planning on adding

    here you go

    https://github.com/4d49/godot-console


    this script just registers a bunch of commands and contains their the functions for their code

    to create a custom command, create a function that contains ur code, and then register it in _ready
    ###
"""

func _log(strang: String):
	return strang

func _cust(cmd: String):
	return cmd

func openskinfold():
	OS.shell_open(ProjectSettings.globalize_path("user://skin"))

func _setmood(val: float):
	Console.warning(Lang.t("Эта команда временно отключена. Настроение можно повысить, поглаживая питомца"))
	return val

func reload():
	get_tree().change_scene_to_file("res://scenes/newmain.tscn")


func spawnExpie(petId: String = ""):
	var path = "res://scenes/sawianBase.tscn"
	var scene = load(path)
	var instance = scene.instantiate()

	if petId == "":
		var skinName = GlobalVariable.userSkinPath.substr(0, len(GlobalVariable.userSkinPath) - 1)
		skinName = skinName.substr(skinName.rfind("/") + 1)
		petId = gbData.addPet(skinName)
	instance.get_node("behavior").petId = petId

	var wrapper = Node2D.new()
	wrapper.scale = Vector2.ONE * gbData.settings.get("petScale", 4.0)

	get_tree().current_scene.add_child(wrapper)
	wrapper.owner = get_tree().current_scene

	wrapper.add_child(instance)
	instance.owner = get_tree().current_scene

	instance.global_position.x = float(GlobalVariable.screenWidth) / 2
	instance.global_position.y = - float(GlobalVariable.screenHeight) * 2
	wrapper.set_meta("Category", "entity")


func _additem(item: String = "containercrate"):
	# add crate only for now
	var path = "res://scenes/objects/" + item + ".tscn"
	if !ResourceLoader.exists(path):
		Console.error("No such object '" + item + "'")
		return
	var scene = load(path)
	var instance = scene.instantiate()
	instance.position = itemSpawnPosition() # до add_child
	get_tree().current_scene.add_child(instance)
	instance.owner = get_tree().current_scene
	instance.set_meta("itemName", item)
	GlobalVariable.itemGiven(instance) # 055.005: подарок, если персонаж ждал


## 054.9992: где появиться предмету. Курсор над рабочим столом - около курсора
## (CustomItems.spawnPosition). Курсор над консолью (нажали кнопку во вкладке
## Предметы) - рядом со случайным ИИ-персонажем, чуть выше, чтобы упал к нему:
## раньше предмет падал у консоли - в левом верхнем углу экрана (тест Alex 20.10).
func itemSpawnPosition() -> Vector2:
	var view: Vector2 = get_tree().root.get_visible_rect().size
	var petScale := float(gbData.settings.get("petScale", 4.0))
	var mouse := DisplayServer.mouse_get_position()
	if DisplayServer.get_window_at_screen_position(mouse) == DisplayServer.MAIN_WINDOW_ID:
		return CustomItems.spawnPosition(view, petScale)
	var pets: Array = get_tree().get_nodes_in_group("pets").filter(func(p): return not p.isPlayer and not p.isUnconscious)
	if pets.is_empty():
		pets = get_tree().get_nodes_in_group("pets")
	var crate := 32.0 * petScale
	var m := minf(2.5 * crate, minf(view.x, view.y) * 0.25)
	if pets.is_empty():
		return Vector2(view.x * 0.5 + randf_range(-3.0, 3.0) * crate, view.y * 0.4)
	var at: Vector2 = pets.pick_random().moveSys.rigidtorso.global_position
	var x := at.x + (1.0 if randf() < 0.5 else -1.0) * randf_range(1.0, 4.5) * crate
	return Vector2(clampf(x, m, view.x - m), clampf(at.y - 3.0 * crate, m, view.y - m))


func _cmd_changePlayerMode(combo: String = "") -> void:
	if combo == "":
		Console.print(Lang.t("Сейчас: [color=CYAN]%s[/color]. Пример: change_player_mode Ctrl+Shift+K") % PlayerManager.currentKeys())
		return
	if PlayerManager.setKeys(combo):
		Console.print(Lang.t("Режим игрока теперь: [color=CYAN]%s[/color]") % combo)
	else:
		Console.print(Lang.t("[color=RED]Не понял сочетание '%s'.[/color] Пиши через + без пробелов, например Ctrl+Alt+P") % combo)


func _cmd_petSize(value: float) -> void:
	gbData.settings["petScale"] = value
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	Console.print(Lang.t("Размер новых питомцев и предметов: [color=CYAN]%s[/color] (заспавни новых, чтобы увидеть - на уже существующих не действует)") % value)


## 054.95: раньше удаляла всех сразу. Теперь показывает список (до 8, по
## порядку спавна) и ждёт номер: 0 - выход, 1-8 - удалить одного.
## Убрать всех разом по-прежнему можно командой clearItems entity.
const DESPAWN_LIST_MAX := 8
func _cmd_despawnPet() -> void:
	var pets: Array = []
	for pet in get_tree().get_nodes_in_group("pets"):
		if is_instance_valid(pet) and not pet.is_queued_for_deletion():
			pets.append(pet)
	if pets.is_empty():
		Console.print(Lang.t("Питомцев на экране нет."))
		return
	# petId вида "id7" - чем больше число, тем позже заспавнен
	pets.sort_custom(func(a, b): return int(String(a.petId).trim_prefix("id")) < int(String(b.petId).trim_prefix("id")))
	pets = pets.slice(0, DESPAWN_LIST_MAX)
	Console.print(Lang.t("[color=ORANGE]Введи цифру 0, чтобы выйти из удаления[/color]"))
	Console.print(Lang.t("[color=ORANGE]Введи цифру 1-%d, чтобы удалить питомца[/color]") % pets.size())
	Console.print(Lang.t("0. выход"))
	for i in pets.size():
		var p = pets[i]
		Console.print("%d. %s%s" % [i + 1, PlayerManager.displayNameFor(p._skinTag()), Lang.t(" (игрок)") if p.isPlayer else ""])
	Console.pending_input = _despawnChoice.bind(pets)


func _despawnChoice(answer: String, pets: Array) -> void:
	if answer != "" and Console.has_command(answer.split(" ", false)[0]):
		Console.print(Lang.t("Выход из удаления."))
		Console.execute(answer)
		return
	if not answer.is_valid_int() or int(answer) < 0 or int(answer) > pets.size():
		Console.print(Lang.t("[color=ORANGE]Нужна цифра от 0 до %d - удаление отменено, введи despawn_pet ещё раз.[/color]") % pets.size())
		return
	var n := int(answer)
	if n == 0:
		Console.print(Lang.t("Выход из удаления."))
		return
	var pet = pets[n - 1]
	if not is_instance_valid(pet):
		Console.print(Lang.t("Этого питомца уже нет на экране."))
		return
	var shown: String = PlayerManager.displayNameFor(pet._skinTag())
	var wrapper: Node = pet.get_parent().get_parent()
	gbData.removePet(String(pet.petId))
	wrapper.queue_free()
	Console.print(Lang.t("Удалён: %s") % shown)


## 0.56 (тест Alex: «clear_items RSASS» и «clear_items фентанил» не убирали -
## сверялось только внутреннее имя файла, а у своих предметов оно custom_...).
## Теперь clear_items без слов - список с номерами, как ban_words/model_manager;
## clear_items <имя> понимает и название с карточки («фентанил», «RSASS»).
const CLEAR_EXCLUDE := ["Floor", "SideR", "SideL", "CanvasLayer", "CanvasLayer2"]

func clearObj(category: String = "") -> void:
	var want := category.strip_edges().to_lower()
	if want == "":
		_printClearMenu()
		return
	if want == "entity":
		_clearNodes(_clearCandidates(func(c): return String(c.get_meta("Category", "")) == "entity"))
		gbData.data["saw"] = {}
		print("cleared pet persistence data")
		return
	var found := _clearCandidates(func(c):
		if want == "object":
			return String(c.get_meta("Category", "")) == "object"
		return String(c.get_meta("itemName", "")).to_lower() == want or _clearKey(c) == want or _clearName(c).to_lower() == want or _clearRuName(c).to_lower() == want)
	if found.is_empty():
		Console.print(Lang.t("[color=ORANGE]Такого на экране нет: %s. Список с номерами - просто clear_items.[/color]") % category)
		return
	_clearNodes(found)


func _clearCandidates(filter: Callable) -> Array:
	var result: Array = []
	for child in get_tree().current_scene.get_children():
		if CLEAR_EXCLUDE.has(child.name) or child.is_queued_for_deletion():
			continue
		if filter.call(child):
			result.append(child)
	return result


func _clearKey(c: Node) -> String:
	if c.scene_file_path != "":
		return c.scene_file_path.get_file().get_basename().to_lower()
	return String(c.get_meta("itemName", "")).to_lower()


func _clearRuName(c: Node) -> String:
	var key := String(c.get_meta("itemName", "")) if c.scene_file_path == "" else c.scene_file_path.get_file().get_basename()
	if key.begins_with(CustomItems.KEY_PREFIX):
		return String(CustomItems.entry(key).get("name", key))
	var cards: Dictionary = load("res://Scripts/ui/terminal/itemsView.gd").ITEM_RU_NAMES
	return String(cards.get(key, key))


func _clearName(c: Node) -> String:
	var key := String(c.get_meta("itemName", "")) if c.scene_file_path == "" else c.scene_file_path.get_file().get_basename()
	if key.begins_with(CustomItems.KEY_PREFIX):
		return _clearRuName(c)
	return Lang.t(_clearRuName(c))


func _clearNodes(nodes: Array) -> void:
	for child in nodes:
		if not is_instance_valid(child):
			continue
		var nm := String(child.get_meta("itemName", ""))
		if gbData.data["saw"].has(nm): # удаляем персонажа
			gbData.removePet(nm)
		var drag = child.get_node_or_null("draggable") # держат мышью - сначала отпустить
		if drag and drag.get("_dragging"):
			drag._stopDrag()
		child.queue_free()


func _printClearMenu() -> void:
	var groups := {}
	var order: Array = []
	var pets := 0
	for c in _clearCandidates(func(_c): return true):
		var cat := String(c.get_meta("Category", ""))
		if cat == "entity":
			pets += 1
		elif cat == "object":
			var k := _clearKey(c)
			if not groups.has(k):
				groups[k] = {"name": _clearName(c), "nodes": []}
				order.append(k)
			groups[k]["nodes"].append(c)
	order.sort_custom(func(a, b): return String(groups[a]["name"]).naturalnocasecmp_to(String(groups[b]["name"])) < 0)
	var entries: Array = [{"all": "object"}, {"all": "entity"}]
	Console.print(Lang.t("Что убрать с экрана:"))
	Console.print(Lang.t("0. выход"))
	var total := 0
	for k in order:
		total += groups[k]["nodes"].size()
	Console.print(Lang.t("1. все предметы (%d)") % total)
	Console.print(Lang.t("2. все персонажи (%d)") % pets)
	for k in order:
		var g: Dictionary = groups[k]
		var count: int = g["nodes"].size()
		Console.print("%d. %s%s" % [entries.size() + 1, g["name"], (" x%d" % count) if count > 1 else ""])
		entries.append(g)
	Console.print(Lang.t("[color=ORANGE]Введи номер, чтобы убрать, 0 - выход[/color]"))
	Console.pending_input = _clearMenuAnswer.bind(entries)


func _clearMenuAnswer(answer: String, entries: Array) -> void:
	answer = answer.strip_edges()
	if answer == "0":
		Console.print(Lang.t("Выход из списка."))
		return
	if answer != "" and Console.has_command(answer.split(" ", false)[0]):
		Console.print(Lang.t("Выход из списка."))
		Console.execute(answer)
		return
	if not answer.is_valid_int() or int(answer) < 1 or int(answer) > entries.size():
		Console.print(Lang.t("[color=ORANGE]Нужна цифра от 0 до %d.[/color]") % entries.size())
		Console.pending_input = _clearMenuAnswer.bind(entries)
		return
	var e: Dictionary = entries[int(answer) - 1]
	if e.has("all"):
		clearObj(String(e["all"]))
		Console.print(Lang.t("Убраны все предметы.") if e["all"] == "object" else Lang.t("Убраны все персонажи."))
	else:
		_clearNodes(e["nodes"])
		Console.print(Lang.t("Убрано: %s") % e["name"])
	await get_tree().process_frame # queue_free срабатывает в конце кадра - список уже без убранного
	_printClearMenu()


## 054.998: full_reset вместо nuke_data. nuke_data срабатывала сразу, без
## вопросов, и не трогала лоры персонажей - пользы почти не было. Теперь
## настоящий заводской сброс с двумя подтверждениями (решение Alex).
const FULL_RESET_LIST := [
	"все настройки вернутся к значениям по умолчанию этой версии (интервалы, мат, флирт, FPS, звуки, монитор, размер консоли, запрещённые слова)",
	"все персонажи на экране и их состояние (здоровье, голод, настроение, зависимость) будут удалены, появится один персонаж по умолчанию",
	"8 встроенных персонажей (Dune, Expie, Leapy, Milky, Orange, Roza, Velvet, Voyager) вернутся к заводским лорам, фразам и паспортам",
	"ВСЕ ТВОИ ПРАВКИ В ЛОРАХ И ФРАЗАХ ВСТРОЕННЫХ ПЕРСОНАЖЕЙ ПРОПАДУТ (старые папки на всякий случай уйдут в full_reset_backup)",
	"общий файл фраз (TRANSLATION.json) вернётся к стоковому",
	"останутся: скачанные модели, выбранная модель и её настройки, персонажи, которых ты добавил сам, логи",
	"после сброса игра перезапустится",
]

func _cmd_fullReset() -> void:
	Console.print(Lang.t("[color=ORANGE]Сбросить игру к заводскому состоянию? Введи ДА, чтобы продолжить, что угодно другое - отмена.[/color]"))
	Console.pending_input = _fullResetStep1


func _fullResetStep1(answer: String) -> void:
	if answer.strip_edges().to_upper() != Lang.t("ДА"):
		Console.print(Lang.t("Сброс отменён."))
		return
	Console.print(Lang.t("[color=WHITE]После сброса:[/color]"))
	for line in FULL_RESET_LIST:
		Console.print("[color=#ff5a5a]- " + Lang.t(line) + "[/color]")
	Console.print(Lang.t("[color=ORANGE]Точно? Напиши VLLM, чтобы подтвердить, что угодно другое - отмена.[/color]"))
	Console.pending_input = _fullResetStep2


func _fullResetStep2(answer: String) -> void:
	if answer.strip_edges().to_upper() != "VLLM":
		Console.print(Lang.t("Сброс отменён."))
		return
	var backup: String = gbData.fullReset()
	Console.print(Lang.t("[color=GREEN]Сброс выполнен. Старые папки персонажей: %s. Перезапускаю игру...[/color]") % backup)
	await get_tree().create_timer(1.5).timeout
	OS.set_restart_on_exit(true, OS.get_cmdline_args())
	get_tree().quit()

func setmonitor(monitorIndex: int = 0):
	var maxIndex: int = DisplayServer.get_screen_count() - 1
	var clamped: int = clampi(monitorIndex, 0, maxi(maxIndex, 0))
	DisplayServer.window_set_current_screen(clamped)
	GlobalVariable.Fresize()
	# 054.96: запоминаем выбор (при запуске игра сама вызывает set_monitor
	# с сохранённым номером, а раньше сохранять было нечему)
	if int(gbData.settings.get("defaultMonitor", 0)) != clamped:
		gbData.settings["defaultMonitor"] = clamped
		gbData.savetodisk("user://CONFIG.json", gbData.settings)
		Console.print(Lang.t("Монитор: [color=CYAN]%d[/color] (из %d), запомнено.") % [clamped, maxIndex + 1])


## Случайный персонаж из папок скинов (раньше spawnExpie спавнил скин,
## последним выбранный во вкладке Skins, - обычно Voyager).
func _cmd_randomSawian() -> void:
	var names: Array = []
	var dir := DirAccess.open("user://skin")
	if dir:
		for d in dir.get_directories():
			if d != "Default" and d != "Body":
				names.append(d)
	if names.is_empty():
		Console.print(Lang.t("[color=RED]Не нашлось ни одного скина в папке skin.[/color]"))
		return
	var pick: String = names.pick_random()
	var previous: String = GlobalVariable.userSkinPath
	GlobalVariable.userSkinPath = "user://skin/%s/" % pick
	spawnExpie() # скин берётся из userSkinPath прямо при создании
	GlobalVariable.userSkinPath = previous
	Console.print(Lang.t("Появился: [color=CYAN]%s[/color]") % PlayerManager.displayNameFor(pick))

func resize(nx, ny, isForce = "no") -> String:
	var ex = str(nx).to_float()
	var ey = str(ny).to_float()
	if (
		(ex < 200 or ey < 100)
		or (ex > float(GlobalVariable.screenWidth) / 2 or ey > GlobalVariable.screenHeight)
		) and isForce == "no":
		Console.warning(Lang.t("Изменение размера консоли до такого значения не рекомендуется!"))
		Console.print(Lang.t("Введи '[url=resize_console {0} {1} force]resize_console {0} {1} force[/url]', если уверен(а)").format([nx, ny]))
		return Lang.t("[color=gray]ПРИМЕЧАНИЕ: размер консоли НЕ сохранится, если задан принудительно![/color]")
	# if it goes through, call a resize
	var _target_size = Vector2(ex, ey)
	resizeCommandCalled.emit(_target_size, true)
	#save to config
	if isForce == "no":
		gbData.settings.ConsoleSize.x = ex
		gbData.settings.ConsoleSize.y = ey

	#debugshit
	if gbData.devMode == true:
		print(gbData.settings.ConsoleSize.x)
		print(gbData.settings.ConsoleSize.y)

	# please work please

	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	return "resized"

func toggleExpieDebugIDs():
	toggleDebugText.emit()

func deathLoop():
	while true:
		Console.execute("log I_HATE_YOU")
		await get_tree().create_timer(.1).timeout

func _ready():
	# connect our signal to running initial commands
	runInitialCommands.connect(_do_i_cmds)

	# register commands
	# 054.96: имена команд через "_" (было toggleAI, despawnPet...); "log"
	# (вывести строку - нужна была только для отладки) убрана из списка
	Console.create_command("toggle_ai", _cmd_visionToggle, Lang.t("вкл/выкл ВСЕХ реакций ИИ (без аргументов = переключить)"))
	Console.create_command("toggle_profanity", _cmd_toggleProfanity, Lang.t("разрешает/запрещает мат в сгенерированных ИИ фразах (без аргументов = переключить)"))
	Console.create_command("toggle_flirt", _cmd_toggleFlirt, Lang.t("разрешает/запрещает лёгкий флирт при очень хорошем настроении (без аргументов = переключить)"))
	Console.create_command("toggle_live_physics", _cmd_toggleLivePhysics, Lang.t("живая физика: плавное вставание, руки, голова и хвост двигаются с инерцией (без аргументов = переключить, status - показать)"))
	Console.create_command("live_physics_strength", _cmd_livePhysicsStrength, Lang.t("сила живой физики: 0 - нет раскачки, 2 - обычная, 3 - сильнее; хвост на 1,5 слабее (без аргументов = показать)"))
	Console.create_command("toggle_debug_tags", _cmd_toggleDebugTags, Lang.t("добавляет к фразам ИИ префикс источника: [screen]/[state]/[pet]/[grab]/итд (без аргументов = переключить)"))
	Console.create_command("toggle_ai_log", _cmd_toggleAiLog, Lang.t("записывает каждую сгенерированную фразу (принятую или отклонённую + причину) в user://ai_debug_log.txt (без аргументов = переключить)"))
	Console.create_command("toggle_diagnostics", _cmd_toggleDiagnostics, Lang.t("отчёт диагностики для тестов: при запуске пишет diagnostics.txt в папку сохранений и раз в 10 минут - строку состояния (без аргументов = переключить)"))
	Console.create_command("ai_status", _cmd_aiStatus, Lang.t("показывает текущее состояние всех настроек ИИ"))
	Console.create_command("ai_creativity", _cmd_aiCreativity, Lang.t("0.0-1.5, выше = более дикие/случайные ответы, ниже = безопаснее/предсказуемее (стандартно 0.8 для gemma4:12b)"))
	Console.create_command("ai_repetition_guard", _cmd_aiRepetitionGuard, Lang.t("1.0-2.0, выше = меньше шанс повторять одну и ту же фразу снова и снова (стандартно 1.1 для gemma4:12b)"))
	Console.create_command("model_manager", _openModelManager, Lang.t("менеджер моделей Ollama: все скачанные модели (размер, подходит ли, настройки), выбрать, удалить или скачать новую"))
	Console.create_command("ai_model", _cmd_aiModel, Lang.t("то же, что model_manager; ai_model <имя> - сразу скачать и выбрать модель"))
	Console.hidden_commands.append("ai_model") # 054.999: работает, но в help не путает
	Console.create_command("potato_mode", _cmd_potatoMode, Lang.t("режим картошки - для медленных компьютеров с большими амбициями: ответ в чате печатается по предложениям, пока модель пишет дальше. potato_mode on / off / auto (сам, если модель пишет медленно); без слова - переключить"))
	Console.create_command("ban_words", _cmd_banwords, Lang.t("список слов/фраз, которые ИИ никогда не должен использовать: после списка вводи номер (удалить), слово (добавить) или 0 (выход)"))
	Console.create_command("reload_lore", LLMManager.reloadLore, Lang.t("перечитывает лор и паспорта всех персонажей (lore.txt, character.json) без перезапуска - наборы фраз создадутся заново только у тех, чей лор поменялся"))
	Console.create_command("resize_console", resize, Lang.t("размер окна консоли: resize_console <ширина> <высота> (проще растянуть уголок справа снизу)"))
	#dont use this it breaks alot of shit Console.create_command("reload", reload, "reload everything")
	Console.create_command("set_monitor", setmonitor, Lang.t("на каком мониторе живут персонажи: set_monitor <номер> (0 - основной, 1 - второй...), запоминается"))
	##Console.create_command("killExpie", killExpie, "Yeha")
	#Console.create_command("setMood", _setmood, "debugging tool that doesnt work because i disabled mood stuff for this build")
	Console.create_command("spawn", _additem, Lang.t("создаёт предмет у курсора: spawn <имя> (bread, bandage, syringe, medkit...). Проще - вкладка Items"))
	Console.create_command("clear_items", clearObj, Lang.t("убрать с экрана: clear_items - список с номерами (все предметы, все персонажи, каждый предмет), введи номер, 0 - выход; clear_items <название> - сразу этот предмет (бинт, RSASS)"))
	Console.create_command("despawn_pet", _cmd_despawnPet, Lang.t("показывает список питомцев на экране и удаляет одного по номеру (всех разом - clear_items entity)"))
	Console.create_command("random_sawian", _cmd_randomSawian, Lang.t("создаёт случайного персонажа из твоих скинов (конкретного - во вкладке Skins)"))
	Console.create_command("change_player_mode", _cmd_changePlayerMode, Lang.t("меняет клавиши входа/выхода из управления игроком (сейчас: Ctrl+Alt+P). Клавиши пишутся ВРУЧНУЮ через + без пробелов, например: change_player_mode Ctrl+Shift+K. Можно: Ctrl, Alt, Shift, Win + одна обычная клавиша (A-Z, 0-9, F1-F24, Space, Tab, Home, End, Insert, Delete, PageUp, PageDown, стрелки Left/Right/Up/Down)"))
	Console.create_command("pet_size", _cmd_petSize, Lang.t("меняет размер персонажа (по умолчанию 4.0) - действует на новых заспавненных, не на уже существующих"))
	#Console.create_command("openSkinFolder", openskinfold, "opens the skin folder")
	Console.create_command("full_reset", _cmd_fullReset, Lang.t("сброс к заводскому состоянию (с двойным подтверждением): настройки, персонажи на экране, лоры и фразы встроенных персонажей. Модель и её настройки остаются"))
	#Console.create_command("expieID", toggleExpieDebugIDs, "toggles debug IDs for expies")
	#Console.create_command("deathLoop", deathLoop, "please dont crash")
	_setupCommandUi()
	
func _do_i_cmds():
	if has_run_commands:
		return
	has_run_commands = true
	_ensureModelInstalled()

	# i thought this had to be run from the console node itself but turns out its reflected on all consoles! hooray!
	Console.execute("set_monitor {0}".format([int(gbData.settings.get("defaultMonitor", 0))]))
	Console.execute("help")
	Console.print(Lang.t("[color=PURPLE]Консоль можно открыть снова в любой момент: Ctrl + правый клик по любому персонажу![/color]"))
	Console.print(Lang.t("ЭКСПИ ИЛИ ЛЮБЫЕ ДРУГИЕ ПЕРСОНАЖИ, КОТОРЫЕ МОГУТ ЗДЕСЬ ПРИСУТСТВОВАТЬ, МНЕ НЕ ПРИНАДЛЕЖАТ. ЭТО ФАНАТСКИЙ ПРОЕКТ"))
	Console.print(Lang.t("ЕСЛИ ТЫ ЗАПЛАТИЛ(А) ЗА ЭТО ИЛИ СКАЧАЛ(А) НЕ С GITHUB — ТЫ СДЕЛАЛ(А) ЭТО НЕПРАВИЛЬНО!"))
	
## Resolves what a toggle command should do: bare call (state="toggle")
## flips the current value, "on"/"true"/"1" forces on, "off"/"false"/"0"
## forces off. This is what makes e.g. `toggleDebugTags` with no argument
## behave like an actual toggle instead of always turning back on.
func _resolveToggle(current: bool, state: String) -> bool:
	state = state.to_lower()
	if state in ["on", "true", "1", "yes"]:
		return true
	if state in ["off", "false", "0", "no"]:
		return false
	return not current

func _cmd_visionToggle(state: String = "toggle") -> void:
	var newVal := _resolveToggle(gbData.settings.get("llmVisionEnabled", true), state)
	LLMManager.setEnabled(newVal)
	_print_toggle_state("AI (toggle_ai)", newVal)

func _cmd_toggleProfanity(state: String = "toggle") -> void:
	var newVal := _resolveToggle(gbData.settings.get("llmAllowProfanity", false), state)
	LLMManager.setProfanityAllowed(newVal)
	_print_toggle_state("Profanity (toggle_profanity)", newVal)

func _cmd_toggleFlirt(state: String = "toggle") -> void:
	var newVal := _resolveToggle(gbData.settings.get("llmFlirtEnabled", false), state)
	LLMManager.setFlirtEnabled(newVal)
	_print_toggle_state("Flirt (toggle_flirt)", newVal)
	if newVal and LLMManager.weakModel():
		Console.print(LLMManager.weakModelWarning())

## F1: «Живая физика» (Scripts/impo/live_body.gd) - та же настройка, что и галочка в «Поведении».
func _cmd_toggleLivePhysics(state: String = "toggle") -> void:
	if state.strip_edges().to_lower() in ["status", "статус", "?"]:
		_print_toggle_state("Live physics (toggle_live_physics)", bool(gbData.settings.get("livePhysics", true)))
		return
	var newVal := _resolveToggle(gbData.settings.get("livePhysics", true), state)
	gbData.settings["livePhysics"] = newVal
	gbData.savetodisk(gbData.conPath, gbData.settings)
	# тест Alex F1: галочка в настройках не знала о команде и показывала старое - обновить
	# без сигнала (иначе галочка записала бы настройку ещё раз)
	for n in get_tree().root.find_children("*", "PanelContainer", true, false):
		if n.get("key") == "livePhysics" and n.get("_checkbox") != null:
			n._checkbox.set_pressed_no_signal(newVal)
	gbData.SettingsChanged.emit()
	_print_toggle_state("Live physics (toggle_live_physics)", newVal)

func _cmd_livePhysicsStrength(value: String = "") -> void:
	if value.strip_edges() != "":
		if not value.strip_edges().replace(",", ".").is_valid_float():
			Console.print(Lang.t("[color=RED]Нужно число от 0 до 3, например: live_physics_strength 1.5[/color]"))
			return
		gbData.settings["livePhysicsStrength"] = clampf(value.strip_edges().replace(",", ".").to_float(), 0.0, 3.0)
		gbData.savetodisk(gbData.conPath, gbData.settings)
	Console.print(Lang.t("Сила живой физики: [color=CYAN]%.1f[/color] (0 - нет раскачки, 2 - обычная, 3 - самая сильная; хвост - на 1,5 слабее)") % float(gbData.settings.get("livePhysicsStrength", 2.0)))

func _cmd_toggleDebugTags(state: String = "toggle") -> void:
	var newVal := _resolveToggle(LLMManager.debugTags, state)
	LLMManager.setDebugTags(newVal)
	_print_toggle_state("Debug tags (toggle_debug_tags)", newVal)

func _cmd_toggleAiLog(state: String = "toggle") -> void:
	var newVal := _resolveToggle(gbData.settings.get("logAiLines", false), state)
	LLMManager.setLogAiLines(newVal)
	_print_toggle_state("AI line log -> user://ai_debug_log.txt (toggle_ai_log)", newVal)

## F2.10 (Alex): в релизе отчёт диагностики выключен по умолчанию; тестер включает здесь.
func _cmd_toggleDiagnostics(state: String = "toggle") -> void:
	var newVal := _resolveToggle(gbData.settings.get("diagnosticsEnabled", false), state)
	gbData.settings["diagnosticsEnabled"] = newVal
	gbData.savetodisk(gbData.conPath, gbData.settings)
	Diagnostics.setEnabled(newVal)
	_print_toggle_state("Diagnostics -> user://diagnostics.txt (toggle_diagnostics)", newVal)

func _print_toggle_state(label: String, on: bool) -> void:
	if on:
		Console.print(label + Lang.t(": [color=GREEN]ВКЛ[/color] (запусти команду ещё раз, чтобы выключить)"))
	else:
		Console.print(label + Lang.t(": [color=RED]ВЫКЛ[/color] (запусти команду ещё раз, чтобы включить)"))
	_statesChanged()

func _cmd_aiStatus() -> void:
	_print_toggle_state("AI (toggle_ai)", gbData.settings.get("llmVisionEnabled", true))
	_print_toggle_state("Profanity (toggle_profanity)", gbData.settings.get("llmAllowProfanity", false))
	_print_toggle_state("Flirt (toggle_flirt)", gbData.settings.get("llmFlirtEnabled", false))
	_print_toggle_state("Debug tags (toggle_debug_tags)", LLMManager.debugTags)
	_print_toggle_state("AI line log (toggle_ai_log)", gbData.settings.get("logAiLines", false))
	_printPotatoMode()
	Console.print(Lang.t("Интервал реакций на экран: [color=CYAN]%s-%s сек[/color]") % [LLMManager.minScreenInterval, LLMManager.maxScreenInterval])
	var talkRange: Vector2 = preload("res://Scripts/impo/behavior.gd").petTalkRange()
	Console.print(Lang.t("Интервал разговоров ИИ-персов: [color=CYAN]%s-%s сек[/color]") % [talkRange.x, talkRange.y])
	Console.print(Lang.t("Модель: [color=CYAN]%s[/color]") % LLMManager.modelName)
	Console.print(Lang.t("Creativity (ai_creativity): [color=CYAN]%s[/color] (0=предсказуемо, 1.5=дико)") % LLMManager.creativity)
	Console.print(Lang.t("Repetition guard (ai_repetition_guard): [color=CYAN]%s[/color] (1=может повторяться, 2=почти не повторяется)") % LLMManager.repetitionGuard)
	LLMManager.listAvailableModels()

## K1: «режим картошки» (LLMManager.potatoActive): ответ в чате по предложениям.
func _cmd_potatoMode(state: String = "toggle") -> void:
	var s := state.to_lower()
	var mode := ""
	if s in ["auto", "авто"]:
		mode = "auto"
	elif s in ["on", "true", "1", "yes", "вкл"]:
		mode = "on"
	elif s in ["off", "false", "0", "no", "выкл"]:
		mode = "off"
	else:
		mode = "off" if LLMManager.potatoActive() else "on"
	LLMManager.setPotatoMode(mode)
	_printPotatoMode()

func _printPotatoMode() -> void:
	var on := LLMManager.potatoActive()
	var why := ""
	match LLMManager.potatoMode():
		"on":
			why = Lang.t(" (включён вручную; сам - potato_mode auto)")
		"off":
			why = Lang.t(" (выключен вручную; сам - potato_mode auto)")
		_:
			var tps := LLMManager.measuredTps()
			if tps > 0.0:
				why = Lang.t(" (сам: модель пишет %d ток/с)") % int(round(tps))
			elif on:
				why = Lang.t(" (сам: большая модель)")
			else:
				why = Lang.t(" (сам: включится, если модель пишет медленно)")
	Console.print(Lang.t("Режим картошки (potato_mode): ") + (Lang.t("[color=GREEN]ВКЛ[/color]") if on else Lang.t("[color=RED]ВЫКЛ[/color]")) + why)
	_statesChanged()

func _cmd_aiCreativity(value: float) -> void:
	LLMManager.setCreativity(value)
	Console.print(Lang.t("Креативность: [color=CYAN]%s[/color]") % LLMManager.creativity)

func _cmd_aiRepetitionGuard(value: float) -> void:
	LLMManager.setRepetitionGuard(value)
	Console.print(Lang.t("Защита от повторов: [color=CYAN]%s[/color]") % LLMManager.repetitionGuard)

## 054.998: model_manager (и ai_model - то же меню). Все скачанные модели:
## размер, подходит ли игре (зрение и без режима размышлений), какая сейчас,
## какие под неё настройки. Дальше как в ban_words: вводишь ответ без имени
## команды - номер (выбрать), "удалить N", имя новой модели (скачать), 0 - выход.
## Новая модель проверяется ДО скачивания по реестру Ollama; если заранее не
## понять - после, а неподходящую можно сразу удалить.
const RECOMMENDED_MODELS := ["gemma4:12b", "qwen3-vl:8b-instruct"] # 04.11: gemma - по умолчанию, qwen - для слабых ПК
# было: ["qwen3-vl:8b-instruct", "gemma4:12b"] # 055.004: gemma4 вместо gemma3 и ministral-3:14b (стенды 24.10: лучше обеих в ~8 раз чаще)

func _cmd_aiModel(name: String = "") -> void:
	if name != "":
		_downloadAndSwitch(name)
		return
	_openModelManager()


func _openModelManager() -> void:
	Console.print(Lang.t("Спрашиваю у Ollama список моделей..."))
	LLMManager.fetchModels(_showModelMenu)


func _showModelMenu(names: Array, ok: bool) -> void:
	if not ok:
		Console.print(Lang.t("[color=RED]Ollama не ответила - проверь, что она запущена (значок в трее).[/color]"))
		return
	# 054.9992: от меньшей к большей (8b - 1, 12b - 2, 14b - 3)
	names.sort_custom(func(a, b): return float(LLMManager.modelSizes.get(a, 0.0)) < float(LLMManager.modelSizes.get(b, 0.0)))
	var problems := {}
	for n in names:
		problems[n] = await _checkModelAsync(String(n))
	Console.print(Lang.t("Скачанные модели (сейчас: [color=CYAN]%s[/color]):") % LLMManager.modelName)
	Console.print(Lang.t("0. выход"))
	for i in names.size():
		var n: String = names[i]
		var p: String = problems[n]
		var line := "%d. %s  [color=GRAY]%s[/color]  " % [i + 1, n, LLMManager.gbText(LLMManager.modelSizes.get(n, 0.0))]
		line += (Lang.t("[color=RED]не подходит: %s[/color]") % p) if p != "" else Lang.t("[color=GREEN]подходит[/color]")
		line += "  [color=GRAY]%s[/color]" % _modelSettingsText(n)
		if n == LLMManager.modelName:
			line += Lang.t("  [color=CYAN]<- сейчас[/color]")
		Console.print(line)
	if names.is_empty():
		Console.print(Lang.t("(пока ни одной)"))
	var missing: Array = RECOMMENDED_MODELS.filter(func(m): return not names.has(m))
	if not missing.is_empty():
		Console.print(Lang.t("Можно скачать (подходят игре): [color=CYAN]%s[/color]") % ", ".join(missing))
	Console.print(Lang.t("[color=ORANGE]Введи номер и нажми Enter - выбрать модель[/color]"))
	Console.print(Lang.t("[color=ORANGE]Введи «удалить» и номер (например: удалить 2) - удалить модель[/color]"))
	Console.print(Lang.t("[color=ORANGE]Введи имя новой модели - скачать её[/color]"))
	Console.print(Lang.t("[color=ORANGE]0 - выход. Игре подходят только модели со зрением (vision) и без режима размышлений (thinking)[/color]"))
	Console.pending_input = _modelMenuAnswer.bind(names, problems)


## Настройки под модель: у текущей - те, что стоят сейчас; у остальных - что
## поставится при переключении (свой набор есть только у проверенных моделей).
func _modelSettingsText(n: String) -> String:
	if n == LLMManager.modelName:
		return Lang.t("креативность %s, защита от повторов %s") % [LLMManager.creativity, LLMManager.repetitionGuard]
	if LLMManager.MODEL_PRESETS.has(n):
		return Lang.t("креативность %s, защита от повторов %s") % LLMManager.MODEL_PRESETS[n]
	return Lang.t("настройки останутся текущими")


func _checkModelAsync(name: String) -> String:
	var result := [null]
	LLMManager.checkModel(name, func(p: String): result[0] = p)
	while result[0] == null:
		await get_tree().process_frame
	return result[0]


func _modelMenuAnswer(answer: String, names: Array, problems: Dictionary) -> void:
	answer = answer.strip_edges()
	if answer == "0":
		Console.print(Lang.t("Выход из меню моделей."))
		return
	if answer.is_valid_int():
		var i := int(answer) - 1
		if i < 0 or i >= names.size():
			Console.print(Lang.t("[color=ORANGE]Нет модели под номером %s.[/color]") % answer)
			Console.pending_input = _modelMenuAnswer.bind(names, problems)
			return
		var p: String = problems.get(names[i], "")
		if p != "":
			Console.print(Lang.t("[color=RED]%s не подойдёт: %s. Игре нужна модель со зрением и без режима размышлений.[/color]") % [names[i], p])
			Console.pending_input = _modelMenuAnswer.bind(names, problems)
			return
		_switchModel(String(names[i]), false) # уже скачана
		return
	var words := answer.split(" ", false)
	if words.size() == 2 and words[0].to_lower() == Lang.t("удалить") and words[1].is_valid_int():
		var d := int(words[1]) - 1
		if d < 0 or d >= names.size():
			Console.print(Lang.t("[color=ORANGE]Нет модели под номером %s.[/color]") % words[1])
			Console.pending_input = _modelMenuAnswer.bind(names, problems)
			return
		if names[d] == LLMManager.modelName:
			Console.print(Lang.t("[color=ORANGE]%s сейчас выбрана - сначала переключись на другую, потом удаляй.[/color]") % names[d])
			Console.pending_input = _modelMenuAnswer.bind(names, problems)
			return
		_askDeleteModel(String(names[d]), true)
		return
	if Console.has_command(words[0]):
		Console.print(Lang.t("Выход из меню моделей."))
		Console.execute(answer)
		return
	_downloadAndSwitch(answer)


## Подтверждение удаления: номер-да/0-нет. backToMenu - после ответа снова меню.
func _askDeleteModel(name: String, backToMenu: bool) -> void:
	Console.print(Lang.t("[color=YELLOW]Удалить %s и освободить %s? 1 - да, 0 - нет[/color]") % [name, LLMManager.gbText(LLMManager.modelSizes.get(name, 0.0))])
	Console.pending_input = _deleteModelAnswer.bind(name, backToMenu)


func _deleteModelAnswer(answer: String, name: String, backToMenu: bool) -> void:
	if answer.strip_edges() == "1":
		if await LLMManager.deleteModel(name):
			Console.print(Lang.t("Модель [color=CYAN]%s[/color] удалена.") % name)
		else:
			Console.print(Lang.t("[color=RED]Не получилось удалить %s - попробуй в командной строке: ollama rm %s[/color]") % [name, name])
	else:
		Console.print(Lang.t("Удаление отменено."))
	if backToMenu:
		_openModelManager()


## Новая модель по имени: проверить по реестру -> скачать с полоской ->
## проверить у Ollama -> переключиться, только если подходит.
func _downloadAndSwitch(name: String) -> void:
	name = name.strip_edges()
	Console.print(Lang.t("Проверяю модель [color=CYAN]%s[/color] до скачивания...") % name)
	var pre: Dictionary = await LLMManager.checkRegistry(name)
	if pre["sure"] and pre["problem"] != "":
		Console.print(Lang.t("[color=RED]%s не подойдёт: %s. Ничего не скачиваю, модель не переключена (сейчас: %s).[/color]") % [name, pre["problem"], LLMManager.modelName])
		return
	if not pre["sure"]:
		Console.print(Lang.t("[color=ORANGE]Заранее проверить %s не получилось - проверю после скачивания. Напоминание: нужна модель со зрением (vision) и без режима размышлений (thinking).[/color]") % name)
	LLMManager.pullModel(name, func(downloaded: bool):
		if not downloaded:
			return # pullModel уже написал, что не так
		LLMManager.checkModel(name, func(p: String):
			if p != "":
				Console.print(Lang.t("[color=RED]%s скачана, но не подойдёт: %s. Модель не переключена (сейчас: %s).[/color]") % [name, p, LLMManager.modelName])
				LLMManager.fetchModels(func(_n, _ok): _askDeleteModel(name, false)) # узнать размер
			else:
				_switchModel(name, false)))


func _switchModel(name: String, pull: bool = true) -> void:
	LLMManager.setModel(name, pull)
	Console.print(Lang.t("Модель переключена на: [color=CYAN]%s[/color]") % name)
	_statesChanged()

func _cmd_banwords(w1: String = "", w2: String = "", w3: String = "", w4: String = "") -> void:
	var words: Array = gbData.settings.get("llmBanWords", [])

	if w1 == "":
		_printBanwordsMenu(words)
		Console.pending_input = _banwordsAnswer
		return

	if w1 == "0" and w2 == "":
		Console.print(Lang.t("Отмена."))
		return

	# same number twice = confirm delete
	if w1.is_valid_int() and w2.is_valid_int() and w3 == "" and w1 == w2:
		var idx: int = int(w1) - 1
		if idx >= 0 and idx < words.size():
			var removed = words[idx]
			words.remove_at(idx)
			Console.print(Lang.t("Удалено: [color=RED]%s[/color]") % removed)
		else:
			Console.print(Lang.t("[color=RED]Нет слова под таким номером.[/color]"))
	elif w1.is_valid_int() and w2 == "":
		Console.print(Lang.t("[color=YELLOW]Введи номер ЕЩЁ РАЗ через пробел, чтобы подтвердить удаление (например: ban_words %s %s).[/color]") % [w1, w1])
		_printBanwordsMenu(words)
		Console.pending_input = _banwordsAnswer
		return
	else:
		var parts: Array = []
		for w in [w1, w2, w3, w4]:
			if w != "":
				parts.append(w)
		var phrase: String = " ".join(parts)
		words.append(phrase)
		Console.print(Lang.t("Добавлено: [color=GREEN]%s[/color]") % phrase)

	gbData.settings["llmBanWords"] = words
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	LLMManager.setBanWords(words)
	_printBanwordsMenu(words)
	Console.pending_input = _banwordsAnswer

func _printBanwordsMenu(words: Array) -> void:
	Console.print(Lang.t("Запрещённые слова/фразы:"))
	if words.is_empty():
		Console.print(Lang.t("(пусто)"))
	for i in words.size():
		Console.print("%d. %s" % [i + 1, words[i]])
	Console.print(Lang.t("[color=ORANGE]Введи цифру 0, чтобы выйти из списка[/color]"))
	Console.print(Lang.t("[color=ORANGE]Введи номер, чтобы удалить слово (потом тот же номер ещё раз - подтвердить)[/color]"))
	Console.print(Lang.t("[color=ORANGE]Введи слово или фразу, чтобы добавить её[/color]"))


## 054.96: banwords работает как despawnPet - после списка просто вводишь
## ответ, без "ban_words" впереди. Список ждёт ответов, пока не введёшь 0.
## Если введена другая команда консоли - выходим из списка и выполняем её
## (иначе "toggle_ai" стал бы запрещённым словом).
func _banwordsAnswer(answer: String) -> void:
	var words: Array = gbData.settings.get("llmBanWords", [])
	if answer == "0":
		Console.print(Lang.t("Выход из списка запрещённых слов."))
		return
	if Console.has_command(answer.split(" ", false)[0]):
		Console.print(Lang.t("Выход из списка запрещённых слов."))
		Console.execute(answer)
		return
	if answer.is_valid_int():
		var idx := int(answer) - 1
		if idx < 0 or idx >= words.size():
			Console.print(Lang.t("[color=RED]Нет слова под таким номером.[/color]"))
		else:
			Console.print(Lang.t("[color=YELLOW]Удалить «%s»? Введи %s ещё раз, чтобы подтвердить, или что угодно другое - отмена.[/color]") % [words[idx], answer])
			Console.pending_input = _banwordsConfirm.bind(idx, answer)
			return
	else:
		words.append(answer)
		Console.print(Lang.t("Добавлено: [color=GREEN]%s[/color]") % answer)
		_saveBanwords(words)
	_printBanwordsMenu(words)
	Console.pending_input = _banwordsAnswer


func _banwordsConfirm(answer: String, idx: int, number: String) -> void:
	var words: Array = gbData.settings.get("llmBanWords", [])
	if answer == number and idx < words.size():
		Console.print(Lang.t("Удалено: [color=RED]%s[/color]") % words[idx])
		words.remove_at(idx)
		_saveBanwords(words)
	else:
		Console.print(Lang.t("Удаление отменено."))
	_printBanwordsMenu(words)
	Console.pending_input = _banwordsAnswer


func _saveBanwords(words: Array) -> void:
	gbData.settings["llmBanWords"] = words
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	LLMManager.setBanWords(words)


## 054.997: в настройках может остаться модель, которой нет в Ollama (опечатка
## при скачивании в 054.995 переключала на неё). При запуске - на подходящую
## скачанную: сначала из рекомендованных, иначе первую.
func _ensureModelInstalled() -> void:
	LLMManager.fetchModels(func(names: Array, ok: bool):
		if not ok or names.is_empty() or names.has(LLMManager.modelName):
			return
		# 054.998: только на ПОДХОДЯЩУЮ модель (со зрением, без размышлений) -
		# раньше без рекомендованных бралась первая попавшаяся, хоть без зрения
		var ordered: Array = RECOMMENDED_MODELS.filter(func(m): return names.has(m))
		for n in names:
			if not ordered.has(n):
				ordered.append(n)
		for n in ordered:
			if await _checkModelAsync(String(n)) == "":
				Console.print(Lang.t("[color=ORANGE]Модели %s нет в Ollama - переключаюсь на %s.[/color]") % [LLMManager.modelName, n])
				_switchModel(String(n), false)
				return
		Console.print(Lang.t("[color=RED]Модели %s нет в Ollama, а среди скачанных нет подходящей (нужна со зрением и без режима размышлений). Открой model_manager и скачай, например, %s.[/color]") % [LLMManager.modelName, RECOMMENDED_MODELS[0]]))


# ---------------- 04.11: «юзер-френдли» консоль (схема Alex) ----------------
# Список help живой: зелёные команды (переключатели и кнопки) срабатывают прямо по щелчку
# в списке, рядом видно ВКЛ/ВЫКЛ; красные открывают окошко справа от консоли (CommandWindows);
# синие спрятаны из списка, но набрать их руками можно. Набирать любые команды в строке
# консоли можно, как раньше: окошки и щелчки выполняют те же самые команды.

const COMMAND_KINDS := {
	"toggle_ai": "toggle", "toggle_ai_log": "toggle", "toggle_flirt": "toggle", "toggle_diagnostics": "toggle",
	"toggle_live_physics": "toggle", "toggle_profanity": "toggle", "potato_mode": "toggle",
	"ai_status": "button", "clear": "button", "full_reset": "button", "random_sawian": "button", "reload_lore": "button",
	"ai_creativity": "window", "ai_repetition_guard": "window", "ban_words": "window", "change_player_mode": "window",
	"clear_items": "window", "despawn_pet": "window", "model_manager": "window", "pet_size": "window",
	"resize_console": "window", "set_monitor": "window",
}
## синие на схеме: «нужно ли?» - не в списке help, но работают (тестеры знают)
const HIDDEN_FROM_HELP := ["diag_report", "live_physics_strength", "spawn", "toggle_debug_tags"]

var _statesPending := false
## окошки красных команд (Scripts/ui/commandWindows.gd) - создаёт консоль (terminalMain)
var commandWindows: Node = null


func _setupCommandUi() -> void:
	Console.command_kinds = COMMAND_KINDS
	Console.state_text = _commandStateText
	if not Console.command_link_clicked.is_connected(_onCommandLink):
		Console.command_link_clicked.connect(_onCommandLink)
	for c in HIDDEN_FROM_HELP:
		if not Console.hidden_commands.has(c):
			Console.hidden_commands.append(c)
	# галочки во вкладке Настройки (флирт, мат, живая физика...) - тоже обновляют список
	if not gbData.SettingsChanged.is_connected(_statesChanged):
		gbData.SettingsChanged.connect(_statesChanged)


## Состояние поменялось - список help перерисуется один раз в конце кадра (ai_status
## печатает шесть строк подряд - перерисовка всё равно одна).
func _statesChanged() -> void:
	if _statesPending:
		return
	_statesPending = true
	_flushStates.call_deferred()


func _flushStates() -> void:
	_statesPending = false
	Console.states_changed.emit()


func _toggleOn(cmd: String) -> bool:
	match cmd:
		"toggle_ai":
			return bool(gbData.settings.get("llmVisionEnabled", true))
		"toggle_ai_log":
			return bool(gbData.settings.get("logAiLines", false))
		"toggle_diagnostics":
			return bool(gbData.settings.get("diagnosticsEnabled", false))
		"toggle_flirt":
			return bool(gbData.settings.get("llmFlirtEnabled", false))
		"toggle_live_physics":
			return bool(gbData.settings.get("livePhysics", true))
		"toggle_profanity":
			return bool(gbData.settings.get("llmAllowProfanity", false))
	return false


## 04.11 (Alex: «выглядят потрясно, добавляем»): пиксельные значки assets/ui/pixicons (12x12 и меньше),
## в консоли - целым множителем, как галочка в окошках.
const PIXICON_SIZES := {"on": Vector2i(12, 7), "off": Vector2i(12, 7), "off_grey": Vector2i(12, 7), "window": Vector2i(10, 9), "run": Vector2i(5, 10), "potato": Vector2i(12, 10)}
func _pix(name: String) -> String:
	var s := maxi(2, int(round(2.0 * load("res://Scripts/ui/terminal/terminalMain.gd").textScale()))) # load: автозагрузка компилируется раньше class_name
	var sz: Vector2i = PIXICON_SIZES.get(name, Vector2i(12, 12)) * s
	return "[img=%dx%d]res://assets/ui/pixicons/%s.png[/img] " % [sz.x, sz.y, name]


## Что показать в списке help рядом с командой: пиксельный значок + слово.
func _commandStateText(cmd: String) -> String:
	match String(COMMAND_KINDS.get(cmd, "")):
		"toggle":
			if cmd == "potato_mode":
				var active := LLMManager.potatoActive()
				var mark := _pix("potato")
				var color := "#7f7" if active else "#f88"
				match LLMManager.potatoMode():
					"on":
						return "[color=%s]%s%s[/color]" % [color, mark, Lang.t("ВКЛ")]
					"off":
						return "[color=%s]%s%s[/color]" % [color, mark, Lang.t("ВЫКЛ")]
					_:
						return "[color=%s]%s%s[/color]" % [color, mark, Lang.t("АВТО")]
			if cmd == "toggle_flirt" and LLMManager.weakModel():
				return _pix("off_grey") + "[color=#999]%s[/color]" % Lang.t("ВЫКЛ: слабая модель")
			if _toggleOn(cmd):
				return _pix("on") + "[color=#7f7]%s[/color]" % Lang.t("ВКЛ")
			return _pix("off") + "[color=#f88]%s[/color]" % Lang.t("ВЫКЛ")
		"window":
			return _pix("window") + "[color=#7cf]%s[/color]" % Lang.t("открыть")
		"button":
			return _pix("run") + "[color=#fc7]%s[/color]" % Lang.t("НАЖАТЬ")
	return ""


## Щелчок по команде в списке help.
func _onCommandLink(cmd: String) -> void:
	match String(COMMAND_KINDS.get(cmd, "")):
		"toggle":
			if cmd == "potato_mode": # три положения по кругу: авто -> вкл -> выкл -> авто
				var next: String = {"auto": "on", "on": "off"}.get(LLMManager.potatoMode(), "auto")
				Console.execute("potato_mode " + next)
			else:
				Console.execute(cmd)
		"window":
			if commandWindows != null and is_instance_valid(commandWindows):
				commandWindows.open(cmd)
			else:
				Console.execute(cmd)
		_:
			Console.execute(cmd)


# --- то, чем пользуются окошки (те же действия, что у команд) ---

## clear_items: что можно убрать - [{label, all: "object"/"entity"} | {label, nodes}]
func clearMenuEntries() -> Array:
	var groups := {}
	var order: Array = []
	var pets := 0
	var total := 0
	for c in _clearCandidates(func(_c): return true):
		var cat := String(c.get_meta("Category", ""))
		if cat == "entity":
			pets += 1
		elif cat == "object":
			total += 1
			var k := _clearKey(c)
			if not groups.has(k):
				groups[k] = {"name": _clearName(c), "nodes": []}
				order.append(k)
			groups[k]["nodes"].append(c)
	order.sort_custom(func(a, b): return String(groups[a]["name"]).naturalnocasecmp_to(String(groups[b]["name"])) < 0)
	var entries: Array = [
		{"label": Lang.t("все предметы (%d)") % total, "all": "object"},
		{"label": Lang.t("все персонажи (%d)") % pets, "all": "entity"},
	]
	for k in order:
		var g: Dictionary = groups[k]
		var count: int = g["nodes"].size()
		entries.append({"label": "%s%s" % [g["name"], (" x%d" % count) if count > 1 else ""], "nodes": g["nodes"], "name": g["name"]})
	return entries


func clearMenuApply(e: Dictionary) -> void:
	if e.has("all"):
		clearObj(String(e["all"]))
		Console.print(Lang.t("Убраны все предметы.") if e["all"] == "object" else Lang.t("Убраны все персонажи."))
	else:
		_clearNodes(e["nodes"])
		Console.print(Lang.t("Убрано: %s") % e["name"])


## despawn_pet: питомцы на экране по порядку появления
func despawnList() -> Array:
	var pets: Array = []
	for pet in get_tree().get_nodes_in_group("pets"):
		if is_instance_valid(pet) and not pet.is_queued_for_deletion():
			pets.append(pet)
	pets.sort_custom(func(a, b): return int(String(a.petId).trim_prefix("id")) < int(String(b.petId).trim_prefix("id")))
	return pets


func despawnOne(pet: Node) -> void:
	if not is_instance_valid(pet) or pet.is_queued_for_deletion():
		Console.print(Lang.t("Этого питомца уже нет на экране."))
		return
	var shown: String = PlayerManager.displayNameFor(pet._skinTag())
	var wrapper: Node = pet.get_parent().get_parent()
	gbData.removePet(String(pet.petId))
	wrapper.queue_free()
	Console.print(Lang.t("Удалён: %s") % shown)


## ban_words: добавить фразу / удалить по номеру (с 1)
func banwordsList() -> Array:
	return (gbData.settings.get("llmBanWords", []) as Array).duplicate()


func banwordAdd(phrase: String) -> void:
	phrase = phrase.strip_edges()
	if phrase == "":
		return
	var words: Array = gbData.settings.get("llmBanWords", [])
	words.append(phrase)
	_saveBanwords(words)
	Console.print(Lang.t("Добавлено: [color=GREEN]%s[/color]") % phrase)


func banwordRemove(number: int) -> bool:
	var words: Array = gbData.settings.get("llmBanWords", [])
	var idx := number - 1
	if idx < 0 or idx >= words.size():
		return false
	Console.print(Lang.t("Удалено: [color=RED]%s[/color]") % words[idx])
	words.remove_at(idx)
	_saveBanwords(words)
	return true


## model_manager: [{name, size, problem, current}] - от меньшей к большей; ok=false - Ollama молчит
func fetchModelRows(callback: Callable) -> void:
	LLMManager.fetchModels(func(names: Array, ok: bool):
		if not ok:
			callback.call([], false)
			return
		names.sort_custom(func(a, b): return float(LLMManager.modelSizes.get(a, 0.0)) < float(LLMManager.modelSizes.get(b, 0.0)))
		var rows: Array = []
		for n in names:
			var p: String = await _checkModelAsync(String(n))
			rows.append({"name": String(n), "size": LLMManager.gbText(LLMManager.modelSizes.get(n, 0.0)), "problem": p, "current": String(n) == LLMManager.modelName, "settings": _modelSettingsText(String(n))})
		callback.call(rows, true))


func modelSelect(name: String) -> void:
	_switchModel(name, false)


func modelDownload(name: String) -> void:
	if name.strip_edges() != "":
		_downloadAndSwitch(name.strip_edges())


func modelDelete(name: String) -> void:
	if name == LLMManager.modelName:
		Console.print(Lang.t("[color=ORANGE]%s сейчас выбрана - сначала переключись на другую, потом удаляй.[/color]") % name)
		return
	if await LLMManager.deleteModel(name):
		Console.print(Lang.t("Модель [color=CYAN]%s[/color] удалена.") % name)
	else:
		Console.print(Lang.t("[color=RED]Не получилось удалить %s - попробуй в командной строке: ollama rm %s[/color]") % [name, name])
