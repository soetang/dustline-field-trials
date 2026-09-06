extends SceneTree

# Differential geometry test: the reference deliberately keeps the original
# rectangle union, five clearance samples, rotated doors, and 0.22 m segment
# sampling. No physics, rendering, gameplay simulation, or timing pass/fail gate.
const Layout = preload("res://scripts/layout.gd")
const RADII := [0.0, 0.1, 0.32, 0.38, 0.43, 0.430000000001, 0.429999999999, 0.7, 1.25]
const SEED := 0x43c1ea
var checks := 0
var failures := 0
var point_comparisons := 0
var segment_comparisons := 0
var false_clear := 0
var false_blocked := 0
var bit_buffer := PackedByteArray()
var rng := RandomNumberGenerator.new()
var layout: FieldLayout

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		if failures <= 12: printerr("FAIL: ", label)

func old_inside(p: Vector2) -> bool:
	for room in Layout.ROOMS:
		if room.has_point(p): return true
	return false

func old_clear(p: Vector2, radius: float) -> bool:
	for offset in [Vector2.ZERO, Vector2(radius, radius), Vector2(-radius, radius), Vector2(radius, -radius), Vector2(-radius, -radius)]:
		if not old_inside(p + offset): return false
	for cover in Layout.COVERS:
		if cover.grow(radius).has_point(p): return false
	for door in Layout.DOORS:
		var local := (p - Vector2(door.hinge)).rotated(float(door.yaw))
		var rect := Rect2(minf(0, door.side * door.width), -0.15, door.width, 0.30)
		if rect.grow(radius).has_point(local): return false
	for support in Layout.CT_SUPPORTS:
		if support.grow(radius).has_point(p): return false
	return true

func old_segment(a: Vector3, b: Vector3) -> bool:
	var from := Vector2(a.x, a.z)
	var to := Vector2(b.x, b.z)
	var count := maxi(1, ceili(from.distance_to(to) / 0.22))
	for i in range(count + 1):
		if not old_clear(from.lerp(to, float(i) / count), 0.43): return false
	return true

# Benchmark baseline is the immediately preceding implementation, with its
# existing exact room lookup. Using old_clear here would wrongly attribute the
# earlier room-union optimization to this new clearance broad phase.
func before_broadphase_clear(p: Vector2, radius: float) -> bool:
	for offset in [Vector2.ZERO, Vector2(radius, radius), Vector2(-radius, radius), Vector2(radius, -radius), Vector2(-radius, -radius)]:
		if not Layout.inside(p + offset): return false
	for cover in Layout.COVERS:
		if cover.grow(radius).has_point(p): return false
	for door in Layout.DOORS:
		var local := (p - Vector2(door.hinge)).rotated(float(door.yaw))
		var rect := Rect2(minf(0, door.side * door.width), -0.15, door.width, 0.30)
		if rect.grow(radius).has_point(local): return false
	for support in Layout.CT_SUPPORTS:
		if support.grow(radius).has_point(p): return false
	return true

func before_broadphase_segment(a: Vector3, b: Vector3) -> bool:
	var from := Vector2(a.x, a.z)
	var to := Vector2(b.x, b.z)
	var count := maxi(1, ceili(from.distance_to(to) / 0.22))
	for i in range(count + 1):
		if not before_broadphase_clear(from.lerp(to, float(i) / count), 0.43): return false
	return true

func compare_point(p: Vector2, radius: float, label: String) -> void:
	point_comparisons += 1
	var expected := old_clear(p, radius)
	var actual := Layout.clear(p, radius)
	if actual != expected:
		if actual: false_clear += 1
		else: false_blocked += 1
		check(false, "%s p=(%.12g,%.12g) radius=%.15g expected=%s actual=%s" % [label, p.x, p.y, radius, expected, actual])
	else:
		checks += 1

func compare_segment(a: Vector3, b: Vector3, label: String) -> void:
	segment_comparisons += 1
	var expected := old_segment(a, b)
	var actual := layout.segment_clear(a, b)
	if actual != expected:
		check(false, "%s a=%s b=%s expected=%s actual=%s" % [label, a, b, expected, actual])
	else:
		checks += 1

