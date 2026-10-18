extends Node

@onready var health: float = 100.0

@export var mouth: RapierArea2D
var maxhealth := 100.0
var minhealth := 0.0
var petId: String = ""
var pet

# same debounce pattern as hunger_handler - without it a bandage sitting in
# the mouth's detection radius would keep re-triggering every physics frame
var cd: float = 3.0
var healDb = false


func loadFromSave(id: String) -> void:
	petId = id
	pet = gbData.data["saw"][petId]
	# Каждый спавн/перезапуск - с полным здоровьем, а не с тем, что было
	# сохранено. Иначе после "отключки" на 0 ХП персонаж загружался почти
	# мёртвым и не мог встать, пока ХП не отрастёт выше 20.
	health = maxhealth
	pet.health = health
	_regenLoop()


## Health slowly regenerates on its own - placeholder rate, balance TBD.
## Light injuries (below HURT_THRESHOLD damage) heal back over time this way
## without needing an item.
## 054.991: тяжело раненый сам не выздоравливает - ноет и просит помощи,
## пока человек его не подлечит. Раньше +0.6 каждые 10 с при любом здоровье:
## персонаж ниже 20 вставал сам через минуту-три, и раны почти не ощущались.
const REGEN_BASE := 0.6          # было за 10 с
const REGEN_OFF_BELOW := 15.0     # ниже - не восстанавливается совсем
const REGEN_SLOW_BELOW := 30.0    # 15-30 - в 2 раза медленнее, выше 30 - в 1.5 раза

func _regenPerTick(hp: float) -> float:
	if hp < REGEN_OFF_BELOW:
		return 0.0
	if hp < REGEN_SLOW_BELOW:
		return REGEN_BASE / 2.0
	return REGEN_BASE / 1.5


func _regenLoop() -> void:
	while true:
		await get_tree().create_timer(10.0).timeout
		if gbData.settings.get("invincible", false):
			continue
		if get_parent().isUnconscious:
			continue # без сознания (0 ХП или передозировка) - само не лечится, это до перезапуска
		if health < maxhealth:
			var gain := _regenPerTick(health)
			if gain <= 0.0:
				continue
			health = clamp(health + gain, minhealth, maxhealth)
			pet.health = health
			get_parent()._applyInjuryLook()


func _onItemEnter(body: Node2D) -> void:
	if healDb == true:
		return
	if get_parent().isSleeping or get_parent().shocked or get_parent().isUnconscious:
		return
	if not body.has_node("properties"):
		return

	var props = body.get_node("properties").propertyTable

	# Препараты (сейчас только фентанил) - своя логика в behavior.gd.
	# Действует ТОЛЬКО если укол делает игрок: шприц у него в руке или
	# только что отпущен. Сама себе персонаж не колет никогда - даже если
	# шприц случайно окажется у головы (лежит на тумбочке, отскочил и т.п.).
	if props.get("drug", "") == "fentanyl":
		if not _givenByUser(body) or get_parent().isPlayer:
			return # перс-игроку фентанил не действует (механика отключена) - шприц просто не тратится
		healDb = true
		AudioManager.play_sfx(AudioManager.injection)
		get_parent().takeFentanyl()
		body.queue_free()
		awaitDB()
		return

	var healAmount: float = props.get("healIfConsumable", 0.0)

	if healAmount <= 0.0:
		return # not a healing item (food etc. still go through hungerHandler)
	healDb = true

	if health >= maxhealth:
		awaitDB() # already full - item just gets consumed silently, no reaction
	else:
		# 054.995: шприц и бинт - звук укола, аптечка - свой звук лечения
		# (раньше все три звучали как аптечка)
		var itemKey: String = body.scene_file_path.get_file().get_basename()
		AudioManager.play_sfx(AudioManager.injection if itemKey in ["syringe", "bandage"] else AudioManager.heal)
		health = clamp(health + healAmount, minhealth, maxhealth)
		pet.health = health
		# 054.998: лечение немного поднимает настроение - но до 100 его
		# аптечками не вытянуть, остальное - лаской и едой
		var moodSys = get_parent().moodSys
		if not get_parent().isPlayer: # у игрока настроение отключено
			moodSys.mood = clampf(moodSys.mood + HEAL_MOOD.get(itemKey, 3.0), moodSys.minmood, minf(moodSys.maxmood, moodSys.woundMoodCap()))
		gbData.savetodisk("user://SAVE.json", gbData.data)
		get_parent()._applyInjuryLook()
		get_parent()._say("healed")

	body.queue_free()
	awaitDB()


