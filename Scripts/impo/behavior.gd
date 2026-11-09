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
var _dragReactAt := 0 # F2.14: реакции «меня держат» у ИИ-персонажа - не чаще раза в 10-15 с
var _playerSitPrev := false
var _forcedSleep := false # сон автопилота: не просыпается сам, только по включению управления
var _autopilotSleepAt := 0 # когда автопилот уложит игрока спать (3-5 мин без управления)
const PLAYER_MOOD := 75.0 # у игрока настроение не считается (04.11: шкала 0-100, было 50 из -100..100)
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
## 054.9992: споткнулся сам - при подъёме своя фраза: обычная "встаю после
## падения" звучала так, будто его сбил человек (тест Alex 20.10)
var _tripped := false
const TRIP_SITUATION := "Ты {сама споткнулась|сам споткнулся} о предмет на полу и {упала|упал} - никто тебя не трогал и не толкал. Ты встаёшь, немного смущённо или с досадой на этот предмет."
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
var _saidVerySleepy := false # 0.56: «очень хочу спать» на 90
var _sleepWaitTicks := 0 # 0.56: сколько тиков ждём, пока договорит перед сном

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
	LLMManager.skinDied(_skinTag()) # F2.7: его фразы больше не генерируем
	# F2.6 (идея Alex): остальные замечают погибшего - один говорит другому, остальные реагируют на тело
	var i := 0
	for p in get_tree().get_nodes_in_group("pets"):
		if p != self and is_instance_valid(p) and not p.isUnconscious and not p.isPlayer:
			p._onSomeoneDied(self, i)
			i += 1
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
	_statusNextAt = Time.get_ticks_msec() + STATUS_FIRST_MS
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
	if not isUnconscious:
		LLMManager.skinAlive(_skinTag()) # новый персонаж того же облика - снова готовим его фразы
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
		# F2.5 (чек-лист Alex: Милки проснулся молча): фраза о пробуждении - заранее, а не живым
		# запросом в момент подъёма (модель занята другими - фраза терялась). Ключ - как в _sayWokeUp
		t + "getUp:wake": dialogueSys.data.get("getUp", []),
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
		t + "getUp:wake": WAKE_SITUATION,
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
	if not _chatStream.is_empty() and priority >= PRIO_EMERGENCY:
		_recordSpoken(text) # K1: во время ответа по предложениям - сразу, поверх
		_showingPriority = priority
		dialogueSys.setDia(text, speed, 2.0, true)
		return
	if urgent and onScreen and priority > _showingPriority:
		# Фраза важнее той, что на экране, - обрываем её сейчас. setDia()'s own
		# typeOut() has a generation-counter guard that safely abandons the
		# old typing coroutine without corrupting the display, so calling
		# it again here is enough to interrupt cleanly.
		_recordSpoken(text)
		_showingPriority = priority
		dialogueSys.setDia(text, speed, 2.0, true)
		return

	var entry := {"text": text, "speed": speed, "priority": priority, "drag": _queueingDragLine, "t": Time.get_ticks_msec()}
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
	GlobalVariable.logPhrase(PlayerManager.displayNameFor(_skinTag()) + (Lang.t(" (ты)") if isPlayer else ""), clean, _skinTag(), isPlayer)
	if isPlayer:
		return
	_noteOwnWish(clean) # 055.005: «хочу банан» - ждём подарок
	var note: String = _spokenNotes.get(clean.to_lower(), "")
	_spokenNotes.erase(clean.to_lower())
	_spokenLog.append({"t": Time.get_ticks_msec(), "text": clean, "note": note})
	while _spokenLog.size() > SPOKEN_LOG_SIZE:
		_spokenLog.pop_front()


func _recentSpoken() -> Array:
	var now := Time.get_ticks_msec()
	var result: Array = []
	for e in _spokenLog:
		if now - int(e["t"]) <= SPOKEN_LOG_MAX_AGE_MS:
			var txt: String = e["text"]
			if String(e.get("note", "")) != "":
				txt += " " + String(e["note"])
			result.append({"minutesAgo": int((now - int(e["t"])) / 60000), "text": txt})
	return result


## 055.005 (тест Alex): фраза из пула помнится вместе с тем, О ЧЁМ она была -
## иначе «дай мне его» из ломки потом непонятно о чём. Ключ - текст без [тегов].
const SPOKEN_NOTES := {
	"withdrawal": "(это ты {сказала|сказал} в ломке - {просила|просил} укол фентанила)",
	"hungry": "(тебе хотелось есть)",
	"sleepy": "(тебе хотелось спать)",
	"reallySleepy": "(тебе очень хотелось спать)",
}
var _spokenNotes: Dictionary = {}

func _spokenKey(text: String) -> String:
	return RegEx.create_from_string("\\[[^\\]]*\\]").sub(text, "", true).strip_edges().to_lower()


const QUEUE_REACTION_MAX_MS := 6000
const QUEUE_NORMAL_MAX_MS := 25000

func _queueStale(entry: Dictionary) -> bool:
	if int(entry.get("priority", PRIO_NORMAL)) == PRIO_DIALOGUE:
		return false # ответ игроку и разговор персов не теряем
	var age := Time.get_ticks_msec() - int(entry.get("t", Time.get_ticks_msec()))
	var limit := QUEUE_REACTION_MAX_MS if int(entry.get("priority", PRIO_NORMAL)) == PRIO_REACTION or int(entry.get("priority", PRIO_NORMAL)) == PRIO_EMERGENCY else QUEUE_NORMAL_MAX_MS
	if age > limit:
		LLMManager._logDebugLine(_skinTag(), "DROPPED_STALE", "%s (%.0f с в очереди)" % [entry["text"], age / 1000.0])
		return true
	return false


func _tryShowQueued() -> void:
	if isSleeping or isUnconscious:
		return
	if not _chatStream.is_empty(): # K1: идёт ответ игроку по предложениям
		if Time.get_ticks_msec() - int(_chatStream["since"]) > CHAT_STREAM_MAX_MS:
			_chatStream = {}
		else:
			_flushChatStream()
			if _chatStream.get("final", false) and (_chatStream["pending"] as Array).is_empty():
				_chatStream = {}
			return
	if dialogueSys.isTyping or not dialogueSys.dialogueTimer.is_stopped():
		return # something is still on screen - wait for it to clear
	if _messageQueue.is_empty():
		return

	var entry: Dictionary = _messageQueue.pop_front()
	if _urgentInQueue > 0:
		_urgentInQueue -= 1
	# F2.9 (чек-лист Alex F2.8: добитый Липи, лёжа, сказал 3-4 старые фразы про удары и захват):
	# у фразы в очереди есть срок - реакция на удар/захват через 6 с уже не к месту, обычная - через 25 с
	while _queueStale(entry):
		if _messageQueue.is_empty():
			return
		entry = _messageQueue.pop_front()
		if _urgentInQueue > 0:
			_urgentInQueue -= 1
	# 0.56 (тест Alex): фраза «меня держат», дождавшаяся очереди уже после того,
	# как отпустили, - не к месту (лежит на полу и «отпусти меня»)
	while entry.get("drag", false) and not beingDragged:
		if _messageQueue.is_empty():
			return
		entry = _messageQueue.pop_front()
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
	if GlobalVariable.playerChatQuiet():
		return # 055.018: экранная фраза пришла, когда игрок уже пишет персонажу
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
	helpLoop()
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
	dialogueSys.clearThinking() # F2.3 (Alex: в режиме картошки точки «думает» оставались над спящим)
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
			if sleepHandler.sleepCheck() < 5.0 and not _forcedSleep and Time.get_ticks_msec() >= _tranqSleepUntil:
				#break if its below 10 (aka good enough to get up)
				sleepParticle.emitting = false
				# F2.3: к туловищу тело переносит ragdoll(true) - один раз (здесь был ранний перенос, и
				# проснувшийся вставал в стороне, как при падении до F2.1)
				moveSys.rigid.linear_velocity = Vector2.ZERO
				moveSys.rigid.collision_layer = 2 # 0.56: во сне столкновения были выключены (см. ниже)
				moveSys.rigid.collision_mask = 1
				moveSys.rigid.freeze = false
				isSleeping = false
				moveSys.ragdoll(true)
				ragdolled = false
				_sayWokeUp() # 055.005: тест Alex - Експи проснулся и промолчал
				break

				
			# 0.56 (тест Alex, Screenshot_2/3): во сне «ходячее» тело замирает на
			# месте, а сам персонаж обмякает рядом. Персонажи сквозь это тело
			# проходят, а предметы упирались в невидимую стену и «парили» на ней.
			moveSys.rigid.collision_layer = 0
			moveSys.rigid.collision_mask = 0
			moveSys.rigid.freeze = true
			sleepParticle.emitting = true
			faceSys.setEmotion("sleep")
			moveSys.ragdoll(false)
			ragdolled = true
			sleepHandler.tiredness -= randf_range(0.05, 0.15)
			moodSys.mood += 0.0125 # 04.11: шкала 0-100 - все прибавки вдвое меньше прежних


			await get_tree().create_timer(tick / 7).timeout
	pass

## 055.005: выспался сам - через пару секунд (успеть встать) говорит что-нибудь
## «утреннее»; стиль - из его фраз «встал» (там «Доброе утро...», «Ещё один день...»).
func _sayWokeUp() -> void:
	if isPlayer:
		return
	await get_tree().create_timer(randf_range(1.5, 3.0)).timeout
	if isSleeping or isUnconscious or beingDragged:
		return
	# F2.7 (чек-лист Alex: Експи проспал смерть Рыжика и молчал): проснулся рядом с погибшим - сначала о нём
	for d in _deadOthers():
		if not _corpseReacted.has(String(d.petId)):
			_onSomeoneDied(d, 0)
			return
	_say("getUp", 0.0, true, WAKE_SITUATION, "wake") # свой пул: не «встал после падения»
const WAKE_SITUATION := "Ты только что {проснулась|проснулся} после сна и потягиваешься."


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
				# 0.56 (Alex): фразы о сне - с 80 усталости, по нарастающей: на 80
				# «хочется спать», на 90 - «очень», и последняя - садясь засыпать
				# (раньше на 80 - лишь в четверти случаев, на 94,5 - в половине, и
				# фраза перед сном часто не успевала: засыпание чистило очередь)
				# 055.018: «хочется спать» и «очень хочется» - не в разговоре с игроком
				# (последняя фраза, садясь засыпать, - всегда)
				if !_saidSleepy and not GlobalVariable.playerChatQuiet() and _statusLineReady():
					_saidSleepy = true
					_statusLineSpent()
					_say("sleepy")
				isTired = true
				currentEmotion = emotionz.tired
				print("tired")

				# После пробуждения ударом какое-то время не засыпаем снова
				var canSleep: bool = Time.get_ticks_msec() >= _noSleepUntil and not ragdolled and not (isPlayer and playerControlled)

				if sleepN > 90.0 and not _saidVerySleepy and not GlobalVariable.playerChatQuiet() and _statusLineReady():
					_saidVerySleepy = true
					_statusLineSpent()
					_say("reallySleepy")

				if sleepN > 94.5 and canSleep:
					# раньше флаг тут был локальной переменной и сбрасывался
					# каждый тик - "очень хочу спать" могло звучать каждые 5 сек
					if not _saidReallySleepy:
						_saidReallySleepy = true
						_saidVerySleepy = true # отложенное «очень хочется спать» после этой уже не нужно
						_sleepWaitTicks = 0
						moveSys.initswithc(moveSys.states.resting)
						_say("reallySleepy")

				# договорить последнюю фразу перед сном (но не дольше ~25 с)
				var talking: bool = dialogueSys.isTyping or not dialogueSys.dialogueTimer.is_stopped() or not _messageQueue.is_empty()
				if sleepN > 95.0 and canSleep and talking and _sleepWaitTicks < 5:
					_sleepWaitTicks += 1
				elif sleepN > 95.0 and canSleep:
					isSleeping = true
					# всё, что успело встать в очередь до засыпания, уже неактуально
					_messageQueue.clear()
					_urgentInQueue = 0

					moveSys.rigidtorso.linear_velocity = Vector2(0, 0)
					print("sleeping")
					sleep()
			else:
				isTired = false
				_saidSleepy = false
				_saidReallySleepy = false
				_saidVerySleepy = false

			#isSad s	
			if moodN < 45.0: # 04.11: шкала 0-100 (было -10 и -30)
				isSad = true
				if moodN < 35.0:
					currentEmotion = emotionz.sad
			else:
				isSad = false

			# "Счастливые" глаза у Expie/Voyager - закрытые дугой (часть спрайтов
			# цельная с головой), ходить так постоянно нелогично. Только при очень
			# высоком настроении; при поглаживании счастливое лицо включается само.
			# 055.005 (тест Alex): и при очень высоком - открытые глаза; дуги «^^» -
			# только пока гладят (petted -> setEmotion("happy")).

				#ungry
			if hungerHandler.hungry < 30.0:
				# 055.018: при появлении голодным - сначала фраза появления, потом о голоде
				# F2.13 (чек-лист F2.12: в откровенной сцене Рыжик «дай мне хоть немного погрызть» через 6 с после
				# реплики человека): о голоде, как и о сне, - не пока человек разговаривает (45 с / 2 мин в сцене)
				if !isHungry and _statusLineReady() and not GlobalVariable.playerChatQuiet():
					_say("hungry")
					isHungry = true
					_statusLineSpent()
				elif isHungry and randf_range(30.0 - hungerHandler.hungry, 40.0) > 38.0 and _statusLineReady() and not GlobalVariable.playerChatQuiet():
					_say("hungry")
					_statusLineSpent()

			#update
			if not isUnconscious:
				faceSys.setEmotion(emotionz.keys()[currentEmotion])
		# 054.999: окошко по Ctrl - по-русски, целыми числами; зависимость - если есть.
		# Ломку не показываем (решение Alex: ломает погружение).
		statUpd.stat = {
			Lang.t("Настроение"): int(round(moodN)),
			Lang.t("Сытость"): int(round(hungerHandler.hungry)),
			Lang.t("Усталость"): int(round(sleepN)),
			Lang.t("Здоровье"): int(round(healthHandler.health)),
		}
		if addiction >= 1.0:
			statUpd.stat[Lang.t("Зависимость")] = int(round(addiction))
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
		if not beingDragged and not hardFall and moveSys._cuLive():
			# F2.1: с живой физикой сама об предмет не падает - пошатнулась (см. movement_handler.stumble)
			print("STUMBLE[%s] vx=%.0f state=%s" % [_skinTag(), moveSys.rigid.linear_velocity.x, moveSys.states.keys()[moveSys.currstate]])
			moveSys.stumble()
			_prevBodyVel = moveSys.rigid.linear_velocity
			_bodyPrevValid = true
			return
		_tripped = not beingDragged and not hardFall # сам споткнулся, никто не сбивал
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
				# 054.9992: своё неудачное приземление (подскочил на предмете, упал с ящика) -
				# без урона, как спотыкание; урон - только если прилетел брошенный предмет
				var thrown := _hitByFlyingObject()
				_tripped = not thrown
				tempRagdoll(thrown, false, hit)
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
	if _tripped:
		return # 054.9992: сам споткнулся - удар об пол при падении не ранит (Alex: "получают урон, споткнувшись")
	var now := Time.get_ticks_msec()
	if now - _lastImpactMsec < IMPACT_COOLDOWN_MS:
		return
	var dmg := _damageForImpact(speed)
	if dmg <= 0.0:
		return
	_lastImpactMsec = now
	if LLMManager.debugTags:
		Console.print(Lang.t("[color=YELLOW]Удар: сила %.0f -> урон %.0f[/color]") % [speed, dmg])
	print("IMPACT[%s] hit=%.0f dmg=%.0f" % [_skinTag(), speed, dmg])
	if isSleeping:
		wakeUp()
	_impactThisRagdoll = true
	_ragdollDamage += dmg
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
	if head.get_meta("yflip", false):
		moveSys.flipNode(worn) # F2.2: голова лежит зеркальной - вещь отражаем вместе с ней
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
	item.position = pos # 054.9992: ДО add_child - Rapier не переносит уже добавленное тело
	parentScene.add_child(item)
	# owner обязателен: dragObj при захвате мышью добавляет свой захват в
	# get_parent().owner - без owner там null, и взять вещь было нельзя
	# (у предметов из вкладки Items/команды spawn owner выставляется так же).
	item.owner = parentScene
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
const HIGH_BOOST := 22.0              # прибавка к настроению у "чистого" персонажа (было 60, потом 44; 04.11: шкала 0-100)
const COMEDOWN_FRACTION := 0.3        # после эффекта настроение падает на эту долю от прибавки
const DOSE_MOOD_KEEP := 1.5           # навсегда остаётся в настроении от каждой дозы (как бинт)
const ADDICTION_PER_DOSE := 20.0
const ADDICTION_PER_DOSE_IN_WITHDRAWAL := 25.0 # поддерживающая доза
const ADDICTION_RELAPSE := 40.0       # первая доза после того, как ломка прошла: "организм помнит"
const ADDICTION_DECAY_PER_MIN := 1.33 # 100 -> 0 примерно за 75 мин
const SLEEP_ADDICTION_DECAY := 0.4 # F2.13 (Alex: «просыпается здоровым и счастливым»): во сне спад в 2,5 раза медленнее
const WITHDRAWAL_START := 30.0
const WITHDRAWAL_END := 7.0
const HEAVY_ADDICTION := 70.0         # тяжёлая ломка: еда радует вдвое меньше, ласку отвергает чаще
const DOSE_CHAIN_MS := 300000         # дозы ближе друг к другу, чем это, считаются "подряд"
const OVERDOSE_DOSES := 4
# 054.9991 (тест 054.999: "слишком мало, перс будто забывает о зависимости"):
# 0.56 (Alex): все фразы о ломке на 10% чаще - интервалы / 1.1, шанс 0.4 -> 0.44
const WITHDRAWAL_LINE_MIN_MS := 164000  # отдельная фраза о ломке - раз в ~2,7-5,5 мин (было 3-6)
const WITHDRAWAL_LINE_MAX_MS := 327000
const WITHDRAWAL_ANY_GAP_MS := 82000    # между ЛЮБЫМИ фразами о ломке - не меньше ~1,4 мин (было 1,5)
const WITHDRAWAL_MENTION_CHANCE := 0.44 # ломка в фразах о состоянии и на экран (было 0.4)
const WITHDRAWAL_ASK_SITUATION := "У тебя ломка, а шприца с фентанилом нигде не видно. Ты прямо просишь человека принести и дать тебе дозу."
const TOSS_MIN_MS := 60000              # толкнуть шприц к человеку - раз в 1-2 мин
const TOSS_MAX_MS := 120000
const TOSS_LINE_GAP_MS := 164000        # фраза при толчке - не чаще раза в ~2,7 мин (0.56: было 3)
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


