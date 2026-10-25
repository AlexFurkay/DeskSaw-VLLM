extends Node
# yeah
# mood system or whatevah
# oh gosh

@export var tick: float = 0
@export var eyeNode: Sprite2D
@export var mouthNode: Sprite2D

@export var normalRate: float = 0.0045 # было 0.009 - настроение вдвое медленнее тянется к нулю
#dont mind the numbers here theyre just placeholders until it gets loaded
var mood: float = 20.0
var trust: float = 10.0


var petId: String = ""

@onready
var minmood = gbData.settings.get("minMood", -100)
@onready
var maxmood = gbData.settings.get("maxMood", 100)
var pet
#for temporary events
var tempOffset: float = 0.0
## Отдельно от tempOffset: поглаживания/испуг перезаписывают tempOffset
## через _tempVal(), и они бы мгновенно "сбивали" действие дозы.
var drugOffset: float = 0.0
var _drugTween: Tween

## Фентанил: настроение резко вверх на boost, плавно спадает за duration,
## в конце - "отходняк": базовое настроение падает на comedown.
func startDrugHigh(boost: float, duration: float, comedown: float) -> void:
	if _drugTween and _drugTween.is_valid():
		_drugTween.kill()
	drugOffset = clampf(drugOffset + boost, 0.0, 150.0)
	_drugTween = create_tween()
	_drugTween.tween_property(self, "drugOffset", 0.0, duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_drugTween.tween_callback(func(): mood = clampf(mood - comedown, minmood, maxmood))
#make sure things are updated


func loadFromSave(id: String) -> void:
	petId = id
	pet = gbData.data["saw"][petId]
	mood = pet.get("mood", mood)
	trust = pet.get("trust", trust)

func _sync_mood() -> void:
	minmood = gbData.settings.get("minMood", -100)
	maxmood = gbData.settings.get("maxMood", 100)

	pet["mood"] = mood
	gbData.data["saw"][petId]["mood"] = mood

	gbData.savetodisk("user://SAVE.json", gbData.data)
#for temporary offsets
func _tempVal(offset: float = 0.0, decayLength: float = 0.0):
	tempOffset = offset
	var tween := create_tween().set_trans(Tween.TRANS_LINEAR).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "tempOffset", 0.0, decayLength)
	pass

# called every tick byu behavoapf[jas[ghnasdfo[gubsdo[ub ]]]]
func moodCheck(delta: float = 1.0) -> float:
	if gbData.settings.get("invincible", false):
		return mood

	# Падение настроения замедлено вдвое (просьба 2026-10-14): отрицательный
	# дрейф (голод/усталость/рэгдолл) и притяжение к нулю - оба x0.5.
	var change: float = calcmood(1) * delta / 1.5
	if change < 0.0:
		change *= 0.5
	mood += change
	mood = clamp(mood, minmood, maxmood)
	mood = minf(mood, woundMoodCap())


	var pull: float = 1.0 - pow(1.0 - normalRate, delta)
	mood = lerp(mood, 0.0, pull)

	mood = clamp(mood, minmood, maxmood)
	mood = snappedf(mood, 0.05)
	if gbData.devMode:
		print(str("mood: ", clamp(mood + snappedf(tempOffset, 0.05), minmood, maxmood), "(temporary offset: ", snappedf(tempOffset, 0.05), ")"))
		print(str("tick: ", calcmood(1.0)))
	if gbData.settings.get("lobotomize", false):
		mood = 0.0

	_sync_mood()


	return snappedf(clamp(mood + tempOffset + drugOffset, minmood, maxmood), 0.05)


## 054.998, реабилитация: пока раны серьёзные, настроение выше потолка не
## поднимается (аптечками хп вылечить можно, а настроение - только лаской и едой).
## Потолок касается базового настроения; приход от фентанила идёт поверх.
## 054.999: под шкалу -100..100 (Alex: потолок 20 при 30 хп - это ещё 120 из 200).
## Ниже 30 хп - уже грустные фразы (LowPassive с -10), ниже 15 - VeryLowPassive (с -30).
const WOUND_CAP_CRITICAL := -30.0 # здоровье ниже 15
const WOUND_CAP_HEAVY := -10.0 # здоровье ниже 30
const WOUND_CAP_LIGHT := 30.0 # здоровье ниже 60

func woundMoodCap() -> float:
	var hp: float = _health()
	if hp < 15.0:
		return WOUND_CAP_CRITICAL
	if hp < 30.0:
		return WOUND_CAP_HEAVY
	if hp < 60.0:
		return WOUND_CAP_LIGHT
	return maxmood


func _health() -> float:
	var mas = get_parent()
	if mas and mas.healthHandler:
		return mas.healthHandler.health
	return 100.0


func tempCalc(total: float = 0.0):
	total -= clamp(((1.0 - (gbData.data["saw"][petId]["health"] * 0.01)) * 3), 0.0, 3)
	total = clamp(total, minmood, maxmood)
	return total

func calcmood(total: float):
	#health
	#hunger
	var mas = self.get_parent()
	if mas.ragdolled and not mas.isSleeping:
		if gbData.devMode:
			print("dragged so substract")
		total -= 2.25
	if mas.isSleeping:
		total += 1.75
	total -= clamp(((1.0 - (pet["hunger"] * 0.01)) * 1), 0.0, 1)
	#trust
	# 055.005 (тест Alex: настроение только падает): штраф был перевёрнут -
	# 1 - усталость/100 бил сильнее всего ВЫСПАВШЕГОСЯ (усталость растёт, пока
	# не спит: sleep_manager +0.15). Теперь штраф растёт вместе с усталостью:
	# сытый и бодрый - настроение растёт, голодный и вымотанный - падает.
	total -= clamp(pet["tired"] * 0.01, 0.0, 1.0)
	# лёгкое колебание - настроение «плавает» само по себе, а не стоит на месте
	total += randf_range(-0.3, 0.3)
	if pet["hunger"] >= 85.0:
		total += 0.25
	# 054.998: раны давят на настроение постоянно (как голод): ниже 60 хп
	# ~-1,2 в минуту, ниже 30 - ~-3 в минуту
	var hp: float = _health()
	if hp < 30.0:
		total -= 1.5
	elif hp < 60.0:
		total -= 0.6
	#clamp to user settings
	total = clamp(total, minmood, maxmood)


	#print(total)
	return total
