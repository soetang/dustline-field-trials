extends SceneTree

## Automated AI round, not human play. Temporary-source probes only. The player
## stays idle; normal bot AI, physics, animation, HUD and High rendering run.
## Audio is muted by --test and mouse capture is removed in this isolated copy.
## The runner re-enables real tracers/impacts without changing those safeguards.
const Probe = preload("res://tests/cpu_profile.gd")
const LABELS: Array[String] = [] # Injected by the temporary-project runner.
var game: Node3D
var observer := Camera3D.new()
var duration := 12.0
var warmup := 30
var resolution := Vector2i(1280, 720)
var gpu_probe: RefCounted

func _initialize() -> void:
	call_deferred("run")

func pin_observer() -> void:
	# Normal death/spectator logic can change the current camera. Keep rendering
	# from one observer pose so that different frame counts cannot change the
	# pixel workload merely by reaching a different part of the death animation.
	if not observer.current: observer.make_current()

func run_segment(name: String, recording: bool, reference_navigation: bool = false) -> void:
	game.paused = true
	# new_round does not delete bullet marks. Expire only this fixture's timers
	# outside measurement, running original callbacks and deferred deletion.
	Probe.expire_effects_for_reset()
	while not Probe.active_effects.is_empty(): await RenderingServer.frame_post_draw
	await process_frame
	assert(game.effects.is_empty())
	Probe.reset_effects()
	var effects_at_start := Probe.active_effects.size()
	if "--presentation-abba" in OS.get_cmdline_user_args():
		JavaScriptBridge.eval("window.presentationStateCache.setEnabled(" + str(name.begins_with("cache-")).to_lower() + ")", true)
	Probe.reference_navigation = reference_navigation
	game.elapsed = 0
	game.round_number = 0
	game.rng.seed = game.match_seed
	game.new_round()
	game.phase = "LIVE"
	game.phase_left = 100
	pin_observer()
	# Sync new CharacterBodies and settle the existing render materials while
	# paused. This setup/import/round-allocation work is outside the measurement.
	for frame in warmup: await RenderingServer.frame_post_draw
	if "--profile-steady" in OS.get_cmdline_user_args():
		JavaScriptBridge.eval("window.renderProfileName=" + JSON.stringify(name) + "; window.renderProfilePhase='ready'", true)
		while JavaScriptBridge.eval("window.renderProfilePhase", true) != "running":
			await process_frame
	game.paused = false # deliberately no sync_pointer / external input request
	game.hud.sync_menu()
	if "--presentation-abba" in OS.get_cmdline_user_args():
		JavaScriptBridge.eval("window.presentationStateCache.resetStats()", true)
	if gpu_probe: gpu_probe.start(name, name.begins_with("timer-on-"))
	Probe.reset(PackedStringArray(LABELS))
	Probe.enabled = recording
	var previous := Time.get_ticks_usec()
	var started := previous
	var physics_start := Engine.get_physics_frames()
	var draws := 0.0
	var primitives := 0.0
	var camera_mismatches := 0
	var unexpected_paused_frames := 0
	# A slow software renderer may produce fewer than twelve frames in a short
	# diagnostic window. Extend it rather than fabricating samples or weakening
	# validation; actual wall duration remains in the report and watchdog bounds
	# a renderer that never produces another frame.
	while ((Time.get_ticks_usec() - started) < duration * 1000000 or Probe.frame_count < 12 or
			((Probe.effect_created.tracer == 0 or Probe.effect_created.impact == 0) and game.elapsed < 15)) and Probe.frame_count < Probe.FRAME_CAPACITY:
		await RenderingServer.frame_post_draw
		if not observer.current: camera_mismatches += 1
		if game.paused: unexpected_paused_frames += 1
		var now := Time.get_ticks_usec()
		Probe.record_frame(now - previous)
		previous = now
		draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		primitives += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		if unexpected_paused_frames > 0: break # game.elapsed cannot bound a paused fixture
	Probe.enabled = false
	game.paused = true
	var effects_measured := Probe.effects_summary()
	if gpu_probe: gpu_probe.stop()
	var physics_end := Engine.get_physics_frames()
	# Stop browser sampling before summary sorting, JSON/PNG and readback work.
	# Snapshot physics count first: paused handshake frames are not gameplay.
	if "--profile-steady" in OS.get_cmdline_user_args():
		JavaScriptBridge.eval("window.renderProfilePhase='done'", true)
		while JavaScriptBridge.eval("window.renderProfilePhase", true) != "stopped":
			await process_frame
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
		"fixture": "normal nine-bot round with real tracers/impacts; idle player; fixed observer camera; audio muted; no host input",
		"effects_enabled": true, "effects_at_start": effects_at_start, "effects": effects_measured,
		"effects_boundary": "owned timers expired outside measurement; original callbacks drain before reset",
		"unexpected_paused_frames": unexpected_paused_frames,
		"silent_test": game.silent_test, "audio_muted": game.sound.muted,
		"camera": {"position": [observer.global_position.x, observer.global_position.y, observer.global_position.z],
			"rotation": [observer.global_rotation.x, observer.global_rotation.y, observer.global_rotation.z], "fov": observer.fov,
			"mismatched_frames": camera_mismatches},
		"instrumented": recording, "seed": game.match_seed,
		"requested_seconds": duration, "minimum_frames": 12, "warmup_frames": warmup,
		"wrapper_control": "disabled controls still include wrapper dispatch/branch; not pristine source",
		"elapsed_wall_seconds": (previous - started) / 1000000.0,
		"elapsed_game_seconds": game.elapsed, "physics_ticks": physics_end - physics_start,
		"mean_fps": Probe.frame_count * 1000000.0 / maxf(1, previous - started),
		"p50_ms": ordered[ceili(ordered.size() * 0.5) - 1], "p95_ms": ordered[ceili(ordered.size() * 0.95) - 1],
		"p99_ms": ordered[ceili(ordered.size() * 0.99) - 1],
		"mean_draw_calls": draws / maxi(1, Probe.frame_count), "mean_primitives": primitives / maxi(1, Probe.frame_count),
		"bot_shots": shots, "bot_travel_m": travel, "ending_round": game.round_number, "ending_phase": game.phase,
		"ending_health": game.player.health, "operators": game.operator_details(), "render": game.render_budget.details(game.get_viewport()),
		"renderer": RenderingServer.get_current_rendering_method(),
		"backend": JavaScriptBridge.eval("window.renderBackend", true)})
	if "--presentation-abba" in OS.get_cmdline_user_args():
		result.presentation_cache = JSON.parse_string(JavaScriptBridge.eval("JSON.stringify(window.presentationStateCache.snapshot())", true))
	if gpu_probe:
		result.gpu_timing_requested = name.begins_with("timer-on-")
		result.gpu_timing = await gpu_probe.collect(self)
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
		if arg.begins_with("--warmup="): warmup = clampi(arg.get_slice("=", 1).to_int(), 3, 600)
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
	game.add_child(observer)
	observer.position = Vector3(1, 1.65, -33)
	observer.look_at(Vector3(1.5, 1.6, -18))
	observer.fov = 80
	observer.near = 0.045
	observer.far = 200
	pin_observer()
	RenderingServer.frame_pre_draw.connect(pin_observer)
	if "--gpu-timing" in OS.get_cmdline_user_args(): gpu_probe = load("res://_gpu_profile.gd").new()
	# Keep the pause overlay out of the automated match, retaining the live HUD.
	JavaScriptBridge.eval("""(() => {
		const gl=document.getElementById('canvas').getContext('webgl2');
		const ext=gl?.getExtension('WEBGL_debug_renderer_info');
		window.renderBackend=ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : 'not exposed';
	})()""", true)
	if gpu_probe:
		# CPU recorder stays disabled in all four GPU-probe overhead windows.
		for name in ["timer-off-before", "timer-on-before", "timer-on-after", "timer-off-after"]:
			await run_segment(name, false)
		gpu_probe.dispose()
	elif "--presentation-abba" in OS.get_cmdline_user_args():
		for name in ["native-before", "cache-before", "cache-after", "native-after"]:
			await run_segment(name, false)
	elif "--navigation-abba" in OS.get_cmdline_user_args():
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
