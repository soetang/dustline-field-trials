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
	print("CPU_PROFILE: %d/%d passed" % [passed, passed + failed])
	quit(1 if failed else 0)
