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
	Console.warning("Эта команда временно отключена. Настроение можно повысить, поглаживая питомца")
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
		Console.print("Сейчас: [color=CYAN]%s[/color]. Пример: change_player_mode Ctrl+Shift+K" % PlayerManager.currentKeys())
		return
	if PlayerManager.setKeys(combo):
		Console.print("Режим игрока теперь: [color=CYAN]%s[/color]" % combo)
	else:
		Console.print("[color=RED]Не понял сочетание '%s'.[/color] Пиши через + без пробелов, например Ctrl+Alt+P" % combo)


func _cmd_petSize(value: float) -> void:
	gbData.settings["petScale"] = value
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	Console.print("Размер новых питомцев и предметов: [color=CYAN]%s[/color] (заспавни новых, чтобы увидеть - на уже существующих не действует)" % value)


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
		Console.print("Питомцев на экране нет.")
		return
	# petId вида "id7" - чем больше число, тем позже заспавнен
	pets.sort_custom(func(a, b): return int(String(a.petId).trim_prefix("id")) < int(String(b.petId).trim_prefix("id")))
	pets = pets.slice(0, DESPAWN_LIST_MAX)
	Console.print("[color=ORANGE]Введи цифру 0, чтобы выйти из удаления[/color]")
	Console.print("[color=ORANGE]Введи цифру 1-%d, чтобы удалить питомца[/color]" % pets.size())
	Console.print("0. выход")
	for i in pets.size():
		var p = pets[i]
		Console.print("%d. %s%s" % [i + 1, PlayerManager.displayNameFor(p._skinTag()), " (игрок)" if p.isPlayer else ""])
	Console.pending_input = _despawnChoice.bind(pets)


func _despawnChoice(answer: String, pets: Array) -> void:
	if answer != "" and Console.has_command(answer.split(" ", false)[0]):
		Console.print("Выход из удаления.")
		Console.execute(answer)
		return
	if not answer.is_valid_int() or int(answer) < 0 or int(answer) > pets.size():
		Console.print("[color=ORANGE]Нужна цифра от 0 до %d - удаление отменено, введи despawn_pet ещё раз.[/color]" % pets.size())
		return
	var n := int(answer)
	if n == 0:
		Console.print("Выход из удаления.")
		return
	var pet = pets[n - 1]
	if not is_instance_valid(pet):
		Console.print("Этого питомца уже нет на экране.")
		return
	var shown: String = PlayerManager.displayNameFor(pet._skinTag())
	var wrapper: Node = pet.get_parent().get_parent()
	gbData.removePet(String(pet.petId))
	wrapper.queue_free()
	Console.print("Удалён: %s" % shown)


func clearObj(category: String = "object"):
	var exclude = [
		"Floor",
		"SideR",
		"SideL",
		"CanvasLayer",
		"CanvasLayer2"
	]
	

	for child in get_tree().current_scene.get_children():
		if not exclude.has(child.name):
			if category == child.get_meta("Category") or category == child.get_meta("itemName"):
				print(child)
				if gbData.data["saw"].has(child.get_meta("itemName")): # check if deleting a pet
					gbData.removePet(child.get_meta("itemName"))
				await get_tree().create_timer(.005).timeout
				child.queue_free()


	if category == "entity":
		gbData.data["saw"] = {}
		print("cleared pet persistence data")


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
	Console.print("[color=ORANGE]Сбросить игру к заводскому состоянию? Введи ДА, чтобы продолжить, что угодно другое - отмена.[/color]")
	Console.pending_input = _fullResetStep1


func _fullResetStep1(answer: String) -> void:
	if answer.strip_edges().to_upper() != "ДА":
		Console.print("Сброс отменён.")
		return
	Console.print("[color=WHITE]После сброса:[/color]")
	for line in FULL_RESET_LIST:
		Console.print("[color=#ff5a5a]- " + line + "[/color]")
	Console.print("[color=ORANGE]Точно? Напиши VLLM, чтобы подтвердить, что угодно другое - отмена.[/color]")
	Console.pending_input = _fullResetStep2


