extends SceneTree

# Individual real functions only: no world, renderer, physics or match replay.
# Times are native GDScript CPU cost, not browser FPS. Correctness is gated;
# host-dependent timings are reported without a performance pass/fail threshold.
const Layout = preload("res://scripts/layout.gd")
const SEED := 0x517ac
const BATCHES := 11
const WARMUP := 2
var checks := 0
var failures := 0
var layout: FieldLayout
var rng := RandomNumberGenerator.new()
var bits := PackedByteArray([0, 0, 0, 0])

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		if failures <= 12: printerr("FAIL: ", label)

# Immediately preceding production sampler, including the existing room and
# clearance caches. Comparing to the old rectangle scan would exaggerate gains.
func baseline_segment(a: Vector3, b: Vector3) -> bool:
	var from := Vector2(a.x, a.z)
	var to := Vector2(b.x, b.z)
	var count := maxi(1, ceili(from.distance_to(to) / 0.22))
	for i in range(count + 1):
		if not Layout.clear(from.lerp(to, float(i) / count), Layout.NAV_RADIUS): return false
	return true

func samples_executed(a: Vector3, b: Vector3) -> int:
	var from := Vector2(a.x, a.z)
	var to := Vector2(b.x, b.z)
	var count := maxi(1, ceili(from.distance_to(to) / 0.22))
	for i in range(count + 1):
		if not Layout.clear(from.lerp(to, float(i) / count), Layout.NAV_RADIUS): return i + 1
	return count + 1

func candidate_samples_executed(a: Vector3, b: Vector3) -> int:
	var from := Vector2(a.x, a.z)
	var to := Vector2(b.x, b.z)
	var count := maxi(1, ceili(from.distance_to(to) / 0.22))
	if not Layout.clear(from.lerp(to, 0.0), Layout.NAV_RADIUS): return 1
	if not Layout.clear(from.lerp(to, 1.0), Layout.NAV_RADIUS): return 2
	if count == 1 or Layout._segment_region_clear(from, to): return 2
	for i in range(1, count):
		if not Layout.clear(from.lerp(to, float(i) / count), Layout.NAV_RADIUS): return i + 2
	return count + 1

func add_pair(pairs: PackedVector3Array, from: Vector2, to: Vector2) -> PackedVector3Array:
	pairs.append(Vector3(from.x, 0, from.y))
	pairs.append(Vector3(to.x, 19, to.y)) # Navigation has always ignored height.
	return pairs

func random_point(padding: float = 0) -> Vector2:
	return Vector2(rng.randf_range(-44 - padding, 44 + padding), rng.randf_range(-44 - padding, 46 + padding))

func adjacent(value: float, up: bool) -> float:
	bits.encode_float(0, value)
	var stored := bits.decode_float(0)
	var encoded := bits.decode_u32(0)
	if stored == 0: encoded = 1 if up else 0x80000001
	else: encoded += 1 if (stored > 0) == up else -1
	bits.encode_u32(0, encoded)
	return bits.decode_float(0)

