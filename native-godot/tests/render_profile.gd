extends SceneTree

## Repeated, warmed static views. No readback/screenshots in measured intervals.
## This is a same-machine renderer comparison, not a live-match FPS guarantee.
const Layout = preload("res://scripts/layout.gd")
var game: Node3D
var label := "working-tree"
var output := "res://builds/render-profile.json"

func _initialize() -> void:
	call_deferred("run")

func warm(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000)
	while Time.get_ticks_msec() < until: await process_frame

func percentile(values: Array[float], fraction: float) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[mini(sorted.size() - 1, int((sorted.size() - 1) * fraction))]

func sample() -> Dictionary:
	var times: Array[float] = []
	var total := 0.0
	var previous := Time.get_ticks_usec()
	while total < 3000:
		await process_frame
		var now := Time.get_ticks_usec()
		var ms := (now - previous) / 1000.0
		previous = now
		times.append(ms)
		total += ms
	return {"frames": times.size(), "seconds": total / 1000, "mean_fps": times.size() * 1000 / total,
		"frame_ms_p50": percentile(times, 0.5), "frame_ms_p95": percentile(times, 0.95), "frame_ms_max": times.max(),
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"rendered_objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"rendered_primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)}

func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("RENDER_PROFILE requires a real native renderer; headless results would be misleading")
		quit(1)
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--profile-label="): label = arg.trim_prefix("--profile-label=")
		if arg.begins_with("--profile-file="): output = arg.trim_prefix("--profile-file=")
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.set_paused(false)
	game.phase = "LIVE"
	game.phase_left = 100
	game.set_physics_process(false)
	game.player.set_physics_process(false)
	game.player.set_process(false)
	game.objective.set_physics_process(false)
	for bot in game.bots: bot.set_physics_process(false)
	game.banner_left = 0
	var result := {"label": label, "build": game.BUILD, "gpu": RenderingServer.get_video_adapter_name(),
		"renderer": RenderingServer.get_current_rendering_method(), "engine": Engine.get_version_info().string,
		"os": OS.get_name(), "window": str(DisplayServer.window_get_size()), "vsync": DisplayServer.window_get_vsync_mode(),
		"scene_nodes": game.find_children("*", "Node", true, false).size(), "views": []}
	var views := [
		["ct", Layout.CT_SPAWN, Vector3(1, 1.6, -15)],
		["a-site", Vector3(35, 0, -23), Vector3(23, 3.5, -32)],
		["tunnels", Vector3(-33, 0, 15), Vector3(-33, 1.6, -5)]
	]
	for view in views:
		game.player.position = Layout.on_floor(view[1])
		var direction: Vector3 = view[2] - game.player.camera.global_position
		game.player.rotation.y = atan2(-direction.x, -direction.z)
		game.player.camera.rotation.x = asin(direction.normalized().y)
		await warm(2)
		var metrics := await sample()
		metrics.view = view[0]
		result.views.append(metrics)
		print("RENDER_VIEW ", JSON.stringify(metrics))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output).get_base_dir())
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		printerr("RENDER_PROFILE cannot write ", output)
		quit(1)
		return
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	print("RENDER_PROFILE_OK ", JSON.stringify(result))
	game.queue_free()
	await process_frame
	quit()