func _fullResetStep2(answer: String) -> void:
	if answer.strip_edges().to_upper() != "VLLM":
		Console.print("Сброс отменён.")
		return
	var backup: String = gbData.fullReset()
	Console.print("[color=GREEN]Сброс выполнен. Старые папки персонажей: %s. Перезапускаю игру...[/color]" % backup)
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
		Console.print("Монитор: [color=CYAN]%d[/color] (из %d), запомнено." % [clamped, maxIndex + 1])


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
		Console.print("[color=RED]Не нашлось ни одного скина в папке skin.[/color]")
		return
	var pick: String = names.pick_random()
	var previous: String = GlobalVariable.userSkinPath
	GlobalVariable.userSkinPath = "user://skin/%s/" % pick
	spawnExpie() # скин берётся из userSkinPath прямо при создании
	GlobalVariable.userSkinPath = previous
	Console.print("Появился: [color=CYAN]%s[/color]" % PlayerManager.displayNameFor(pick))

func resize(nx, ny, isForce = "no") -> String:
	var ex = str(nx).to_float()
	var ey = str(ny).to_float()
	if (
		(ex < 200 or ey < 100)
		or (ex > float(GlobalVariable.screenWidth) / 2 or ey > GlobalVariable.screenHeight)
		) and isForce == "no":
		Console.warning("Изменение размера консоли до такого значения не рекомендуется!")
		Console.print("Введи '[url=resize_console {0} {1} force]resize_console {0} {1} force[/url]', если уверен(а)".format([nx, ny]))
		return "[color=gray]ПРИМЕЧАНИЕ: размер консоли НЕ сохранится, если задан принудительно![/color]"
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
	Console.create_command("toggle_ai", _cmd_visionToggle, "вкл/выкл ВСЕХ реакций ИИ (без аргументов = переключить)")
	Console.create_command("toggle_profanity", _cmd_toggleProfanity, "разрешает/запрещает мат в сгенерированных ИИ фразах (без аргументов = переключить)")
	Console.create_command("toggle_flirt", _cmd_toggleFlirt, "разрешает/запрещает лёгкий флирт при очень хорошем настроении (без аргументов = переключить)")
	Console.create_command("toggle_debug_tags", _cmd_toggleDebugTags, "добавляет к фразам ИИ префикс источника: [screen]/[state]/[pet]/[grab]/итд (без аргументов = переключить)")
	Console.create_command("toggle_ai_log", _cmd_toggleAiLog, "записывает каждую сгенерированную фразу (принятую или отклонённую + причину) в user://ai_debug_log.txt (без аргументов = переключить)")
	Console.create_command("ai_status", _cmd_aiStatus, "показывает текущее состояние всех настроек ИИ")
	Console.create_command("ai_creativity", _cmd_aiCreativity, "0.0-1.5, выше = более дикие/случайные ответы, ниже = безопаснее/предсказуемее (стандартно 0.7 для qwen3-vl:8b-instruct)")
	Console.create_command("ai_repetition_guard", _cmd_aiRepetitionGuard, "1.0-2.0, выше = меньше шанс повторять одну и ту же фразу снова и снова (стандартно 1.2 для qwen3-vl:8b-instruct)")
	Console.create_command("model_manager", _openModelManager, "менеджер моделей Ollama: все скачанные модели (размер, подходит ли, настройки), выбрать, удалить или скачать новую")
	Console.create_command("ai_model", _cmd_aiModel, "то же, что model_manager; ai_model <имя> - сразу скачать и выбрать модель")
	Console.hidden_commands.append("ai_model") # 054.999: работает, но в help не путает
	Console.create_command("ban_words", _cmd_banwords, "список слов/фраз, которые ИИ никогда не должен использовать: после списка вводи номер (удалить), слово (добавить) или 0 (выход)")
	Console.create_command("reload_lore", LLMManager.reloadLore, "перечитывает лор и паспорта всех персонажей (lore.txt, character.json) без перезапуска - наборы фраз создадутся заново")
	Console.create_command("resize_console", resize, "размер окна консоли: resize_console <ширина> <высота> (проще растянуть уголок справа снизу)")
	#dont use this it breaks alot of shit Console.create_command("reload", reload, "reload everything")
	Console.create_command("set_monitor", setmonitor, "на каком мониторе живут персонажи: set_monitor <номер> (0 - основной, 1 - второй...), запоминается")
	##Console.create_command("killExpie", killExpie, "Yeha")
	#Console.create_command("setMood", _setmood, "debugging tool that doesnt work because i disabled mood stuff for this build")
	Console.create_command("spawn", _additem, "создаёт предмет у курсора: spawn <имя> (bread, bandage, syringe, medkit...). Проще - вкладка Items")
	Console.create_command("clear_items", clearObj, "убирает с экрана: clear_items - все предметы, clear_items entity - всех персонажей, clear_items <имя> - конкретный предмет")
	Console.create_command("despawn_pet", _cmd_despawnPet, "показывает список питомцев на экране и удаляет одного по номеру (всех разом - clear_items entity)")
	Console.create_command("random_sawian", _cmd_randomSawian, "создаёт случайного персонажа из твоих скинов (конкретного - во вкладке Skins)")
	Console.create_command("change_player_mode", _cmd_changePlayerMode, "меняет клавиши входа/выхода из управления игроком (сейчас: Ctrl+Alt+P). Клавиши пишутся ВРУЧНУЮ через + без пробелов, например: change_player_mode Ctrl+Shift+K. Можно: Ctrl, Alt, Shift, Win + одна обычная клавиша (A-Z, 0-9, F1-F24, Space, Tab, Home, End, Insert, Delete, PageUp, PageDown, стрелки Left/Right/Up/Down)")
	Console.create_command("pet_size", _cmd_petSize, "меняет размер персонажа (по умолчанию 4.0) - действует на новых заспавненных, не на уже существующих")
	#Console.create_command("openSkinFolder", openskinfold, "opens the skin folder")
	Console.create_command("full_reset", _cmd_fullReset, "сброс к заводскому состоянию (с двойным подтверждением): настройки, персонажи на экране, лоры и фразы встроенных персонажей. Модель и её настройки остаются")
	#Console.create_command("expieID", toggleExpieDebugIDs, "toggles debug IDs for expies")
	#Console.create_command("deathLoop", deathLoop, "please dont crash")
	
