extends Node

## Autoload: LLMManager
##
## Two independent sources of AI-generated lines, sharing one request queue:
##
## 1. Screen reactions - every minScreenInterval..maxScreenInterval seconds,
##    grabs the desktop via ScreenCapture (C#) and sends it to a local Ollama
##    vision model. Broadcast to all pets via the `llmReaction` signal.
##
## 2. State reactions - called from behavior.gd's passivetalk() loop (same
##    cadence as minDialogueTime/maxDialogueTime). Delivered to a SPECIFIC
##    pet via Callable, not broadcast.
##
## reactToEvent() is for one-off triggers (e.g. being dragged). Pass a
## callback if the reaction must bypass the normal "don't interrupt" guards
## (see behavior.gd's _on_drag_reaction) - otherwise it broadcasts like a
## screen reaction.
##
## Requires Ollama running locally, e.g.: ollama pull qwen3-vl:8b-instruct

signal llmReaction(text: String)
signal aiEnabledChanged(enabled: bool)
signal prewarmBatchFinished()
## Все готовые пулы фраз сброшены (reloadLore) - питомцы перезапускают
## прогрев, чтобы новые фразы были сгенерированы уже с новым лором.
signal poolsCleared()

const OLLAMA_URL := "http://127.0.0.1:11434/api/generate" # NOT "localhost" - on some Windows setups (VPN software installed even if inactive, IPv6/DNS quirks) resolving "localhost" can add seconds of delay per request; the literal loopback IP skips DNS resolution entirely

var modelName := "qwen3-vl:8b-instruct"
var creativity := 0.7    # was "temperature" - higher = more random/wild answers, lower = more predictable/on-character

## _on_screen_tick() runs on its own, independent of any specific pet, so it
## has no direct line to a pet's mood/health. behavior.gd/health_handler.gd
## keep these updated whenever their own values change - screen reactions
## read them to let bad mood/low health quietly colour the tone.
var repetitionGuard := 1.2 # was "repeat_penalty" - higher = less likely to repeat the same words/phrases
var minScreenInterval := 60.0
var maxScreenInterval := 120.0

## Free text loaded from user://LORE.txt - reload at runtime with `reloadLore`.
var lore := ""

var http: HTTPRequest
var screenTimer: Timer
var busy := false
var _prefetchPools: Dictionary = {}   # category -> Array[String] ready-made lines
var _prefetchPending: Dictionary = {} # category -> bool, true while a refill is in flight
const PREFETCH_TARGET := 8 # 054.96: -20% (было 10), генерация шла слишком долго
## Окно контекста модели. 4096 стало впритык: правила (~970 токенов) + лор
## (630-1040) + скриншот (~1080) или история чата. 6144 у qwen3-vl:8b ещё
## целиком помещается в 8 ГБ видеопамяти (5.67 ГБ против 5.51 при 4096),
## 8192 уже вылезает в обычную память и тормозит (замер 2026-10-15, GTX 1070 Ti).
const NUM_CTX := 6144
## 054.99: окно под модель. ministral-3 тратит на русский текст в ~1.5 раза
## больше токенов (лор Voyager: 1455 против 951 у qwen) - с окном 6144 чат и
## экран переполнялись, Ollama отрезала начало промпта (правила и лор), и
## модель "дуркала". Неизвестным моделям - 8192 с запасом.
const NUM_CTX_BY_MODEL := {
	"qwen3-vl:8b-instruct": 6144,
	"ministral-3:14b": 9216,
	"gemma3:12b": 8192, # 054.999: третья рекомендованная (решение Alex)
}
func numCtx() -> int:
	return int(NUM_CTX_BY_MODEL.get(modelName, 8192))
const PREFETCH_REFILL_AT := 3

## Категории, которые игрок трогает чаще всего - генерируем для них батч
## побольше, чтобы разнообразия хватало дольше и повторы в начале сессии
## случались реже.
const PREFETCH_TARGET_OVERRIDES := {
	"pet": 20,
	"petReject": 10,
	"getUp": 10,
	"getUpPet": 10,
	"beingDragged": 10,
	"screamBIG": 10,
	"drag_level0": 12,
	"drag_level1": 12,
	"drag_level2": 12,
	"fell": 12,
}

## Ключ пула - "Скин:категория" (например "Expie:pet"); настройки выше заданы
## по одной категории. Раньше искался весь ключ, и пакет на 20 для pet
## никогда не срабатывал - генерировалось по 7.
func _prefetchTargetFor(category: String) -> int:
	return PREFETCH_TARGET_OVERRIDES.get(category.get_slice(":", category.get_slice_count(":") - 1), PREFETCH_TARGET)


## Пополнять пул, когда в нём осталась треть (у больших пулов раньше, чем при 3).
func _refillThresholdFor(category: String) -> int:
	return maxi(PREFETCH_REFILL_AT, _prefetchTargetFor(category) / 3)

var debugTags := false
var _queue: Array = []           # foreground/interactive requests - always drained first
var _backgroundQueue: Array = [] # prefetch pool refills - only drained when _queue is empty
var _sinceBackgroundJob := 0
const BACKGROUND_EVERY_N := 3    # guarantee background a turn at least this often
var _currentCallback: Callable
var _currentTag: String = ""
var _currentJob: Dictionary = {} # чтобы прерванный фоновый пакет можно было вернуть в очередь
var _watchdogTimer: Timer


func _ready() -> void:
	http = HTTPRequest.new()
	http.timeout = 60.0 # give up on a truly dead connection instead of hanging forever
	add_child(http)
	http.request_completed.connect(_on_request_completed)

	screenTimer = Timer.new()
	screenTimer.one_shot = true
	add_child(screenTimer)
	screenTimer.timeout.connect(_on_screen_tick)

	# Watchdog: if a request gets stuck (e.g. Ollama cancels it server-side
	# without properly signaling completion - this happened for real, a
	# 500 left `busy` stuck true and silenced the entire queue for 5+
	# minutes), force it unstuck rather than staying dead until something
	# else happens to nudge it.
	_watchdogTimer = Timer.new()
	_watchdogTimer.one_shot = true
	_watchdogTimer.wait_time = 75.0
	add_child(_watchdogTimer)
	_watchdogTimer.timeout.connect(_onWatchdogTimeout)

	_loadLore()
	_loadSavedSettings()
	_scheduleScreenTick()


## 054.998: при выходе из игры - отменить запросы и сразу выгрузить модель.
## Раньше модель сидела в видеопамяти ещё 30 минут (keep_alive), а уже
## начатые запросы Ollama досчитывала после выхода: у тестеров Ollama
## грузила компьютер при закрытой игре.
func _exit_tree() -> void:
	_queue.clear()
	_backgroundQueue.clear()
	if http:
		http.cancel_request() # оборванное соединение - Ollama бросает генерацию
	_unloadModelSync()


## Запрос с keep_alive 0 и без текста - Ollama выгружает модель. Синхронно и
## не дольше ~1,5 с: игра закрывается, ждать ответа асинхронно уже некому.
func _unloadModelSync() -> void:
	if modelName == "":
		return
	var client := HTTPClient.new()
	if client.connect_to_host("127.0.0.1", 11434) != OK:
		return
	var deadline := Time.get_ticks_msec() + 1500
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		if Time.get_ticks_msec() > deadline:
			return
		client.poll()
		OS.delay_msec(10)
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return
	var body := JSON.stringify({"model": modelName, "keep_alive": 0})
	if client.request(HTTPClient.METHOD_POST, "/api/generate", ["Content-Type: application/json"], body) != OK:
		return
	while client.get_status() == HTTPClient.STATUS_REQUESTING and Time.get_ticks_msec() < deadline:
		client.poll()
		OS.delay_msec(10)
	client.close()


func _loadSavedSettings() -> void:
	modelName = String(gbData.settings.get("llmModelName", modelName)).strip_edges()
	creativity = gbData.settings.get("llmCreativity", creativity)
	repetitionGuard = gbData.settings.get("llmRepetitionGuard", repetitionGuard)
	_refreshScreenInterval()
	banWords = gbData.settings.get("llmBanWords", [])


func _scheduleScreenTick(overrideSeconds: float = -1.0) -> void:
	var wait := overrideSeconds
	if wait < 0.0:
		if gbData.settings.get("llmVisionEnabled", true):
			_refreshScreenInterval()
			wait = randf_range(minScreenInterval, maxScreenInterval) * GlobalVariable.pace()
		else:
			wait = 5.0
	screenTimer.start(wait)


## Интервал экрана читается из настроек при каждом срабатывании: поля во
## вкладке Settings хранят строки ("60"), а команда visionInterval - числа.
func _refreshScreenInterval() -> void:
	minScreenInterval = maxf(1.0, float(GlobalVariable.getNumFromString(str(gbData.settings.get("llmMinInterval", minScreenInterval)))))
	maxScreenInterval = maxf(minScreenInterval, float(GlobalVariable.getNumFromString(str(gbData.settings.get("llmMaxInterval", maxScreenInterval)))))


const OLD_LORE_PATH := "user://LORE.txt" # kept forever - never deleted, only read once for migration

## Лор теперь живёт ВНУТРИ папки скина (user://skin/<Имя>/lore.txt), рядом с
## TRANSLATION.json - один персонаж, одна папка, а не файлы, размазанные по
## разным местам. Раньше лор лежал плоско в корне (user://<имя>lore.txt).
func _lorePathForSkin(skinName: String) -> String:
	return "user://skin/%s/lore.txt" % skinName

## Лор каждого скина отдельно (раньше всем питомцам подставлялся лор
## defaultSkin - второй персонаж на экране говорил бы с чужой биографией).
var _loreBySkin: Dictionary = {} # имя скина -> текст лора

## 054.999 (идея Alex): два лора - lore.txt (полный, для моделей от 10b) и
## lore_lite.txt (короче и проще, для моделей до 10b: 8b путается в длинном
## лоре, а 14b, наоборот, раскрывает его детали). Нет lore_lite.txt - берётся
## обычный. Настройка loreMode: "auto" (по размеру модели), "full", "lite".
## lore_lite ищется у игрока, потом в сборке (у старых игроков его ещё нет).
func useLiteLore() -> bool:
	match String(gbData.settings.get("loreMode", "auto")):
		"lite":
			return true
		"full":
			return false
	return modelBillions() < 10.0


## Размер модели в миллиардах параметров - из имени ("qwen3-vl:8b-instruct" -> 8,
## "ministral-3:14b" -> 14). Не понять - считаем маленькой (8).
var _sizeRegex := RegEx.create_from_string("(\\d+(?:\\.\\d+)?)b(?![a-z])")
func modelBillions() -> float:
	var m := _sizeRegex.search(modelName.to_lower().get_slice(":", 1) if modelName.contains(":") else modelName.to_lower())
	return float(m.get_string(1)) if m else 8.0