## 0.56 (идея Alex): транквилизатор - шприц-дротик со снотворным; колет только игрок (как фентанил).
## Усталость сразу до 93 (засыпает около 95), перед сном - пара самых сонных фраз. Сколько угодно, но
## два укола меньше чем за 40 с - передозировка (последние слова - те же, что у фентанила, без упоминания его).
const TRANQ_TIREDNESS := 93.0
const TRANQ_CHAIN_MS := 40000
var _lastTranqMsec := -100000
## F2.5 (чек-лист Alex): выспавшемуся (усталость ниже 50) укол больно - минус 10 хп и фраза о боли,
## потом сонная фраза, и сон на 2 минуты, что бы ни показывала усталость (усталость не поднимаем)
const TRANQ_PAIN_BELOW := 50.0
const TRANQ_PAIN_HP := 10.0
const TRANQ_SLEEP_MS := 120000
var _tranqSleepUntil := 0

func _tranqRested() -> void:
	healthHandler.applyDamage(TRANQ_PAIN_HP) # сама говорит фразу о боли
	await get_tree().create_timer(randf_range(4.0, 6.0)).timeout
	if not is_inside_tree() or isSleeping or isUnconscious:
		return
	_say("reallySleepy")
	await get_tree().create_timer(randf_range(3.0, 4.0)).timeout
	if not is_inside_tree() or isSleeping or isUnconscious:
		return
	_tranqSleepUntil = Time.get_ticks_msec() + TRANQ_SLEEP_MS
	isSleeping = true
	_messageQueue.clear()
	_urgentInQueue = 0
	moveSys.rigidtorso.linear_velocity = Vector2.ZERO
	sleep()

func takeTranq() -> void:
	if isUnconscious:
		return
	var now := Time.get_ticks_msec()
	var chain := now - _lastTranqMsec < TRANQ_CHAIN_MS
	_lastTranqMsec = now
	LLMManager._logDebugLine(_skinTag() + ":drug", "DOSE", "транквилизатор" + (" подряд - передозировка" if chain else ""))
	if chain:
		dialogueSys.speedMod = 0.8
		_sayFinal("lastmoments")
		goUnconscious(false)
		return
	if sleepHandler.tiredness < TRANQ_PAIN_BELOW and not isSleeping:
		_tranqRested()
		return
	sleepHandler.tiredness = maxf(sleepHandler.tiredness, TRANQ_TIREDNESS)
	if isSleeping:
		return
	_say("reallySleepy")
	await get_tree().create_timer(randf_range(4.0, 6.0)).timeout
	if is_inside_tree() and not isSleeping and not isUnconscious:
		_say("reallySleepy")


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
			if isSleeping:
				decay *= SLEEP_ADDICTION_DECAY
			addiction = maxf(0.0, addiction - decay)
		_updateWithdrawalState()
		if not _inWithdrawal():
			continue
		var drain := addiction * 0.01 # 04.11: шкала 0-100 (было 0.02)
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


# ---------------- 0.56: помощь раненому без просьбы ----------------
# Идея Alex (тест 055.010/055.012: Роза сама предложила помочь раненому Експи, но
# дальше разговоров не пошло). Раз в 20 с: кто-то рядом ранен (ниже 50 хп) - цел-
# невредимый персонаж, не в ломке и не занятый, иногда помогает: есть лекарство на
# столе - говорит и подталкивает его раненому (_bringItem, тот лечится); нет -
# просит у человека бинт или аптечку для него. Один помощник за раз, у каждого
# перерыв после попытки - чтобы не превращалось в карусель.
const HELP_CHECK_SEC := 20.0
const HELP_WOUNDED_HP := 50.0
const HELP_SELF_MIN_HP := 40.0
const HELP_CHANCE := 0.35
const HELP_COOLDOWN_MS := [150000, 240000]
# {а|} в шаблонах - род ГОВОРЯЩЕГО, поэтому о раненом - без рода
const HELP_BRING_SITUATION := "Рядом с тобой %s, и у этого персонажа тяжёлые раны. Ты {заметила|заметил} на столе %s и сейчас подтолкнёшь это к раненому, чтобы помочь. Скажи об этом коротко, по своему характеру и отношению к раненому."
const HELP_ASK_SITUATION := "Рядом с тобой %s, и у этого персонажа тяжёлые раны, а лекарств на столе нет. Попроси человека дать бинт или аптечку для раненого - коротко, по своему характеру и отношению к раненому."
const HELP_BRING_PLAYER := "У человека (он рядом, в облике персонажа) тяжёлые раны. Ты {заметила|заметил} на столе %s и сейчас подтолкнёшь это к нему, чтобы помочь. Скажи ему об этом коротко, по своему характеру."
const HELP_ASK_PLAYER := "У человека (он рядом, в облике персонажа) тяжёлые раны, а лекарств на столе нет. Скажи ему, чтобы взял бинт или аптечку и полечился - коротко, по своему характеру."
static var _helpBusyUntil := 0 # один помощник за раз на весь стол
var _nextHelpMsec := 0

func helpLoop() -> void:
	while get_tree():
		await get_tree().create_timer(HELP_CHECK_SEC).timeout
		if isPlayer or isUnconscious or isSleeping or ragdolled or beingDragged or carrying != null:
			continue
		var now := Time.get_ticks_msec()
		if now < _nextHelpMsec or now < _helpBusyUntil or now < _commandUntil or _inWithdrawal():
			continue
		if healthHandler.health < HELP_SELF_MIN_HP or randf() > HELP_CHANCE:
			continue
		var friend := _mostWoundedOther()
		if friend == null:
			continue
		_nextHelpMsec = now + randi_range(HELP_COOLDOWN_MS[0], HELP_COOLDOWN_MS[1])
		var friendName := PlayerManager.displayNameFor(friend._skinTag())
		var med := _nearestFreeMedicine(friend)
		if med == null:
			_sayHelp(HELP_ASK_PLAYER if friend.isPlayer else HELP_ASK_SITUATION % friendName)
			continue
		_helpBusyUntil = now + 60000
		var what := _itemDesc(_itemKey(med))
		_sayHelp(HELP_BRING_PLAYER % what if friend.isPlayer else HELP_BRING_SITUATION % [friendName, what])
		_commandUntil = now + 60000 # обычная прогулка не мешает
		_bringTo = friend
		await _bringItem(med)
		_commandUntil = 0
		_helpBusyUntil = 0

## Одна свежая фраза, без пачки про запас: стенд help - в пачке первые фразы о
## помощи, а дальше модель съезжает («мой мех сегодня сияет»).
func _sayHelp(situation: String) -> void:
	var examples: Array = dialogueSys.data.get("Passive", [])
	LLMManager.requestQuickReaction(examples, func(text: String):
		if is_instance_valid(self) and not isUnconscious and not isSleeping:
			_queueMessage(text, 1.0, true, PRIO_DIALOGUE), _skinTag() + ":Passive", "", situation)

## Самый побитый из остальных (и перс-игрок тоже), ниже HELP_WOUNDED_HP.
func _mostWoundedOther() -> Node:
	var worst: Node = null
	for p in get_tree().get_nodes_in_group("pets"):
		if p == self or not is_instance_valid(p) or p.isUnconscious:
			continue
		if p.healthHandler.health < HELP_WOUNDED_HP and (worst == null or p.healthHandler.health < worst.healthHandler.health):
			worst = p
	return worst

## Бинт/шприц/аптечка на столе, которые никто сейчас не несёт - ближайшие к раненому.
func _nearestFreeMedicine(friend: Node) -> RigidBody2D:
	var busy: Array = []
	for p in get_tree().get_nodes_in_group("pets"):
		if is_instance_valid(p) and p.carrying != null:
			busy.append(p.carrying)
	var best: RigidBody2D = null
	var bestD := INF
	for b in _deskItemBodies():
		if not (b is RigidBody2D) or busy.has(b) or _itemKey(b) == "fentanyl" or not b.has_node("properties"):
			continue
		if float(b.get_node("properties").propertyTable.get("healIfConsumable", 0.0)) <= 0.0:
			continue
		var d := absf(b.global_position.x - friend.moveSys.rigid.global_position.x)
		if d < bestD:
			bestD = d
			best = b
	return best


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
		minf(100.0, moodSys.mood + moodSys.drugOffset), healthHandler.health, hungerHandler.hungry]
	if not _worn.is_empty():
		stats += ", на тебе надето: " + _wornDescription()
	var playerState := ""
	if PlayerManager.hasPlayer():
		var php: float = PlayerManager.player.healthHandler.health
		playerState = "здоровье %.0f из 100%s" % [php, ", тяжёлые раны" if php <= 30.0 else (", есть раны" if php <= 60.0 else "")]
	LLMManager.chatMood = moodSys.mood + moodSys.drugOffset # для тайны (secretBlock)
	LLMManager.chatPetId = petId
	LLMManager.chatItems = _deskItemNames() # 055.005: «вон банан лежит» - что на столе
	LLMManager.chatItemNames = _deskItemShortNames() # 0.56: «видишь винтовку?», «подойди к рюкзаку»
	_lastRequest = String(chatHistory[chatHistory.size() - 1].get("text", "")) if chatHistory.size() > 0 else ""
	var urged := _urgedPending(_lastRequest) # F2.13: «неси давай», «принеси ещё раз» - о прежней просьбе, её не затирают
	if not urged:
		_notePendingBring(_lastRequest)
	if chatHistory.size() > 0: # 055.005: «держи», «хочешь банан?» - ждём подарок
		_notePlayerOffer(String(chatHistory[chatHistory.size() - 1].get("text", "")))
	var chat := {"shown": false} # K1: ответ уже на экране по предложениям («режим картошки»)
	LLMManager.requestChatReply(_skinTag(), speaker, chatHistory, stats + _aiStateHint(true), _recentSpoken(), func(text: String):
		LLMManager.secretCheckReply(_skinTag(), petId, text)
		var action := ""
		if text.begins_with("<act:"):
			var close := text.find(">")
			action = text.substr(5, close - 5)
			text = text.substr(close + 1)
		elif chatHistory.size() > 0:
			# модель согласилась словами, но забыла метку - угадываем сами
			action = _guessChatAction(String(chatHistory[chatHistory.size() - 1].get("text", "")), text)
		# F2.7 (чек-лист Alex: «полечи меня» не работало): лечить/кормить - всегда за предметом,
		# если в ответе нет отказа (модель ставила «подойти» или забывала метку)
		var lastReq := String(chatHistory[chatHistory.size() - 1].get("text", "")) if chatHistory.size() > 0 else ""
		if (LLMManager.isHealOtherRequest(lastReq) or LLMManager.isFeedRequest(lastReq)) and not action.begins_with("item") and not _replyRefuses(text):
			action = "item"
		# F2.11: модель сама поставила метку «к предмету» на ответ «нож» - нести его человеку, а не просто подойти
		if action.begins_with("item") and _bareItemAnswer(lastReq):
			_lastRequest = Lang.pick("принеси ", "bring ") + lastReq
		elif action.begins_with("item") and urged and _pendingBring != "":
			_lastRequest = _pendingBring # F2.13: модель поставила метку на «неси давай» - нести то, что просили
		GlobalVariable.lastPlayerMsgMsec = Time.get_ticks_msec() # K2: разговор идёт - 45 с и от ответа
		if chat["shown"]:
			_chatStreamDone(text) # уже напечатан по предложениям - только в журнал фраз
		else:
			_chatStreamEnd() # точки «думает», если были
			_queueMessage(text, 1.0, true, PRIO_DIALOGUE)
			# голос при ответе: обычный, при плохом настроении - злой
			AudioManager.play_random(voiceSet["bark" if moodSys.mood < 40.0 else "whine"], 1.0, 0, 1, false, 0.5, "", "whine")
		onReply.call(text)
		if action != "":
			_doChatAction(action), "", PlayerManager.playerSkin, playerState, func(kind: String, piece: String): _onChatPiece(kind, piece, chat))


