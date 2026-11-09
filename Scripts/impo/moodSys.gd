extends Node
# yeah
# mood system or whatevah
# oh gosh

@export var tick: float = 0
@export var eyeNode: Sprite2D
@export var mouthNode: Sprite2D

@export var normalRate: float = 0.0045 # было 0.009 - настроение вдвое медленнее тянется к спокойному
#dont mind the numbers here theyre just placeholders until it gets loaded
var mood: float = 60.0
var trust: float = 10.0

## 04.11 (Alex): шкала настроения 0-100, как у всех параметров (было -100..100 с нулём посередине).
## 0 - хуже некуда, 50 - спокойное (к нему настроение само тянется), 100 - лучше некуда.
## Старое значение -> новое: (старое + 100) / 2; все прибавки и потери - вдвое меньше прежних,
## чтобы игра ощущалась так же. Сейвы и настройки переводятся один раз (SaveLoadSys.migrateMoodScale).
const MOOD_NEUTRAL := 50.0
const MOOD_UNIT := 0.5 # прибавки, посчитанные в старых единицах (calcmood) -> новые
const MOOD_SNAP := 0.025 # шаг округления: было 0.05 на старой шкале - иначе мелкие прибавки (сон +0.0125) пропадали бы

static func fromOldScale(v: float) -> float:
	return (v + 100.0) / 2.0


var petId: String = ""

@onready
var minmood = gbData.settings.get("minMood", 0.0)
@onready
var maxmood = gbData.settings.get("maxMood", 100.0)
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
	drugOffset = clampf(drugOffset + boost, 0.0, 75.0)
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
	minmood = gbData.settings.get("minMood", 0.0)
	maxmood = gbData.settings.get("maxMood", 100.0)

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
	# дрейф (голод/усталость/рэгдолл) и притяжение к спокойному - оба x0.5.
	var change: float = calcmood(1) * MOOD_UNIT * delta / 1.5
	if change < 0.0:
		change *= 0.5
	mood += change
	mood = clamp(mood, minmood, maxmood)
	mood = minf(mood, woundMoodCap())


	var pull: float = 1.0 - pow(1.0 - normalRate, delta)
	mood = lerp(mood, MOOD_NEUTRAL, pull)

	mood = clamp(mood, minmood, maxmood)
	mood = snappedf(mood, MOOD_SNAP)
	if gbData.devMode:
		print(str("mood: ", clamp(mood + snappedf(tempOffset, 0.05), minmood, maxmood), "(temporary offset: ", snappedf(tempOffset, 0.05), ")"))
		print(str("tick: ", calcmood(1.0)))
	if gbData.settings.get("lobotomize", false):
		mood = MOOD_NEUTRAL

	_sync_mood()


	return snappedf(clamp(mood + tempOffset + drugOffset, minmood, maxmood), MOOD_SNAP)


## 054.998, реабилитация: пока раны серьёзные, настроение выше потолка не
## поднимается (аптечками хп вылечить можно, а настроение - только лаской и едой).
## Потолок касается базового настроения; приход от фентанила идёт поверх.
## Ниже 30 хп - уже грустные фразы (LowPassive ниже 45), ниже 15 - VeryLowPassive (ниже 35).
## 04.11: шкала 0-100 - было -30 / -10 / 30.
const WOUND_CAP_CRITICAL := 35.0 # здоровье ниже 15
const WOUND_CAP_HEAVY := 45.0 # здоровье ниже 30
const WOUND_CAP_LIGHT := 65.0 # здоровье ниже 60

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
	total -= clamp(((1.0 - (gbData.data["saw"][petId]["health"] * 0.01)) * 1.5), 0.0, 1.5)
	return total

## Сдвиг настроения за тик - в СТАРЫХ единицах (moodCheck умножает на MOOD_UNIT).
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
	# ~-1,2 в минуту, ниже 30 - ~-3 в минуту (старые единицы)
	var hp: float = _health()
	if hp < 30.0:
		total -= 1.5
	elif hp < 60.0:
		total -= 0.6
	# 04.11: раньше здесь был clamp(total, minmood, maxmood) - на шкале 0-100 он съел бы
	# любой отрицательный сдвиг. Сдвиг за тик и так маленький.
	total = clampf(total, -10.0, 10.0)


	#print(total)
	return total
