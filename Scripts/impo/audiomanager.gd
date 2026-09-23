extends Node

#basic audio manager for handling playing multiple sounds at once, with
#the capabilities for random chance to play along with cooldowns for specific
#sounds and sound categories.

#works on the principle of generating temporary AudioStreamPlayers for each
#sound before deleting them

## List of cooldown groups.
var _cooldowns: Dictionary = {}
## Global sound volume multiplier.
var soundMult := 1.0

# AUDIO LIBRARY
#----------------
#expie sfx
@export var expie_whine: Array[AudioStream] = []
@export var expie_bark: Array[AudioStream] = []
var speech: AudioStream
@export var thudwoosh: AudioStream = load("res://assets/sounds/effects/thudswoosh.ogg")
#random sfx
@export var eat: AudioStream = load("res://assets/sounds/effects/eatCasSFX.wav")
#----------------

# NOTE: all individual sound toggles are handled in this script, but they are assigned in settings. not auto-made.

## Голосовой набор на скин, с кешем - см. getVoiceSet(). Раньше голос
## грузился ОДИН РАЗ на всю игру по общей настройке defaultSkin, поэтому
## АБСОЛЮТНО ЛЮБОЙ питомец (даже с другим визуальным скином) звучал
## одинаково - каждый должен запрашивать свой набор через getVoiceSet(
## своё_имя_скина) вместо обращения к expie_bark/expie_whine напрямую.
var _voiceSetCache: Dictionary = {} # имя скина -> {"whine":[], "bark":[], "speech":AudioStream}

## Falls back to the original "expie" voice set if a skin doesn't have its
## own res://assets/sounds/<SkinName>/ folder yet - so adding new species
## voices is just "create the folder", nothing breaks without it.
func _ready() -> void:
	var skinName: String = gbData.settings.get("defaultSkin", "Default")
	var defaultSet := getVoiceSet(skinName)
	# Оставлено для обратной совместимости с тем, что ещё не перешло на
	# getVoiceSet() явно - новый код должен использовать per-pet набор.
	expie_whine = defaultSet["whine"]
	expie_bark = defaultSet["bark"]
	speech = defaultSet["speech"]

	# set config volume
	AudioManager.soundMult = gbData.settings.get("soundVolume", 1.0)


## Возвращает (и кеширует) голосовой набор конкретного скина - вызывай с
## именем скина ЭТОГО ПИТОМЦА (см. behavior.gd::_skinTag()), а не полагайся
## на глобальные expie_bark/expie_whine, которые отражают только тот скин,
## что был активен при запуске игры.
func getVoiceSet(skinName: String) -> Dictionary:
	if _voiceSetCache.has(skinName):
		return _voiceSetCache[skinName]

	# Три места по порядку: (1) папка скина в user:// - для скинов, которые
	# игрок сам вручную скачал и распаковал (никогда не проходят через
	# импорт Godot, поэтому там могут быть обычные .ogg/.wav/.mp3 без
	# всяких сложностей); (2) встроенный в саму игру res://assets/sounds/
	# - для персонажей, которых добавил сам автор игры; (3) общий "expie"
	# по умолчанию, если ни того ни другого нет.
	var voicePath := "user://skin/%s/sounds/" % skinName
	if not DirAccess.dir_exists_absolute(voicePath):
		voicePath = "res://assets/sounds/%s/" % skinName
	if not DirAccess.dir_exists_absolute(voicePath):
		voicePath = "res://assets/sounds/expie/"

	var speechPath := voicePath + "speech.ogg"
	var voiceSet := {
		"whine": _load_sounds(voicePath + "whine/"),
		"bark": _load_sounds(voicePath + "bark/"),
		"speech": load(speechPath) if ResourceLoader.exists(speechPath) else load("res://assets/sounds/expie/speech.ogg"),
	}
	_voiceSetCache[skinName] = voiceSet
	return voiceSet


## Loads all sounds from this folder into an array.
func _load_sounds(path: String) -> Array[AudioStream]:
	var streams: Array[AudioStream] = []
	var dir := DirAccess.open(path)

	if not dir:
		push_error("There is no folder at this path: ", path)
		return streams

	dir.list_dir_begin()
	var file_name := dir.get_next()

	while file_name != "":
		if not dir.current_is_dir():
			# skip exported suffixes
			var clean_name := file_name.trim_suffix(".import").trim_suffix(".remap")

			if clean_name.ends_with(".wav") or clean_name.ends_with(".ogg") or clean_name.ends_with(".mp3"):
				var full_path := path + clean_name
				var stream := load(full_path) as AudioStream

				# dupe check for debug environment
				if stream and not streams.has(stream):
					streams.append(stream)

		file_name = dir.get_next()

	return streams

