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
const CRITICAL_HEALTH_THRESHOLD := 20.0 # ниже этого - не может встать, но остаётся в сознании и говорит

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
func goUnconscious() -> void:
	if isUnconscious:
		return
	isUnconscious = true
	_finalLinePending = true
	faceSys.setEmotion("sleep") # уже готовое состояние с закрытыми глазами, ничего рисовать не нужно


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
	"Тебя держат СЛИШКОМ долго и категорически не отпускают. Ты в настоящей ярости, почти рычишь и готова укусить - можешь даже выделить одно слово ЗАГЛАВНЫМИ буквами для акцента. Скажи это как утверждение или восклицание, не как вопрос."
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
	

	#im very sorry that i had to comment this out i have no idea what its supposed to do and it was throwing an error
	"""
	# Set debug text to Node's ID:
	$"../textParent/DebugText".text = "Test"
	print(get_parent().get_parent().get_children().find(self))
	connect("toggleDebugText", _on_debugToggle_signal)
	"""

		#setup For spawn
	_spawnGraceUntil = Time.get_ticks_msec() + 2000 # 2 сек. неприкосновенности сразу после спавна
	_initalSpawn()
	LLMManager.llmReaction.connect(_on_llm_reaction)
	LLMManager.aiEnabledChanged.connect(func(enabled): if enabled: _prewarmMyCategories())
	LLMManager.poolsCleared.connect(_prewarmMyCategories)
	if gbData.settings.get("llmVisionEnabled", false):
		_prewarmMyCategories()

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
		t + "lastmoments": dialogueSys.data.get("lastmoments", []),
		t + "healed": dialogueSys.data.get("healed", []),
		t + "fentanyl": dialogueSys.data.get("fentanyl", []),
		t + "withdrawal": dialogueSys.data.get("withdrawal", []),
		# готовая фраза нужна заранее: после передозировки персонаж сразу
		# отключается, и "живой" запрос к ИИ уже не успел бы прозвучать
		t + "overdose": dialogueSys.data.get("lastmoments", []),
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
		t + "lastmoments": CATEGORY_SITUATION.get("lastmoments", ""),
		t + "healed": CATEGORY_SITUATION.get("healed", ""),
		t + "fentanyl": CATEGORY_SITUATION.get("fentanyl", ""),
		t + "withdrawal": CATEGORY_SITUATION.get("withdrawal", ""),
		t + "overdose": CATEGORY_SITUATION.get("overdose", ""),
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
func _queueMessage(text: String, speed: float = 1.0, urgent: bool = false) -> void:
	if isUnconscious:
		# Последняя фраза (lastmoments/overdose) запрашивается ДО отключки,
		# но ответ ИИ может прийти уже после неё - раньше он здесь молча
		# выбрасывался. Пропускаем ровно одну срочную фразу и показываем сразу.
		if urgent and _finalLinePending:
			_finalLinePending = false
			_messageQueue.clear()
			_urgentInQueue = 0
			var finalText := _applyStupid(text)
			dialogueSys.setDia(finalText[0], speed + finalText[1], 2.0, true)
		return # 0 хп - state/screen/grab и всё остальное тоже не должно звучать, не только _say()
	if isSleeping:
		return # ответ ИИ мог прийти уже после того, как персонаж уснул - во сне молчим
	var processed := _applyStupid(text)
	text = processed[0]
	speed += processed[1]
	if urgent and (dialogueSys.isTyping or not dialogueSys.dialogueTimer.is_stopped()):
		# Urgent lines (screamBIG etc.) shouldn't politely wait behind
		# whatever's already on screen - cut it off now. setDia()'s own
		# typeOut() has a generation-counter guard that safely abandons the
		# old typing coroutine without corrupting the display, so calling
		# it again here is enough to interrupt cleanly.
		dialogueSys.setDia(text, speed, 2.0, true)
		return

	var entry := {"text": text, "speed": speed}
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

	dialogueSys.setDia(entry["text"], entry["speed"], 2.0, true)