func _do_i_cmds():
	if has_run_commands:
		return
	has_run_commands = true
	_ensureModelInstalled()

	# i thought this had to be run from the console node itself but turns out its reflected on all consoles! hooray!
	Console.execute("set_monitor {0}".format([int(gbData.settings.get("defaultMonitor", 0))]))
	Console.execute("help")
	Console.print("[color=PURPLE]Консоль можно открыть снова в любой момент: Ctrl + правый клик по любому персонажу![/color]")
	Console.print("ЭКСПИ ИЛИ ЛЮБЫЕ ДРУГИЕ ПЕРСОНАЖИ, КОТОРЫЕ МОГУТ ЗДЕСЬ ПРИСУТСТВОВАТЬ, МНЕ НЕ ПРИНАДЛЕЖАТ. ЭТО ФАНАТСКИЙ ПРОЕКТ")
	Console.print("ЕСЛИ ТЫ ЗАПЛАТИЛ(А) ЗА ЭТО ИЛИ СКАЧАЛ(А) НЕ С GITHUB — ТЫ СДЕЛАЛ(А) ЭТО НЕПРАВИЛЬНО!")
	
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

func _cmd_toggleDebugTags(state: String = "toggle") -> void:
	var newVal := _resolveToggle(LLMManager.debugTags, state)
	LLMManager.setDebugTags(newVal)
	_print_toggle_state("Debug tags (toggle_debug_tags)", newVal)

func _cmd_toggleAiLog(state: String = "toggle") -> void:
	var newVal := _resolveToggle(gbData.settings.get("logAiLines", false), state)
	LLMManager.setLogAiLines(newVal)
	_print_toggle_state("AI line log -> user://ai_debug_log.txt (toggle_ai_log)", newVal)

func _print_toggle_state(label: String, on: bool) -> void:
	if on:
		Console.print(label + ": [color=GREEN]ВКЛ[/color] (запусти команду ещё раз, чтобы выключить)")
	else:
		Console.print(label + ": [color=RED]ВЫКЛ[/color] (запусти команду ещё раз, чтобы включить)")

func _cmd_aiStatus() -> void:
	_print_toggle_state("AI (toggle_ai)", gbData.settings.get("llmVisionEnabled", true))
	_print_toggle_state("Profanity (toggle_profanity)", gbData.settings.get("llmAllowProfanity", false))
	_print_toggle_state("Flirt (toggle_flirt)", gbData.settings.get("llmFlirtEnabled", false))
	_print_toggle_state("Debug tags (toggle_debug_tags)", LLMManager.debugTags)
	_print_toggle_state("AI line log (toggle_ai_log)", gbData.settings.get("logAiLines", false))
	Console.print("Интервал реакций на экран: [color=CYAN]%s-%s сек[/color]" % [LLMManager.minScreenInterval, LLMManager.maxScreenInterval])
	var talkRange: Vector2 = preload("res://Scripts/impo/behavior.gd").petTalkRange()
	Console.print("Интервал разговоров ИИ-персов: [color=CYAN]%s-%s сек[/color]" % [talkRange.x, talkRange.y])
	Console.print("Модель: [color=CYAN]%s[/color]" % LLMManager.modelName)
	Console.print("Creativity (ai_creativity): [color=CYAN]%s[/color] (0=предсказуемо, 1.5=дико)" % LLMManager.creativity)
	Console.print("Repetition guard (ai_repetition_guard): [color=CYAN]%s[/color] (1=может повторяться, 2=почти не повторяется)" % LLMManager.repetitionGuard)
	LLMManager.listAvailableModels()

