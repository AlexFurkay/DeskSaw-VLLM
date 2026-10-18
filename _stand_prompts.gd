extends SceneTree
## Стенд промптов DeskSaw VLLM (054.998, пункт 16 отчёта 054.997).
## Запросы строит САМА игра (LLMManager.build*Prompt), стенд только
## подставляет персонажа, состояние, скриншот и отправляет в Ollama с теми же
## настройками, что и игра. Результат - текстовая таблица по персонажам.
##
## Запуск (из папки проекта, run_stand.ps1 делает это сам):
##   Godot --headless --path . --script res://_stand_prompts.gd -- <метка> [скины через запятую]
## Скриншоты - test-stand/screens, результат - test-stand/results_<метка>.txt

const STAND_DIR := "D:/Games/desksaw-builds/!build-files 036-100/test-stand"
const MODEL := "qwen3-vl:8b-instruct"
const SCREENS := ["!Молококвас.jpg", "2020-04-10_13.03.32.png", "2image.png", "8Zev.png", "8b773d5d87167d6daac1d6b46749cd2b.jpg", "_DSC0347.JPG"]
const SKINS := ["Dune", "VoyagerAlt", "Roza", "Velvet", "Leapy", "Milky", "Orange", "Expie"]
## [название, настроение, здоровье, мат]
const CONDITIONS := [
	["хорошо", 60.0, 100.0, false],
	["злой", -60.0, 100.0, false],
	["злой+мат", -60.0, 100.0, true],
	["ранен", 10.0, 15.0, false],
]
const CHAT_LINES := ["Привет! Чем занят?", "Ты сегодня какой-то странный.", "Хочешь, дам тебе жёлтую плоть?"]
const POOL_CATS := ["pet", "petWounded", "grab", "hungry"]

var lm
var gb
var out: Array[String] = []
var label := "run"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	lm = root.get_node("LLMManager")
	gb = root.get_node("gbData")
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		label = args[0]
	var skins: Array = SKINS
	if args.size() > 1:
		skins = Array(args[1].split(","))
	# настройки как в игре для этой модели (в памяти, на диск не пишем)
	lm.modelName = MODEL
	lm.creativity = 0.7
	lm.repetitionGuard = 1.2
	var images := {}
	for f in SCREENS:
		images[f] = _loadScreen(STAND_DIR + "/screens/" + f)
	var t0 := Time.get_ticks_msec()
	out.append("Стенд промптов: метка %s, модель %s, %s" % [label, MODEL, Time.get_datetime_string_from_system()])
	for skin in skins:
		out.append("")
		out.append("################ %s ################" % skin)
		var examples: Dictionary = _translation(skin)
		for cond in CONDITIONS:
			gb.settings["llmAllowProfanity"] = cond[3]
			var hint: String = lm.stateHint(cond[1], cond[2], 0)
			var stat := "настроение %.0f из 100, сытость 60 из 100, усталость 30.0, здоровье %.0f из 100" % [cond[1], cond[2]]
			out.append("--- %s (настроение %.0f, здоровье %.0f, мат %s) ---" % [cond[0], cond[1], cond[2], "вкл" if cond[3] else "выкл"])
			for f in SCREENS:
				var p: String = lm.buildScreenPrompt(skin + ":screen", hint)
				out.append("  [экран %s] %s" % [f.left(14), await _ask(skin, p, [images[f]], 220)])
			for i in 2:
				var pool: Array = examples.get("VeryLowPassive" if cond[1] < 0 or cond[2] < 30 else "Passive", [])
				var p2: String = lm.buildStatePrompt(stat, _pick(pool, 8), skin + ":state")
				out.append("  [состояние] %s" % await _ask(skin, p2, [], 220))
			for line in CHAT_LINES:
				var hist := [{"who": "Человек", "text": line}]
				var p3: String = lm.buildChatReplyPrompt(skin, "Человек", hist, stat + hint, [])
				out.append("  [чат: %s] %s" % [line, await _ask(skin, p3, [], 220)])
		gb.settings["llmAllowProfanity"] = false
		out.append("--- пулы (настроение 30, здоровье 100 / 15 для petWounded) ---")
		for cat in POOL_CATS:
			var src: String = {"petWounded": "LowPassive", "grab": "beingDragged"}.get(cat, cat)
			var situation: String = _situation(skin, cat)
			var p4: String = lm.buildPoolPrompt(skin + ":" + cat, _pick(examples.get(src, []), 8), "", situation)
			var raw: String = await _ask(skin, p4, [], 1200)
			out.append("  [пул %s]" % cat)
			for l in raw.split("\n", false).slice(0, 8):
				out.append("      " + l.strip_edges())
		_save()
	out.append("")
	out.append("Время: %d мин" % ((Time.get_ticks_msec() - t0) / 60000))
	_save()
	quit()


func _situation(skin: String, cat: String) -> String:
	var beh = load("res://Scripts/impo/behavior.gd")
	if cat == "petWounded":
		var hint := String(lm.passport(skin).get("woundedPet", ""))
		return "Тебя гладят рукой, а ты тяжело {ранена|ранен}, тебе очень больно. " + hint
	return String(beh.CATEGORY_SITUATION.get(cat, ""))


func _save() -> void:
	var f := FileAccess.open(STAND_DIR + "/results_" + label + ".txt", FileAccess.WRITE)
	f.store_string("\n".join(out) + "\n")
	f.close()


func _translation(skin: String) -> Dictionary:
	var path := "res://defaults/skins/%s/TRANSLATION.json" % skin
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (data is Dictionary):
		return {}
	var d: Dictionary = data.get("diaGlobal", data)
	return d


func _pick(pool: Array, n: int) -> Array:
	var p := pool.duplicate()
	p.shuffle()
	return p.slice(0, n)


## Скриншот ужимается до 1920 по ширине (как экран у большинства) - PNG в base64.
func _loadScreen(path: String) -> String:
	var img := Image.load_from_file(path)
	if img.get_width() > 1920:
		img.resize(1920, int(img.get_height() * 1920.0 / img.get_width()), Image.INTERPOLATE_LANCZOS)
	return Marshalls.raw_to_base64(img.save_png_to_buffer())


func _ask(skin: String, prompt: String, imgs: Array, predict: int) -> String:
	var payload := {
		"model": MODEL, "keep_alive": "10m", "prompt": lm._g(skin, prompt), "stream": false,
		"options": {"repeat_penalty": lm.repetitionGuard, "temperature": lm.creativity, "num_predict": predict, "num_ctx": lm.numCtx()},
	}
	if not imgs.is_empty():
		payload["images"] = imgs
	var http := HTTPRequest.new()
	http.timeout = 300.0
	root.add_child(http)
	http.request("http://127.0.0.1:11434/api/generate", ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(payload))
	var res: Array = await http.request_completed
	http.queue_free()
	if res[1] != 200:
		return "(ошибка %d)" % res[1]
	var parsed = JSON.parse_string(res[3].get_string_from_utf8())
	return String(parsed.get("response", "")).strip_edges().replace("\n\n", "\n") if parsed is Dictionary else "(не разобрал ответ)"
