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
@export var speech: AudioStream = load("res://assets/sounds/expie/speech.ogg")
@export var thudwoosh: AudioStream = load("res://assets/sounds/effects/thudswoosh.ogg")
#random sfx
@export var eat: AudioStream = load("res://assets/sounds/effects/eatCasSFX.wav")
#----------------

# NOTE: all individual sound toggles are handled in this script, but they are assigned in settings. not auto-made.


func _ready() -> void:
	expie_whine = _load_sounds("res://assets/sounds/expie/whine/")
	expie_bark = _load_sounds("res://assets/sounds/expie/bark/")
	# set config volume
	AudioManager.soundMult = gbData.settings.get("soundVolume", 1.0)


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
	audio_bus = "Main"
) -> AudioStreamPlayer:
	# Im so, so sorry for this abomination of if statements...
	# check if this sound is enabled:
	for sound in expie_bark:
		if stream == sound and !gbData.settings.barkSoundEnabled:
			return null
	for sound in expie_whine:
		if stream == sound and !gbData.settings.whiningSoundEnabled:
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
func play_random(sound_list: Array[AudioStream], chance: float = 1.0, volume_db: float = 0.0, pitch_scale: float = 1.0, cooldown_check: bool = false, cooldown_sec: float = 0.5, cooldown_group: String = "") -> AudioStreamPlayer:
	if sound_list.is_empty():
		return null
	return play_sfx(sound_list.pick_random(), chance, volume_db, pitch_scale, cooldown_check, cooldown_sec, cooldown_group)

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