## Called by behavior.gd's tempRagdoll() when a real fall/hit happens.
## Numbers are placeholders - balance later, per the plan.
func applyDamage(amount: float) -> void:
	if gbData.settings.get("invincible", false):
		return
	var wasAlive: bool = health > 0.0
	health = clamp(health - amount, minhealth, maxhealth)
	pet.health = health
	# 054.998: удар бьёт и по настроению - по силе удара (5 урона -> -5).
	# Раньше любой удар отнимал одинаковые 2,5 (это осталось в shock()).
	var moodSys = get_parent().moodSys
	if not get_parent().isPlayer: # у игрока настроение отключено
		moodSys.mood = clampf(moodSys.mood - amount * DAMAGE_MOOD_PER_HP, moodSys.minmood, moodSys.maxmood)
	gbData.savetodisk("user://SAVE.json", gbData.data)
	get_parent()._applyInjuryLook()

	if wasAlive and health <= 0.0:
		# Одна последняя реплика перед тишиной, а не мгновенное молчание -
		# goUnconscious() ставится СРАЗУ после вызова _say (внутри которого
		# проверка isUnconscious идёт только один раз, в самом начале), так
		# что этот конкретный запрос успевает уйти и потом отобразиться,
		# а вот все последующие вызовы _say уже блокируются.
		get_parent()._sayFinal("lastmoments") # 054.991: сразу на экран, мимо очереди
		get_parent().goUnconscious(false)
		return

	if amount >= HARD_DAMAGE_THRESHOLD:
		_spawnBlood(BLOOD_PARTICLES_HARD)
		get_parent()._say("HardDamage")
	elif amount >= MEDIUM_DAMAGE_THRESHOLD:
		_spawnBlood(BLOOD_PARTICLES_MEDIUM)
		get_parent()._say("MediumDamage")
	elif amount >= LIGHT_DAMAGE_THRESHOLD:
		_spawnBlood(BLOOD_PARTICLES_LIGHT)
		get_parent()._say("LightDamage")
	# else: too small to react to on its own - the existing fell/getUp line already covers it


const DAMAGE_MOOD_PER_HP := 1.0
const HEAL_MOOD := {"bandage": 3.0, "syringe": 5.0, "medkit": 8.0}
const LIGHT_DAMAGE_THRESHOLD := 5.0
const MEDIUM_DAMAGE_THRESHOLD := 15.0
const HARD_DAMAGE_THRESHOLD := 30.0

const BLOOD_BURST_SCENE := preload("res://scenes/effects/blood_burst.tscn")

## ЭТИ ТРИ СТРОЧКИ - то самое место, где сам крутишь количество частиц на
## каждый уровень тяжести. Формат [минимум, максимум] - реальное число берётся
## случайно из этого диапазона при каждом попадании. Пока это грубая прикидка
## (5-10 / 12-20 / 25-40) - подбирай, что выглядит уместно на глаз.
const BLOOD_PARTICLES_LIGHT := [15, 20]
const BLOOD_PARTICLES_MEDIUM := [20, 40]
const BLOOD_PARTICLES_HARD := [40, 50]

func _spawnBlood(countRange: Array) -> void:
	var burst = BLOOD_BURST_SCENE.instantiate()
	get_tree().current_scene.add_child(burst)
	burst.global_position = get_parent().moveSys.rigidtorso.global_position
	burst.burst(randi_range(countRange[0], countRange[1]))


func _givenByUser(body: Node) -> bool:
	var drag = body.get_node_or_null("draggable")
	if drag and drag._dragging:
		return true
	var releasedAt: int = body.get_meta("releasedAt", -100000)
	return Time.get_ticks_msec() - releasedAt < 2000


func awaitDB() -> void:
	await get_tree().create_timer(cd).timeout
	healDb = false
