extends Node


"""
hey this is like 2 days before 0.2 releases

most of this script is 2014 toby fox level bullshit

and i need to recode it asap


im putting this here as a reminder

"""


#referebces for systems to be used by this script
@onready var faceSys = $faceHandler
@onready var moodSys = $moodHandler
@onready var moveSys = $movementHandler
@onready var sleepHandler = $sleepManager
@onready var hungerHandler = $hungerHandler
@onready var healthHandler = $healthHandler
@onready var skinmapper = $skinmapper
@onready var dialogueSys = $dialogue
@onready var detectRange = $detRadius
@onready var statUpd = $statWatcher

@onready var settings = gbData.settings
#settings for dialoguetimer

##Timer used for keeping time since the last recent pet.
@onready var pet_timer: Timer = $petTimer

@export var sleepParticle: CPUParticles2D
##How much does the pet timer last. Keep it higher getUpTimer so the wrong dialogue
##doesn't get sent.
var pet_timer_inc := 10.0
##How many times has the node been pet recently.
var pet_count := 0


var beingDragged := false

var ragdolled := false

var launchflag := false

## Момент (Time.get_ticks_msec()), до которого подавляются урон/испуг от
## падений и бросков - только чтобы не пугать и не бить персонажа в самый
## первый кадр после спавна (ложное "падение" из-за физики затухания при
## появлении). Раньше для этого использовался launchflag, но он же блокировал
## АБСОЛЮТНО ЛЮБОЙ урон до первого завершённого цикла "встал" - то есть если
## бросить свежеспавненного питомца об стену сразу же, урон не засчитывался
## вообще, пока он хоть раз не поднимется сам. launchflag теперь используется
## только для выбора реплики при подъёме (см. tempRagdoll), а не для урона.
var _spawnGraceUntil: int = 0


var wander := true


# every spawned sawian will be assigned an id regardless of if they exist for like a few seconds or days on end.
# this is how they are stored in SAVE.json
var petId := ""


#status, stuff
# used for emotions and others related
var isTired := false
var isSleeping := false
var isHungry := false
var isSad := false
var shocked := false
var isUnconscious := false # 0 хп - навсегда (до перезапуска приложения), персонаж молчит и не приходит в себя
var _finalLinePending := false # одна последняя фраза, которая ещё может прозвучать после отключки (см. _queueMessage)

## Персонаж-игрок (см. PlayerManager): та же физика и статы, но без своих
## ИИ-фраз - говорит только то, что пишет человек. Выставляется ДО
## добавления в сцену (как petId).
var isPlayer := false
var playerControlled := false
var _playerDir := 0.0
var _playerJump := false
var _playerSit := false
## звук "меня держат" у перса-игрока - не чаще, чем раз в столько секунд
const PLAYER_DRAG_SOUND_MIN := 4.5
const PLAYER_DRAG_SOUND_MAX := 6.0
var _playerDragSoundAt := 0
var _playerSitPrev := false
var _forcedSleep := false # сон автопилота: не просыпается сам, только по включению управления
var _autopilotSleepAt := 0 # когда автопилот уложит игрока спать (3-5 мин без управления)
const PLAYER_MOOD := 50.0 # у игрока настроение не считается
const CRITICAL_HEALTH_THRESHOLD := 20.0 # ниже этого - не может встать, но остаётся в сознании и говорит
const LANDING_GRACE_MS := 1200 # после вставания приземление тела не считается ударом
var _landingGraceUntil := 0

## Сила удара = насколько резко изменилась скорость тела за один кадр
## физики (пикс/сек). Меряется в момент столкновения, а не в момент
## отпускания мышкой - поэтому считаются и броски, и просто падения с
## высоты, и удары о стены, в любом направлении. Пороги подбирать по
## ощущениям (toggleDebugTags печатает силу каждого удара в консоль).
## Ориентир: ящик 96 пикс, гравитация персонажа 980*0.8 - падение даже с
## 6 ящиков друг на друге (~576 пикс) даёт ~950, это ещё НЕ урон. Падение
## с самого верха экрана 1080p - около 1250, лёгкий урон.
const IMPACT_LIGHT := 1150.0
const IMPACT_MEDIUM := 1700.0
const IMPACT_HARD := 2300.0
const DAMAGE_LIGHT := 5.0
const DAMAGE_MEDIUM := 15.0
const DAMAGE_HARD := 30.0
const IMPACT_COOLDOWN_MS := 600 # отскок от пола сразу после удара - это не второй удар
var _prevTorsoVel := Vector2.ZERO
var _prevBodyVel := Vector2.ZERO
var _impactPrevValid := false
var _bodyPrevValid := false
var _lastImpactMsec := -100000
var _impactThisRagdoll := false # был ли настоящий удар за этот цикл рэгдолла - тогда при подъёме реплика "fell", а не "getUp"
## Бессмертие при спавне: персонаж появляется высоко за экраном и
## гарантированно падает - до тех пор, пока он впервые не встанет на ноги
## после этого падения, никакой урон не считается.
var _spawnSettled := false

## Сколько персонаж не может снова заснуть после того, как его разбудили
## ударом. Без этого при усталости > 95 он засыпал бы обратно на следующем
## же тике (5 сек). Сама усталость при пробуждении не сбрасывается.
const WAKE_NO_SLEEP_MS := 120000
var _noSleepUntil: int = 0
var _saidReallySleepy := false

## Вызывается из health_handler.gd, когда ХП падает до 0. Не смерть - просто
## окончательная "отключка" на весь текущий запуск приложения: персонаж
## молчит (см. guard в _say()) и держит закрытые глаза, пока пользователь
## сам не перезапустит игру. Это НЕ откатывается автоматическим
## восстановлением здоровья - решение однозначно постоянное на сессию.
## 054.991: последние слова (0 здоровья, передозировка) - сразу на экран,
## мимо очереди и без ожидания ИИ. Тестер не слышал фразы при передозировке:
## путь через очередь и ИИ-пул зависел от того, успел ли пул создаться и
## что в этот момент печаталось. Сначала готовая ИИ-фраза из пула, иначе - из
## файла (lastmoments, у передозировки своих фраз в файле нет).
func _sayFinal(category: String) -> void:
	if isPlayer:
		category = "lastmoments"
	var line := ""
	var poolKey := _skinTag() + ":" + category
	var pool: Array = LLMManager._prefetchPools.get(poolKey, [])
	if not isPlayer and not pool.is_empty():
		line = String(pool.pop_front())
		LLMManager._prefetchPools[poolKey] = pool
	if line == "":
		var fromFile: Array = dialogueSys.data.get(CATEGORY_EXAMPLES_FROM.get(category, category), [])
		if fromFile.is_empty():
			return
		line = String(fromFile.pick_random())
	_messageQueue.clear()
	_urgentInQueue = 0
	var processed := _applyStupid(line)
	_recordSpoken(processed[0])
	_showingPriority = PRIO_EMERGENCY
	dialogueSys.setDia(processed[0], dialogueSys.speedMod + processed[1], 2.0, true)


## waitFinalLine - ждать ли ещё одну последнюю фразу от ИИ (если она уже
## показана через _sayFinal - не ждём, иначе после неё проскочила бы ещё одна).
func goUnconscious(waitFinalLine: bool = true) -> void:
	if isUnconscious:
		return
	isUnconscious = true
	_finalLinePending = waitFinalLine
	faceSys.setEmotion("sleep") # уже готовое состояние с закрытыми глазами, ничего рисовать не нужно
	if not ragdolled:
		# При 0 ХП от удара персонаж и так уже лежит, а при передозировке он
		# стоял - без этого так и оставался стоять с закрытыми глазами.
		tempRagdoll(false, true)


#unused atm
var isDead := false


#might be worth it change most of the timers in this script with variables
#so we can avoid magic numbers
##How long does it take the sawian to get up after being ragdolled.
var getUpTimer := 5.0
var _dragEscalationLevel := 0
const DRAG_STAGE_DESCRIPTIONS := [
	"Тебя подняли и слегка покачивают в воздухе. Немного странно и неловко, но пока терпимо - лёгкое ворчание, без настоящей злости. Скажи это как утверждение или восклицание, не как вопрос.",
	"Тебя держат в воздухе уже довольно долго и не думают отпускать. Терпение реально заканчивается - огрызнись по-настоящему, с явным раздражением в голосе. Скажи это как утверждение или восклицание, не как вопрос.",
	"Тебя держат СЛИШКОМ долго и категорически не отпускают. Ты в настоящей ярости, почти рычишь и {готова|готов} укусить - можешь даже выделить одно слово ЗАГЛАВНЫМИ буквами для акцента. Скажи это как утверждение или восклицание, не как вопрос."
]
##How long does it take for the sawian to send dialogue after getting up.
var getUpTimerMsg := 1.5

#you get the idea
var hungryRemind := 90.0


#ricktate in seconds for updating status
var tick: float = 5.0

# table for every emotion avaibalekl to them
enum emotionz {
	normal, sad, sleep, tired, scared, panic, happy
}
var currentEmotion = emotionz.normal

func _ready() -> void:
	# Анимация рта (talkLoop в faceSys.gd) при разговоре сама переключает
	# текстуру головы туда-обратно, ничего не зная про травмы - в итоге
	# голова "чинится" на время речи и остаётся здоровой на вид, пока не
	# случится следующее не связанное с этим событие урона/лечения.
	# Переподтверждаем вид травмы сразу же, как речь заканчивается.
	dialogueSys.stoptalking.connect(_applyInjuryLook)
	voiceSet = AudioManager.getVoiceSet(_skinTag())

	if petId == "":
		var skinName = GlobalVariable.userSkinPath.substr(0, len(GlobalVariable.userSkinPath) - 1)
		skinName = skinName.substr(skinName.rfind("/") + 1)
		petId = gbData.addPet(skinName)

	get_parent().get_parent().set_meta("itemName", petId)
	add_to_group("pets") # PlayerManager ищет, кто ответит игроку
	if gbData.data["saw"].has(petId) and gbData.data["saw"][petId].get("player", false):
		isPlayer = true # восстановлен из сейва (expiePersistence)
	if isPlayer:
		PlayerManager.adopt(self, _skinTag())
		_autopilotSleepAt = Time.get_ticks_msec() + randi_range(180000, 300000)
		moodSys.mood = PLAYER_MOOD # настроение у игрока отключено (petLimb и пр. читают moodSys.mood напрямую)
		# реплики игрока - белые с чёрной обводкой и висят в 1.5 раза дольше,
		# чтобы в разговоре было видно, кто говорит
		dialogueSys.holdMultiplier = 1.5
		var rtl: RichTextLabel = dialogueSys.richtextlabel
		rtl.add_theme_color_override("default_color", Color.WHITE)
		rtl.add_theme_color_override("font_outline_color", Color.BLACK)
		rtl.add_theme_constant_override("outline_size", 4)


	#im very sorry that i had to comment this out i have no idea what its supposed to do and it was throwing an error
	"""
	# Set debug text to Node's ID:
	$"../textParent/DebugText".text = "Test"
	print(get_parent().get_parent().get_children().find(self))
	connect("toggleDebugText", _on_debugToggle_signal)
	"""

		#setup For spawn
	_spawnGraceUntil = Time.get_ticks_msec() + 2000 # 2 сек. неприкосновенности сразу после спавна
	_quietUntil = Time.get_ticks_msec() + SPAWN_QUIET_MS
	_initalSpawn()
	LLMManager.llmReaction.connect(_on_llm_reaction)
	LLMManager.aiEnabledChanged.connect(func(enabled): if enabled and not isPlayer: _prewarmMyCategories())
	if not isPlayer: # игроку свои ИИ-фразы не нужны - и видеокарту не грузим прогревом
		LLMManager.poolsCleared.connect(_prewarmMyCategories)
		if gbData.settings.get("llmVisionEnabled", false):
			_prewarmMyCategories()
	# одежда надевается через ту же зону у головы, через которую персонаж ест
	healthHandler.mouth.body_entered.connect(_onWearableEnter)

	_queueTimer = Timer.new()
	_queueTimer.wait_time = 0.3
	add_child(_queueTimer)
	_queueTimer.timeout.connect(_tryShowQueued)
	_queueTimer.start()

func _prewarmMyCategories() -> void:
	# Common - happen often enough that they're worth having ready up front.
	# .get(key, []) everywhere here on purpose: a skin missing any one of
	# these categories (no override + base file also lacking it) used to
	# hard-crash this whole dict literal before prewarm even started,
	# silently killing ALL prewarm output with zero console trace - the
	# crash happened while building the argument, before the function
	# that would have printed anything ever ran.
	var t := _skinTag() + ":" # префикс скина - разные персонажи не должны делить один и тот же прогретый пул
	LLMManager.prewarmAllCategories({
		t + "sleepy": dialogueSys.data.get("sleepy", []),
		t + "hungry": dialogueSys.data.get("hungry", []),
		t + "getUp": dialogueSys.data.get("getUp", []),
		t + "fell": dialogueSys.data.get("fell", []),
		t + "pet": dialogueSys.data.get("pet", []),
		t + "grab": dialogueSys.data.get("beingDragged", []),
	}, {
		t + "drag_level0": DRAG_STAGE_DESCRIPTIONS[0],
		t + "drag_level1": DRAG_STAGE_DESCRIPTIONS[1],
		t + "drag_level2": DRAG_STAGE_DESCRIPTIONS[2],
	}, false, {
		t + "drag_level0": dialogueSys.data.get("drag_level0", []),
		t + "drag_level1": dialogueSys.data.get("drag_level1", []),
		t + "drag_level2": dialogueSys.data.get("drag_level2", []),
	}, {
		t + "sleepy": CATEGORY_SITUATION.get("sleepy", ""),
		t + "hungry": CATEGORY_SITUATION.get("hungry", ""),
		t + "getUp": CATEGORY_SITUATION.get("getUp", ""),
		t + "fell": CATEGORY_SITUATION.get("fell", ""),
		t + "pet": CATEGORY_SITUATION.get("pet", ""),
		t + "grab": CATEGORY_SITUATION.get("grab", ""),
	})
	# Rare ones continue automatically, passively, right after the common
	# batch finishes - no need to wait for them to actually happen in play.
	# Проверка нужна: прогрев может запускаться повторно (poolsCleared), а
	# повторный connect того же метода Godot считает ошибкой.
	if not LLMManager.prewarmBatchFinished.is_connected(_prewarmRareCategories):
		LLMManager.prewarmBatchFinished.connect(_prewarmRareCategories, CONNECT_ONE_SHOT)


