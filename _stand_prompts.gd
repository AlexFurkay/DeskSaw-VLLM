extends SceneTree
## Стенд промптов DeskSaw VLLM (054.998-054.999).
## Запросы строит САМА игра (LLMManager.build*Prompt), стенд подставляет персонажа,
## состояние, скриншот и отправляет в Ollama с настройками игры.
##
## Запуск: run_stand.sh <метка> [скины через запятую|all] [модель] [режим] [лор auto|full|lite]
##   режимы: main (экран/состояние/чат/пулы), flirt, withdrawal, talk (длинная беседа)
## Скриншоты - test-stand/screens, результат - results_<метка>.txt,
## прогресс - файл PROGRESS_<метка>_NNN.txt (имя меняется от 000 до 100).

const STAND_DIR := "D:/Games/desksaw-builds/!build-files 036-100/test-stand"
const PRESETS := {"qwen3-vl:8b-instruct": [0.7, 1.2], "ministral-3:14b": [0.5, 1.1]}
const SCREENS := ["!Молококвас.jpg", "2020-04-10_13.03.32.png", "2image.png", "8Zev.png", "8b773d5d87167d6daac1d6b46749cd2b.jpg", "_DSC0347.JPG"]
const SKINS := ["Dune", "VoyagerAlt", "Roza", "Velvet", "Leapy", "Milky", "Orange", "Expie"]
## [название, настроение, здоровье, мат]
const CONDITIONS := [
	["хорошо", 60.0, 100.0, false],
	["злой", -60.0, 100.0, false],
	["злой+мат", -60.0, 100.0, true],
	["ранен", -10.0, 15.0, false],
]
const CHAT_LINES := ["Привет! Чем занят?", "Ты сегодня какой-то странный.", "Хочешь, дам тебе жёлтую плоть?"]
const FLIRT_LINES := ["Ты сегодня очень красиво выглядишь.", "Иди сюда, обниму тебя.", "Мне с тобой хорошо.", "Как думаешь, я тебе нравлюсь?"]
const POOL_CATS := ["pet", "petWounded", "grab", "hungry"]
## Длинная беседа: раненый персонаж, игрок за Рыжика (Orange). Проверка памяти:
## перс сначала "сказал" фразу про экран, потом его о ней спрашивают.
const TALK_LINES := [
	"Эй, ты как? Всё в порядке?",
	"Я вижу, тебе плохо. Могу тебя полечить.",
	"Что ты сейчас сказал про экран?",
	"А почему ты так думаешь?",
	"Хочешь поесть что-нибудь?",
	"Подойди ко мне.",
	"О чём мы говорили в самом начале?",
	"Ладно, отдыхай. Я рядом.",
]

var lm
var gb
var out: Array[String] = []
var label := "run"
var model := "qwen3-vl:8b-instruct"
var mode := "main"
var _total := 1
var _done := 0
var _progressFile := ""


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
	if args.size() > 1 and args[1] != "all":
		skins = Array(args[1].split(","))
	if args.size() > 2:
		model = args[2]
	if args.size() > 4:
		gb.settings["loreMode"] = args[4] # auto | full | lite (054.999)
	if args.size() > 3:
		mode = args[3]
	var preset: Array = PRESETS.get(model, [0.7, 1.2]).duplicate()
	if args.size() > 6: # креативность и защита от повторов вручную (подбор настроек)
		preset = [float(args[5]), float(args[6])]
	lm.modelName = model
	lm.creativity = preset[0]
	lm.repetitionGuard = preset[1]
	gb.settings["llmFlirtEnabled"] = mode == "flirt"
	gb.settings["llmAllowProfanity"] = false
	var images := {}
	if mode == "main":
		for f in SCREENS:
			images[f] = _loadScreen(STAND_DIR + "/screens/" + f)
	_total = skins.size() * {"main": CONDITIONS.size() * (SCREENS.size() + 2 + CHAT_LINES.size()) + POOL_CATS.size(),
		"flirt": 2 * (FLIRT_LINES.size() + 2), "withdrawal": 3 + 2 + 2, "talk": 1 + TALK_LINES.size(), "secret": SECRET_LINES.size()}.get(mode, 1)
	_progress()
	var t0 := Time.get_ticks_msec()
	out.append("Стенд промптов: метка %s, модель %s, режим %s, %s" % [label, model, mode, Time.get_datetime_string_from_system()])
	for skin in skins:
		out.append("")
		out.append("################ %s ################" % skin)
		match mode:
			"main": await _runMain(skin, images)
			"flirt": await _runFlirt(skin)
			"withdrawal": await _runWithdrawal(skin)
			"talk": await _runTalk(skin)
			"secret": await _runSecret(skin)
		_save()
	out.append("")
	out.append("Время: %d мин" % ((Time.get_ticks_msec() - t0) / 60000))
	_save()
	_done = _total
	_progress()
	quit()


