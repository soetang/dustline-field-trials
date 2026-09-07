extends SceneTree

var game: Node3D
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if condition: print("PASS: ", message)
	else:
		failures += 1
		printerr("FAIL: ", message)

func frames(count: int) -> void:
	for i in count: await physics_frame

func run() -> void:
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	for bot in game.bots: bot.set_physics_process(false)
	game.player.set_physics_process(false)
	game.player.position = Vector3(1, 0, 4)
	game.set_paused(false)
	game.phase = "LIVE"
	game.phase_left = 100
	await frames(3)
	var sound: Node = game.sound
	check(sound.world_voices.size() == 16 and sound.voices.size() == 12, "Audio uses bounded spatial and local voice pools")
	var source := Vector3(1, 1.6, 9)
	check(sound.play_at("ak", source) == null, "Muted game does not allocate a world voice")
	sound.muted = false
	var voice: AudioStreamPlayer3D = sound.play_at("ak", source)
	check(voice != null and voice.global_position == source and voice.stream == sound.samples.ak, "World shot uses generated sample at its actual position")
	check(voice.panning_strength > 0 and voice.max_distance == 65 and voice.unit_size == 7, "World shot enables directional panning and finite distance attenuation")
	var clear_volume: float = voice.volume_db
	var clear_filter: float = voice.attenuation_filter_cutoff_hz
	check(not sound.occluded(source, game.view_position()), "Open firing lane is acoustically unobstructed")
	var wall: Node3D = game.world.box(Vector3(1, 1.5, 6.5), Vector3(5, 3, 0.3), game.world.material(Color.GRAY), true)
	await frames(3)
	voice = sound.play_at("ak", source)
	check(sound.occluded(source, game.view_position()), "Actual solid wall obstructs the sound path")
	check(voice.volume_db < clear_volume - 5 and voice.attenuation_filter_cutoff_hz < clear_filter, "Wall reduces volume and high-frequency cutoff")
	wall.queue_free()
	await frames(3)
	voice = sound.play_at("step", source)
	check(voice.max_distance == 20, "Footsteps have shorter reach than gunfire")
	voice = sound.play_at("beep", source)
	check(voice.max_distance == 40, "Device beep is spatial with a bounded hearing range")
	var index: int = sound.world_index
	check(sound.play_at("ak", Vector3(90, 1.6, 90)) == null and sound.world_index == index, "Inaudible distant shots do not consume a spatial voice")
	for i in 50: sound.play_at("ak", source)
	check(sound.world_voices.size() == 16, "Heavy gunfire reuses the pool without allocating scene nodes")
	sound.muted = true
	var stopped := true
	for world_voice in sound.world_voices: stopped = stopped and not world_voice.playing
	for local_voice in sound.voices: stopped = stopped and not local_voice.playing
	check(stopped, "Mute immediately stops already playing sounds")
	sound.muted = false
	sound.play_at("ak", source)
	game.set_paused(true)
	stopped = true
	for world_voice in sound.world_voices: stopped = stopped and not world_voice.playing
	check(stopped and sound.play_at("ak", source) == null, "Pause stops world sounds and prevents new ones")
	game.set_paused(false)
	game.player.take_hit(500, game.bots[4])
	game.spectator.cycle()
	await frames(3)
	check(game.view_position() == game.spectator.camera.global_position and game.spectator.camera.is_current(), "Spectator culling and engine audio listener use the current camera")
	sound.play_at("ak", game.view_position() + Vector3.RIGHT)
	game.new_round()
	stopped = true
	for world_voice in sound.world_voices: stopped = stopped and not world_voice.playing
	check(stopped, "Round reset stops old positional sounds")
	print("AUDIO: ", checks - failures, "/", checks, " passed")
	game.queue_free()
	# Let the real audio thread retire queued playbacks, even with fixed simulation FPS.
	var drain_until := Time.get_ticks_msec() + 150
	while Time.get_ticks_msec() < drain_until: await process_frame
	quit(0 if failures == 0 else 1)
