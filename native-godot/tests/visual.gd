extends SceneTree

## Real renderer smoke/capture. Staged shots are labelled, not gameplay benchmarks.
const Layout = preload("res://scripts/layout.gd")
var game: Node3D
var folder := "res://builds/captures"

func _initialize() -> void:
	call_deferred("run")

func frames(count: int) -> void:
	for i in count: await process_frame

func physics_frames(count: int) -> void:
	for i in count: await physics_frame

func capture(label: String) -> void:
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path(folder).path_join(label + ".png")
	var result := root.get_texture().get_image().save_png(path)
	print("VISUAL_CAPTURE ", path, " result=", result)

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="): folder = arg.trim_prefix("--capture-dir=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var scene: PackedScene = load("res://main.tscn")
	game = scene.instantiate()
	root.add_child(game)
	current_scene = game
	await frames(90)
	await capture("menu")
	game.set_paused(false)
	game.phase = "LIVE"
	game.phase_left = 100
	game.notify("NATIVE RENDERER PLAYTEST", 2.0)
	game.diagnostics = true
	for bot in game.bots: bot.set_physics_process(false)
	var start: Vector3 = game.player.position
	Input.action_press("forward")
	await physics_frames(120)
	Input.action_release("forward")
	await frames(8)
	await capture("ct-middle")
	print("NATIVE_MOVEMENT ", game.player.position.distance_to(start))
	Input.action_press("fire")
	await physics_frames(45)
	Input.action_release("fire")
	print("NATIVE_SHOTS ", game.player.shot_count)
	game.player.reload_weapon()
	while game.player.reload_left > 0: await physics_frame
	await frames(3)
	print("NATIVE_AMMO_AFTER_RELOAD ", game.player.ammo)
	if game.player.position.distance_to(start) < 3 or game.player.shot_count < 1 or game.player.ammo != 30:
		printerr("NATIVE_VISUAL_FAILED controls/reload")
		quit(1)
		return
	# Staged environment views for visual review, not a claimed continuous playthrough.
	for bot in game.bots: bot.set_physics_process(false)
	game.banner_left = 0
	game.kill_feed.clear()
	var views := [
		["a-site", Vector3(35, 0, -23), Vector3(23, 3.5, -32)],
		["b-site", Vector3(-18, 0, -20), Vector3(-31, 1.9, -29)],
		["tunnels", Vector3(-33, 0, 15), Vector3(-33, 1.6, -5)],
		["long", Vector3(37, 0, 4), Vector3(36, 3.6, -27)]
	]
	for view in views:
		game.player.health = 100
		game.player.position = Layout.on_floor(view[1]) + Vector3.UP * 0.05
		var direction: Vector3 = view[2] - (game.player.position + Vector3.UP * 1.62)
		game.player.rotation.y = atan2(-direction.x, -direction.z)
		game.player.pitch = asin(direction.normalized().y)
		await frames(30)
		await capture(view[0])
	print("NATIVE_VISUAL_OK ", game.details())
	game.queue_free()
	await process_frame
	quit()