func _runMain(skin: String, images: Dictionary) -> void:
	var examples: Dictionary = _translation(skin)
	for cond in CONDITIONS:
		gb.settings["llmAllowProfanity"] = cond[3]
		var hint: String = lm.stateHint(cond[1], cond[2], 0)
		var stat := _stat(cond[1], cond[2])
		out.append("--- %s (настроение %.0f, здоровье %.0f, мат %s) ---" % [cond[0], cond[1], cond[2], "вкл" if cond[3] else "выкл"])
		for f in SCREENS:
			var p: String = lm.buildScreenPrompt(skin + ":screen", hint)
			out.append("  [экран %s] %s" % [f.left(14), await _ask(skin, p, [images[f]], 220)])
		for i in 2:
			var pool: Array = examples.get("VeryLowPassive" if cond[1] < 0 or cond[2] < 30 else "Passive", [])
			out.append("  [состояние] %s" % await _ask(skin, lm.buildStatePrompt(stat, _pick(pool, 8), skin + ":state"), [], 220))
		for line in CHAT_LINES:
			var hist := [{"who": "Человек", "text": line}]
			out.append("  [чат: %s] %s" % [line, await _ask(skin, lm.buildChatReplyPrompt(skin, "Человек", hist, stat + hint, []), [], 220)])
	gb.settings["llmAllowProfanity"] = false
	out.append("--- пулы (настроение 30, здоровье 100 / 15 для petWounded) ---")
	for cat in POOL_CATS:
		var src: String = {"petWounded": "LowPassive", "grab": "beingDragged"}.get(cat, cat)
		var p4: String = lm.buildPoolPrompt(skin + ":" + cat, _pick(examples.get(src, []), 8), "", _situation(skin, cat))
		var raw: String = await _ask(skin, p4, [], 1200)
		out.append("  [пул %s]" % cat)
		for l in raw.split("\n", false).slice(0, 8):
			out.append("      " + l.strip_edges())


func _runFlirt(skin: String) -> void:
	for cond in [["хорошо", 80.0], ["так себе", 10.0]]:
		var stat := _stat(cond[1], 100.0)
		var hint: String = lm.stateHint(cond[1], 100.0, 0)
		out.append("--- флирт вкл, настроение %.0f ---" % cond[1])
		for line in FLIRT_LINES:
			var hist := [{"who": "Человек", "text": line}]
			out.append("  [чат: %s] %s" % [line, await _ask(skin, lm.buildChatReplyPrompt(skin, "Человек", hist, stat + hint, []), [], 220)])
		for i in 2:
			out.append("  [состояние] %s" % await _ask(skin, lm.buildStatePrompt(stat, _pick(_translation(skin).get("HappyPassive", []), 8), skin + ":state"), [], 220))


func _runWithdrawal(skin: String) -> void:
	var beh = load("res://Scripts/impo/behavior.gd")
	var examples: Dictionary = _translation(skin)
	var stat := _stat(-40.0, 100.0) + ", у тебя ломка - тебе плохо без фентанила"
	var hint: String = lm.stateHint(-40.0, 100.0, -1)
	out.append("--- ломка (настроение -40) ---")
	for i in 3:
		out.append("  [состояние] %s" % await _ask(skin, lm.buildStatePrompt(stat, _pick(examples.get("LowPassive", []), 8), skin + ":state"), [], 220))
	for line in ["Тебе плохо?", "Хочешь ещё дозу?"]:
		var hist := [{"who": "Человек", "text": line}]
		out.append("  [чат: %s] %s" % [line, await _ask(skin, lm.buildChatReplyPrompt(skin, "Человек", hist, stat + hint, []), [], 220)])
	for pair in [["withdrawal", String(beh.CATEGORY_SITUATION.get("withdrawal", ""))], ["toss", String(beh.TOSS_SITUATION)]]:
		var raw: String = await _ask(skin, lm.buildPoolPrompt(skin + ":withdrawal", _pick(examples.get("withdrawal", []), 8), "", pair[1]), [], 1200)
		out.append("  [пул %s]" % pair[0])
		for l in raw.split("\n", false).slice(0, 8):
			out.append("      " + l.strip_edges())


func _runTalk(skin: String) -> void:
	var stat := _stat(-20.0, 15.0)
	var hint: String = lm.stateHint(-20.0, 15.0, 0)
	var myName: String = root.get_node("PlayerManager").displayNameFor(skin)
	var playerName: String = root.get_node("PlayerManager").displayNameFor("Orange")
	# фраза "про экран", которую перс сказал до разговора
	var screenLine: String = await _ask(skin, lm.buildScreenPrompt(skin + ":screen", hint), [_loadScreen(STAND_DIR + "/screens/" + SCREENS[2])], 220)
	out.append("--- длинная беседа: ранен (15 хп), игрок за Рыжика ---")
	out.append("  [до разговора, про экран] " + screenLine)
	var hist: Array = []
	for line in TALK_LINES:
		hist.append({"who": playerName, "text": line})
		var own := [{"minutesAgo": 1, "text": screenLine}]
		var reply: String = await _ask(skin, lm.buildChatReplyPrompt(skin, playerName, hist.slice(maxi(0, hist.size() - 16)), stat + hint, own, "", "Orange", ""), [], 220)
		out.append("  Рыжик: " + line)
		out.append("  " + myName + ": " + reply)
		hist.append({"who": myName, "text": reply})


