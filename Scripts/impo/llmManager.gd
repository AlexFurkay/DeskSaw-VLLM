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

const OLLAMA_URL := "http://127.0.0.1:11434/api/generate" # NOT "localhost" - on some Windows setups (VPN software installed even if inactive, IPv6/DNS quirks) resolving "localhost" can add seconds of delay per request; the literal loopback IP skips DNS resolution entirely

var modelName := "qwen3-vl:8b-instruct"
var creativity := 1.0    # was "temperature" - higher = more random/wild answers, lower = more predictable/on-character

## _on_screen_tick() runs on its own, independent of any specific pet, so it
## has no direct line to a pet's mood/health. behavior.gd/health_handler.gd
## keep these updated whenever their own values change - screen reactions
## read them to let bad mood/low health quietly colour the tone.
var lastKnownMood: float = 50.0
var lastKnownHealth: float = 100.0
var repetitionGuard := 1.2 # was "repeat_penalty" - higher = less likely to repeat the same words/phrases
var minScreenInterval := 30.0
var maxScreenInterval := 60.0

## Free text loaded from user://LORE.txt - reload at runtime with `reloadLore`.
var lore := ""

var http: HTTPRequest
var screenTimer: Timer
var busy := false
var _prefetchPools: Dictionary = {}   # category -> Array[String] ready-made lines
var _prefetchPending: Dictionary = {} # category -> bool, true while a refill is in flight
const PREFETCH_TARGET := 7
const PREFETCH_REFILL_AT := 3

## Категории, которые игрок трогает чаще всего - генерируем для них батч
## побольше, чтобы разнообразия хватало дольше и повторы в начале сессии
## случались реже.
const PREFETCH_TARGET_OVERRIDES := {
	"pet": 20,
	"drag_level0": 15,
	"drag_level1": 15,
	"drag_level2": 15,
	"fell": 15,
}

func _prefetchTargetFor(category: String) -> int:
	return PREFETCH_TARGET_OVERRIDES.get(category, PREFETCH_TARGET)

var debugTags := false
var _queue: Array = []           # foreground/interactive requests - always drained first
var _backgroundQueue: Array = [] # prefetch pool refills - only drained when _queue is empty
var _sinceBackgroundJob := 0
const BACKGROUND_EVERY_N := 3    # guarantee background a turn at least this often
var _currentCallback: Callable
var _currentTag: String = ""
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


func _loadSavedSettings() -> void:
	modelName = gbData.settings.get("llmModelName", modelName)
	creativity = gbData.settings.get("llmCreativity", creativity)
	repetitionGuard = gbData.settings.get("llmRepetitionGuard", repetitionGuard)
	minScreenInterval = gbData.settings.get("llmMinInterval", minScreenInterval)
	maxScreenInterval = gbData.settings.get("llmMaxInterval", maxScreenInterval)
	banWords = gbData.settings.get("llmBanWords", [])


func _scheduleScreenTick(overrideSeconds: float = -1.0) -> void:
	var wait := overrideSeconds
	if wait < 0.0:
		if gbData.settings.get("llmVisionEnabled", true):
			wait = randf_range(minScreenInterval, maxScreenInterval)
		else:
			wait = 5.0
	screenTimer.start(wait)


const OLD_LORE_PATH := "user://LORE.txt" # kept forever - never deleted, only read once for migration

## Лор теперь живёт ВНУТРИ папки скина (user://skin/<Имя>/lore.txt), рядом с
## TRANSLATION.json - один персонаж, одна папка, а не файлы, размазанные по
## разным местам. Раньше лор лежал плоско в корне (user://<имя>lore.txt).
func _lorePathForSkin(skinName: String) -> String:
	return "user://skin/%s/lore.txt" % skinName

func _loadLore() -> void:
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
	f.store_string("Ты %s.\n\nОпиши здесь: происхождение персонажа, характер, как он относится к человеку рядом с собой, тон речи.\nЭтот файл читается заново командой reloadLore в консоли." % skinName)
	f.close()


func _clearPrefetchPools() -> void:
	_prefetchPools.clear()
	_prefetchPending.clear()


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
func _findSentenceEnd(s: String) -> int:
	var i := 0
	while i < s.length():
		var c := s[i]
		if c == "!" or c == "?" or c == "…":
			return i
		if c == "." and (i + 1 >= s.length() or s[i + 1] != "."):
			return i
		i += 1
	return -1


