extends SceneTree

## Staged native character/pose inspection, not a live-match recording.
var game: Node3D
var folder := "res://builds/operators-04"

func _initialize() -> void:
	call_deferred("run")

func frames(count: int) -> void:
	for i in count: await process_frame

func capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path(folder).path_join(label + ".png")
	var error := root.get_texture().get_image().save_png(path)
	print("OPERATOR_CAPTURE ", path, " result=", error)

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="): folder = arg.trim_prefix("--capture-dir=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.set_paused(false)
	game.set_physics_process(false)
	game.phase = "LIVE"
	game.phase_left = 100
	game.banner_left = 0
	game.player.set_physics_process(false)
	game.player.set_process(false)
	game.player.held.visible = false
	game.player.position = Vector3(.55, -.16, -29.6)
	game.player.rotation.y = PI
	game.player.camera.rotation.x = -.10
	for bot in game.bots:
		bot.set_physics_process(false)
		bot.model.visible = false
	var ct: Node3D = game.bots[0]
	var attacker: Node3D = game.bots[4]
	for bot in [ct, attacker]:
		bot.model.visible = true
		bot.position = Vector3(-.10 if bot == ct else 1.2, 0, -26.5)
		bot.rotation.y = 0
		bot.look_goal = game.player.camera.global_position
	await frames(90)
	await capture("operators-front")
	for bot in [ct, attacker]:
		bot.rotation.y = .7
		bot.look_goal = bot.eye() - bot.global_basis.z * 8
	await frames(30)
	await capture("operators-quarter")
	for bot in [ct, attacker]:
		bot.velocity = Vector3(0, 0, -4.65)
		bot.travel = 0.35
	await frames(20)
	await capture("operators-stride")
	for bot in [ct, attacker]:
		bot.velocity = Vector3.ZERO
		bot.reload_left = 1.5
	await frames(20)
	await capture("operators-reload")
	print("OPERATORS_VISUAL_OK")
	game.queue_free()
	await process_frame
	quit()
