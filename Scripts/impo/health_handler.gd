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
	health = pet.get("health", health)
	LLMManager.lastKnownHealth = health
	_regenLoop()


## Health slowly regenerates on its own - placeholder rate, balance TBD.
## Light injuries (below HURT_THRESHOLD damage) heal back over time this way
## without needing an item.
func _regenLoop() -> void:
	while true:
		await get_tree().create_timer(10.0).timeout
		if gbData.settings.get("invincible", false):
			continue
		if health < maxhealth:
			health = clamp(health + 0.6, minhealth, maxhealth)
			pet.health = health
			LLMManager.lastKnownHealth = health
			get_parent()._applyInjuryLook()


func _onItemEnter(body: Node2D) -> void:
	if healDb == true:
		return
	if get_parent().isSleeping or get_parent().shocked or get_parent().isUnconscious:
		return
	if not body.has_node("properties"):
		return

	var props = body.get_node("properties").propertyTable
	var healAmount: float = props.get("healIfConsumable", 0.0)

	if healAmount <= 0.0:
		return # not a healing item (food etc. still go through hungerHandler)
	healDb = true

	if health >= maxhealth:
		awaitDB() # already full - item just gets consumed silently, no reaction
	else:
		AudioManager.play_sfx(AudioManager.eat) # заглушка, замени на свой звук лечения при желании
		health = clamp(health + healAmount, minhealth, maxhealth)
		pet.health = health
		LLMManager.lastKnownHealth = health
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
	LLMManager.lastKnownHealth = health
	gbData.savetodisk("user://SAVE.json", gbData.data)
	get_parent()._applyInjuryLook()

	if wasAlive and health <= 0.0:
		# Одна последняя реплика перед тишиной, а не мгновенное молчание -
		# goUnconscious() ставится СРАЗУ после вызова _say (внутри которого
		# проверка isUnconscious идёт только один раз, в самом начале), так
		# что этот конкретный запрос успевает уйти и потом отобразиться,
		# а вот все последующие вызовы _say уже блокируются.
		get_parent()._say("lastmoments")
		get_parent().goUnconscious()
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


func awaitDB() -> void:
	await get_tree().create_timer(cd).timeout
	healDb = false