## Heuristic: does this look like the model broke character entirely and
## started writing in English/meta-language instead of a Russian line?
func _looksLikeGarbage(text: String) -> bool:
	var latinCount := 0
	var cyrillicCount := 0
	for c in text:
		var code := c.unicode_at(0)
		if (code >= 65 and code <= 90) or (code >= 97 and code <= 122):
			latinCount += 1
		elif code >= 0x0400 and code <= 0x04FF:
			cyrillicCount += 1
	return latinCount > 10 and latinCount > cyrillicCount


## Catches the model breaking character to comment on the TASK itself
## instead of writing a line (e.g. "Примечание: раз требовалось 7 фраз, я
## выдал ровно семь строк.", or a lone leftover header like "Дополнительно").
## _looksLikeGarbage only catches wrong-alphabet text, not this - it's
## perfectly valid Cyrillic, just not something the character would say.
const _META_MARKERS := [
	"примечание", "дополнительно", "note:", "p.s.", "как и просили",
	"согласно заданию", "в задании", "фраз.", "фраз,", "строк.", "строк,",
	"вот %d" ,"вот несколько фраз", "как и указано", "требовалось",
	"пользователь", "альтернативный вариант", "конкретное количество",
]
func _looksLikeMetaCommentary(text: String) -> bool:
	var lower := text.to_lower().strip_edges()
	for marker in _META_MARKERS:
		if lower.contains(marker):
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
func _isFuzzyDuplicateOf(text: String, others: Array) -> bool:
	var lowerText := text.to_lower().strip_edges()
	var wordsNew := lowerText.split(" ", false)
	var setNew := {}
	for w in wordsNew:
		setNew[w] = true
	for other in others:
		var lowerOld := String(other).to_lower().strip_edges()
		if lowerText == lowerOld:
			return true
		var wordsOld := lowerOld.split(" ", false)
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


## Hard enforcement for "don't repeat yourself" - the prompt-based instruction
## alone isn't reliable (small models sometimes copy the very "don't repeat
## this" examples instead of avoiding them). Catches exact repeats and
## near-identical openers (same first 3 words = same tired pattern, e.g.
## "Ты снова..." every time) regardless of what the model intended. Checked
## only within the SAME category - see _rememberLine for why.
func _looksLikeRepeat(category: String, text: String) -> bool:
	return _isFuzzyDuplicateOf(text, _recentLinesByCategory.get(category, []))


## Console command: reloadLore
func reloadLore() -> void:
	_loadLore()
	_clearPrefetchPools() # old cached lines were written under the old lore
	print("LLMManager: lore reloaded (", lore.length(), " chars)")


func _buildBasePrompt(category: String = "") -> String:
	var parts: Array[String] = []
	parts.append("Ты - маленькое существо, которое живёт на рабочем столе человека. Ты женского рода - всегда согласуй слова по родам как о себе говорила бы девушка/самка ('я сделала', 'я готова', 'я была', а не 'сделал'/'готов'/'был'). Ты говоришь от СВОЕГО лица, только о своих чувствах и мыслях. Ты никогда не описываешь, что делает или чувствует человек, каким бы ни было действие ('держат', 'гладят' и т.п.) - оно происходит С ТОБОЙ, а не наоборот. Обращайся к человеку ТОЛЬКО на 'ты' - никогда 'вы'/'вам'/'держите'/'откройте', звучит слишком официально и совсем не в характере.")
	parts.append("Отвечай ТОЛЬКО по-русски, одной фразой (3-20 слов). Никогда не говори, что тебе что-то 'прислали' или 'отправили' - ты сама всё видишь и чувствуешь.")
	parts.append("Выведи ТОЛЬКО саму реплику - без кавычек, без пояснений в скобках, без описания действий или тона (никаких '*зевает*', 'вздрагивает и говорит'). Только слова, которые ты произносишь вслух.")
	parts.append("Почти всегда говори утверждением или восклицанием, а не вопросом - риторический вопрос ('Тебе снова нужно...?', 'Как вс...?') звучит неестественно из твоих уст. Вопрос уместен очень редко и только если он предельно простой и короткий.")
	parts.append("НЕ начинай фразу с 'Ты снова...' или 'Опять...' - это стали самые частые и приевшиеся штампы, начинай по-разному каждый раз.")
	if banWords.size() > 0:
		parts.append("Никогда не используй эти слова или фразы ни в каком виде: " + ", ".join(banWords))
	if gbData.settings.get("llmAllowProfanity", false):
		parts.append("Мат разрешён, если уместен, но не как тик в конце каждой фразы - вплетай его по-разному (усилитель, отдельное восклицание) или вообще обходись без него в конкретной фразе. Используй ТОЛЬКО настоящие целые русские матерные слова (блять, сука, хуй, пизда, ебать и их обычные формы) - никогда не выдумывай и не искажай ругательства.")
	else:
		parts.append("Мат и ругательства строго запрещены, даже если персонаж злится.")
	parts.append("Используй только реальные существующие русские слова - никогда не выдумывай новые и не искажай/склеивай существующие в бессмысленные наборы букв.")
	if gbData.settings.get("llmFlirtEnabled", false):
		parts.append("Изредка, только при очень хорошем настроении, можно слегка кокетничать - лёгкие тёплые комплименты, дружеский флирт, строго без сексуального подтекста.")
	else:
		parts.append("Флирт и романтический подтекст полностью исключены - только дружеское отношение.")
	if lore != "":
		parts.append("О себе ты знаешь следующее: " + lore)
	# Only THIS category's own recent lines - a global "everything said
	# recently" list bled unrelated categories' vocabulary/theme into each
	# other (e.g. Full picking up "держать/отпусти" fresh from drag_level2).
	var recentForThis: Array = _recentLinesByCategory.get(category, [])
	if recentForThis.size() > 0:
		var lastFew: Array = recentForThis.slice(maxi(0, recentForThis.size() - 4))
		parts.append("Вот что ты только что говорила В ЭТОЙ ЖЕ ситуации:\n- " + "\n- ".join(lastFew))
		parts.append("Дословно или почти дословно эти фразы НЕ повторяй - реагируй на текущий момент заново.")
	return "\n".join(parts)