func _prewarmRareCategories() -> void:
	var t := _skinTag() + ":"
	LLMManager.prewarmAllCategories({
		t + "reallySleepy": dialogueSys.data.get("reallySleepy", []),
		t + "screamBIG": dialogueSys.data.get("screamBIG", []),
		t + "getUpPet": dialogueSys.data.get("getUpPet", []),
		t + "petReject": dialogueSys.data.get("petReject", []),
		t + "Full": dialogueSys.data.get("Full", []),
		t + "EatReject": dialogueSys.data.get("EatReject", []),
		t + "EatBad": dialogueSys.data.get("EatBad", []),
		t + "EatOk": dialogueSys.data.get("EatOk", []),
		t + "EatGood": dialogueSys.data.get("EatGood", []),
		t + "LightDamage": dialogueSys.data.get("LightDamage", []),
		t + "MediumDamage": dialogueSys.data.get("MediumDamage", []),
		t + "HardDamage": dialogueSys.data.get("HardDamage", []),
		# lastmoments - сразу из файла (_say), как start: пул не генерируем
		t + "healed": dialogueSys.data.get("healed", []),
		t + "fentanyl": dialogueSys.data.get("fentanyl", []),
		t + "withdrawal": dialogueSys.data.get("withdrawal", []),
		# готовая фраза нужна заранее: после передозировки персонаж сразу
		# отключается, и "живой" запрос к ИИ уже не успел бы прозвучать
		t + "overdose": dialogueSys.data.get("lastmoments", []),
		t + "petWounded": dialogueSys.data.get("LowPassive", []),
	}, {}, true, {}, {
		t + "reallySleepy": CATEGORY_SITUATION.get("reallySleepy", ""),
		t + "screamBIG": CATEGORY_SITUATION.get("screamBIG", ""),
		t + "getUpPet": CATEGORY_SITUATION.get("getUpPet", ""),
		t + "petReject": CATEGORY_SITUATION.get("petReject", ""),
		t + "Full": CATEGORY_SITUATION.get("Full", ""),
		t + "EatReject": CATEGORY_SITUATION.get("EatReject", ""),
		t + "EatBad": CATEGORY_SITUATION.get("EatBad", ""),
		t + "EatOk": CATEGORY_SITUATION.get("EatOk", ""),
		t + "EatGood": CATEGORY_SITUATION.get("EatGood", ""),
		t + "LightDamage": CATEGORY_SITUATION.get("LightDamage", ""),
		t + "MediumDamage": CATEGORY_SITUATION.get("MediumDamage", ""),
		t + "HardDamage": CATEGORY_SITUATION.get("HardDamage", ""),
		t + "healed": CATEGORY_SITUATION.get("healed", ""),
		t + "fentanyl": CATEGORY_SITUATION.get("fentanyl", ""),
		t + "withdrawal": CATEGORY_SITUATION.get("withdrawal", ""),
		t + "overdose": CATEGORY_SITUATION.get("overdose", ""),
		t + "petWounded": _woundedPetSituation(),
	})

var _messageQueue: Array = []      # [{text, speed}] shown in order; urgent entries get inserted at the front
var _urgentInQueue := 0            # how many of the front entries are urgent (caps back-to-back urgent runs)
var _queueTimer: Timer

## Queues a line to display instead of showing it immediately - prevents two
## AI responses that happen to arrive close together from overlapping/
## interrupting each other. `urgent` (used for drag/pet/petReject/screamBIG/
## fell) jumps ahead of whatever's already queued, but can't monopolize the
## queue forever - after 2 urgent lines in a row, a normal one gets a turn,
## so a flurry of urgent reactions can't indefinitely starve getUp/hungry/etc.
## 054.995: приоритеты фраз. Перебить то, что сейчас на экране, может только
## фраза уровнем выше; остальные встают в очередь (срочные - в её начало).
## Раньше любая "срочная" (погладили, схватили) обрывала реплику разговора.
const PRIO_NORMAL := 0     # о состоянии, экран, предметы
const PRIO_REACTION := 1   # погладили, схватили, фентанил, встал
const PRIO_DIALOGUE := 2   # разговор с игроком и между персами
const PRIO_EMERGENCY := 3  # боль, крик от удара, падение, последние слова
const EMERGENCY_CATEGORIES := ["screamBIG", "fell", "LightDamage", "MediumDamage", "HardDamage", "lastmoments", "overdose"]
var _showingPriority := PRIO_NORMAL

## priority -1 = по старому флагу urgent (реакция или обычная)
func _queueMessage(text: String, speed: float = 1.0, urgent: bool = false, priority: int = -1) -> void:
	if priority < 0:
		priority = PRIO_REACTION if urgent else PRIO_NORMAL
	if isUnconscious:
		# Последняя фраза (lastmoments/overdose) запрашивается ДО отключки,
		# но ответ ИИ может прийти уже после неё - раньше он здесь молча
		# выбрасывался. Пропускаем ровно одну срочную фразу и показываем сразу.
		if urgent and _finalLinePending:
			_finalLinePending = false
			_messageQueue.clear()
			_urgentInQueue = 0
			var finalText := _applyStupid(text)
			_recordSpoken(finalText[0])
			dialogueSys.setDia(finalText[0], speed + finalText[1], 2.0, true)
		return # 0 хп - state/screen/grab и всё остальное тоже не должно звучать, не только _say()
	if isSleeping:
		return # ответ ИИ мог прийти уже после того, как персонаж уснул - во сне молчим
	var processed := _applyStupid(text)
	text = processed[0]
	speed += processed[1]
	var onScreen: bool = dialogueSys.isTyping or not dialogueSys.dialogueTimer.is_stopped()
	if urgent and onScreen and priority > _showingPriority:
		# Фраза важнее той, что на экране, - обрываем её сейчас. setDia()'s own
		# typeOut() has a generation-counter guard that safely abandons the
		# old typing coroutine without corrupting the display, so calling
		# it again here is enough to interrupt cleanly.
		_recordSpoken(text)
		_showingPriority = priority
		dialogueSys.setDia(text, speed, 2.0, true)
		return

	var entry := {"text": text, "speed": speed, "priority": priority}
	if urgent and _urgentInQueue < 2:
		_messageQueue.insert(_urgentInQueue, entry)
		_urgentInQueue += 1
	else:
		_messageQueue.append(entry)
	if _messageQueue.size() > 5:
		_messageQueue.pop_back() # don't let stale lines pile up forever

	_tryShowQueued()


## Тег [stupid] (заплетающийся язык) раньше работал только для фраз из
## файла (dialogueSys.send), а ИИ-фразы шли через setDia и показали бы его
## как текст. Возвращает [текст, поправка скорости].
func _applyStupid(text: String) -> Array:
	if text.find("[stupid]") == -1:
		return [text, 0.0]
	return [dialogueSys.stupify(text.replace("[stupid]", "")), -0.3]


## Общая память разговора: что персонаж сам сказал вслух (экран, состояние,
## предметы...) за последнее время. Её видит чат с персом-игроком - можно
## спросить "почему ты так сказала?" про экранную реплику пятиминутной давности.
const SPOKEN_LOG_SIZE := 30 # 054.99: было 20
const SPOKEN_LOG_MAX_AGE_MS := 3600000 # 60 минут (было 45)
var _spokenLog: Array = [] # [{"t": msec, "text": реплика}]

func _recordSpoken(text: String) -> void:
	var clean := RegEx.create_from_string("\\[[^\\]]*\\]").sub(text, "", true).strip_edges()
	if clean == "":
		return
	# во вкладку «Фразы» - все, включая реплики перса-игрока
	GlobalVariable.logPhrase(PlayerManager.displayNameFor(_skinTag()) + (" (ты)" if isPlayer else ""), clean, _skinTag(), isPlayer)
	if isPlayer:
		return
	_spokenLog.append({"t": Time.get_ticks_msec(), "text": clean})
	while _spokenLog.size() > SPOKEN_LOG_SIZE:
		_spokenLog.pop_front()


func _recentSpoken() -> Array:
	var now := Time.get_ticks_msec()
	var result: Array = []
	for e in _spokenLog:
		if now - int(e["t"]) <= SPOKEN_LOG_MAX_AGE_MS:
			result.append({"minutesAgo": int((now - int(e["t"])) / 60000), "text": e["text"]})
	return result


func _tryShowQueued() -> void:
	if isSleeping or isUnconscious:
		return
	if dialogueSys.isTyping or not dialogueSys.dialogueTimer.is_stopped():
		return # something is still on screen - wait for it to clear
	if _messageQueue.is_empty():
		return

	var entry: Dictionary = _messageQueue.pop_front()
	if _urgentInQueue > 0:
		_urgentInQueue -= 1

	_recordSpoken(entry["text"])
	_showingPriority = int(entry.get("priority", PRIO_NORMAL))
	dialogueSys.setDia(entry["text"], entry["speed"], 2.0, true)


func _on_llm_reaction(text: String, direct: bool = false) -> void:
	if isPlayer or beingDragged or isSleeping or shocked:
		return
	# у нескольких питомцев на экране — не все обязаны реагировать разом
	if not direct and gbData.data["saw"].size() > 1 and randf() < 0.5:
		return
	_queueMessage(text)

## 054.998: удалили последнего персонажа этого скина - его недоделанные
## наборы фраз больше не нужны (LLMManager.dropSkinJobs).
func _exit_tree() -> void:
	if isPlayer or not is_instance_valid(LLMManager):
		return
	var skin := _skinTag()
	for p in get_tree().get_nodes_in_group("pets"):
		if p != self and not p.is_queued_for_deletion() and p._skinTag() == skin:
			return
	LLMManager.dropSkinJobs(skin)


func _initalSpawn() -> void:
	#teag you can like guess what this does
	faceSys.setEmotion("default")
	#this specific line  is the reason why there was a bug in v0.1 and below where the face was permanantly in a shocked state
	#not the entire reason but its why it was locked into this emotion
	moveSys.sigragdoll.connect(shock)


	#this dont even work properly it always puts it somewhere else.
	moveSys.rigid.global_position.x = float(GlobalVariable.screenWidth) / 2
	moveSys.rigid.global_position.y = float(GlobalVariable.screenHeight) * 2

	#load the stats from the id (for presistance)
	moodSys.loadFromSave(petId)
	hungerHandler.loadFromSave(petId)
	healthHandler.loadFromSave(petId)
	sleepHandler.loadFromSave(petId)
	if isPlayer:
		moodSys.mood = PLAYER_MOOD # после загрузки сейва, иначе перезапишется шаблонным
	# зависимость от фентанила живёт только в пределах одного запуска
	gbData.data["saw"][petId].erase("addiction") # старое поле из 051 - убираем из сейва


	tempRagdoll()
	
	#initialized stuff

	wandering()
	passivetalk()
	checker()
	itemWatch()
	drugLoop()
	petTalkLoop()
	pass

## 054.998: засыпая, перс подпрыгивает со звуком - видно, что он уснул (Alex:
## "видный знак и выглядит забавно"). Раньше подскок был случайным (части тела
## получали скорость ходьбы), а приземление считалось ударом: урон и
## пробуждение - Вояджер уснула только с третьего раза. Теперь подскок всегда
## одинаковый, звук обычный (скулёж), а SLEEP_GRACE_MS после засыпания удары
## не считаются. Настоящий удар позже - будит, как раньше.
const SLEEP_HOP_SPEED := 260.0
const SLEEP_GRACE_MS := 3000
var _sleepGraceUntil := 0

func _sleepHop() -> void:
	_sleepGraceUntil = Time.get_ticks_msec() + SLEEP_GRACE_MS
	moveSys.rigid.linear_velocity = Vector2(0.0, -SLEEP_HOP_SPEED)
	moveSys.rigid.angular_velocity = 0.0
	AudioManager.play_random(voiceSet["whine"], 1.0, 0, 1, false, 0.5, "", "whine")


func sleep():
	_sleepHop()
	#handle sleeep loop this is probably one of the worst ways i couldve handled this ill fix it later
	while get_tree():
			#print("2")
			if not isSleeping:
				# Разбудили ударом (wakeUp) - тело уже в рэгдолле от удара,
				# дальше подъёмом занимается tempRagdoll(), здесь только
				# гасим "сонные" эффекты и выходим.
				sleepParticle.emitting = false
				break
			if sleepHandler.sleepCheck() < 5.0 and not _forcedSleep:
				#break if its below 10 (aka good enough to get up)
				sleepParticle.emitting = false
				moveSys.rigid.global_position = moveSys.rigidtorso.global_position
				moveSys.rigid.linear_velocity = Vector2.ZERO
				moveSys.rigid.freeze = false
				isSleeping = false
				moveSys.ragdoll(true)
				ragdolled = false
				break

				
			moveSys.rigid.freeze = true
			sleepParticle.emitting = true
			faceSys.setEmotion("sleep")
			moveSys.ragdoll(false)
			ragdolled = true
			sleepHandler.tiredness -= randf_range(0.05, 0.15)
			moodSys.mood += 0.025


			await get_tree().create_timer(tick / 7).timeout
	pass

func checker():
	while get_tree():
		#this was calling each function like 90 times per check which is why everyting was very extreme!
		#DONT DO THAT MISTAKE AGAIN!
		# Перс-игрок на автопилоте: еда и сон не тратятся. Настроение у игрока
		# отключено совсем (ровные 50) - меньше лишних расчётов и сохранений.
		var statsFrozen: bool = isPlayer and not playerControlled
		if not statsFrozen:
			hungerHandler.hungercheck()
		var sleepN = sleepHandler.tiredness if statsFrozen else sleepHandler.sleepCheck()
		var moodN = PLAYER_MOOD if isPlayer else moodSys.moodCheck(.5)
		if not shocked and not isSleeping:
			#sleep stuff
			currentEmotion = emotionz.normal
			if sleepN > 80.0:
				if !isTired:
					if randi() % 4 == 0:
						_say("sleepy")
				isTired = true
				currentEmotion = emotionz.tired
				print("tired")

				# После пробуждения ударом какое-то время не засыпаем снова
				var canSleep: bool = Time.get_ticks_msec() >= _noSleepUntil and not ragdolled and not (isPlayer and playerControlled)

				if sleepN > 94.5 and canSleep:
					# раньше флаг тут был локальной переменной и сбрасывался
					# каждый тик - "очень хочу спать" могло звучать каждые 5 сек
					if not _saidReallySleepy:
						_saidReallySleepy = true
						moveSys.initswithc(moveSys.states.resting)
						if randi() % 2 == 0:
							_say("reallySleepy")


				if sleepN > 95.0 and canSleep:
					isSleeping = true
					# всё, что успело встать в очередь до засыпания, уже неактуально
					_messageQueue.clear()
					_urgentInQueue = 0

					moveSys.rigidtorso.linear_velocity = Vector2(0, 0)
					print("sleeping")
					sleep()
			else:
				isTired = false
				_saidReallySleepy = false

			#isSad s	
			if moodN < -10.0:
				isSad = true
				if moodN < -30.0:
					currentEmotion = emotionz.sad
			else:
				isSad = false

			# "Счастливые" глаза у Expie/Voyager - закрытые дугой (часть спрайтов
			# цельная с головой), ходить так постоянно нелогично. Только при очень
			# высоком настроении; при поглаживании счастливое лицо включается само.
			if moodN > 85.0:
				currentEmotion = emotionz.happy

				#ungry
			if hungerHandler.hungry < 30.0:
				if !isHungry:
					_say("hungry")
					isHungry = true
				var r = randf_range(30.0 - hungerHandler.hungry, 40.0)
				#print("hunger notif chance ", r)
				if r > 38.0:
						_say("hungry")

			#update
			if not isUnconscious:
				faceSys.setEmotion(emotionz.keys()[currentEmotion])
		# 054.999: окошко по Ctrl - по-русски, целыми числами; зависимость - если есть.
		# Ломку не показываем (решение Alex: ломает погружение).
		statUpd.stat = {
			"Настроение": int(round(moodN)),
			"Сытость": int(round(hungerHandler.hungry)),
			"Усталость": int(round(sleepN)),
			"Здоровье": int(round(healthHandler.health)),
		}
		if addiction >= 1.0:
			statUpd.stat["Зависимость"] = int(round(addiction))
		statUpd.upd(statUpd.stat)

		await get_tree().create_timer(tick).timeout

