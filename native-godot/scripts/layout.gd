class_name FieldLayout
extends RefCounted

## Original blockout: recognisable long / mid / catwalk / tunnels / two sites.
## Measurements and geometry are authored here, not extracted from Valve maps.
const BOUNDS := Rect2i(-44, -44, 88, 90)
const CT_SPAWN := Vector3(1, 0, -33)
const T_SPAWN := Vector3(-9, 0, 36)
const SITE_A := Vector3(27, 0, -29)
const SITE_B := Vector3(-29, 0, -28)
const ROOMS := [
	Rect2(-16, 28, 32, 14), # T courtyard
	Rect2(12, 22, 24, 12), # long approach
	Rect2(24, 10, 8, 16), # long doors
	Rect2(24, 2, 18, 14), # long corner
	Rect2(32, -24, 10, 30), # long lane + ramp
	Rect2(14, -38, 28, 18), # A site
	Rect2(-8, -38, 24, 12), # CT spawn / A ramp
	Rect2(-18, -32, 14, 10), # B doors / CT link
	Rect2(-40, -38, 24, 22), # B site
	Rect2(-38, -18, 10, 40), # upper tunnels
	Rect2(-34, 18, 24, 16), # tunnel entrance
	Rect2(-28, 2, 28, 8), # lower tunnels
	Rect2(-4, -26, 10, 56), # middle
	Rect2(4, -4, 14, 8), # short turn
	Rect2(12, -24, 7, 24), # catwalk
	Rect2(-8, -30, 16, 8), # middle doors
]
const COVERS := [
	Rect2(-3, 27, 4, 3), Rect2(7, 35, 4, 2),
	Rect2(26, 27, 3, 3), Rect2(35, 7, 4, 2),
	Rect2(35, -13, 2, 3), Rect2(22, -30, 3, 3),
	Rect2(32, -34, 4, 3), Rect2(16, -26, 2, 2),
	Rect2(-34, -31, 3, 4), Rect2(-24, -24, 3, 3),
	Rect2(-37, -21, 3, 2), Rect2(-34, 14, 3, 2),
	Rect2(-23, 24, 3, 3), Rect2(2, 14, 2, 3),
	Rect2(-3, -16, 2, 3), Rect2(-3, -29, 3, 2),
]
const DOORS := [
	# Hinged leaves: x/z footprints, collision and radar use this same geometry.
	{"hinge":Vector2(24.2,16.5),"width":3.70,"side":1.0,"yaw":-PI/12},
	{"hinge":Vector2(31.8,16.5),"width":2.85,"side":-1.0,"yaw":PI/7.5},
	{"hinge":Vector2(-3.8,-21),"width":4.85,"side":1.0,"yaw":-PI/9.5},
	{"hinge":Vector2(5.8,-21),"width":3.90,"side":-1.0,"yaw":PI/8},
]
# Ground-level supports only. The CT building's occupied upper storey is above
# the walkable undercroft and must not turn the spawn into a solid nav obstacle.
const CT_SUPPORTS := [Rect2(-7.9,-35.5,0.6,0.6),Rect2(-7.9,-29,0.6,0.6),
	Rect2(11.5,-35.5,0.6,0.6),Rect2(11.5,-29,0.6,0.6)]

var nav := AStarGrid2D.new()

func _init() -> void:
	nav.region = BOUNDS
	nav.cell_size = Vector2.ONE
	nav.offset = Vector2(0.5, 0.5)
	nav.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	nav.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	nav.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	nav.update()
	for x in range(BOUNDS.position.x, BOUNDS.end.x):
		for z in range(BOUNDS.position.y, BOUNDS.end.y):
			nav.set_point_solid(Vector2i(x, z), not clear(Vector2(x + 0.5, z + 0.5), 0.43))