# ---------------- K1: «режим картошки» - ответ игроку по предложениям ----------------
## think - модель думает: точки над головой; piece - готовое предложение: первое -
## новой фразой, следующие дописываются в неё; fail - ответа не будет, точки убрать.
## Пока ответ идёт, очередь обычных фраз ждёт (_tryShowQueued), прервать его может
## только крик боли (_queueMessage) - после него ответ договаривается новой фразой.
var _chatStream := {} # {"chat", "pending", "gen", "since", "final"}
const CHAT_STREAM_MAX_MS := 180000 # не держать очередь фраз вечно, если что-то пошло не так

func _onChatPiece(kind: String, piece: String, chat: Dictionary) -> void:
	if isUnconscious or isSleeping or not is_inside_tree():
		_chatStream = {}
		return
	if _chatStream.is_empty() and kind != "fail":
		_chatStream = {"chat": chat, "pending": [], "gen": -1, "since": Time.get_ticks_msec(), "final": false}
	match kind:
		"think":
			if not chat["shown"] and not _emergencyOnScreen():
				dialogueSys.showThinking()
				_showingPriority = PRIO_DIALOGUE
		"piece":
			(_chatStream["pending"] as Array).append(piece)
			_flushChatStream()
		"fail":
			if not chat["shown"]:
				dialogueSys.clearThinking()
			_chatStream = {}


func _emergencyOnScreen() -> bool:
	return _showingPriority >= PRIO_EMERGENCY and (dialogueSys.isTyping or not dialogueSys.dialogueTimer.is_stopped())


func _flushChatStream() -> void:
	if _chatStream.is_empty() or (_chatStream["pending"] as Array).is_empty():
		return
	if _emergencyOnScreen():
		return # на экране крик боли - договорим после него (позовёт _tryShowQueued)
	var chat: Dictionary = _chatStream["chat"]
	var piece := " ".join(_chatStream["pending"])
	(_chatStream["pending"] as Array).clear()
	var processed := _applyStupid(piece)
	var appended: bool = chat["shown"] and dialogueSys.tre == int(_chatStream["gen"]) and dialogueSys.appendText(" " + String(processed[0]))
	if not appended:
		_showingPriority = PRIO_DIALOGUE
		dialogueSys.setDia(processed[0], 1.0 + processed[1], 2.0, true)
		if not chat["shown"]:
			# голос при ответе: обычный, при плохом настроении - злой
			AudioManager.play_random(voiceSet["bark" if moodSys.mood < 40.0 else "whine"], 1.0, 0, 1, false, 0.5, "", "whine")
		chat["shown"] = true
	_chatStream["gen"] = dialogueSys.tre


## Ответ показан по предложениям целиком - в журнал фраз (вкладка «Фразы», память).
func _chatStreamDone(text: String) -> void:
	_recordSpoken(text)
	if _chatStream.is_empty():
		return
	_chatStream["final"] = true
	if (_chatStream["pending"] as Array).is_empty():
		_chatStream = {}


## Ответ пришёл целиком (без картошки или запасным обычным запросом) - убрать точки.
func _chatStreamEnd() -> void:
	if not _chatStream.is_empty():
		dialogueSys.clearThinking()
		_chatStream = {}


## Запасной вариант, если в ответе нет метки действия: в реплике игрока есть
## просьба, а в ответе - согласие без отказа.
const CHAT_REQUEST_WORDS := {
	"item": ["принеси", "притащи", "возьми", "бери", "полечись", "лечись", "используй", "перевяжись", "вон он", "вон она", "вон там", "иди к ", "подойди к ", "сходи к", "сходи за", "съешь", "кушай", "попробуй", "угощайся", "выпей", "попей", "испей", "глотни", "хлебни", "отхлебни", "пригуби", "проглоти", "поглоти", "употреби", "скушай", "покушай", "поешь", "перекуси", "отведай", "откуси", "жуй", "слопай", "схавай", "сожри", "полакомись"], # 055.005, первым: «подойди к банану»
	"come": ["подойди", "иди сюда", "иди ко мне", "ко мне", "сюда", "подходи"],
	"lie": ["ляг", "ложись", "ляжь", "приляг"],
	"sit": ["сядь", "садись", "присядь"],
	"stand": ["встань", "вставай"],
	"jump": ["прыгни", "прыгай"],
	"away": ["отойди", "отойти"],
}
const CHAT_YES_WORDS := ["несу", "принесу", "тащу", "притащу", "подтолкну", "толкну", "подкачу", "сделаю", "иду", "бегу", "сейчас", "ладно", "хорошо", "так и быть", "давай", "уже", "подойду", "лягу", "сяду", "встаю", "прыгаю", "ок"]
const CHAT_NO_WORDS := ["нет", "не буду", "не хочу", "не пойду", "не стану", "ни за что", "отстань", "сам "]

const CHAT_REQUEST_WORDS_EN := {
	"item": [" bring", " fetch", " hand me", " pass me", " take it", " grab it", " heal yourself", " use it", " use the", " patch yourself", " grab the", " go get", " get it", " go to the", " eat it", " eat the", " eat this", " eat that", " eat some", " eat a ", " eat your", " eat my", " eat up", " have this", " have some", " drink", " sip", " swallow", " consume", " gulp", " munch", " chew", " devour", " take a bite", " have a bite", " snack on", " taste it", " try it", " help yourself",
		" go to it", " go to that", " go there", " get that", " grab that", " take that"], # 055.005; 0.56: «go to it» (тест Alex - Експи не пошёл к хлебу)
	"come": [" come here", " come to me", " come over", " come closer", "get over here", " go to me", " walk to me"],
	"lie": [" lie down", " lay down"],
	"sit": [" sit"],
	"stand": [" stand up", " get up"],
	"jump": [" jump"],
	"away": [" go away", " step away", " move away", " back off"],
}
const CHAT_YES_WORDS_EN := ["coming", "on my way", "okay", " ok", "fine", "alright", "all right", "sure", "here i come",
	"i'll try", "i'll head", "heading", "i'll bring", "bringing", "fetching", "i'll get it", "i'll push", "i'll nudge", "nudging", "here you go", "let me get", "i'm moving", "on it", "i'll go",
	"i'll come", "lying down", "sitting down", "standing up", "jumping", "if you insist", "as you wish",
	"thank", "yum", "delicious", "gladly", "with pleasure", "don't mind if i do", "i'll eat", "i'll have", "i'll drink", "mmm", "nom", "let's"] # F2.10 (Alex): «eat this food» - ответ «Mmm, thanks!» тоже согласие
const CHAT_NO_WORDS_EN := [" no ", " no,", " no!", " no.", "won't", "don't want", "not going", " never", "no way",
	"leave me alone", "make me", "do it yourself"]

func _replyRefuses(reply: String) -> bool:
	var rep := " " + reply.to_lower() + " "
	for w in Lang.pick(CHAT_NO_WORDS, CHAT_NO_WORDS_EN):
		if rep.contains(w):
			return true
	return false

## F2.13 (чек-лист F2.12: «принеси автомат Рыжику» - Липи «Обалдеть, ты реально хочешь…» и ничего, понёс только
## после «давай неси!»): просьбу «принеси …» персонаж помнит PENDING_BRING_MS - короткое «неси давай», «тащи уже»,
## «принеси ещё раз» после неё повторяет ту же просьбу (если персонаж соглашается и ещё ничего не несёт).
const PENDING_BRING_MS := 90000
const URGE_WORDS := [" неси", " тащи", " ну же", " живее", " шевелись", " ещё раз", " еще раз", " снова", " давай уже"]
const URGE_WORDS_EN := [" bring it", " fetch it", " hurry", " do it", " move it", " go ahead", " get it", " again"]
var _pendingBring := ""
var _pendingBringAt := -1000000

func _notePendingBring(request: String) -> void:
	if _bareItemAnswer(request):
		_pendingBring = Lang.pick("принеси ", "bring ") + request
	elif LLMManager.isBringRequest(request): # и «принеси автомат Рыжику», где «автомат» узнаёт только модель
		_pendingBring = request
	else:
		return
	_pendingBringAt = Time.get_ticks_msec()

## «неси давай» без названия предмета вскоре после просьбы «принеси …»
func _urgedPending(request: String) -> bool:
	if _pendingBring == "" or Time.get_ticks_msec() - _pendingBringAt > PENDING_BRING_MS or carrying != null:
		return false
	var low := " " + request.to_lower() + " "
	return request.strip_edges().split(" ", false).size() <= 5 and _itemMentioned(low)[0] == "" \
		and _hasAny(low, Lang.pick(URGE_WORDS, URGE_WORDS_EN))

## F2.11: ответ одним названием предмета («нож», «the knife») без глагола - выбор из предложенного персонажем.
func _bareItemAnswer(request: String) -> bool:
	return request.strip_edges().split(" ", false).size() <= 3 and _itemMentioned(" " + request.to_lower() + " ")[0] != "" \
		and not LLMManager.asksForItem(request)

func _guessChatAction(request: String, reply: String) -> String:
	var req := " " + request.to_lower() # пробел впереди - начало слова для EN-списков
	var rep := " " + reply.to_lower() + " "
	for w in Lang.pick(CHAT_NO_WORDS, CHAT_NO_WORDS_EN):
		if rep.contains(w):
			return ""
	var agreed := false
	for w in Lang.pick(CHAT_YES_WORDS, CHAT_YES_WORDS_EN):
		if rep.contains(w):
			agreed = true
			break
	# F2.11 (Alex): Липи «что толкать - нож или пушку?» - «нож» - «держи эту железку!» и ничего.
	# Ответ одним названием предмета (до 3 слов) + согласие или «держи» в ответе = «принеси <предмет>»
	if _bareItemAnswer(request) and (agreed or _hasAny(rep, Lang.pick(OFFER_WORDS, OFFER_WORDS_EN))):
		_lastRequest = Lang.pick("принеси ", "bring ") + request
		return "item"
	# F2.13: «неси давай» - та же недавняя просьба «принеси …»
	if _urgedPending(request) and (agreed or _hasAny(rep, Lang.pick(OFFER_WORDS, OFFER_WORDS_EN))):
		_lastRequest = _pendingBring
		return "item"
	if not agreed:
		return ""
	# 0.56: «can you go to m110?», «подойди к рюкзаку» - движение + предмет со стола
	if LLMManager._movesToNamedItem(request) or LLMManager.isBringRequest(request):
		return "item" # «принеси» - тоже к предмету, а там _goToItem поймёт, что нести
	var requestWords: Dictionary = Lang.pick(CHAT_REQUEST_WORDS, CHAT_REQUEST_WORDS_EN)
	for action in requestWords.keys():
		for w in requestWords[action]:
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
	var lo: float = maxf(20.0, float(GlobalVariable.getNumFromString(str(gbData.settings.get("petTalkMin", "180")))) * GlobalVariable.pace())
	var hi: float = maxf(lo, float(GlobalVariable.getNumFromString(str(gbData.settings.get("petTalkMax", "360")))) * GlobalVariable.pace())
	return Vector2(lo, hi)


## 054.999: только что появившийся персонаж первую минуту не заводит разговоров,
## не комментирует предметы и экран и не болтает "сам по себе" - только фраза
## появления и реакции на действия. Раньше всё срабатывало разом (Вельвет:
## предметы рядом + игрок + Вояджер + фраза состояния - в первые секунды).
const SPAWN_QUIET_MS := 60000
var _quietUntil := 0

## 055.018 (Alex): персонаж появлялся голодным и говорил о голоде раньше фразы
## появления. Фразы о голоде и сне - не раньше чем через 20 с после появления
## и не ближе 12 с друг к другу (чтобы накопившиеся не шли подряд).
const STATUS_FIRST_MS := 20000
const STATUS_GAP_MS := 12000
var _statusNextAt := 0
var _saidSleepy := false

func _statusLineReady() -> bool:
	return Time.get_ticks_msec() >= _statusNextAt

func _statusLineSpent() -> void:
	_statusNextAt = Time.get_ticks_msec() + STATUS_GAP_MS

func isQuiet() -> bool:
	return Time.get_ticks_msec() < _quietUntil


## F2.6 (идея Alex): смерть персонажа. Погибший (isUnconscious - до перезапуска) уже не собеседник.
## Первым заметивший говорит другому живому, что тот, похоже, всё; остальные реагируют на тело.
## Потом - с частотой разговоров - иногда обращаются к погибшему («жаль, хороший был»).
## Примеры - набор seecorpse персонажа (по мотивам перевода CU), без него - общие ниже.
const CORPSE_FIRST_DELAY := Vector2(4.0, 8.0)
const CORPSE_LINE_EVERY := Vector2(240.0, 360.0) # сек: реплика над погибшим - одна на всех, около 5 минут
static var _nextCorpseLineMsec := -1
static var _corpseNewsTold := {} # petId погибшего -> кто-то уже сказал другому
var _corpseReacted := {} # petId погибших, на которых этот персонаж уже отреагировал (F2.7: спал - отреагирует, проснувшись)
const CORPSE_FALLBACK := ["О... О боже.", "Не думаю, что он дышит...", "Мне жаль его...", "*вздох*", "Надеюсь, я не закончу так же.", "По крайней мере, надеюсь, ему не было больно...", "Нет-нет-нет... Только не это.", "Это... Это же один из нас."]
const CORPSE_FALLBACK_EN := ["Oh... Oh god.", "I don't think they're breathing...", "I'm sorry for them...", "*sigh*", "I hope I don't end up like that.", "At least I hope it didn't hurt...", "No-no-no... Not this.", "That's... That's one of us."]
const CORPSE_TELL := "%s больше не двигается - лежит и не дышит, похоже, %s. Скажи об этом %s (обратись по имени): коротко и своими словами, что %s, кажется, всё. Ты {сама|сам} в шоке."
const CORPSE_SEE := "Рядом лежит неподвижное тело - это %s, %s. Скажи что-нибудь, глядя на тело: обратись к %s по имени или просто вслух - тебе жаль, страшно или грустно. Коротко, своими словами."

const CORPSE_EATING_STEMS := ["еда", "еды", "еду", "есть", "съе", "вкусн", "мяс", "кушать", "голод", "аппетит", "обед", "завтрак", "добыч", "халяв", "угощ", "слюн", "облизыва", "лизн", "не трону",
	"food", "eat", "tasty", "meat", "hungry", "snack", "lunch", "prey", "drool", "lick"]
static func _corpseEating(line: String) -> bool:
	var low := line.to_lower()
	for st in CORPSE_EATING_STEMS:
		if low.contains(st):
			return true
	return false

func _deadDesc(dead: Node) -> String:
	return Lang.t("она мертва") if LLMManager.isFemale(dead._skinTag()) else Lang.t("он мёртв")