func make_groups() -> Dictionary:
	var groups := {}
	var pairs := PackedVector3Array()
	# Real bot steering/waypoint scales, distributed across navigable map space.
	for i in 512:
		var p := random_point()
		while not Layout.clear(p, Layout.NAV_RADIUS): p = random_point()
		var distance: float = [0.22, 0.65, 1.5, 3.0, 6.0, 12.0][i % 6]
		pairs = add_pair(pairs, p, p + Vector2.from_angle(rng.randf_range(-PI, PI)) * distance)
	groups["mixed_navigation"] = pairs
	pairs = PackedVector3Array()
	for i in 256:
		var x := rng.randf_range(0.7, 1.7) if i % 2 else rng.randf_range(38.2, 40.8)
		var p := Vector2(x, rng.randf_range(-18, -2))
		var q := Vector2(x, rng.randf_range(-18, -2))
		pairs = add_pair(pairs, p, q)
	groups["open_corridors"] = pairs
	pairs = PackedVector3Array()
	for i in 256:
		var p := Vector2(rng.randf_range(17, 21), rng.randf_range(-36, -32))
		var q := Vector2(rng.randf_range(25.8, 29), rng.randf_range(-25, -21))
		pairs = add_pair(pairs, p, q)
	groups["blocked_room_diagonals"] = pairs
	pairs = PackedVector3Array()
	for i in 256:
		var p := Vector2(rng.randf_range(25.8, 29), rng.randf_range(-36, -32))
		var q := Vector2(rng.randf_range(26, 29), rng.randf_range(-25, -23))
		pairs = add_pair(pairs, p, q)
	groups["open_room_diagonals"] = pairs
	pairs = PackedVector3Array()
	for rect: Rect2 in Layout.COVERS + Layout.CT_SUPPORTS:
		var expanded := rect.grow(Layout.NAV_RADIUS)
		for x in [expanded.position.x, expanded.end.x]:
			for direction in [-1, 1]:
				for delta in [-0.0001, 0.0, 0.0001]:
					var p := Vector2(x + delta, expanded.get_center().y)
					pairs = add_pair(pairs, p, p + Vector2(direction * 0.65, 0.12))
	for door: Dictionary in Layout.DOORS:
		for corner in Layout.door_corners(door):
			for step in 16:
				var p := corner + Vector2.from_angle(step * TAU / 16.0) * 0.43
				pairs = add_pair(pairs, p, p + Vector2.from_angle(step * TAU / 16.0) * 0.65)
	groups["dense_obstacles_and_doors"] = pairs
	pairs = PackedVector3Array()
	for i in 128:
		var p := random_point(4)
		pairs = add_pair(pairs, p, random_point(4))
	for p in [Vector2(-44, -44), Vector2(44, 46), Vector2(-44, 46), Vector2(44, -44)]:
		for delta in [-0.0001, 0.0, 0.0001]:
			pairs = add_pair(pairs, p + Vector2.ONE * delta, p)
	groups["outside_and_sparse_map"] = pairs
	pairs = PackedVector3Array()
	for y in range(-44, 47, 2):
		for x in range(-44, 45, 2):
			var p := Vector2(x + 0.5, y + 0.5)
			for up in [false, true]:
				var q := Vector2(adjacent(p.x, up), adjacent(p.y, not up))
				pairs = add_pair(pairs, p, q)
	groups["half_cell_ulp_boundaries"] = pairs
	pairs = PackedVector3Array()
	# Longer horizontal/vertical/diagonal legs straddle half-cell boundaries
	# at both ends and must reach the prefix path, unlike the short group above.
	for y in range(-44, 47, 6):
		for x in range(-44, 45, 6):
			var corner := Vector2(x + 0.5, y + 0.5)
			for offset in [Vector2(1, 0), Vector2(0, 1), Vector2(1, 1), Vector2(-2, 2)]:
				var end: Vector2 = corner + offset
				for up in [false, true]:
					var p := Vector2(adjacent(corner.x, up), adjacent(corner.y, not up))
					var q := Vector2(adjacent(end.x, not up), adjacent(end.y, up))
					pairs = add_pair(pairs, p, q)
	groups["long_half_cell_ulp_boundaries"] = pairs
	return groups

func verify_group(name: String, pairs: PackedVector3Array) -> Dictionary:
	var accepted := 0
	var baseline_work := 0
	var candidate_work := 0
	var clear_count := 0
	for i in range(0, pairs.size(), 2):
		var a := pairs[i]
		var b := pairs[i + 1]
		var expected := baseline_segment(a, b)
		check(layout.segment_clear(a, b) == expected, name + " forward equivalence")
		check(layout.segment_clear(b, a) == baseline_segment(b, a), name + " reverse equivalence")
		clear_count += int(expected)
		var work := samples_executed(a, b)
		baseline_work += work
		candidate_work += candidate_samples_executed(a, b)
		var from := Vector2(a.x, a.z)
		var to := Vector2(b.x, b.z)
		var count := maxi(1, ceili(from.distance_to(to) / 0.22))
		if count > 1 and Layout._segment_region_clear(from, to):
			check(expected, name + " fast acceptance never reports a blocked segment clear")
			accepted += 1
	if name == "long_half_cell_ulp_boundaries":
		check(accepted > 0, "Long ULP-boundary group exercises certified fast acceptance")
		check(accepted < pairs.size() / 2, "Long ULP-boundary group also exercises uncertain/blocked fallback")
	return {"calls_per_batch": pairs.size() / 2, "clear_segments": clear_count, "fast_accepts": accepted,
		"baseline_clear_calls": baseline_work, "candidate_clear_calls": candidate_work}

func summarize(values: PackedFloat64Array) -> Dictionary:
	var ordered := values.duplicate()
	ordered.sort()
	return {"median_us_per_call": ordered[ordered.size() / 2], "p95_us_per_call": ordered[ceili(ordered.size() * 0.95) - 1], "batches_us_per_call": values}