## Core function for playing sounds.
func play_sfx(stream: AudioStream,
	chance: float = 1.0,
	volume_db: float = 0.0,
	pitch_scale: float = 1.0,
	cooldown_check: bool = false,
	cooldown_sec: float = 0.5,
	cooldown_group: String = "",
	audio_bus = "Main",
	soundType: String = "" # "bark"/"whine" - явно, а не через принадлежность к глобальному массиву, раз голос теперь per-pet
) -> AudioStreamPlayer:
	# Im so, so sorry for this abomination of if statements...
	# check if this sound is enabled:
	if soundType == "bark" and not gbData.settings.barkSoundEnabled:
		return null
	if soundType == "whine" and not gbData.settings.whiningSoundEnabled:
		return null
	if stream == thudwoosh and !gbData.settings.pettingSoundEnabled:
		return null
	if stream == eat and !gbData.settings.eatingSoundEnabled:
		return null

	if not stream or randf() > chance:
		return null
		
	if cooldown_check and not check_cooldown(stream, cooldown_sec, cooldown_group):
		return null

	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.volume_db = volume_db + linear_to_db(soundMult)
	player.pitch_scale = pitch_scale
	player.bus = audio_bus
	player.finished.connect(player.queue_free)

	add_child(player)
	player.play()
	return player

## Picks a random sound from an array and plays it.
func play_random(sound_list: Array[AudioStream], chance: float = 1.0, volume_db: float = 0.0, pitch_scale: float = 1.0, cooldown_check: bool = false, cooldown_sec: float = 0.5, cooldown_group: String = "", soundType: String = "") -> AudioStreamPlayer:
	if sound_list.is_empty():
		return null
	return play_sfx(sound_list.pick_random(), chance, volume_db, pitch_scale, cooldown_check, cooldown_sec, cooldown_group, "Main", soundType)

## Weighted "which voice, if any" - e.g. playVoiceWeighted(voiceSet, 0.5, 0.25) means
## 50% chance of bark, 25% whine, and the remaining 25% is silence on purpose.
## overallChance additionally scales all three down together - e.g. 0.66
## makes everything (including the silence chance) about 1.5x less frequent.
## This is the code equivalent of padding a folder with "empty" sounds -
## same effect, no fake files needed.
## voiceSet - результат AudioManager.getVoiceSet(skinName) ЭТОГО питомца,
## не глобальный expie_bark/expie_whine.
func playVoiceWeighted(voiceSet: Dictionary, barkChance: float = 0.5, whineChance: float = 0.25, overallChance: float = 1.0, volume_db: float = 0.0, pitch_scale: float = 1.0, cooldown_check: bool = false, cooldown_sec: float = 0.5, cooldown_group: String = "") -> void:
	if randf() > overallChance:
		return
	var r := randf()
	if r < barkChance:
		play_random(voiceSet.get("bark", []), 1.0, volume_db, pitch_scale, cooldown_check, cooldown_sec, cooldown_group, "bark")
	elif r < barkChance + whineChance:
		play_random(voiceSet.get("whine", []), 1.0, volume_db, pitch_scale, cooldown_check, cooldown_sec, cooldown_group, "whine")
	# else: silence, on purpose

## Plays a specific sound from an array by file name.
func play_by_name(sound_list: Array[AudioStream], file_name: String, chance: float = 1.0, volume_db: float = 0.0, pitch_scale: float = 1.0, cooldown_check: bool = false, cooldown_sec: float = 0.5, cooldown_group: String = "") -> AudioStreamPlayer:
	for stream in sound_list:
		if stream and stream.resource_path.get_file() == file_name:
			return play_sfx(stream, chance, volume_db, pitch_scale, cooldown_check, cooldown_sec, cooldown_group)
	return null

## Check if the given audioStream is currently on a cooldown.
func check_cooldown(sound: Variant, cooldown_sec: float, cooldown_group: String) -> bool:
	var key: Variant
	
	if not cooldown_group.is_empty():
		key = cooldown_group
	else:
		key = sound

	var current_time := Time.get_ticks_msec()
	var cooldown_ms := int(cooldown_sec * 1000.0)

	if _cooldowns.has(key):
		if current_time - _cooldowns[key] < cooldown_ms:
			return false

	_cooldowns[key] = current_time
	return true