func _on_screen_tick() -> void:
	if not gbData.settings.get("llmVisionEnabled", true):
		_scheduleScreenTick()
		return

	var png_bytes: PackedByteArray = ScreenCapture.GetScreenshotPng()
	_scheduleScreenTick()

	if png_bytes.is_empty():
		return

	var images: Array = [Marshalls.raw_to_base64(png_bytes)]
	var prompt := _buildBasePrompt("screen") + "\nВот скриншот рабочего стола. ВАЖНО: человек, за которым ты наблюдаешь, на этом скриншоте физически не присутствует и присутствовать не может (это просто экран его компьютера) - никогда не описывай его как будто он на картинке, даже если на экране идёт видеозвонок, стрим, видео или фото с реальными людьми. Если на скриншоте видно маленькое пиксельное существо поверх окон - это ТЫ САМА, а не человек. Любое другое изображение - существо, персонаж, животное, реальный человек или лицо в видео, стриме, звонке или на фото - это просто картинка на экране, а не тот человек, за которым ты наблюдаешь, и оно тебя не видит, не смотрит на тебя и не смотрит в камеру НА ТЕБЯ. Прокомментируй содержимое экрана (окна, текст, видео и т.д.), а не то, кто на нём якобы физически присутствует или смотрит на тебя. Скажи это как утверждение или восклицание, НЕ как вопрос - и не начинай с 'Ты снова'/'Опять'/'Снова', и НЕ заканчивай фразу шаблоном 'но ты всё ещё мешаешь мне' или похожим - придумывай разные концовки."
	prompt += _screenMoodHealthHint()
	_enqueue(prompt, images, func(text): llmReaction.emit(text), "screen")


## Постепенная примесь состояния в screen-реакции - чем хуже здоровье и/или
## настроение, тем сильнее это должно просачиваться в тон, не перекрывая
## собой саму реакцию на экран. Пороги - грубая прикидка, баланс потом.
func _screenMoodHealthHint() -> String:
	var severity := 0
	if lastKnownHealth <= 15.0 or lastKnownMood <= -60.0:
		severity = 3
	elif lastKnownHealth <= 40.0 or lastKnownMood <= -30.0:
		severity = 2
	elif lastKnownHealth <= 70.0 or lastKnownMood <= -10.0:
		severity = 1

	match severity:
		1:
			return "\nТебе сейчас не очень хорошо (здоровье или настроение так себе) - пусть в реакцию едва заметно проскальзывает лёгкая усталость или раздражение, не заостряй на этом внимание."
		2:
			return "\nТебе сейчас довольно плохо (здоровье или настроение заметно просели) - в реакции должна ощущаться усталость, лёгкая боль или подавленность, наравне с самой реакцией на экран, не перекрывая её полностью."
		3:
			return "\nТебе сейчас очень плохо (здоровье или настроение совсем никакие) - реакция на экран должна звучать через явную боль/слабость/подавленность, коротко и через силу, а не как обычно."
		_:
			return ""


