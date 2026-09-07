extends SceneTree

var game: Node3D
var camera := Camera3D.new()
var folder := "res://builds/map-review"
var label := "undercroft"

func _initialize() -> void:
	call_deferred("run")

func capture(name: String,position: Vector3,target: Vector3) -> void:
	camera.position = position
	camera.look_at(target)
	print("MAP_VIEW ",name)
	for i in 3: await process_frame
	print("MAP_READBACK ",name)
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path(folder).path_join(label+"-"+name+".png")
	var snapshot := root.get_texture().get_image()
	if OS.has_feature("web"):
		# Only the separately exported test scene exposes captures. It is not
		# included in release packs and adds no command bridge to the game.
		var capture_data := {"name": name, "png": Marshalls.raw_to_base64(snapshot.save_png_to_buffer()),
			"draws": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)}
		JavaScriptBridge.eval("window.mapReviewCaptures.push("+JSON.stringify(capture_data)+")", true)
	else:
		assert(snapshot.save_png(path) == OK)
	print("MAP_CAPTURE ",path," draws=",Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))

func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Map review needs an isolated real renderer")
		quit(1)
		return
	root.size = Vector2i(960,540)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="): folder = arg.trim_prefix("--capture-dir=")
		if arg.begins_with("--label="): label = arg.trim_prefix("--label=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.hud.visible = false
	game.player.visible = false
	for bot in game.bots: bot.visible = false
	game.add_child(camera)
	camera.fov = 75
	camera.far = 200 # Same viewing distance as the playable camera.
	camera.current = true
	if "--diagnostic-no-shadows" in OS.get_cmdline_user_args():
		for light in game.world.find_children("*","Light3D",true,false): light.shadow_enabled = false
		print("MAP_DIAGNOSTIC shadows disabled, not final lighting")
	await capture("house",Vector3(5,3,-22.8),Vector3(2,4.7,-32.5))
	await capture("spawn",Vector3(1,1.65,-33),Vector3(1.5,1.6,-18))
	await capture("a-exit",Vector3(6,2.4,-32),Vector3(15,3.2,-31))
	await capture("mid-doors",Vector3(1.5,1.65,-16.5),Vector3(1.5,1.6,-22))
	await capture("long-doors",Vector3(28.5,2.4,22.5),Vector3(28.5,1.9,16.5))
	print("MAP_REVIEW_OK")
	if OS.has_feature("web"):
		# Close the page after capture, just like the real browser playtest.
		# Engine.quit() in this 4.7.2 single-thread template reports an outstanding
		# WorkerThreadPool group on shutdown; this is not an engine-exit test.
		JavaScriptBridge.eval("window.mapReviewComplete = true",true)
		return
	game.queue_free()
	await process_frame
	quit()