func _physics_process(_delta: float) -> void:
	# игрок под управлением: направление и прыжок - с клавиатуры (PlayerManager)
	if isPlayer and playerControlled and not ragdolled and not isSleeping and not isUnconscious:
		# S - сесть, ещё раз S или движение/прыжок - встать
		var resting: bool = moveSys.currstate == moveSys.states.resting
		var sitPressed := _playerSit and not _playerSitPrev
		_playerSitPrev = _playerSit
		if resting and (sitPressed or _playerDir != 0.0 or _playerJump):
			moveSys.initswithc(moveSys.states.idle)
		elif sitPressed and (moveSys.currstate == moveSys.states.idle or moveSys.currstate == moveSys.states.moving):
			moveSys.dir = 0
			moveSys.forcedRestPose = 1
			moveSys.initswithc(moveSys.states.resting)
		moveSys.dir = _playerDir
		if _playerJump:
			moveSys.jump()
	#detect speed and aiosdhfopjkasfguopjasfgsdfhcvio[]
	#and ragdoll based on taht
	var vx: float = moveSys.rigid.linear_velocity.x
	# Собственная ходьба (идёт в ту же сторону, скорость лишь немного выше
	# порога) - не "сбита с ног". Настоящий толчок даёт скорость заметно выше.
	var ownWalk: bool = moveSys.currstate == moveSys.states.moving and signf(vx) == signf(moveSys.dir) and absf(vx) < moveSys.ragdollspeed * 1.3
	if not ragdolled and ((absf(vx) > moveSys.ragdollspeed and not ownWalk) or beingDragged):
		_bodyPrevValid = false
		if not beingDragged:
			print("KNOCK[%s] horizontal vx=%.0f state=%s" % [_skinTag(), moveSys.rigid.linear_velocity.x, moveSys.states.keys()[moveSys.currstate]])
		# 054.998: упёрся в ящик и споткнулся - падает, но без урона и крика.
		# Урон - только если сбил брошенный/летящий предмет.
		var hardFall: bool = not beingDragged and _hitByFlyingObject()
		tempRagdoll(hardFall, false, abs(moveSys.rigid.linear_velocity.x))
	elif not ragdolled:
		# Стоит на ногах: ловим жёсткое приземление (падение вертикально,
		# например с ящика) - раньше проверялась только горизонтальная
		# скорость, и падение сверху вниз не считалось вообще.
		var bodyVel: Vector2 = moveSys.rigid.linear_velocity
		if _bodyPrevValid and _spawnSettled:
			var hit := (_prevBodyVel - bodyVel).length()
			# рывок вверх от собственного прыжка (прыжок срабатывает в момент
			# касания пола, скорость "вниз" сразу становится "вверх") - не удар
			if Time.get_ticks_msec() - moveSys.lastJumpMsec < 150 or Time.get_ticks_msec() < _landingGraceUntil:
				hit = 0.0
			if hit >= IMPACT_LIGHT:
				_bodyPrevValid = false
				print("KNOCK[%s] landing hit=%.0f prev=%s now=%s state=%s" % [_skinTag(), hit, _prevBodyVel, bodyVel, moveSys.states.keys()[moveSys.currstate]])
				tempRagdoll(true, false, hit)
				return
		_prevBodyVel = bodyVel
		_bodyPrevValid = true

	if ragdolled:
		moveSys.dir = 0
		_bodyPrevValid = false
		_trackRagdollImpact()


## Пока персонаж лежит/летит рэгдоллом (после броска, падения, во сне) -
## смотрим, насколько резко затормозило туловище за этот кадр. Резкое
## торможение = удар о пол/стену/предмет. Пока его держат мышкой - не
## считаем (иначе любой рывок курсором был бы "ударом").
func _trackRagdollImpact() -> void:
	if beingDragged or isUnconscious:
		_impactPrevValid = false
		return
	var vel: Vector2 = moveSys.rigidtorso.linear_velocity
	if _impactPrevValid:
		var hit := (_prevTorsoVel - vel).length()
		if hit >= KNOCKOFF_IMPACT and _spawnSettled:
			_knockOffClothes()
		if hit >= IMPACT_LIGHT:
			_registerImpact(hit)
	_prevTorsoVel = vel
	_impactPrevValid = true


func _damageForImpact(speed: float) -> float:
	if speed >= IMPACT_HARD:
		return DAMAGE_HARD
	if speed >= IMPACT_MEDIUM:
		return DAMAGE_MEDIUM
	if speed >= IMPACT_LIGHT:
		return DAMAGE_LIGHT
	return 0.0


## Урон от удара (уже во время рэгдолла). Будит спящего персонажа.
func _registerImpact(speed: float) -> void:
	if isUnconscious or not _spawnSettled or Time.get_ticks_msec() < _spawnGraceUntil:
		return
	if isSleeping and Time.get_ticks_msec() < _sleepGraceUntil:
		return # приземление после подскока при засыпании - не удар
	var now := Time.get_ticks_msec()
	if now - _lastImpactMsec < IMPACT_COOLDOWN_MS:
		return
	var dmg := _damageForImpact(speed)
	if dmg <= 0.0:
		return
	_lastImpactMsec = now
	if LLMManager.debugTags:
		Console.print("[color=YELLOW]Удар: сила %.0f -> урон %.0f[/color]" % [speed, dmg])
	print("IMPACT[%s] hit=%.0f dmg=%.0f" % [_skinTag(), speed, dmg])
	if isSleeping:
		wakeUp()
	_impactThisRagdoll = true
	healthHandler.applyDamage(dmg)
	if not shocked:
		shock()


# ---------------- Одежда ----------------
## Предмет с "wearable" в propertyTable ("head" - шляпа/берет, "eyes" -
## очки) надевается, когда его подносят к голове. В каждый слот - одна вещь.
## Сильный удар (KNOCKOFF_IMPACT) сбивает одежду, она падает обратно
## предметом. Надетое держится только в пределах запуска.
##
## Позиции - в пикселях спрайта головы (26x18, лицом вправо), посчитаны по
## непрозрачным пикселям experimentHead.png/experimentEyeOpen.png:
## макушка ~ y -6.5, глаз ~ (0, 2). Для нового предмета без своей строки
## берётся позиция по слоту.
const WEAR_OFFSETS := {
	"hat": Vector2(-1.5, -6.0), # 054.9991: на пиксель ниже - сидели слишком высоко (Alex)
	"beret": Vector2(-1.5, -4.5),
	"glasses": Vector2(-1.5, 3.0),
}
const WEAR_SLOT_DEFAULT := {"head": "hat", "eyes": "glasses"}
const KNOCKOFF_IMPACT := 800.0 # слабее, чем порог урона - шляпу сбить проще, чем поранить
const CLOTHES_SITUATION := {
	"clothesOn": "На тебя только что надели: %s. Отреагируй - как тебе в этом, идёт ли тебе, нравится или раздражает.",
	"clothesOff": "От удара с тебя только что слетело: %s. Отреагируй на это.",
}
var _worn: Dictionary = {} # слот -> {"sprite": Sprite2D, "scene": путь сцены, "key": имя предмета}
var _wearCooldownUntil := 0 # только что слетевшая вещь не надевается обратно сама, пока лежит у головы


func _onWearableEnter(body: Node2D) -> void:
	if isUnconscious or Time.get_ticks_msec() < _wearCooldownUntil:
		return
	var propsNode = body.get_node_or_null("properties")
	if propsNode == null:
		return
	var slot: String = String(propsNode.propertyTable.get("wearable", ""))
	if slot == "" or _worn.has(slot):
		return
	var itemSprite := body.get_node_or_null("Sprite") as Sprite2D
	if itemSprite == null:
		return
	var key := _itemKey(body)
	var head: Node2D = healthHandler.mouth.get_parent() # RigidBodies/Head - одежда двигается и падает вместе с головой
	var worn := Sprite2D.new()
	worn.set_meta("worn", true) # _applyInjuryLook пропускает такие спрайты
	worn.texture = itemSprite.texture
	worn.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	worn.position = WEAR_OFFSETS.get(key, WEAR_OFFSETS[WEAR_SLOT_DEFAULT.get(slot, "hat")])
	head.add_child(worn)
	_worn[slot] = {"sprite": worn, "scene": body.scene_file_path, "key": key}
	# Вещь могут надевать прямо из руки: сначала отпускаем захват мышью
	# (его пружинный шарнир держится за это тело), и удаляем тело уже вне
	# текущего шага физики - удаление тела посреди шага физики/с живым
	# шарниром может уронить движок.
	var drag = body.get_node_or_null("draggable")
	if drag and drag._dragging:
		drag._stopDrag()
	body.hide()
	body.set_deferred("freeze", true)
	body.call_deferred("queue_free")
	_saySituational("clothesOn", key)


func _knockOffClothes() -> void:
	if _worn.is_empty():
		return
	_wearCooldownUntil = Time.get_ticks_msec() + 2500
	var lost := ""
	for slot in _worn.keys():
		if slot == "eyes" and randf() < 0.5:
			continue # очки сидят плотнее шляпы - слетают через раз
		var w: Dictionary = _worn[slot]
		var sprite: Sprite2D = w["sprite"]
		var pos: Vector2 = sprite.global_position
		sprite.queue_free()
		_worn.erase(slot)
		# Вызывается из _physics_process - добавлять новое физическое тело
		# прямо посреди шага физики нельзя, поэтому создаём вещь отложенно.
		call_deferred("_spawnDroppedItem", String(w["scene"]), pos, String(w["key"]))
		if lost == "":
			lost = w["key"]
	if lost != "":
		_saySituational("clothesOff", lost)


func _spawnDroppedItem(scenePath: String, pos: Vector2, key: String) -> void:
	if scenePath == "":
		return
	var scene: PackedScene = load(scenePath)
	if scene == null:
		return
	var item = scene.instantiate()
	var parentScene := get_tree().current_scene
	parentScene.add_child(item)
	# owner обязателен: dragObj при захвате мышью добавляет свой захват в
	# get_parent().owner - без owner там null, и взять вещь было нельзя
	# (у предметов из вкладки Items/команды spawn owner выставляется так же).
	item.owner = parentScene
	item.global_position = pos
	item.set_meta("itemName", key)
	_seenItems[item.get_instance_id()] = true # уже прозвучит clothesOff - отдельная реакция "предмет рядом" не нужна
	if item is RigidBody2D:
		item.linear_velocity = Vector2(randf_range(-250.0, 250.0), randf_range(-450.0, -250.0))
		item.angular_velocity = randf_range(-8.0, 8.0)


func _saySituational(category: String, key: String) -> void:
	var desc: String = ITEM_DESCRIPTIONS.get(key, key)
	_say(category, 0.0, true, CLOTHES_SITUATION[category] % desc, key)


func _wornDescription() -> String:
	var names: Array = []
	for slot in _worn.keys():
		names.append(ITEM_DESCRIPTIONS.get(_worn[slot]["key"], _worn[slot]["key"]))
	return ", ".join(names)


# ---------------- Фентанил ----------------
## Доза: сильный, но временный подъём настроения, после него - спад ниже
## исходного. Каждая доза добавляет зависимость (только на этот запуск),
## с ней следующие дозы действуют слабее, а без новой дозы начинается
## ломка. OVERDOSE_DOSES доз подряд (каждая в пределах DOSE_CHAIN_MS от
## предыдущей) - передозировка, отключка как при 0 ХП.
##
## 054.998, баланс по таблице с Alex (отчёт 054.997, пункт 19). Ломка после
## окончания прихода: 1 доза - нет, 2 дозы - ~20 мин, 3 - ~35 мин, максимум -
## ~65 мин. Поэтому у ломки два порога: начинается, только если зависимость
## дошла до WITHDRAWAL_START (от двух доз), а кончается ниже WITHDRAWAL_END.
## Задумка: дозами из ломки не выбраться ("зло от добра") - поддерживающая
## доза поднимает зависимость сильнее, чем снимает ломку, а еда и ласка
## помогают. Персонаж по-прежнему не колет себя сам.
const HIGH_DURATION_SEC := 300.0      # сколько держится эффект одной дозы
const HIGH_BOOST := 44.0              # прибавка к настроению у "чистого" персонажа (было 60)
const COMEDOWN_FRACTION := 0.3        # после эффекта настроение падает на эту долю от прибавки
const DOSE_MOOD_KEEP := 3.0           # навсегда остаётся в настроении от каждой дозы (как бинт)
const ADDICTION_PER_DOSE := 20.0
const ADDICTION_PER_DOSE_IN_WITHDRAWAL := 25.0 # поддерживающая доза
const ADDICTION_RELAPSE := 40.0       # первая доза после того, как ломка прошла: "организм помнит"
const ADDICTION_DECAY_PER_MIN := 1.33 # 100 -> 0 примерно за 75 мин
const WITHDRAWAL_START := 30.0
const WITHDRAWAL_END := 7.0
const HEAVY_ADDICTION := 70.0         # тяжёлая ломка: еда радует вдвое меньше, ласку отвергает чаще
const DOSE_CHAIN_MS := 300000         # дозы ближе друг к другу, чем это, считаются "подряд"
const OVERDOSE_DOSES := 4
# 054.9991 (тест 054.999: "слишком мало, перс будто забывает о зависимости"):
const WITHDRAWAL_LINE_MIN_MS := 180000  # отдельная фраза о ломке - раз в 3-6 мин (было 8-12)
const WITHDRAWAL_LINE_MAX_MS := 360000
const WITHDRAWAL_ANY_GAP_MS := 90000    # между ЛЮБЫМИ фразами о ломке - не меньше 1,5 мин (было 2)
const WITHDRAWAL_MENTION_CHANCE := 0.4  # ломка в фразах о состоянии и на экран (было 0.25)
const WITHDRAWAL_ASK_SITUATION := "У тебя ломка, а шприца с фентанилом нигде не видно. Ты прямо просишь человека принести и дать тебе дозу."
const TOSS_MIN_MS := 60000              # толкнуть шприц к человеку - раз в 1-2 мин
const TOSS_MAX_MS := 120000
const TOSS_LINE_GAP_MS := 180000        # фраза при толчке - не чаще раза в 3 мин
const FOOD_HELP_MS := 600000            # вкусная еда ускоряет спад зависимости 10 мин
const PET_HELP_MS := 120000             # после ласки падение настроения в ломке вдвое слабее 2 мин
var addiction := 0.0
var _dosesInRow := 0
var _lastDoseMsec := -10000000
var _highMs := int(HIGH_DURATION_SEC * 1000.0)
var _withdrawalActive := false
var _hadWithdrawal := false
var _nextWithdrawalLineMsec := 0
var _lastWithdrawalLineMsec := -10000000
var _nextTossMsec := 0
var _lastTossLineMsec := -10000000
var _foodHelpUntil := 0
var _foodHelpFactor := 1.0
var _petHelpUntil := 0


func _isHigh() -> bool:
	return Time.get_ticks_msec() - _lastDoseMsec < _highMs


func _inWithdrawal() -> bool:
	return _withdrawalActive and not _isHigh()


