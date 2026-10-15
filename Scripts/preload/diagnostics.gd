extends Node

## Диагностика для тестов на чужом компьютере (054.98).
## При каждом запуске пишет user://diagnostics.txt (прошлый - diagnostics_prev.txt):
## сборка, система, экраны, настройки, перенос старых данных, проверка каждого
## персонажа, связь с Ollama. Потом раз в STATUS_EVERY_SEC дописывает строку
## состояния (персонажи, память, FPS, очередь ИИ) - видно, что происходит
## в долгой сессии. Ошибки движка пишет сам Godot в user://logs/godot*.log.
## Команда консоли diag_report - пересобрать отчёт прямо сейчас.

const REPORT := "user://diagnostics.txt"
const REPORT_PREV := "user://diagnostics_prev.txt"
const FIRST_REPORT_DELAY := 20.0 # дать запуститься скинам и первым запросам к ИИ
const STATUS_EVERY_SEC := 600.0

var _startMsec := 0
var _ollama := "ещё не проверено"


func _ready() -> void:
	_startMsec = Time.get_ticks_msec()
	if FileAccess.file_exists(REPORT):
		DirAccess.copy_absolute(ProjectSettings.globalize_path(REPORT), ProjectSettings.globalize_path(REPORT_PREV))
	Console.create_command("diag_report", writeReport, "пересобрать отчёт диагностики (diagnostics.txt в папке сохранений)")
	await get_tree().create_timer(FIRST_REPORT_DELAY).timeout
	await _checkOllama()
	writeReport()
	while get_tree():
		await get_tree().create_timer(STATUS_EVERY_SEC).timeout
		_appendStatus()


func writeReport() -> void:
	var L: Array[String] = []
	L.append("=== DeskSaw VLLM - диагностика ===")
	L.append("Сборка: %s   Время: %s   Работает: %d мин" % [GlobalVariable.BUILD, Time.get_datetime_string_from_system(), (Time.get_ticks_msec() - _startMsec) / 60000])
	L.append("")
	L.append("--- Система ---")
	L.append("ОС: %s %s" % [OS.get_name(), OS.get_version()])
	L.append("Процессор: %s (%d потоков)" % [OS.get_processor_name(), OS.get_processor_count()])
	L.append("Видеокарта: %s / %s" % [RenderingServer.get_video_adapter_vendor(), RenderingServer.get_video_adapter_name()])
	L.append("Отрисовка: %s   FPS сейчас: %d   лимит: %d" % [ProjectSettings.get_setting("rendering/renderer/rendering_method", "?"), Performance.get_monitor(Performance.TIME_FPS), Engine.max_fps])
	for i in DisplayServer.get_screen_count():
		L.append("Экран %d: %s, рабочая область %s, масштаб %.2f%s" % [i, DisplayServer.screen_get_size(i), DisplayServer.screen_get_usable_rect(i).size, DisplayServer.screen_get_scale(i), "  <- текущий" if i == DisplayServer.window_get_current_screen() else ""])
	L.append("Размер текста консоли: x%.2f" % preload("res://Scripts/ui/terminal/terminalMain.gd").textScale())
	L.append("Папка данных: %s" % ProjectSettings.globalize_path("user://"))
	var oldRoot := OS.get_data_dir().path_join(gbData.OLD_DATA_DIR)
	L.append("Старая папка DeskSaw (%s): %s" % [oldRoot, "есть" if DirAccess.dir_exists_absolute(oldRoot) else "нет"])
	L.append("")
	L.append("--- События запуска ---")
	if gbData.startupNotes.is_empty():
		L.append("(ничего не переносилось и не обновлялось)")
	for n in gbData.startupNotes:
		L.append(String(n))
	L.append("")
	L.append("--- ИИ / Ollama ---")
	L.append("Модель: %s   ИИ включён: %s   AI-лог: %s" % [LLMManager.modelName, gbData.settings.get("llmVisionEnabled", true), gbData.settings.get("logAiLines", false)])
	L.append("Ollama: %s" % _ollama)
	L.append("Очередь запросов: %d срочных, %d фоновых   Готовых фраз в пулах: %d" % [LLMManager._queue.size(), LLMManager._backgroundQueue.size(), _poolLines()])
	L.append("")
	L.append("--- Персонажи (папка skin) ---")
	L.append_array(_skinsReport())
	L.append("")
	L.append("--- На экране ---")
	L.append_array(_petsNow())
	L.append("")
	L.append("--- Настройки (CONFIG.json) ---")
	var keys: Array = gbData.settings.keys()
	keys.sort()
	for k in keys:
		L.append("%s = %s" % [k, str(gbData.settings[k])])
	L.append("")
	L.append("--- Состояние раз в %d мин ---" % int(STATUS_EVERY_SEC / 60.0))
	var f := FileAccess.open(REPORT, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(L) + "\n")
		f.close()
	Console.print("Отчёт диагностики записан: [color=CYAN]%s[/color]" % ProjectSettings.globalize_path(REPORT))