func _readText(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	var t := f.get_as_text().strip_edges()
	f.close()
	return t


func _loreFor(skinName: String) -> String:
	var lite := useLiteLore()
	var key := skinName + ("|lite" if lite else "")
	if not _loreBySkin.has(key):
		var text := ""
		if lite:
			text = _readText("user://skin/%s/lore_lite.txt" % skinName)
			if text == "":
				text = _readText("res://defaults/skins/%s/lore_lite.txt" % skinName)
		if text == "":
			text = _readText(_lorePathForSkin(skinName))
		_loreBySkin[key] = text
	return _loreBySkin[key]


## 054.998: паспорт скина (character.json) целиком - для новых полей
## (вкусы, фирменные слова, реакция раненого на ласку). Сначала папка игрока,
## потом зашитая в сборку. Кэш сбрасывается в reloadLore().
var _passportBySkin: Dictionary = {}

func passport(skinName: String) -> Dictionary:
	if not _passportBySkin.has(skinName):
		# зашитый в сборку паспорт - основа, паспорт игрока поверх: у игрока со
		# старой версией нет новых полей (tastes, woundedPet, signatureWords) -
		# они берутся из сборки, а то, что он правил сам, остаётся его.
		var result := {}
		for path in ["res://defaults/skins/%s/character.json" % skinName, "user://skin/%s/character.json" % skinName]:
			if FileAccess.file_exists(path):
				var data = JSON.parse_string(FileAccess.get_file_as_string(path))
				if data is Dictionary:
					result.merge(data, true)
		_passportBySkin[skinName] = result
	return _passportBySkin[skinName]


## Род персонажа - из паспорта скина character.json (поле gender). Сначала
## папка игрока, потом зашитая в сборку (у старых игроков файла в папке
## может не быть - _syncBundledSkins существующие папки не обновляет).
## По умолчанию мужской: по лору GunSaw женского рода только Voyager.
var _genderBySkin: Dictionary = {}

func isFemale(skinName: String) -> bool:
	if not _genderBySkin.has(skinName):
		var gender := "male"
		for path in ["user://skin/%s/character.json" % skinName, "res://defaults/skins/%s/character.json" % skinName]:
			if FileAccess.file_exists(path):
				var data = JSON.parse_string(FileAccess.get_file_as_string(path))
				if data is Dictionary:
					gender = String(data.get("gender", "male")).to_lower()
					break
		_genderBySkin[skinName] = gender
	return _genderBySkin[skinName] == "female"


## В текстах промптов женские формы записаны как {женский|мужской}
## ("{упала|упал}") - здесь подставляется вариант по роду скина.
var _genderRegex := RegEx.create_from_string("\\{([^{}|]*)\\|([^{}|]*)\\}")

func _g(skinName: String, text: String) -> String:
	return _genderRegex.sub(text, "$1" if isFemale(skinName) else "$2", true)


## Из тега запроса "Скин:категория" достаёт имя скина. Запросы без скина
## (screen - один скриншот на всех) идут с лором defaultSkin.
func _skinFromTag(tag: String) -> String:
	var t := tag.trim_prefix("prefetch:")
	if t.contains(":"):
		return t.get_slice(":", 0)
	return String(gbData.settings.get("defaultSkin", "Default"))


func _loadLore() -> void:
	_loreBySkin.clear()
	var skinName: String = gbData.settings.get("defaultSkin", "Default")
	var path := _lorePathForSkin(skinName)
	var oldFlatPath := "user://%slore.txt" % skinName.to_lower() # старое плоское расположение, до переноса в папку скина

	if not FileAccess.file_exists(path):
		DirAccess.make_dir_recursive_absolute("user://skin/" + skinName) # на случай если папки скина ещё нет

		if FileAccess.file_exists(oldFlatPath):
			# Мигрируем со старого плоского расположения - без этого лор
			# выглядел бы пропавшим у всех, кто уже его написал.
			var oldFlatFile := FileAccess.open(oldFlatPath, FileAccess.READ)
			var oldFlatText := oldFlatFile.get_as_text()
			oldFlatFile.close()
			var migratedFile := FileAccess.open(path, FileAccess.WRITE)
			migratedFile.store_string(oldFlatText)
			migratedFile.close()
		elif FileAccess.file_exists(OLD_LORE_PATH):
			# Ещё более старый вариант - один общий LORE.txt на всех.
			var oldFile := FileAccess.open(OLD_LORE_PATH, FileAccess.READ)
			var oldText := oldFile.get_as_text()
			oldFile.close()
			var newFile := FileAccess.open(path, FileAccess.WRITE)
			newFile.store_string(oldText)
			newFile.close()
		else:
			_createLoreTemplate(path, skinName)

	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		lore = f.get_as_text().strip_edges()
		f.close()
	else:
		lore = ""


func _createLoreTemplate(path: String, skinName: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("Ты %s.\n\nОпиши здесь: происхождение персонажа, характер, как он относится к человеку рядом с собой, тон речи.\nЭтот файл читается заново командой reload_lore в консоли." % skinName)
	f.close()


func _clearPrefetchPools() -> void:
	_prefetchPools.clear()
	_prefetchPending.clear()
	# Ещё не отправленные пакеты прогрева тоже выкидываем - иначе после
	# повторного прогрева одни и те же категории генерировались бы дважды,
	# а счётчик "Прогрев: N/M" путался.
	_backgroundQueue.clear()
	_prewarmTotal = 0
	_prewarmDone = 0


## Drops only the individual cached lines that actually contain profanity,
## instead of wiping every ready-made pool - toggling this setting shouldn't
## force a full, slow regeneration of everything the game already had ready.
## Categories lose at most a few lines each; the normal "refill when low"
## mechanism tops them back up under the new rule over time.
func _purgeProfaneLines() -> void:
	for category in _prefetchPools.keys():
		var pool: Array = _prefetchPools[category]
		var kept: Array = []
		for line in pool:
			if not _containsProfanity(String(line)):
				kept.append(line)
		_prefetchPools[category] = kept


## Finds the index of the first real sentence-ending punctuation in `s`,
## skipping over "..." (an ellipsis of 2+ dots is a pause, not a sentence
## end) - a plain single "." still counts. Returns -1 if none found.
## "…" (один символ-многоточие) - тоже пауза, а не конец: раньше
## "Неплохо… для тебя" обрезалось до "Неплохо…".
func _findSentenceEnd(s: String, from: int = 0) -> int:
	var i := from
	while i < s.length():
		var c := s[i]
		if c == "!" or c == "?":
			return i
		if c == "." and (i + 1 >= s.length() or s[i + 1] != ".") and (i == 0 or s[i - 1] != "."):
			return i
		i += 1
	return -1


## Оставляет первое предложение (отрезает ролевые "действия" после него),
## но если оно короче 3 слов ("Шляпа?", "Ах ты!") - берёт и следующее:
## раньше от "Шляпа? Ну ты и модник..." оставалось одно "Шляпа?".
func _cutToFirstSentence(s: String) -> String:
	var end := _findSentenceEnd(s)
	while end > 0 and s.substr(0, end + 1).split(" ", false).size() < 3:
		var nxt := _findSentenceEnd(s, end + 1)
		if nxt == -1:
			return s.strip_edges()
		end = nxt
	if end > 0:
		return s.substr(0, end + 1).strip_edges()
	return s.strip_edges()


## Heuristic: does this look like the model broke character entirely and
## started writing in English/meta-language instead of a Russian line?
func _looksLikeGarbage(text: String) -> bool:
	var latinCount := 0
	var cyrillicCount := 0
	var upperCyr := 0
	for c in text:
		var code := c.unicode_at(0)
		if (code >= 65 and code <= 90) or (code >= 97 and code <= 122):
			latinCount += 1
		elif code >= 0x0400 and code <= 0x04FF:
			cyrillicCount += 1
			if (code >= 0x0410 and code <= 0x042F) or code == 0x0401:
				upperCyr += 1
	if latinCount > 10 and latinCount > cyrillicCount:
		return true
	# Длинная фраза целиком ЗАГЛАВНЫМИ - у 8B это почти всегда бессвязная каша
	# ("НЕ БЕГУ ОБРАЩАЮСЬ К ТЕБЕ — СТАНЬ ПОМОЩНИКОМ!"). Короткий крик
	# ("ЧТО ЭТО БЫЛО?") оставляем.
	return text.split(" ", false).size() >= 5 and upperCyr * 10 > cyrillicCount * 7


## Catches the model breaking character to comment on the TASK itself
## instead of writing a line (e.g. "Примечание: раз требовалось 7 фраз, я
## выдал ровно семь строк.", or a lone leftover header like "Дополнительно").
## _looksLikeGarbage only catches wrong-alphabet text, not this - it's
## perfectly valid Cyrillic, just not something the character would say.
const _META_MARKERS := [
	"примечание", "дополнительно", "note:", "p.s.", "как и просили",
	"согласно заданию", "в задании", "фраз.", "фраз,", "строк.", "строк,",
	"вот несколько фраз", "как и указано", "требовалось",
	"пользователь", "альтернативный вариант", "конкретное количество",
	# 054.94: в пул Voyager попали "Вот 15 строк:", "Проверь: 15 строк?",
	# "Итого: 15 фраз...", у Milky "— исправленный вариант:", у Dune
	# "Дополнительная строка"
	" строк", "строки:", "фразы", " фраз ", "итого", "проверь:", "персонажк",
	"исправленный", "вариант:", "дополнительная строка", "по стилю", "в духе твое",
	"от лица самой", "от лица самого",
]
## Число + "строк"/"фраз" ("15 строк", "10 фраз") - отчёт модели о задании.
var _metaCountRegex := RegEx.create_from_string("\\d+\\s*(строк|фраз|реплик)")
func _looksLikeMetaCommentary(text: String) -> bool:
	var lower := text.to_lower().strip_edges()
	for marker in _META_MARKERS:
		if lower.contains(marker):
			return true
	if _metaCountRegex.search(lower) != null:
		return true
	# заголовок перед списком ("Вот что ты можешь сказать о себе:")
	if lower.ends_with(":"):
		return true
	# A single bare word with no ending punctuation and no lowercase letters
	# after the first one (like a stray header "Дополнительно") - real lines
	# almost always end in ./!/?/… or are at least a short phrase.
	if lower.split(" ", false).size() <= 1 and not (lower.ends_with(".") or lower.ends_with("!") or lower.ends_with("?") or lower.ends_with("…")):
		return true
	return false


## Categories where the CHARACTER is the one being held/grabbed - the model
## sometimes still flips this and writes as if the character is the one
## doing the holding ("Мне неудобно так держать тебя", "Я держу тебя").
## Prompt calibration reduces this but isn't reliable at 100% on an 8B
## model, so this catches the specific inverted phrasing as a hard backstop.
const _HELD_CATEGORIES := ["grab", "drag_level0", "drag_level1", "drag_level2", "beingDragged"]
const _ROLE_INVERSION_PATTERNS := [
	"держать тебя", "держу тебя", "держал тебя", "держала тебя",
	"держать вас", "держу вас", "тебя в руках у меня",
	"неудобно так держать", "тяжело так держать", "неудобно держать так",
]
func _looksLikeRoleInversion(category: String, text: String) -> bool:
	if not _HELD_CATEGORIES.has(category):
		return false
	var lower := text.to_lower()
	for pattern in _ROLE_INVERSION_PATTERNS:
		if lower.contains(pattern):
			return true
	return false


## Shared "is this basically the same line as one already in `others`" check -
## exact match, or same first 3 words (same tired opener, e.g. "Ты снова...").
## Слова без знаков препинания - иначе "продолжать," и "продолжать"
## считались разными словами, и фразы с одинаковым началом проскакивали.
const _WORD_PUNCT := [".", ",", "!", "?", "…", ";", ":", "\"", "'", "«", "»", "(", ")", "—", "–", "-", "*"]
func _normWords(text: String) -> PackedStringArray:
	var s := text.to_lower()
	for p in _WORD_PUNCT:
		s = s.replace(p, " ")
	return s.split(" ", false)


func _isFuzzyDuplicateOf(text: String, others: Array) -> bool:
	var lowerText := text.to_lower().strip_edges()
	var wordsNew := _normWords(text)
	var setNew := {}
	for w in wordsNew:
		setNew[w] = true
	for other in others:
		var lowerOld := String(other).to_lower().strip_edges()
		if lowerText == lowerOld:
			return true
		var wordsOld := _normWords(lowerOld)
		if wordsNew.size() >= 3 and wordsOld.size() >= 3 and wordsNew[0] == wordsOld[0] and wordsNew[1] == wordsOld[1] and wordsNew[2] == wordsOld[2]:
			return true
		# Word-overlap check (Jaccard-ish) - catches "Ночь - лучшее время для
		# охоты..." vs "Ночь - идеальное время для охоты..." (only one word
		# swapped for a synonym), which the exact-opener check above misses.
		if wordsOld.size() >= 3:
			var setOld := {}
			for w in wordsOld:
				setOld[w] = true
			var shared := 0
			for w in setNew.keys():
				if setOld.has(w):
					shared += 1
			var unionSize := setNew.size() + setOld.size() - shared
			if unionSize > 0 and float(shared) / float(unionSize) >= 0.7:
				return true
	return false


## Чат: ответ "залип", если почти повторяет один из прошлых ответов или
## кончается теми же тремя словами ("...ты снова в деле?").
## Обороты из трёх слов, которые встречаются в 2+ последних ответах чата -
## "затёртые" (так "ты снова в деле" прилипло ко всем ответам подряд).
func _wornOutPhrases(tag: String) -> Array:
	var recent: Array = _recentLinesByCategory.get(tag, [])
	recent = recent.slice(maxi(0, recent.size() - 6))
	var counts := {}
	for line in recent:
		var w := _normWords(String(line))
		var seen := {}
		for i in range(0, w.size() - 2):
			var tri := " ".join(w.slice(i, i + 3))
			if not seen.has(tri):
				seen[tri] = true
				counts[tri] = int(counts.get(tri, 0)) + 1
	var result: Array = []
	for tri in counts.keys():
		if counts[tri] >= 2:
			result.append(tri)
	return result.slice(0, 4)


## Навязчивые темы: значимое слово (5+ букв, сравнение по первым 5 буквам,
## чтобы "мышками"/"мышки" и "охотиться"/"охоты" считались одним), которое
## есть в 3+ из последних 6 фраз. Ловит то, что пропускают тройки слов:
## "Мой хвост сегодня светится/мерцает...", "...мешаешь мне охотиться за мышками".
## Чат и разговор с персонажами одного скина считаются вместе. Латиница
## пропускается - это имена (Expie, Voyager), к ним обращаться можно.
## Возвращает {основа: слово в последней форме}.
## 20.10: "снова"/"опять" убраны из исключений - они и были главным повтором.
const _MOTIF_STOP := ["просто", "сейчас", "только", "очень", "когда", "потому", "может", "хочешь", "хочется", "сегодня", "всегда", "теперь", "здесь", "почему", "ничего", "немного"]
## 054.997: короткие слова тоже бывают навязчивыми (Voyager восемь ответов
## подряд "топила лёд" - а слова короче 5 букв раньше не считались). Служебные
## короткие слова исключаем.
const _MOTIF_SHORT_STOP := ["что", "как", "это", "мне", "меня", "тебе", "тебя", "ты", "мы", "вы", "они", "она", "оно", "его", "её", "ещё", "уже", "вот", "так", "там", "тут", "где", "кто", "для", "без", "над", "под", "при", "про", "или", "нет", "даже", "всё", "все", "был", "была", "было", "если", "чем", "тоже", "свой", "твой", "мой", "моя", "твоя", "себя", "себе", "тем", "этот", "эта", "эти", "раз", "ведь", "лишь", "будто", "пока", "надо", "могу", "хочу", "есть", "буду", "иди", "давай", "знаю", "вижу", "хоть", "чуть", "ну", "да", "же", "ли", "бы", "не", "ни", "но", "а", "и"]
func _obsessiveWords(tag: String) -> Dictionary:
	var recent: Array = _recentLinesByCategory.get(tag, [])
	recent = recent.slice(maxi(0, recent.size() - 6))
	var skin := _skinFromTag(tag)
	if tag.ends_with(":chat") or tag.ends_with(":pettalk"):
		var sibling := skin + (":pettalk" if tag.ends_with(":chat") else ":chat")
		var other: Array = _recentLinesByCategory.get(sibling, [])
		recent = recent + other.slice(maxi(0, other.size() - 3))
	var counts := {}
	var forms := {}
	for line in recent:
		var seen := {}
		for w in _normWords(String(line)):
			if w.length() < 3 or not _isCyrillicWord(w) or (w.length() < 5 and _MOTIF_SHORT_STOP.has(w)) or _isSignatureWord(skin, w):
				continue
			var stem := w.substr(0, 5)
			if _MOTIF_STOP.has(w) or seen.has(stem):
				continue
			seen[stem] = true
			counts[stem] = int(counts.get(stem, 0)) + 1
			forms[stem] = w
	var result := {}
	for stem in counts.keys():
		if counts[stem] >= 3:
			result[stem] = forms[stem]
	return result


## 054.998: фирменные слова персонажа (паспорт, signatureWords) фильтр повторов
## не трогает. Лог 054.997: у Дюны выбрасывалось 89% фраз о состоянии, потому
## что "Дюна" и "еда" есть почти в каждой - это его манера речи, а не повтор;
## да ещё модели велели "обойтись без этих слов", и Дюна начинал говорить
## гладко, как Вояджер. Основа слова: без последней буквы, 2-4 буквы
## ("еда" -> "ед", "охота" -> "охот"), формы слова до +5 букв.
var _signatureCache: Dictionary = {}

func _signatureStems(skin: String) -> Array:
	if not _signatureCache.has(skin):
		var stems: Array = []
		for w in passport(skin).get("signatureWords", []):
			var low := String(w).to_lower()
			stems.append(low.substr(0, clampi(low.length() - 1, 2, 4)))
		_signatureCache[skin] = stems
	return _signatureCache[skin]


func _isSignatureWord(skin: String, w: String) -> bool:
	for st in _signatureStems(skin):
		if w.begins_with(st) and w.length() <= st.length() + 5:
			return true
	return false


func _isCyrillicWord(w: String) -> bool:
	var c := w.unicode_at(0)
	return (c >= 0x0430 and c <= 0x044F) or c == 0x0451


func _hitsObsession(tag: String, text: String) -> bool:
	var motifs := _obsessiveWords(tag)
	if motifs.is_empty():
		return false
	var skin := _skinFromTag(tag)
	for w in _normWords(text):
		if w.length() >= 3 and motifs.has(w.substr(0, 5)) and not _isSignatureWord(skin, w):
			return true
	return false


## Одно и то же начало из двух слов в одной из 4 последних фраз
## ("Мне немного грустно..." / "Мне немного одиноко...").
func _sameOpener(tag: String, text: String) -> bool:
	var words := _normWords(text)
	if words.size() < 3:
		return false
	var recent: Array = _recentLinesByCategory.get(tag, [])
	for old in recent.slice(maxi(0, recent.size() - 4)):
		var ow := _normWords(String(old))
		if ow.size() >= 2 and ow[0] == words[0] and ow[1] == words[1]:
			return true
	return false


## Блок промпта про навязчивые темы (пусто, если их нет).
func _obsessionHint(tag: String) -> String:
	var hint := ""
	var motifs := _obsessiveWords(tag)
	if not motifs.is_empty():
		hint = _g(_skinFromTag(tag), "\nТы уже {зациклилась|зациклился} на этих темах - в этой фразе их НЕ упоминай совсем, скажи о чём-то другом: ") + ", ".join(motifs.values()) + "."
	var worn := _skinOverusedWords(_skinFromTag(tag))
	if not worn.is_empty():
		hint += "\nЭти слова ты в последнее время повторяешь почти в каждой фразе, из-за них ты звучишь однообразно. Сейчас обойдись без них, найди другие слова и другие темы: " + ", ".join(worn.values()) + "."
	return hint


## 054.95, авто-адаптация. _obsessiveWords смотрит только внутрь одной
## ситуации и слова от 5 букв, а повторы из лога 054.94 были другого рода:
## "Дюна" в 41% всех фраз Dune, хвост у Roza, прыжки у Leapy, кровь и паутина
## у Velvet - понемногу в КАЖДОЙ ситуации. Здесь считаем по всем недавним
## фразам скина сразу, по основе из 4 букв (кровь/крови/кровью, хвост/хвостик).
const _SKIN_STOP := ["тебя", "меня", "тебе", "себя", "хочу", "могу", "нужно", "надо", "спасибо", "хорошо",
	"очень", "только", "просто", "сейчас", "когда", "потом", "может", "даже", "всегда",
	"теперь", "здесь", "ничего", "немного", "хоть", "чуть", "будет", "было", "была", "были", "этот", "этого",
	"такой", "тоже", "почти", "больше", "пока", "если", "чтобы", "твой", "твоя", "твои", "твоё", "твою", "твоей",
	"твоих", "твоим", "свой", "своей", "свою", "нравится", "хочется", "давай", "пожалуйста", "знаешь",
	"сегодня", "вообще", "равно", "готов", "готова", "рядом", "чувствую", "стало", "стала", "стал", "есть",
	"всех", "весь", "вся", "лучше", "пусть", "мной", "тобой", "него", "неё", "этой", "этом", "так", "раз"]
const SKIN_WORN_WINDOW := 15 # последних фраз каждой ситуации скина
const SKIN_WORN_SHARE := 0.10 # слово в 10%+ этих фраз - перебор
func _contentStems(text: String, skin: String = "") -> Dictionary:
	var stems := {}
	for w in _normWords(text):
		if w.length() < 4 or not _isCyrillicWord(w) or _SKIN_STOP.has(w) or (skin != "" and _isSignatureWord(skin, w)):
			continue
		var st := w.substr(0, 4)
		if not stems.has(st):
			stems[st] = w
	return stems


## {основа: слово} - что этот скин в последнее время говорит слишком часто.
func _skinOverusedWords(skin: String) -> Dictionary:
	if skin == "":
		return {}
	var lines: Array = []
	for key in _recentLinesByCategory.keys():
		if String(key).begins_with(skin + ":"):
			var list: Array = _recentLinesByCategory[key]
			lines.append_array(list.slice(maxi(0, list.size() - SKIN_WORN_WINDOW)))
	if lines.size() < 30:
		return {} # мало данных - любое слово покажется частым
	var counts := {}
	var forms := {}
	for line in lines:
		var stems := _contentStems(String(line), skin)
		for st in stems.keys():
			counts[st] = int(counts.get(st, 0)) + 1
			forms[st] = stems[st]
	var ranked: Array = counts.keys()
	ranked.sort_custom(func(a, b): return counts[a] > counts[b])
	var result := {}
	for st in ranked:
		if float(counts[st]) / lines.size() < SKIN_WORN_SHARE or result.size() >= 6:
			break
		result[st] = forms[st]
	return result


## Убирает из ответа куски (между " — ", " - ", ", "), где сидит затёртый
## оборот. Если от фразы почти ничего не остаётся - возвращает как было.
func _stripWornClause(tag: String, text: String) -> String:
	var worn := _wornOutPhrases(tag)
	if worn.is_empty():
		return text
	var parts := text.replace(" - ", " — ").split(" — ")
	var kept: Array = []
	for part in parts:
		var joined := " " + " ".join(_normWords(part)) + " "
		var bad := false
		for tri in worn:
			if joined.contains(" " + tri + " "):
				bad = true
				break
		if not bad:
			kept.append(part.strip_edges())
	var result := " — ".join(kept).strip_edges().trim_suffix(",").strip_edges()
	if result.split(" ", false).size() < 2:
		return text
	if not (result.ends_with(".") or result.ends_with("!") or result.ends_with("?") or result.ends_with("…")):
		result += "."
	return result


## Конец фразы (3 последних слова) совпал с концом одной из недавних -
## отрезаем последний кусок после " — " или ", " ("Expie — странный, но
## ты знаешь: я всё равно с тобой" -> "Expie — странный"). Если от фразы
## остаётся меньше 3 слов - возвращаем как было.
func _stripRepeatedTail(tag: String, text: String) -> String:
	var words := _normWords(text)
	if words.size() < 5:
		return text
	var tail := " ".join(words.slice(words.size() - 3))
	var recent: Array = _recentLinesByCategory.get(tag, [])
	var repeated := false
	for old in recent.slice(maxi(0, recent.size() - 6)):
		var ow := _normWords(String(old))
		if ow.size() >= 3 and " ".join(ow.slice(ow.size() - 3)) == tail:
			repeated = true
			break
	if not repeated:
		return text
	var cut := -1
	for sep in [" — ", " - ", ", но ", ": ", ", "]:
		cut = maxi(cut, text.rfind(sep))
	if cut <= 0:
		return text
	var head := text.substr(0, cut).strip_edges()
	if head.split(" ", false).size() < 3:
		return text
	if not (head.ends_with(".") or head.ends_with("!") or head.ends_with("?") or head.ends_with("…")):
		head += "."
	return head


func _chatLooksStuck(tag: String, text: String) -> bool:
	var recent: Array = _recentLinesByCategory.get(tag, [])
	recent = recent.slice(maxi(0, recent.size() - 6))
	if _isFuzzyDuplicateOf(text, recent):
		return true
	var joined := " " + " ".join(_normWords(text)) + " "
	for tri in _wornOutPhrases(tag):
		if joined.contains(" " + tri + " "):
			return true
	if _sameOpener(tag, text) or _hitsObsession(tag, text):
		return true
	var words := _normWords(text)
	if words.size() < 3:
		return false
	var tail := " ".join(words.slice(words.size() - 3))
	for old in recent:
		var ow := _normWords(String(old))
		if ow.size() >= 3 and " ".join(ow.slice(ow.size() - 3)) == tail:
			return true
	return false


## Hard enforcement for "don't repeat yourself" - the prompt-based instruction
## alone isn't reliable (small models sometimes copy the very "don't repeat
## this" examples instead of avoiding them). Catches exact repeats and
## near-identical openers (same first 3 words = same tired pattern, e.g.
## "Ты снова..." every time) regardless of what the model intended. Checked
## only within the SAME category - see _rememberLine for why.
func _looksLikeRepeat(category: String, text: String) -> bool:
	if _isFuzzyDuplicateOf(text, _recentLinesByCategory.get(category, [])):
		return true
	return _sameOpener(category, text) or _hitsObsession(category, text)


## Console command: reloadLore
func reloadLore() -> void:
	_loadLore()
	# лор и род каждого скина кэшируются при первом запросе - без сброса
	# правка lore.txt/character.json не применялась до перезапуска игры
	_loreBySkin.clear()
	_genderBySkin.clear()
	_passportBySkin.clear()
	_signatureCache.clear()
	_speechBySkin.clear()
	_clearPrefetchPools() # old cached lines were written under the old lore
	print("LLMManager: lore reloaded (", lore.length(), " chars)")
	poolsCleared.emit()


## 054.998, переписанная схема запросов (пункт 2в отчёта 054.997).
## Порядок для маленькой модели, которая лучше помнит начало и конец:
##   1) кто ты: _buildBasePrompt - одна строка о мире + лор персонажа;
##   2) что сейчас: состояние, экран, разговор, ситуация - добавляет build*Prompt;
##   3) правила: _closingBlock - короткий список, каждое правило один раз
##      (раньше "не вопрос", "от своего лица", "не начинай с Ты снова"
##      повторялись в 3-4 местах и тонули в середине);
##   4) напоминание "как ты говоришь" из лора - последним перед репликой
##      (Дюна говорил гладко, как Вояджер: описание речи терялось в середине).
## Подробно - test-stand/КАК_УСТРОЕНЫ_ЗАПРОСЫ.txt.
func _buildBasePrompt(category: String = "") -> String:
	var parts: Array[String] = []
	parts.append("Ты - маленькое существо-савианин и живёшь на рабочем столе у своего человека. (Если зайдёт речь о крови: у всех савиан, и у тебя, она жёлтая.)")
	var skinLore := _loreFor(_skinFromTag(category))
	if skinLore != "":
		parts.append("О себе ты знаешь:\n" + skinLore)
	return "\n".join(parts)


## Правила + что персонаж уже говорил + напоминание о манере речи.
## lines > 1 - пакет фраз для пула (каждая с новой строки).
func _closingBlock(category: String, lines: int = 1) -> String:
	var skin := _skinFromTag(category)
	var r: Array[String] = []
	if lines > 1:
		r.append("- напиши %d РАЗНЫХ коротких фраз (3-15 слов), каждую с новой строки, без нумерации, кавычек и пояснений;" % lines)
	elif lines == 0: # разговор - можно чуть длиннее
		r.append("- только по-русски, одной-двумя короткими фразами в одну строку; выведи только саму реплику - без кавычек, пояснений, эмодзи и описаний действий (никаких *зевает*);")
	else:
		r.append("- только по-русски, ОДНОЙ фразой из 3-20 слов; выведи только саму реплику - без кавычек, пояснений, эмодзи и описаний действий (никаких *зевает*);")
	r.append("- говори от своего лица; что делают с тобой (держат, гладят, кормят) - происходит с ТОБОЙ;")
	# Без примеров слов: модель вставляет пример прямо в ответ - с "я устал"
	# в примере "Я устал" стало в 47 фразах из 352, с "я сделал" Експи выдал
	# "Я сделал, что ты пришёл!"; запрет "не начинай с Это" дал 32 фразы
	# с "Это" вместо 12 (стенд 19.10). Поэтому - только общие слова.
	# 20.10: то же с "не начинай с 'Ты снова' или 'Опять'" - "опять" было в трети
	# реакций на экран (стенд fear8: 63 из 192), убрано.
	r.append("- о себе - в {женском|мужском} роде; к человеку только на 'ты', он парень;")
	r.append("- ПОЧТИ ВСЕГДА утверждение или восклицание; вопрос - редко и только короткий. Начинай каждую фразу по-своему;" if lines != 0 else "- вопрос в ответ можно, но не в каждой реплике;")
	r.append("- только настоящие русские слова, ничего не выдумывай;")
	if gbData.settings.get("llmAllowProfanity", false):
		# 054.997: стенд test_profanity - так мат в ~40% злых фраз и в разных местах
		r.append("- мат можно, но примерно в каждой третьей фразе: только в злых, резких или когда больно; в спокойных и ласковых - без него. Ругательство в середину или конец фразы, не в начало; настоящие слова и их формы (блять, сука, хуй, пиздец, нахер, ебать), разные; не выдумывай и не искажай их;")
	else:
		r.append("- мат и ругательства запрещены, даже если ты злишься;")
	if gbData.settings.get("llmFlirtEnabled", false):
		# 054.999: флирт по роду (просьба Alex и тестеров): персонажу-девушке - смелее
		# и чаще, персонажу-парню - без романтики к человеку-парню, по-приятельски
		if isFemale(skin):
			r.append("- в хорошем настроении можешь кокетничать с человеком-парнем: игривые комплименты, поддразнивания, лёгкие намёки на симпатию - тепло и смело, но без пошлости;")
		else:
			r.append("- с человеком-парнем ты как с близким другом: можешь по-приятельски хвалить и подкалывать, но без романтики и намёков;")
	else:
		r.append("- без флирта и романтики - только дружеское отношение;")
	if banWords.size() > 0:
		r.append("- никогда не используй эти слова: " + ", ".join(banWords) + ";")
	var out := "\nПравила ответа:\n" + "\n".join(r)
	# Только фразы ЭТОЙ ситуации - общий список "что говорил недавно"
	# перетаскивал словечки одной ситуации в другую (Full подхватывал "отпусти" из drag).
	var recentForThis: Array = _recentLinesByCategory.get(category, [])
	if recentForThis.size() > 0:
		out += "\nНедавно в такой же ситуации ты {говорила|говорил}:\n- " + "\n- ".join(recentForThis.slice(maxi(0, recentForThis.size() - 4))) + "\nНе повторяй их и их начало - скажи по-новому."
	if not category.ends_with(":chat"): # у чата свой такой же блок
		var worn := _wornOutPhrases(category)
		if worn.size() > 0:
			out += "\nЭти обороты ты уже {затёрла|затёр} до дыр - не используй их: \"" + "\", \"".join(worn) + "\"."
	var obsession := _obsessionHint(category)
	if obsession != "":
		out += "\n" + obsession.strip_edges()
	var speech := _speechFor(skin)
	if speech != "":
		# "(это описание, а не слова для фразы)": лор Вельвет начинается с "Медленно, мягко,
		# ласково" - и она стала начинать фразы словом "Медленно..." (лог 19.10)
		out += "\nГлавное - говори так, как говоришь всегда (это описание твоей манеры, а не слова для фразы): " + speech
	# 054.999: без этого речь стала суше - у Вояджер восклицаний 32 -> 9 из ~430
	# ("тон спокойный" из лора модель поняла буквально)
	out += "\nГовори живо и с интонацией: где-то восклицание, где-то многоточие или пауза - будь {интересной и живой|интересным и живым}, а не сухой справкой."
	return out


## Раздел "Как ты говоришь:" (у Вояджер - "Тон речи:") из лора - до пустой
## строки. Повторяется в конце запроса как напоминание (1в, проверено стендом).
var _speechBySkin: Dictionary = {}

func _speechFor(skin: String) -> String:
	if not _speechBySkin.has(skin + str(useLiteLore())):
		var text := ""
		var lore := _loreFor(skin)
		for head in ["Как ты говоришь:", "Тон речи:"]:
			var i := lore.find(head)
			if i >= 0:
				var rest := lore.substr(i + head.length()).strip_edges()
				var end := rest.find("\n\n")
				text = (rest if end < 0 else rest.substr(0, end)).replace("\n", " ").strip_edges()
				break
		_speechBySkin[skin + str(useLiteLore())] = text
	return _speechBySkin[skin + str(useLiteLore())]


## Вкусы персонажа словами (из паспорта) - для чата, предметов и фраз о еде.
## Без этого Дюна в чате отказывался от жёлтой плоти, хотя любит её.
const TASTE_NAMES := {"bread": "хлеб", "pizzaslice": "пицца", "burger": "бургер", "banana": "банан", "juicedobry": "сок", "geofruit": "геофрукт", "yellowflesh": "жёлтая плоть"}

func tastesText(skin: String) -> String:
	var tastes = passport(skin).get("tastes", {})
	if not (tastes is Dictionary) or tastes.is_empty():
		return ""
	var love: Array = []
	var hate: Array = []
	for k in tastes.keys():
		if int(tastes[k]) >= 8:
			love.append(TASTE_NAMES.get(k, k))
		elif int(tastes[k]) <= 3:
			hate.append(TASTE_NAMES.get(k, k))
	var bits: Array = []
	if not love.is_empty():
		bits.append("обожаешь " + ", ".join(love))
	if not hate.is_empty():
		bits.append("терпеть не можешь " + ", ".join(hate))
	return ("\nВ еде ты " + "; ".join(bits) + ".") if not bits.is_empty() else ""


func _pickScreenSpeaker() -> Node:
	var candidates: Array = []
	for pet in get_tree().get_nodes_in_group("pets"):
		if not (pet.isPlayer or pet.isSleeping or pet.isUnconscious or pet.beingDragged or pet.shocked or pet.isQuiet()):
			candidates.append(pet)
	return null if candidates.is_empty() else candidates[randi() % candidates.size()]


var _screenDeferred := false

func _on_screen_tick() -> void:
	if not gbData.settings.get("llmVisionEnabled", true):
		_scheduleScreenTick()
		return

	# Реакцию на экран говорит ОДИН случайный ИИ-персонаж - своим лором, родом
	# и состоянием. Раньше одна фраза (с лором defaultSkin) рассылалась всем,
	# и Expie говорил "я бы сделала точнее" голосом Voyager.
	# 054.9992: идёт разговор - реакцию на экран один раз откладываем на 20-40 с
	if GlobalVariable.inDialogue() and not _screenDeferred:
		_screenDeferred = true
		_scheduleScreenTick(randf_range(20.0, 40.0))
		return
	_screenDeferred = false
	var speaker: Node = _pickScreenSpeaker()
	_scheduleScreenTick()
	if speaker == null:
		return
	var tag: String = speaker._skinTag() + ":screen"

	# 054.992: снимок в фоновом потоке - главный поток игры не замирает
	if not ScreenCapture.CaptureAsync():
		return # прошлый снимок ещё делается - пропускаем этот тик
	var png_bytes: PackedByteArray = await ScreenCapture.ScreenshotReady
	if png_bytes.is_empty() or not is_instance_valid(speaker):
		return

	var images: Array = [Marshalls.raw_to_base64(png_bytes)]
	var prompt := buildScreenPrompt(tag, speaker._aiStateHint())
	_enqueue(prompt, images, func(text):
		if is_instance_valid(speaker):
			speaker._on_llm_reaction(text, true), tag)


func buildScreenPrompt(tag: String, stateHintText: String) -> String:
	var prompt := _buildBasePrompt(tag)
	prompt += "\n\nСейчас: ты смотришь на скриншот рабочего стола своего человека. Самого человека на нём нет - это просто его экран. Маленькие пиксельные существа поверх окон - ты и твои соседи. Люди, звери и персонажи в видео, стримах, звонках и на фото - просто картинки, они тебя не видят."
	prompt += "\nНе описывай экран ('Это окно...', 'На экране видно...') - человек и сам его видит. Отреагируй на увиденное как живой персонаж: своими словами и со своим отношением."
	prompt += "\nПодход на этот раз: " + _pickScreenAngle()
	prompt += _closingBlock(tag)
	# самочувствие - в самом конце, рядом с ответом: в середине модель его
	# не замечала (раненый Дюна на стенде говорил только "Дюна голодный")
	prompt += stateHintText
	prompt += "\nТвоя реплика:"
	return prompt


## Почему экранные реакции звучали одинаково при любой креативности:
## картинка перевешивала характер, и модель каждый раз просто ОПИСЫВАЛА
## экран ("Это окно экспорта проекта..."), а описание одного и того же
## экрана почти не зависит от температуры (проверено на qwen3-vl:8b при
## 0.1 и 1.5). Запрет на описание + случайный "угол" реакции на каждый
## скриншот дают разные по смыслу фразы. Углы общие для всех скинов - без
## привязки к конкретному персонажу (охота и т.п. берётся из его лора).
## 054.998: без "строгого совета" и "оцени, как справляется" - это голос
## Вояджер, и Дюна по ним говорил её словами ("Ты снова гонишь видеокарту?").
const SCREEN_ANGLES := [
	"подколи или похвали человека за то, чем он занят, - по-своему.",
	"свяжи увиденное со своим характером или прошлым.",
	"выскажи личное мнение - нравится тебе это или нет.",
	"зацепись за одну мелкую деталь.",
	"отреагируй эмоцией - скукой, азартом, удивлением, страхом или раздражением.",
	"скажи, чего тебе захотелось, глядя на это.",
	"пошути над увиденным в своём стиле.",
]
var _lastScreenAngle := -1

func _pickScreenAngle() -> String:
	var idx := randi() % SCREEN_ANGLES.size()
	if idx == _lastScreenAngle:
		idx = (idx + 1) % SCREEN_ANGLES.size() # не два одинаковых подхода подряд
	_lastScreenAngle = idx
	return SCREEN_ANGLES[idx]



## Общая подсказка состояния для динамических реакций (экран, предметы):
## настроение/здоровье + фентанил. Опьянение и ломка перекрашивают тон
## поверх обычного настроения.
func stateHint(mood: float, health: float, drugLevel: int) -> String:
	var drug := ""
	match drugLevel:
		1:
			drug = "\nТы под фентанилом (лёгкий приход): спокойнее и мягче обычного - это лишь слегка окрашивает тон, сам приход не описывай."
		2:
			drug = "\nТы сильно под фентанилом: {рассеянна, расслаблена и слишком довольна|рассеян, расслаблен и слишком доволен} - передавай это тоном и простыми словами, не описывая ощущения ('плывёт', 'волна', 'тепло')."
		-1:
			# 054.9991: было "...- это сквозит в реакции" - 12b так и делала: только намекала,
			# ломку было не понять без дрожащего текста (тест Alex 20.10)
			drug = "\nУ тебя ломка без фентанила: трясёт и знобит, ломит кости, мутит, мысли только о дозе. Тебе по-настоящему плохо, и это слышно прямо в словах."
	return _moodHealthHint(mood, health) + drug


## 054.998: раны и настроение - отдельно. Раньше общая подсказка "тебе плохо:
## усталость, боль или подавленность" превращала злость в "я устал" у всех
## (стенд 19.10): плохое настроение - это раздражение, а раны - это боль.
func _moodHealthHint(mood: float, health: float) -> String:
	var out := ""
	if health <= 15.0:
		out += "\nТы тяжело {ранена|ранен}: всё болит, сил почти нет - говори коротко и через боль, это главное сейчас."
	elif health <= 40.0:
		out += "\nТы {ранена|ранен}, раны болят - это заметно в том, что ты говоришь."
	elif health <= 70.0:
		out += "\nУ тебя есть раны, они немного ноют."
	if mood <= -60.0:
		out += "\nНастроение ужасное: ты {злая и раздражённая|злой и раздражённый}, огрызаешься - это злость, а не усталость."
	elif mood <= -30.0:
		out += "\nНастроение плохое: ты {раздражена|раздражён} и {недовольна|недоволен}."
	elif mood <= -10.0:
		out += "\nНастроение так себе, проскальзывает лёгкое раздражение."
	return out


## Wraps a situation/event description so the prompt clearly marks it as
## background context, not a line to read aloud. Small local models tend to
## just paraphrase a bare description back as if it were the answer itself
## (e.g. "Тебя держат слишком долго" -> "Тебя держат слишком долго - вырвусь!")
## - this framing plus an explicit "don't repeat it" instruction fixes that.
func _situationBlock(description: String) -> String:
	if description == "":
		return ""
	return "\n\nСейчас (это описание для тебя, а НЕ реплика): " + description + "\nСкажи, что ТЫ {почувствовала|почувствовал} бы, своими словами и не пересказывая описание. Например, тебя держат в руках: правильно - 'Отпусти меня!' (о себе); неправильно - 'Тяжело тебя держать' (перепутаны роли)."


## Trigger an immediate, text-only reaction to something happening right now.
## Pass `callback` to deliver the result to ONE specific pet, bypassing the
## broadcast (and its "don't interrupt" guards) - see behavior.gd/dragExp.gd.
func reactToEvent(eventDescription: String, callback: Callable = Callable(), tag: String = "event") -> void:
	if not gbData.settings.get("llmVisionEnabled", true):
		return
	var prompt := _buildBasePrompt(tag) + _situationBlock(eventDescription) + _closingBlock(tag) + "\nТвоя реплика:"
	var cb := callback
	if not cb.is_valid():
		cb = func(text): llmReaction.emit(text)
	_enqueue(prompt, [], cb, tag)


## Реакция на предмет рядом (behavior.itemWatch). Как и экранные - живой
## запрос без пула, со случайным "углом", чтобы не звучать одинаково.
const ITEM_ANGLES := [
	"оцени, пригодится ли он тебе.",
	"скажи, что бы ты с ним {сделала|сделал}.",
	"подколи человека за то, что он оставил это рядом с тобой.",
	"вырази желание или отвращение.",
	"вспомни, что он тебе напоминает.",
	"пошути над ним в своём стиле.",
]

func requestItemReaction(skinTag: String, itemDescription: String, stateHintText: String, callback: Callable) -> void:
	if not gbData.settings.get("llmVisionEnabled", true):
		return
	_enqueue(buildItemPrompt(skinTag, itemDescription, stateHintText), [], callback, skinTag + ":item")


func buildItemPrompt(skinTag: String, itemDescription: String, stateHintText: String) -> String:
	var tag := skinTag + ":item"
	var prompt := _buildBasePrompt(tag)
	prompt += "\n\nСейчас: рядом с тобой на рабочем столе лежит предмет - " + itemDescription + ". Не описывай его, а вырази своё отношение к нему."
	prompt += "\nПодход на этот раз: " + ITEM_ANGLES[randi() % ITEM_ANGLES.size()]
	if stateHintText != "":
		prompt += "\n" + stateHintText.strip_edges()
	prompt += _closingBlock(tag)
	prompt += "\nТвоя реплика:"
	return prompt


## Ответ ИИ-персонажа на реплику игрока (PlayerManager). Высший приоритет:
## встаёт первым в очередь, а идущую фоновую генерацию пакета фраз
## прерывает (она потом повторится). Без примеров из TRANSLATION.json -
## только лор, состояние и сам разговор.
## Действия, на которые ИИ-персонаж может согласиться в чате (метка в ответе).
const CHAT_ACTIONS := {
	"подойти": "come", "лечь": "lie", "сесть": "sit",
	"встать": "stand", "прыгнуть": "jump", "отойти": "away",
}
var _actionRegex := RegEx.create_from_string("\\[\\s*(?:ДЕЙСТВИЕ|Действие|действие)\\s*:\\s*([^\\]]+)\\]")

## Случайный тон ответа в чате - чтобы разговор не был однотонным.
const CHAT_ANGLES := [
	"ответь с подколкой, но по делу.",
	"прояви любопытство - ответь и задай встречный вопрос.",
	"ответь эмоционально: удивлением, возмущением или радостью.",
	"ответь в своём стиле и добавь неожиданную деталь из своего характера или прошлого.",
	"ответь коротко и хлёстко.",
	"ответь тепло, но не теряя гордости и характера.",
	"ответь с иронией над ситуацией.",
]

## Отношение персонажа к другому - из паспорта (relations[папка скина]).
func relationTo(skinName: String, otherSkin: String) -> String:
	for path in ["user://skin/%s/character.json" % skinName, "res://defaults/skins/%s/character.json" % skinName]:
		if FileAccess.file_exists(path):
			var data = JSON.parse_string(FileAccess.get_file_as_string(path))
			if data is Dictionary and data.get("relations") is Dictionary:
				# "*" - отношение ко всем, кто не указан отдельно
				var r := String(data["relations"].get(otherSkin, data["relations"].get("*", "")))
				return "" if r == "?" else r
	return ""


## Кто это: имя + вид, номер Saw и род из паспорта ("Voyager (вид Voyager, Saw-07, женского рода)").
func aboutCharacter(skinName: String, withGender: bool = true) -> String:
	var shown: String = PlayerManager.displayNameFor(skinName)
	for path in ["user://skin/%s/character.json" % skinName, "res://defaults/skins/%s/character.json" % skinName]:
		if FileAccess.file_exists(path):
			var data = JSON.parse_string(FileAccess.get_file_as_string(path))
			if data is Dictionary:
				var bits: Array = []
				if String(data.get("race", "")) != "":
					bits.append("вид " + String(data["race"]))
				if withGender:
					bits.append("женского рода" if String(data.get("gender", "")) == "female" else "мужского рода")
				# что о нём знают остальные (раньше персы ничего не знали,
				# например, о том, что Дюну все боятся)
				var desc := String(data.get("description", "")).strip_edges().trim_suffix(".")
				if desc != "":
					var about := "о ней" if String(data.get("gender", "")) == "female" else "о нём"
					return "%s (%s). Что ты %s знаешь: %s" % [shown, ", ".join(bits), about, desc]
				return "%s (%s)" % [shown, ", ".join(bits)]
	return shown


## 054.994: общие воспоминания - аккуратно. Рыжик "вспомнил", как человек учил
## его есть из чашки, и потом цеплялся за это в каждом ответе. Пользователю
## сама механика понравилась: теперь примерно в каждом пятом разговоре можно
## вспомнить мелочь из жизни на столе и держаться её, если она уже звучала;
## в остальных - не выдумывать.
const NO_FAKE_MEMORIES := "\nНе придумывай общих воспоминаний и событий, которых нет в разговоре выше и в описании тебя."
const SMALL_MEMORY_OK := "\nЕсли к месту, можешь вспомнить небольшой случай из вашей жизни на этом рабочем столе - мелочь, без громких событий. Если такой случай уже упоминался в разговоре выше - держись его и не противоречь, новых не добавляй."
const MEMORY_CHANCE := 0.2

func _memoriesRule() -> String:
	return SMALL_MEMORY_OK if randf() < MEMORY_CHANCE else NO_FAKE_MEMORIES

## Поводы для разговора двух персонажей (один выбирается случайно).
const PET_TOPICS := [
	"то, чем сейчас занят человек за компьютером - пожалуйся, похвали или пошути об этом.",
	"еда - чем вас тут кормят и чего бы хотелось.",
	"ваше прошлое: лаборатория, тесты, корпорация, которая вас создала.",
	"внешность или привычки собеседника - что тебе в нём кажется странным, смешным или впечатляющим.",
	"ваши виды: чем твой вид лучше или хуже его вида.",
	"человек, который с вами возится: как он с вами обращается.",
	"скука - предложи собеседнику чем-нибудь заняться.",
	"что-то недавно случившееся с тобой здесь (падение, сон, еда, тебя таскали курсором).",
	"сон и усталость - кто из вас больше спит.",
	"просто подколи собеседника в своём стиле.",
	"спроси у собеседника что-то личное и простое.",
	"страх - чего ты боишься здесь, на рабочем столе.",
]


## Один ИИ-персонаж сам заговаривает с другим, стоящим рядом.
func requestPetOpener(skinTag: String, otherSkin: String, stateText: String, callback: Callable, history: Array = [], otherState: String = "") -> void:
	if not gbData.settings.get("llmVisionEnabled", true):
		return
	_enqueue(buildPetOpenerPrompt(skinTag, otherSkin, stateText, history, otherState), [], callback, skinTag + ":pettalk")


func buildPetOpenerPrompt(skinTag: String, otherSkin: String, stateText: String, history: Array = [], otherState: String = "") -> String:
	var tag := skinTag + ":pettalk"
	var myName: String = PlayerManager.displayNameFor(skinTag)
	var prompt := _buildBasePrompt(tag)
	prompt += "\n\nСейчас: рядом с тобой стоит другой персонаж - %s." % aboutCharacter(otherSkin)
	var rel := relationTo(skinTag, otherSkin)
	if rel != "":
		prompt += "\nТвоё отношение к нему: " + rel + "."
	prompt += _historyBlock(history, myName, "Вы уже разговаривали (внизу - самое недавнее):")
	prompt += "\nТвоё состояние: " + stateText.strip_edges()
	if otherState != "":
		prompt += "\nСостояние собеседника: " + otherState.strip_edges() + "."
	# конкретный повод - без него реплики были гладкими, но ни о чём
	prompt += "\nЗаговори с ним первым. Повод: " + PET_TOPICS[randi() % PET_TOPICS.size()] + " Если кто-то из вас ранен или ему плохо - начни с этого."
	prompt += _memoriesRule()
	prompt += _closingBlock(tag)
	prompt += "\nТвоя реплика:"
	return prompt


## Прошлый разговор строками "Ты: ..." / "Имя: ..." (пусто, если не было).
func _historyBlock(history: Array, myName: String, title: String) -> String:
	if history.is_empty():
		return ""
	var lines: Array = []
	for e in history:
		var who := String(e.get("who", ""))
		lines.append(("Ты" if who == myName else who) + ": " + String(e.get("text", "")))
	return "\n" + title + "\n" + "\n".join(lines) + "\nМожешь продолжить или начать новую тему, но не повторяй уже сказанное."


## 054.99: ИИ-персонаж сам заговаривает с персом-игроком (человеком в теле
## персонажа). Реплика идёт в его память разговора с игроком - на неё можно
## ответить через Enter.
func requestPlayerOpener(skinTag: String, playerSkin: String, stateText: String, history: Array, playerState: String, callback: Callable) -> void:
	if not gbData.settings.get("llmVisionEnabled", true):
		return
	_enqueue(buildPlayerOpenerPrompt(skinTag, playerSkin, stateText, history, playerState), [], callback, skinTag + ":chat")


func buildPlayerOpenerPrompt(skinTag: String, playerSkin: String, stateText: String, history: Array, playerState: String) -> String:
	var tag := skinTag + ":chat"
	var myName: String = PlayerManager.displayNameFor(skinTag)
	var prompt := _buildBasePrompt(tag)
	prompt += "\n\nСейчас: рядом с тобой стоит %s - персонаж, которым управляет твой человек." % aboutCharacter(playerSkin, false)
	prompt += _playerFormRule(skinTag, playerSkin)
	prompt += _historyBlock(history, myName, "Ваш прошлый разговор (внизу - самое недавнее):")
	prompt += "\nТвоё состояние: " + stateText.strip_edges()
	if playerState != "":
		prompt += "\nСостояние его персонажа: " + playerState.strip_edges() + "."
	# вкусы - только когда речь о еде (иначе Вельвет сравнивала всё с бургером)
	var topic: String = PET_TOPICS[randi() % PET_TOPICS.size()]
	if topic.begins_with("еда"):
		prompt += tastesText(skinTag)
	prompt += "\nЗаговори с ним первым. Повод: " + topic + " Если кто-то из вас ранен или ему плохо - начни с этого."
	prompt += _memoriesRule()
	prompt += _closingBlock(tag)
	prompt += "\nТвоя реплика:"
	return prompt


## Человек в теле персонажа: к виду - как в паспорте, но внутри - свой
## человек, и отношение к нему (из лора) важнее. Женский облик - обращаться
## в женском роде, изредка по-доброму обыгрывая маскарад.
func _playerFormRule(skinTag: String, playerSkin: String) -> String:
	if playerSkin == "":
		return ""
	# 054.999: gemma на стенде говорила о собеседнике "он пытался...", будто человек
	# и его персонаж - два разных существа
	var out := "\nЭтот персонаж и есть твой человек - говори с ним на 'ты', а не о нём в третьем лице."
	var rel := relationTo(skinTag, playerSkin)
	if rel != "" and rel != "своя" and rel != "свой":
		out += "\nК его виду ты относишься так: " + rel + ". Но внутри - твой человек, и к нему ты относишься как всегда: вид можешь подколоть, человека - нет."
	if isFemale(playerSkin):
		out += "\nОн сейчас в женском облике - обращайся в женском роде ('ты пришла'); изредка, не в каждой фразе, можешь по-доброму обыграть, что внутри твой человек-парень."
	return out


## speakerSkin - скин ИИ-собеседника (разговор персов); для игрока пусто.
## playerSkin - скин перса-игрока; speakerState - здоровье/настроение собеседника.
func requestChatReply(skinTag: String, speaker: String, chatHistory: Array, stateText: String, ownRecent: Array, callback: Callable, speakerSkin: String = "", playerSkin: String = "", speakerState: String = "") -> void:
	GlobalVariable.lastDialogueMsec = Time.get_ticks_msec() # идёт разговор - фоновые фразы подождут
	if not gbData.settings.get("llmVisionEnabled", true):
		return
	var tag := skinTag + ":chat"
	var prompt := buildChatReplyPrompt(skinTag, speaker, chatHistory, stateText, ownRecent, speakerSkin, playerSkin, speakerState)

	# в разговоре чуть "смелее" обычного - живее и разнообразнее
	var job := {"prompt": _g(skinTag, prompt), "images": [], "callback": callback, "tag": tag, "temperature": minf(1.1, creativity + 0.05)}
	if busy and _currentTag.begins_with("prefetch:") and not _currentJob.is_empty():
		# прерываем фоновый пакет - ответ человеку важнее
		http.cancel_request()
		_watchdogTimer.stop()
		_backgroundQueue.push_front(_currentJob)
		busy = false
	_queue.push_front(job)
	_processQueue()


func buildChatReplyPrompt(skinTag: String, speaker: String, chatHistory: Array, stateText: String, ownRecent: Array, speakerSkin: String = "", playerSkin: String = "", speakerState: String = "") -> String:
	var tag := skinTag + ":chat"
	var myName: String = PlayerManager.displayNameFor(skinTag) # так же, как имя записано в истории разговора
	var prompt := _buildBasePrompt(tag)
	if speakerSkin == "":
		prompt += "\n\nСейчас: с тобой разговаривает %s - персонаж на рабочем столе, которым управляет твой человек." % (aboutCharacter(playerSkin, false) if playerSkin != "" else speaker)
		prompt += _playerFormRule(skinTag, playerSkin)
	else:
		# ответ другому ИИ-персонажу (behavior.petTalkLoop)
		prompt += "\n\nСейчас: с тобой заговорил %s - другой персонаж, который живёт рядом." % aboutCharacter(speakerSkin)
		var rel := relationTo(skinTag, speakerSkin)
		if rel != "":
			prompt += "\nТвоё отношение к нему: " + rel + "."
	prompt += "\nТвоё состояние: " + stateText.strip_edges()
	if speakerState != "":
		prompt += "\nСостояние собеседника: " + speakerState.strip_edges() + "."
	prompt += "\nЕсли кто-то из вас ранен или ему плохо - это должно чувствоваться: не болтай беззаботно."
	# 054.999: вкусы - только когда в последней реплике речь о еде: с ними в
	# каждом разговоре Вельвет сравнивала всё подряд с бургером (лог 19.10)
	if chatHistory.size() > 0 and _aboutFood(String(chatHistory[chatHistory.size() - 1].get("text", ""))):
		prompt += tastesText(skinTag)
	# Общая память: что персонаж сам говорил вслух вне разговора (экран,
	# состояние, предметы) - чтобы понимать вопросы вроде "почему ты так сказала?"
	var inChat := {}
	for entry in chatHistory:
		inChat[String(entry.get("text", ""))] = true
	var own: Array = []
	# 054.999: свои слова до разговора - только когда о них спрашивают. Если давать
	# их всегда и рядом с разговором, Вояджер в каждом ответе повторяла
	# "убирай рекламу" из своей фразы про экран (стенд talk2, 19.10).
	var lastText: String = String(chatHistory[chatHistory.size() - 1].get("text", "")) if chatHistory.size() > 0 else ""
	# 054.9992: но свою СВЕЖУЮ фразу (меньше минуты назад) - всегда: Роза сказала
	# "мне совсем нехорошо", на "Что случилось?" ответила "Ты меня напугал!", а на
	# "Ты его хочешь?" (про банан из её же фразы) - про лепестки сакуры (тест 20.10)
	var justSaid := ""
	if not _asksAboutPast(lastText):
		for e in ownRecent:
			if int(e["minutesAgo"]) == 0 and not inChat.has(String(e["text"])):
				justSaid = String(e["text"])
		ownRecent = []
	for e in ownRecent:
		if not inChat.has(String(e["text"])):
			var ago: int = int(e["minutesAgo"])
			own.append("(%s) %s" % ["только что" if ago == 0 else "%d мин назад" % ago, e["text"]])
	# 054.97: на "могу дать сок или еду" перс пообещал "принесу тебе в лапах"
	prompt += "\nПредметы на стол кладёт только человек; ты их принимаешь, но никому не приносишь. Предлагают что-то - это дают ТЕБЕ: обрадуйся, выбери или откажись."
	# 054.999: свои слова до разговора - вплотную к разговору, а не в середине
	# запроса: на "что ты сказала про экран?" Вояджер отвечала общими словами,
	# не вспомнив свою же фразу (стенд talk, 19.10)
	if own.size() > 0:
		prompt += "\nЧто ты {сама|сам} {сказала|сказал} вслух незадолго до этого разговора (в том числе про экран):\n- " + "\n- ".join(own)
	elif justSaid != "":
		prompt += "\nТы только что {сказала|сказал} вслух: \"" + justSaid + "\" - собеседник, скорее всего, отвечает именно на это."
	var last := ""
	if chatHistory.size() > 0:
		var lines: Array = []
		for entry in chatHistory:
			var who: String = String(entry.get("who", ""))
			lines.append(("Ты" if who == myName else who) + ": " + String(entry.get("text", "")))
		prompt += "\nРазговор (внизу - самая новая реплика):\n" + "\n".join(lines)
		last = String(chatHistory[chatHistory.size() - 1].get("text", ""))
	# 054.998: метка действия - только если о чём-то попросили. Раньше правило
	# было в каждом ответе, и модель дописывала "[ДЕЙСТВИЕ: подойти]" к ответу
	# на "ты сегодня странный" - перс шёл невпопад (стенд, 19.10).
	# тайна - только в разговоре с игроком. Ставится в самый конец запроса и без
	# случайного тона: "ответь с подколкой/иронией" после "расскажи тайну" - и qwen
	# отшучивалась на каждом шаге (стенд sec2, 20.10)
	var secretPart := secretBlock(skinTag, last) if speakerSkin == "" else ""
	# 054.9992: облик игрока - в самый конец. gemma всё равно говорила Експи-игроку
	# "пойдём посмотрим, что человек там надумал" и звала человека "он" (тест 20.10)
	if speakerSkin == "" and playerSkin != "":
		secretPart = "\nПомни: %s перед тобой - это и есть твой человек, просто в облике персонажа. Других людей рядом нет: не говори о человеке \"он\" или \"человек\" - обращайся к нему на \"ты\"." % PlayerManager.displayNameFor(playerSkin) + secretPart
	if _asksForAction(last):
		prompt += "\nСобеседник просит тебя что-то сделать. Реши по характеру и настроению, согласиться или нет, и скажи это. ТОЛЬКО если соглашаешься, в самом конце допиши одну метку: [ДЕЙСТВИЕ: подойти], [ДЕЙСТВИЕ: лечь], [ДЕЙСТВИЕ: сесть], [ДЕЙСТВИЕ: встать], [ДЕЙСТВИЕ: прыгнуть] или [ДЕЙСТВИЕ: отойти]."
	if secretPart == "":
		prompt += "\nТон ответа на этот раз: " + CHAT_ANGLES[randi() % CHAT_ANGLES.size()]
	prompt += _memoriesRule()
	prompt += _closingBlock(tag, 0)
	var worn := _wornOutPhrases(tag)
	if worn.size() > 0:
		prompt += "\nЭти обороты ты уже {затёрла|затёр} до дыр - не используй их ни в каком виде: \"" + "\", \"".join(worn) + "\"."
	if last != "":
		prompt += "\nОтветь ИМЕННО на последние слова %s: \"%s\". Не копируй начало и концовку своих прошлых ответов и не начинай с повтора его слов." % [speaker, last]
		if own.size() > 0 or chatHistory.size() > 2:
			prompt += " Если спрашивают о том, что ты {говорила|говорил} раньше или о чём шла речь, - найди это выше (в разговоре или в своих словах до него) и ответь именно об этом, конкретно."
	prompt += secretPart
	prompt += "\nТвой ответ:"
	return prompt


## 054.999: ТАЙНЫ ПЕРСОНАЖЕЙ (идея Alex). В паспорте: secret - сама тайна,
## secretHint - что персонаж знает "снаружи" (есть тайна, он уходит от ответа).
## Маленькая модель тайну не удержит, поэтому она её просто НЕ ВИДИТ, пока тайну
## не заслужили: игрок расспрашивает о прошлом, когда у персонажа настроение
## от SECRET_MOOD, несколько раз в разных разговорах (SECRET_STEPS шагов, не
## чаще раза в SECRET_GAP_MS). Удар откатывает шаг (secretSetback).
## Прогресс у КАЖДОГО созданного персонажа свой (две Дюны - два прогресса), лежит
## в SAVE.json -> saw[petId].secret и пропадает вместе с персонажем: удалить и
## создать заново, full_reset - тайну надо заслужить снова (решение Alex 19.10).
const SECRET_ASK_STEMS := ["лаборатор", "прошл", "откуда ты", "тайн", "секрет", "клетк", "тест", "делали с тобой", "с тобой делали", "корпорац", "расскажи о себе", "скрываешь", "что с тобой было"]
const SECRET_MOOD := 60.0
const SECRET_STEPS := 4
const SECRET_GAP_MS := 60000   # 054.9991: шаг - через минуту ИЛИ через SECRET_GAP_MSGS реплик о другом (Alex)
const SECRET_GAP_MSGS := 3
const SECRET_HINT_DEFAULT := "У тебя есть тайна о прошлом. Ты о ней не рассказываешь: уходишь от ответа, отшучиваешься, нервничаешь или меняешь тему."
const SECRET_STAGES := [
	"Сейчас ты резко уходишь от этой темы.",
	"Сейчас ты уходишь от темы, но заметно нервничаешь.",
	"Сейчас ты почти проговариваешься - бросаешь туманный намёк и тут же замолкаешь.",
	"Сейчас ты на грани: начинаешь рассказывать и обрываешь себя на полуслове.",
]
var chatMood := 0.0 # настроение того, кто сейчас отвечает игроку (behavior.replyToPlayer)
var chatPetId := "" # и его petId - прогресс тайны у каждого персонажа свой
var _secretTemp := {} # для petId, которых нет в сейве (стенд) - только в памяти

func _secretState(petId: String) -> Dictionary:
	var keep: Dictionary = gbData.data.get("everPresentAcrossSaves", {})
	keep.erase("secrets") # до 19.10 прогресс был общим на скин - больше не нужен
	var saw: Dictionary = gbData.data.get("saw", {})
	if not saw.has(petId):
		if not _secretTemp.has(petId):
			_secretTemp[petId] = {"progress": 0, "revealed": false, "last": 0}
		return _secretTemp[petId]
	if not saw[petId].has("secret"):
		saw[petId]["secret"] = {"progress": 0, "revealed": false, "last": 0}
	return saw[petId]["secret"]


func _saveSecret(petId: String) -> void:
	if gbData.data.get("saw", {}).has(petId):
		gbData.savetodisk("user://SAVE.json", gbData.data)


## Свои слова-ключи у каждой тайны (паспорт secretAsk): у Милки - Вояджер,
## у Вельвет - сны, у Розы - обиды. Нет поля - общие (прошлое, лаборатория).
## Прямой вопрос о тайне (SECRET_ASK_ANY) засчитывается у всех: у Експи свой
## список заменял общий, "ты что-то скрываешь?" не считалось (стенд sec3, 20.10).
const SECRET_ASK_ANY := ["тайн", "секрет", "скрываешь", "скрывает", "скрыва", "прячешь", "утаива", "правду", "расскажи о себе"]
func _asksAboutSecret(skin: String, text: String) -> bool:
	var low := text.to_lower()
	var stems: Array = SECRET_ASK_ANY + passport(skin).get("secretAsk", SECRET_ASK_STEMS)
	for st in stems:
		if low.contains(st):
			return true
	return false


## Кусок запроса о тайне для ответа игроку (пусто, если о ней не спрашивают).
func secretBlock(skin: String, lastText: String) -> String:
	var p := passport(skin)
	var secret := String(p.get("secret", ""))
	if secret == "":
		return ""
	# флирт выключен - романтическая тайна (Вояджер) раскрывается как сильная привязанность
	if not gbData.settings.get("llmFlirtEnabled", false) and String(p.get("secretSafe", "")) != "":
		secret = String(p["secretSafe"])
	var st := _secretState(chatPetId)
	var asked := _asksAboutSecret(skin, lastText)
	if st.get("revealed", false):
		return "\nТвоя тайна, которую ты уже {рассказала|рассказал} человеку: " + secret + " Ты можешь иногда к ней возвращаться." if asked else ""
	if not asked:
		st["msgs"] = int(st.get("msgs", 0)) + 1 # разговор о другом между расспросами
		return ""
	var hint := String(p.get("secretHint", SECRET_HINT_DEFAULT))
	# 054.9991: время - по часам системы, не с запуска игры (после перезапуска
	# старое "last" из сейва было больше нового счётчика - шаги вставали)
	var now := int(Time.get_unix_time_from_system() * 1000.0)
	var step := int(st.get("progress", 0))
	var gapOk: bool = now - int(st.get("last", 0)) >= SECRET_GAP_MS or int(st.get("msgs", 0)) >= SECRET_GAP_MSGS
	if step < SECRET_STEPS and chatMood >= SECRET_MOOD and gapOk:
		step += 1
		st["progress"] = step
		st["last"] = now
		st["msgs"] = 0
		_saveSecret(chatPetId)
		_logDebugLine(skin + ":secret", "SECRET", "step=%d" % step)
	if step >= SECRET_STEPS:
		# тайна считается рассказанной, только когда в ответе есть её слова
		# (secretCheckReply). Увильнул - на следующий вопрос приказ жёстче:
		# gemma на последнем шаге у Розы ответила "я просто люблю гладить шипы" (тест 20.10)
		var tries := int(st.get("tries", 0))
		st["tries"] = tries + 1
		# без secretHint ("ты её не выдаёшь") - иначе противоречие, и на стенде
		# Вояджер, Роза, Милки и Вельвет на последнем шаге всё равно отнекивались
		if tries == 0:
			return "\nТвоя тайна: " + secret + "\nСейчас ты наконец решаешься рассказать её человеку - прямо, но сбивчиво и со страхом, своими словами. Не уходи от ответа: это тот самый момент."
		return "\nТвоя тайна: " + secret + "\nТы уже {начала|начал} признаваться и {увильнула|увильнул}. Теперь скажи её прямо, с первых слов ответа: о чём она, своими словами. Без шуток и без смены темы."
	return "\n" + hint + "\n" + SECRET_STAGES[clampi(step, 0, SECRET_STAGES.size() - 1)]


## Тайна персонажа с учётом флирта (выключен - вариант без романтики).
func _secretTextFor(skin: String) -> String:
	var p := passport(skin)
	if not gbData.settings.get("llmFlirtEnabled", false) and String(p.get("secretSafe", "")) != "":
		return String(p["secretSafe"])
	return String(p.get("secret", ""))


## Слова тайны для проверки ответа: основы от 5 букв без общих слов.
const _SECRET_STEM_STOP := ["челов", "котор", "никог", "всегд", "тольк", "потом", "очень", "когда", "своих", "этого",
	"здесь", "больш", "сейча", "может", "чтобы", "почем", "сразу", "такие", "такой", "обрат", "иногд", "никто", "никем"]

func _secretStems(secret: String) -> Array:
	var stems: Array = []
	for w in _normWords(secret):
		if w.length() < 5:
			continue
		var stem := w.substr(0, 5)
		if not _SECRET_STEM_STOP.has(stem) and not stems.has(stem):
			stems.append(stem)
	return stems


## Ответ игроку на последнем шаге: есть слова тайны - рассказана (behavior.replyToPlayer).
func secretCheckReply(skin: String, petId: String, text: String) -> void:
	var secret := _secretTextFor(skin)
	if secret == "":
		return
	var st := _secretState(petId)
	if st.get("revealed", false) or int(st.get("progress", 0)) < SECRET_STEPS or int(st.get("tries", 0)) == 0:
		return
	# 054.9992: свои слова-признаки тайны (паспорт secretReveal, подстроки) -
	# по первым 5 буквам "Я помню все обиды" не совпадало с "обидел", а
	# "ничего плохого" ложно совпадало с "ничего не забываешь" (стенд sec4).
	# Нет поля (персонаж игрока) - по основам слов самой тайны.
	var keys: Array = passport(skin).get("secretReveal", [])
	var low := text.to_lower()
	for k in keys:
		if low.contains(String(k)):
			st["revealed"] = true
			_saveSecret(petId)
			_logDebugLine(skin + ":secret", "SECRET", "revealed (признак: %s)" % k)
			return
	var stems := _secretStems(secret) if keys.is_empty() else []
	for w in _normWords(text):
		for stem in stems:
			if w.begins_with(stem):
				st["revealed"] = true
				_saveSecret(petId)
				_logDebugLine(skin + ":secret", "SECRET", "revealed (слово: %s)" % w)
				return
	_logDebugLine(skin + ":secret", "SECRET", "dodged - тайна не прозвучала, на следующий вопрос - жёстче")


## Удар или грубость - доверие падает, шаг к тайне назад.
func secretSetback(skin: String, petId: String) -> void:
	if String(passport(skin).get("secret", "")) == "":
		return
	var st := _secretState(petId)
	if not st.get("revealed", false) and int(st.get("progress", 0)) > 0:
		st["progress"] = int(st["progress"]) - 1
		_saveSecret(petId)


## Собеседник спрашивает о прошлых словах ("что ты сказала", "почему", "помнишь").
const PAST_STEMS := ["сказал", "говорил", "имел в виду", "имела в виду", "почему", "зачем ты", "помнишь", "о чём", "о чем", "что это было", "про экран", "что ты там"]

func _asksAboutPast(text: String) -> bool:
	var low := text.to_lower()
	for st in PAST_STEMS:
		if low.contains(st):
			return true
	return false


## Речь о еде в реплике собеседника (тогда в запрос - вкусы персонажа).
const FOOD_STEMS := ["ед", "еду", "есть", "поесть", "куша", "голод", "корм", "жра", "плот", "бургер", "пицц", "хлеб", "банан", "сок", "фрукт", "вкус", "мяс", "перекус", "обед", "ужин", "завтрак"]

func _aboutFood(text: String) -> bool:
	for w in _normWords(text):
		for st in FOOD_STEMS:
			if w.begins_with(st) and (st.length() > 2 or w.length() <= 4):
				return true
	return false


## Просьба что-то сделать (подойти, лечь, сесть, встать, прыгнуть, отойти).
const ACTION_REQUEST_STEMS := ["подойд", "подходи", "иди сюда", "иди ко мне", "ляг", "ложис", "приляг", "сядь", "садис", "присядь", "встань", "вставай", "прыгн", "прыгай", "подпрыгн", "отойд", "отходи", "уйди"]

func _asksForAction(text: String) -> bool:
	var low := text.to_lower()
	for st in ACTION_REQUEST_STEMS:
		if low.contains(st):
			return true
	return false


## Called from a specific pet's passivetalk() loop. Result delivered ONLY to
## that pet via callback - not broadcast.
const _PROFANITY_ROOTS := ["хуй", "ебат", "ёбан", "ебан", "заеб", "наеб", "выеб", "проеб", "отъеб", "уебан", "уебищ", "ебуч", "ебаш", "пизд", "мудак", "долбоёб", "долбоеб", "гандон", "нахер", "похер"] # 054.997: + формы, которых фильтр не знал ("ебучая", "ебашься")
## Эти корни ищем только В НАЧАЛЕ слова: как простая подстрока они ловили
## обычные слова ("корабля", "рубля", "барсук", "сукно") и молча
## выкидывали нормальные примеры, когда мат выключен.
var _profanityWordStart := RegEx.create_from_string("(?<![а-яёa-z])(бля|сук|хер|хуе|хуё|ебл|ёб)") # хуе/ёб - только с начала слова ("страхуемый", "дёшево" не ловить)

## Strips profane example lines before they ever reach the model - relying
## on a prompt instruction alone isn't enough, since a capable model will
## happily imitate the STYLE of its examples, swearing included, even when
## told not to. When profanity is allowed, this is a no-op.
## Quotes in TRANSLATION.json sometimes start with a display-formatting tag
## like [shake] or [wave] (makes the text shake/float on screen) - that's
## presentation, not something the model should ever see or copy into its
## own output.
func _stripDisplayTags(line: String) -> String:
	var s: String = String(line).strip_edges()
	while s.begins_with("["):
		var closeIdx := s.find("]")
		if closeIdx == -1:
			break
		s = s.substr(closeIdx + 1).strip_edges()
	return s


## Мелкие привычки модели, которые проще поправить, чем выбрасывать фразу:
## английское "Hey" она пишет как "Гей" ("Гей? Дюна тут...").
var _heyRegex := RegEx.create_from_string("^(Гей|Хей)(?=[\\s,!?.—-])")
## 054.999: эмодзи и *описания действий* (*покраснела*, *хвостом махнула*) модель
## в чате иногда пишет вопреки правилам (стенд flirt, Роза) - вырезаем сами.
var _starActionRegex := RegEx.create_from_string("\\*[^*]{1,40}\\*")
var _emojiRegex := RegEx.create_from_string("[\\x{1F000}-\\x{1FAFF}\\x{2600}-\\x{27BF}\\x{FE0F}]")
func _fixOutputQuirks(text: String) -> String:
	text = _starActionRegex.sub(text, "", true)
	text = _emojiRegex.sub(text, "", true)
	text = text.replace("  ", " ").strip_edges()
	return _heyRegex.sub(text, "Эй")


func _containsProfanity(text: String) -> bool:
	var lower: String = text.to_lower()
	for root in _PROFANITY_ROOTS:
		if lower.find(root) != -1:
			return true
	return _profanityWordStart.search(lower) != null


func _filterExamplesForProfanity(lines: Array) -> Array:
	var cleaned: Array = []
	for line in lines:
		cleaned.append(_stripDisplayTags(line))

	if gbData.settings.get("llmAllowProfanity", false):
		return cleaned

	var filtered: Array = []
	for line in cleaned:
		if not _containsProfanity(String(line)):
			filtered.append(line)
	return filtered


## 054.99: о чём фоновая фраза на этот раз. Без темы модель раз за разом
## говорила про экран ("Этот экран - как...", "свет режет глаза").
const STATE_TOPICS := [
	"как ты себя чувствуешь телом прямо сейчас.",
	"еда - чего хочется или что вспоминается.",
	"сон и усталость.",
	"человек за компьютером - что ты о нём думаешь или чего от него хочешь.",
	"что-то из твоего прошлого, о чём говорится в описании тебя.",
	"чем бы тебе сейчас хотелось заняться.",
	"твоё настроение - честно, одной мыслью.",
	"какая-то мелочь вокруг тебя на рабочем столе (не экран целиком).",
	"твой вид и твоя внешность.",
	"скука или, наоборот, что тебе сейчас нравится.",
]
var _lastStateTopic := -1

## woundFocus - если ранен, просьба говорить о самочувствии (behavior решает,
## насколько часто, по здоровью); тогда тема не выбирается.
func requestStateReaction(statLine: String, exampleLines: Array, callback: Callable, tag: String = "state", woundFocus: String = "") -> void:
	if not gbData.settings.get("llmVisionEnabled", true):
		return
	_enqueue(buildStatePrompt(statLine, exampleLines, tag, woundFocus), [], callback, tag)


## 054.998: сборка запросов вынесена в build*Prompt - их же вызывает стенд
## (test-stand), чтобы проверять ровно те запросы, что строит игра.
func buildStatePrompt(statLine: String, exampleLines: Array, tag: String, woundFocus: String = "") -> String:
	exampleLines = _filterExamplesForProfanity(exampleLines)

	var prompt := _buildBasePrompt(tag)
	prompt += "\n\nСейчас: никто к тебе не обращается, ты просто говоришь что-то вслух {сама|сам} по себе."
	prompt += "\nТвоё состояние: " + statLine + "."
	if woundFocus != "":
		prompt += "\n" + woundFocus
	else:
		var idx := randi() % STATE_TOPICS.size()
		if idx == _lastStateTopic:
			idx = (idx + 1) % STATE_TOPICS.size()
		_lastStateTopic = idx
		prompt += "\nО чём сказать на этот раз: " + STATE_TOPICS[idx] + " Про экран, свет и окна - только если тема о них."
		if idx == 1:
			prompt += tastesText(_skinFromTag(tag))
	if exampleLines.size() > 0:
		prompt += "\nТак ты обычно говоришь в таком состоянии (бери стиль и настроение, не копируй):\n- " + "\n- ".join(exampleLines)
	prompt += _closingBlock(tag)
	prompt += "\nТвоя новая фраза:"
	return prompt


## Lightweight variant for INSTANT events (petting, getting picked up,
## rejecting a pet, waking up...) where speed matters more than deep
## personalization - deliberately skips lore and stats, just blends a
## handful of example lines from that moment's usual quote pool. Used by
## behavior.gd's _say() helper. `tag` is just for debugTags (e.g. "pet",
## "getUp", "petReject" - whatever category _say() was called with).
func requestQuickReaction(exampleLines: Array, callback: Callable, tag: String = "quick", styleHint: String = "", situationDescription: String = "") -> void:
	if not gbData.settings.get("llmVisionEnabled", true):
		return
	var prompt := _buildBasePrompt(tag) + _situationBlock(situationDescription)
	if styleHint != "":
		prompt += "\n" + styleHint
	prompt += _examplesBlock(_filterExamplesForProfanity(exampleLines))
	prompt += _closingBlock(tag)
	prompt += "\nТвоя реплика:"
	_enqueue(prompt, [], callback, tag)


## Примеры фраз для вдохновения (пусто, если все отсеял фильтр мата).
func _examplesBlock(lines: Array) -> String:
	if lines.is_empty():
		return ""
	return "\nПохожие фразы для вдохновения (не копируй):\n- " + "\n- ".join(lines)


## INSTANT variant of requestQuickReaction, for reactions that should show
## with zero perceived delay (pet, start/getUp, petReject...). Pulls one
## ready-made line from a small per-category cache and delivers it to
## `callback` immediately (synchronously, this frame). When the cache runs
## low, quietly asks the model for a fresh batch in the background so the
## NEXT call is instant too. First-ever call for a category has nothing
## cached yet, so it falls back to the normal (slower) request just that
## once, while also kicking off the background refill.
func requestPooledReaction(category: String, exampleLines: Array, callback: Callable, styleHint: String = "", situationDescription: String = "") -> void:
	if not gbData.settings.get("llmVisionEnabled", true):
		return

	var pool: Array = _prefetchPools.get(category, [])
	if pool.size() > 0:
		var text: String = pool.pop_front()
		_prefetchPools[category] = pool
		_rememberLine(category, text)
		if debugTags:
			text = "[%s] %s" % [category, text]
		callback.call(text)
		if pool.size() <= _refillThresholdFor(category):
			_refillPool(category, exampleLines, styleHint, situationDescription)
	else:
		requestQuickReaction(exampleLines, callback, category, styleHint, situationDescription)
		_refillPool(category, exampleLines, styleHint, situationDescription)


func _refillPool(category: String, exampleLines: Array, styleHint: String = "", situationDescription: String = "") -> void:
	if _prefetchPending.get(category, false):
		return # a refill is already in flight for this category
	_prefetchPending[category] = true
	_enqueue(buildPoolPrompt(category, exampleLines, styleHint, situationDescription), [], func(rawText): _onPoolRefilled(category, rawText), "prefetch:" + category)


func buildPoolPrompt(category: String, exampleLines: Array, styleHint: String = "", situationDescription: String = "") -> String:
	var target := _prefetchTargetFor(category)
	var prompt := _buildBasePrompt(category) + _situationBlock(situationDescription)
	if styleHint != "":
		prompt += "\n" + styleHint
	prompt += _examplesBlock(_filterExamplesForProfanity(exampleLines))
	prompt += _closingBlock(category, target)
	prompt += "\nТвои %d фраз:" % target
	return prompt


## Same idea as requestPooledReaction, but for moments with no existing quote
## pool to draw style from - just a single situation description (e.g. "held
## for a long time, getting angrier"). Used for the drag-hold escalation,
## which is timing-critical (10-15 sec cadence) and shouldn't ever wait on
## a live request if it can help it.
func requestPooledEvent(poolKey: String, eventDescription: String, callback: Callable, exampleLines: Array = []) -> void:
	if not gbData.settings.get("llmVisionEnabled", true):
		return

	var pool: Array = _prefetchPools.get(poolKey, [])
	if pool.size() > 0:
		var text: String = pool.pop_front()
		_prefetchPools[poolKey] = pool
		_rememberLine(poolKey, text)
		if debugTags:
			text = "[%s] %s" % [poolKey, text]
		callback.call(text)
		if pool.size() <= _refillThresholdFor(poolKey):
			_refillEventPool(poolKey, eventDescription, exampleLines)
	else:
		reactToEvent(eventDescription, callback, poolKey)
		_refillEventPool(poolKey, eventDescription, exampleLines)


func _refillEventPool(poolKey: String, eventDescription: String, exampleLines: Array = []) -> void:
	if _prefetchPending.get(poolKey, false):
		return
	_prefetchPending[poolKey] = true
	_enqueue(buildPoolPrompt(poolKey, exampleLines, "", eventDescription), [], func(rawText): _onPoolRefilled(poolKey, rawText), "prefetch:" + poolKey)


var _prewarmTotal := 0
var _prewarmIsFinalWave := true
var _prewarmStartMsec := 0
var _recentLinesByCategory: Dictionary = {} # category -> Array[String]
var banWords: Array = []
const RECENT_LINES_MAX := 60

## Called whenever a line actually gets shown, so future prompts for THIS
## SAME category know what was already said and can avoid repeating the
## same opener/structure. Kept per-category (not one shared pool) - a
## global "last N said" fed to every category regardless of theme caused
## real cross-contamination (e.g. Full generated right after drag_level2
## produced "...если ты не отпустишь", echoing drag's "держать/отпусти"
## vocabulary purely because it was sitting in the "what you just said"
## context, confirmed by matching timestamps in the debug log).
func _rememberLine(category: String, text: String) -> void:
	var list: Array = _recentLinesByCategory.get(category, [])
	list.append(text)
	if list.size() > RECENT_LINES_MAX:
		list.pop_front()
	_recentLinesByCategory[category] = list


## Plain-text debug log of every line the AI pipeline produces, kept or
## rejected, with a reason. Independent of toggleDebugTags (the in-game
## prefix) - some issues (like truncation) showed up even with that off, so
## this always writes when enabled, giving one file to send instead of
## screenshots. Toggle with `logAiLines` console command.
## Format: <time>\t[<category>]\t<STATUS>\t<text>
func _logDebugLine(category: String, status: String, text: String) -> void:
	if not gbData.settings.get("logAiLines", false):
		return
	var f: FileAccess
	if FileAccess.file_exists("user://ai_debug_log.txt"):
		f = FileAccess.open("user://ai_debug_log.txt", FileAccess.READ_WRITE)
		if f:
			f.seek_end()
	else:
		f = FileAccess.open("user://ai_debug_log.txt", FileAccess.WRITE)
	if f == null:
		return
	var timestamp := Time.get_datetime_string_from_system()
	f.store_line("%s\t[%s]\t%s\t%s" % [timestamp, category, status, text.replace("\t", " ")])
	f.close()
var _prewarmDone := 0
var _lastResponseWasTruncated := false

## Warms up every category's cache at once (instead of lazily, one at a time
## as each moment happens to occur), with visible progress in the console.
## `categoriesToExamples` maps a category name (as used by _say()/grab) to
## its array of example quotes.
## Same idea as behavior.gd's _pickExamples() - biases the example sample
## toward longer, more descriptive lines instead of a pure random slice, so
## a pool's short generic entries ("Ок.", "Хорошо.") don't crowd out the
## thematic ones purely by chance.
func _pickExamples(pool: Array, n: int) -> Array:
	var descriptive: Array = []
	var short: Array = []
	for line in pool:
		if String(line).split(" ", false).size() >= 3:
			descriptive.append(line)
		else:
			short.append(line)
	descriptive.shuffle()
	short.shuffle()
	var picked: Array = descriptive.slice(0, mini(n, descriptive.size()))
	if picked.size() < n:
		picked += short.slice(0, n - picked.size())
	return picked


func prewarmAllCategories(categoriesToExamples: Dictionary, eventPoolsToDescriptions: Dictionary = {}, isFinalWave: bool = true, eventExamples: Dictionary = {}, situationDescriptions: Dictionary = {}) -> void:
	if not gbData.settings.get("llmVisionEnabled", true):
		return
	_prewarmIsFinalWave = isFinalWave

	if _prewarmTotal == 0 and gbData.settings.get("logAiLines", false):
		# Snapshot of the settings active THIS session, written once at the
		# top of a fresh log - so a log file is self-documenting instead of
		# needing "what were your settings when you made this?" every time.
		_logDebugLine("SESSION", "SETTINGS", "model=%s creativity=%.2f repetitionGuard=%.2f profanity=%s flirt=%s" % [
			modelName, creativity, repetitionGuard,
			gbData.settings.get("llmAllowProfanity", false),
			gbData.settings.get("llmFlirtEnabled", false),
		])

	var toWarm: Array = []
	for cat in categoriesToExamples.keys():
		var pool: Array = _prefetchPools.get(cat, [])
		if pool.is_empty() and not _prefetchPending.get(cat, false):
			toWarm.append(cat)

	var eventsToWarm: Array = []
	for key in eventPoolsToDescriptions.keys():
		var pool: Array = _prefetchPools.get(key, [])
		if pool.is_empty() and not _prefetchPending.get(key, false):
			eventsToWarm.append(key)

	if toWarm.is_empty() and eventsToWarm.is_empty():
		return

	if _prewarmTotal == 0:
		_prewarmStartMsec = Time.get_ticks_msec()
	_prewarmTotal += toWarm.size() + eventsToWarm.size()
	Console.print("[color=CYAN]ИИ создаёт %d наборов фраз, первые 1-2 минуты будут тупняки. Сообщение о готовности появится здесь, в консоли.[/color]" % _prewarmTotal)

	for cat in toWarm:
		var examples: Array = _pickExamples(categoriesToExamples[cat].duplicate(), 8)
		_refillPool(cat, examples, "", situationDescriptions.get(cat, ""))

	for key in eventsToWarm:
		var examples: Array = _pickExamples(Array(eventExamples.get(key, [])).duplicate(), 8)
		_refillEventPool(key, eventPoolsToDescriptions[key], examples)


func _onPoolRefilled(category: String, rawText: String) -> void:
	_prefetchPending[category] = false

	var pool: Array = _prefetchPools.get(category, [])
	var startSize := pool.size()
	var lines: PackedStringArray = rawText.split("\n")
	# После служебной строки модель обычно пишет второй заход списка или
	# описание персонажа со стороны ("Ты маленькая и..."), поэтому всё, что
	# идёт ниже неё в этом пакете, тоже выбрасываем.
	var metaSeen := false
	# Повторы внутри одной пачки: одно слово (по основе) - не больше чем в
	# каждой пятой фразе, а слово, которое скин и так затёр, - один раз
	# (в 054.94 в пачке pet у Roza "хвостик" стоял через строку).
	var batchStems := {}
	var maxPerStem := maxi(2, ceili(lines.size() * 0.2))
	var skinWorn := _skinOverusedWords(_skinFromTag(category))
	for i in lines.size():
		var raw: String = lines[i]
		var cleaned: String = lines[i].strip_edges().replace("*", "")
		cleaned = cleaned.lstrip("0123456789.-) ").strip_edges()

		if metaSeen:
			if cleaned != "":
				_logDebugLine(category, "REJECTED:META_TAIL", raw)
			continue

		if cleaned.begins_with("("):
			_logDebugLine(category, "REJECTED:META_PAREN", raw)
			continue # entire line is meta-commentary, not a quote - skip it

		var parenStart := cleaned.find("(")
		if parenStart > 2:
			cleaned = cleaned.substr(0, parenStart).strip_edges()
		if cleaned.length() <= 2:
			if cleaned.length() > 0:
				_logDebugLine(category, "REJECTED:TOO_SHORT", raw)
			continue

		# служебную строку проверяем ДО обрезки по первому предложению:
		# "Нет — эти фразы не подходят... Вот строго по правилам:" иначе
		# теряет хвост с двоеточием
		if _looksLikeMetaCommentary(cleaned):
			_logDebugLine(category, "REJECTED:META_COMMENTARY", raw)
			metaSeen = true
			continue

		cleaned = _fixOutputQuirks(_cutToFirstSentence(cleaned))

		if _looksLikeGarbage(cleaned):
			_logDebugLine(category, "REJECTED:GARBAGE", raw)
			continue

		if _looksLikeMetaCommentary(cleaned):
			_logDebugLine(category, "REJECTED:META_COMMENTARY", raw)
			metaSeen = true
			continue

		# обрывок вроде "Я сидел ровно," - модель не дописала строку
		if cleaned.ends_with(",") or cleaned.ends_with("—") or cleaned.ends_with("-"):
			_logDebugLine(category, "REJECTED:TOO_FRAGMENTARY", raw)
			continue

		if not gbData.settings.get("llmAllowProfanity", false) and _containsProfanity(cleaned):
			_logDebugLine(category, "REJECTED:PROFANITY", raw)
			continue

		if _looksLikeRoleInversion(category, cleaned):
			_logDebugLine(category, "REJECTED:ROLE_INVERSION", raw)
			continue

		if _isFuzzyDuplicateOf(cleaned, pool) or _looksLikeRepeat(category, cleaned):
			_logDebugLine(category, "REJECTED:DUPLICATE", raw)
			continue
		if _containsBanWord(cleaned):
			_logDebugLine(category, "REJECTED:BANWORD", raw)
			continue

		# Only the batch's actual LAST line can plausibly have been cut by
		# num_predict, and only if Ollama confirms the response really was
		# truncated - a missing "." elsewhere (or anywhere, really) is just
		# this model's normal style as often as not (confirmed in the debug
		# log), so nothing else here gets touched based on punctuation alone.
		if i == lines.size() - 1 and _lastResponseWasTruncated:
			var lastEnd := -1
			for stopChar in [".", "!", "?", "…"]:
				lastEnd = maxi(lastEnd, cleaned.rfind(stopChar))
			if lastEnd > 2:
				var trimmed := cleaned.substr(0, lastEnd + 1).strip_edges()
				_logDebugLine(category, "TRIMMED_CUTOFF", raw + "  -->  " + trimmed)
				cleaned = trimmed
			else:
				var lastSpace := cleaned.rfind(" ")
				if lastSpace > 2:
					var trimmed2 := cleaned.substr(0, lastSpace).strip_edges()
					_logDebugLine(category, "TRIMMED_CUTOFF", raw + "  -->  " + trimmed2)
					cleaned = trimmed2
				else:
					_logDebugLine(category, "REJECTED:TOO_FRAGMENTARY", raw)
					continue # too fragmentary to salvage - drop this line entirely

		var lineStems := _contentStems(cleaned, _skinFromTag(category))
		var overused := ""
		for st in lineStems.keys():
			var used := int(batchStems.get(st, 0))
			if used >= maxPerStem or (skinWorn.has(st) and used >= 1):
				overused = lineStems[st]
				break
		if overused != "":
			_logDebugLine(category, "REJECTED:OVERUSED(" + overused + ")", raw)
			continue
		for st in lineStems.keys():
			batchStems[st] = int(batchStems.get(st, 0)) + 1

		_logDebugLine(category, "OK", cleaned)
		pool.append(cleaned)
	_prefetchPools[category] = pool

	# Прогрев категорий идёт параллельно - без этого свежесгенерированные
	# фразы одной категории не видны остальным, пока их реально не покажут
	# на экране, и в первые минуты сессии часто получаются почти одинаковые
	# фразы в разных категориях. Запоминаем их сразу же, как только сгенерированы.
	for i in range(startSize, pool.size()):
		_rememberLine(category, pool[i])

	if _prewarmTotal > 0:
		_prewarmDone += 1
		var elapsed := (Time.get_ticks_msec() - _prewarmStartMsec) / 1000.0
		Console.print("[color=CYAN]Прогрев: %d/%d готово (только что: %s, прошло %.0f сек с начала)[/color]" % [_prewarmDone, _prewarmTotal, category, elapsed])
		if _prewarmDone >= _prewarmTotal:
			if _prewarmIsFinalWave:
				Console.print("[color=GREEN]Все ИИ-реплики созданы, можно взаимодействовать.[/color]")
			else:
				Console.print("[color=GREEN]Все первостепенные ИИ-реплики готовы, можно взаимодействовать (редкие ещё догружаются в фоне).[/color]")
			_prewarmTotal = 0
			_prewarmDone = 0
			prewarmBatchFinished.emit()


const MAX_QUEUED_PER_TAG := 2


## 054.998: персонажа удалили, а его наборы фраз ещё стояли в очереди - и
## видеокарта генерировала их для того, кого уже нет, пока новый персонаж ждал.
## Убираем из очереди всё, что относится к этому скину, и из счётчика прогрева.
func dropSkinJobs(skin: String) -> void:
	var removed := 0
	for j in _backgroundQueue.duplicate():
		var tag: String = j.get("tag", "")
		if tag.begins_with("prefetch:" + skin + ":"):
			_backgroundQueue.erase(j)
			_prefetchPending[tag.trim_prefix("prefetch:")] = false
			removed += 1
	for j in _queue.duplicate():
		if String(j.get("tag", "")).begins_with(skin + ":"):
			_queue.erase(j)
	if removed > 0 and _prewarmTotal > 0:
		_prewarmTotal = maxi(_prewarmDone, _prewarmTotal - removed)
		if _prewarmDone >= _prewarmTotal:
			_prewarmTotal = 0
			_prewarmDone = 0
			prewarmBatchFinished.emit()

func _enqueue(prompt: String, images: Array, callback: Callable, tag: String = "") -> void:
	prompt = _g(_skinFromTag(tag), prompt) # {женский|мужской} -> по роду скина
	var job := {"prompt": prompt, "images": images, "callback": callback, "tag": tag, "t": Time.get_ticks_msec()}
	if tag.begins_with("prefetch:"):
		_backgroundQueue.append(job)
	else:
		# Rapid clicking (e.g. spamming pet 35 times) can queue far more live
		# generations than the pool has lines for - once the pool runs dry,
		# each extra click becomes its own slow cold-start request, and they
		# all play out one by one long after the player stopped clicking,
		# stuttering the game well after the fact. Once a category already
		# has a couple requests waiting, silently drop further ones instead.
		var sameTagCount := 0
		for j in _queue:
			if j.get("tag", "") == tag:
				sameTagCount += 1
		if tag != "" and sameTagCount >= MAX_QUEUED_PER_TAG:
			return
		_queue.append(job)
	_processQueue()


## 054.992: запросы, которые слишком долго ждали очереди, выбрасываем. Когда
## модель тормозила (видеокарту заняли голосовой Discord и стрим), реакции на
## экран и фразы о состоянии копились, а потом приходили все разом - уже
## не к месту. Фоновые наборы фраз не устаревают.
const STALE_MS := {"screen": 45000, "state": 60000, "pettalk": 60000, "item": 30000, "chat": 120000}
const STALE_DEFAULT_MS := 30000 # мгновенные реакции (погладили, подняли)

func _dropStaleJobs() -> void:
	var now := Time.get_ticks_msec()
	var kept: Array = []
	for job in _queue:
		var tag := String(job.get("tag", ""))
		var kind := tag.get_slice(":", tag.get_slice_count(":") - 1)
		var limit: int = STALE_MS.get(kind, STALE_DEFAULT_MS)
		if now - int(job.get("t", now)) > limit:
			_logDebugLine(tag, "DROPPED:STALE", "ждал %d с" % ((now - int(job.get("t", now))) / 1000))
			continue
		kept.append(job)
	_queue = kept


func _processQueue() -> void:
	if busy:
		return
	_dropStaleJobs()
	if _queue.is_empty() and _backgroundQueue.is_empty():
		return
	busy = true
	_watchdogTimer.start()
	TransparentWindow.call("SetAiBusy", true) # 054.993: FPS простоя 30, пока модель думает

	var job: Dictionary
	_sinceBackgroundJob += 1
	# Foreground always wins EXCEPT every Nth job, when background gets a
	# guaranteed turn - otherwise a steady stream of foreground requests
	# (screen/state/petting reactions) can starve prewarm forever on slow
	# hardware, and the "all done" notification never fires.
	if not _backgroundQueue.is_empty() and (_queue.is_empty() or _sinceBackgroundJob >= BACKGROUND_EVERY_N):
		job = _backgroundQueue.pop_front()
		_sinceBackgroundJob = 0
	else:
		job = _queue.pop_front()

	_currentCallback = job["callback"]
	_currentTag = job.get("tag", "")
	_currentJob = job

	# Batch (prefetch pool refill) requests carry PREFETCH_TARGET lines in one
	# response, so they need a much bigger token budget than a single line.
	var predictBudget: int = 220
	if _currentTag.begins_with("prefetch:"):
		# ~20-40 токенов на строку; потолок, чтобы промпт + ответ всегда влезали в NUM_CTX
		predictBudget = mini(80 * _prefetchTargetFor(_currentTag.trim_prefix("prefetch:")), 2400)

	var payload := {
		"model": modelName,
		"keep_alive": "30m",
		"prompt": job["prompt"],
		"stream": false,
		"options": {
			"repeat_penalty": repetitionGuard,
			"temperature": float(job.get("temperature", creativity)), # повтор ответа в чате идёт чуть "смелее"
			"num_predict": predictBudget,
			"num_ctx": numCtx()
		}
	}
	# Ollama's own multimodal models are picky about an empty "images" key -
	# only include it when there's actually an image to send.
	if job["images"].size() > 0:
		payload["images"] = job["images"]

	var headers := ["Content-Type: application/json"]
	var err := http.request(OLLAMA_URL, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		print("LLMManager: failed to start request: ", err)
		busy = false
		TransparentWindow.call("SetAiBusy", false)
		_processQueue()


func _clearPendingIfPrefetch() -> void:
	if _currentTag.begins_with("prefetch:"):
		var category := _currentTag.trim_prefix("prefetch:")
		_prefetchPending[category] = false


## 054.992: три неудачи подряд - подсказка в консоли (раньше игра просто молчала).
var _failStreak := 0
func _noteFailure(code: int) -> void:
	_failStreak += 1
	_logDebugLine(_currentTag, "OLLAMA_FAIL", "код %d, подряд %d" % [code, _failStreak])
	if _failStreak == 3:
		Console.print("[color=ORANGE]Ollama не успевает отвечать (3 раза подряд). Скорее всего, видеокарта перегружена: голосовой Discord, стрим, игра. В Discord помогает выключить аппаратное ускорение (Настройки - Расширенные).[/color]")


func _on_request_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_watchdogTimer.stop()
	busy = false
	TransparentWindow.call("SetAiBusy", false)
	var cb := _currentCallback

	if response_code != 200:
		print("LLMManager: Ollama returned code ", response_code, " - is `ollama serve` running with the model pulled?")
		_noteFailure(response_code)
		_clearPendingIfPrefetch()
		_processQueue()
		return

	_failStreak = 0
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary):
		print("LLMManager: JSON parse failed")
		_clearPendingIfPrefetch()
		_processQueue()
		return

	# Ollama tells us WHY generation stopped - "length" means num_predict cut
	# it off mid-thought for real; "stop" means the model finished on its
	# own, whatever punctuation (or lack of it) it ended on. Missing a "."
	# is this model's normal style as often as not (confirmed in the debug
	# log), so only touch endings when we KNOW it was actually truncated,
	# rather than guessing from punctuation alone.
	_lastResponseWasTruncated = String(parsed.get("done_reason", "stop")) == "length"
	# Сколько токенов занял промпт: если он упрётся в NUM_CTX, Ollama молча
	# отрежет НАЧАЛО (правила и лор) - в логе это видно как CONTEXT_FULL.
	var promptTokens: int = int(parsed.get("prompt_eval_count", 0))
	var tps := _noteSpeed(parsed)
	_logDebugLine(_currentTag, "TOKENS", "prompt=%d answer=%d of %d  speed=%.1f tok/s%s" % [promptTokens, int(parsed.get("eval_count", 0)), numCtx(), tps, "  CONTEXT_FULL" if promptTokens >= numCtx() - 300 else ""])

	var text: String = ""
	if parsed.has("response") and String(parsed["response"]).strip_edges() != "":
		text = String(parsed["response"]).strip_edges()
	elif parsed.has("thinking") and String(parsed["thinking"]).strip_edges() != "":
		# Fallback for reasoning models that only filled "thinking" - grab the
		# last non-trivial line as a best-effort guess at the actual reply.
		var lines = String(parsed["thinking"]).strip_edges().split("\n")
		for i in range(lines.size() - 1, -1, -1):
			var line = lines[i].strip_edges()
			if line.length() > 5:
				text = line
				break

	text = text.trim_prefix("\"").trim_suffix("\"").strip_edges()

	var isPrefetchBatch: bool = _currentTag.begins_with("prefetch:")

	# Чат: метку действия "[ДЕЙСТВИЕ: подойти]" вырезаем ДО всех чисток
	# (обрезка по предложениям её бы потеряла) и передаём персонажу в начале
	# текста как "<act:come>" - behavior.replyToPlayer выполнит действие.
	var chatAction := ""
	if _currentTag.ends_with(":chat"):
		var m := _actionRegex.search(text)
		if m:
			chatAction = CHAT_ACTIONS.get(m.get_string(1).strip_edges().to_lower(), "")
			text = _actionRegex.sub(text, "", true).strip_edges()

	if not isPrefetchBatch:
		var rawReply := text
		text = text.replace("*", "").strip_edges()
		var rejectReason := ""

		# The model's ENTIRE reply is sometimes meta-commentary instead of a
		# line of dialogue (e.g. "(Note: the request asked for...)") - if it
		# starts with a paren, there's no real content to salvage from it.
		if text.begins_with("("):
			rejectReason = "META_PAREN"
			text = ""
		else:
			# A trailing self-explanation ("...(Это фраза в нужном тоне)")
			# still has real content before the paren - keep just that part.
			var parenStart := text.find("(")
			if parenStart > 2:
				text = text.substr(0, parenStart).strip_edges()

		# Keep only the FIRST sentence - some models tack on a second,
		# roleplay-style "action" sentence even when told not to
		# ("надевает шляпу...", "вздрагиваю и..."). Cutting after the first
		# terminator removes that second sentence outright, whatever it says.
		if text != "":
			var full := text
			text = _cutToFirstSentence(full)
			# в разговоре с игроком разрешаем и второе предложение - живее
			if _currentTag.ends_with(":chat"):
				var rest := full.substr(text.length()).strip_edges()
				if rest != "":
					text = text + " " + _cutToFirstSentence(rest)

		# Only touch the ending if Ollama confirms num_predict actually cut
		# generation short - a missing "." otherwise is a deliberate style
		# choice as often as not (confirmed in the debug log: dropping the
		# last word whenever there was no "." mangled correct, complete
		# sentences far more often than it ever repaired a real cutoff).
		if text != "" and _lastResponseWasTruncated:
			var lastEnd := -1
			for stopChar in [".", "!", "?", "…"]:
				lastEnd = maxi(lastEnd, text.rfind(stopChar))
			if lastEnd > 0:
				var trimmed := text.substr(0, lastEnd + 1).strip_edges()
				_logDebugLine(_currentTag, "TRIMMED_CUTOFF", rawReply + "  -->  " + trimmed)
				text = trimmed
			else:
				# no punctuation anywhere to anchor on - at minimum, drop the
				# trailing partial word so we never show a broken half-word.
				var lastSpace := text.rfind(" ")
				if lastSpace > 2:
					var trimmed2 := text.substr(0, lastSpace).strip_edges()
					_logDebugLine(_currentTag, "TRIMMED_CUTOFF", rawReply + "  -->  " + trimmed2)
					text = trimmed2

		# Last line of defense: if this is supposed to be Russian but came
		# out mostly Latin letters, the model went off the rails entirely
		# (e.g. started explaining itself in English) - discard rather than
		# show garbage.
		if text != "" and _looksLikeGarbage(text):
			rejectReason = "GARBAGE"
			text = ""

		if text != "" and _looksLikeRoleInversion(_currentTag, text):
			rejectReason = "ROLE_INVERSION"
			text = ""

		# В разговоре с игроком повтор лучше молчания - не отбрасываем насовсем,
		# но один раз переспрашиваем модель: 8B залипает на шаблоне своих же
		# прошлых ответов из истории ("X - значит, ты снова в деле?" раз за разом).
		if text != "" and _currentTag.ends_with(":chat") and int(_currentJob.get("retry", 0)) == 0 and _chatLooksStuck(_currentTag, text):
			_logDebugLine(_currentTag, "RETRY:SAME_PATTERN", text)
			var again: Dictionary = _currentJob.duplicate()
			again["retry"] = 1
			again["temperature"] = minf(1.2, creativity + 0.25)
			again["prompt"] = String(again["prompt"]).trim_suffix("\nТвой ответ (только сама реплика):") + _g(_skinFromTag(_currentTag), "\nВНИМАНИЕ: ты уже {отвечала|отвечал} так: \"") + text + "\". Скажи СОВСЕМ по-другому - другими словами, с другим началом и другой концовкой.\nТвой ответ (только сама реплика):"
			_queue.push_front(again)
			_processQueue()
			return
		# переспрос тоже вернул затёртый оборот - отрезаем ту часть фразы, где он
		if text != "" and _currentTag.ends_with(":chat") and int(_currentJob.get("retry", 0)) > 0:
			var stripped := _stripWornClause(_currentTag, text)
			stripped = _stripRepeatedTail(_currentTag, stripped)
			if stripped != text:
				_logDebugLine(_currentTag, "STRIPPED_WORN", text + "  -->  " + stripped)
				text = stripped
		# Фразы о состоянии и реакции на экран: раньше повтор просто
		# выбрасывался, а модель раз за разом выдавала то же самое ("Мне немного
		# грустно, но я всё ещё здесь...") - и перс молчал. Теперь один переспрос.
		var isStateLike: bool = _currentTag.ends_with(":state") or _currentTag.ends_with(":screen")
		if text != "" and isStateLike and int(_currentJob.get("retry", 0)) == 0 and _looksLikeRepeat(_currentTag, text):
			_logDebugLine(_currentTag, "RETRY:REPEAT", text)
			var again2: Dictionary = _currentJob.duplicate()
			again2["retry"] = 1
			again2["temperature"] = minf(1.2, creativity + 0.25)
			again2["prompt"] = String(again2["prompt"]) + _g(_skinFromTag(_currentTag), "\nВНИМАНИЕ: ты {хотела|хотел} сказать \"") + text + "\" - но почти это же ты уже {говорила|говорил}. Скажи о СОВСЕМ другом: другая мысль, другие слова, другое начало и другая концовка."
			_queue.push_front(again2)
			_processQueue()
			return
		if text != "" and not _currentTag.ends_with(":chat") and _looksLikeRepeat(_currentTag, text):
			rejectReason = "REPEAT"
			text = ""

		if text != "" and _containsBanWord(text):
			rejectReason = "BANWORD"
			text = ""

		# раньше мат отсекался только в примерах, а не в ответе модели
		# (у Velvet в чате проскочило "Бля...")
		if text != "" and not gbData.settings.get("llmAllowProfanity", false) and _containsProfanity(text):
			rejectReason = "PROFANITY"
			text = ""

		if text != "":
			text = _fixOutputQuirks(text)

		_logDebugLine(_currentTag, "OK" if text != "" else "REJECTED:" + rejectReason, text if text != "" else rawReply)

		if debugTags and _currentTag != "":
			text = "[%s] %s" % [_currentTag, text]

	if text != "" and not isPrefetchBatch:
		_rememberLine(_currentTag, text.trim_prefix("[" + _currentTag + "] ") if debugTags and _currentTag != "" else text)

	if text != "" and chatAction != "":
		text = "<act:%s>%s" % [chatAction, text]

	if text != "" and cb.is_valid():
		cb.call(text)

	_processQueue()


## Fires only if a request never completed at all within 75 sec - normal
## requests (even slow batches) finish and stop this timer well before then.
## Recovers from the exact failure mode seen in the wild: Ollama cancelling
## a request server-side without Godot's HTTPRequest firing completion,
## which left `busy` stuck and silenced the whole queue for 5+ minutes.
func _onWatchdogTimeout() -> void:
	print("LLMManager: watchdog - a request seems stuck, resetting the queue")
	_noteFailure(-1)
	busy = false
	TransparentWindow.call("SetAiBusy", false)
	_clearPendingIfPrefetch()
	_processQueue()


## Console command: toggleDebugTags - prefixes every AI line with its source
## ([screen], [state], [pet], [getUp], [petReject], [drag], etc.) so you can
## tell at a glance which trigger produced a given reaction.
func setDebugTags(enabled: bool) -> void:
	debugTags = enabled


## Console command: toggleAiLog. Writes every generated line (kept or
## rejected, with the reason) to user://ai_debug_log.txt - independent of
## toggleDebugTags, since some issues show up even without the in-game
## prefix. Send that file over instead of screenshots for batch debugging.
func setLogAiLines(enabled: bool) -> void:
	gbData.settings["logAiLines"] = enabled
	gbData.savetodisk("user://CONFIG.json", gbData.settings)


## Console command: visionToggle
func setEnabled(enabled: bool) -> void:
	gbData.settings["llmVisionEnabled"] = enabled
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	if enabled:
		_scheduleScreenTick()
	aiEnabledChanged.emit(enabled)


## Console command: toggleProfanity
func setProfanityAllowed(enabled: bool) -> void:
	gbData.settings["llmAllowProfanity"] = enabled
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	if not enabled:
		_purgeProfaneLines() # drop only the stale lines that actually swear
	print("LLMManager: profanity ", "allowed" if enabled else "forbidden")


## Console command: toggleFlirt
func setFlirtEnabled(enabled: bool) -> void:
	gbData.settings["llmFlirtEnabled"] = enabled
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	print("LLMManager: flirt ", "enabled" if enabled else "disabled")


## Интервал реакций на экран (сек). Консольной команды больше нет - поля в Settings.
func setInterval(minSeconds: float, maxSeconds: float) -> void:
	minScreenInterval = max(1.0, minSeconds)
	maxScreenInterval = max(minScreenInterval, maxSeconds)
	gbData.settings["llmMinInterval"] = str(minScreenInterval)
	gbData.settings["llmMaxInterval"] = str(maxScreenInterval)
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	print("LLMManager: screen-reaction interval set to ", minScreenInterval, "-", maxScreenInterval, " seconds")


## Console command: aiCreativity <0.0-1.5>
## Готовые пулы фраз при смене НЕ сбрасываются (чтобы не ждать прогрев
## заново) - новое значение применяется к пулам по мере их дозаполнения,
## а к экранным реакциям - сразу, со следующего скриншота.
func setCreativity(value: float) -> void:
	creativity = clampf(value, 0.0, 1.5)
	gbData.settings["llmCreativity"] = creativity
	gbData.savetodisk("user://CONFIG.json", gbData.settings)


## Console command: aiRepetitionGuard <1.0-2.0>
func setRepetitionGuard(value: float) -> void:
	repetitionGuard = clampf(value, 1.0, 2.0)
	gbData.settings["llmRepetitionGuard"] = repetitionGuard
	gbData.savetodisk("user://CONFIG.json", gbData.settings)


## Console command: aiModel <name>
## Console command: aiStatus calls this automatically. Lists models already
## pulled locally via Ollama's own /api/tags - separate small HTTPRequest so
## it doesn't interfere with the main dialogue queue. Prints asynchronously,
## so this line can land slightly after the rest of aiStatus's output.
## 054.996: подходит ли модель игре. Обязательно (проверено пользователем
## многократно): зрение (vision - реакции на экран) и без режима размышлений
## (thinking - модель "думает вслух", ответы медленные и ломают фразы).
## callback(problem: String) - пустая строка, если подходит; иначе - почему нет.
func checkModel(name: String, callback: Callable) -> void:
	var http := HTTPRequest.new()
	Engine.get_main_loop().root.add_child(http)
	http.timeout = 15.0
	http.request_completed.connect(func(_result, response_code, _headers, body):
		http.queue_free()
		if response_code != 200:
			callback.call("Ollama не знает такую модель (код %d)" % response_code)
			return
		var parsed = JSON.parse_string(body.get_string_from_utf8())
		var caps: Array = parsed.get("capabilities", []) if parsed is Dictionary else []
		var problems: Array = []
		if not caps.has("vision"):
			problems.append("не умеет видеть картинки (нет vision)")
		if caps.has("thinking"):
			problems.append("с режимом размышлений (thinking)")
		callback.call(", ".join(problems))
	)
	if http.request("http://127.0.0.1:11434/api/show", ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify({"model": name})) != OK:
		http.queue_free()
		callback.call("не удалось спросить Ollama")


## 054.995: список скачанных моделей для меню ai_model.
## callback(names: Array, ok: bool) - ok=false, если Ollama не ответила.
## Размеры (байты) - в modelSizes после ответа.
var modelSizes: Dictionary = {}

func fetchModels(callback: Callable) -> void:
	var http := HTTPRequest.new()
	Engine.get_main_loop().root.add_child(http)
	http.timeout = 10.0
	http.request_completed.connect(func(_result, response_code, _headers, body):
		var names: Array = []
		var ok := false
		if response_code == 200:
			var parsed = JSON.parse_string(body.get_string_from_utf8())
			if parsed is Dictionary and parsed.has("models"):
				ok = true
				modelSizes.clear()
				for m in parsed["models"]:
					names.append(String(m.get("name", "?")))
					modelSizes[names[-1]] = float(m.get("size", 0))
		http.queue_free()
		callback.call(names, ok)
	)
	if http.request("http://127.0.0.1:11434/api/tags") != OK:
		http.queue_free()
		callback.call([], false)


## 054.999: скорость генерации. Во время стрима в Discord пакет фраз шёл 100 сек
## вместо 10 (отчёт Alex 20.10). Две разные причины: модель не влезла в
## видеопамять (часть ушла в обычную - в 5-10 раз медленнее) или влезла, но
## видеокарту делит кодировщик стрима. Два медленных ответа подряд - спрашиваем
## Ollama (/api/ps: size и size_vram) и пишем в консоль, что именно и что делать.
const SLOW_TPS := 8.0                # qwen 8b на 8 ГБ даёт ~30 ток/с
const SLOW_WARN_GAP_MS := 1800000    # не чаще раза в 30 минут
var _slowStreak := 0
var _lastSlowWarnMs := -SLOW_WARN_GAP_MS

func _noteSpeed(parsed: Dictionary) -> float:
	var count := int(parsed.get("eval_count", 0))
	var dur := float(parsed.get("eval_duration", 0)) / 1e9
	if count < 10 or dur <= 0.0:
		return 0.0 # короткий ответ - скорость по нему не понять
	var tps := count / dur
	_slowStreak = _slowStreak + 1 if tps < SLOW_TPS else 0
	var now := Time.get_ticks_msec()
	if _slowStreak >= 2 and now - _lastSlowWarnMs >= SLOW_WARN_GAP_MS:
		_lastSlowWarnMs = now
		_explainSlow(tps)
	return tps


func _explainSlow(tps: float) -> void:
	var http := HTTPRequest.new()
	Engine.get_main_loop().root.add_child(http)
	http.request_completed.connect(func(_result, response_code, _headers, body):
		http.queue_free()
		var share := -1.0
		if response_code == 200:
			var parsed = JSON.parse_string(body.get_string_from_utf8())
			if parsed is Dictionary:
				for m in parsed.get("models", []):
					if String(m.get("name", "")) == modelName and float(m.get("size", 0)) > 0.0:
						share = float(m.get("size_vram", 0)) / float(m["size"])
		var msg := ""
		if share >= 0.0 and share < 0.97:
			msg = "ИИ отвечает медленно (%.0f ток/с): модель не влезла в видеопамять - на видеокарте только %d%%, остальное в обычной памяти. Видеопамять заняли другие программы: стрим или звонок в Discord, браузер, видеоплеер, игры. В Discord выключи аппаратное ускорение (Настройки - Расширенные), закрой лишнее и перезапусти DeskSaw - модель загрузится заново. Или выбери модель поменьше в model_manager (qwen3-vl:8b-instruct влезает в 8 ГБ)." % [tps, int(share * 100)]
		elif share >= 0.97:
			# Ollama видит 100%, но на Windows драйвер NVIDIA при нехватке видеопамяти тихо
			# переносит часть в общую память - и тогда тоже в разы медленнее (20.10)
			msg = "ИИ отвечает медленно (%.0f ток/с). Ollama считает, что модель целиком в видеопамяти, но, скорее всего, видеопамяти впритык и драйвер тихо перенёс часть в обычную память. Проверь: Диспетчер задач - Производительность - GPU - \"Общая память графического процессора\": если там больше 0,3 ГБ, видеопамяти не хватает. Помогает закрыть или свернуть то, что держит видеокарту (браузер, плеер, второй стрим), выключить в Discord аппаратное ускорение и перезапустить DeskSaw. Или выбери модель поменьше в model_manager." % tps
		else:
			msg = "ИИ отвечает медленно (%.0f ток/с). Если идёт стрим или звонок в Discord - выключи в нём аппаратное ускорение (Настройки - Расширенные) и закрой лишние программы на видеокарте." % tps
		_logDebugLine("system", "SLOW", "%.1f tok/s, vram share %s" % [tps, ("%.0f%%" % (share * 100)) if share >= 0.0 else "?"])
		Console.print("[color=YELLOW]" + msg + "[/color]")
	)
	if http.request("http://127.0.0.1:11434/api/ps") != OK:
		http.queue_free()


## 054.9991: ИИ-описание своего предмета (вкладка Предметы). Без лора, самая
## большая установленная модель со зрением (решение Alex - точнее; у него 14b).
## Если она не основная - Ollama на время подгрузит её вместо основной.
const ITEM_DESCRIBE_PROMPT := "Это картинка предмета для игры. Назови предмет и коротко опиши то, что на картинке точно видно: одна фраза до 10 слов, только русскими словами, без вступлений, без кавычек и без точки в конце."
## 054.9992: для картинок, положенных в папку руками, - ещё и название (было имя файла)
const ITEM_NAME_PROMPT := "Это картинка предмета для игры. Ответь ровно двумя строками, только русскими словами, без кавычек:\nНазвание: 1-3 слова\nОписание: что на картинке точно видно, до 10 слов"
var _describeModel := ""

func _ollamaJson(path: String, body = null):
	var http := HTTPRequest.new()
	http.timeout = 240.0
	add_child(http)
	var err := http.request("http://127.0.0.1:11434" + path, ["Content-Type: application/json"],
		HTTPClient.METHOD_POST if body != null else HTTPClient.METHOD_GET, JSON.stringify(body) if body != null else "")
	if err != OK:
		http.queue_free()
		return null
	var res: Array = await http.request_completed
	http.queue_free()
	if int(res[1]) != 200:
		return null
	return JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())


func _largestVisionModel() -> String:
	if _describeModel != "":
		return _describeModel
	var tags = await _ollamaJson("/api/tags")
	if not (tags is Dictionary):
		return ""
	var models: Array = tags.get("models", [])
	models.sort_custom(func(a, b): return float(a.get("size", 0)) > float(b.get("size", 0)))
	for m in models:
		var name := String(m.get("name", ""))
		var info = await _ollamaJson("/api/show", {"model": name})
		if info is Dictionary and (info.get("capabilities", []) as Array).has("vision"):
			_describeModel = name
			return name
	return ""


func describeItemImage(path: String, withName: bool, cb: Callable) -> void:
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	if img == null or img.is_empty():
		cb.call("", "")
		return
	var side := maxi(img.get_width(), img.get_height())
	if side > 512:
		var q := 512.0 / side
		img.resize(maxi(1, int(img.get_width() * q)), maxi(1, int(img.get_height() * q)), Image.INTERPOLATE_BILINEAR)
	elif side < 192:
		# иконка 30x30 для модели - пара пикселей; увеличиваем без сглаживания
		var k := int(ceil(256.0 / side))
		img.resize(img.get_width() * k, img.get_height() * k, Image.INTERPOLATE_NEAREST)
	var model := await _largestVisionModel()
	if model == "":
		_logDebugLine("items", "DESCRIBE", "нет установленной модели со зрением")
		cb.call("", "")
		return
	var payload := {"model": model, "prompt": ITEM_NAME_PROMPT if withName else ITEM_DESCRIBE_PROMPT, "images": [Marshalls.raw_to_base64(img.save_png_to_buffer())],
		"stream": false, "keep_alive": "1m", "options": {"temperature": 0.2, "num_predict": 40, "num_ctx": 4096}}
	var parsed = await _ollamaJson("/api/generate", payload)
	var desc := ""
	var name := ""
	if parsed is Dictionary:
		var raw := String(parsed.get("response", ""))
		if withName:
			for line in raw.split("\n", false):
				var l := line.strip_edges()
				if l.to_lower().begins_with("название"):
					name = _cleanItemDescription(l.get_slice(":", 1)) if l.contains(":") else ""
				elif l.to_lower().begins_with("описание"):
					desc = _cleanItemDescription(l.get_slice(":", 1)) if l.contains(":") else ""
			name = name.get_slice("/", 0).get_slice("(", 0).strip_edges() # "Гном/Предмет игры" -> "Гном"
			if name.split(" ", false).size() > 4:
				name = " ".join(name.split(" ", false).slice(0, 4))
			if name != "":
				name = name.substr(0, 1).to_upper() + name.substr(1)
		else:
			desc = _cleanItemDescription(raw)
	_logDebugLine("items", "DESCRIBE", "%s -> %s / %s (%s)" % [path.get_file(), name if name != "" else "-", desc if desc != "" else "(пусто)", model])
	cb.call(desc, name)


func _cleanItemDescription(text: String) -> String:
	var t := _fixOutputQuirks(text.strip_edges()).get_slice("\n", 0).strip_edges()
	for q in ["\"", "«", "»", "*"]:
		t = t.replace(q, "")
	t = t.strip_edges().trim_suffix(".").strip_edges()
	var words := t.split(" ", false)
	if words.size() > 12:
		t = " ".join(words.slice(0, 12))
	return t


func listAvailableModels() -> void:
	var http := HTTPRequest.new()
	Engine.get_main_loop().root.add_child(http)
	http.request_completed.connect(func(_result, response_code, _headers, body):
		if response_code == 200:
			var parsed = JSON.parse_string(body.get_string_from_utf8())
			if parsed is Dictionary and parsed.has("models"):
				var names: Array = []
				for m in parsed["models"]:
					names.append(String(m.get("name", "?")))
				if names.is_empty():
					Console.print("Доступные модели: [color=CYAN](ни одна ещё не скачана)[/color]")
				else:
					Console.print("Доступные модели: [color=CYAN]%s[/color]" % ", ".join(names))
			else:
				Console.print("Не удалось разобрать список моделей от Ollama.")
		else:
			Console.print("Не удалось получить список моделей от Ollama (код ответа %d)." % response_code)
		http.queue_free()
	)
	var err := http.request("http://127.0.0.1:11434/api/tags")
	if err != OK:
		Console.print("Не получилось запросить список моделей у Ollama.")
		http.queue_free()


## Подобранные вручную настройки под конкретные модели: [креативность,
## защита от повторов]. При переключении модели (aiModel) применяются сами.
## Для модели не из списка текущие значения не трогаем.
const MODEL_PRESETS := {
	"qwen3-vl:8b-instruct": [0.7, 1.2], # 0.8 давал много странных метафор (лог 2026-10-14)
	"gemma3:12b": [0.8, 1.1], # 054.999: стенд talk 6 вариантов - 1.0 грубит ("псина"), 0.6 суше; 0.8/1.1 живее и связнее
	"ministral-3:14b": [0.5, 1.1], # 054.99: было 0.6 - тест: 0.6 путала род, 0.45-0.5 точнее отвечает на вопрос
}

func setModel(name: String, pull: bool = true) -> void:
	name = name.strip_edges() # в конфиге уже находили "ministral-3:14b\n"
	modelName = name
	gbData.settings["llmModelName"] = modelName
	if MODEL_PRESETS.has(name):
		creativity = MODEL_PRESETS[name][0]
		repetitionGuard = MODEL_PRESETS[name][1]
		gbData.settings["llmCreativity"] = creativity
		gbData.settings["llmRepetitionGuard"] = repetitionGuard
		Console.print("Настройки под модель: креативность [color=CYAN]%s[/color], защита от повторов [color=CYAN]%s[/color]" % [creativity, repetitionGuard])
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	# 054.9991: смена модели видна в ИИ-логе (в отчёте 054.999 её угадывали по окну 8192)
	_logDebugLine("SESSION", "MODEL", "model=%s creativity=%.2f repetitionGuard=%.2f" % [modelName, creativity, repetitionGuard])
	# Раньше тут был _clearPrefetchPools() - специально убрал: часть тестеров
	# и разработчик хотят прогреть пулы на одной модели, потом переключиться
	# на другую (например для более живых screen-реакций) и НЕ терять уже
	# прогретое - остальные пулы просто будут тихо дозаполняться новой
	# моделью по мере естественного расхода, без принудительного сброса.
	if pull:
		pullModel(name)


## Скачивание модели через Ollama (/api/pull, без ollama.exe в PATH).
## 054.998: потоком - Ollama шлёт строку за строкой, сколько скачано, и в
## консоли одна строка-полоска обновляется на месте:
## "Установка модели 31% [====          ] 1,9 из 6,1 ГБ". Раньше было молча
## до самого конца.
const PULL_BAR_WIDTH := 20

func pullModel(name: String, onDone: Callable = Callable()) -> void:
	Console.print("Скачиваю модель [color=CYAN]%s[/color] через Ollama..." % name)
	var client := HTTPClient.new()
	var ok := false
	var errText := ""
	if client.connect_to_host("127.0.0.1", 11434) == OK:
		while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
			client.poll()
			await get_tree().process_frame
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		errText = "Ollama не отвечает - проверь, что она запущена (значок в трее)"
	elif client.request(HTTPClient.METHOD_POST, "/api/pull", ["Content-Type: application/json"], JSON.stringify({"model": name, "stream": true})) != OK:
		errText = "не удалось отправить запрос"
	else:
		while client.get_status() == HTTPClient.STATUS_REQUESTING:
			client.poll()
			await get_tree().process_frame
		var buffer := ""
		var totals := {}
		var completed := {}
		var lastDraw := 0
		var lastBar := ""
		while client.get_status() == HTTPClient.STATUS_BODY:
			client.poll()
			var chunk := client.read_response_body_chunk()
			if chunk.is_empty():
				await get_tree().process_frame
				continue
			buffer += chunk.get_string_from_utf8()
			while buffer.contains("\n"):
				var line := buffer.get_slice("\n", 0)
				buffer = buffer.substr(line.length() + 1)
				var msg = JSON.parse_string(line)
				if not (msg is Dictionary):
					continue
				if msg.has("error"):
					errText = String(msg["error"])
				elif String(msg.get("status", "")) == "success":
					ok = true
				elif msg.has("digest") and msg.has("total"):
					totals[msg["digest"]] = float(msg["total"])
					completed[msg["digest"]] = float(msg.get("completed", 0))
					var bar := _pullBar(_sumValues(completed), _sumValues(totals))
					if Time.get_ticks_msec() - lastDraw > 300 and bar != lastBar:
						lastDraw = Time.get_ticks_msec()
						lastBar = bar
						Console.print_progress(bar)
		if ok and not totals.is_empty():
			Console.print_progress(_pullBar(_sumValues(totals), _sumValues(totals)))
	client.close()
	if ok:
		Console.print("Модель [color=CYAN]%s[/color] скачана." % name)
	else:
		Console.print("[color=RED]Не получилось скачать модель %s: %s.[/color]" % [name, errText if errText != "" else "Ollama оборвала загрузку"])
	if onDone.is_valid():
		onDone.call(ok)


func _sumValues(d: Dictionary) -> float:
	var total := 0.0
	for v in d.values():
		total += float(v)
	return total


func _pullBar(done: float, total: float) -> String:
	var frac := clampf(done / total, 0.0, 1.0) if total > 0.0 else 0.0
	var filled := int(round(frac * PULL_BAR_WIDTH))
	return "Установка модели %d%% [%s%s] %s из %s" % [int(frac * 100.0), "=".repeat(filled), " ".repeat(PULL_BAR_WIDTH - filled), gbText(done), gbText(total)]


## 6140415975 -> "6,1 ГБ", 91000000 -> "91 МБ"
static func gbText(bytes: float) -> String:
	if bytes < 1e9:
		return "%d МБ" % int(round(bytes / 1e6))
	return ("%.1f ГБ" % (bytes / 1e9)).replace(".", ",")


## 054.998: можно ли проверить модель ДО скачивания - по "паспорту" в реестре
## Ollama (несколько КБ). Возвращает {"problem": текст или "", "sure": bool}.
## sure=false - проверить заранее не вышло (модель не из библиотеки Ollama,
## нет связи с реестром, незнакомое семейство) - тогда проверка после скачивания.
## Зрение: отдельный блок зрения (projector), "clip" в семействах или семейство
## со встроенным зрением. Размышления: renderer/parser "...thinking" или шаблон
## с Think (так помечены qwen3:8b и даже qwen3-vl:8b без -instruct).
const VISION_FAMILIES := ["qwen3vl", "qwen25vl", "qwen2vl", "mistral3", "gemma3", "mllama", "llava", "llama4", "minicpmv"]
const TEXT_FAMILIES := ["llama", "qwen2", "qwen3", "qwen3moe", "gemma2", "gemma", "phi3", "phi4", "mistral", "deepseek2", "gptoss", "granite", "command-r", "starcoder2", "nomic-bert", "bert"]
const REGISTRY := "https://registry.ollama.ai/v2/"

func checkRegistry(name: String) -> Dictionary:
	var unsure := {"problem": "", "sure": false}
	var path := name.strip_edges()
	var tag := "latest"
	if path.contains(":"):
		tag = path.get_slice(":", 1)
		path = path.get_slice(":", 0)
	if path.contains("/"):
		if path.get_slice("/", 0).contains("."):
			return unsure # hf.co/... и другие сайты - заранее не проверить
	else:
		path = "library/" + path
	var manifest = await _registryJson(REGISTRY + path + "/manifests/" + tag, ["Accept: application/vnd.docker.distribution.manifest.v2+json"])
	if manifest is int:
		if manifest == 404:
			return {"problem": "такой модели нет в библиотеке Ollama - проверь имя", "sure": true}
		return unsure
	var configDigest := ""
	var templateDigest := ""
	var hasProjector := false
	if manifest.get("config") is Dictionary:
		configDigest = String(manifest["config"].get("digest", ""))
	for layer in manifest.get("layers", []):
		var media := String(layer.get("mediaType", ""))
		if media.ends_with(".projector"):
			hasProjector = true
		elif media.ends_with(".template"):
			templateDigest = String(layer.get("digest", ""))
	var config = {}
	if configDigest != "":
		config = await _registryJson(REGISTRY + path + "/blobs/" + configDigest)
	if config is int:
		return unsure
	var families: Array = config.get("model_families", [config.get("model_family", "")])
	var family := String(config.get("model_family", ""))
	var thinking := String(config.get("renderer", "")).contains("thinking") or String(config.get("parser", "")).contains("thinking")
	if not thinking and templateDigest != "":
		var tpl = await _registryText(REGISTRY + path + "/blobs/" + templateDigest)
		thinking = tpl is String and tpl.to_lower().contains("think")
	var vision := hasProjector or families.has("clip") or VISION_FAMILIES.has(family)
	var problems: Array = []
	if thinking:
		problems.append("с режимом размышлений (thinking)")
	if not vision and TEXT_FAMILIES.has(family):
		problems.append("не умеет видеть картинки (нет vision)")
	elif not vision:
		return {"problem": ", ".join(problems), "sure": not problems.is_empty()} # незнакомое семейство - зрение проверим после
	return {"problem": ", ".join(problems), "sure": true}


## JSON с адреса; при ошибке - код ответа (int).
func _registryJson(url: String, headers: Array = []):
	var res = await _httpGet(url, headers)
	if res[0] != 200:
		return res[0]
	var parsed = JSON.parse_string(res[1].get_string_from_utf8())
	return parsed if parsed is Dictionary else 0


func _registryText(url: String):
	var res = await _httpGet(url, [])
	return res[1].get_string_from_utf8() if res[0] == 200 else res[0]


func _httpGet(url: String, headers: Array) -> Array:
	var http := HTTPRequest.new()
	http.timeout = 15.0
	add_child(http)
	if http.request(url, PackedStringArray(headers)) != OK:
		http.queue_free()
		return [0, PackedByteArray()]
	var res: Array = await http.request_completed
	http.queue_free()
	return [res[1], res[3]]


## 054.998: удалить скачанную модель из Ollama (освободить место).
func deleteModel(name: String) -> bool:
	var http := HTTPRequest.new()
	http.timeout = 30.0
	add_child(http)
	if http.request("http://127.0.0.1:11434/api/delete", ["Content-Type: application/json"], HTTPClient.METHOD_DELETE, JSON.stringify({"model": name})) != OK:
		http.queue_free()
		return false
	var res: Array = await http.request_completed
	http.queue_free()
	return res[1] == 200


## Console command: banwords
func setBanWords(words: Array) -> void:
	banWords = words
	gbData.settings["llmBanWords"] = words
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	_purgeBannedLines() # drop only the stale lines that actually contain a banned word


func _purgeBannedLines() -> void:
	for category in _prefetchPools.keys():
		var pool: Array = _prefetchPools[category]
		var kept: Array = []
		for line in pool:
			if not _containsBanWord(String(line)):
				kept.append(line)
		_prefetchPools[category] = kept


func _containsBanWord(text: String) -> bool:
	var lower := text.to_lower()
	for w in banWords:
		var wl: String = String(w).strip_edges().to_lower()
		if wl != "" and lower.find(wl) != -1:
			return true
	return false
