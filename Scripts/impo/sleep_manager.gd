extends Node

@onready var tiredness: float = 40

var maxtired := 100.0
var mintired := 0.0
#@onready var trust: float = gbData.data.save.trust
var likelihood := 0
var petId: String = ""
var pet

func loadFromSave(id: String) -> void:
	petId = id
	pet = gbData.data["saw"][petId]
	tiredness = pet.get("tired", tiredness)

func sleepCheck():
		if gbData.settings.get("sleepEnabled", true):
			#await get_tree().create_timer(5).timeout
			print(str(tiredness) + " tiredness")
			tiredness = snappedf(tiredness, 0.01)
			tiredness = clamp(tiredness, mintired, maxtired)
			pet.tired = tiredness

			if !self.get_parent().isSleeping:
				tiredness += 0.15
			gbData.savetodisk("user://SAVE.json", gbData.data)
			pass
			return tiredness
		else:
			return mintired
