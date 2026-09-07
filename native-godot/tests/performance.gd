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