func _cmd_aiCreativity(value: float) -> void:
	LLMManager.setCreativity(value)
	Console.print("Креативность: [color=CYAN]%s[/color]" % LLMManager.creativity)

func _cmd_aiRepetitionGuard(value: float) -> void:
	LLMManager.setRepetitionGuard(value)
	Console.print("Защита от повторов: [color=CYAN]%s[/color]" % LLMManager.repetitionGuard)

## 054.998: model_manager (и ai_model - то же меню). Все скачанные модели:
## размер, подходит ли игре (зрение и без режима размышлений), какая сейчас,
## какие под неё настройки. Дальше как в ban_words: вводишь ответ без имени
## команды - номер (выбрать), "удалить N", имя новой модели (скачать), 0 - выход.
## Новая модель проверяется ДО скачивания по реестру Ollama; если заранее не
## понять - после, а неподходящую можно сразу удалить.
const RECOMMENDED_MODELS := ["qwen3-vl:8b-instruct", "gemma4:12b", "ministral-3:14b"] # 055.004: gemma4 вместо gemma3 (стенд 24.10: лучше в ~8 раз чаще)

func _cmd_aiModel(name: String = "") -> void:
	if name != "":
		_downloadAndSwitch(name)
		return
	_openModelManager()


func _openModelManager() -> void:
	Console.print("Спрашиваю у Ollama список моделей...")
	LLMManager.fetchModels(_showModelMenu)


func _showModelMenu(names: Array, ok: bool) -> void:
	if not ok:
		Console.print("[color=RED]Ollama не ответила - проверь, что она запущена (значок в трее).[/color]")
		return
	# 054.9992: от меньшей к большей (8b - 1, 12b - 2, 14b - 3)
	names.sort_custom(func(a, b): return float(LLMManager.modelSizes.get(a, 0.0)) < float(LLMManager.modelSizes.get(b, 0.0)))
	var problems := {}
	for n in names:
		problems[n] = await _checkModelAsync(String(n))
	Console.print("Скачанные модели (сейчас: [color=CYAN]%s[/color]):" % LLMManager.modelName)
	Console.print("0. выход")
	for i in names.size():
		var n: String = names[i]
		var p: String = problems[n]
		var line := "%d. %s  [color=GRAY]%s[/color]  " % [i + 1, n, LLMManager.gbText(LLMManager.modelSizes.get(n, 0.0))]
		line += ("[color=RED]не подходит: %s[/color]" % p) if p != "" else "[color=GREEN]подходит[/color]"
		line += "  [color=GRAY]%s[/color]" % _modelSettingsText(n)
		if n == LLMManager.modelName:
			line += "  [color=CYAN]<- сейчас[/color]"
		Console.print(line)
	if names.is_empty():
		Console.print("(пока ни одной)")
	var missing: Array = RECOMMENDED_MODELS.filter(func(m): return not names.has(m))
	if not missing.is_empty():
		Console.print("Можно скачать (подходят игре): [color=CYAN]%s[/color]" % ", ".join(missing))
	Console.print("[color=ORANGE]Введи номер и нажми Enter - выбрать модель[/color]")
	Console.print("[color=ORANGE]Введи «удалить» и номер (например: удалить 2) - удалить модель[/color]")
	Console.print("[color=ORANGE]Введи имя новой модели - скачать её[/color]")
	Console.print("[color=ORANGE]0 - выход. Игре подходят только модели со зрением (vision) и без режима размышлений (thinking)[/color]")
	Console.pending_input = _modelMenuAnswer.bind(names, problems)