## Обновляет флаг ломки по двум порогам (вызывается при каждом изменении).
func _updateWithdrawalState() -> void:
	if not _withdrawalActive and addiction >= WITHDRAWAL_START and not _isHigh():
		_withdrawalActive = true
		_hadWithdrawal = true
		LLMManager._logDebugLine(_skinTag() + ":drug", "WITHDRAWAL", "началась, зависимость=%.0f" % addiction)
	elif _withdrawalActive and addiction < WITHDRAWAL_END:
		_withdrawalActive = false
		LLMManager._logDebugLine(_skinTag() + ":drug", "WITHDRAWAL", "прошла")


## Можно ли сейчас сказать фразу о ломке (общая пауза между всеми такими фразами).
func _withdrawalLineAllowed() -> bool:
	return Time.get_ticks_msec() - _lastWithdrawalLineMsec >= WITHDRAWAL_ANY_GAP_MS


func _sayWithdrawal(situation: String = "", poolSuffix: String = "") -> void:
	_lastWithdrawalLineMsec = Time.get_ticks_msec()
	_say("withdrawal", 0.0, true, situation, poolSuffix)


## Вызывается из health_handler.gd, когда шприц с фентанилом попал в персонажа.
func takeFentanyl() -> void:
	if isUnconscious:
		return
	var now := Time.get_ticks_msec()
	if now - _lastDoseMsec > DOSE_CHAIN_MS:
		_dosesInRow = 0
	_dosesInRow += 1
	var duringWithdrawal := _inWithdrawal()

	LLMManager._logDebugLine(_skinTag() + ":drug", "DOSE", "доза подряд=%d зависимость до=%.0f ломка=%s" % [_dosesInRow, addiction, "да" if duringWithdrawal else "нет"])
	if _dosesInRow >= OVERDOSE_DOSES:
		_lastDoseMsec = now
		dialogueSys.speedMod = 0.8
		_sayFinal("overdose")
		goUnconscious(false)
		return

	# поддерживающая доза в ломке - облегчение вдвое короче, зависимость растёт сильнее
	_highMs = int(HIGH_DURATION_SEC * 1000.0 * (0.5 if duringWithdrawal else 1.0))
	_lastDoseMsec = now
	var gain := ADDICTION_PER_DOSE
	if duringWithdrawal:
		gain = ADDICTION_PER_DOSE_IN_WITHDRAWAL
	elif _hadWithdrawal and not _withdrawalActive:
		gain = ADDICTION_RELAPSE # срыв: ломка уже прошла, а организм помнит
		_hadWithdrawal = false
	# чем сильнее зависимость, тем слабее эффект (толерантность)
	var boost: float = HIGH_BOOST / (1.0 + addiction / 40.0)
	moodSys.startDrugHigh(boost, _highMs / 1000.0, boost * COMEDOWN_FRACTION)
	moodSys.mood = clampf(moodSys.mood + DOSE_MOOD_KEEP, moodSys.minmood, maxf(moodSys.mood, minf(moodSys.maxmood, moodSys.woundMoodCap())))
	addiction = minf(100.0, addiction + gain)
	dialogueSys.speedMod = 0.8
	_say("fentanyl")


## Поел (hunger_handler.gd). Вкусное (7+) в ломке ускоряет спад зависимости:
## 7 -> на 15%, 10 -> на 25%, 10 минут после еды.
func onAte(taste: int) -> void:
	if taste >= 7 and addiction > 0.0:
		_foodHelpFactor = 1.0 + lerpf(0.15, 0.25, clampf((taste - 7) / 3.0, 0.0, 1.0))
		_foodHelpUntil = Time.get_ticks_msec() + FOOD_HELP_MS


## Раз в 30 сек: зависимость понемногу спадает сама, а в ломке настроение
## ползёт вниз и время от времени звучит фраза из withdrawal.
func drugLoop() -> void:
	while get_tree():
		await get_tree().create_timer(30.0).timeout
		if isUnconscious or isPlayer:
			continue # у игрока ломки нет
		var now := Time.get_ticks_msec()
		if addiction > 0.0:
			var decay := ADDICTION_DECAY_PER_MIN * 0.5
			if now < _foodHelpUntil:
				decay *= _foodHelpFactor
			addiction = maxf(0.0, addiction - decay)
		_updateWithdrawalState()
		if not _inWithdrawal():
			continue
		var drain := addiction * 0.02
		if now < _petHelpUntil:
			drain *= 0.5 # ласка смягчает ломку
		moodSys.mood = clampf(moodSys.mood - drain, moodSys.minmood, moodSys.maxmood)
		if now >= _nextWithdrawalLineMsec and _withdrawalLineAllowed() and not isSleeping and not beingDragged and not shocked:
			_nextWithdrawalLineMsec = now + randi_range(WITHDRAWAL_LINE_MIN_MS, WITHDRAWAL_LINE_MAX_MS)
			# шприца нигде нет - через раз прямо просит дозу у человека
			if _nearestFentanylAnywhere() == null and randf() < 0.5:
				_sayWithdrawal(WITHDRAWAL_ASK_SITUATION, "ask")
			else:
				_sayWithdrawal()


# ---------------- Игрок ----------------
func setPlayerControlled(on: bool) -> void:
	playerControlled = on
	moveSys.faceMoveDir = on # под управлением смотрит туда, куда идёт, а не на курсор
	if on:
		_forcedSleep = false
		_autopilotSleepAt = 0
		if isSleeping:
			wakeUp()
		if moveSys.currstate == moveSys.states.resting:
			moveSys.initswithc(moveSys.states.idle)
		wander = true
		moveSys.jumpCoolDown = 0.6
	else:
		_playerDir = 0.0
		_playerJump = false
		_playerSit = false
		moveSys.dir = 0
		moveSys.jumpCoolDown = 4.0
		_autopilotSleepAt = Time.get_ticks_msec() + randi_range(180000, 300000)


func playerInput(dir: float, jump: bool, sit: bool = false) -> void:
	_playerDir = dir
	_playerJump = jump
	_playerSit = sit


## Реплика, которую написал человек. Звук - обычный голос скина (whine).
func playerSay(text: String) -> void:
	if isUnconscious:
		return
	_recordSpoken(text) # во вкладку «Фразы»
	dialogueSys.setDia(text, 1.0, 2.0, true)
	AudioManager.play_random(voiceSet["whine"], 1.0, 0, 1, false, 0.5, "", "whine")


## ИИ-персонаж отвечает игроку - вне очереди, с учётом лора и состояния,
## без примеров из TRANSLATION.json.
func replyToPlayer(speaker: String, chatHistory: Array, onReply: Callable) -> void:
	if isPlayer or isUnconscious or isSleeping:
		return
	var stats := "настроение %.0f из 100, здоровье %.0f из 100, сытость %.0f из 100" % [
		moodSys.mood + moodSys.drugOffset, healthHandler.health, hungerHandler.hungry]
	if not _worn.is_empty():
		stats += ", на тебе надето: " + _wornDescription()
	var playerState := ""
	if PlayerManager.hasPlayer():
		var php: float = PlayerManager.player.healthHandler.health
		playerState = "здоровье %.0f из 100%s" % [php, ", тяжёлые раны" if php <= 30.0 else (", есть раны" if php <= 60.0 else "")]
	LLMManager.chatMood = moodSys.mood + moodSys.drugOffset # для тайны (secretBlock)
	LLMManager.chatPetId = petId
	LLMManager.requestChatReply(_skinTag(), speaker, chatHistory, stats + _aiStateHint(), _recentSpoken(), func(text: String):
		LLMManager.secretCheckReply(_skinTag(), petId, text)
		var action := ""
		if text.begins_with("<act:"):
			var close := text.find(">")
			action = text.substr(5, close - 5)
			text = text.substr(close + 1)
		elif chatHistory.size() > 0:
			# модель согласилась словами, но забыла метку - угадываем сами
			action = _guessChatAction(String(chatHistory[chatHistory.size() - 1].get("text", "")), text)
		_queueMessage(text, 1.0, true, PRIO_DIALOGUE)
		# голос при ответе: обычный, при плохом настроении - злой
		AudioManager.play_random(voiceSet["bark" if moodSys.mood < -20.0 else "whine"], 1.0, 0, 1, false, 0.5, "", "whine")
		onReply.call(text)
		if action != "":
			_doChatAction(action), "", PlayerManager.playerSkin, playerState)


## Запасной вариант, если в ответе нет метки действия: в реплике игрока есть
## просьба, а в ответе - согласие без отказа.
const CHAT_REQUEST_WORDS := {
	"come": ["подойди", "иди сюда", "иди ко мне", "ко мне", "сюда", "подходи"],
	"lie": ["ляг", "ложись", "ляжь", "приляг"],
	"sit": ["сядь", "садись", "присядь"],
	"stand": ["встань", "вставай"],
	"jump": ["прыгни", "прыгай"],
	"away": ["отойди", "отойти"],
}
const CHAT_YES_WORDS := ["иду", "бегу", "сейчас", "ладно", "хорошо", "так и быть", "давай", "уже", "подойду", "лягу", "сяду", "встаю", "прыгаю", "ок"]
const CHAT_NO_WORDS := ["нет", "не буду", "не хочу", "не пойду", "не стану", "ни за что", "отстань", "сам "]

func _guessChatAction(request: String, reply: String) -> String:
	var req := request.to_lower()
	var rep := " " + reply.to_lower() + " "
	for w in CHAT_NO_WORDS:
		if rep.contains(w):
			return ""
	var agreed := false
	for w in CHAT_YES_WORDS:
		if rep.contains(w):
			agreed = true
			break
	if not agreed:
		return ""
	for action in CHAT_REQUEST_WORDS.keys():
		for w in CHAT_REQUEST_WORDS[action]:
			if req.contains(w):
				return action
	return ""


## Случайный разговор двух ИИ-персонажей, стоящих рядом: один заговаривает,
## второй отвечает. Интервал между разговорами (общий на всех) - настройки
## petTalkMin/petTalkMax в секундах: вкладка Settings.
const PET_TALK_DISTANCE := 900.0 # пикс экрана при petSize 4
const PET_REPLY_PAUSE_MIN := 3.6 # пауза после того, как первый договорил, сек
const PET_REPLY_PAUSE_MAX := 6.3
static var _nextPetTalkMsec := -1

static func petTalkRange() -> Vector2:
	var lo: float = maxf(20.0, float(GlobalVariable.getNumFromString(str(gbData.settings.get("petTalkMin", "180")))))
	var hi: float = maxf(lo, float(GlobalVariable.getNumFromString(str(gbData.settings.get("petTalkMax", "360")))))
	return Vector2(lo, hi)


## 054.999: только что появившийся персонаж первую минуту не заводит разговоров,
## не комментирует предметы и экран и не болтает "сам по себе" - только фраза
## появления и реакции на действия. Раньше всё срабатывало разом (Вельвет:
## предметы рядом + игрок + Вояджер + фраза состояния - в первые секунды).
const SPAWN_QUIET_MS := 60000
var _quietUntil := 0

func isQuiet() -> bool:
	return Time.get_ticks_msec() < _quietUntil


func petTalkLoop() -> void:
	if _nextPetTalkMsec < 0: # первый разговор - не раньше минимума после запуска
		_nextPetTalkMsec = Time.get_ticks_msec() + int(petTalkRange().x * 1000.0)
	while get_tree():
		await get_tree().create_timer(randf_range(15.0, 30.0)).timeout
		if isPlayer or isUnconscious or isSleeping or beingDragged or ragdolled or shocked or isQuiet():
			continue
		if not gbData.settings.get("llmVisionEnabled", false) or gbData.settings.get("mutePassive", false):
			continue
		if Time.get_ticks_msec() < _nextPetTalkMsec:
			continue
		var other = _nearestTalkPartner()
		# 054.99: перс-игрок рядом - иногда заговариваем с ним (тот же интервал)
		var playerNear: Node = _playerNearForTalk()
		if playerNear != null and (other == null or randf() < 0.5):
			var playerTalkRange := petTalkRange()
			_nextPetTalkMsec = Time.get_ticks_msec() + int(randf_range(playerTalkRange.x, playerTalkRange.y) * 1000.0)
			_talkToPlayer(playerNear)
			continue
		if other == null:
			continue
		var talkRange := petTalkRange()
		_nextPetTalkMsec = Time.get_ticks_msec() + int(randf_range(talkRange.x, talkRange.y) * 1000.0)
		var otherSkin: String = other._skinTag()
		# всего реплик в разговоре (вместе с первой): раньше всегда ровно 2
		var turns := randi_range(PET_TALK_TURNS_MIN, PET_TALK_TURNS_MAX)
		LLMManager.requestPetOpener(_skinTag(), otherSkin, _petStats() + _aiStateHint(), func(line: String):
			_queueMessage(line, 1.0, true, PRIO_DIALOGUE)
			AudioManager.play_random(voiceSet["whine"], 1.0, 0, 1, false, 0.5, "", "whine")
			notePetLine(other, PlayerManager.displayNameFor(_skinTag()), line)
			if is_instance_valid(other):
				other.replyToPet(self, line, turns - 1), _petTalkWith(other), other._petStats())


## Память разговоров с другими ИИ-персами: у каждого перса своя, по каждому
## собеседнику отдельно (ключ - petId собеседника). Раньше ответ видел только
## одну последнюю реплику, и каждый разговор начинался с нуля.
const PET_TALK_MEMORY := 10
var _petTalkHistory: Dictionary = {}

func _petTalkWith(other: Node) -> Array:
	return (_petTalkHistory.get(String(other.petId), []) as Array).duplicate()


func notePetLine(other: Node, who: String, text: String) -> void:
	if not is_instance_valid(other):
		return
	var key := String(other.petId)
	var h: Array = _petTalkHistory.get(key, [])
	h.append({"who": who, "text": text})
	while h.size() > PET_TALK_MEMORY:
		h.pop_front()
	_petTalkHistory[key] = h


func _nearestTalkPartner() -> Node:
	var maxDist: float = PET_TALK_DISTANCE * float(gbData.settings.get("petScale", 4.0)) / 4.0
	for pet in get_tree().get_nodes_in_group("pets"):
		if pet == self or pet.isPlayer or pet.isUnconscious or pet.isSleeping or pet.isQuiet():
			continue
		if moveSys.rigidtorso.global_position.distance_to(pet.moveSys.rigidtorso.global_position) < maxDist:
			return pet
	return null


## Перс-игрок рядом и может слушать (не спит, не без сознания).
func _playerNearForTalk() -> Node:
	if not PlayerManager.hasPlayer():
		return null
	var p: Node = PlayerManager.player
	if p == self or p.isUnconscious or p.isSleeping:
		return null
	var maxDist: float = PET_TALK_DISTANCE * float(gbData.settings.get("petScale", 4.0)) / 4.0
	if moveSys.rigidtorso.global_position.distance_to(p.moveSys.rigidtorso.global_position) < maxDist:
		return p
	return null


func _talkToPlayer(p: Node) -> void:
	var key := String(petId)
	var myName: String = PlayerManager.displayNameFor(_skinTag())
	var history: Array = (PlayerManager.histories.get(key, []) as Array).duplicate()
	var playerState: String = p._petStats() if is_instance_valid(p) else ""
	LLMManager.requestPlayerOpener(_skinTag(), PlayerManager.playerSkin, _petStats() + _aiStateHint(), history, playerState, func(line: String):
		if line.begins_with("<act:"):
			line = line.substr(line.find(">") + 1)
		if isUnconscious or isSleeping or not is_inside_tree():
			return
		_queueMessage(line, 1.0, true, PRIO_DIALOGUE)
		AudioManager.play_random(voiceSet["whine"], 1.0, 0, 1, false, 0.5, "", "whine")
		PlayerManager._remember(key, myName, line)) # ответ через Enter увидит, с чего начали


