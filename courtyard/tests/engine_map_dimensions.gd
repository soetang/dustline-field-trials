extends SceneTree

# Call only the fixture's pure dimension predicate: no scene, window resize,
# renderer, JavaScript bridge or image readback is created by this regression.
const Review = preload("res://tests/engine_map_review.gd")
var checks := 0
var failures := 0

func _initialize() -> void: call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ",label)

func run() -> void:
	for size in [Vector2i(2560,1242),Vector2i(1600,900)]:
		var parsed = JSON.parse_string(JSON.stringify([size.x,size.y]))
		check(parsed is Array and typeof(parsed[0]) == TYPE_FLOAT and typeof(parsed[1]) == TYPE_FLOAT,
			"actual JSON dimensions are floating-point numbers")
		check(parsed != [size.x,size.y],"regression reproduces the old type-sensitive array failure")
		check(Review.canvas_matches_window(parsed,size),"exact JSON dimensions match the physical Window")
	for source in ["[2559,1242]","[2560,1241]","[2560.5,1242]","[2560,1242.5]",
		"[1242,2560]","[-2560,1242]","[2560]","[2560,1242,0]","[]",
		"[\"2560\",1242]","[true,1242]","null","{\"width\":2560,\"height\":1242}"]:
		check(not Review.canvas_matches_window(JSON.parse_string(source),Vector2i(2560,1242)),
			"incorrect or malformed observed dimensions are rejected: "+source)
	print("ENGINE_MAP_DIMENSIONS: %d/%d passed" % [checks-failures,checks])
	quit(1 if failures else 0)
