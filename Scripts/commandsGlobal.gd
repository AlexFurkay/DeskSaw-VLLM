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
	get_tree().current_scene.add_child(instance)
	instance.global_position = instance.get_global_mouse_position()
	instance.owner = get_tree().current_scene
	instance.set_meta("itemName", item)


func _cmd_petSize(value: float) -> void:
	gbData.settings["petScale"] = value
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	Console.print("Размер новых питомцев: [color=CYAN]%s[/color] (заспавни нового, чтобы увидеть - на уже существующих не действует)" % value)


func _cmd_despawnPet() -> void:
	clearObj("entity")


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


func nukesettings():
	#command that fixes the "terror" bug
	gbData.killEverything()
	GlobalVariable.dataNuked.emit()

func setmonitor(monitorIndex: int = 0):
	var maxIndex: int = DisplayServer.get_screen_count() - 1
	var clamped: int = clampi(monitorIndex, 0, maxi(maxIndex, 0))
	DisplayServer.window_set_current_screen(clamped)
	GlobalVariable.Fresize()

func resize(nx, ny, isForce = "no") -> String:
	var ex = str(nx).to_float()
	var ey = str(ny).to_float()
	if (
		(ex < 200 or ey < 100)
		or (ex > float(GlobalVariable.screenWidth) / 2 or ey > GlobalVariable.screenHeight)
		) and isForce == "no":
		Console.warning("Изменение размера консоли до такого значения не рекомендуется!")
		Console.print("Введи '[url=resizeConsole {0} {1} force]resizeConsole {0} {1} force[/url]', если уверен(а)".format([nx, ny]))
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
	Console.create_command("log", _log, "вывести строку в консоль.")
	Console.create_command("toggleAI", _cmd_visionToggle, "вкл/выкл ВСЕХ реакций ИИ (без аргументов = переключить)")
	Console.create_command("toggleProfanity", _cmd_toggleProfanity, "разрешает/запрещает мат в сгенерированных ИИ фразах (без аргументов = переключить)")
	Console.create_command("toggleFlirt", _cmd_toggleFlirt, "разрешает/запрещает лёгкий флирт при очень хорошем настроении (без аргументов = переключить)")
	Console.create_command("toggleDebugTags", _cmd_toggleDebugTags, "добавляет к фразам ИИ префикс источника: [screen]/[state]/[pet]/[grab]/итд (без аргументов = переключить)")
	Console.create_command("toggleAiLog", _cmd_toggleAiLog, "записывает каждую сгенерированную фразу (принятую или отклонённую + причину) в user://ai_debug_log.txt (без аргументов = переключить)")
	Console.create_command("aiStatus", _cmd_aiStatus, "показывает текущее состояние всех настроек ИИ")
	Console.create_command("aiCreativity", _cmd_aiCreativity, "0.0-1.5, выше = более дикие/случайные ответы, ниже = безопаснее/предсказуемее")
	Console.create_command("aiRepetitionGuard", _cmd_aiRepetitionGuard, "1.0-2.0, выше = меньше шанс повторять одну и ту же фразу снова и снова")
	Console.create_command("aiModel", _cmd_aiModel, "переключает модель Ollama, которую использует ИИ (сама скачает её через Ollama, если ещё не скачана)")
	Console.create_command("banwords", _cmd_banwords, "управление словами/фразами, которые ИИ никогда не должен использовать")
	Console.create_command("visionInterval", _cmd_visionInterval, "мин/макс секунд между реакциями ИИ на экран")
	Console.create_command("reloadLore", LLMManager.reloadLore, "перезагружает user://LORE.txt")
	Console.create_command("resizeConsole", resize, "изменить размер консоли")
	#dont use this it breaks alot of shit Console.create_command("reload", reload, "reload everything")
	Console.create_command("setMonitor", setmonitor, "временная команда")
	##Console.create_command("killExpie", killExpie, "Yeha")
	#Console.create_command("setMood", _setmood, "debugging tool that doesnt work because i disabled mood stuff for this build")
	Console.create_command("spawn", _additem, "")
	Console.create_command("clearItems", clearObj, "очищает по 'entity', 'object' или конкретному имени предмета/скина")
	Console.create_command("despawnPet", _cmd_despawnPet, "удаляет текущего питомца(ев) с экрана, чтобы можно было заспавнить нового")
	Console.create_command("spawnExpie", spawnExpie, "создаёт Савианина на основе твоего скина по умолчанию")
	Console.create_command("petSize", _cmd_petSize, "меняет размер персонажа (по умолчанию 4.0) - действует на новых заспавненных, не на уже существующих")
	#Console.create_command("openSkinFolder", openskinfold, "opens the skin folder")
	Console.create_command("nukeData", nukesettings, "сбрасывает ВСЁ. Файл сохранения, настройки и т.д. Используй на свой страх и риск.")
	#Console.create_command("expieID", toggleExpieDebugIDs, "toggles debug IDs for expies")
	#Console.create_command("deathLoop", deathLoop, "please dont crash")
	
