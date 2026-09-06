extends SceneTree

## Automated AI round, not human play. Temporary-source probes only. The player
## stays idle; normal bot AI, physics, animation, HUD and High rendering run.
## Audio is muted by --test and mouse capture is removed in this isolated copy.
const Probe = preload("res://tests/cpu_profile.gd")
const LABELS: Array[String] = [] # Injected by the temporary-project runner.
var game: Node3D
var duration := 12.0
var resolution := Vector2i(1280, 720)

func _initialize() -> void:
	call_deferred("run")

func run_segment(name: String, recording: bool, reference_navigation: bool = false) -> void:
	game.paused = true
	Probe.reference_navigation = reference_navigation
	game.elapsed = 0
	game.round_number = 0
	game.rng.seed = game.match_seed
	game.new_round()
	game.phase = "LIVE"
	game.phase_left = 100
	game.player.camera.current = true
	# Sync new CharacterBodies and settle the existing render materials while
	# paused. This setup/import/round-allocation work is outside the measurement.
	for frame in 30: await RenderingServer.frame_post_draw
	game.paused = false # deliberately no sync_pointer / external input request
	game.hud.sync_menu()
	Probe.reset(PackedStringArray(LABELS))
	Probe.enabled = recording
	var previous := Time.get_ticks_usec()
	var started := previous
	var physics_start := Engine.get_physics_frames()
	var draws := 0.0
	var primitives := 0.0
	while (Time.get_ticks_usec() - started) < duration * 1000000 and Probe.frame_count < Probe.FRAME_CAPACITY:
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		Probe.record_frame(now - previous)
		previous = now
		draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		primitives += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	Probe.enabled = false
	game.paused = true
	var result := Probe.summary()
	var ordered: PackedFloat64Array = result.samples_ms.duplicate()
	ordered.sort()
	var shots := 0
	var travel := 0.0
	for bot in game.bots:
		shots += bot.shots
		travel += bot.travel
	result.merge({"name": name, "build": game.BUILD,
		"navigation": "original exact predicate" if reference_navigation else "production clearance",
		"fixture": "normal nine-bot round; idle player; audio muted; no host input",
		"instrumented": recording, "seed": game.match_seed,
		"wrapper_control": "disabled controls still include wrapper dispatch/branch; not pristine source",
		"elapsed_wall_seconds": (previous - started) / 1000000.0,
		"elapsed_game_seconds": game.elapsed, "physics_ticks": Engine.get_physics_frames() - physics_start,
		"mean_fps": Probe.frame_count * 1000000.0 / maxf(1, previous - started),
		"p50_ms": ordered[ceili(ordered.size() * 0.5) - 1], "p95_ms": ordered[ceili(ordered.size() * 0.95) - 1],
		"p99_ms": ordered[ceili(ordered.size() * 0.99) - 1],
		"mean_draw_calls": draws / maxi(1, Probe.frame_count), "mean_primitives": primitives / maxi(1, Probe.frame_count),
		"bot_shots": shots, "bot_travel_m": travel, "ending_round": game.round_number, "ending_phase": game.phase,
		"ending_health": game.player.health, "render": game.render_budget.details(game.get_viewport()),
		"renderer": RenderingServer.get_current_rendering_method(),
		"backend": JavaScriptBridge.eval("window.renderBackend", true)})
	# Screenshot encoding and JS serialization are explicitly outside timing.
	if "--capture" in OS.get_cmdline_user_args():
		await RenderingServer.frame_post_draw
		result.png = Marshalls.raw_to_base64(root.get_texture().get_image().save_png_to_buffer())
	print("GAMEPLAY_CPU_SAMPLE ", name, " frames=", result.frames, " physics=", result.physics_ticks,
		" measured_self_ms_per_frame=", result.mean_instrumented_self_ms_per_frame,
		" bot_shots=", shots, " travel=", travel)
	JavaScriptBridge.eval("window.mapReviewCaptures.push(" + JSON.stringify(result) + ")", true)

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--duration="): duration = clampf(arg.get_slice("=", 1).to_float(), 3, 30)
		if arg.begins_with("--width="): resolution.x = clampi(arg.get_slice("=", 1).to_int(), 320, 3840)
		if arg.begins_with("--height="): resolution.y = clampi(arg.get_slice("=", 1).to_int(), 180, 2160)
	root.size = resolution
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.match_seed = 512
	game.render_budget.level = 2
	game.render_budget.apply(game)
	game.hud.sync_menu()
	# Keep the pause overlay out of the automated match, retaining the live HUD.
	JavaScriptBridge.eval("""(() => {
		const gl=document.getElementById('canvas').getContext('webgl2');
		const ext=gl?.getExtension('WEBGL_debug_renderer_info');
		window.renderBackend=ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : 'not exposed';
	})()""", true)
	if "--navigation-abba" in OS.get_cmdline_user_args():
		# Same renderer, probes and static geometry. Only segment_clear's point
		# predicate switches between original calculation and broad-phase lookup.
		for entry in [["reference-before", true], ["lookup-before", false], ["lookup-after", false], ["reference-after", true]]:
			await run_segment(entry[0], true, entry[1])
	else:
		# ABBA order estimates recorder impact; it is not a language-port speedup.
		for entry in [["control-before", false], ["profile-before", true], ["profile-after", true], ["control-after", false]]:
			await run_segment(entry[0], entry[1])
	print("GAMEPLAY_PROFILE_OK")
	JavaScriptBridge.eval("window.mapReviewComplete = true", true)