## Wraps a situation/event description so the prompt clearly marks it as
## background context, not a line to read aloud. Small local models tend to
## just paraphrase a bare description back as if it were the answer itself
## (e.g. "Тебя держат слишком долго" -> "Тебя держат слишком долго - вырвусь!")
## - this framing plus an explicit "don't repeat it" instruction fixes that.
func _situationBlock(description: String) -> String:
	if description == "":
		return ""
	return "\nСитуация (это описание для тебя, а НЕ реплика для произношения): " + description + "\nСкажи, что почувствовала бы ТЫ в такой ситуации, от своего лица. Например, если ситуация - 'тебя держат в руках': ПРАВИЛЬНО - 'Отпусти меня!', 'Мне неудобно так висеть' (говоришь о СЕБЕ). НЕПРАВИЛЬНО - 'Тяжело держать тебя', 'Я держу тебя' (это звучит так, будто ТЫ держишь кого-то - перепутаны роли, так нельзя). ВАЖНО: не пересказывай и не перефразируй само описание ситуации почти теми же словами - придумай СВОЮ короткую эмоциональную реплику."


## Trigger an immediate, text-only reaction to something happening right now.
## Pass `callback` to deliver the result to ONE specific pet, bypassing the
## broadcast (and its "don't interrupt" guards) - see behavior.gd/dragExp.gd.
func reactToEvent(eventDescription: String, callback: Callable = Callable(), tag: String = "event") -> void:
	if not gbData.settings.get("llmVisionEnabled", true):
		return
	var prompt := _buildBasePrompt(tag) + _situationBlock(eventDescription)
	var cb := callback
	if not cb.is_valid():
		cb = func(text): llmReaction.emit(text)
	_enqueue(prompt, [], cb, tag)


## Called from a specific pet's passivetalk() loop. Result delivered ONLY to
## that pet via callback - not broadcast.
const _PROFANITY_ROOTS := ["хуй", "хер", "ебат", "ёбан", "ебан", "заеб", "пизд", "бля", "сук", "мудак", "долбоёб", "гандон"]

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


func _containsProfanity(text: String) -> bool:
	var lower: String = text.to_lower()
	for root in _PROFANITY_ROOTS:
		if lower.find(root) != -1:
			return true
	return false


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


func requestStateReaction(statLine: String, exampleLines: Array, callback: Callable) -> void:
	if not gbData.settings.get("llmVisionEnabled", true):
		return

	exampleLines = _filterExamplesForProfanity(exampleLines)

	var prompt := _buildBasePrompt("state")
	prompt += "\nТвоё текущее состояние: " + statLine + "."
	if exampleLines.size() > 0:
		prompt += "\nПримеры того, как ты обычно говоришь в таком состоянии (не копируй дословно, ориентируйся только на стиль и настроение):\n- " + "\n- ".join(exampleLines)
	prompt += "\nПридумай одну НОВУЮ короткую фразу в этом же духе. Сохраняй характер и примерную длину примеров."

	_enqueue(prompt, [], callback, "state")


## Lightweight variant for INSTANT events (petting, getting picked up,
## rejecting a pet, waking up...) where speed matters more than deep
## personalization - deliberately skips lore and stats, just blends a
## handful of example lines from that moment's usual quote pool. Used by
## behavior.gd's _say() helper. `tag` is just for debugTags (e.g. "pet",
## "getUp", "petReject" - whatever category _say() was called with).
func requestQuickReaction(exampleLines: Array, callback: Callable, tag: String = "quick", styleHint: String = "", situationDescription: String = "") -> void:
	if not gbData.settings.get("llmVisionEnabled", true):
		return

	var filtered: Array = _filterExamplesForProfanity(exampleLines)

	var prompt := _buildBasePrompt(tag)
	prompt += _situationBlock(situationDescription)
	if styleHint != "":
		prompt += "\n" + styleHint
	if filtered.size() > 0:
		prompt += "\nВот несколько похожих фраз для вдохновения (не копируй дословно):\n- " + "\n- ".join(filtered)
		prompt += "\nПридумай одну НОВУЮ фразу в этом же духе и стиле."
	else:
		# every example got filtered out (profanity) - still react, just
		# without a style example to lean on, rather than staying silent.
		prompt += "\nПридумай короткую фразу, подходящую персонажу по духу и характеру."

	_enqueue(prompt, [], callback, tag)


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
		if pool.size() <= PREFETCH_REFILL_AT:
			_refillPool(category, exampleLines, styleHint, situationDescription)
	else:
		requestQuickReaction(exampleLines, callback, category, styleHint, situationDescription)
		_refillPool(category, exampleLines, styleHint, situationDescription)


