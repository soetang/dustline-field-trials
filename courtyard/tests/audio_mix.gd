extends SceneTree

## Actual engine stereo mix, not microphone/system audio capture. Run without
## --fixed-fps: audio processing follows wall time. Intended for native desktop.
var game: Node3D
var capture := AudioEffectCapture.new()
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func wait_ms(duration: int) -> void:
	var until := Time.get_ticks_msec() + duration
	while Time.get_ticks_msec() < until: await process_frame

func check(condition: bool, message: String) -> void:
	checks += 1
	if condition: print("PASS: ", message)
	else:
		failures += 1
		printerr("FAIL: ", message)

func measure(at: Vector3) -> Vector2:
	game.sound.stop_all()
	await wait_ms(100)
	capture.clear_buffer()
	game.sound.play_at("ak", at)
	await wait_ms(380)
	var buffer := capture.get_buffer(capture.get_frames_available())
	var energy := Vector2.ZERO
	for sample in buffer:
		energy += Vector2(sample.x * sample.x, sample.y * sample.y)
	print("AUDIO_MIX ", at, " frames=", buffer.size(), " stereo_energy=", energy)
	return energy

func run() -> void:
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	for bot in game.bots: bot.set_physics_process(false)
	game.player.set_physics_process(false)
	game.player.set_process(false)
	game.player.position = Vector3(1, 0, 4)
	game.player.rotation.y = 0
	game.player.camera.rotation = Vector3.ZERO
	game.set_paused(false)
	game.phase = "LIVE"
	game.phase_left = 100
	game.sound.muted = false
	capture.buffer_length = 2
	AudioServer.add_bus_effect(0, capture)
	await wait_ms(500)
	var left := await measure(Vector3(-2, 1.62, 4))
	var right := await measure(Vector3(4, 1.62, 4))
	check(left.x > 0.0001 and right.y > 0.0001, "Native mixer produces non-silent generated gunfire")
	check(left.x > left.y * 1.5 and right.y > right.x * 1.5, "Left/right world shots pan to the correct stereo channels")
	var clear := await measure(Vector3(1, 1.62, 10))
	var wall: Node3D = game.world.box(Vector3(1, 1.5, 7), Vector3(5, 3, 0.3), game.world.material(Color.GRAY), true)
	await wait_ms(100)
	var blocked := await measure(Vector3(1, 1.62, 10))
	check(clear.length_squared() > 0.0000001 and blocked.length() < clear.length() * 0.4, "Wall occlusion reduces actual mixed signal energy")
	wall.queue_free()
	await wait_ms(100)
	game.sound.muted = true
	var muted := await measure(Vector3(1, 1.62, 10))
	check(muted.length_squared() < 0.000000001, "Mute produces silence at engine output")
	AudioServer.remove_bus_effect(0, AudioServer.get_bus_effect_count(0) - 1)
	game.queue_free()
	await wait_ms(150)
	print("AUDIO_MIX: ", checks - failures, "/", checks, " passed")
	quit(0 if failures == 0 else 1)
