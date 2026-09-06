extends SceneTree

# Same export engine and world as the release, deterministic camera/animation.
# No screenshot/readback in the timed region. This is a RENDER fixture: physics,
# AI decisions, gunfire and audio are intentionally absent. Use live telemetry
# for matches. Software-renderer times must never be labelled hardware FPS.
var game: Node3D
var camera := Camera3D.new()
var samples := 60
var warmup := 12
var resolution := Vector2i(640, 360)
var frame := 0
var gpu_probe: RefCounted

func _initialize() -> void:
	call_deferred("run")

func animate() -> void:
	frame += 1
	for bot in game.bots:
		bot.rig.update_pose(1.0/60, Vector3.ZERO, Vector2(sin(frame * 0.01 + bot.index) * 0.2, 0.2),
			0, false, false, 0, bot.global_transform, game.Layout.floor_height)

func capture(name: String, at: Vector3, target: Vector3) -> void:
	camera.position = at
	camera.look_at(target)
	frame = 0
	for i in warmup:
		animate()
		await RenderingServer.frame_post_draw
	if "--profile-steady" in OS.get_cmdline_user_args():
		JavaScriptBridge.eval("window.renderProfileName="+JSON.stringify(name)+"; window.renderProfilePhase='ready'",true)
		while JavaScriptBridge.eval("window.renderProfilePhase",true) != "running":
			await process_frame
	if gpu_probe: gpu_probe.start(name, true)
	var times: Array[float] = []
	var draws := 0.0
	var primitives := 0.0
	var setup_cpu := 0.0
	var render_cpu := 0.0
	var render_gpu := 0.0
	var previous := Time.get_ticks_usec()
	for i in samples:
		animate()
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		times.append((now - previous) / 1000.0)
		previous = now
		draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		primitives += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		setup_cpu += RenderingServer.get_frame_setup_time_cpu()
		render_cpu += RenderingServer.viewport_get_measured_render_time_cpu(game.get_viewport().get_viewport_rid())
		render_gpu += RenderingServer.viewport_get_measured_render_time_gpu(game.get_viewport().get_viewport_rid())
	if gpu_probe: gpu_probe.stop()
	if "--profile-steady" in OS.get_cmdline_user_args():
		JavaScriptBridge.eval("window.renderProfilePhase='done'",true)
		while JavaScriptBridge.eval("window.renderProfilePhase",true) != "stopped":
			await process_frame
	var ordered := times.duplicate()
	ordered.sort()
	var total := 0.0
	var stalls := 0
	for value in times:
		total += value
		if value > 50: stalls += 1
	var data := {"name": name, "build": game.BUILD, "fixture": "staged render + nine animated operators; no AI/audio",
		"ssao": game.world.find_children("*","WorldEnvironment",true,false)[0].environment.ssao_enabled,
		"resolution": [resolution.x,resolution.y], "samples_ms": times, "warmup_frames": warmup,
		"render": game.render_budget.details(game.get_viewport()),
		"mean_fps": samples * 1000.0 / total, "p50_ms": ordered[ceili(samples * 0.50)-1],
		"p95_ms": ordered[ceili(samples * 0.95)-1], "p99_ms": ordered[ceili(samples * 0.99)-1],
		"over_50_ms": stalls, "mean_draw_calls": draws / samples, "mean_primitives": primitives / samples,
		"render_setup_cpu_ms": setup_cpu / samples, "render_cpu_ms": render_cpu / samples,
		"render_gpu_ms": render_gpu / samples, "zero_timing_means_unavailable": true,
		"renderer": RenderingServer.get_current_rendering_method(), "batching": game.world.batching}
	if gpu_probe:
		data.gpu_timing_requested = true
		data.gpu_timing = await gpu_probe.collect(self)
	print("RENDER_SAMPLE ", JSON.stringify(data))
	if "--capture" in OS.get_cmdline_user_args():
		data.png = Marshalls.raw_to_base64(root.get_texture().get_image().save_png_to_buffer())
	JavaScriptBridge.eval("window.mapReviewCaptures.push(Object.assign("+JSON.stringify(data)+", {backend:window.renderBackend}))", true)

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--samples="): samples = clampi(arg.get_slice("=",1).to_int(),12,3600)
		if arg.begins_with("--warmup="): warmup = clampi(arg.get_slice("=",1).to_int(),3,600)
		if arg.begins_with("--width="): resolution.x = clampi(arg.get_slice("=",1).to_int(),160,3840)
		if arg.begins_with("--height="): resolution.y = clampi(arg.get_slice("=",1).to_int(),90,2160)
	root.size = resolution
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--quality="): game.render_budget.level = clampi(arg.get_slice("=",1).to_int(),0,2)
	game.render_budget.apply(game)
	RenderingServer.viewport_set_measure_render_time(game.get_viewport().get_viewport_rid(),true)
	game.hud.visible = false
	game.player.visible = false
	game.add_child(camera)
	camera.fov = 75
	camera.far = 200
	camera.current = true
	if "--gpu-timing" in OS.get_cmdline_user_args(): gpu_probe = load("res://_gpu_profile.gd").new()
	for bot in game.bots:
		bot.position = game.Layout.on_floor(Vector3(-3 + (bot.index % 3) * 3, 0, -25 + (bot.index / 3) * 3))
	for light in game.world.find_children("*","Light3D",true,false):
		if "--diagnostic-no-shadows" in OS.get_cmdline_user_args(): light.shadow_enabled = false
		if not light is DirectionalLight3D: continue
		for arg in OS.get_cmdline_user_args():
			if arg == "--splits=2": light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
			if arg == "--splits=4": light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
			if arg.begins_with("--shadow-distance="): light.directional_shadow_max_distance = arg.get_slice("=",1).to_float()
	JavaScriptBridge.eval("""(() => {
		const gl=document.getElementById('canvas').getContext('webgl2');
		const ext=gl?.getExtension('WEBGL_debug_renderer_info');
		window.renderBackend=ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : 'not exposed';
	})()""",true)
	var poses := [["spawn",Vector3(1,1.65,-33),Vector3(1.5,1.6,-18)],
		["a-site",Vector3(29,4.05,-29),Vector3(36,3.5,-14)],
		["long-doors",Vector3(28.5,2.4,22.5),Vector3(28.5,1.9,16.5)]]
	for pose in poses:
		if "--compare-ssao" in OS.get_cmdline_user_args():
			for mode in ["ao-before","no-ao-before","no-ao-after","ao-after"]:
				game.world.find_children("*","WorldEnvironment",true,false)[0].environment.ssao_enabled = mode.begins_with("ao-")
				await capture(pose[0]+"-"+mode,pose[1],pose[2])
		elif "--compare" in OS.get_cmdline_user_args():
			for mode in ["high-before","balanced-before","balanced-after","high-after"]:
				game.render_budget.level = 2 if mode.begins_with("high") else 0
				game.render_budget.apply(game)
				await capture(pose[0]+"-"+mode,pose[1],pose[2])
		else: await capture(pose[0],pose[1],pose[2])
	print("RENDER_BENCHMARK_OK")
	if gpu_probe: gpu_probe.dispose()
	JavaScriptBridge.eval("window.mapReviewComplete = true",true)
