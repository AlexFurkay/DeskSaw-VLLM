extends Node
# yeah
# mood system or whatevah
# oh gosh

@export var tick: float = 0
@export var eyeNode: Sprite2D
@export var mouthNode: Sprite2D

@export var normalRate: float = 0.009
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

	mood += calcmood(1) * delta / 1.5
	mood = clamp(mood, minmood, maxmood)


	var pull: float = 1.0 - pow(1.0 - normalRate, delta)
	mood = lerp(mood, 0.0, pull)

	mood = clamp(mood, minmood, maxmood)
	mood = snappedf(mood, 0.05)
	if gbData.devMode:
		print(str("mood: ", clamp(mood + snappedf(tempOffset, 0.05), minmood, maxmood), "(temporary offset: ", snappedf(tempOffset, 0.05), ")"))
		print(str("tick: ", calcmood(1.0)))
	if gbData.settings.get("lobotomize", true):
		mood = 0.0

	_sync_mood()


	return snappedf(clamp(mood + tempOffset, minmood, maxmood), 0.05)
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
	total -= clamp(((1.0 - (pet["tired"] * 0.01)) * 1), 0.0, 1)
	print(str(clamp(((1.0 - (pet["tired"] * 0.01)) * 1), 0.0, 1)) + " 123123")
	if pet["hunger"] >= 85.0:
		total += 0.25
	#clamp to user settings
	total = clamp(total, minmood, maxmood)


	#print(total)
	return total