## Стоит ли этот собеседник всё ещё рядом (для продолжения разговора).
func _nearestTalkPartnerIs(other: Node) -> bool:
	if not is_instance_valid(other):
		return false
	var maxDist: float = PET_TALK_DISTANCE * float(gbData.settings.get("petScale", 4.0)) / 4.0 * 1.5 # отойти чуть дальше - можно
	return moveSys.rigidtorso.global_position.distance_to(other.moveSys.rigidtorso.global_position) < maxDist


func _petStats() -> String:
	var hp: float = healthHandler.health
	var wound := ", тяжёлые раны" if hp <= 30.0 else (", есть раны" if hp <= 60.0 else "")
	return "настроение %.0f из 100, здоровье %.0f из 100%s" % [moodSys.mood + moodSys.drugOffset, hp, wound]


## Ответ другому ИИ-персонажу (вызывает его petTalkLoop).
## turnsLeft - сколько реплик в разговоре ещё осталось, считая этот ответ.
## Если больше одной - собеседник ответит на ответ, и так по очереди.
const PET_TALK_TURNS_MIN := 2
const PET_TALK_TURNS_MAX := 6
func replyToPet(speaker: Node, line: String, turnsLeft: int = 1) -> void:
	if turnsLeft < 1 or isPlayer or isUnconscious or isSleeping or isQuiet() or not is_instance_valid(speaker):
		return
	# разговор обрывается, если кого-то схватили, уронили или он отошёл
	if beingDragged or ragdolled or shocked or _nearestTalkPartnerIs(speaker) == false:
		return
	var speakerSkin: String = speaker._skinTag()
	var speakerName: String = PlayerManager.displayNameFor(speakerSkin)
	var myName: String = PlayerManager.displayNameFor(_skinTag())
	notePetLine(speaker, speakerName, line)
	var talk: Array = _petTalkWith(speaker)
	# Ответ генерируется сразу, но показывается не раньше, чем собеседник
	# допечатает свою фразу (~0.04 с на букву, x8 на знаках препинания) + пауза -
	# иначе реплики шли почти впритык.
	var showAt: int = Time.get_ticks_msec() + int((line.length() * 0.054 + randf_range(PET_REPLY_PAUSE_MIN, PET_REPLY_PAUSE_MAX)) * 1000.0)
	var onReply := func(text: String):
		if text.begins_with("<act:"):
			text = text.substr(text.find(">") + 1) # действия - только по просьбе игрока
		var wait: int = showAt - Time.get_ticks_msec()
		if wait > 0:
			await get_tree().create_timer(wait / 1000.0).timeout
		if isUnconscious or isSleeping or not is_inside_tree():
			return
		_queueMessage(text, 1.0, true, PRIO_DIALOGUE)
		AudioManager.play_random(voiceSet["whine"], 1.0, 0, 1, false, 0.5, "", "whine")
		notePetLine(speaker, myName, text)
		if is_instance_valid(speaker):
			speaker.notePetLine(self, myName, text) # собеседник тоже запоминает ответ
			if turnsLeft > 1:
				speaker.replyToPet(self, text, turnsLeft - 1)
	LLMManager.requestChatReply(_skinTag(), speakerName, talk, _petStats() + _aiStateHint(), _recentSpoken(), onReply, speakerSkin, "", speaker._petStats())


## Действие, на которое ИИ-персонаж сам согласился в разговоре с игроком.
var _commandUntil := 0 # пока выполняется просьба игрока - обычные прогулки ждут

func _doChatAction(action: String) -> void:
	if isUnconscious or isSleeping or ragdolled:
		return
	print("CHAT ACTION[%s]: %s" % [_skinTag(), action])
	_commandUntil = Time.get_ticks_msec() + 15000
	match action:
		"come", "away":
			if moveSys.currstate == moveSys.states.resting:
				moveSys.initswithc(moveSys.states.idle)
			wander = true
			var px: float = PlayerManager.player.moveSys.rigid.global_position.x if PlayerManager.hasPlayer() else moveSys.rigid.get_global_mouse_position().x
			var x: float = moveSys.rigid.global_position.x
			var target := px - signf(px - x) * 110.0 # подойти, но не вплотную
			if action == "away":
				target = x - signf(px - x) * 400.0
			target = clampf(target, 60.0, float(GlobalVariable.screenWidth) - 60.0)
			await _walkTo(target, true)
		"lie", "sit":
			moveSys.dir = 0
			moveSys.forcedRestPose = 2 if action == "lie" else 1
			moveSys.initswithc(moveSys.states.resting)
		"stand":
			if moveSys.currstate == moveSys.states.resting:
				moveSys.initswithc(moveSys.states.idle)
				wander = true
		"jump":
			moveSys.jump()
	_commandUntil = 0


func _forceSleep() -> void:
	if isSleeping or isUnconscious:
		return
	_autopilotSleepAt = 0
	isSleeping = true
	_forcedSleep = true
	_messageQueue.clear()
	_urgentInQueue = 0
	moveSys.rigidtorso.linear_velocity = Vector2.ZERO
	if isPlayer:
		PlayerManager._showStatus("Игрок уснул (автопилот) - %s, чтобы разбудить" % PlayerManager.currentKeys())
	sleep()


## Разбудить спящего (сейчас - только от урона). Усталость остаётся какой
## была, просто персонаж какое-то время не может снова заснуть.
func wakeUp() -> void:
	if not isSleeping:
		return
	isSleeping = false # sleep() увидит это на следующей итерации и выйдет сам
	sleepParticle.emitting = false
	_noSleepUntil = Time.get_ticks_msec() + WAKE_NO_SLEEP_MS
	tempRagdoll(false) # долежать удар и встать обычным путём


"""

green because it needs to catch my attention
PLEASE FUCKING RECODE BOTH OF THESE

"""
func shock() -> void:
	if isUnconscious or beingDragged or isSleeping or Time.get_ticks_msec() < _spawnGraceUntil:
		# screamBIG - только настоящий удар/падение, не обычное хватание мышкой
		# и не самый первый спавн. isSleeping: засыпая, sleep() сам переводит
		# тело в рэгдолл, а это шлёт тот же сигнал sigragdoll, что и падение -
		# раньше персонаж из-за этого вскрикивал, просто укладываясь спать.
		# (Если удар будит спящего, wakeUp() снимает isSleeping ДО вызова shock.)
		return
	shocked = true
	moodSys._tempVal(-5.0, 15)
	moodSys.mood -= 2.5
	faceSys.setEmotion("panic")

	dialogueSys.speedMod = 1.3
	_say("screamBIG")
	AudioManager.play_random(voiceSet["whine"], 1.0, 0, 1, false, 0.5, "", "whine")
	await get_tree().create_timer(2).timeout
	faceSys.setEmotion("scared")
	await get_tree().create_timer(5).timeout
	faceSys.setEmotion("sad")
	await get_tree().create_timer(13).timeout


	shocked = false

func tempRagdoll(isHardFall: bool = false, silent: bool = false, impactSpeed: float = 0.0) -> void:
	_impactThisRagdoll = false
	_impactPrevValid = false
	ragdolled = true # заранее: урон ниже может вызвать goUnconscious(), а тот не должен запускать второе падение
	if isHardFall and not isUnconscious and _spawnSettled and Time.get_ticks_msec() >= _spawnGraceUntil:
		# Урон и обновление спрайтов - сразу в момент падения/удара, а не
		# позже, когда персонаж уже встаёт и говорит. Раньше оба совпадали
		# по времени с репликой, что на глаз незаметно для одних лишь цифр
		# ХП, но было бы явно видно на уровне смены спрайтов тела.
		# ВАЖНО: раньше тут стояла проверка launchflag, а не грейс-период -
		# из-за этого урон не засчитывался вообще ни разу, пока персонаж не
		# завершит хотя бы один цикл "встал" после спавна (launchflag
		# становился true только в конце этой же функции).
		# Сбить с ног может и слабый толчок - урон только если удар
		# дотягивает хотя бы до лёгкого порога.
		var dmg: float = _damageForImpact(impactSpeed)
		if impactSpeed >= KNOCKOFF_IMPACT:
			_knockOffClothes()
		if LLMManager.debugTags:
			Console.print("[color=YELLOW]Сбита с ног: сила %.0f -> урон %.0f[/color]" % [impactSpeed, dmg])
		if dmg > 0.0:
			_lastImpactMsec = Time.get_ticks_msec()
			_impactThisRagdoll = true
			healthHandler.applyDamage(dmg)
	moveSys.ragdoll(false)
	ragdolled = true
	moveSys.rigid.collision_layer = 0
	moveSys.rigid.collision_mask = 0
	moveSys.rigid.freeze = true
	_dragEscalationLevel = 0
	_playerDragSoundAt = Time.get_ticks_msec() + int(PLAYER_DRAG_SOUND_MIN * 1000.0) # звук захвата уже прозвучал
	while true:
		var aiOn: bool = gbData.settings.get("llmVisionEnabled", false)
		var waitTime: float = randf_range(10.0, 15.0) if aiOn else (getUpTimer + randf_range(0, 5))
		if isPlayer:
			waitTime = 1.5 # игроку незачем ждать ИИ-реплик - встаёт почти сразу
		await get_tree().create_timer(waitTime).timeout
		if beingDragged:
			# у игрока цикл крутится раз в 1.5 с (чтобы быстро вставать), но звук
			# "меня держат" от этого шёл каждые 1.5 с - для игрока он реже
			var playerSoundDue := true
			if isPlayer:
				playerSoundDue = Time.get_ticks_msec() >= _playerDragSoundAt
				if playerSoundDue:
					_playerDragSoundAt = Time.get_ticks_msec() + int(randf_range(PLAYER_DRAG_SOUND_MIN, PLAYER_DRAG_SOUND_MAX) * 1000.0)
			if not isSleeping and not isUnconscious and playerSoundDue:
				if aiOn:
					_dragEscalationLevel += 1
					var idx: int = mini(_dragEscalationLevel - 1, DRAG_STAGE_DESCRIPTIONS.size() - 1)
					var key := "drag_level%d" % idx
					# Falls back to an empty array if the skin's translation
					# doesn't have this key yet - fully backward compatible,
					# these categories ran with zero examples before this.
					var examples: Array = _pickExamples(dialogueSys.data.get(key, []).duplicate(), 8)
					if not isPlayer:
						LLMManager.requestPooledEvent(_skinTag() + ":" + key, DRAG_STAGE_DESCRIPTIONS[idx], _on_drag_reaction, examples)
					# больше шипения (bark), чем дальше затягивается захват
					AudioManager.playVoiceWeighted(voiceSet, minf(0.95, 0.75 + 0.2 * idx), 0.3)
				else:
					AudioManager.play_random(voiceSet["whine"], 1.0, 0, 1, false, 0.5, "", "whine")
					if not isPlayer:
						dialogueSys.pool = dialogueSys.data.get("beingDragged", [])
						dialogueSys.send(10, false)
			#fix the weird ghost collision during ragdoll
			continue
		# 054.99: ниже CRITICAL_HEALTH_THRESHOLD - лежит в сознании, пока не
		# подлечится. Раньше вставал и тут же оседал, а подъём тела засчитывался
		# как удар: "упал" каждые 10-15 с и новый урон, здоровье не росло.
		if not isUnconscious and healthHandler.health > 0.0 and healthHandler.health < CRITICAL_HEALTH_THRESHOLD:
			continue
		if moveSys.rigidtorso.linear_velocity.length() > 10.0:
			continue
		break
	_spawnSettled = true # первое падение после спавна закончилось - дальше урон считается как обычно
	if isUnconscious:
		# 0 хп - персонаж остаётся в физическом рэгдолле навсегда (до
		# перезапуска приложения). Ragdoll(false) уже включён в начале
		# функции и не отменяется - просто никогда не восстанавливаем
		# управление/collision и не доходим до реплики "встал".
		return
	moveSys.rigid.collision_layer = 2
	moveSys.rigid.collision_mask = 1
	moveSys.rigid.freeze = false
	moveSys.rigid.linear_velocity.x = 0.0
	moveSys.rigid.linear_velocity.y = 0.0
	moveSys.rigid.global_position.x = moveSys.rigidtorso.global_position.x
	moveSys.rigid.global_position.y = moveSys.rigidtorso.global_position.y
	moveSys.ragdoll(true)
	# тело только что поставили на высоту туловища - его опускание на пол не удар
	_landingGraceUntil = Time.get_ticks_msec() + LANDING_GRACE_MS
	_bodyPrevValid = false

	ragdolled = false
	await get_tree().create_timer(getUpTimerMsg).timeout
	moveSys.initswithc(moveSys.states.idle)
	var _upCategory := "start"
	if launchflag:
		if isHardFall or _impactThisRagdoll:
			_upCategory = "fell"
		elif not pet_timer.is_stopped() and pet_count >= 5:
			_upCategory = "getUpPet"
		else:
			_upCategory = "getUp"
	dialogueSys.speedMod = 1.3
	if silent:
		pass # низкое ХП - персонаж не может по-настоящему встать, повторять реплику вставания на каждом цикле не нужно
	elif _upCategory == "start":
		# Fires exactly once, right at launch - by the time an AI-generated
		# pool for it would be ready (a minute or more into warmup), the
		# moment has already passed. Speak straight from the file instead -
		# instant, and frees up a prewarm slot for a category that actually
		# gets reused and benefits from AI variation.
		# Routed through _queueMessage (not dialogueSys.send() directly) so
		# it respects "something is already typing" like everything else -
		# dialogueSys.send()'s default args skip that check entirely, and
		# start can otherwise land mid-launch alongside passivetalk() etc.
		if dialogueSys.data.get("start", []).size() > 0 and not isPlayer:
			_queueMessage(dialogueSys.data.get("start", []).pick_random(), dialogueSys.speedMod)
	else:
		_say(_upCategory)
	if not silent:
		AudioManager.play_random(voiceSet["whine"], 1.0, 0, 1, false, 0.5, "", "whine")
	launchflag = true
	pet_count = 0
	pet_timer.stop()

	# "Чем больше можно нанести увечий, тем меньше пользователей позволят
	# себе это сделать" - ниже CRITICAL_HEALTH_THRESHOLD персонаж не
	# способен по-настоящему подняться: он снова обмякает почти сразу,
	# но остаётся в сознании (реплику вставания при этом не повторяет -
	# см. silent=true ниже, чтобы не долбить одной и той же фразой на
	# каждом цикле). isHardFall=false здесь намеренно - это не новый удар,
	# а неспособность встать, доп. урон не нужен. Окно короткое (1-3 сек) -
	# персонаж едва успевает подняться, а не расхаживает секундами до
	# следующего обмякания. Останавливается либо когда здоровье
	# восстановится выше порога, либо насовсем при потере сознания.
	if not isUnconscious and healthHandler.health > 0.0 and healthHandler.health < CRITICAL_HEALTH_THRESHOLD:
		await get_tree().create_timer(randf_range(1.0, 3.0)).timeout
		if not isUnconscious and healthHandler.health < CRITICAL_HEALTH_THRESHOLD:
			tempRagdoll(false, true)


