extends SceneTree

# Exact old/new predicates. This fixture has no rendering or game simulation.
# Dense and boundary-focused points exercise the half-open union convention;
# clearance and segments keep their original corner/obstacle sampling.
const Layout = preload("res://scripts/layout.gd")
var checks := 0
var failures := 0
var points_compared := 0

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ",label)

func old_inside(p: Vector2) -> bool:
	for room in Layout.ROOMS:
		if room.has_point(p): return true
	return false

func old_clear(p: Vector2, radius: float) -> bool:
	for offset in [Vector2.ZERO,Vector2(radius,radius),Vector2(-radius,radius),Vector2(radius,-radius),Vector2(-radius,-radius)]:
		if not old_inside(p + offset): return false
	for cover in Layout.COVERS:
		if cover.grow(radius).has_point(p): return false
	for door in Layout.DOORS:
		var local := (p - Vector2(door.hinge)).rotated(float(door.yaw))
		var rect := Rect2(minf(0,door.side*door.width),-0.15,door.width,0.30)
		if rect.grow(radius).has_point(local): return false
	for support in Layout.CT_SUPPORTS:
		if support.grow(radius).has_point(p): return false
	return true

func old_segment(a: Vector3, b: Vector3) -> bool:
	var from := Vector2(a.x,a.z)
	var to := Vector2(b.x,b.z)
	var count := maxi(1,ceili(from.distance_to(to) / 0.22))
	for i in range(count + 1):
		if not old_clear(from.lerp(to,float(i) / count),0.43): return false
	return true

func compare_points(points: PackedVector2Array, label: String, clearance: bool = true) -> void:
	var same_union := true
	var same_clearance := true
	for p in points:
		points_compared += 1
		same_union = same_union and Layout.inside(p) == old_inside(p)
		if clearance:
			for radius in [0.0,0.1,0.38,0.43,0.7]:
				same_clearance = same_clearance and Layout.clear(p,radius) == old_clear(p,radius)
	check(same_union,label + ": identical room union")
	if clearance: check(same_clearance,label + ": identical body clearance at five radii")

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var points := PackedVector2Array()
	# A dense sub-unit grid, including one cell outside every map edge.
	for y in range(-90,95):
		for x in range(-90,91):
			points.append(Vector2(x * 0.5,y * 0.5))
	compare_points(points,"Dense half-unit grid",false)
	points.clear()
	for room in Layout.ROOMS:
		for x in [room.position.x,room.end.x]:
			for y in [room.position.y,room.end.y]:
				for dx in [-0.00001,0.0,0.00001]:
					for dy in [-0.00001,0.0,0.00001]:
						points.append(Vector2(x+dx,y+dy))
		for x in range(int(room.position.x),int(room.end.x)+1):
			for edge in [room.position.y,room.end.y]:
				for delta in [-0.00001,0.0,0.00001]: points.append(Vector2(x,edge+delta))
		for y in range(int(room.position.y),int(room.end.y)+1):
			for edge in [room.position.x,room.end.x]:
				for delta in [-0.00001,0.0,0.00001]: points.append(Vector2(edge+delta,y))
	compare_points(points,"Room corners and edges")
	points.clear()
	for door in Layout.DOORS:
		for corner in Layout.door_corners(door):
			for dx in [-0.43,-0.00001,0.0,0.00001,0.43]:
				for dy in [-0.43,-0.00001,0.0,0.00001,0.43]:
					points.append(corner + Vector2(dx,dy))
	compare_points(points,"Door corners and clearance margins")
	compare_points(PackedVector2Array([Vector2(-INF,0),Vector2(INF,0),Vector2(0,-INF),Vector2(0,INF),
		Vector2(NAN,0),Vector2(0,NAN),Vector2(NAN,NAN),Vector2(1e30,-1e30)]),"Nonfinite and distant points",false)
	check(Layout._room_cells.size() == Layout.BOUNDS.size.x * Layout.BOUNDS.size.y,"Exactly 7,920 bytes, independent of query count")
	var unit_bounds := Rect2i(-2,-2,4,4)
	var cells := Layout._build_room_lookup([Rect2(-2,-2,2,2),Rect2(-1,-1,2,2)],unit_bounds)
	check(cells.size() == 16 and cells.count(1) == 7,"Overlapping integer rooms form a union")
	check(Layout._build_room_lookup([Rect2(-1.5,-1,1,1)],unit_bounds).is_empty(),"Fractional room starts select original-predicate fallback")
	check(Layout._build_room_lookup([Rect2(-1,-1,1.5,1)],unit_bounds).is_empty(),"Fractional room ends select original-predicate fallback")
	check(Layout._build_room_lookup([Rect2(-3,-1,1,1)],unit_bounds).is_empty(),"Out-of-bounds rooms select original-predicate fallback")
	check(Layout._build_room_lookup([Rect2(0,0,-1,1)],unit_bounds).is_empty(),"Negative room sizes select original-predicate fallback")
	check(Layout._build_room_lookup([],Rect2i()).is_empty(),"Empty bounds are safe")
	var layout := Layout.new()
	var same_grid := true
	for y in range(Layout.BOUNDS.position.y,Layout.BOUNDS.end.y):
		for x in range(Layout.BOUNDS.position.x,Layout.BOUNDS.end.x):
			same_grid = same_grid and layout.nav.is_point_solid(Vector2i(x,y)) == not old_clear(Vector2(x+0.5,y+0.5),0.43)
	check(same_grid,"Every AStarGrid cell retains its original solidity")
	var routes := [[Vector3(1.5,0,-24),Vector3(1.5,0,-17)], [Vector3(28.5,0,13),Vector3(28.5,0,21)],
		[Layout.CT_SPAWN,Layout.T_SPAWN],[Layout.CT_SPAWN,Layout.SITE_A],[Layout.T_SPAWN,Layout.SITE_B]]
	for route in routes:
		check(layout.segment_clear(route[0],route[1]) == old_segment(route[0],route[1]),"Segment sampling retains exact room/obstacle decisions")
	print("ROOM_LOOKUP: %d/%d passed; %d points compared" % [checks-failures,checks,points_compared])
	quit(1 if failures else 0)