func _appendStatus() -> void:
	var f := FileAccess.open(REPORT, FileAccess.READ_WRITE)
	if f == null:
		return
	f.seek_end()
	var pets: Array = []
	for p in get_tree().get_nodes_in_group("pets"):
		pets.append("%s%s hp%d" % [p._skinTag(), "(игрок)" if p.isPlayer else "", int(p.healthHandler.health)])
	f.store_line("[%s] %d мин | FPS %d | память %d МБ | узлов %d | очередь ИИ %d+%d | фраз в пулах %d | %s" % [
		Time.get_time_string_from_system(), (Time.get_ticks_msec() - _startMsec) / 60000,
		Performance.get_monitor(Performance.TIME_FPS), OS.get_static_memory_usage() / 1048576,
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		LLMManager._queue.size(), LLMManager._backgroundQueue.size(), _poolLines(), ", ".join(pets)])
	f.close()


func _poolLines() -> int:
	var n := 0
	for k in LLMManager._prefetchPools.keys():
		n += (LLMManager._prefetchPools[k] as Array).size()
	return n


func _petsNow() -> Array[String]:
	var out: Array[String] = []
	for p in get_tree().get_nodes_in_group("pets"):
		out.append("%s (id %s)%s: здоровье %d, настроение %d, сытость %d, сон: %s, без сознания: %s" % [
			p._skinTag(), p.petId, " - ИГРОК" if p.isPlayer else "", int(p.healthHandler.health),
			int(p.moodSys.mood), int(p.hungerHandler.hungry), p.isSleeping, p.isUnconscious])
	if out.is_empty():
		out.append("(никого)")
	return out


## Каждая папка скина: паспорт, лор, фразы, звуки - чего не хватает.
func _skinsReport() -> Array[String]:
	var out: Array[String] = []
	var dir := DirAccess.open("user://skin")
	if dir == null:
		out.append("ПАПКА skin НЕ НАЙДЕНА")
		return out
	for skin in dir.get_directories():
		var p := "user://skin/%s/" % skin
		var problems: Array[String] = []
		var info := ""
		if FileAccess.file_exists(p + "character.json"):
			var c = JSON.parse_string(FileAccess.get_file_as_string(p + "character.json"))
			if c is Dictionary:
				info = "%s, %s, текстуры v%s, тексты v%s, описание %d симв., отношений %d" % [
					c.get("name", "?"), c.get("gender", "?"), str(c.get("version", "-")), str(c.get("textVersion", "-")),
					String(c.get("description", "")).length(), (c.get("relations", {}) as Dictionary).size()]
			else:
				problems.append("character.json не читается")
		else:
			problems.append("нет character.json")
		var lore := p + "lore.txt"
		if not FileAccess.file_exists(lore):
			problems.append("нет lore.txt")
		elif FileAccess.get_file_as_string(lore).length() < 200:
			problems.append("lore.txt почти пустой")
		if FileAccess.file_exists(p + "TRANSLATION.json"):
			var t = JSON.parse_string(FileAccess.get_file_as_string(p + "TRANSLATION.json"))
			if t is Dictionary and t.get("diaGlobal") is Dictionary:
				var cats: Dictionary = t["diaGlobal"]
				var minCat := ""
				var minN := 1 << 30
				for k in cats.keys():
					var n: int = (cats[k] as Array).size() if cats[k] is Array else 0
					if n < minN:
						minN = n
						minCat = k
				info += ", фразы: %d категорий (меньше всего - %s: %d)" % [cats.size(), minCat, minN]
			else:
				problems.append("TRANSLATION.json не читается")
		else:
			problems.append("нет TRANSLATION.json")
		var sounds := "свои звуки" if DirAccess.dir_exists_absolute(p + "sounds") else ("звуки из игры" if DirAccess.dir_exists_absolute("res://assets/sounds/%s" % skin) else "звуки Expie по умолчанию")
		out.append("%s: %s, %s%s" % [skin, info, sounds, ("   ПРОБЛЕМЫ: " + "; ".join(problems)) if not problems.is_empty() else ""])
	return out


func _checkOllama() -> void:
	var http := HTTPRequest.new()
	add_child(http)
	http.timeout = 5.0
	if http.request("http://127.0.0.1:11434/api/tags") != OK:
		_ollama = "запрос не отправился"
		http.queue_free()
		return
	var res: Array = await http.request_completed
	http.queue_free()
	if res[0] != HTTPRequest.RESULT_SUCCESS or res[1] != 200:
		_ollama = "НЕ ОТВЕЧАЕТ (результат %d, код %d) - Ollama не запущена?" % [res[0], res[1]]
		return
	var data = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	var names: Array = []
	if data is Dictionary:
		for m in data.get("models", []):
			names.append(String(m.get("name", "")))
	var has := LLMManager.modelName in names
	_ollama = "отвечает; моделей %d; нужная модель %s; список: %s" % [names.size(), "ЕСТЬ" if has else "НЕ СКАЧАНА", ", ".join(names)]