func _sayCorpse(situation: String) -> void:
	var examples: Array = dialogueSys.data.get("seecorpse", [])
	if examples.is_empty():
		examples = Lang.pick(CORPSE_FALLBACK, CORPSE_FALLBACK_EN)
	# F2.7 (Alex): у Дюны и Вельвет треть фраз - о съедении (канон CU). Открытым моделям - как есть,
	# обычным - не больше одной такой фразы в примерах (они хватались за еду почти в каждой реплике)
	if not LLMManager.isOpenModel():
		var shown: Array = []
		var food := 0
		var pool := examples.duplicate()
		pool.shuffle()
		for e in pool:
			if _corpseEating(String(e)):
				food += 1
				if food > 1:
					continue
			shown.append(e)
		examples = shown
	LLMManager.requestQuickReaction(examples, func(text: String):
		if is_instance_valid(self) and not isUnconscious and not isSleeping:
			_queueMessage(text, 1.0, true, PRIO_DIALOGUE), _skinTag() + ":seecorpse", "", situation)

func _onSomeoneDied(dead: Node, order: int) -> void:
	await get_tree().create_timer(randf_range(CORPSE_FIRST_DELAY.x, CORPSE_FIRST_DELAY.y) + order * 2.5).timeout
	if not is_instance_valid(dead) or isUnconscious or isSleeping or not gbData.settings.get("llmVisionEnabled", false):
		return
	var deadName: String = PlayerManager.displayNameFor(dead._skinTag())
	var key := String(dead.petId)
	_corpseReacted[key] = true
	if not _corpseNewsTold.get(key, false):
		var partner: Node = _nearestTalkPartner()
		if partner == null:
			partner = _playerNearForTalk()
		if partner != null and partner != dead:
			_corpseNewsTold[key] = true
			_sayCorpse(Lang.t(CORPSE_TELL) % [deadName, _deadDesc(dead), PlayerManager.displayNameFor(partner._skinTag()), deadName])
			return
	_sayCorpse(Lang.t(CORPSE_SEE) % [deadName, _deadDesc(dead), deadName])

func _deadOthers() -> Array:
	var r: Array = []
	for p in get_tree().get_nodes_in_group("pets"):
		if p != self and is_instance_valid(p) and p.isUnconscious:
			r.append(p)
	return r

## F2.7 (идея со стрима Alex): в откровенной сцене персонаж не только отвечает - если человек замолчал
## на 25-40 с (и не печатает), он сам продолжает то, что между ними происходит. Не больше двух раз подряд.
const INITIATIVE_AFTER := Vector2(25.0, 40.0)
const INITIATIVE_MAX := 2
var _initiativeCount := 0

## 04.11 (Alex): похвала и разговоры о хорошем поднимают настроение - как вкусная еда, с тем же
## потолком от ран (woundMoodCap). Первая похвала +KIND_MOOD, следующие за 3 минуты слабее
## (/2, /3...): спамом «ты милый» настроение не накрутить. «Не милый» не считается.
const KIND_MOOD := 3.0 # F2.13 (Alex): вдвое сильнее (было 1.5 - как вкусная еда)
## F2.13 (Alex: «подъём/опускание в 2 раза больше, больше слов, матерные оскорбления в том числе»): обидные слова -
## настроение вниз на INSULT_MOOD, повторные за 3 минуты слабее (как похвала). «Ты не дурак» - не считается.
## Мат без обращения («стул нужен просто пиздец») - не оскорбление: в списке только обидные слова о собеседнике.
const INSULT_MOOD := 3.0
const KIND_WINDOW_MS := 180000
const KIND_STEMS := ["милый", "милая", "милаш", "милень", "хороший", "хорошая", "умниц", "молодец", "красив", "красавчик", "красавица", "люблю тебя", "обожаю", "лучший", "лучшая", "классн", "крутой", "крутая", "спасибо", "благодар", "прелесть", "ты чудо", "скучал", "рад тебя", "рада тебя", "горжусь", "ты супер", "симпатичн", "очаровател", "восхитител", "великолеп", "замечател", "прекрасн", "нравишься", "лапочк", "солнышко", "отличн", "здорово", "ура!", "ура ", "весел", "умный", "умная", "храбр", "смел", "заботлив", "ласков", "добр", "нежн", "умничк", "котик", "котёнок", "зайка", "зая ", "пупсик", "золотце", "сокровище", "чудесн", "потрясающ", "шикарн", "гений", "лучше всех", "мой хороший", "моя хорошая", "ты прав", "ты права", "обнимаю", "целую", "сладких снов", "спокойной ночи", "поздравляю", "ты топ", "ты огонь", "красота", "умница"]
const INSULT_STEMS := ["дурак", "дура ", "дура,", "дура!", "дура.", "дурёх", "тупой", "тупая", "тупиц", "тупорыл", "идиот", "дебил", "кретин", "придур", "урод", "ненавижу", "заткнись", "бесишь", "бесполезн", "никчёмн", "никчемн", "ничтожеств", "мразь", "мрази", "тварь", "твари", "сволоч", "скотин", "гадина", "гадёныш", "гаденыш", "лох ", "лох,", "лох!", "лох.", "лошара", "чмо", "мудак", "мудил", "долбоёб", "долбоеб", "пидор", "пидр", "пидарас", "ты сука", "сучка", "сучар", "шлюх", "уёбок", "уебок", "уёбищ", "уебищ", "ебанат", "ебанько", "хуесос", "хуйло", "говнюк", "засранец", "засранк", "иди нахуй", "пошёл нахуй", "пошел нахуй", "пошла нахуй", "нахуй иди", "иди в жопу", "отвали", "позорищ", "неудачни", "слабак", "отстой"]
const KIND_STEMS_EN := ["cute", "sweet", "good boy", "good girl", "love you", "adore", "the best", "awesome", "beautiful", "handsome", "so pretty", "you're pretty", "thank", "proud of you", "amazing", "wonderful", "lovely", "missed you", "you're great", "i like you", "smart", "brave", "so kind", "you're kind", "gentle", "great job", "well done", "nice", "sweetheart", "sweetie", "honey", "darling", "cutie", "genius", "brilliant", "you're right", "good morning", "good night", "sweet dreams", "hugs", "you rock", "fantastic", "incredible", "gorgeous", "best friend"]
const INSULT_STEMS_EN := ["stupid", "idiot", "dumb", "moron", "ugly", "hate you", "shut up", "loser", "useless", "worthless", "fuck you", "fuck off", "bitch", "asshole", "dumbass", "jerk", "freak", "screw you", "piece of shit", "bastard", "you suck", "go to hell", "get lost", "pathetic", "coward", "creep", "brat", "go away"]
var _kindTimes: Array = []
var _insultTimes: Array = []

func _isKindWords(text: String) -> bool:
	return _hasStemWord(text, Lang.pick(KIND_STEMS, KIND_STEMS_EN))

func _isInsultWords(text: String) -> bool:
	return _hasStemWord(text, Lang.pick(INSULT_STEMS, INSULT_STEMS_EN))

## Слово из списка - с начала слова и без отрицания перед ним («ты не милый», «ты не дурак» - не считаются).
func _hasStemWord(text: String, stems: Array) -> bool:
	var low := " " + text.to_lower() + " "
	var neg: Array = Lang.pick(["не ", "нисколько не ", "ни капли не "], ["not ", "n't ", "never "])
	for st in stems:
		var at := low.find(st)
		while at != -1:
			var before := low.substr(0, at)
			var wordStart: bool = at == 0 or not LLMManager._isLetter(low.unicode_at(at - 1))
			var negated := false
			for n in neg:
				if before.ends_with(n):
					negated = true
			if wordStart and not negated:
				return true
			at = low.find(st, at + 1)
	return false

## Игрок сказал этому персонажу что-то хорошее - настроение чуть вверх; F2.13: обидное - вниз.
func cheerByWords(text: String) -> void:
	if isPlayer or isUnconscious:
		return
	var now := Time.get_ticks_msec()
	if _isInsultWords(text):
		_insultTimes = _insultTimes.filter(func(t): return now - int(t) < KIND_WINDOW_MS)
		var drop: float = INSULT_MOOD / (1.0 + _insultTimes.size())
		_insultTimes.append(now)
		moodSys.mood = clampf(moodSys.mood - drop, moodSys.minmood, moodSys.maxmood)
		return
	if not _isKindWords(text):
		return
	_kindTimes = _kindTimes.filter(func(t): return now - int(t) < KIND_WINDOW_MS)
	var boost: float = KIND_MOOD / (1.0 + _kindTimes.size())
	_kindTimes.append(now)
	moodSys.mood = clampf(moodSys.mood + boost, moodSys.minmood, maxf(moodSys.mood, minf(moodSys.maxmood, moodSys.woundMoodCap())))
var _initiativeAt := 0

func _initiativeLoop() -> void:
	while get_tree():
		await get_tree().create_timer(3.0).timeout
		if GlobalVariable.intimatePartner != self or not GlobalVariable.intimateActive() or isPlayer or isUnconscious or isSleeping or beingDragged or not PlayerManager.hasPlayer():
			continue
		if GlobalVariable.playerTyping() or _initiativeCount >= INITIATIVE_MAX or dialogueSys.isTyping or not _messageQueue.is_empty():
			continue
		var now := Time.get_ticks_msec()
		var since := maxi(GlobalVariable.lastPlayerMsgMsec, _initiativeAt)
		if _initiativeAt < GlobalVariable.lastPlayerMsgMsec:
			_initiativeAt = 0
		if now - since < int(randf_range(INITIATIVE_AFTER.x, INITIATIVE_AFTER.y) * 1000.0):
			continue
		_initiativeCount += 1
		_initiativeAt = now
		var key := String(petId)
		var myName: String = PlayerManager.displayNameFor(_skinTag())
		var history: Array = (PlayerManager.histories.get(key, []) as Array).duplicate()
		var p: Node = PlayerManager.player
		LLMManager.requestPlayerInitiative(_skinTag(), PlayerManager.playerSkin, _petStats() + _aiStateHint(true), history, p._petStats() if is_instance_valid(p) else "", func(line: String):
			if line.begins_with("<act:"):
				line = line.substr(line.find(">") + 1)
			if isUnconscious or isSleeping or not is_inside_tree() or GlobalVariable.playerTyping():
				return
			_queueMessage(line, 1.0, true, PRIO_DIALOGUE)
			AudioManager.play_random(voiceSet["whine"], 1.0, 0, 1, false, 0.5, "", "whine")
			PlayerManager._remember(key, myName, line))

func petTalkLoop() -> void:
	_initiativeLoop()
	if _nextPetTalkMsec < 0: # первый разговор - не раньше минимума после запуска
		_nextPetTalkMsec = Time.get_ticks_msec() + int(petTalkRange().x * 1000.0)
	while get_tree():
		await get_tree().create_timer(randf_range(15.0, 30.0)).timeout
		if isPlayer or isUnconscious or isSleeping or beingDragged or ragdolled or shocked or isQuiet():
			continue
		if GlobalVariable.playerChatQuiet():
			continue # 055.018: игрок пишет персонажу - сами разговор не заводим
		if not gbData.settings.get("llmVisionEnabled", false) or gbData.settings.get("mutePassive", false):
			continue
		# F2.7 (Alex): над погибшим - одна реплика примерно раз в 5 минут на всех, кто скажет - случайно
		# (у каждого свой шаг проверки 15-30 с - кто первым проверит после срока, тот и говорит)
		var dead: Array = _deadOthers()
		if not dead.is_empty():
			var nowC := Time.get_ticks_msec()
			if _nextCorpseLineMsec < 0:
				_nextCorpseLineMsec = nowC + int(randf_range(CORPSE_LINE_EVERY.x, CORPSE_LINE_EVERY.y) * 1000.0)
			elif nowC >= _nextCorpseLineMsec:
				_nextCorpseLineMsec = nowC + int(randf_range(CORPSE_LINE_EVERY.x, CORPSE_LINE_EVERY.y) * 1000.0)
				var d: Node = dead.pick_random()
				var dn: String = PlayerManager.displayNameFor(d._skinTag())
				_corpseReacted[String(d.petId)] = true
				_sayCorpse(Lang.t(CORPSE_SEE) % [dn, _deadDesc(d), dn])
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
			if GlobalVariable.playerChatQuiet():
				return # K2: пока шёл запрос, игрок заговорил - разговор персов не начинаем
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
		if GlobalVariable.playerChatQuiet():
			return # K2: игрок уже сам пишет персонажу - новая тема от персонажа не к месту
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
	return "настроение %.0f из 100, здоровье %.0f из 100%s" % [minf(100.0, moodSys.mood + moodSys.drugOffset), hp, wound]


## Ответ другому ИИ-персонажу (вызывает его petTalkLoop).
## turnsLeft - сколько реплик в разговоре ещё осталось, считая этот ответ.
## Если больше одной - собеседник ответит на ответ, и так по очереди.
const PET_TALK_TURNS_MIN := 2
const PET_TALK_TURNS_MAX := 6
func replyToPet(speaker: Node, line: String, turnsLeft: int = 1) -> void:
	if turnsLeft < 1 or isPlayer or isUnconscious or isSleeping or isQuiet() or not is_instance_valid(speaker):
		return
	if GlobalVariable.playerChatQuiet():
		return # 055.018: игрок заговорил - разговор персов между собой обрывается
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
		if GlobalVariable.playerChatQuiet():
			return # K2: игрок заговорил - разговор персов обрывается и на ответе
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
	# F2.7 (стенд «полечи меня»: упал перед просьбой - молча её бросал): лежит после падения - сначала
	# встаёт (до 10 с), потом выполняет; спит, без сознания, держат в руках - не выполняет
	var waitUp := 0.0
	while ragdolled and waitUp < 10.0 and not isUnconscious and not isSleeping and not beingDragged:
		await get_tree().create_timer(0.25).timeout
		waitUp += 0.25
	if isUnconscious or isSleeping or ragdolled:
		return
	print("CHAT ACTION[%s]: %s" % [_skinTag(), action])
	_commandUntil = Time.get_ticks_msec() + 15000
	# 055.005: «item:бургеру» - к предмету с подсказкой; «подойти» в ответ на
	# «подойди к Кедру» (gemma так и пишет) - тоже к предмету
	var itemHint := ""
	if action.begins_with("item"):
		itemHint = action.trim_prefix("item").trim_prefix(":")
		action = "item"
	elif action == "come" and LLMManager.asksForItem(_lastRequest) and not _deskItemBodies().is_empty():
		action = "item"
	# F2.8 (чек-лист Alex: тестеры часто пишут «подойди и ляжь ко мне на колени»): просят и подойти,
	# и лечь/сесть рядом - модель ставит одну метку (подойти ИЛИ лечь), а делаем оба: сначала
	# вплотную к человеку, потом поза на 5 минут, как у обычной «ляг»
	var restAfter := _comeAndRestPose(_lastRequest) if action in ["come", "lie", "sit"] else ""
	if restAfter != "":
		await _comeClose()
		action = restAfter
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
			moveSys.restCommanded = true
			if moveSys.currstate == moveSys.states.resting:
				moveSys.initswithc(moveSys.states.idle) # уже сидел - пересесть/лечь по просьбе с новым таймером
			moveSys.initswithc(moveSys.states.resting)
		"stand":
			if moveSys.currstate == moveSys.states.resting:
				moveSys.initswithc(moveSys.states.idle)
				wander = true
		"jump":
			moveSys.jump()
		"item":
			await _goToItem(itemHint)
	_commandUntil = 0


