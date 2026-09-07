extends SceneTree

const Probe = preload("res://tests/cpu_profile.gd")
var passed := 0
var failed := 0

func check(ok: bool, label: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	Probe.reset(PackedStringArray(["parent", "child"]))
	check(not Probe.enabled and Probe.depth == 0, "disabled by default; empty stack")
	Probe.enabled = true
	Probe.begin(0, 100)
	Probe.begin(1, 120)
	Probe.end(170)
	Probe.end(200)
	Probe.record_frame(20000)
	var report := Probe.summary()
	check(report.scopes[0].inclusive_ms == 0.1 and report.scopes[0].self_ms == 0.05, "nested scope removed from parent self")
	check(report.scopes[1].self_ms == 0.05 and report.instrumented_self_ms == 0.1, "self sum does not double-count children")
	check(report.scopes[0].calls == 1 and report.scopes[1].calls == 1, "per-scope invocation counts")
	Probe.begin(0, 300)
	Probe.begin(0, 310)
	Probe.end(320)
	Probe.end(340)
	Probe.record_frame(30000)
	report = Probe.summary()
	check(report.scopes[0].inclusive_ms == 0.15 and report.scopes[0].self_ms == 0.09, "recursive scope inclusive/self accounting")
	check(report.scopes[0].max_inclusive_ms_per_call == 0.1, "retain maximum inclusive duration")
	check(report.scopes[0].p95_self_ms_per_frame == 0.05, "self per-frame percentile")
	check(report.samples_ms == PackedFloat64Array([20, 30]), "preserve actual monotonic frame intervals")
	Probe.reset(PackedStringArray(["new capture"]))
	check(not Probe.enabled and Probe.calls.size() == 1 and Probe.calls[0] == 0 and Probe.frame_count == 0, "reset clears counters without retaining prior scene data")
	for frame in Probe.FRAME_CAPACITY + 7: Probe.record_frame(10000)
	report = Probe.summary()
	check(report.frames == Probe.FRAME_CAPACITY and report.dropped_frames == 7, "frame storage is bounded; overflow explicit")
	check(report.instrumented_self_ms == 0 and report.scopes[0].calls == 0, "disabled control contains no fabricated CPU samples")
	Probe.reset(PackedStringArray(["clock/probe overhead"]))
	Probe.enabled = true
	var started := Time.get_ticks_usec()
	for i in 5000:
		Probe.begin(0)
		Probe.end()
	print("CPU_PROBE_NATIVE_OVERHEAD_US_PER_PAIR ", (Time.get_ticks_usec() - started) / 5000.0,
		" (empty nested-timer bookkeeping; not browser or whole-frame cost)")
	check(Probe.depth == 0 and Probe.calls[0] == 5000 and Probe.exclusive[0] >= 0, "real clock and repeated scopes stay balanced")
	Probe.enabled = false
	Probe.reset_effects()
	check(Probe.effects_summary().active == 0, "effects start empty independently of CPU recorder")
	var tracer := Node3D.new()
	var impact := Node3D.new()
	root.add_child(tracer)
	root.add_child(impact)
	var tracer_timer := create_timer(0.01)
	var impact_timer := create_timer(8.0)
	Probe.track_effect(tracer, "tracer", tracer_timer)
	Probe.track_effect(impact, "impact", impact_timer)
	tracer_timer.timeout.connect(func(): tracer.queue_free())
	impact_timer.timeout.connect(func(): impact.queue_free())
	var effects := Probe.effects_summary()
	check(effects.created == {"tracer": 1, "impact": 1} and effects.active == 2 and effects.peak == 2,
		"disabled CPU controls still track actual effect nodes")
	while Probe.effect_retired.tracer == 0: await process_frame
	await process_frame
	check(Probe.effects_summary().retired.tracer == 1 and Probe.active_effects.size() == 1,
		"deferred deletion retires each effect exactly once")
	check(effects.retired.tracer == 0 and effects.active == 2, "snapshots do not mutate during later retirement")
	Probe.expire_effects_for_reset()
	while not Probe.active_effects.is_empty(): await process_frame
	await process_frame
	check(Probe.effects_summary().retired == Probe.effects_summary().created,
		"owned timer reset runs original callbacks and drains effects")
	check(Probe.effect_reset_expired == 1, "reset expiry is distinguished from natural timer expiry")
	Probe.reset_effects()
	check(Probe.effects_summary().created == {"tracer": 0, "impact": 0} and Probe.effect_peak == 0,
		"next segment has no live effects or previous counts")
	print("CPU_PROFILE: %d/%d passed" % [passed, passed + failed])
	quit(1 if failed else 0)