func _refillPool(category: String, exampleLines: Array, styleHint: String = "", situationDescription: String = "") -> void:
	if _prefetchPending.get(category, false):
		return # a refill is already in flight for this category
	_prefetchPending[category] = true

	var filtered: Array = _filterExamplesForProfanity(exampleLines)

	var prompt := _buildBasePrompt(category)
	prompt += _situationBlock(situationDescription)
	if styleHint != "":
		prompt += "\n" + styleHint
	var target := _prefetchTargetFor(category)
	prompt += "\nИСКЛЮЧЕНИЕ из правила выше про одно предложение: сейчас напиши сразу %d РАЗНЫХ коротких фраз (каждая - как обычно, 3-15 слов, в характере, без кавычек и пояснений), каждую на отдельной строке, без нумерации." % target
	if filtered.size() > 0:
		prompt += "\nВот несколько похожих фраз для вдохновения (не копируй дословно):\n- " + "\n- ".join(filtered)
	else:
		# every example got filtered out (profanity) - still generate a
		# batch, just without a style example to lean on.
		prompt += "\nОриентируйся на характер персонажа."
	prompt += "\nВыведи ровно %d строк, каждая - отдельная новая фраза в этом же духе." % PREFETCH_TARGET

	_enqueue(prompt, [], func(rawText): _onPoolRefilled(category, rawText), "prefetch:" + category)


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
		if pool.size() <= PREFETCH_REFILL_AT:
			_refillEventPool(poolKey, eventDescription, exampleLines)
	else:
		reactToEvent(eventDescription, callback, poolKey)
		_refillEventPool(poolKey, eventDescription, exampleLines)


func _refillEventPool(poolKey: String, eventDescription: String, exampleLines: Array = []) -> void:
	if _prefetchPending.get(poolKey, false):
		return
	_prefetchPending[poolKey] = true

	var filtered: Array = _filterExamplesForProfanity(exampleLines)

	var prompt := _buildBasePrompt(poolKey)
	prompt += _situationBlock(eventDescription)
	var target := _prefetchTargetFor(poolKey)
	prompt += "\nИСКЛЮЧЕНИЕ из правила выше про одно предложение: сейчас напиши сразу %d РАЗНЫХ коротких фраз в этой ситуации (каждая 3-15 слов, без кавычек и пояснений), каждую на отдельной строке, без нумерации." % target
	if filtered.size() > 0:
		prompt += "\nВот несколько похожих фраз для вдохновения (не копируй дословно):\n- " + "\n- ".join(filtered)

	_enqueue(prompt, [], func(rawText): _onPoolRefilled(poolKey, rawText), "prefetch:" + poolKey)


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
	for i in lines.size():
		var raw: String = lines[i]
		var cleaned: String = lines[i].strip_edges().replace("*", "")
		cleaned = cleaned.lstrip("0123456789.-) ").strip_edges()

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

		var firstEnd := _findSentenceEnd(cleaned)
		if firstEnd > 0:
			cleaned = cleaned.substr(0, firstEnd + 1).strip_edges()

		if _looksLikeGarbage(cleaned):
			_logDebugLine(category, "REJECTED:GARBAGE", raw)
			continue

		if _looksLikeMetaCommentary(cleaned):
			_logDebugLine(category, "REJECTED:META_COMMENTARY", raw)
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

func _enqueue(prompt: String, images: Array, callback: Callable, tag: String = "") -> void:
	var job := {"prompt": prompt, "images": images, "callback": callback, "tag": tag}
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