func _on_llm_reaction(text: String) -> void:
	if beingDragged or isSleeping or shocked:
		return
	# у нескольких питомцев на экране — не все обязаны реагировать разом
	if gbData.data["saw"].size() > 1 and randf() < 0.5:
		return
	_queueMessage(text)

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
	# зависимость от фентанила живёт только в пределах одного запуска
	gbData.data["saw"][petId].erase("addiction") # старое поле из 051 - убираем из сейва


	tempRagdoll()
	
	#initialized stuff

	wandering()
	passivetalk()
	checker()
	itemWatch()
	drugLoop()
	pass

func sleep():
	#handle sleeep loop this is probably one of the worst ways i couldve handled this ill fix it later
	while get_tree():
			#print("2")
			if not isSleeping:
				# Разбудили ударом (wakeUp) - тело уже в рэгдолле от удара,
				# дальше подъёмом занимается tempRagdoll(), здесь только
				# гасим "сонные" эффекты и выходим.
				sleepParticle.emitting = false
				break
			if sleepHandler.sleepCheck() < 5.0:
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
		hungerHandler.hungercheck()
		var sleepN = sleepHandler.sleepCheck()
		var moodN = moodSys.moodCheck(.5)
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
				var canSleep: bool = Time.get_ticks_msec() >= _noSleepUntil and not ragdolled

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

			if moodN > 50.0:
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
		statUpd.stat.mood = moodN
		LLMManager.lastKnownMood = moodN
		statUpd.stat.hunger = hungerHandler.hungry
		statUpd.stat.health = healthHandler.health
		statUpd.stat.sleep = snapped(sleepN, 0.1) # ???? why was it like that before?
		statUpd.upd(statUpd.stat)

		await get_tree().create_timer(tick).timeout

func _physics_process(_delta: float) -> void:
	#detect speed and aiosdhfopjkasfguopjasfgsdfhcvio[]
	#and ragdoll based on taht
	if not ragdolled and (abs(moveSys.rigid.linear_velocity.x) > moveSys.ragdollspeed or beingDragged):
		_bodyPrevValid = false
		tempRagdoll(not beingDragged, false, abs(moveSys.rigid.linear_velocity.x)) # true = genuine uncontrolled fall, not a hand-release
	elif not ragdolled:
		# Стоит на ногах: ловим жёсткое приземление (падение вертикально,
		# например с ящика) - раньше проверялась только горизонтальная
		# скорость, и падение сверху вниз не считалось вообще.
		var bodyVel: Vector2 = moveSys.rigid.linear_velocity
		if _bodyPrevValid and _spawnSettled:
			var hit := (_prevBodyVel - bodyVel).length()
			if hit >= IMPACT_LIGHT:
				_bodyPrevValid = false
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
	var now := Time.get_ticks_msec()
	if now - _lastImpactMsec < IMPACT_COOLDOWN_MS:
		return
	var dmg := _damageForImpact(speed)
	if dmg <= 0.0:
		return
	_lastImpactMsec = now
	if LLMManager.debugTags:
		Console.print("[color=YELLOW]Удар: сила %.0f -> урон %.0f[/color]" % [speed, dmg])
	if isSleeping:
		wakeUp()
	_impactThisRagdoll = true
	healthHandler.applyDamage(dmg)
	if not shocked:
		shock()


# ---------------- Фентанил ----------------
## Доза: сильный, но временный подъём настроения, после него - спад ниже
## исходного. Каждая доза добавляет зависимость (только на этот запуск),
## с ней следующие дозы действуют слабее, а без новой дозы начинается
## ломка. OVERDOSE_DOSES доз подряд (каждая в пределах DOSE_CHAIN_MS от
## предыдущей) - передозировка, отключка как при 0 ХП. Все числа -
## стартовые, баланс потом.
const HIGH_DURATION_SEC := 300.0      # сколько держится эффект одной дозы
const HIGH_BOOST := 60.0              # прибавка к настроению у "чистого" персонажа
const COMEDOWN_FRACTION := 0.3        # после эффекта настроение падает на эту долю от прибавки
const ADDICTION_PER_DOSE := 20.0
const ADDICTION_DECAY_PER_MIN := 1.0
const WITHDRAWAL_THRESHOLD := 30.0    # с какой зависимости начинается ломка
const DOSE_CHAIN_MS := 300000         # дозы ближе друг к другу, чем это, считаются "подряд"
const OVERDOSE_DOSES := 4
var addiction := 0.0
var _dosesInRow := 0
var _lastDoseMsec := -10000000
var _nextWithdrawalLineMsec := 0