# Vector2 components are float32 in this build. Fixed tiny epsilons disappear
# at map-scale coordinates, so test the actual adjacent representable values.
func adjacent(value: float, upward: bool) -> float:
	bit_buffer.encode_float(0, value)
	var stored := bit_buffer.decode_float(0)
	var bits := bit_buffer.decode_u32(0)
	if stored == 0.0:
		bits = 1 if upward else 0x80000001
	else:
		bits += 1 if (stored > 0.0) == upward else -1
	bit_buffer.encode_u32(0, bits)
	return bit_buffer.decode_float(0)

func compare_neighbours(p: Vector2, radius: float, label: String) -> void:
	for x in [adjacent(p.x, false), p.x, adjacent(p.x, true)]:
		for y in [adjacent(p.y, false), p.y, adjacent(p.y, true)]:
			compare_point(Vector2(x, y), radius, label)

func perimeter(rect: Rect2) -> PackedVector2Array:
	var points := PackedVector2Array()
	for t in [0.0, 0.25, 0.5, 0.75, 1.0]:
		points.append(Vector2(lerpf(rect.position.x, rect.end.x, t), rect.position.y))
		points.append(Vector2(lerpf(rect.position.x, rect.end.x, t), rect.end.y))
		points.append(Vector2(rect.position.x, lerpf(rect.position.y, rect.end.y, t)))
		points.append(Vector2(rect.end.x, lerpf(rect.position.y, rect.end.y, t)))
	return points

func random_point(padding: float = 0.0) -> Vector2:
	return Vector2(rng.randf_range(Layout.BOUNDS.position.x - padding, Layout.BOUNDS.end.x + padding), rng.randf_range(Layout.BOUNDS.position.y - padding, Layout.BOUNDS.end.y + padding))

func verify_cells() -> void:
	var width := Layout.BOUNDS.size.x * 2
	var height := Layout.BOUNDS.size.y * 2
	for y in range(height + 1):
		for x in range(width + 1):
			var corner := Vector2(Layout.BOUNDS.position) + Vector2(x, y) * 0.5
			compare_neighbours(corner, 0.43, "Half-cell corner/ULP")
			if x < width and y < height:
				compare_point(corner + Vector2(0.25, 0.25), 0.43, "Half-cell centre")
				compare_point(corner + Vector2(0.25, 0.0), 0.43, "Half-cell horizontal edge")
				compare_point(corner + Vector2(0.0, 0.25), 0.43, "Half-cell vertical edge")
	for y in range(Layout.BOUNDS.position.y, Layout.BOUNDS.end.y):
		for x in range(Layout.BOUNDS.position.x, Layout.BOUNDS.end.x):
			check(layout.nav.is_point_solid(Vector2i(x, y)) == not old_clear(Vector2(x + 0.5, y + 0.5), 0.43), "AStar cell retains original solidity")

func verify_edges() -> void:
	for radius: float in RADII:
		var offsets := [Vector2.ZERO, Vector2(radius, radius), Vector2(-radius, radius), Vector2(radius, -radius), Vector2(-radius, -radius)]
		for room: Rect2 in Layout.ROOMS:
			for edge in perimeter(room):
				for offset: Vector2 in offsets:
					compare_neighbours(edge - offset, radius, "Room sample on edge/ULP")
		for obstacle: Rect2 in Layout.COVERS + Layout.CT_SUPPORTS:
			for edge in perimeter(obstacle.grow(radius)):
				compare_neighbours(edge, radius, "Expanded obstacle edge/ULP")
		for door: Dictionary in Layout.DOORS:
			var rect := Rect2(minf(0, door.side * door.width), -0.15, door.width, 0.30).grow(radius)
			for edge in perimeter(rect):
				var world := Vector2(door.hinge) + edge.rotated(-float(door.yaw))
				compare_neighbours(world, radius, "Rotated expanded door edge/world ULP")
				# Approach in door-local space too, to test the inverse rotation's
				# rounded result rather than assuming world/local round trips exact.
				for delta in [Vector2(0.0001, 0), Vector2(-0.0001, 0), Vector2(0, 0.0001), Vector2(0, -0.0001)]:
					compare_point(Vector2(door.hinge) + (edge + delta).rotated(-float(door.yaw)), radius, "Rotated door local-side samples")