func _cmd_visionInterval(minSeconds: float, maxSeconds: float) -> void:
	LLMManager.setInterval(minSeconds, maxSeconds)
	Console.print("Интервал реакций ИИ на экран: [color=CYAN]%s-%s сек[/color]" % [minSeconds, maxSeconds])

func _do_i_cmds():
	if has_run_commands:
		return
	has_run_commands = true

	# i thought this had to be run from the console node itself but turns out its reflected on all consoles! hooray!
	Console.execute("setMonitor {0}".format([int(gbData.settings.get("defaultMonitor", 0))]))
	Console.execute("help")
	Console.print("[color=PURPLE]You can reopen this console any time by Ctrl + Right Clicking on any Desksawian![/color]")
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
	_print_toggle_state("AI (toggleAI)", newVal)

func _cmd_toggleProfanity(state: String = "toggle") -> void:
	var newVal := _resolveToggle(gbData.settings.get("llmAllowProfanity", false), state)
	LLMManager.setProfanityAllowed(newVal)
	_print_toggle_state("Profanity (toggleProfanity)", newVal)

func _cmd_toggleFlirt(state: String = "toggle") -> void:
	var newVal := _resolveToggle(gbData.settings.get("llmFlirtEnabled", false), state)
	LLMManager.setFlirtEnabled(newVal)
	_print_toggle_state("Flirt (toggleFlirt)", newVal)

func _cmd_toggleDebugTags(state: String = "toggle") -> void:
	var newVal := _resolveToggle(LLMManager.debugTags, state)
	LLMManager.setDebugTags(newVal)
	_print_toggle_state("Debug tags (toggleDebugTags)", newVal)

func _cmd_toggleAiLog(state: String = "toggle") -> void:
	var newVal := _resolveToggle(gbData.settings.get("logAiLines", false), state)
	LLMManager.setLogAiLines(newVal)
	_print_toggle_state("AI line log -> user://ai_debug_log.txt (toggleAiLog)", newVal)

func _print_toggle_state(label: String, on: bool) -> void:
	if on:
		Console.print(label + ": [color=GREEN]ВКЛ[/color] (запусти команду ещё раз, чтобы выключить)")
	else:
		Console.print(label + ": [color=RED]ВЫКЛ[/color] (запусти команду ещё раз, чтобы включить)")

func _cmd_aiStatus() -> void:
	_print_toggle_state("AI (toggleAI)", gbData.settings.get("llmVisionEnabled", true))
	_print_toggle_state("Profanity (toggleProfanity)", gbData.settings.get("llmAllowProfanity", false))
	_print_toggle_state("Flirt (toggleFlirt)", gbData.settings.get("llmFlirtEnabled", false))
	_print_toggle_state("Debug tags (toggleDebugTags)", LLMManager.debugTags)
	_print_toggle_state("AI line log (toggleAiLog)", gbData.settings.get("logAiLines", false))
	Console.print("Интервал реакций на экран: [color=CYAN]%s-%s сек[/color]" % [LLMManager.minScreenInterval, LLMManager.maxScreenInterval])
	Console.print("Модель: [color=CYAN]%s[/color]" % LLMManager.modelName)
	Console.print("Creativity (aiCreativity): [color=CYAN]%s[/color] (0=предсказуемо, 1.5=дико)" % LLMManager.creativity)
	Console.print("Repetition guard (aiRepetitionGuard): [color=CYAN]%s[/color] (1=может повторяться, 2=почти не повторяется)" % LLMManager.repetitionGuard)
	LLMManager.listAvailableModels()

func _cmd_aiCreativity(value: float) -> void:
	LLMManager.setCreativity(value)
	Console.print("Креативность: [color=CYAN]%s[/color]" % LLMManager.creativity)

func _cmd_aiRepetitionGuard(value: float) -> void:
	LLMManager.setRepetitionGuard(value)
	Console.print("Защита от повторов: [color=CYAN]%s[/color]" % LLMManager.repetitionGuard)

func _cmd_aiModel(name: String) -> void:
	LLMManager.setModel(name)
	Console.print("Модель переключена на: [color=CYAN]%s[/color]" % name)

func _cmd_banwords(w1: String = "", w2: String = "", w3: String = "", w4: String = "") -> void:
	var words: Array = gbData.settings.get("llmBanWords", [])

	if w1 == "":
		_printBanwordsMenu(words)
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
		Console.print("[color=YELLOW]Введи номер ЕЩЁ РАЗ через пробел, чтобы подтвердить удаление (например: banwords %s %s).[/color]" % [w1, w1])
		_printBanwordsMenu(words)
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

func _printBanwordsMenu(words: Array) -> void:
	Console.print("Запрещённые слова/фразы:")
	if words.is_empty():
		Console.print("(пусто)")
	for i in words.size():
		Console.print("%d. %s" % [i + 1, words[i]])
	Console.print(">Для удаления слова из списка укажи его номер ДВАЖДЫ через пробел (например: banwords 2 2)")
	Console.print(">Для ввода слова напиши его после команды и нажми ENTER (например: banwords ты снова)")
	Console.print(">Чтобы выйти без изменений, введи: banwords 0")