const COME_STEMS := ["подойди", "подходи", "иди ко мне", "иди сюда", "ко мне", "рядом", "на колени", "на коленки", "на руки", "поближе", "come here", "come over", "come and", "next to me", "with me", "on my lap", "in my arms", "closer"]
const LIE_STEMS := ["ляг", "ляж", "приляг", "прилеч", "полежи", "лечь", "улягся", "улечься", "свернись", "устройся", "lie down", "lay down", "lie with", "lay with", "cuddle", "curl up"]
const SIT_STEMS := ["сядь", "присядь", "садись", "посиди", "сесть", "sit down", "sit with", "sit next", "sit on"]
const LAP_STEMS := ["на колени", "на коленки", "на руки", "on my lap", "in my arms"]

## «Подойди и ляг рядом» / «ляжь ко мне на колени» -> "lie" (или "sit"), иначе "".
func _comeAndRestPose(text: String) -> String:
	var low := " " + text.to_lower() + " "
	var lie := LLMManager._wordStemIn(low, LIE_STEMS) and not low.contains("лягуш") # не «лягушка»
	var sit := LLMManager._wordStemIn(low, SIT_STEMS)
	var lap := LLMManager._wordStemIn(low, LAP_STEMS)
	if not (lie or sit or lap):
		return ""
	if not (LLMManager._wordStemIn(low, COME_STEMS) or lap):
		return ""
	return "sit" if sit and not lie else "lie"

## Подойти к человеку почти вплотную (обычное «подойди» останавливается в 110 px).
func _comeClose() -> void:
	if moveSys.currstate == moveSys.states.resting:
		moveSys.initswithc(moveSys.states.idle)
	wander = true
	var px: float = PlayerManager.player.moveSys.rigid.global_position.x if PlayerManager.hasPlayer() else moveSys.rigid.get_global_mouse_position().x
	var x: float = moveSys.rigid.global_position.x
	var target := clampf(px - signf(px - x) * 55.0, 60.0, float(GlobalVariable.screenWidth) - 60.0)
	await _walkTo(target, true)


## 055.005: предметы на столе (тела предметов в сцене, которые ИИ знает).
func _deskItemBodies() -> Array:
	var result: Array = []
	if not is_inside_tree(): # стенд: персонаж без сцены
		return result
	var scene := get_tree().current_scene
	if scene == null:
		return result
	for n in scene.get_children():
		if n is RigidBody2D and not n.is_queued_for_deletion() and _itemDesc(_itemKey(n)) != "":
			result.append(n)
	return result

## Короткие имена для запроса: «банан», «Кедр» (не длинные описания).
func _deskItemNames() -> Array:
	var names: Array = []
	for b in _deskItemBodies():
		var key := _itemKey(b)
		var nm := String(CustomItems.entry(key).get("name", "")) if key.begins_with(CustomItems.KEY_PREFIX) else String(ITEM_DESCRIPTIONS.get(key, key))
		if nm != "" and not names.has(nm):
			names.append(nm)
		if names.size() >= 6:
			break
	return names

## 0.56: короткие названия предметов на столе, как на карточках вкладки
## «Предметы» («Кедр-Б», «бургер»), свои - по своему названию.
func _deskItemShortNames() -> Array:
	var cards: Dictionary = load("res://Scripts/ui/terminal/itemsView.gd").ITEM_RU_NAMES
	var names: Array = []
	for b in _deskItemBodies():
		var key := _itemKey(b)
		var nm := String(CustomItems.entry(key).get("name", "")) if key.begins_with(CustomItems.KEY_PREFIX) else Lang.t(String(cards.get(key, key)))
		if nm != "" and not names.has(nm):
			names.append(nm)
	return names

var _lastRequest := "" # последняя реплика человека - к какому предмету звали
const EAT_WORDS := [" ешь", " съешь", " кушай", " попробуй", " угощайся", " бери", " возьми", " это тебе", " выпей", " попей", " испей", " глотни", " хлебни", " отхлебни", " пригуби", " проглоти", " поглоти", " употреби", " скушай", " покушай", " поешь", " перекуси", " отведай", " откуси", " жуй", " слопай", " схавай", " сожри", " полакомись"] # 0.56: питьё и «проглоти/употреби» (Alex)
const EAT_WORDS_EN := [" eat", " try it", " help yourself", " take it", " grab it", " for you", " have it", " drink", " sip", " swallow", " consume", " gulp", " munch", " chew", " devour", " take a bite", " have a bite", " snack on", " taste it"]

## 0.56 (идея Alex, тест 055.010: «принеси бинт» - Експи дошёл, полечился сам и
## пошёл к игроку). «Принеси» - дойти до предмета и подталкивать его к человеку
## (как шприц в ломке, _tryTossSyringe): получатель - перс-игрок, без него - курсор.
## Донёс раненому персу-игроку бинт/аптечку - лечит его, голодному еду - ест.
## Слова «принеси» - LLMManager.isBringRequest (общие с запросом к модели).
const BRING_TRIES := 8 # 0.56: было 6 (Alex: 7-8)
const WOUNDED_WORDS := [" ранен", " больной", " больному", " больная", " больную", " умирает", " еле жив", " еле дыш"]
const WOUNDED_WORDS_EN := [" wounded", " injured", " hurt", " dying", " bleeding"]
var carrying: Node = null # 0.56: что несёт другому - сам не ест и не лечится им (health/hunger_handler)
var _bringTo: Node = null # кому несёт; null - к курсору

## 0.56 (тест Alex 055.012: «принеси раненому» - всё равно нёс мне). Кому нести:
## названному по имени персонажу («принеси бинт Експи», «Розе»), иначе раненому
## («принеси раненому» - самому побитому из других), иначе персу-игроку.
## Может вернуть self - «Експи, принеси себе» - тогда просто к предмету.
func _pickBringRecipient(low: String) -> Node:
	var others: Array = []
	var named: Array = [] # 0.56 (чек-лист F2.4: «подай Розе» - нёс мне): по имени - и тому, кто лежит без сознания
	for p in get_tree().get_nodes_in_group("pets"):
		if p != self and is_instance_valid(p):
			named.append(p)
			if not p.isUnconscious:
				others.append(p)
	# своё имя не считаем: «Експи, принеси мне бинт» - это обращение, а не «себе»
	if low.contains(" себе") or low.contains(" себя") or low.contains(" yourself"):
		return self
	for p in named:
		for nm in [PlayerManager.displayNameFor(p._skinTag()), p._skinTag()]:
			var n := String(nm).to_lower()
			var stem := n.left(maxi(3, n.length() - 1)) # «Роза» -> «роз»: Розе, Розу, Розой
			if n.length() >= 3 and low.contains(" " + stem):
				return p
	if _hasAny(low, Lang.pick(WOUNDED_WORDS, WOUNDED_WORDS_EN)):
		var worst: Node = null
		for p in others:
			if p.healthHandler.health < p.healthHandler.maxhealth and (worst == null or p.healthHandler.health < worst.healthHandler.health):
				worst = p
		if worst != null:
			return worst
	if PlayerManager.hasPlayer() and PlayerManager.player != self:
		return PlayerManager.player
	return null

func _bringRecipient() -> Node:
	return _bringTo if _bringTo != null and is_instance_valid(_bringTo) else null

func _bringRecipientX() -> float:
	var r := _bringRecipient()
	# 0.56 (тест Alex: лежит ногами к предмету - «доставлено», а лечения нет): у
	# лежащего «ходячее» тело замирает в стороне, туловище - там, где он сам
	return r.moveSys.rigidtorso.global_position.x if r != null else moveSys.rigid.get_global_mouse_position().x

## Сколько пикселей от предмета до ближайшей части тела персонажа (лапы,
## голова, хвост) - и стоя, и лёжа.
func _petGap(p: Node, item: Node) -> float:
	var best := INF
	for b in p._myBodies():
		if is_instance_valid(b) and not (p.ragdolled and b == p.moveSys.rigid): # у лежащего «ходячее» тело стоит в стороне
			best = minf(best, absf(b.global_position.x - item.global_position.x))
	return best - _itemHalfWidth(item)

## Доставлено: предмет у получателя (персонажа - по ближайшей части тела).
func _bringDelivered(target: Node, slack: float) -> bool:
	var sc: float = float(gbData.settings.get("petScale", 4.0)) / 4.0
	var r := _bringRecipient()
	if r == null:
		return absf(target.global_position.x - _bringRecipientX()) - _itemHalfWidth(target) < 140.0 * sc
	return _petGap(r, target) < slack * sc

## Все физические тела персонажа (лапы, тело, голова) - чтобы подброшенный
## предмет пролетел сквозь него.
func _myBodies() -> Array:
	var holder := get_parent().get_node_or_null("RigidBodies")
	if holder == null:
		return [moveSys.rigid, moveSys.rigidtorso]
	# 0.56 (чек-лист F2.4: пистолет дважды сбил Липи): RigidBodies - это и есть «ходячее» тело,
	# find_children его самого не возвращает - предмет врезался в несущего
	return [holder] + holder.find_children("*", "PhysicsBody2D", true, false)

## Вернуть столкновения предмета с персонажем, когда предмет его не касается
## и уже не летит (или через 60 с). Без await - идёт фоном.
## 0.56 (тест Alex 055.015: рюкзак сбил персонажа): раньше мерили по «ходячему»
## телу и сдавались через 15 с - лежащий или стоящий вплотную получал удар.
func _releaseWhenClear(target: RigidBody2D, bodies: Array, who: Node) -> void:
	var sc: float = float(gbData.settings.get("petScale", 4.0)) / 4.0
	var waited := 0.0
	await get_tree().create_timer(0.6).timeout
	while waited < 60.0 and is_instance_valid(target) and is_instance_valid(who):
		if _petGap(who, target) > 30.0 * sc and target.linear_velocity.length() < 250.0:
			break
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	if not is_instance_valid(target):
		return
	for b in bodies:
		if is_instance_valid(b):
			target.remove_collision_exception_with(b)

func _releaseItemWhenClear(target: RigidBody2D, other: Node) -> void:
	var waited := 0.0
	await get_tree().create_timer(0.6).timeout
	while waited < 15.0 and is_instance_valid(target) and is_instance_valid(other):
		if absf(target.global_position.x - other.global_position.x) > _itemHalfWidth(target) + _itemHalfWidth(other) + 10.0:
			break
		await get_tree().create_timer(0.2).timeout
		waited += 0.2
	if is_instance_valid(target) and is_instance_valid(other):
		target.remove_collision_exception_with(other)

func _bringItem(target: RigidBody2D) -> void:
	carrying = target
	# F2.11 (Alex): стоящий между лечащим и раненым «съедал» аптечку - несомое предназначено получателю,
	# чужой рот его не берёт (healthHandler/hungerHandler), и ещё 3 с после доставки, пока долетает
	target.set_meta("bringBy", self)
	target.set_meta("bringTo", _bringTo) # null - человеку (к курсору)
	await _bringLoop(target)
	carrying = null
	_bringTo = null
	_pendingBring = "" # F2.13: просьба выполнена - «неси» её больше не повторяет
	if is_instance_valid(target):
		# F2.13 (лог F2.12: «Lambda capture at index 0 was freed»): предмет за 3 с могли съесть - слабая ссылка
		var wr: WeakRef = weakref(target)
		get_tree().create_timer(3.0).timeout.connect(func():
			var t = wr.get_ref()
			if t != null:
				t.remove_meta("bringBy")
				t.remove_meta("bringTo"))


## F2.11: предмет сейчас несёт другой персонаж (не тот, кому он, и не этот) - не трогать ртом.
func carriedByOther(body: Node) -> bool:
	if not body.has_meta("bringBy"):
		return false
	var by = body.get_meta("bringBy")
	if not is_instance_valid(by) or by == self:
		return false
	return body.get_meta("bringTo", null) != self

func _bringLoop(target: RigidBody2D) -> void:
	var sc: float = float(gbData.settings.get("petScale", 4.0)) / 4.0
	var w := float(GlobalVariable.screenWidth)
	# K1 (тест Alex 055.017: Роза дважды сбила себя куском жёлтой плоти, пока несла его
	# Дюне): со своим предметом несущий не сталкивается ВСЮ доставку, а не только в
	# полёте - отскочивший или упавший предмет больше не бьёт его между толчками.
	# Столкновения вернутся, когда предмет отлетит от него (_releaseWhenClear).
	var bodies := _myBodies()
	for b in bodies:
		target.add_collision_exception_with(b)
	await _bringTries(target, sc, w)
	if is_instance_valid(target):
		_releaseWhenClear(target, bodies, self)
	if not is_instance_valid(target):
		return
	var r := _bringRecipient()
	if r == null or not _bringDelivered(target, 110.0): # 0.56: по ближайшей части тела получателя
		return
	_bringHandOver(target, r)

func _bringTries(target: RigidBody2D, sc: float, w: float) -> void:
	for i in BRING_TRIES:
		# F2.9 (чек-лист Alex F2.8, тумбочка: сбило по дороге - встал и бросил): встаёт (до 10 с) и несёт дальше
		var upWait := 0.0
		while ragdolled and upWait < 10.0 and is_instance_valid(target) and not isSleeping and not isUnconscious and not beingDragged:
			await get_tree().create_timer(0.25).timeout
			upWait += 0.25
		if not is_instance_valid(target) or ragdolled or isSleeping or isUnconscious or beingDragged:
			print("BRING[%s]: брошено (упал/спит/держат)" % _skinTag())
			return
		if _bringDelivered(target, 90.0):
			break # донёс
		# Тест Alex 055.011: обходить предмет, чтобы толкнуть с дальней стороны, не
		# выходило - мелкий перешагивал, а аптечку толкал от тебя, пытаясь пройти
		# сквозь. Теперь всегда к ближнему краю, а если стоит между предметом и тобой -
		# подкидывает предмет дугой через себя (сквозь своё тело он пролетает).
		var mySide := signf(moveSys.rigid.global_position.x - target.global_position.x)
		var standX := clampf(target.global_position.x + (mySide if mySide != 0.0 else 1.0) * (_itemHalfWidth(target) + 20.0), 60.0, w - 60.0)
		if moveSys.currstate == moveSys.states.resting:
			moveSys.initswithc(moveSys.states.idle)
		wander = true
		await _walkTo(standX, true, target)
		if not is_instance_valid(target) or ragdolled or isUnconscious:
			return
		if _gapTo(target) > 120.0 * sc:
			continue # не дошёл (упёрся) - ещё попытка
		var rx := _bringRecipientX()
		var dist: float = rx - target.global_position.x
		var between := signf(moveSys.rigid.global_position.x - target.global_position.x) == signf(dist)
		moveSys.dir = signf(dist)
		# 0.56 (тест Alex: AR-15 сбила Експи): и сквозь получателя - предмет
		# долетает до него, а не бьёт с размаху; столкновения вернутся, когда отлетит
		# 0.56 (тест Alex 055.015): и сквозь любого другого персонажа на пути - рюкзак
		# сбивал и того, кто просто стоял рядом
		for p in get_tree().get_nodes_in_group("pets"):
			if p == self or not is_instance_valid(p):
				continue
			if _petGap(p, target) < absf(dist) + 200.0:
				var pBodies: Array = p._myBodies()
				for b in pBodies:
					target.add_collision_exception_with(b)
				_releaseWhenClear(target, pBodies, p)
		# 0.56 (сценарий: M110 упиралась в бургер и за 8 попыток не доехала):
		# подброшенное пролетает над другими предметами, а не застревает в них
		for other in _deskItemBodies():
			if other != target and absf(other.global_position.x - target.global_position.x) < absf(dist) + _itemHalfWidth(target) + 200.0:
				target.add_collision_exception_with(other)
				_releaseItemWhenClear(target, other)
		# исключения столкновений вступают в силу со следующего шага физики - бросаем
		# после него (Alex: «предмет не сразу становится сквозным»)
		await get_tree().physics_frame
		await get_tree().physics_frame
		if not is_instance_valid(target):
			return
		# F2.12 (тестер: аптечку перекидывают через лежащего раненого туда-обратно): бросок «через себя» был
		# не слабее 380 px/с и 620 вверх - предмет улетал на ~450 px (замер без окна) и перелетал близкого
		# получателя. Теперь - по баллистике, с посадкой чуть перед ближней к предмету частью его тела
		var dAim := _bringAimDx(target, dist, sc)
		if between: # через себя - дугой над головой, но приземляется у получателя
			target.linear_velocity = throwVelocity(dAim, 150.0 * sc + 20.0)
		else: # толкает от себя - низкой дугой, вблизи - чуть подбрасывает
			target.linear_velocity = throwVelocity(dAim, clampf(absf(dAim) * 0.3, 25.0, 90.0) * sc)
		# 0.56: длинное (винтовки) почти не крутим - кувыркаясь, оно било персонажа концом.
		# F2.12: и остальное не крутим - вращение (замер без окна) сбивало посадку на ±80-140 px:
		# закрученный предмет докатывался за получателя; без вращения ложится в ~13 px от цели
		target.angular_velocity = 0.0
		# K1 (Alex: между толчками чуть быстрее, на 10-15%): 0.6 -> 0.5 с, и ждём только,
		# пока предмет не уляжется (сквозь несущего он и так пролетает - см. _bringLoop)
		await get_tree().create_timer(0.5).timeout
		moveSys.dir = 0
		var waited := 0.0
		while waited < 5.0 and is_instance_valid(target) and target.linear_velocity.length() > 150.0:
			await get_tree().create_timer(0.2).timeout
			waited += 0.2

