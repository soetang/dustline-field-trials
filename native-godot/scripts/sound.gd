class_name FieldSound
extends Node

## All samples are generated from seeded noise and oscillators, not recordings.
var samples: Dictionary = {}
var voices: Array[AudioStreamPlayer] = []
var world_voices: Array[AudioStreamPlayer3D] = []
var game: Node3D
var voice_index := 0
var world_index := 0
var muted := false:
	set(value):
		muted = value
		if value: stop_all()

func _ready() -> void:
	for i in 12:
		var voice := AudioStreamPlayer.new()
		voice.bus = "Master"
		add_child(voice)
		voices.append(voice)
	for i in 16:
		var voice := AudioStreamPlayer3D.new()
		voice.bus = "Master"
		voice.max_db = -6
		voice.unit_size = 7
		voice.panning_strength = 1
		add_child(voice)
		world_voices.append(voice)
	for type in ["m4", "ak", "awp", "deagle", "step", "reload", "hit", "beep", "start"]:
		samples[type] = synth(type)

func synth(type: String) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = type.hash()
	var rate := 22050
	var duration := 0.30 if type in ["awp", "deagle"] else 0.16
	if type in ["beep", "start"]: duration = 0.22
	var data := PackedByteArray()
	data.resize(int(rate * duration) * 2)
	var low := 0.0
	for i in data.size() / 2:
		var time := float(i) / rate
		var noise := rng.randf_range(-1.0, 1.0)
		low = lerpf(low, noise, 0.18)
		var value := 0.0
		match type:
			"m4", "ak", "awp", "deagle":
				var weight := 0.8 if type in ["awp", "ak"] else 0.5
				value = noise * exp(-time * 70.0) * 0.55 + low * exp(-time * 18.0) * weight
				value += sin(time * TAU * (85.0 - time * 130.0)) * exp(-time * 26.0) * 0.32
			"step": value = low * exp(-time * 48.0) * 0.6
			"reload": value = noise * exp(-fmod(time, 0.067) * 170.0) * 0.14
			"hit": value = (noise * 0.23 + sin(time * 740.0) * 0.18) * exp(-time * 48.0)
			"beep", "start": value = sin(time * TAU * (880.0 if type == "beep" else 660.0)) * sin(time / duration * PI) * 0.16
		# Tiny fade avoids a discontinuity at the end of generated samples.
		value *= minf(1.0, (duration - time) * 300.0)
		data.encode_s16(i * 2, int(clampf(value, -0.9, 0.9) * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.data = data
	return stream

func play(type: String, volume: float = 0.0, pitch: float = 1.0) -> void:
	if muted or not samples.has(type) or voices.is_empty(): return
	var voice := voices[voice_index % voices.size()]
	voice_index += 1
	voice.stream = samples[type]
	voice.volume_db = clampf(volume - 7.0, -40.0, 0.0)
	voice.pitch_scale = pitch
	voice.play()

func stop_all() -> void:
	for voice in voices: voice.stop()
	for voice in world_voices: voice.stop()

func occluded(at: Vector3, listener: Vector3) -> bool:
	if at.distance_squared_to(listener) < 0.01: return false
	var ray := PhysicsRayQueryParameters3D.create(listener, at, 1)
	return not game.get_world_3d().direct_space_state.intersect_ray(ray).is_empty()

func play_at(type: String, at: Vector3, volume: float = 0.0, pitch: float = 1.0) -> AudioStreamPlayer3D:
	if muted or game.paused or not samples.has(type) or world_voices.is_empty(): return null
	var listener: Vector3 = game.view_position()
	var distance := 20.0 if type == "step" else (40.0 if type == "beep" else 65.0)
	if at.distance_to(listener) >= distance: return null
	var blocked := occluded(at, listener)
	var voice := world_voices[world_index % world_voices.size()]
	world_index += 1
	voice.stop()
	voice.global_position = at
	voice.stream = samples[type]
	voice.max_distance = distance
	voice.volume_db = clampf(volume - 7.0 - (10.0 if blocked else 0.0), -45.0, -6.0)
	voice.attenuation_filter_cutoff_hz = 1600 if blocked else 10000
	voice.attenuation_filter_db = -24
	voice.pitch_scale = pitch
	voice.play()
	return voice