func measure_group(pairs: PackedVector3Array, work: Dictionary) -> Dictionary:
	var baseline := PackedFloat64Array()
	var candidate := PackedFloat64Array()
	for batch in BATCHES + WARMUP:
		for variant in ([0, 1] if batch % 2 == 0 else [1, 0]):
			var checksum := 0
			var start := Time.get_ticks_usec()
			for i in range(0, pairs.size(), 2):
				if baseline_segment(pairs[i], pairs[i + 1]) if variant == 0 else layout.segment_clear(pairs[i], pairs[i + 1]): checksum += 1
			var elapsed := (Time.get_ticks_usec() - start) / float(work.calls_per_batch)
			check(checksum == work.clear_segments, "Timed batch preserves outputs")
			if batch >= WARMUP:
				if variant == 0: baseline.append(elapsed)
				else: candidate.append(elapsed)
	return {"baseline": summarize(baseline), "candidate": summarize(candidate)}

func verify_prefix_and_fallback() -> void:
	var width := Layout.BOUNDS.size.x * Layout.CLEARANCE_SCALE
	var stride := width + 1
	var height := Layout.BOUNDS.size.y * Layout.CLEARANCE_SCALE
	check(Layout._segment_prefix.size() == stride * (height + 1), "Bounded prefix storage")
	for y in height:
		for x in width:
			var recovered: int = Layout._segment_prefix[(y + 1) * stride + x + 1] - Layout._segment_prefix[y * stride + x + 1] - Layout._segment_prefix[(y + 1) * stride + x] + Layout._segment_prefix[y * stride + x]
			check(recovered == int(Layout._clearance_cells[y * width + x] != 1), "Prefix agrees with every certified cell")
	check(Layout._build_segment_prefix(PackedByteArray()).is_empty(), "Unsupported table is rejected")
	var saved := Layout._clearance_cells
	Layout._clearance_cells = PackedByteArray()
	check(not Layout._segment_region_clear(Vector2.ONE, Vector2.ONE * 2), "Empty table never uses stale prefix")
	for points in [[Vector3(1, 0, -33), Vector3(1, 0, -30)], [Vector3(-3, 0, -29), Vector3.ZERO]]:
		check(layout.segment_clear(points[0], points[1]) == baseline_segment(points[0], points[1]), "Unsupported cache uses exact sampler")
	Layout._clearance_cells = saved
	for p in [Vector2(INF, 0), Vector2(NAN, 0), Vector2(-INF, 0), Vector2(10000, 10000)]:
		check(not Layout._segment_region_clear(p, Vector2.ZERO), "Nonfinite/distant input cannot fast accept")

func run() -> void:
	var start := Time.get_ticks_usec()
	rng.seed = SEED
	var cold := Time.get_ticks_usec()
	layout = Layout.new()
	var layout_us := Time.get_ticks_usec() - cold
	check(not Layout._segment_prefix.is_empty(), "Constructor prepares the prefix before gameplay")
	cold = Time.get_ticks_usec()
	var rebuilt := Layout._build_segment_prefix(Layout._clearance_cells)
	var prefix_us := Time.get_ticks_usec() - cold
	check(rebuilt == Layout._segment_prefix, "Standalone builder matches the constructor-prepared prefix")
	verify_prefix_and_fallback()
	var groups := make_groups()
	var results := {}
	for name in groups:
		var work := verify_group(name, groups[name])
		results[name] = {"work": work, "timing": measure_group(groups[name], work)}
	var report := {"measurement": "native headless GDScript functions only; percentiles of batch means, not individual-call latency or browser FPS",
		"seed": SEED, "warmup_batches": WARMUP, "measured_batches": BATCHES, "alternating_order": true,
		"cold_layout_init_including_prefix_us": layout_us, "standalone_prefix_rebuild_us": prefix_us,
		"additional_prefix_bytes": Layout._segment_prefix.size() * 4,
		"groups": results, "checks": checks, "failures": failures, "elapsed_ms": (Time.get_ticks_usec() - start) / 1000.0}
	print("FUNCTION_BENCHMARK_JSON ", JSON.stringify(report))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			var file := FileAccess.open(arg.get_slice("=", 1), FileAccess.WRITE)
			if file: file.store_string(JSON.stringify(report, "  ") + "\n")
			else: check(false, "Requested JSON output is writable")
	print("FUNCTION_BENCHMARK: %d/%d passed" % [checks - failures, checks])
	quit(1 if failures else 0)