static func floor_height(p: Vector2) -> float:
	var south := 1.6 * clampf((p.y - 14.0) / 14.0, 0.0, 1.0)
	var a_ramp := 2.2 * clampf((p.x - 4.0) / 8.0, 0.0, 1.0) * clampf((-p.y - 2.0) / 20.0, 0.0, 1.0)
	return maxf(south, a_ramp)

static func on_floor(p: Vector3) -> Vector3:
	return Vector3(p.x, floor_height(Vector2(p.x, p.z)), p.z)

static func inside(p: Vector2) -> bool:
	for room in ROOMS:
		if room.has_point(p):
			return true
	return false

static func clear(p: Vector2, radius: float = 0.38) -> bool:
	# Check the union, not individual shrunken rooms: connected doorways stay open.
	for offset in [Vector2.ZERO, Vector2(radius, radius), Vector2(-radius, radius), Vector2(radius, -radius), Vector2(-radius, -radius)]:
		if not inside(p + offset):
			return false
	for cover in COVERS:
		if cover.grow(radius).has_point(p):
			return false
	for door in DOORS:
		var local := (p - Vector2(door.hinge)).rotated(float(door.yaw))
		if door_rect(door).grow(radius).has_point(local): return false
	for support in CT_SUPPORTS:
		if support.grow(radius).has_point(p): return false
	return true

static func door_rect(door: Dictionary) -> Rect2:
	return Rect2(minf(0,door.side*door.width),-0.15,door.width,0.30)

static func door_corners(door: Dictionary) -> PackedVector2Array:
	var rect := door_rect(door)
	var points := PackedVector2Array()
	for corner in [rect.position,Vector2(rect.end.x,rect.position.y),rect.end,Vector2(rect.position.x,rect.end.y)]:
		points.append(Vector2(door.hinge)+corner.rotated(-float(door.yaw)))
	return points

static func door_floor(door: Dictionary) -> float:
	# Fit the lowest part of the rotated leaf, not just its uphill hinge.
	var base := floor_height(door.hinge)
	for corner in door_corners(door): base = minf(base,floor_height(corner))
	return base

func cell(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x), floori(p.z))

func nearest(p: Vector3) -> Vector2i:
	var c := cell(p)
	if nav.is_in_boundsv(c) and not nav.is_point_solid(c):
		return c
	var best := c
	var best_distance := INF
	for dx in range(-8, 9):
		for dz in range(-8, 9):
			var candidate := c + Vector2i(dx, dz)
			if nav.is_in_boundsv(candidate) and not nav.is_point_solid(candidate):
				var distance := Vector2(dx, dz).length_squared()
				if distance < best_distance:
					best_distance = distance
					best = candidate
	return best

func segment_clear(a: Vector3, b: Vector3) -> bool:
	var from := Vector2(a.x, a.z)
	var to := Vector2(b.x, b.z)
	var count := maxi(1, ceili(from.distance_to(to) / 0.22))
	for i in range(count + 1):
		if not clear(from.lerp(to, float(i) / count), 0.43):
			return false
	return true

func path(from: Vector3, to: Vector3) -> PackedVector3Array:
	var points := nav.get_point_path(nearest(from), nearest(to))
	var result := PackedVector3Array()
	for point in points:
		result.append(on_floor(Vector3(point.x, 0, point.y)))
	# Keep the first centering waypoint when displacement makes the next leg unsafe.
	if result.size() > 1 and segment_clear(from, result[1]):
		result.remove_at(0)
	return result

static func callout(p: Vector3) -> String:
	if p.z > 28: return "T COURTYARD"
	if p.x < -16 and p.z < -16: return "B SITE"
	if p.x < -27: return "UPPER TUNNELS"
	if p.x < -6 and p.z > 16: return "TUNNEL ENTRANCE"
	if p.x < -5 and p.z > 0: return "LOWER TUNNELS"
	if p.x > 13 and p.z < -21: return "A SITE"
	if p.x > 23: return "LONG"
	if p.x > 10: return "SHORT / CATWALK"
	if p.z < -25: return "CT COURTYARD"
	return "MIDDLE"