## Реакции на предметы рядом - "динамические", как экранные: каждый раз
## живой запрос к ИИ без заготовленного пула. Свой цикл, но с теми же
## интервалами, что у обычных фраз (minDialogueTime/maxDialogueTime).
## Один и тот же предмет комментируется не чаще раза в ITEM_REPEAT_MS.
##
## Почему раньше крашилось: вкладка Items записывала в предмет meta
## "itemName" не имя, а служебный объект ItemEntry, а этот код читал его
## в переменную типа String. Теперь предмет опознаётся по имени его файла
## сцены (burger.tscn -> "burger"), meta вообще не нужна.
## Реакция - только на предмет, который ВПЕРВЫЕ оказался рядом (положили,
## подкатился, персонаж сам подошёл), а не по таймеру на всё подряд:
## раньше при куче предметов персонаж находил "ещё не обсуждённый" почти
## каждый интервал. Плюс общий перерыв между любыми реакциями на предметы
## и отдельный - на повтор того же самого предмета.
const ITEM_NEAR_DISTANCE := 600.0 # пикс экрана при petSize 4 - что считается "рядом"
const ITEM_GLOBAL_COOLDOWN_MS := 180000 # между любыми реакциями на предметы
const ITEM_REPEAT_MS := 900000 # тот же предмет (по имени) - не чаще
var _itemCommentedAt: Dictionary = {} # имя предмета -> когда последний раз комментировали
var _seenItems: Dictionary = {} # instance_id предмета -> уже был рядом (новым не считается)
var _lastItemReactionMsec := -ITEM_GLOBAL_COOLDOWN_MS

func itemWatch() -> void:
	var firstScan := true
	while get_tree():
		await get_tree().create_timer(3.0).timeout
		var fresh: Array = []
		for body in _nearbyItemBodies():
			var id: int = body.get_instance_id()
			if _seenItems.has(id):
				continue
			_seenItems[id] = true
			if not firstScan: # то, что уже лежало рядом при появлении персонажа, - не "новое"
				fresh.append(body)
		firstScan = false
		if fresh.is_empty() or isPlayer or isQuiet():
			continue
		if not gbData.settings.get("llmVisionEnabled", false) or gbData.settings.get("mutePassive", false):
			continue
		if beingDragged or isSleeping or shocked or isUnconscious or ragdolled:
			continue
		var now := Time.get_ticks_msec()
		if now - _lastItemReactionMsec < ITEM_GLOBAL_COOLDOWN_MS:
			continue
		var key := ""
		for body in fresh:
			var k := _itemKey(body)
			if now - int(_itemCommentedAt.get(k, -ITEM_REPEAT_MS)) >= ITEM_REPEAT_MS:
				key = k
				break
		if key == "":
			continue
		_itemCommentedAt[key] = now
		_lastItemReactionMsec = now
		var extra := ""
		if _isFoodKey(key):
			# 054.998: у каждого персонажа свои вкусы (паспорт, поле tastes)
			var taste := tasteFor(key, 5)
			extra = "\nНа вкус для тебя это " + ("очень вкусно." if taste >= 7 else ("противно." if taste <= 3 else "так себе, обычная еда."))
			if hungerHandler.hungry < 30.0:
				extra += "\nТы {голодна|голоден}." # было "Ты голодна." и для мужских персонажей
		LLMManager.requestItemReaction(_skinTag(), _itemDesc(key), _aiStateHint() + extra, _on_state_reaction)


## Знакомые предметы (есть в ITEM_DESCRIPTIONS) в радиусе ITEM_NEAR_DISTANCE.
func _nearbyItemBodies() -> Array:
	var result: Array = []
	var maxDist: float = ITEM_NEAR_DISTANCE * float(gbData.settings.get("petScale", 4.0)) / 4.0
	for body in detectRange.inRadius.keys():
		if not is_instance_valid(body):
			continue
		if _itemDesc(_itemKey(body)) == "":
			continue
		if moveSys.rigidtorso.global_position.distance_to(body.global_position) < maxDist:
			result.append(body)
	return result


## Имя предмета по файлу его сцены ("res://scenes/objects/burger.tscn" -> "burger").
func _itemKey(body: Node) -> String:
	if body.scene_file_path != "":
		return body.scene_file_path.get_file().get_basename()
	var meta = body.get_meta("itemName", "")
	return meta if meta is String else ""


## 054.998: вкус еды для ЭТОГО персонажа - из паспорта (tastes), а если там
## нет - вкус самого предмета. Дюне и Вельвет жёлтая плоть - 10, Розе хлеб - 2...
func tasteFor(key: String, itemTaste: int) -> int:
	var tastes = LLMManager.passport(_skinTag()).get("tastes", {})
	if tastes is Dictionary and tastes.has(key):
		return int(tastes[key])
	return itemTaste


func _isFoodKey(key: String) -> bool:
	return key in ["bread", "pizzaslice", "burger", "banana", "juicedobry", "geofruit", "yellowflesh"] or CustomItems.isFood(key)


## Описание предмета для ИИ: встроенные (ITEM_DESCRIPTIONS) и пользовательские
## (CustomItems, ключ "custom:<id>"). "" - незнакомый предмет.
func _itemDesc(key: String) -> String:
	if ITEM_DESCRIPTIONS.has(key):
		return ITEM_DESCRIPTIONS[key]
	return CustomItems.describe(key)


## Состояние персонажа для ИИ-реакций (предметы, экран): настроение,
## здоровье и степень фентанилового опьянения/ломки.
func _drugLevel() -> int:
	if _isHigh():
		return 2 if moodSys.drugOffset > 30.0 else 1
	# 054.998: ломка упоминается примерно в каждой четвёртой фразе (была в каждой)
	if _inWithdrawal() and randf() < WITHDRAWAL_MENTION_CHANCE:
		return -1
	return 0


func _aiStateHint() -> String:
	return LLMManager.stateHint(moodSys.mood + moodSys.drugOffset, healthHandler.health, _drugLevel())


# periodically send a message based on mood
func passivetalk() -> void:
	while true:
		if isPlayer:
			await get_tree().create_timer(5.0).timeout
			continue
		if isQuiet():
			await get_tree().create_timer(5.0).timeout
			continue
		if !gbData.settings.get("mutePassive", false):
			var diaTimerMinimum = float(GlobalVariable.getNumFromString(str(gbData.settings["minDialogueTime"])))

			var diaTimerMaximum = float(GlobalVariable.getNumFromString(str(gbData.settings["maxDialogueTime"])))

			# 054.99: чем сильнее ранен, тем чаще говорит (и чаще - о самочувствии)
			var hp: float = healthHandler.health
			var woundTier := _woundTier(hp)
			var pace: float = [1.0, 0.8, 0.55, 0.35][woundTier]
			await get_tree().create_timer(randf_range(float(diaTimerMinimum), float(diaTimerMaximum)) * pace).timeout
			if not beingDragged and not isSleeping and not shocked:
				dialogueSys.pool = dialogueSys.data.get("Passive", [])
				match currentEmotion:
					emotionz.normal:
						dialogueSys.pool = dialogueSys.data.get("Passive", [])
					emotionz.happy:
						dialogueSys.pool = dialogueSys.data.get("HappyPassive", [])
					emotionz.sad:
						#oops
						dialogueSys.pool = dialogueSys.data.get("LowPassive", [])
						if moodSys.mood < -30.0:
							dialogueSys.pool = dialogueSys.data.get("VeryLowPassive", [])


				dialogueSys.speedMod = 1.0
				if gbData.settings.get("llmVisionEnabled", false):
					var statLine := "настроение %.0f из 100, сытость %.0f из 100, усталость %.1f, здоровье %.0f из 100" % [
						moodSys.mood,
						hungerHandler.hungry,
						sleepHandler.tiredness,
						gbData.data["saw"][petId]["health"]
					]
					if _isHigh():
						statLine += ", ты под действием фентанила - тебе слишком хорошо и всё плывёт"
					elif _inWithdrawal() and randf() < WITHDRAWAL_MENTION_CHANCE:
						statLine += ", у тебя ломка - тебе плохо без фентанила"
					if not _worn.is_empty():
						statLine += ", на тебе надето: " + _wornDescription()
					# при ранах - чаще о самочувствии (а примеры - из грустных фраз)
					var woundFocus := ""
					woundTier = _woundTier(healthHandler.health)
					if woundTier > 0 and randf() < [0.0, 0.35, 0.6, 0.85][woundTier]:
						woundFocus = WOUND_FOCUS[woundTier]
						var sadPool: Array = dialogueSys.data.get("VeryLowPassive" if woundTier == 3 else "LowPassive", [])
						if not sadPool.is_empty():
							dialogueSys.pool = sadPool
					var examples: Array = _pickExamples(dialogueSys.pool.duplicate(), 10)
					LLMManager.requestStateReaction(statLine, examples, _on_state_reaction, _skinTag() + ":state", woundFocus)
				else:
					dialogueSys.send()
		else:
			await get_tree().create_timer(5.0).timeout
			
func _on_drag_reaction(text: String) -> void:
	if isSleeping or isPlayer:
		return
	_queueMessage(text, 1.0, true)


## 0 - цел (70+), 1 - лёгкие ушибы (45-70), 2 - ранен (20-45), 3 - тяжело (<20)
func _woundTier(hp: float) -> int:
	if hp < CRITICAL_HEALTH_THRESHOLD:
		return 3
	if hp < 45.0:
		return 2
	if hp < 70.0:
		return 1
	return 0

const WOUND_FOCUS := [
	"",
	"У тебя лёгкие ушибы и царапины - можешь мимоходом упомянуть, что немного побаливает.",
	"Ты {ранена|ранен}, тебе больно и плохо - скажи о своём самочувствии или попроси человека помочь (бинт, аптечка), в своём характере.",
	"У тебя тяжёлые раны, ты лежишь и не можешь встать, сама по себе рана не заживёт - тебе очень плохо и страшно. Скажи об этом коротко и тяжело: пожалуйся, или попроси человека помочь, или прямо скажи, что без его помощи не встанешь.",
]


func _on_state_reaction(text: String) -> void:
	if isPlayer or beingDragged or isSleeping or shocked:
		return
	_queueMessage(text)


## Speaks from `category` (a key in dialogueSys.data, e.g. "sleepy", "pet",
## "petReject", "getUp"...). If the AI is on, asks it to blend a few example
## lines from that category into something fresh; otherwise falls back to
## the normal random pick - so behavior is identical to before when the AI
## is off. cooldown/ignoreCooldown match dialogueSys.send()'s own params.
## Categories that should sound louder/more physical - a bit of emphasis
## (occasional CAPS on a word, sharper tone) fits the moment better than the
## usual calm delivery.
## Какие фразы может сказать сам персонаж-игрок (только голод и боль).
## Эти фразы у ИИ-персов тоже берутся прямо из файла (без ИИ-пула).
const FILE_ONLY_CATEGORIES := ["lastmoments"]
const PLAYER_FILE_CATEGORIES := ["hungry", "LightDamage", "MediumDamage", "HardDamage", "lastmoments"]
const LOUD_CATEGORIES := ["getUp", "getUpPet", "fell", "screamBIG", "LightDamage", "MediumDamage", "HardDamage"]

## Maps a spawned item's "itemName" meta to a human description for the AI.
## To support a new item, just add one line here - nothing else needs to
## change, no matter how many items exist.
## Ключ - имя файла сцены предмета в scenes/objects/ (без .tscn).
const ITEM_DESCRIPTIONS := {
	"bandage": "бинт",
	"syringe": "шприц с красным лекарством, который лечит",
	"medkit": "аптечка",
	"medcrate": "медицинский ящик с аптечкой",
	"bread": "хлеб",
	"pizzaslice": "кусок пиццы",
	"burger": "бургер",
	"banana": "банан",
	"juicedobry": "пакет яблочного сока 'Добрый'",
	"geofruit": "странный минеральный фрукт, наполовину похожий на камень",
	"yellowflesh": "кусок жёлтой плоти - мясо существ, похожих на савиан (таких, как ты и твои соседи)",
	"containercrate": "обычный ящик с припасами",
	"sawblade": "ржавое лезвие циркулярной пилы",
	"fentanyl": "шприц с сине-белой жидкостью - фентанил",
	"chair": "деревянный стул",
	"nightstand": "прикроватная тумбочка с ящиками",
	"hat": "шляпа",
	"beret": "берет",
	"glasses": "прозрачные очки",
}


## Categories that are a reaction to something sudden happening right now -
## they should jump straight to the front of the display queue instead of
## waiting behind whatever ambient line is already lined up, same as drag.
const URGENT_CATEGORIES := ["petReject", "screamBIG", "fell", "pet", "petWounded", "LightDamage", "MediumDamage", "HardDamage", "lastmoments", "fentanyl", "overdose"]

## Which [tag] each category's quotes originally used in TRANSLATION.json -
## AI-generated replacement text never includes this on its own, so it's
## applied here in code instead, based on category.
const CATEGORY_DISPLAY_TAG := {
	"getUp": "[wave]", "getUpPet": "[wave]", "sleepy": "[wave]", "reallySleepy": "[wave]",
	"EatGood": "[wave]", "start": "[wave]", "beingDragged": "[wave]",
	"fell": "[shake]", "screamBIG": "[shake]", "petReject": "[shake]", "EatBad": "[shake]",
	"fentanyl": "[stupid][wave]", "withdrawal": "[shake]", "overdose": "[stupid][shake]",
}

## Явное описание того, что сейчас происходит с персонажем, для категорий,
## где раньше модель понимала ситуацию ТОЛЬКО по стилю примеров-цитат (что
## работало ненадёжно). Без этого модель может сгенерировать стилистически
## похожую, но по смыслу случайную фразу.
const CATEGORY_SITUATION := {
	"pet": "Тебя прямо сейчас гладят рукой - это приятно, тебе нравится ласка.",
	"petReject": "Тебя пытаются погладить, но сейчас тебе это неприятно или не в настроении - ты недовольно отвергаешь ласку.",
	"hungry": "Ты сейчас {голодна|голоден}, хочешь есть.",
	"sleepy": "Тебя клонит в сон, ты {сонная и вялая|сонный и вялый}.",
	"reallySleepy": "Ты очень хочешь спать, вот-вот заснёшь прямо на месте.",
	"getUp": "Ты только что {упала|упал} и теперь встаёшь на ноги.",
	"getUpPet": "Ты только что {упала|упал}, но перед этим тебя долго гладили - вставая, ты всё ещё немного млеешь от этого.",
	"fell": "Ты только что неожиданно и неконтролируемо {упала|упал} - это застало тебя врасплох.",
	"start": "Ты только что {появилась|появился} на рабочем столе - самый первый момент, как ты здесь оказалась.",
	"screamBIG": "Тебя что-то резко напугало или ударило - ты вскрикиваешь от неожиданности.",
	"Full": "Тебе предлагают ещё еды, но ты уже {наелась|наелся} досыта.",
	"EatReject": "Тебе предлагают еду, но ты отказываешься её есть.",
	"EatBad": "Ты только что {съела|съел} что-то невкусное или неприятное на вкус.",
	"EatOk": "Ты только что {съела|съел} что-то так себе на вкус, не хорошее и не плохое.",
	"EatGood": "Ты только что {съела|съел} что-то очень вкусное.",
	"grab": "Тебя только что схватили рукой и подняли в воздух.",
	"LightDamage": "Тебе только что было немного больно - лёгкий удар или падение, не критично, но неприятно.",
	"MediumDamage": "Тебе только что было по-настоящему больно - серьёзный удар или падение.",
	"HardDamage": "Тебе только что было ОЧЕНЬ больно - тяжёлый удар, здоровье на исходе, это серьёзно и страшно.",
	"healed": "Тебе только что помогли вылечиться, тебе физически стало лучше, но ты всё ещё в невесёлом настроении.",
	"fentanyl": "Тебе только что вкололи фентанил. Накрывает тёплой волной - боль и тревога уходят, всё плывёт, тебе слишком хорошо.",
	"withdrawal": "У тебя ломка - давно не было фентанила, и тело его требует. Тебя трясёт и знобит, ломит кости и мышцы, мутит, ты не находишь себе места и думаешь только о дозе. Ты {раздражена|раздражён}, тебе по-настоящему плохо, ты говоришь об этом прямо и просишь человека дать тебе дозу.",
	"overdose": "Тебе вкололи слишком много фентанила подряд - передозировка. Ты проваливаешься в тяжёлую темноту, это последние слова перед тем, как ты отключишься.",
}