## Настройки под модель: у текущей - те, что стоят сейчас; у остальных - что
## поставится при переключении (свой набор есть только у проверенных моделей).
func _modelSettingsText(n: String) -> String:
	if n == LLMManager.modelName:
		return "креативность %s, защита от повторов %s" % [LLMManager.creativity, LLMManager.repetitionGuard]
	if LLMManager.MODEL_PRESETS.has(n):
		return "креативность %s, защита от повторов %s" % LLMManager.MODEL_PRESETS[n]
	return "настройки останутся текущими"


func _checkModelAsync(name: String) -> String:
	var result := [null]
	LLMManager.checkModel(name, func(p: String): result[0] = p)
	while result[0] == null:
		await get_tree().process_frame
	return result[0]


func _modelMenuAnswer(answer: String, names: Array, problems: Dictionary) -> void:
	answer = answer.strip_edges()
	if answer == "0":
		Console.print("Выход из меню моделей.")
		return
	if answer.is_valid_int():
		var i := int(answer) - 1
		if i < 0 or i >= names.size():
			Console.print("[color=ORANGE]Нет модели под номером %s.[/color]" % answer)
			Console.pending_input = _modelMenuAnswer.bind(names, problems)
			return
		var p: String = problems.get(names[i], "")
		if p != "":
			Console.print("[color=RED]%s не подойдёт: %s. Игре нужна модель со зрением и без режима размышлений.[/color]" % [names[i], p])
			Console.pending_input = _modelMenuAnswer.bind(names, problems)
			return
		_switchModel(String(names[i]), false) # уже скачана
		return
	var words := answer.split(" ", false)
	if words.size() == 2 and words[0].to_lower() == "удалить" and words[1].is_valid_int():
		var d := int(words[1]) - 1
		if d < 0 or d >= names.size():
			Console.print("[color=ORANGE]Нет модели под номером %s.[/color]" % words[1])
			Console.pending_input = _modelMenuAnswer.bind(names, problems)
			return
		if names[d] == LLMManager.modelName:
			Console.print("[color=ORANGE]%s сейчас выбрана - сначала переключись на другую, потом удаляй.[/color]" % names[d])
			Console.pending_input = _modelMenuAnswer.bind(names, problems)
			return
		_askDeleteModel(String(names[d]), true)
		return
	if Console.has_command(words[0]):
		Console.print("Выход из меню моделей.")
		Console.execute(answer)
		return
	_downloadAndSwitch(answer)


## Подтверждение удаления: номер-да/0-нет. backToMenu - после ответа снова меню.
func _askDeleteModel(name: String, backToMenu: bool) -> void:
	Console.print("[color=YELLOW]Удалить %s и освободить %s? 1 - да, 0 - нет[/color]" % [name, LLMManager.gbText(LLMManager.modelSizes.get(name, 0.0))])
	Console.pending_input = _deleteModelAnswer.bind(name, backToMenu)


func _deleteModelAnswer(answer: String, name: String, backToMenu: bool) -> void:
	if answer.strip_edges() == "1":
		if await LLMManager.deleteModel(name):
			Console.print("Модель [color=CYAN]%s[/color] удалена." % name)
		else:
			Console.print("[color=RED]Не получилось удалить %s - попробуй в командной строке: ollama rm %s[/color]" % [name, name])
	else:
		Console.print("Удаление отменено.")
	if backToMenu:
		_openModelManager()


## Новая модель по имени: проверить по реестру -> скачать с полоской ->
## проверить у Ollama -> переключиться, только если подходит.
func _downloadAndSwitch(name: String) -> void:
	name = name.strip_edges()
	Console.print("Проверяю модель [color=CYAN]%s[/color] до скачивания..." % name)
	var pre: Dictionary = await LLMManager.checkRegistry(name)
	if pre["sure"] and pre["problem"] != "":
		Console.print("[color=RED]%s не подойдёт: %s. Ничего не скачиваю, модель не переключена (сейчас: %s).[/color]" % [name, pre["problem"], LLMManager.modelName])
		return
	if not pre["sure"]:
		Console.print("[color=ORANGE]Заранее проверить %s не получилось - проверю после скачивания. Напоминание: нужна модель со зрением (vision) и без режима размышлений (thinking).[/color]" % name)
	LLMManager.pullModel(name, func(downloaded: bool):
		if not downloaded:
			return # pullModel уже написал, что не так
		LLMManager.checkModel(name, func(p: String):
			if p != "":
				Console.print("[color=RED]%s скачана, но не подойдёт: %s. Модель не переключена (сейчас: %s).[/color]" % [name, p, LLMManager.modelName])
				LLMManager.fetchModels(func(_n, _ok): _askDeleteModel(name, false)) # узнать размер
			else:
				_switchModel(name, false)))