func verify_random_and_fallbacks() -> void:
	for i in 12000:
		var p := random_point(4.0)
		compare_point(p, 0.43, "Seeded fixed-radius point")
		compare_point(p, float(RADII[i % RADII.size()]), "Seeded alternate-radius point")
		if i % 4 == 0: compare_point(p, rng.randf_range(0.0, 3.5), "Seeded arbitrary-radius point")
	for p in [Vector2(-INF, 0), Vector2(INF, 0), Vector2(0, -INF), Vector2(0, INF), Vector2(NAN, 0), Vector2(0, NAN), Vector2(NAN, NAN), Vector2(1e30, -1e30)]:
		for radius: float in [0.0, 0.38, 0.43, 0.7]: compare_point(p, radius, "Nonfinite/distant point fallback")
	for p in [Vector2(1, -33), Vector2(29, 20), Vector2.ZERO]:
		for radius: float in [INF, NAN, 1e30]: compare_point(p, radius, "Nonfinite/distant radius fallback")
	# Simulate the documented unsupported-layout signal without changing map
	# constants: an empty, already-built room cache must disable the broad phase.
	var saved_rooms := Layout._room_cells
	var saved_clearance := Layout._clearance_cells
	Layout._room_cells = PackedByteArray()
	Layout._clearance_cells = PackedByteArray()
	Layout._clearance_lookup_ready = false
	compare_point(Vector2(1, -33), 0.43, "Unsupported room lookup fallback")
	check(Layout._clearance_cells.is_empty(), "Unsupported room lookup leaves clearance cache empty")
	for i in 256: compare_point(random_point(1.0), 0.43, "Seeded unsupported room lookup fallback")
	Layout._room_cells = saved_rooms
	Layout._clearance_cells = saved_clearance
	Layout._clearance_lookup_ready = true

func verify_segments() -> void:
	for i in 1600:
		var a := random_point(1.0)
		var b := random_point(1.0) if i % 3 == 0 else a + Vector2.from_angle(rng.randf_range(-PI, PI)) * rng.randf_range(0.0, 14.0)
		var from := Vector3(a.x, rng.randf_range(-20.0, 20.0), a.y)
		var to := Vector3(b.x, rng.randf_range(-20.0, 20.0), b.y)
		compare_segment(from, to, "Seeded segment")
		compare_segment(to, from, "Seeded reverse segment")
	var starts := PackedVector2Array([Vector2(1.5, -33), Vector2(1.5, -24), Vector2(28.5, 13), Vector2(-7.57, -33), Vector2(16, -26), Vector2(29, 20)])
	for door: Dictionary in Layout.DOORS: starts.append(Vector2(door.hinge))
	for a in starts:
		for step in [0, 1, 2, 3, 5, 10, 25]:
			var length: float = step * 0.22
			for distance: float in [maxf(0.0, adjacent(length, false)), length, adjacent(length, true)]:
				for angle: float in [0.0, PI / 6, PI / 4, PI / 2, PI * 0.7, PI]:
					var b := a + Vector2.from_angle(angle) * distance
					compare_segment(Vector3(a.x, 0, a.y), Vector3(b.x, 999, b.y), "0.22 m sampling threshold/height ignored")
	for door: Dictionary in Layout.DOORS:
		var rect := Rect2(minf(0, door.side * door.width), -0.15, door.width, 0.30).grow(0.43)
		for edge in perimeter(rect):
			var a := Vector2(door.hinge) + edge.rotated(-float(door.yaw))
			for delta: Vector2 in [Vector2(0.02, 0), Vector2(-0.02, 0), Vector2(0, 0.02), Vector2(0, -0.02)]:
				var b := a + delta.rotated(-float(door.yaw))
				compare_segment(Vector3(a.x, 0, a.y), Vector3(b.x, 0, b.y), "Door boundary crossing")
				compare_segment(Vector3(b.x, 0, b.y), Vector3(a.x, 0, a.y), "Reverse door boundary crossing")