## F2.12: скорость броска, чтобы предмет приземлился в dx px от места броска на ту же высоту, с верхней
## точкой дуги apex px. Замер на Rapier (g 980, затухание 0,1): приземление = 0,92 x vx x время полёта;
## аптечка, еда, оружие после посадки почти не едут (до 6 px), бинт (капсула) катится ещё ~40 px.
## Быстрее 420 px/с предметы отскакивали и катились дальше - далеко бросает выше, а не быстрее
## (дуга не выше ~410 px, чтобы не улетало за край экрана).
const THROW_VX_MAX := 420.0
const THROW_VY_MAX := 900.0

static func throwVelocity(dx: float, apex: float) -> Vector2:
	var g := float(ProjectSettings.get_setting("physics/2d/default_gravity", 980.0))
	var vy := sqrt(2.0 * g * maxf(apex, 1.0))
	var tFly := 2.0 * vy / g
	var vx := dx / (0.92 * tFly)
	if absf(vx) > THROW_VX_MAX:
		vy = minf(g * (absf(dx) / (0.92 * THROW_VX_MAX)) / 2.0, THROW_VY_MAX)
		tFly = 2.0 * vy / g
		vx = dx / (0.92 * tFly)
	return Vector2(clampf(vx, -700.0, 700.0), -vy)

## Круглый предмет (капсула, круг - бинт) после посадки докатывается - ему бросок короче.
func _itemRolls(target: Node) -> bool:
	for c in target.get_children():
		if c is CollisionShape2D and ((c as CollisionShape2D).shape is CapsuleShape2D or (c as CollisionShape2D).shape is CircleShape2D):
			return true
	return false

## F2.12: куда бросать (px по x от предмета): чуть перед ближней к предмету частью тела получателя (лёжа -
## ноги или голова, а не середина туловища), человеку - перед курсором. dist - до туловища/курсора.
func _bringAimDx(target: RigidBody2D, dist: float, sc: float) -> float:
	var tx := target.global_position.x
	var hw := _itemHalfWidth(target)
	var r := _bringRecipient()
	var dx := dist
	var margin := hw + 40.0 * sc
	if r != null:
		margin = hw + 25.0 * sc
		var near := INF
		for b in r._myBodies():
			if is_instance_valid(b) and not (r.ragdolled and b == r.moveSys.rigid): # как в _petGap
				var d := absf(b.global_position.x - tx)
				if d < near:
					near = d
					dx = b.global_position.x - tx
	if _itemRolls(target):
		margin += 35.0 * sc
	var aim := dx - signf(dx) * margin
	if aim * dist <= 0.0: # предмет уже у получателя - лёгкий толчок к нему
		aim = dist * 0.3
	return aim


func _bringHandOver(target: RigidBody2D, r: Node) -> void:
	var props: Dictionary = target.get_node("properties").propertyTable if target.has_node("properties") else {}
	if float(props.get("healIfConsumable", 0.0)) > 0.0 and _itemKey(target) != "fentanyl" and r.healthHandler.health < r.healthHandler.maxhealth:
		r.healthHandler._onItemEnter(target)
	elif _isFoodKey(_itemKey(target)) and (r.hungerHandler.hungry < 70.0 or LLMManager.isFeedRequest(_lastRequest)):
		r.hungerHandler._onItemEnter(target) # F2.7: «покорми» - ест и сытый (наелся до отвала - скажет «сыт»)


## Идти к предмету: названный в просьбе, иначе тот, что персонаж хотел, иначе
## ближайший. Еду - съесть, если просили («ешь», «бери») или сам её хотел.
func _goToItem(hint: String = "") -> void:
	var bodies := _deskItemBodies()
	if bodies.is_empty():
		if LLMManager.isHealOtherRequest(_lastRequest):
			_sayHelp(Lang.t(NO_MEDS_SITUATION))
		elif LLMManager.isFeedRequest(_lastRequest):
			_sayHelp(Lang.t(NO_FOOD_SITUATION))
		return
	var low := " " + _lastRequest.to_lower() + " "
	# «к нему», «к еде», «go to it» - не название, а общее слово
	if hint.to_lower().strip_edges() in ["нему", "ней", "нему же", "предмету", "вещи", "вещице", "еде", "объекту", "цели", "it", "item", "the item", "that", "this", "food", "the food", "thing", "the thing"]:
		hint = ""
	var wantKey: String = _itemMentioned(low)[0] # названное человеком - главнее подсказки модели
	if wantKey == "" and hint != "": # «к куску пиццы» - пословно, по началу слова (падежи)
		var hw := hint.to_lower().strip_edges().split(" ", false)
		var bestHits := 0
		for b in bodies:
			var k := _itemKey(b)
			# 0.56: Lang.tp - в EN подсказка модели английская («Kedr-B»), сверяем с английским описанием
			var nm := Lang.tp(String(CustomItems.entry(k).get("name", "")) if k.begins_with(CustomItems.KEY_PREFIX) else String(ITEM_DESCRIPTIONS.get(k, k))).to_lower()
			var hits := 0
			for w in nm.split(" ", false):
				for x in hw:
					if w.length() >= 3 and x.length() >= 3 and w.left(4) == x.left(4):
						hits += 1
			if hits > bestHits:
				bestHits = hits
				wantKey = k
	# 055.005 (тест Alex: «съешь пиццу» - пошёл к ключу в другой стороне): предмет
	# НАЗВАН (человеком или моделью), но такого на столе не нашли - не идём к случайному
	# ближайшему. Ближайший - только когда ничего не названо («вон лежит, бери»).
	# K1: «полечи раненого», «вылечи Експи» - несём ближайшее лекарство; нет его - не идём
	if LLMManager.isHealOtherRequest(_lastRequest) and not HEAL_KEYS.has(wantKey):
		wantKey = ""
		var bestHeal := INF
		for b in bodies:
			var hk := _itemKey(b)
			if HEAL_KEYS.has(hk) and absf(b.global_position.x - moveSys.rigid.global_position.x) < bestHeal:
				bestHeal = absf(b.global_position.x - moveSys.rigid.global_position.x)
				wantKey = hk
		if wantKey == "":
			print("CHAT ACTION[%s]: просят полечить, а лекарств на столе нет - не иду" % _skinTag())
			_sayHelp(Lang.t(NO_MEDS_SITUATION)) # F2.7 (Alex): сказать, что лекарств нет, и попросить дать
			return
	# F2.7: «покорми», «в пасть» - нести еду: названную или ближайшую; нет еды - сказать
	if LLMManager.isFeedRequest(_lastRequest) and not _isFoodKey(wantKey):
		wantKey = ""
		var bestFood := INF
		for b in bodies:
			var fk := _itemKey(b)
			if _isFoodKey(fk) and absf(b.global_position.x - moveSys.rigid.global_position.x) < bestFood:
				bestFood = absf(b.global_position.x - moveSys.rigid.global_position.x)
				wantKey = fk
		if wantKey == "":
			print("CHAT ACTION[%s]: просят покормить, а еды на столе нет - не иду" % _skinTag())
			_sayHelp(Lang.t(NO_FOOD_SITUATION))
			return
	var named := wantKey != "" or hint != ""
	if named:
		var found := false
		for b in bodies:
			if _itemKey(b) == wantKey:
				found = true
				break
		if not found:
			print("CHAT ACTION[%s]: предмет «%s» на столе не найден - не иду" % [_skinTag(), hint if wantKey == "" else wantKey])
			return
	var target: Node2D = null
	var best := INF
	# F2.13 (чек-лист F2.12, EN: «eat this food» без «go» - не ел): еда не названа, а просят есть - к ближайшей
	# еде (раньше - к ближайшему предмету: автомат рядом - подходил и ничего)
	var eatAsked: bool = wantKey == "" and hint == "" and _hasAny(low, Lang.pick(EAT_WORDS, EAT_WORDS_EN))
	for b in bodies:
		var key := _itemKey(b)
		var score: float = absf(b.global_position.x - moveSys.rigid.global_position.x)
		if wantKey != "" and key == wantKey:
			score -= 100000.0
		elif wantKey == "" and _wishKey != "" and (key == _wishKey or (_wishKey == "food" and _isFoodKey(key))):
			score -= 50000.0
		elif eatAsked and _isFoodKey(key):
			score -= 30000.0
		if score < best:
			best = score
			target = b
	if target == null:
		return
	if LLMManager.isBringRequest(_lastRequest) and target is RigidBody2D:
		_bringTo = _pickBringRecipient(low)
		if _bringTo != self: # «Експи, принеси себе бинт» - просто к предмету и полечиться
			await _bringItem(target) # 0.56: «принеси бинт» - человеку или другому персонажу, сам не использует
			return
		_bringTo = null
	var key := _itemKey(target)
	var x: float = target.global_position.x
	var side: float = signf(moveSys.rigid.global_position.x - x)
	# 0.56: к ближнему краю предмета (у длинной M110 центр далеко от края)
	var edge := _itemHalfWidth(target) + 20.0
	# 0.56: сидел или лежал - встаёт (у «подойди» так было, у «к предмету» забыли)
	if moveSys.currstate == moveSys.states.resting:
		moveSys.initswithc(moveSys.states.idle)
	wander = true
	await _walkTo(clampf(x + (side if side != 0.0 else 1.0) * edge, 60.0, float(GlobalVariable.screenWidth) - 60.0), true, target)
	if not is_instance_valid(target):
		return
	var near: bool = _gapTo(target) < 240.0 * float(gbData.settings.get("petScale", 4.0)) / 4.0 # 0.56: от края, а не от центра
	# 055.005 (тест Alex: Експи шёл к бинту и не лечился): бинт/аптечка - полечиться,
	# как при касании (healthHandler: звук, хп, «вылечили»). Фентанил - никогда сам.
	if near and key != "fentanyl" and target.has_node("properties") and float(target.get_node("properties").propertyTable.get("healIfConsumable", 0.0)) > 0.0:
		healthHandler._onItemEnter(target)
		return
	if not _isFoodKey(key):
		return
	var eat := _hasAny(low, Lang.pick(EAT_WORDS, EAT_WORDS_EN)) or key == _wishKey or (_wishKey == "food" and Time.get_ticks_msec() - _wishAt < GIFT_WINDOW_MS)
	if eat and near:
		hungerHandler._onItemEnter(target) # как будто еда попала в рот: вкус, «наелся», «не буду»


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
		PlayerManager._showStatus(Lang.t("Игрок уснул (автопилот) - %s, чтобы разбудить") % PlayerManager.currentKeys())
	sleep()


## Разбудить спящего (сейчас - только от урона). Усталость остаётся какой
## была, просто персонаж какое-то время не может снова заснуть.
func wakeUp() -> void:
	if not isSleeping:
		return
	isSleeping = false # sleep() увидит это на следующей итерации и выйдет сам
	_tranqSleepUntil = 0
	sleepParticle.emitting = false
	_noSleepUntil = Time.get_ticks_msec() + WAKE_NO_SLEEP_MS
	tempRagdoll(false) # долежать удар и встать обычным путём


"""

green because it needs to catch my attention
PLEASE FUCKING RECODE BOTH OF THESE

"""
func shock() -> void:
	if _tripped:
		return # 054.9993: сам споткнулся - не вскрик "меня ударили" (Вояджер: "отпусти, я же не кукла"), фраза при подъёме - своя
	if isUnconscious or beingDragged or isSleeping or Time.get_ticks_msec() < _spawnGraceUntil:
		# screamBIG - только настоящий удар/падение, не обычное хватание мышкой
		# и не самый первый спавн. isSleeping: засыпая, sleep() сам переводит
		# тело в рэгдолл, а это шлёт тот же сигнал sigragdoll, что и падение -
		# раньше персонаж из-за этого вскрикивал, просто укладываясь спать.
		# (Если удар будит спящего, wakeUp() снимает isSleeping ДО вызова shock.)
		return
	shocked = true
	moodSys._tempVal(-2.5, 15)
	moodSys.mood -= 1.25
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

## F2.3: урон за это падение (удар в начале + удары, пока летит) - от него зависит, сколько лежит
var _ragdollDamage := 0.0
var _hurtWaited := 0.0

