extends SceneTree

const Metrics = preload("res://scripts/frame_metrics.gd")
const Budget = preload("res://scripts/render_budget.gd")
var passed := 0
var failed := 0

func check(ok: bool, label: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("FAIL: ",label)

func _initialize() -> void:
	call_deferred("run")

func check_render_dimensions() -> void:
	# Off-tree Window: exercises real engine layout calculations without opening
	# another native window, allocating a render target, or reading back pixels.
	var window := Window.new()
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	window.content_scale_size = Vector2i(1600,900)
	var budget := Budget.new()
	for fixture in [
		[Vector2i(1920,882),Vector2i(1568,882)],
		[Vector2i(1280,720),Vector2i(1280,720)],
		[Vector2i(1920,1080),Vector2i(1920,1080)],
		[Vector2i(900,1600),Vector2i(900,506)],
	]:
		window.size = fixture[0]
		var expected: Vector2i = fixture[1]
		var details := budget.details(window)
		check(Budget.actual_render_size(window) == expected,"Actual drawable dimensions for %s" % fixture[0])
		check(details.viewport == [float(window.size.x),float(window.size.y)],"Telemetry preserves physical window dimensions")
		check(details.viewport_pixels == [expected.x,expected.y],"Telemetry separately reports actual viewport pixels")
		check(details.render_3d == [expected.x,expected.y],"High 3D dimensions exclude black margins")
		check(details.quality == "High" and details.ssao and details.scale_3d == 1,"Dimension reporting leaves High unchanged")
		check(Budget.pixel_size(window) == Vector2(window.size),"Dimension fix does not change existing cap-policy inputs")
	window.size = Vector2i(1920,882)
	window.content_scale_factor = 2.0
	check(window.get_visible_rect().size == Vector2(800,450),"Content scale changes logical UI size")
	check(Budget.actual_render_size(window) == Vector2i(1568,882),"Content scale does not multiply target size twice")
	check(budget.details(window).logical_size == [800.0,450.0],"Logical dimensions remain separately visible")
	window.content_scale_factor = 1.0
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	check(Budget.actual_render_size(window) == Vector2i(1920,882),"Expand aspect has a full-window drawable target")
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_KEEP
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	check(Budget.actual_render_size(window) == Vector2i(1600,900),"Viewport stretch reports its actual fixed-size render target")
	window.content_scale_factor = 2.0
	check(Budget.actual_render_size(window) == Vector2i(800,450),"Viewport mode content scale reduces its actual target")
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	check(Budget.actual_render_size(window) == Vector2i(1920,882),"Disabled stretching reports the full drawable target")
	window.free()
	var subviewport := SubViewport.new()
	subviewport.size = Vector2i(641,359)
	subviewport.size_2d_override = Vector2i(1000,600)
	for stretch in [false,true]:
		subviewport.size_2d_override_stretch = stretch
		check(Budget.actual_render_size(subviewport) == Vector2i(641,359),"SubViewport uses physical size with stretch=%s" % stretch)
		check(budget.details(subviewport).render_3d == [641,359],"SubViewport logical override cannot inflate High 3D metadata")
	subviewport.scaling_3d_scale = 0.5
	var details := budget.details(subviewport)
	check(details.viewport_pixels == [641,359],"3D scaling leaves the base target dimensions unchanged")
	check(details.render_3d == [320,179],"Fractional 3D dimensions follow renderer truncation, not rounding")
	check(subviewport.scaling_3d_scale == 0.5 and budget.level == 2,"Reading details does not mutate render state")
	subviewport.free()

func vector_from(values: Array) -> Vector3:
	return Vector3(values[0],values[1],values[2])

func check_camera_pose(details: Dictionary, camera: Camera3D, label: String) -> void:
	var pose := camera.get_camera_transform()
	check(vector_from(details.position_xyz).is_equal_approx(pose.origin),label + " position includes camera/parent offsets")
	var columns: Array = details.basis
	var basis := Basis(vector_from(columns[0]),vector_from(columns[1]),vector_from(columns[2]))
	check(basis.is_equal_approx(pose.basis),label + " basis reconstructs the full view orientation")
	check(is_equal_approx(details.fov_degrees,camera.fov) and is_equal_approx(details.near,camera.near) and is_equal_approx(details.far,camera.far) and details.keep_aspect == camera.keep_aspect,label + " preserves lens parameters")

func check_camera_feedback(game: Node3D) -> void:
	# Paused fixture: exercise actual camera ownership without rendering or input.
	var player_pose: Transform3D = game.player.transform
	var camera: Camera3D = game.player.camera
	var camera_pose := camera.transform
	var fov := camera.fov
	game.player.position = Vector3(9.65,1.57,-30.65)
	game.player.rotation.y = -1.98
	camera.rotation = Vector3(-0.13,0.02,0.01)
	camera.fov = 30
	var details: Dictionary = JSON.parse_string(game.details())
	check(details.camera.mode == "player","Living feedback uses the active player camera")
	check_camera_pose(details.camera,camera,"Player zoom/recoil")
	check(vector_from(details.position_xyz).is_equal_approx(game.player.position),"Existing feedback keeps player body coordinates")
	check(not vector_from(details.camera.position_xyz).is_equal_approx(game.player.position),"Camera is not confused with the player body")
	var health: float = game.player.health
	game.player.health = 0
	game.spectator.select_target()
	camera = game.spectator.camera
	camera.position = Vector3(-24,3.2,-34)
	camera.look_at(Vector3(-20,1.5,-29))
	var before := camera.get_camera_transform()
	details = JSON.parse_string(game.details())
	check(details.camera.mode == "spectator" and not details.spectating.is_empty(),"Dead-player feedback identifies the current spectator camera")
	check_camera_pose(details.camera,camera,"Spectator")
	check(vector_from(details.position_xyz).is_equal_approx(game.player.position),"Spectating preserves separate corpse coordinates")
	check(camera.get_camera_transform().is_equal_approx(before) and camera.is_current(),"Reading feedback does not move or switch the camera")
	game.spectator.reset()
	check(JSON.parse_string(game.details()).camera.mode == "player","Round reset restores player camera feedback")
	# No active camera is valid during view teardown. Do not select one implicitly.
	game.spectator.remove_child(camera)
	var head: Node = game.player.camera.get_parent()
	head.remove_child(game.player.camera)
	check(game.camera_details().is_empty(),"Missing active camera safely reports no pose")
	game.spectator.add_child(camera)
	head.add_child(game.player.camera)
	game.player.transform = player_pose
	game.player.camera.transform = camera_pose
	game.player.camera.fov = fov
	game.player.health = health
	game.player.camera.make_current()

func run() -> void:
	check_render_dimensions()
	var metrics := Metrics.new()
	metrics.record(1000000,true)
	for i in 100: metrics.record(1000000+(i+1)*20000,true)
	var result := metrics.summary()
	check(result.samples == 100 and is_equal_approx(result.mean_fps,50),"Wall-clock frame rate, not engine dt")
	check(result.p50_ms == 20 and result.p95_ms == 20 and result.p99_ms == 20,"Known frame-time percentiles")
	metrics.record(3200000,true)
	check(metrics.summary().max_ms == 200 and metrics.summary().over_100_ms == 1,"Retain real long stalls")
	metrics.record(3300000,false)
	check(metrics.cached.samples == 101,"Pausing publishes final live samples")
	metrics.record(99000000,true)
	check(metrics.count == 101,"Do not count pause/resume gap as a frame")
	for i in 2000: metrics.record(99000000+(i+1)*10000,true)
	check(metrics.count == Metrics.CAPACITY and metrics.values.size() == Metrics.CAPACITY,"Bounded storage after many frames")
	check(metrics.summary().p99_ms == 10,"Old samples leave rolling window")
	check(Budget.scale_for(Vector2(1920,1080),0) == 1,"1080p balanced remains native resolution")
	check(Budget.scale_for(Vector2(3840,2160),0) == 0.5,"4K balanced caps 3D at 1080p")
	check(is_equal_approx(Budget.scale_for(Vector2(1920,1080),1),2.0/3),"Performance caps 3D at 720p")
	check(Budget.scale_for(Vector2(3840,2160),2) == 1,"High remains full resolution")
	check(Budget.scale_for(Vector2.ZERO,0) == 1,"Resize through zero stays finite")
	var game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	for i in 3: await process_frame
	check_camera_feedback(game)
	check(game.render_budget.level == 2,"High is the default on every platform")
	check(game.get_viewport().scaling_3d_scale == 1.0,"Default does not reduce rendering resolution")
	check(game.world.find_children("*","WorldEnvironment",true,false)[0].environment.ssao_enabled,"Default retains ambient occlusion")
	check(game.world.find_children("*","DirectionalLight3D",true,false)[0].directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS,"Default retains four shadow cascades")
	var baseline := get_node_count()
	# Isolated lifetime regression: rounds rebuild all nine operators and menus.
	# No real-time FPS inference from this accelerated, headless fixture.
	for round_index in 12:
		game.new_round()
		for i in 3: await process_frame
		check(get_node_count() == baseline,"Round %d does not accumulate scene nodes" % round_index)
	game.render_budget.level = 0
	game.render_budget.apply(game)
	var sun = game.world.find_children("*","DirectionalLight3D",true,false)[0]
	check(sun.directional_shadow_mode == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS and sun.directional_shadow_max_distance == 70,"Balanced keeps real shadows with bounded passes/range")
	var environment = game.world.find_children("*","WorldEnvironment",true,false)[0].environment
	check(not environment.ssao_enabled,"Balanced does not silently enable expensive browser SSAO")
	game.render_budget.level = 2
	game.render_budget.apply(game)
	check(environment.ssao_enabled,"High explicitly retains SSAO")
	check(JSON.parse_string(game.details()).has("recent_live_frames"),"Feedback carries recent live frame statistics")
	game.queue_free()
	await process_frame
	print("PERFORMANCE: %d/%d passed" % [passed,passed+failed])
	quit(1 if failed else 0)