## Категории без своих примеров в TRANSLATION.json - берут примеры из
## другой, близкой по духу категории.
const CATEGORY_EXAMPLES_FROM := {
	"overdose": "lastmoments",
	"petWounded": "LowPassive",
}

## Body-part injury art, matched by filename through skinmapper's own
## userSkinPath/loadUserTex (so it respects whichever skin is active,
## falling back to res://assets/Body/ for default) - same convention
## already sitting in VoyagerAlt: experimentHead.png -> experimentHead
## Disfigured1.png (and Disfigured2/3 for parts that have extra tiers,
## currently just the head).
##
## Combines both things asked for: which PARTS look hurt is a stable count
## proportional to missing HP (100hp / N parts, like a slowly-filling damage
## bar across the body - a part, once picked, stays picked as health drops
## further, so nothing flickers); a part that only has ONE tier of art just
## shows it plainly once picked (normal <-> Disfigured, no numbers). A part
## that happens to have MULTIPLE tiers (the head, right now) additionally
## escalates through them (1->2->3) as health keeps dropping, once it's
## among the picked parts.
var _originalPartTextures: Dictionary = {} # Sprite2D -> its healthy Texture2D, cached the first time we touch it
var _injuryOrder: Array = [] # stable shuffled sprite order, fixed once per pet so "which parts" never flickers

func _injuryFileName(baseFile: String, tier: int) -> String:
	var ext := baseFile.get_extension()
	var stem := baseFile.get_basename()
	return "%sDisfigured%d.%s" % [stem, tier, ext]

func _loadInjuryTex(baseFile: String, tier: int) -> Texture2D:
	var candidate := _injuryFileName(baseFile, tier)
	var tex = skinmapper.loadUserTex(skinmapper.userSkinPath + candidate)
	if tex == null and skinmapper.userSkinPath != skinmapper.resPath:
		tex = skinmapper.loadUserTex(skinmapper.resPath + candidate)
	return tex

## Recomputes body-part injury look from current health. Placeholder
## breakpoints/formula - balance later, per the plan. Call any time health
## changes (damage or healing).
func _applyInjuryLook() -> void:
	if skinmapper == null or not is_instance_valid(skinmapper):
		return
	var root = skinmapper.get_node_or_null(skinmapper.bodyRoot)
	if root == null:
		return
	# ВАЖНО: используем ТОТ ЖЕ обход, что и skinmapper.mapSkin(), без
	# фильтрации глаза здесь - иначе индексы разойдутся с currtextures.
	# Надетая одежда - тоже Sprite2D на голове; без фильтра список спрайтов
	# становился длиннее списка текстур скина, функция выходила на проверке
	# размеров ниже, и вид травм "замерзал" (нога оставалась раненой при 100 ХП).
	var allSprites: Array = skinmapper.getspr(root).filter(func(s): return not s.has_meta("worn"))
	# skinmapper при подмене скина (для любого user:// скина, включая
	# VoyagerAlt) грузит текстуры через Image.load()+ImageTexture, у которых
	# НЕТ resource_path - поэтому имя файла бралось из resource_path и
	# ВСЕГДА оказывалось пустым после применения скина. skinmapper уже сам
	# запомнил исходное имя файла для каждого спрайта в том же порядке -
	# берём имя оттуда, а не пытаемся угадать по текущей текстуре.
	var appliedList: Array = skinmapper.getAppliedTextures()
	if allSprites.is_empty() or appliedList.size() != allSprites.size():
		return

	if _injuryOrder.size() != allSprites.size():
		_injuryOrder = allSprites.duplicate()
		_injuryOrder.shuffle() # fixed once - which parts are "the hurt ones" doesn't reshuffle on every call

	var hp: float = healthHandler.health
	var totalParts: int = allSprites.size()
	var healthyParts: int = ceili((hp / 100.0) * totalParts)
	var damagedCount: int = clampi(totalParts - healthyParts, 0, totalParts)
	var injured: Array = _injuryOrder.slice(0, damagedCount)

	# У всех частей, включая голову, одно состояние травмы (Disfigured1).
	# Раньше голова шла 1->2->3, и кадры рта разных степеней не совпадали
	# с кадром головы - лицо мерцало во время речи.
	var severity: int = 1

	for i in allSprites.size():
		var sprite = allSprites[i]
		if sprite.name == "EyeSprite":
			continue # управляется faceSys.gd по настроению - не трогаем здесь

		if not _originalPartTextures.has(sprite):
			_originalPartTextures[sprite] = sprite.texture # здоровый вид, до первой подмены

		var healthyTex: Texture2D = _originalPartTextures[sprite]
		var baseFile: String = String(appliedList[i].get("name", ""))
		if not (sprite in injured) or baseFile == "":
			sprite.texture = healthyTex
			if sprite.name == "HeadSprite":
				faceSys.setInjuryTier(0)
			continue

		var appliedTex: Texture2D = null
		# Пробуем свой текущий уровень тяжести, потом ниже - часть только с
		# Disfigured1 просто держит его на любой тяжести; голова (1/2/3)
		# нормально идёт по нарастающей.
		for t in range(severity, 0, -1):
			appliedTex = _loadInjuryTex(baseFile, t)
			if appliedTex != null:
				break

		# Голова по умолчанию рисуется через experimentHeadBack.png (вид со
		# спины при повороте), а файлы травм называются experimentHead
		# Disfigured*.png (без "Back") - без этой попытки голова осталась бы
		# вечно целой, раз имя никогда не совпадёт напрямую.
		if appliedTex == null and baseFile.contains("Back"):
			var strippedFile := baseFile.replace("Back", "")
			for t in range(severity, 0, -1):
				appliedTex = _loadInjuryTex(strippedFile, t)
				if appliedTex != null:
					break

		sprite.texture = appliedTex if appliedTex != null else healthyTex
		if sprite.name == "HeadSprite":
			# Анимация рта (talkLoop в faceSys.gd) сама решает, какой кадр
			# рта показывать во время речи - сообщаем ей текущую степень
			# травмы, чтобы она могла подобрать травмированный кадр вместо
			# здорового, если он нарисован (см. _headTextureFor в faceSys.gd).
			faceSys.setInjuryTier(severity if appliedTex != null else 0)


## Биасит выборку примеров в сторону более описательных строк, когда в пуле
## их достаточно. Некоторые пулы (например pet) вперемешку с содержательными
## строками содержат десятки коротких "Ок.", "Хорошо.", "Норм." - при чисто
## случайной выборке 8 из ~120 строк такие огрызки могут случайно занять
## половину "примеров для вдохновения" и лишить модель тематического сигнала.
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

var _lastSayTime: Dictionary = {}

## Стабильное имя скина ИМЕННО ЭТОГО питомца - не через GlobalVariable.
## userSkinPath, которая после спавна ДРУГОГО питомца с другим скином
## перестаёт указывать на скин этого конкретного (она общая на весь синглтон,
## перезаписывается при каждом новом спавне). skinmapper.userSkinPath же
## захватывается один раз при создании ЭТОГО узла и дальше не меняется.
func _skinTag() -> String:
	if skinmapper and skinmapper.userSkinPath != "":
		return skinmapper.userSkinPath.trim_suffix("/").get_file()
	return "Default"


## Голос ИМЕННО ЭТОГО питомца (whine/bark/speech) - раньше все питомцы
## разом звучали голосом того скина, что стоял в defaultSkin при запуске
## игры, независимо от собственного визуального скина каждого. См.
## AudioManager.getVoiceSet().
var voiceSet: Dictionary = {}


## situationOverride/poolSuffix - для событий с конкретным предметом
## (одежда): своя ситуация и отдельный пул "Скин:категория:предмет".
func _say(category: String, cooldown: float = 0.0, ignoreCooldown: bool = true, situationOverride: String = "", poolSuffix: String = "") -> void:
	if isUnconscious:
		return # 0 хп - персонаж без сознания, молчит до перезапуска приложения
	if isPlayer:
		# Игрок говорит то, что напишет человек. Из своих фраз - только голод
		# и боль, и сразу из файла персонажа: ИИ-пулов у игрока нет, а ждать
		# генерации ради одной строки - видеокарту зря грузить.
		if category in PLAYER_FILE_CATEGORIES:
			var own: Array = dialogueSys.data.get(CATEGORY_EXAMPLES_FROM.get(category, category), [])
			if not own.is_empty():
				_queueMessage(String(own.pick_random()), dialogueSys.speedMod, category in URGENT_CATEGORIES, PRIO_EMERGENCY if category in EMERGENCY_CATEGORIES else -1)
		return
	# 054.96: последние слова - сразу из файла персонажа, как start. Звучат
	# раз за жизнь, ради них не стоит держать целый ИИ-пул (и ждать его).
	if category in FILE_ONLY_CATEGORIES:
		var fromFile: Array = dialogueSys.data.get(category, [])
		if not fromFile.is_empty():
			_queueMessage(String(fromFile.pick_random()), dialogueSys.speedMod, true, PRIO_EMERGENCY)
		return
	if not ignoreCooldown and cooldown > 0.0:
		var now := Time.get_ticks_msec()
		var last: int = _lastSayTime.get(category, -999999999)
		if now - last < int(cooldown * 1000.0):
			return
		_lastSayTime[category] = now

	dialogueSys.pool = dialogueSys.data.get(CATEGORY_EXAMPLES_FROM.get(category, category), [])
	if gbData.settings.get("llmVisionEnabled", false):
		var examples: Array = _pickExamples(dialogueSys.pool.duplicate(), 8)
		var speed: float = dialogueSys.speedMod
		var styleHint := ""
		if category in LOUD_CATEGORIES:
			styleHint = "Ситуация громкая и напряжённая, но сама фраза должна быть простой и сдержанной - обычные слова, без надрыва в формулировке. Громкость передавай только тем, что одно слово можно выделить ЗАГЛАВНЫМИ буквами - не всю фразу и не усложняй саму мысль."
		var urgent: bool = category in URGENT_CATEGORIES
		var tag: String = CATEGORY_DISPLAY_TAG.get(category, "")
		var situation: String = situationOverride if situationOverride != "" else CATEGORY_SITUATION.get(category, "")
		var poolKey := _skinTag() + ":" + category + ((":" + poolSuffix) if poolSuffix != "" else "")
		# Пул прогрева ключуется по "Скин:категория" - иначе разные персонажи
		# (когда их станет больше одного) делили бы один и тот же пул и
		# путались бы в стиле друг друга.
		LLMManager.requestPooledReaction(poolKey, examples, func(text): _queueMessage(tag + text, speed, urgent, PRIO_EMERGENCY if category in EMERGENCY_CATEGORIES else -1), styleHint, situation)
	else:
		dialogueSys.send(cooldown, ignoreCooldown)
	
## Прогулки. Раньше: раз в 4-8 сек случайный рывок на 0.5-2 сек. Теперь
## персонаж выбирает ЦЕЛЬ и идёт к ней, а выбор зависит от состояния:
## голодна - к еде рядом, хорошее настроение - подойти к курсору,
## любопытство - к интересному предмету, иначе - в случайную точку экрана.
## Уставшая/грустная чаще стоит и ходит медленнее, под фентанилом -
## короткими неуверенными отрезками.
var _baseMaxSpeed := -1.0

func wandering() -> void:
	while get_tree():
		if Time.get_ticks_msec() < _commandUntil:
			await get_tree().create_timer(0.5).timeout # выполняет просьбу игрока
			continue
		if isPlayer and playerControlled:
			await get_tree().create_timer(0.5).timeout # ходит человек
			continue
		if isPlayer and not isSleeping and not isUnconscious and not ragdolled and _autopilotSleepAt > 0 and Time.get_ticks_msec() >= _autopilotSleepAt:
			moveSys.dir = 0
			_forceSleep() # автопилот: через 3-5 минут без управления игрок ложится спать
			await get_tree().create_timer(1.0).timeout
			continue
		if not wander or ragdolled or isSleeping or isUnconscious or beingDragged:
			moveSys.dir = 0
			await get_tree().create_timer(1.0).timeout
			continue

		# пауза между прогулками
		var pause := randf_range(2.0, 6.0)
		if isTired or isSad:
			pause *= 1.8
		await get_tree().create_timer(pause).timeout
		if not wander or ragdolled or isSleeping or isUnconscious or beingDragged:
			continue

		var restChance := 0.06
		if isTired:
			restChance = 0.3
		if isPlayer:
			restChance = 0.0 # у игрока "прилечь" путалось со сном автопилота - он просто засыпает по таймеру
		if randf() < restChance:
			moveSys.initswithc(moveSys.states.resting) # присесть/прилечь (сам встанет через 2-3 мин)
			continue

		if randf() < (0.35 if isSad else 0.15):
			continue # просто постоять

		await _walkTo(_pickWalkTarget())
		_tryTossSyringe()


## Дошла в ломке до шприца - толкает его в сторону курсора и требует,
## чтобы укол сделал человек. Сама себе - никогда (см. health_handler:
## фентанил действует, только если шприц держит/только что отпустил игрок).
const TOSS_SITUATION := "У тебя ломка. Ты только что {толкнула|толкнул} лапой шприц с фентанилом к человеку: колоть себя {сама|сам} ты не станешь никогда, ты требуешь, чтобы укол тебе сделал он. Шприц не у тебя в руках - он лежит у человека."
var _tossTarget: Node2D = null

func _tryTossSyringe() -> void:
	var syringe := _tossTarget
	_tossTarget = null
	if syringe == null or not is_instance_valid(syringe) or not _inWithdrawal() or ragdolled or isUnconscious or isSleeping:
		return
	var reach: float = 120.0 * float(gbData.settings.get("petScale", 4.0)) / 4.0
	if absf(syringe.global_position.x - moveSys.rigid.global_position.x) > reach:
		return
	# 054.998: толчок - раз в 1-2 мин, фраза при нём - не чаще раза в 3 мин.
	# Раньше: толкнул, шприц упал рядом, подошёл, толкнул - и фраза каждые секунды.
	var now := Time.get_ticks_msec()
	if now < _nextTossMsec:
		return
	_nextTossMsec = now + randi_range(TOSS_MIN_MS, TOSS_MAX_MS)
	if syringe is RigidBody2D:
		var toCursor: Vector2 = (moveSys.rigid.get_global_mouse_position() - syringe.global_position).normalized()
		syringe.linear_velocity = toCursor * 650.0 + Vector2(0.0, -250.0)
		syringe.angular_velocity = randf_range(-10.0, 10.0)
	if now - _lastTossLineMsec >= TOSS_LINE_GAP_MS and _withdrawalLineAllowed():
		_lastTossLineMsec = now
		_sayWithdrawal(TOSS_SITUATION, "toss")