func _isHigh() -> bool:
	return Time.get_ticks_msec() - _lastDoseMsec < int(HIGH_DURATION_SEC * 1000.0)


func _inWithdrawal() -> bool:
	return addiction >= WITHDRAWAL_THRESHOLD and not _isHigh()


## Вызывается из health_handler.gd, когда шприц с фентанилом попал в персонажа.
func takeFentanyl() -> void:
	if isUnconscious:
		return
	var now := Time.get_ticks_msec()
	if now - _lastDoseMsec > DOSE_CHAIN_MS:
		_dosesInRow = 0
	_dosesInRow += 1
	_lastDoseMsec = now

	if _dosesInRow >= OVERDOSE_DOSES:
		dialogueSys.speedMod = 0.8
		_say("overdose")
		goUnconscious()
		return

	# чем сильнее зависимость, тем слабее эффект (толерантность)
	var boost: float = HIGH_BOOST / (1.0 + addiction / 40.0)
	moodSys.startDrugHigh(boost, HIGH_DURATION_SEC, boost * COMEDOWN_FRACTION)
	addiction = minf(100.0, addiction + ADDICTION_PER_DOSE)
	dialogueSys.speedMod = 0.8
	_say("fentanyl")


## Раз в 30 сек: зависимость понемногу спадает сама, а в ломке настроение
## ползёт вниз и время от времени звучит фраза из withdrawal.
func drugLoop() -> void:
	while get_tree():
		await get_tree().create_timer(30.0).timeout
		if isUnconscious:
			continue
		if addiction > 0.0:
			addiction = maxf(0.0, addiction - ADDICTION_DECAY_PER_MIN * 0.5)
		if not _inWithdrawal():
			continue
		moodSys.mood = clampf(moodSys.mood - addiction * 0.02, moodSys.minmood, moodSys.maxmood)
		var now := Time.get_ticks_msec()
		if now >= _nextWithdrawalLineMsec and not isSleeping and not beingDragged and not shocked:
			_nextWithdrawalLineMsec = now + randi_range(120000, 240000)
			_say("withdrawal")


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
	while true:
		var aiOn: bool = gbData.settings.get("llmVisionEnabled", false)
		var waitTime: float = randf_range(10.0, 15.0) if aiOn else (getUpTimer + randf_range(0, 5))
		await get_tree().create_timer(waitTime).timeout
		if beingDragged:
			if not isSleeping and not isUnconscious:
				if aiOn:
					_dragEscalationLevel += 1
					var idx: int = mini(_dragEscalationLevel - 1, DRAG_STAGE_DESCRIPTIONS.size() - 1)
					var key := "drag_level%d" % idx
					# Falls back to an empty array if the skin's translation
					# doesn't have this key yet - fully backward compatible,
					# these categories ran with zero examples before this.
					var examples: Array = _pickExamples(dialogueSys.data.get(key, []).duplicate(), 8)
					LLMManager.requestPooledEvent(_skinTag() + ":" + key, DRAG_STAGE_DESCRIPTIONS[idx], _on_drag_reaction, examples)
					# больше шипения (bark), чем дальше затягивается захват
					AudioManager.playVoiceWeighted(voiceSet, minf(0.95, 0.75 + 0.2 * idx), 0.3)
				else:
					AudioManager.play_random(voiceSet["whine"], 1.0, 0, 1, false, 0.5, "", "whine")
					dialogueSys.pool = dialogueSys.data.get("beingDragged", [])
					dialogueSys.send(10, false)
			#fix the weird ghost collision during ragdoll
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
		if dialogueSys.data.get("start", []).size() > 0:
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


