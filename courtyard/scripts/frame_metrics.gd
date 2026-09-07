class_name FieldFrameMetrics
extends RefCounted

# Bounded recent LIVE frame intervals. Use the monotonic wall clock, not dt
# (which can be capped by the engine). Pause/menu time never becomes a stall.
const CAPACITY := 1800
var values := PackedFloat64Array()
var count := 0
var cursor := 0
var previous := 0
var report_at := 0
var cached: Dictionary = {}

func _init() -> void:
	values.resize(CAPACITY)

func record(now: int, active: bool) -> void:
	if not active:
		if previous > 0: cached = summary()
		previous = 0
		return
	if previous > 0:
		values[cursor] = (now - previous) / 1000.0
		cursor = (cursor + 1) % CAPACITY
		count = mini(count + 1, CAPACITY)
	previous = now
	if now >= report_at:
		cached = summary()
		report_at = now + 1000000

func summary() -> Dictionary:
	if count == 0: return {"samples": 0}
	var ordered := values.slice(0,count)
	ordered.sort()
	var total := 0.0
	var over_33 := 0
	var over_50 := 0
	var over_100 := 0
	for value in ordered:
		total += value
		if value > 33.34: over_33 += 1
		if value > 50: over_50 += 1
		if value > 100: over_100 += 1
	return {"samples": count, "window_seconds": total / 1000.0, "mean_fps": count * 1000.0 / maxf(total,0.001),
		"p50_ms": ordered[ceili(count * 0.50)-1], "p95_ms": ordered[ceili(count * 0.95)-1],
		"p99_ms": ordered[ceili(count * 0.99)-1], "max_ms": ordered[-1],
		"over_33_ms": over_33, "over_50_ms": over_50, "over_100_ms": over_100}
