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

func run() -> void:
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