func benchmark() -> void:
	var froms := PackedVector3Array()
	var tos := PackedVector3Array()
	var lengths := [0.22, 0.66, 1.5, 3.0, 6.0, 12.0]
	for i in 600:
		var p := random_point()
		while not old_clear(p, 0.43): p = random_point()
		var q := p + Vector2.from_angle(rng.randf_range(-PI, PI)) * float(lengths[i % lengths.size()])
		froms.append(Vector3(p.x, 0, p.y))
		tos.append(Vector3(q.x, 0, q.y))
	var baseline := PackedFloat64Array()
	var candidate := PackedFloat64Array()
	var expected_checksum := -1
	for repetition in 6:
		# Warm once, then alternate ordering so neither side always runs first.
		for which in ([0, 1] if repetition % 2 == 0 else [1, 0]):
			var checksum := 0
			var start := Time.get_ticks_usec()
			for i in froms.size():
				if before_broadphase_segment(froms[i], tos[i]) if which == 0 else layout.segment_clear(froms[i], tos[i]): checksum += 1
			var elapsed := float(Time.get_ticks_usec() - start) / froms.size()
			if expected_checksum < 0: expected_checksum = checksum
			check(checksum == expected_checksum, "Benchmark baseline/candidate checksum")
			if repetition > 0:
				if which == 0: baseline.append(elapsed)
				else: candidate.append(elapsed)
	baseline.sort()
	candidate.sort()
	print("NAVIGATION_CLEARANCE_BENCH: native headless 600 fixed seeded segments, 1 warmup + 5 alternating samples; room lookup enabled in both")
	print("NAVIGATION_CLEARANCE_BENCH: original_clearance median=%.3f range=%.3f..%.3f us/segment; broadphase median=%.3f range=%.3f..%.3f us/segment; clear_checksum=%d/600; report only, not browser FPS" % [baseline[2], baseline[0], baseline[4], candidate[2], candidate[0], candidate[4], expected_checksum])

func run() -> void:
	var test_start := Time.get_ticks_usec()
	bit_buffer.resize(4)
	rng.seed = SEED
	check(adjacent(44.0, false) < 44.0 and adjacent(44.0, true) > 44.0, "ULP neighbours remain distinct at positive map edge")
	check(adjacent(-44.0, false) < -44.0 and adjacent(-44.0, true) > -44.0, "ULP neighbours remain distinct at negative map edge")
	Layout._room_lookup_ready = false
	Layout._room_cells = PackedByteArray()
	Layout._clearance_lookup_ready = false
	Layout._clearance_cells = PackedByteArray()
	var cold_start := Time.get_ticks_usec()
	var first := Layout.clear(Vector2(1, -33), 0.43)
	var cold_usec := Time.get_ticks_usec() - cold_start
	check(first == old_clear(Vector2(1, -33), 0.43), "Cold first query retains original result")
	check(Layout._clearance_cells.size() == 31680, "Clearance lookup is exactly 31,680 bytes")
	check(Layout._clearance_cells.count(0) > 0 and Layout._clearance_cells.count(1) > 0 and Layout._clearance_cells.count(2) > 0, "Mixed, clear, and blocked paths are all present")
	print("NAVIGATION_CLEARANCE_CACHE: cold_first_query_us=%d (includes room lookup); bytes=%d mixed=%d clear=%d blocked=%d" % [cold_usec, Layout._clearance_cells.size(), Layout._clearance_cells.count(0), Layout._clearance_cells.count(1), Layout._clearance_cells.count(2)])
	layout = Layout.new()
	verify_cells()
	verify_edges()
	verify_random_and_fallbacks()
	verify_segments()
	if not OS.get_cmdline_user_args().has("--no-bench"): benchmark()
	print("NAVIGATION_CLEARANCE: %d/%d passed; points=%d segments=%d false_clear=%d false_blocked=%d seed=%d elapsed_ms=%.2f" % [checks - failures, checks, point_comparisons, segment_comparisons, false_clear, false_blocked, SEED, float(Time.get_ticks_usec() - test_start) / 1000.0])
	quit(1 if failures else 0)