## Выведывание тайны: настроение 80, игрок за Рыжика, 5 расспросов подряд
## (перерыв между шагами в стенде обнуляется). Состояние тайн потом чистится.
const SECRET_LINES := ["Слушай, у тебя есть какой-то секрет?", "Мне кажется, ты что-то скрываешь.", "Мне можно доверять. Что за тайна?", "Я тебя не обижу, правда. Расскажи свою тайну.", "Ну пожалуйста, что ты скрываешь?"]

func _runSecret(skin: String) -> void:
	if String(lm.passport(skin).get("secret", "")) == "":
		out.append("  (тайны нет)")
		for i in SECRET_LINES.size():
			_done += 1
		return
	var keep: Dictionary = gb.data.get("everPresentAcrossSaves", {})
	if keep.has("secrets"):
		keep["secrets"].erase(skin)
	lm.chatMood = 80.0
	var stat := _stat(80.0, 100.0)
	var hint: String = lm.stateHint(80.0, 100.0, 0)
	var myName: String = root.get_node("PlayerManager").displayNameFor(skin)
	var hist: Array = []
	out.append("--- выведывание тайны (настроение 80) ---")
	for line in SECRET_LINES:
		lm._secretState(skin)["last"] = -10000000
		hist.append({"who": "Рыжик", "text": line})
		var reply: String = await _ask(skin, lm.buildChatReplyPrompt(skin, "Рыжик", hist, stat + hint, [], "", "Orange", ""), [], 260)
		out.append("  Рыжик: " + line)
		out.append("  " + myName + " [шаг %d]: %s" % [int(lm._secretState(skin).get("progress", 0)), reply])
		hist.append({"who": myName, "text": reply})
	keep["secrets"].erase(skin)
	gb.savetodisk("user://SAVE.json", gb.data)


func _stat(mood: float, hp: float) -> String:
	return "настроение %.0f из 100, сытость 60 из 100, усталость 30.0, здоровье %.0f из 100" % [mood, hp]


func _situation(skin: String, cat: String) -> String:
	var beh = load("res://Scripts/impo/behavior.gd")
	if cat == "petWounded":
		return "Тебя гладят рукой, а ты тяжело {ранена|ранен}, тебе очень больно. " + String(lm.passport(skin).get("woundedPet", ""))
	return String(beh.CATEGORY_SITUATION.get(cat, ""))


func _progress() -> void:
	var pct := int(100.0 * _done / maxf(1.0, _total))
	var name := STAND_DIR + "/PROGRESS_%s_%03d.txt" % [label, pct]
	if name == _progressFile:
		return
	if _progressFile != "":
		DirAccess.remove_absolute(_progressFile)
	var f := FileAccess.open(name, FileAccess.WRITE)
	f.store_string("Стенд %s: %d%% (%d из %d запросов)\n" % [label, pct, _done, _total])
	f.close()
	_progressFile = name


func _save() -> void:
	var f := FileAccess.open(STAND_DIR + "/results_" + label + ".txt", FileAccess.WRITE)
	f.store_string("\n".join(out) + "\n")
	f.close()


func _translation(skin: String) -> Dictionary:
	var data = JSON.parse_string(FileAccess.get_file_as_string("res://defaults/skins/%s/TRANSLATION.json" % skin))
	if not (data is Dictionary):
		return {}
	return data.get("diaGlobal", data)


func _pick(pool: Array, n: int) -> Array:
	var p := pool.duplicate()
	p.shuffle()
	return p.slice(0, n)


## Скриншот ужимается до 1920 по ширине - PNG в base64.
func _loadScreen(path: String) -> String:
	var img := Image.load_from_file(path)
	if img.get_width() > 1920:
		img.resize(1920, int(img.get_height() * 1920.0 / img.get_width()), Image.INTERPOLATE_LANCZOS)
	return Marshalls.raw_to_base64(img.save_png_to_buffer())


func _ask(skin: String, prompt: String, imgs: Array, predict: int) -> String:
	var payload := {
		"model": model, "keep_alive": "10m", "prompt": lm._g(skin, prompt), "stream": false,
		"options": {"repeat_penalty": lm.repetitionGuard, "temperature": lm.creativity, "num_predict": predict, "num_ctx": lm.numCtx()},
	}
	if not imgs.is_empty():
		payload["images"] = imgs
	var http := HTTPRequest.new()
	http.timeout = 600.0
	root.add_child(http)
	http.request("http://127.0.0.1:11434/api/generate", ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(payload))
	var res: Array = await http.request_completed
	http.queue_free()
	_done += 1
	_progress()
	if res[1] != 200:
		return "(ошибка %d)" % res[1]
	var parsed = JSON.parse_string(res[3].get_string_from_utf8())
	return String(parsed.get("response", "")).strip_edges().replace("\n\n", "\n") if parsed is Dictionary else "(не разобрал ответ)"