func _pickWalkTarget() -> float:
	var w := float(GlobalVariable.screenWidth)
	var x: float = moveSys.rigid.global_position.x
	var margin := w * 0.06

	# ломка - к шприцу с фентанилом (колоть себя сама она НЕ может - только
	# отбросит шприц к человеку, см. _tryTossSyringe)
	if _inWithdrawal() and randf() < 0.8 and Time.get_ticks_msec() >= _nextTossMsec:
		var syringe := _nearestFentanylAnywhere()
		if syringe:
			_tossTarget = syringe
			return syringe.global_position.x
	# голодна - к ближайшей еде
	if hungerHandler.hungry < 30.0 and randf() < 0.7:
		var food := _nearestBody(func(body, key): return _isFoodKey(key))
		if food:
			return food.global_position.x
	# хорошее настроение - подойти к человеку (курсору), но не вплотную
	var mood: float = moodSys.mood + moodSys.drugOffset
	if mood > 30.0 and randf() < 0.25:
		var mx: float = moveSys.rigid.get_global_mouse_position().x
		if mx > margin and mx < w - margin:
			return mx - signf(mx - x) * 120.0
	# любопытство - к интересному предмету (но не к пиле)
	if randf() < 0.2:
		var thing := _nearestBody(func(body, key): return _itemDesc(key) != "" and not DANGER_ITEMS.has(key) and _curiousAbout(key))
		if thing:
			return _stopBeforeDanger(x, thing.global_position.x + randf_range(-60.0, 60.0))
	# случайная точка: от 150 до 700 пикс, у края - разворот к центру
	var dist := randf_range(150.0, 700.0)
	var dir := -1.0 if randf() < 0.5 else 1.0
	if x < w * 0.25:
		dir = 1.0
	elif x > w * 0.75:
		dir = -1.0
	return _stopBeforeDanger(x, clampf(x + dir * dist, margin, w - margin))


## 054.9991: фентанил интересен только тому, у кого есть зависимость, и никогда -
## игроку (Експи-игрок "подозрительно часто" ходил к шприцу из любопытства).
func _curiousAbout(key: String) -> bool:
	return key != "fentanyl" or (addiction > 0.0 and not isPlayer)


## 054.97: опасные предметы. Раньше персы шли прямо на пилу (в том числе
## из любопытства), пытались её перепрыгнуть, спотыкались и кричали.
const DANGER_ITEMS := ["sawblade"]
const DANGER_KEEP_DISTANCE := 110.0 # при petScale 4; масштабируется с размером

func _dangerKeepDistance() -> float:
	return DANGER_KEEP_DISTANCE * float(gbData.settings.get("petScale", 4.0)) / 4.0


## Опасные предметы на сцене (примерно на высоте персонажа).
func _dangersNearMyLevel() -> Array:
	var found: Array = []
	var y: float = moveSys.rigid.global_position.y
	for child in get_tree().current_scene.get_children():
		if child is Node2D and child.has_meta("itemName") and DANGER_ITEMS.has(String(child.get_meta("itemName"))):
			if absf(child.global_position.y - y) < 200.0:
				found.append(child)
	return found


## Если между x и targetX лежит пила - цель обрезается перед ней.
func _stopBeforeDanger(x: float, targetX: float) -> float:
	var dir := signf(targetX - x)
	var keep := _dangerKeepDistance()
	for saw in _dangersNearMyLevel():
		var sx: float = saw.global_position.x
		if signf(sx - x) == dir and absf(sx - x) < absf(targetX - x) + keep:
			var stopAt := sx - dir * keep
			if signf(stopAt - x) != dir:
				return x # пила уже вплотную в эту сторону - стоим
			if absf(stopAt - x) < absf(targetX - x):
				targetX = stopAt
	return targetX


## Пила прямо по курсу ближе безопасного расстояния.
## 054.999: в ломке шприц ищется по всему экрану (раньше - только в радиусе
## "зрения" персонажа, и далёкий шприц он просто не замечал). Из нескольких -
## тот, до которого меньше всего мешает: расстояние + штраф за каждый
## предмет на прямой линии между персонажем и шприцем.
func _nearestFentanylAnywhere() -> Node2D:
	var me: Vector2 = moveSys.rigidtorso.global_position
	var best: Node2D = null
	var bestCost := INF
	for body in _allItemBodies():
		if _itemKey(body) != "fentanyl":
			continue
		var cost: float = absf(body.global_position.x - me.x) + 400.0 * _obstaclesOnLine(me, body.global_position, body)
		if cost < bestCost:
			bestCost = cost
			best = body
	return best


## Все предметы на экране (RigidBody2D с properties), не только рядом.
func _allItemBodies() -> Array:
	var out: Array = []
	var stack: Array = [get_tree().current_scene]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			if c is RigidBody2D and c.has_node("properties"):
				out.append(c)
			elif not (c is RigidBody2D):
				stack.append(c)
	return out


## Сколько предметов пересекает прямая от персонажа до цели (лучом физики).
func _obstaclesOnLine(from: Vector2, to: Vector2, target: Node) -> int:
	var space: PhysicsDirectSpaceState2D = moveSys.rigidtorso.get_world_2d().direct_space_state
	var exclude: Array = [target.get_rid()]
	var hits := 0
	for i in 6:
		var q := PhysicsRayQueryParameters2D.create(from, to)
		q.exclude = exclude
		q.collision_mask = 1
		var r: Dictionary = space.intersect_ray(q)
		if r.is_empty():
			break
		if r["collider"] is RigidBody2D and r["collider"].has_node("properties"):
			hits += 1
		exclude.append(r["rid"])
	return hits


## Рядом летит предмет (бросили) - значит, перса сбило им, а не он сам споткнулся.
const FLYING_OBJECT_SPEED := 450.0

func _hitByFlyingObject() -> bool:
	var maxDist: float = 220.0 * float(gbData.settings.get("petScale", 4.0)) / 4.0
	for body in detectRange.inRadius.keys():
		if is_instance_valid(body) and body is RigidBody2D and body.linear_velocity.length() > FLYING_OBJECT_SPEED:
			if moveSys.rigidtorso.global_position.distance_to(body.global_position) < maxDist:
				return true
	return false


## 054.998: впереди высокий предмет (нижний и верхний лучи упёрлись) - раньше
## перс шёл в него, упирался, ящик отталкивал - "споткнулся" с уроном.
## Невысокие и так перепрыгиваются (movement_handler.checkJump).
func _tallObstacleAhead() -> bool:
	return moveSys.wallDetect.is_colliding() and moveSys.heightDetect.is_colliding() and moveSys.wallDetect.get_collider() is RigidBody2D


## В ломке перс не обходит предметы, а лезет напролом: лёгкое отпинывает,
## на тяжёлое пытается запрыгнуть (себе урона от этого нет - см. KNOCK выше).
var _stormAt := 0

func _stormObstacle() -> void:
	var now := Time.get_ticks_msec()
	if now < _stormAt:
		return
	_stormAt = now + 900
	var thing = moveSys.wallDetect.get_collider()
	if thing is RigidBody2D and thing.mass <= 2.0:
		thing.linear_velocity = Vector2(moveSys.dir * 520.0, -320.0)
		thing.angular_velocity = randf_range(-8.0, 8.0)
	else:
		moveSys.jump()


func _dangerAhead(dir: float) -> bool:
	if dir == 0.0:
		return false
	var x: float = moveSys.rigid.global_position.x
	for saw in _dangersNearMyLevel():
		var dx: float = saw.global_position.x - x
		if signf(dx) == dir and absf(dx) < _dangerKeepDistance():
			return true
	return false


func _nearestBody(filter: Callable) -> Node2D:
	var best: Node2D = null
	var bestDist := INF
	for body in detectRange.inRadius.keys():
		if not is_instance_valid(body):
			continue
		var key := _itemKey(body)
		if not filter.call(body, key):
			continue
		var d: float = absf(body.global_position.x - moveSys.rigid.global_position.x)
		if d < bestDist:
			bestDist = d
			best = body
	return best


func _walkTo(targetX: float, isCommand: bool = false) -> void:
	if _baseMaxSpeed < 0.0:
		_baseMaxSpeed = moveSys.maxspeed
	var speedMul := 1.0
	if isTired:
		speedMul = 0.8
	elif isSad:
		speedMul = 0.9
	# Быстрее обычного НЕ разгоняем: физика ходьбы "перелетает" лимит
	# скорости, и при x1.15 персонаж разгонялся до ~597 - выше порога
	# "сбита с ног" (575), то есть сбивал сам себя (054P, настроение > 50).
	var high := _isHigh()
	if high:
		speedMul *= 0.8 # плюс случайные остановки ниже - этого хватает, чтобы походка была "пьяной"
	moveSys.maxspeed = _baseMaxSpeed * speedMul

	var startX: float = moveSys.rigid.global_position.x
	var timeLimit := absf(targetX - startX) / maxf(60.0, moveSys.maxspeed * 0.6) + 3.0
	var t := 0.0
	var lastX := startX
	var stuckFor := 0.0
	while t < timeLimit:
		if not wander or ragdolled or isSleeping or isUnconscious or beingDragged:
			break
		if not isCommand and Time.get_ticks_msec() < _commandUntil:
			break # игрок о чём-то попросил - обычная прогулка уступает
		var x: float = moveSys.rigid.global_position.x
		var dx := targetX - x
		if absf(dx) < 25.0:
			break
		moveSys.dir = signf(dx)
		# пилу могли подкинуть уже по ходу прогулки - останавливаемся перед ней
		if _dangerAhead(moveSys.dir):
			break
		if _tallObstacleAhead():
			if _inWithdrawal():
				_stormObstacle()
			else:
				break # обходим: эта прогулка кончилась, следующая выберет другую цель
		# под фентанилом - заплетающиеся ноги: внезапные остановки
		if high and randf() < 0.08:
			moveSys.dir = 0
			await get_tree().create_timer(randf_range(0.4, 1.2)).timeout
		await get_tree().create_timer(0.1).timeout
		t += 0.1
		# упёрлась (в стену, ящик, который не перепрыгнуть) - сдаёмся
		stuckFor = stuckFor + 0.1 if absf(moveSys.rigid.global_position.x - lastX) < 1.0 else 0.0
		lastX = moveSys.rigid.global_position.x
		if stuckFor > 1.5:
			break
	moveSys.dir = 0
	moveSys.maxspeed = _baseMaxSpeed

const PET_REJECT_MOOD := 20.0
## 054.998: тяжело раненого гладят - не радость, а реакция по характеру
## (поле "woundedPet" в паспорте: Роза то благодарит, то огрызается, Липи
## больно и просит полечить, Дюне ласка не нужна - кормить!).
const WOUNDED_PET_HP := 30.0

func _woundedPetSituation() -> String:
	var hint := String(LLMManager.passport(_skinTag()).get("woundedPet", ""))
	if hint == "":
		hint = "Отреагируй на ласку в своём характере."
	return "Тебя гладят рукой, а ты тяжело {ранена|ранен}, тебе очень больно. " + hint


func petReject() -> void:
	dialogueSys.speedMod = 1.2
	_say("petReject", 2, false)
	AudioManager.play_random(voiceSet["bark"], 0.25, 0, 1, true, 0.5, 'exp_pet', "bark")
	pass

"""
green because i need a reminder to implement different reactions based on mood
"""
func petLimb(limb: RigidBody2D):
	if isUnconscious:
		return
	AudioManager.play_sfx(AudioManager.thudwoosh)
	if isSleeping:
		return # спит - звук касания есть, но без голоса (раньше голос звучал до этой проверки)
	# Шипение (bark) уместно только при плохом настроении - при обычном или
	# хорошем всегда используем whine вместо случайного 50/50 выбора.
	if moodSys.mood < -20.0 and randf() < 0.5:
		AudioManager.play_random(voiceSet["bark"], 0.375, 0, 1, true, 0.5, 'exp_pet', "bark")
	else:
		AudioManager.play_random(voiceSet["whine"], 0.375, 0, 1, true, 1, 'exp_pet', "whine")

	# под фентанилом ласку принимает даже при плохом базовом настроении;
	# 054.998: порог 10 -> 20 (Дюна с 16 хп радовался ласке)
	if moodSys.mood + moodSys.drugOffset < PET_REJECT_MOOD or (_inWithdrawal() and addiction > HEAVY_ADDICTION and randf() < 0.5):
		petReject() # тяжёлая ломка - отталкивает ласку через раз
		return
	if _inWithdrawal():
		_petHelpUntil = Time.get_ticks_msec() + PET_HELP_MS # ласка смягчает ломку

	#print("I JUST PET THE EXPIE ON HIS ", limb.name)
	faceSys.setEmotion("happy")
	moodSys.mood += 0.33 # было 0.5, уменьшено в 1.5 раза - настроение слишком быстро упиралось в 100
	moodSys._tempVal(3.33, 13) # было 5.0, тот же коэффициент 1.5
	pet_timer.start(pet_timer_inc)
	pet_count += 1
	
	#we can't tween the actual rigid body, its position doesn't update while tweening
	var sprite := limb.get_node_or_null("Sprite2D") as CanvasItem
	if not sprite:
		# if we fuck up, grab the first child node that isn't a CollisionShape2D
		for child in limb.get_children():
			if child is CanvasItem and not child is CollisionShape2D:
				sprite = child
				break

	if sprite:
		var tween := create_tween().set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)

		tween.tween_property(sprite, "scale", Vector2(1.07, 0.93), 0.08)
		tween.tween_property(sprite, "scale", Vector2(1.0, 1.0), 0.25)
	
	if not dialogueSys.is_dialogue_playing():
		dialogueSys.speedMod = 0.7
		if healthHandler.health < WOUNDED_PET_HP:
			_say("petWounded", 2, false, _woundedPetSituation())
		else:
			_say("pet", 2, false)
		
	await get_tree().create_timer(5).timeout
	faceSys.setEmotion("normal")


#i genuinely dont know what this does
func _on_debugToggle_signal():
	if $"../textParent/DebugText".text == "":
		$"../textParent/DebugText".text = "Test"
	else:
		$"../textParent/DebugText".text = ""


# unused and also this is recycled from my game "Fishy" go play it! It's really good!
# its not and i barely placed top 500 in gmtk with it
func struggle():
	while get_tree():
		randomize()
		await get_tree().create_timer(.1).timeout
		if ragdolled or beingDragged:
			var random_torque = randf_range(-1500.0, 1500.0)
			moveSys.rigidtorso.apply_torque(random_torque)

			var random_force = Vector2(randf_range(-1, 1), randf_range(-1, -2.0))
			moveSys.rigidtorso.apply_central_impulse(random_force * .3)

			await get_tree().create_timer(randf_range(.5, 1.2), false).timeout
