extends SceneTree

var game: Node3D
var failures := 0
var checks := 0

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
	game.set_paused(false)
	game.phase = "LIVE"
	game.phase_left = 100
	await frames(3)
	print("INPUT_CONTEXT display=", DisplayServer.get_name(), " mouse_mode=", Input.mouse_mode, " paused=", game.paused, " phase=", game.phase, " health=", game.player.health)
	for slot in 4:
		game.player.equip(slot)
		await frames(16)
		var before: int = game.player.shot_count
		Input.action_press("fire")
		await frames(120)
		Input.action_release("fire")
		await frames(2)
		var shots: int = game.player.shot_count - before
		check(shots > 8 if slot < 2 else shots == 1, "Weapon %d held trigger: %d shots" % [slot, shots])
		if slot >= 2:
			Input.action_press("fire")
			await frames(2)
			Input.action_release("fire")
			check(game.player.shot_count == before + 2, "Weapon %d fires again on a fresh press" % slot)
	game.player.cooldown = 0
	var before: int = game.player.shot_count
	var tap := InputEventAction.new()
	tap.action = "fire"
	tap.pressed = true
	game.player._unhandled_input(tap)
	tap.pressed = false
	game.player._unhandled_input(tap)
	await frames(2)
	check(game.player.shot_count == before + 1, "Short press/release between physics ticks is not lost")
	game.player.pending_fire = true
	game.set_paused(true)
	check(not game.player.pending_fire, "Pause discards a queued shot")
	var yaw: float = game.player.rotation.y
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(120, -80)
	game.player._unhandled_input(motion)
	check(game.player.rotation.y == yaw, "Pause blocks mouse-look changes")
	game.set_paused(false)
	game.player._unhandled_input(motion)
	await frames(2)
	check(absf(angle_difference(yaw, game.player.rotation.y) + 120 * game.player.sensitivity) < 0.0001, "Mouse motion steers yaw across angle wrapping at configured sensitivity")
	check(absf(game.player.pitch - 80 * game.player.sensitivity) < 0.0001, "Mouse motion steers pitch")
	check(absf(game.player.camera.rotation.x - game.player.pitch - game.player.recoil.x) < 0.0001, "Physics shot camera uses current aim and recoil")
	print("INPUT: ", checks - failures, "/", checks, " passed")
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