func _switchModel(name: String, pull: bool = true) -> void:
	LLMManager.setModel(name, pull)
	Console.print("Модель переключена на: [color=CYAN]%s[/color]" % name)

func _cmd_banwords(w1: String = "", w2: String = "", w3: String = "", w4: String = "") -> void:
	var words: Array = gbData.settings.get("llmBanWords", [])

	if w1 == "":
		_printBanwordsMenu(words)
		Console.pending_input = _banwordsAnswer
		return

	if w1 == "0" and w2 == "":
		Console.print("Отмена.")
		return

	# same number twice = confirm delete
	if w1.is_valid_int() and w2.is_valid_int() and w3 == "" and w1 == w2:
		var idx: int = int(w1) - 1
		if idx >= 0 and idx < words.size():
			var removed = words[idx]
			words.remove_at(idx)
			Console.print("Удалено: [color=RED]%s[/color]" % removed)
		else:
			Console.print("[color=RED]Нет слова под таким номером.[/color]")
	elif w1.is_valid_int() and w2 == "":
		Console.print("[color=YELLOW]Введи номер ЕЩЁ РАЗ через пробел, чтобы подтвердить удаление (например: ban_words %s %s).[/color]" % [w1, w1])
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
		Console.print("Добавлено: [color=GREEN]%s[/color]" % phrase)

	gbData.settings["llmBanWords"] = words
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	LLMManager.setBanWords(words)
	_printBanwordsMenu(words)
	Console.pending_input = _banwordsAnswer

func _printBanwordsMenu(words: Array) -> void:
	Console.print("Запрещённые слова/фразы:")
	if words.is_empty():
		Console.print("(пусто)")
	for i in words.size():
		Console.print("%d. %s" % [i + 1, words[i]])
	Console.print("[color=ORANGE]Введи цифру 0, чтобы выйти из списка[/color]")
	Console.print("[color=ORANGE]Введи номер, чтобы удалить слово (потом тот же номер ещё раз - подтвердить)[/color]")
	Console.print("[color=ORANGE]Введи слово или фразу, чтобы добавить её[/color]")


## 054.96: banwords работает как despawnPet - после списка просто вводишь
## ответ, без "ban_words" впереди. Список ждёт ответов, пока не введёшь 0.
## Если введена другая команда консоли - выходим из списка и выполняем её
## (иначе "toggle_ai" стал бы запрещённым словом).
func _banwordsAnswer(answer: String) -> void:
	var words: Array = gbData.settings.get("llmBanWords", [])
	if answer == "0":
		Console.print("Выход из списка запрещённых слов.")
		return
	if Console.has_command(answer.split(" ", false)[0]):
		Console.print("Выход из списка запрещённых слов.")
		Console.execute(answer)
		return
	if answer.is_valid_int():
		var idx := int(answer) - 1
		if idx < 0 or idx >= words.size():
			Console.print("[color=RED]Нет слова под таким номером.[/color]")
		else:
			Console.print("[color=YELLOW]Удалить «%s»? Введи %s ещё раз, чтобы подтвердить, или что угодно другое - отмена.[/color]" % [words[idx], answer])
			Console.pending_input = _banwordsConfirm.bind(idx, answer)
			return
	else:
		words.append(answer)
		Console.print("Добавлено: [color=GREEN]%s[/color]" % answer)
		_saveBanwords(words)
	_printBanwordsMenu(words)
	Console.pending_input = _banwordsAnswer


func _banwordsConfirm(answer: String, idx: int, number: String) -> void:
	var words: Array = gbData.settings.get("llmBanWords", [])
	if answer == number and idx < words.size():
		Console.print("Удалено: [color=RED]%s[/color]" % words[idx])
		words.remove_at(idx)
		_saveBanwords(words)
	else:
		Console.print("Удаление отменено.")
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
				Console.print("[color=ORANGE]Модели %s нет в Ollama - переключаюсь на %s.[/color]" % [LLMManager.modelName, n])
				_switchModel(String(n), false)
				return
		Console.print("[color=RED]Модели %s нет в Ollama, а среди скачанных нет подходящей (нужна со зрением и без режима размышлений). Открой model_manager и скачай, например, %s.[/color]" % [LLMManager.modelName, RECOMMENDED_MODELS[0]]))