# periodically check for a nearby item worth commenting on - runs on its
# own faster cadence, independent of the slower mood-based passivetalk loop
func itemWatch() -> void:
	# ВРЕМЕННО ОТКЛЮЧЕНО: реакции на предметы стабильно вызывали зависание ПК
	# при поднятии предмета мышкой. Логика оставлена нетронутой ниже на случай,
	# если понадобится включить обратно - просто убери "return" и комментарии.
	return
	while true:
		await get_tree().create_timer(randf_range(12.0, 20.0)).timeout
		if beingDragged or isSleeping or shocked:
			continue
		if not gbData.settings.get("llmVisionEnabled", false):
			continue
		var itemDesc := _getNearbyItemDescription()
		if itemDesc == "":
			continue
		if randf() < 0.6:
			LLMManager.reactToEvent("Ты замечаешь рядом с собой предмет: " + itemDesc + ". Прокомментируй его в своём духе - одной фразой.", func(text): _queueMessage(text, 1.0), "item")


# periodically send a message based on mood
func passivetalk() -> void:
	while true:
		if !gbData.settings.get("mutePassive", false):
			var diaTimerMinimum = float(GlobalVariable.getNumFromString(str(gbData.settings["minDialogueTime"])))

			var diaTimerMaximum = float(GlobalVariable.getNumFromString(str(gbData.settings["maxDialogueTime"])))

			print(diaTimerMinimum, "min")
			print(diaTimerMaximum, "max")
			await get_tree().create_timer(randf_range(float(diaTimerMinimum), float(diaTimerMaximum))).timeout
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
					elif _inWithdrawal():
						statLine += ", у тебя ломка - тебе плохо без фентанила"
					var examples: Array = _pickExamples(dialogueSys.pool.duplicate(), 10)
					LLMManager.requestStateReaction(statLine, examples, _on_state_reaction, _skinTag() + ":state")
				else:
					dialogueSys.send()
		else:
			await get_tree().create_timer(5.0).timeout
			
func _on_drag_reaction(text: String) -> void:
	if isSleeping:
		return
	_queueMessage(text, 1.0, true)


func _on_state_reaction(text: String) -> void:
	if beingDragged or isSleeping or shocked:
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
const LOUD_CATEGORIES := ["getUp", "getUpPet", "fell", "screamBIG", "LightDamage", "MediumDamage", "HardDamage"]

## Maps a spawned item's "itemName" meta to a human description for the AI.
## To support a new item, just add one line here - nothing else needs to
## change, no matter how many items exist.
const ITEM_DESCRIPTIONS := {
	"bread": "хлеб",
	"containercrate": "обычный ящик с припасами",
	"geofruit": "странный минеральный фрукт, наполовину похожий на камень",
	"medcrate": "медицинский ящик с аптечкой",
	"pizzaslice": "кусок пиццы",
	"sawblade": "ржавое лезвие циркулярной пилы",
	"yellowflesh": "кусок жёлтой плоти непонятного происхождения",
}

## Finds the closest known item currently in the pet's detection radius and
## returns its description, or "" if nothing recognized is nearby.
func _getNearbyItemDescription() -> String:
	var closestBody: Node2D = null
	var closestDist := INF
	for body in detectRange.inRadius.keys():
		if not is_instance_valid(body):
			continue
		var itemName: String = body.get_meta("itemName", "")
		if not ITEM_DESCRIPTIONS.has(itemName):
			continue
		var d: float = moveSys.rigid.global_position.distance_to(body.global_position)
		if d < closestDist:
			closestDist = d
			closestBody = body
	if closestBody == null:
		return ""
	return ITEM_DESCRIPTIONS[closestBody.get_meta("itemName")]