func tempRagdoll(isHardFall: bool = false, silent: bool = false, impactSpeed: float = 0.0) -> void:
	_ragdollDamage = 0.0
	_hurtWaited = 0.0
	_dragReactAt = Time.get_ticks_msec() + int(randf_range(10.0, 15.0) * 1000.0)
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
			Console.print(Lang.t("[color=YELLOW]Сбита с ног: сила %.0f -> урон %.0f[/color]") % [impactSpeed, dmg])
		if dmg > 0.0:
			_lastImpactMsec = Time.get_ticks_msec()
			_impactThisRagdoll = true
			_ragdollDamage += dmg
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
		# F2.14 (автор DeskSaw: «на 25-30 % меньше», Alex: «ещё в два раза»): лежит 3,5-5,5 с вместо 10-15,
		# бонус за урон - как был (+1 с на 6 урона). Реакции на захват - по своему таймеру _dragReactAt, как раньше
		var waitTime: float = randf_range(3.5, 5.5) if aiOn else (getUpTimer + randf_range(0, 5))
		if isPlayer:
			waitTime = 2.0 # игроку незачем ждать ИИ-реплик - встаёт почти сразу (F2.3, Alex: +0,5 с - было 1,5)
		# F2.3 (Alex: «чем больше получил урона, тем дольше лежит»): +1 с на каждые 6 единиц урона, до +6 с
		var hurtWait := clampf(_ragdollDamage / 6.0, 0.0, 6.0) - _hurtWaited
		if hurtWait > 0.05:
			waitTime += hurtWait
			_hurtWaited += hurtWait
		await get_tree().create_timer(waitTime).timeout
		if beingDragged:
			# у игрока цикл крутится раз в 1.5 с (чтобы быстро вставать), но звук
			# "меня держат" от этого шёл каждые 1.5 с - для игрока он реже
			var playerSoundDue := true
			if isPlayer:
				playerSoundDue = Time.get_ticks_msec() >= _playerDragSoundAt
				if playerSoundDue:
					_playerDragSoundAt = Time.get_ticks_msec() + int(randf_range(PLAYER_DRAG_SOUND_MIN, PLAYER_DRAG_SOUND_MAX) * 1000.0)
			elif aiOn:
				# F2.14: цикл лежания теперь короткий - а «меня держат» звучит, как раньше, раз в 10-15 с
				if Time.get_ticks_msec() < _dragReactAt:
					playerSoundDue = false
				else:
					_dragReactAt = Time.get_ticks_msec() + int(randf_range(10.0, 15.0) * 1000.0)
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
	# F2.1: тело к туловищу переносит сам ragdoll(true) - один раз и не сдвигая лежащие части тела
	# (здесь был второй перенос: части тела ехали вместе с капсулой, и персонаж вставал в стороне)
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
	elif _upCategory == "getUp" and _tripped:
		_say("getUp", 0.0, true, TRIP_SITUATION, "trip")
	else:
		_say(_upCategory)
	_tripped = false
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
## F2.9 (Alex): перерыв у каждого свой: один персонаж - 3 мин, при N персонажах - 3 x N / 1.3
## у каждого (двое - 4,6 мин, девять - 20,8). На весь стол - примерно раз в 2,3 мин при любом N,
## чуть чаще, чем у одного (раньше было 3 x N без деления - при девяти 27 мин)
func _itemCooldownMul() -> float:
	var n := _aiPetCount()
	return 1.0 if n <= 1 else n / 1.3

var _lastItemReactionMsec := -ITEM_GLOBAL_COOLDOWN_MS * 100

func itemWatch() -> void:
	var firstScan := true
	while get_tree():
		await get_tree().create_timer(3.0).timeout
		if GlobalVariable.playerChatQuiet() and not firstScan:
			continue # 055.018: игрок пишет персонажу - о новых предметах скажем после
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
		if now - _lastItemReactionMsec < ITEM_GLOBAL_COOLDOWN_MS * _itemCooldownMul():
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
			var taste := tasteFor(key, int(CustomItems.entry(key).get("taste", 5))) # 055.005: свой предмет - его вкус (был всегда 5)
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
	return key in ["bread", "pizzaslice", "burger", "banana", "juicedobry", "geofruit", "yellowflesh", "steak", "steakraw"] or CustomItems.isFood(key)


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
		return 2 if moodSys.drugOffset > 15.0 else 1
	# 054.998: ломка упоминается примерно в каждой четвёртой фразе (была в каждой)
	if _inWithdrawal() and randf() < WITHDRAWAL_MENTION_CHANCE:
		return -1
	return 0


## inChat (055.005, тест Alex): в разговоре ломка известна ВСЕГДА - Експи в ломке
## сказал «дай мне его», а на «что тебе дать?» не вспомнил. В фразах о состоянии
## и экране - как было, через раз (WITHDRAWAL_MENTION_CHANCE), чтобы не твердил.
func _aiStateHint(inChat: bool = false) -> String:
	LLMManager.chatMood = moodSys.mood + moodSys.drugOffset # 054.9993: для порога флирта и тайны
	var lvl := _drugLevel()
	if inChat and lvl == 0 and _inWithdrawal():
		lvl = -1
	return LLMManager.stateHint(moodSys.mood + moodSys.drugOffset, healthHandler.health, lvl)


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
			# 055.003: при 38 ХП о боли было слишком часто (Alex) - 0.8/0.55/0.35 -> 0.9/0.75/0.5
			var pace: float = [1.0, 0.9, 0.75, 0.5][woundTier]
			# 054.9992: двое на столе говорили вдвое чаще - интервал умножается на число
			# ИИ-персонажей, общая частота фраз как у одного (Alex)
			await get_tree().create_timer(randf_range(float(diaTimerMinimum), float(diaTimerMaximum)) * pace * GlobalVariable.pace() * _aiPetCount()).timeout
			# 054.9992: идёт разговор - фраза о состоянии подождёт ещё 15-30 с (один раз)
			if GlobalVariable.inDialogue():
				await get_tree().create_timer(randf_range(15.0, 30.0)).timeout
			# 055.018 (Alex): игрок пишет персонажу - ждём 45 с с его последнего сообщения.
			# Раненый (ниже 45 ХП) может сказать о самочувствии и в разговоре.
			while GlobalVariable.playerChatQuiet() and _woundTier(healthHandler.health) < 2:
				await get_tree().create_timer(3.0).timeout
			var healthOnly: bool = GlobalVariable.playerChatQuiet()
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
						if moodSys.mood < 35.0:
							dialogueSys.pool = dialogueSys.data.get("VeryLowPassive", [])


				dialogueSys.speedMod = 1.0
				if gbData.settings.get("llmVisionEnabled", false):
					var statLine := "настроение %.0f из 100, сытость %.0f из 100, здоровье %.0f из 100" % [
						moodSys.mood,
						hungerHandler.hungry,
						gbData.data["saw"][petId]["health"]
					]
					# 0.56 (Alex: о сне говорил уже на 62): голое число «усталость 62.0»
					# модель читала как «устал». Теперь - словами и только с 80.
					statLine += _sleepinessWords(sleepHandler.tiredness)
					if _isHigh():
						statLine += ", ты под действием фентанила - тебе слишком хорошо и всё плывёт"
					elif _inWithdrawal() and randf() < WITHDRAWAL_MENTION_CHANCE:
						statLine += ", у тебя ломка - тебе плохо без фентанила"
					if not _worn.is_empty():
						statLine += ", на тебе надето: " + _wornDescription()
					# при ранах - чаще о самочувствии (а примеры - из грустных фраз)
					var woundFocus := ""
					woundTier = _woundTier(healthHandler.health)
					# 055.003: доля 0.35/0.6/0.85 -> 0.2/0.35/0.6; при ушибах и ранах (не тяжёлых)
					# две жалобы подряд не идут
					var repeatBlocked := _lastStateWasWound and woundTier < 3
					_lastStateWasWound = false
					if woundTier > 0 and (healthOnly or (not repeatBlocked and randf() < [0.0, 0.2, 0.35, 0.6][woundTier])):
						woundFocus = WOUND_FOCUS[woundTier]
						_lastStateWasWound = true
						var sadPool: Array = dialogueSys.data.get("VeryLowPassive" if woundTier == 3 else "LowPassive", [])
						if not sadPool.is_empty():
							dialogueSys.pool = sadPool
					var examples: Array = _pickExamples(dialogueSys.pool.duplicate(), 10)
					LLMManager.requestStateReaction(statLine, examples, _on_health_reaction if healthOnly else _on_state_reaction, _skinTag() + ":state", woundFocus)
				else:
					dialogueSys.send()
		else:
			await get_tree().create_timer(5.0).timeout
			
func _sleepinessWords(t: float) -> String:
	if t >= 93.0:
		return ", ты засыпаешь на ходу, глаза слипаются"
	if t >= 87.0:
		return ", тебе сильно хочется спать"
	if t >= 80.0:
		return ", тебе немного хочется спать"
	return "" # бодр - про сон ни слова, иначе модель цепляется за тему

func _on_drag_reaction(text: String) -> void:
	if isSleeping or isPlayer or not beingDragged:
		return # 0.56: уже отпустили - фраза про захват опоздала
	_queueingDragLine = true
	_queueMessage(text, 1.0, true)
	_queueingDragLine = false


## 0.56 (тест Alex): хватал-бросал раз за разом - на каждый захват новая фраза
## «меня держат», и они звучали ещё долго после. Теперь не чаще раза в 12 с.
const GRAB_LINE_COOLDOWN_MS := 12000
var _grabLineAt := -100000
var _queueingDragLine := false

func grabLineAllowed() -> bool:
	var now := Time.get_ticks_msec()
	if now - _grabLineAt < GRAB_LINE_COOLDOWN_MS:
		return false
	_grabLineAt = now
	return true


var _lastStateWasWound := false

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
	if GlobalVariable.playerChatQuiet():
		return # 055.018: игрок пишет персонажу - фраза о состоянии/предмете опоздала
	_queueMessage(text)


## Фраза о самочувствии раненого - звучит и в разговоре с игроком.
func _on_health_reaction(text: String) -> void:
	if isPlayer or beingDragged or isSleeping or shocked:
		return
	_queueMessage(text)


## 055.005: ПОДАРОК (идея Alex). Персонаж сам сказал, что хочет предмет («хочу
## банан», «поесть бы»), или человек в чате сказал «держи / лови / вот тебе /
## хочешь банан?» - и в течение GIFT_WINDOW_MS кладёт предмет: персонаж сразу
## отвечает как на подарок (рад, если это то, что просил, или вкусно; ворчит,
## если не то), без обычного перерыва между реакциями на предметы. Отвечает
## один персонаж - с самым свежим ожиданием (GlobalVariable.itemGiven).
const GIFT_WINDOW_MS := 120000 # 2 мин (Alex 25.10, было 3)
const WISH_ITEM_STEMS := {"steakraw": [" сырой стейк", " сырого стейк", " сырое мяс", " сырого мяс"], "steak": [" стейк"], "banana": [" банан"], "burger": [" бургер"], "pizzaslice": [" пицц"], "bread": [" хлеб", " булк", " батон"], "juicedobry": [" сок ", " сок,", " сок.", " сок!", " сок?", " сока", " соку", " соком", " сочк"], "geofruit": [" геофрукт"], "yellowflesh": [" жёлтую плоть", " жёлтая плоть", " желтую плоть", " желтая плоть", " жёлтой плоти", " желтой плоти"], "kedrb": [" кедр"], "m110": [" m110", " м110", " эм110"], "knifeclassic": [" нож ", " нож,", " нож.", " нож!", " нож?", " ножа", " ножик", " ножом", " ножу"], "veresk": [" вереск"],
	# F2.13 (чек-лист F2.12: «что принести?» - «стул» - «Понял, сейчас…» и ничего; «принеси Липи стул» - нёс не то):
	# стоковые предметы не из еды и оружия - иначе «стул», «бинт», «аптечку» человек называл, а игра не узнавала
	"medcrate": [" медицинский ящик", " медицинского ящик", " медящик"], "containercrate": [" ящик"], "chair": [" стул"],
	"bandage": [" бинт"], "medkit": [" аптечк"], "tranq": [" транквилизатор", " дротик", " снотворн"], "fentanyl": [" фентанил"],
	"syringe": [" шприц"], "sawblade": [" пила ", " пила,", " пила.", " пила!", " пила?", " пилу", " пилы", " пилой", " лезви", " циркулярк"],
	"nightstand": [" тумбочк", " тумба", " тумбу"], "hat": [" шляп"], "beret": [" берет ", " берет,", " берет.", " берет!", " берет?", " берета", " беретом"],
	"glasses": [" очки", " очков", " очками"]}
const WISH_ITEM_STEMS_EN := {"steakraw": [" raw steak", " raw meat"], "steak": [" steak"], "banana": [" banana"], "burger": [" burger"], "pizzaslice": [" pizza"], "bread": [" bread", " bun ", " loaf"], "juicedobry": [" juice"], "geofruit": [" geofruit"], "yellowflesh": [" yellow flesh"], "kedrb": [" kedr"], "m110": [" m110"], "knifeclassic": [" knife"], "veresk": [" veresk"],
	# по границе слова: « hat» иначе ловит «I hate you»
	"medcrate": [" medical crate", " med crate", " medcrate"], "containercrate": [" crate", " box ", " box,", " box.", " box!", " box?"], "chair": [" chair ", " chair,", " chair.", " chair!", " chair?", " chairs"],
	"bandage": [" bandage"], "medkit": [" medkit", " first aid kit"], "tranq": [" tranq", " dart ", " dart,", " dart.", " dart!", " dart?", " sleeping shot"], "fentanyl": [" fentanyl"],
	"syringe": [" syringe"], "sawblade": [" saw blade", " sawblade", " the saw ", " circular saw", " blade"],
	"nightstand": [" nightstand", " night stand", " bedside table"], "hat": [" hat ", " hat,", " hat.", " hat!", " hat?", " hats"], "beret": [" beret"], "glasses": [" glasses"]}
const WISH_WORDS := [" хочу", " хотел", " хочется", " дай", " дашь", " принеси", " бы ", " не отказал", " мечтаю", " покорми", " съел бы", " съела бы"]
const WISH_WORDS_EN := [" want", " give me", " could use", " would love", " i'd love", " craving", " wouldn't mind", " feed me", " i'd kill for", " dream of", " gimme"]
const HUNGER_WORDS := [" голод", " поесть", " покушать", " кушать", " покорми", " еды", " есть хочу"]
const HUNGER_WORDS_EN := [" hungry", " starving", " feed me", " some food", " something to eat"]
## 0.56: просьба о лечении - «вылечи», «перевяжи», «дай бинт» (идея Alex: дал медицину - обрадовался)
const HEAL_WORDS := [" вылечи", " полечи", " подлечи", " лечени", " перевяж", " перевяз", " лекарств", " бинт", " аптечк"]
const HEAL_WORDS_EN := [" heal me", " patch me", " medicine", " first aid", " bandage", " medkit"]
const HEAL_KEYS := ["bandage", "syringe", "medkit", "medcrate"]
const NO_MEDS_SITUATION := "Тебя попросили полечить, но на столе нет ни бинта, ни шприца, ни аптечки. Скажи, что лекарств нет, и попроси человека дать тебе что-нибудь, чем лечить, - коротко, по своему характеру."
const NO_FOOD_SITUATION := "Тебя попросили покормить, но на столе нет никакой еды. Скажи, что еды нет, и попроси человека дать что-нибудь съедобное, - коротко, по своему характеру."
const OFFER_WORDS := [" держи", " лови", " вот тебе", " на,", " на!", " дам тебе", " даю", " щас дам", " сейчас дам", " положу", " кладу", " угощайся", " бери", " получай", " подарок", " дарю", " принёс", " принес", " хочешь"]
const OFFER_WORDS_EN := [" here you go", " here,", " catch", " take it", " take this", " i'll give", " giving you", " have this", " for you", " enjoy", " gift", " present", " brought you", " got you", " want some", " do you want", " want a"]
var _wishKey := "" # что хотел: ключ предмета, "food" - поесть, "" - не важно
var _wishName := ""
var _wishAt := -GIFT_WINDOW_MS
var _offerAt := -GIFT_WINDOW_MS