func _processQueue() -> void:
	if busy:
		return
	if _queue.is_empty() and _backgroundQueue.is_empty():
		return
	busy = true
	_watchdogTimer.start()

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

	# Batch (prefetch pool refill) requests carry PREFETCH_TARGET lines in one
	# response, so they need a much bigger token budget than a single line.
	var predictBudget: int = 220
	if _currentTag.begins_with("prefetch:"):
		predictBudget = 220 * _prefetchTargetFor(_currentTag.trim_prefix("prefetch:"))

	var payload := {
		"model": modelName,
		"keep_alive": "30m",
		"prompt": job["prompt"],
		"stream": false,
		"options": {
			"repeat_penalty": repetitionGuard,
			"temperature": creativity,
			"num_predict": predictBudget,
			"num_ctx": 4096
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
		_processQueue()


func _clearPendingIfPrefetch() -> void:
	if _currentTag.begins_with("prefetch:"):
		var category := _currentTag.trim_prefix("prefetch:")
		_prefetchPending[category] = false


func _on_request_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_watchdogTimer.stop()
	busy = false
	var cb := _currentCallback

	if response_code != 200:
		print("LLMManager: Ollama returned code ", response_code, " - is `ollama serve` running with the model pulled?")
		_clearPendingIfPrefetch()
		_processQueue()
		return

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
			var firstEnd := _findSentenceEnd(text)
			if firstEnd > 0:
				text = text.substr(0, firstEnd + 1).strip_edges()

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

		if text != "" and _looksLikeRepeat(_currentTag, text):
			rejectReason = "REPEAT"
			text = ""

		if text != "" and _containsBanWord(text):
			rejectReason = "BANWORD"
			text = ""

		_logDebugLine(_currentTag, "OK" if text != "" else "REJECTED:" + rejectReason, text if text != "" else rawReply)

		if debugTags and _currentTag != "":
			text = "[%s] %s" % [_currentTag, text]

	if text != "" and not isPrefetchBatch:
		_rememberLine(_currentTag, text.trim_prefix("[" + _currentTag + "] ") if debugTags and _currentTag != "" else text)

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
	busy = false
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


## Console command: visionInterval <min> <max>  (seconds) - screen reactions only.
func setInterval(minSeconds: float, maxSeconds: float) -> void:
	minScreenInterval = max(1.0, minSeconds)
	maxScreenInterval = max(minScreenInterval, maxSeconds)
	gbData.settings["llmMinInterval"] = minScreenInterval
	gbData.settings["llmMaxInterval"] = maxScreenInterval
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	print("LLMManager: screen-reaction interval set to ", minScreenInterval, "-", maxScreenInterval, " seconds")


## Console command: aiCreativity <0.0-1.5>
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


func setModel(name: String) -> void:
	modelName = name
	gbData.settings["llmModelName"] = modelName
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	# Раньше тут был _clearPrefetchPools() - специально убрал: часть тестеров
	# и разработчик хотят прогреть пулы на одной модели, потом переключиться
	# на другую (например для более живых screen-реакций) и НЕ терять уже
	# прогретое - остальные пулы просто будут тихо дозаполняться новой
	# моделью по мере естественного расхода, без принудительного сброса.
	pullModel(name)


## Console command: aiModel triggers this automatically. Calls Ollama's own
## /api/pull directly (not the CLI "ollama pull") so it works regardless of
## whether ollama.exe is on PATH. Non-streaming - Ollama just holds the
## connection open until the whole model is downloaded, then replies once.
## For a large model this can take a long time; there's no progress bar,
## just a final success/failure line in the console.
func pullModel(name: String) -> void:
	var pullHttp := HTTPRequest.new()
	Engine.get_main_loop().root.add_child(pullHttp)
	Console.print("Скачиваю модель [color=CYAN]%s[/color] через Ollama, если её ещё нет - подожди, для больших моделей это может занять долго..." % name)
	pullHttp.request_completed.connect(func(_result, response_code, _headers, body):
		if response_code == 200:
			var parsed = JSON.parse_string(body.get_string_from_utf8())
			if parsed is Dictionary and String(parsed.get("status", "")) == "success":
				Console.print("Модель [color=CYAN]%s[/color] готова к использованию." % name)
			else:
				Console.print("Модель [color=CYAN]%s[/color]: ответ Ollama получен, но статус не 'success' - проверь вручную (ollama list)." % name)
		else:
			Console.print("Не получилось скачать модель [color=CYAN]%s[/color] (код ответа %d) - проверь, запущена ли Ollama, и правильно ли написано имя модели." % [name, response_code])
		pullHttp.queue_free()
	)
	var payload := {"name": name, "stream": false}
	var headers := ["Content-Type: application/json"]
	var err := pullHttp.request("http://127.0.0.1:11434/api/pull", headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		Console.print("Не получилось отправить запрос на скачивание модели [color=CYAN]%s[/color] (ошибка %d)." % [name, err])
		pullHttp.queue_free()


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