## Categories that are a reaction to something sudden happening right now -
## they should jump straight to the front of the display queue instead of
## waiting behind whatever ambient line is already lined up, same as drag.
const URGENT_CATEGORIES := ["petReject", "screamBIG", "fell", "pet", "LightDamage", "MediumDamage", "HardDamage", "lastmoments", "fentanyl", "overdose"]

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
	"hungry": "Ты сейчас голодна, хочешь есть.",
	"sleepy": "Тебя клонит в сон, ты сонная и вялая.",
	"reallySleepy": "Ты очень хочешь спать, вот-вот заснёшь прямо на месте.",
	"getUp": "Ты только что упала и теперь встаёшь на ноги.",
	"getUpPet": "Ты только что упала, но перед этим тебя долго гладили - вставая, ты всё ещё немного млеешь от этого.",
	"fell": "Ты только что неожиданно и неконтролируемо упала - это застало тебя врасплох.",
	"start": "Ты только что появилась на рабочем столе - самый первый момент, как ты здесь оказалась.",
	"screamBIG": "Тебя что-то резко напугало или ударило - ты вскрикиваешь от неожиданности.",
	"Full": "Тебе предлагают ещё еды, но ты уже наелась досыта.",
	"EatReject": "Тебе предлагают еду, но ты отказываешься её есть.",
	"EatBad": "Ты только что съела что-то невкусное или неприятное на вкус.",
	"EatOk": "Ты только что съела что-то так себе на вкус, не хорошее и не плохое.",
	"EatGood": "Ты только что съела что-то очень вкусное.",
	"grab": "Тебя только что схватили рукой и подняли в воздух.",
	"LightDamage": "Тебе только что было немного больно - лёгкий удар или падение, не критично, но неприятно.",
	"MediumDamage": "Тебе только что было по-настоящему больно - серьёзный удар или падение.",
	"HardDamage": "Тебе только что было ОЧЕНЬ больно - тяжёлый удар, здоровье на исходе, это серьёзно и страшно.",
	"lastmoments": "Твоё здоровье равно нулю. Это твоя последняя короткая фраза, драматичная или слегка пафосная, перед тем как ты навсегда потеряешь сознание.",
	"healed": "Тебе только что помогли вылечиться, тебе физически стало лучше, но ты всё ещё в невесёлом настроении.",
	"fentanyl": "Тебе только что вкололи фентанил. Накрывает тёплой волной - боль и тревога уходят, всё плывёт, тебе слишком хорошо.",
	"withdrawal": "У тебя ломка - давно не было фентанила. Тебя знобит, всё ломит, ты раздражена и тебе очень плохо, ты хочешь ещё дозу.",
	"overdose": "Тебе вкололи слишком много фентанила подряд - передозировка. Ты проваливаешься в тяжёлую темноту, это последние слова перед тем, как ты отключишься.",
}

## Категории без своих примеров в TRANSLATION.json - берут примеры из
## другой, близкой по духу категории.
const CATEGORY_EXAMPLES_FROM := {
	"overdose": "lastmoments",
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
	var allSprites: Array = skinmapper.getspr(root)
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

	# Overall severity, for parts that have more than one tier of art
	# (currently just the head) - how far into its own Disfigured1/2/3
	# progression an already-picked part should be.
	var severity: int = 1
	if hp <= 15.0:
		severity = 3
	elif hp <= 40.0:
		severity = 2

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


func _say(category: String, cooldown: float = 0.0, ignoreCooldown: bool = true) -> void:
	if isUnconscious:
		return # 0 хп - персонаж без сознания, молчит до перезапуска приложения
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
		var situation: String = CATEGORY_SITUATION.get(category, "")
		# Пул прогрева ключуется по "Скин:категория" - иначе разные персонажи
		# (когда их станет больше одного) делили бы один и тот же пул и
		# путались бы в стиле друг друга.
		LLMManager.requestPooledReaction(_skinTag() + ":" + category, examples, func(text): _queueMessage(tag + text, speed, urgent), styleHint, situation)
	else:
		dialogueSys.send(cooldown, ignoreCooldown)
	
func wandering() -> void:
	while get_tree():
		if wander:
			var restChance = randi_range(1, 22)
			if restChance == 1: moveSys.initswithc(moveSys.states.resting)
			await get_tree().create_timer(randi_range(4, 8)).timeout

			var center = GlobalVariable.screenWidth / 2.0
			var ex = moveSys.rigid.global_position.x
			var offset = ex - center
			var th = GlobalVariable.screenWidth * 0.25

			if offset > th:
				moveSys.dir = -1
			elif offset < -th:
				moveSys.dir = 1
			else:
				moveSys.dir = randi_range(-1, 1)

			await get_tree().create_timer(randf_range(.5, 2.0)).timeout
			
			moveSys.dir = 0
		else:
			await get_tree().create_timer(randi_range(4, 8)).timeout

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

	if moodSys.mood + moodSys.drugOffset < 10.0: # под фентанилом ласку принимает даже при плохом базовом настроении
		petReject()
		return

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
