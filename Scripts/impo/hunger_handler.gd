extends Node

@onready var hungry: float = 0.0


@export var mouth: RapierArea2D
var maxhunger := 100.0
var minhunger := 0.0
#@onready var trust: float = gbData.data.save.trust
var petId: String = ""
var pet


#adding this because if they were hungry enough theyd just become a food black hole
var cd: float = 3.0
var foodDb = false
@export var dialogue: Node
func loadFromSave(id: String) -> void:
	petId = id
	pet = gbData.data["saw"][petId]
	hungry = pet.get("hunger", hungry)


func hungercheck():
		if gbData.settings.get("hungerEnabled", true):
			#await get_tree().create_timer(5).timeout
			hungry -= 0.05
			#print(str(hungry) + " hunger")
			hungry = snappedf(hungry, 0.01)
			hungry = clamp(hungry, minhunger, maxhunger)
			pet.hunger = hungry
			gbData.savetodisk("user://SAVE.json", gbData.data)
			pass
			return hungry
		else:
			return maxhunger


func _onItemEnter(body: Node2D) -> void:
	#consolidate this later
	if foodDb == true:
		return
	if get_parent().isSleeping or get_parent().shocked or get_parent().isUnconscious:
		return
	if not body.has_node("properties"):
		return

	var props = body.get_node("properties").propertyTable

	if not props.consumable:
		return
	if props.get("healIfConsumable", 0.0) > 0.0:
		return # medical item - healthHandler handles this one, not food logic
	if props.get("drug", "") != "":
		return # препарат (фентанил) - тоже healthHandler, иначе тут прозвучало бы "не буду это есть"
	foodDb = true

	if hungry >= 98.0:
		get_parent()._say("Full")
		awaitDB()
		return
	if props.tasteIfConsumable == 0:
		get_parent()._say("EatReject")
		awaitDB()
		return
	# 054.998: вкус - свой у каждого персонажа (паспорт), настроение - по вкусу
	var itemKey: String = get_parent()._itemKey(body) # и пользовательские ("custom:<id>")
	var taste: int = get_parent().tasteFor(itemKey, int(props.tasteIfConsumable))
	AudioManager.play_sfx(AudioManager.eat)
	hungry += props.replenishIfConsumable
	var moodSys = get_parent().moodSys
	var boost := _moodForTaste(taste)
	if boost > 0.0 and get_parent().addiction > get_parent().HEAVY_ADDICTION and get_parent()._inWithdrawal():
		boost *= 0.5 # тяжёлая ломка - еда радует вдвое меньше
	if not get_parent().isPlayer:
		# вверх - не выше потолка ран (moodSys.woundMoodCap)
		moodSys.mood = clampf(moodSys.mood + boost, moodSys.minmood, maxf(moodSys.mood, minf(moodSys.maxmood, moodSys.woundMoodCap())))
	get_parent().onAte(taste)
	get_parent()._say(_getTasteCategory(taste))

	body.queue_free()
	awaitDB()


func awaitDB() -> void:
	await get_tree().create_timer(cd).timeout
	foodDb = false
	pass
## Вкус 10 -> +4, 5 -> 0, 1 -> -2 (невкусное опускает не сильно - решение Alex).
## Раньше настроение было свойством предмета, одно на всех (плоть -6 даже Дюне).
func _moodForTaste(taste: int) -> float:
	if taste >= 5:
		return (taste - 5) * 0.8
	return -(5 - taste) * 0.5


func _getTasteCategory(taste: int) -> String:
	if taste <= 3:
		return "EatBad"
	elif taste <= 6:
		return "EatOk"
	else:
		return "EatGood"

"""
					dialogueSys.pool = dialogue.data.sleepy
					dialogueSys.send()
					ao[sdkfopasdifpas pfasip[df pasdf p[asdp[asjdfjsdpfjasoi dfjiopasdfjiopasdfjiopasfjipasdjf[ipasjfipj]]]]]
					"""