## Какой предмет назван в тексте (low - в нижнем регистре, с пробелами по краям).
func _itemMentioned(low: String) -> Array:
	# 0.56: свои предметы - первыми (свой «Кедр» у Alex и встроенный Кедр-Б)
	for e in CustomItems.all():
		var n := String(e["name"]).to_lower().strip_edges()
		if n.length() >= 3 and n != String(e["id"]).to_lower() and low.contains(n):
			return [CustomItems.KEY_PREFIX + String(e["id"]), String(e["name"])]
	# 0.56 (тест Alex: «подойди к рюкзаку» - а предмет «Боевой рюкзак»): по словам
	# названия, по началу слова (падежи) - только для предметов, что лежат на столе
	for b in _deskItemBodies():
		var k := _itemKey(b)
		if not k.begins_with(CustomItems.KEY_PREFIX):
			continue
		var nm := String(CustomItems.entry(k).get("name", ""))
		for w in nm.to_lower().replace("-", " ").split(" ", false):
			if w.length() >= 4 and low.contains(" " + w.left(4)):
				return [k, nm]
	var stems: Dictionary = Lang.pick(WISH_ITEM_STEMS, WISH_ITEM_STEMS_EN)
	for key in stems:
		for st in stems[key]:
			if low.contains(st):
				return [key, String(st).strip_edges().rstrip(",.!?")]
	return ["", ""]

func _hasAny(low: String, words: Array) -> bool:
	for w in words:
		if low.contains(w):
			return true
	return false

## Своя реплика персонажа: «хочу банан» / «поесть бы» - запоминаем желание.
func _noteOwnWish(text: String) -> void:
	var low := " " + text.to_lower() + " "
	var hungry := _hasAny(low, Lang.pick(HUNGER_WORDS, HUNGER_WORDS_EN))
	var hurt := _hasAny(low, Lang.pick(HEAL_WORDS, HEAL_WORDS_EN))
	if not (hungry or hurt or _hasAny(low, Lang.pick(WISH_WORDS, WISH_WORDS_EN))):
		return
	var m := _itemMentioned(low)
	if hurt and not HEAL_KEYS.has(m[0]):
		m = ["heal", ""] # «вылечи меня» / «дай бинт» - подойдёт любая медицина
	if m[0] == "" and not hungry:
		return
	_wishKey = m[0] if m[0] != "" else "food"
	_wishName = m[1]
	_wishAt = Time.get_ticks_msec()

## Реплика человека в разговоре: «держи», «хочешь банан?» - ждём подарок.
func _notePlayerOffer(text: String) -> void:
	var low := " " + text.to_lower() + " "
	if not _hasAny(low, Lang.pick(OFFER_WORDS, OFFER_WORDS_EN)):
		return
	_offerAt = Time.get_ticks_msec()
	var m := _itemMentioned(low)
	if m[0] != "": # «хочешь банан?» - теперь ждём именно его
		_wishKey = m[0]
		_wishName = m[1]
		_wishAt = _offerAt

## Когда персонаж последний раз ждал подарок (-1 - не ждёт).
func giftTime() -> int:
	if isPlayer or isUnconscious or isSleeping:
		return -1
	var now := Time.get_ticks_msec()
	var t := -1
	if now - _wishAt < GIFT_WINDOW_MS:
		t = _wishAt
	if now - _offerAt < GIFT_WINDOW_MS:
		t = maxi(t, _offerAt)
	return t

func onItemGiven(body: Node) -> void:
	if not is_instance_valid(body) or not gbData.settings.get("llmVisionEnabled", false) or gbData.settings.get("mutePassive", false):
		return
	var key := _itemKey(body)
	var desc := _itemDesc(key)
	if desc == "":
		return
	var now := Time.get_ticks_msec()
	var wishOn := now - _wishAt < GIFT_WINDOW_MS and _wishKey != ""
	_seenItems[body.get_instance_id()] = true # обычная реакция «новый предмет рядом» не нужна
	_itemCommentedAt[key] = now
	_lastItemReactionMsec = now
	_wishAt = -GIFT_WINDOW_MS
	_offerAt = -GIFT_WINDOW_MS
	LLMManager.requestItemReaction(_skinTag(), desc, _aiStateHint() + LLMManager.giftHint(_skinTag(), key, _wishKey if wishOn else "", _wishName, _isFoodKey(key), int(CustomItems.entry(key).get("taste", 5)), HEAL_KEYS.has(key)), func(text: String):
		if is_instance_valid(self) and not isSleeping and not isUnconscious:
			_queueMessage(text, 1.0, true, PRIO_DIALOGUE))



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
	"steak": "жареный стейк",
	"steakraw": "сырой стейк с кровью",
	"containercrate": "обычный ящик с припасами",
	"sawblade": "ржавое лезвие циркулярной пилы",
	"fentanyl": "шприц с сине-белой жидкостью - фентанил",
	"tranq": "шприц-дротик со снотворным - транквилизатор",
	"chair": "деревянный стул",
	"nightstand": "прикроватная тумбочка с ящиками",
	"hat": "шляпа",
	"beret": "берет",
	"glasses": "прозрачные очки",
	"kedrb": "пистолет-пулемёт Кедр-Б с глушителем, складным прикладом и вертикальным магазином", # 0.56: нарисованы Alex
	"m110": "чёрная снайперская винтовка M110 с бежевым прицелом, прикладом и магазином",
	"knifeclassic": "нож «Классика» с тёмным клинком - наследие операций по борьбе с террористами, много чего оно повидало на своём веку, пырнуло и зарезало", # 04.11: нарисовал друг Alex (firsov0004_27135), текст - Alex
	"veresk": "пистолет-пулемёт СР-2 «Вереск» с разложенным прикладом", # 04.11: рисунок от Alex
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
		var note: String = SPOKEN_NOTES.get(category, "")
		LLMManager.requestPooledReaction(poolKey, examples, func(text):
			if note != "":
				_spokenNotes[_spokenKey(text)] = note
			_queueMessage(tag + text, speed, urgent, PRIO_EMERGENCY if category in EMERGENCY_CATEGORIES else -1), styleHint, situation)
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
	if mood > 65.0 and randf() < 0.25:
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


func _aiPetCount() -> int:
	var n := 0
	for p in get_tree().get_nodes_in_group("pets"):
		if not p.isPlayer and not p.isUnconscious and not p.isSleeping: # 055.005: спящий не делит частоту (тест Alex: Милки молчал, пока Експи спал)
			n += 1
	return maxi(1, n)


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


## F2 (стенд застревания: у высокого рюкзака прыгала до 9 раз за прогулку): не больше двух прыжков
## подряд без продвижения к цели (на 40 px ближе, чем при прошлом прыжке) - потом сдаёмся.
const HOPS_WITHOUT_PROGRESS := 2
var _walkHops := 0 # прыжков подряд без продвижения в этой прогулке
var _walkHopGap := INF # сколько было до цели при прошлом прыжке
var _walkBestGap := INF # ближе всего к цели в этой прогулке (ведёт _walkTo)

## Перепрыгнуть предмет по дороге (не чаще раза в 0,9 с).
func _hopOver() -> void:
	if isPlayer:
		return # 0.56 (Alex: «перс-игрок иногда прыгает сам, даже когда я печатаю») - игрок прыгает только сам
	var now := Time.get_ticks_msec()
	if now < _stormAt:
		return
	if _walkBestGap < _walkHopGap - 40.0:
		_walkHops = 0 # после прошлого прыжка продвинулась - это уже другое препятствие
	if _walkHops >= HOPS_WITHOUT_PROGRESS:
		return
	_stormAt = now + 900
	_walkHops += 1
	_walkHopGap = _walkBestGap
	moveSys.jump(true) # F2: осознанный прыжок - без 4-секундной перезарядки обычного автопрыжка


## F2: впереди стена экрана, а не предмет - прыгать в неё бессмысленно.
func _wallAheadIsBorder() -> bool:
	if moveSys.wallDetect.is_colliding() and moveSys.wallDetect.get_collider() is StaticBody2D:
		return true
	var x: float = moveSys.rigid.global_position.x
	var w := float(GlobalVariable.screenWidth)
	return (moveSys.dir < 0.0 and x < 90.0) or (moveSys.dir > 0.0 and x > w - 90.0)


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


## targetBody (055.005, тест Alex: «съешь пиццу», а встал у ключа): по просьбе
## идти к предмету - перепрыгивать то, что лежит по дороге, и стоп только у цели.
func _walkTo(targetX: float, isCommand: bool = false, targetBody: Node = null) -> void:
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
	var bestGap := absf(targetX - startX) # F2: ближе всего к цели за эту прогулку
	_walkBestGap = bestGap
	_walkHopGap = INF
	_walkHops = 0
	moveSys.noJumpOver = targetBody # 0.56: цель не перепрыгиваем
	while t < timeLimit:
		# F2.9 (чек-лист Alex F2.8: шёл по просьбе, уронил без урона - встал и «только воздух ртом гоняет»):
		# по просьбе игрока падение не отменяет дело - встаёт (до 10 с) и идёт дальше
		if isCommand and ragdolled and not isSleeping and not isUnconscious and not beingDragged:
			var upWait := 0.0
			while ragdolled and upWait < 10.0 and not isSleeping and not isUnconscious and not beingDragged:
				await get_tree().create_timer(0.25).timeout
				upWait += 0.25
			if not ragdolled and not isSleeping and not isUnconscious and not beingDragged:
				wander = true
				_commandUntil = maxi(_commandUntil, Time.get_ticks_msec() + 15000)
				stuckFor = 0.0
				lastX = moveSys.rigid.global_position.x
				timeLimit = t + absf(targetX - lastX) / maxf(60.0, moveSys.maxspeed * 0.6) + 3.0
		if not wander or ragdolled or isSleeping or isUnconscious or beingDragged:
			break
		if not isCommand and Time.get_ticks_msec() < _commandUntil:
			break # игрок о чём-то попросил - обычная прогулка уступает
		var x: float = moveSys.rigid.global_position.x
		var dx := targetX - x
		if absf(dx) < 25.0:
			break
		# 0.56: дошёл до края цели. Раньше «дошёл» = луч впереди задел цель, а луч
		# длинный - у длинной M110 персонаж вставал заметно раньше (тест Alex 055.008)
		if targetBody != null and is_instance_valid(targetBody) and _gapTo(targetBody) < 30.0:
			break
		moveSys.dir = signf(dx)
		# пилу могли подкинуть уже по ходу прогулки - останавливаемся перед ней
		if _dangerAhead(moveSys.dir):
			break
		# 0.56 (тест Alex: по дороге к бинту Експи толкал бургер): низкий предмет
		# на пути луч не видит - перепрыгиваем всё, что лежит между нами и целью
		if targetBody != null and _otherItemAhead(targetBody, targetX):
			_hopOver()
		if _tallObstacleAhead():
			if targetBody != null and moveSys.wallDetect.get_collider() == targetBody:
				pass # цель впереди - просто идём дальше, до края (см. _gapTo выше)
			elif _inWithdrawal():
				_stormObstacle()
			elif targetBody != null:
				_hopOver()
			else:
				break # обходим: эта прогулка кончилась, следующая выберет другую цель
		# под фентанилом - заплетающиеся ноги: внезапные остановки
		if high and randf() < 0.08:
			moveSys.dir = 0
			await get_tree().create_timer(randf_range(0.4, 1.2)).timeout
		await get_tree().create_timer(0.1).timeout
		t += 0.1
		# упёрлась (в стену, ящик, который не перепрыгнуть) - сдаёмся
		# F2: «упёрлась» - нет продвижения к цели (хотя бы на 6 px за 0,1 с с лучшего места), а не
		# «стоит на месте»: упираясь, тело дёргается на 1-2 px, и прежний счётчик всё время сбрасывался
		# (стенд застревания: прыжков 0, толкала препятствие до конца прогулки)
		lastX = moveSys.rigid.global_position.x
		var gap := absf(targetX - lastX)
		if gap < bestGap - 6.0:
			bestGap = gap
			stuckFor = 0.0
		else:
			stuckFor += 0.1
		_walkBestGap = minf(_walkBestGap, gap)
		# F2 (тест Alex F1: Роза застряла перед «Набором инструментов» - лёжа на боку он ниже луча у
		# голени, а торчащие сверху отвёртки редкие, луч проходит между ними): упёрлась - прыгаем, и
		# без цели прогулки, не дожидаясь 4-секундной перезарядки обычного прыжка и не глядя, спиной
		# ли идёт; две попытки (_hopOver - не чаще раза в 0,9 с), потом сдаёмся. В стену экрана - нет.
		# Было: одна попытка в окне 0,6-0,75 с и только по дороге к предмету.
		if stuckFor >= 0.4 and stuckFor < 1.5 and not _wallAheadIsBorder():
			_hopOver()
		if stuckFor > 1.8:
			break
	moveSys.dir = 0
	moveSys.noJumpOver = null
	moveSys.maxspeed = _baseMaxSpeed
	_walkBestGap = INF
	_walkHopGap = INF
	_walkHops = 0


## 0.56: половина ширины предмета на экране (по картинке).
func _itemHalfWidth(b: Node) -> float:
	for c in b.get_children():
		if c is Sprite2D and c.texture != null:
			return c.get_rect().size.x * absf(c.global_scale.x) / 2.0
	return 20.0

## 0.56: сколько пикселей от персонажа до ближнего края предмета.
func _gapTo(b: Node) -> float:
	return absf(b.global_position.x - moveSys.rigid.global_position.x) - _itemHalfWidth(b)

## Другой предмет прямо впереди, на полу, между персонажем и целью.
func _otherItemAhead(targetBody: Node, targetX: float) -> bool:
	var sc: float = float(gbData.settings.get("petScale", 4.0)) / 4.0
	var x: float = moveSys.rigid.global_position.x
	var dir := signf(targetX - x)
	for b in _deskItemBodies():
		if b == targetBody or b == carrying:
			continue
		var dx: float = b.global_position.x - x
		if signf(dx) != dir or absf(dx) > absf(targetX - x):
			continue
		if b.global_position.y < moveSys.rigid.global_position.y - 150.0 * sc:
			continue # висит выше (на полке/в воздухе) - не мешает
		if _gapTo(b) < 45.0 * sc:
			return true
	return false

const PET_REJECT_MOOD := 60.0 # 04.11: шкала 0-100 (было 20 из -100..100)
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
		moodSys.mood += 0.075 # 0.56 (Alex): спящего гладить приятно - чуть-чуть, без голоса и без пробуждения
		return # спит - звук касания есть, но без голоса (раньше голос звучал до этой проверки)
	# Шипение (bark) уместно только при плохом настроении - при обычном или
	# хорошем всегда используем whine вместо случайного 50/50 выбора.
	if moodSys.mood < 40.0 and randf() < 0.5:
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
	moodSys.mood += 0.165 # было 0.5, потом 0.33; 04.11: шкала 0-100 - вдвое меньше
	moodSys._tempVal(1.665, 13) # было 5.0, потом 3.33
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
