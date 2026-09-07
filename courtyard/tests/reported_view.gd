extends SceneTree

const View = preload("res://tests/fixtures/reported_view.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ", label)

func run() -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/reported-ct.json"))
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	for bot in game.bots:
		bot.position = game.Layout.on_floor(Vector3(-3 + (bot.index % 3) * 3, 0, -25 + (bot.index / 3) * 3))
	var camera := Camera3D.new()
	game.add_child(camera)
	await physics_frame
	await process_frame
	var view := View.new()
	view.configure(game, camera, data)
	for frame in 4: await process_frame
	view.start_measurement()
	var before: Transform3D = camera.transform
	for frame in 120:
		view.animate(game)
		await process_frame
	var result := view.details(game)
	check(game.paused, "Setup/animation leaves the game paused")
	check(result.operators == {"alive": 2, "dead": 7, "sleeping": 7}, "Reported workload uses real settled rigs")
	check(result.sleeping_poses_unchanged and result.sleeping_skeleton_updates == 0, "Sleeping bones are untouched during samples")
	check(camera.transform == before and camera.is_current(), "Camera stays fixed")
	check(camera.global_position == View.vector(data.camera.position_xyz), "Exact reported camera position")
	for i in 3: check(camera.basis[i].is_equal_approx(View.vector(data.camera.basis[i])), "Reported camera basis column %d" % i)
	check(camera.fov == data.camera.fov_degrees and is_equal_approx(camera.near, data.camera.near) and camera.far == data.camera.far and camera.keep_aspect == data.camera.keep_aspect, "Reported lens preserved")
	check(game.render_budget.level == 2 and game.get_viewport().scaling_3d_scale == 1, "High settings unchanged")
	print("REPORTED_VIEW: %d/%d passed | headless state/pose checks; not GPU or FPS" % [checks - failures, checks])
	game.free()
	quit(0 if failures == 0 else 1)
