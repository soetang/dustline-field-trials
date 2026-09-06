extends RefCounted

## Test-only single-thread collector. The runner copies this into its temporary
## project; the playable game has neither probes nor this resource.
## "Self" removes nested instrumented scopes, NOT calls into the native engine.
const STACK_SIZE := 32
const FRAME_CAPACITY := 2048
static var enabled := false
static var reference_navigation := false # isolated ABBA fixture only
static var labels := PackedStringArray()
static var calls := PackedInt64Array()
static var inclusive := PackedInt64Array()
static var exclusive := PackedInt64Array()
static var maximum := PackedInt64Array()
static var stack_ids := PackedInt32Array()
static var stack_start := PackedInt64Array()
static var stack_child := PackedInt64Array()
static var depth := 0
static var frame_count := 0
static var dropped_frames := 0
static var frames := PackedFloat64Array()
static var self_frames := PackedFloat64Array()
static var last_self := PackedInt64Array()

static func reset(names: PackedStringArray) -> void:
	assert(depth == 0, "Cannot reset in a measured scope")
	enabled = false
	labels = names
	calls.resize(names.size())
	calls.fill(0)
	inclusive.resize(names.size())
	inclusive.fill(0)
	exclusive.resize(names.size())
	exclusive.fill(0)
	maximum.resize(names.size())
	maximum.fill(0)
	last_self.resize(names.size())
	last_self.fill(0)
	stack_ids.resize(STACK_SIZE)
	stack_start.resize(STACK_SIZE)
	stack_child.resize(STACK_SIZE)
	frame_count = 0
	dropped_frames = 0
	frames.resize(FRAME_CAPACITY)
	# Flat, uniquely owned storage avoids nested PackedArray copy-on-write
	# during the profiler's own per-frame updates.
	self_frames.resize(FRAME_CAPACITY * names.size())

static func begin(id: int, now: int = -1) -> void:
	assert(enabled and id >= 0 and id < labels.size() and depth < STACK_SIZE)
	stack_ids[depth] = id
	stack_child[depth] = 0
	stack_start[depth] = Time.get_ticks_usec() if now < 0 else now
	depth += 1

static func end(now: int = -1) -> void:
	var finished := Time.get_ticks_usec() if now < 0 else now
	assert(depth > 0)
	depth -= 1
	var id := stack_ids[depth]
	var elapsed := maxi(0, finished - stack_start[depth])
	calls[id] += 1
	inclusive[id] += elapsed
	exclusive[id] += maxi(0, elapsed - stack_child[depth])
	maximum[id] = maxi(maximum[id], elapsed)
	if depth > 0: stack_child[depth - 1] += elapsed

static func record_frame(elapsed_us: int) -> void:
	assert(depth == 0)
	if frame_count == FRAME_CAPACITY:
		dropped_frames += 1
		return
	frames[frame_count] = elapsed_us / 1000.0
	for id in labels.size():
		self_frames[id * FRAME_CAPACITY + frame_count] = (exclusive[id] - last_self[id]) / 1000.0
		last_self[id] = exclusive[id]
	frame_count += 1

static func summary() -> Dictionary:
	assert(depth == 0)
	var rows: Array[Dictionary] = []
	var self_total := 0
	for id in labels.size():
		var sorted := self_frames.slice(id * FRAME_CAPACITY, id * FRAME_CAPACITY + frame_count)
		sorted.sort()
		self_total += exclusive[id]
		rows.append({"scope": labels[id], "calls": calls[id],
			"inclusive_ms": inclusive[id] / 1000.0, "self_ms": exclusive[id] / 1000.0,
			"mean_inclusive_us_per_call": inclusive[id] / float(maxi(1, calls[id])),
			"mean_self_ms_per_frame": exclusive[id] / (1000.0 * maxi(1, frame_count)),
			"p95_self_ms_per_frame": sorted[ceili(frame_count * 0.95) - 1] if frame_count else 0,
			"max_inclusive_ms_per_call": maximum[id] / 1000.0})
	return {"frames": frame_count, "dropped_frames": dropped_frames,
		"samples_ms": frames.slice(0, frame_count), "scopes": rows,
		"instrumented_self_ms": self_total / 1000.0,
		"mean_instrumented_self_ms_per_frame": self_total / (1000.0 * maxi(1, frame_count)),
		"semantics": "self excludes nested probes, but includes native engine calls and some probe overhead; not total CPU/GPU time"}
