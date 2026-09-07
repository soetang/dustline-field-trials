class_name FieldWeaponClearance
extends RefCounted

## Visual clearance only: never changes an actor capsule, bullet ray or accuracy.
## Cached whole-weapon hull, not a muzzle-only ray (which misses oblique walls).
## All transforms here are rigid; bake the viewmodel's .54 scale into bounds.
const SKIN := 0.055 # Covers door handles/ironwork beyond the solid leaf face.
const SEARCH_STEPS := 6
var bounds := AABB()
var center := Vector3.ZERO
var amount := 0.0
var blocked := false
var clear := true
var query := PhysicsShapeQueryParameters3D.new()
var ray := PhysicsRayQueryParameters3D.new()
var shape := BoxShape3D.new()
var queries := 0

func configure(hull: AABB) -> void:
	bounds = hull
	center = bounds.get_center()
	shape.size = bounds.size + Vector3.ONE * SKIN * 2
	query.shape = shape
	query.collision_mask = 1
	query.collide_with_areas = false
	query.margin = 0
	ray.collision_mask = 1
	ray.collide_with_areas = false
	ray.hit_from_inside = true
	amount = 0
	blocked = false
	clear = true

func fits(space: PhysicsDirectSpaceState3D, at: Transform3D, anchor: Vector3) -> bool:
	query.transform = Transform3D(at.basis, at * center)
	queries += 1
	if not space.intersect_shape(query, 1).is_empty(): return false
	# A short weapon can end up wholly beyond a thin door. Keep its hull
	# connected to the owner's side as well as checking final overlap.
	ray.from = anchor
	ray.to = query.transform.origin
	queries += 1
	return space.intersect_ray(ray).is_empty()

func between(desired: Transform3D, safe: Transform3D, weight: float) -> Transform3D:
	if weight == 0: return desired
	if weight == 1: return safe
	# Imported bind matrices carry tiny scale drift. Extract rotations before
	# slerp; Basis.slerp requires stricter normalization than those assets have.
	var basis := Basis(desired.basis.get_rotation_quaternion().slerp(safe.basis.get_rotation_quaternion(), weight))
	# Rotate about the gun's centre, not the distant skeleton/scene origin.
	return Transform3D(basis, (desired * center).lerp(safe * center, weight) - basis * center)

func resolve(space: PhysicsDirectSpaceState3D, desired: Transform3D, safe: Transform3D,
		anchor: Vector3, dt: float) -> Transform3D:
	queries = 0
	# Withdraw immediately enough to be safe, recover gradually. A smoothed
	# transform must itself pass the test: lerping after collision resolution
	# otherwise lets the weapon pass through a wall during quick turns.
	var trial := maxf(0, amount - maxf(dt, 0) * 2.8)
	var candidate := between(desired, safe, trial)
	clear = fits(space, candidate, anchor)
	if not clear:
		var low := trial
		var high := 1.0
		candidate = safe
		clear = fits(space, safe, anchor)
		# At oblique walls the padded hand hull is slightly wider than the
		# capsule; slopes can also rise under its lower corner. Resolve those
		# small low-ready contacts using the real contact plane, not a guessed
		# fixed rearward offset (which is wrong when backing into a wall).
		if not clear:
			for attempt in 4:
				queries += 1
				var contact := space.get_rest_info(query)
				if contact.is_empty(): break
				var normal: Vector3 = contact.normal
				if normal.dot(anchor - contact.point) < 0: normal = -normal
				var half := shape.size * 0.5
				var radius := absf(normal.dot(safe.basis.x)) * half.x + absf(normal.dot(safe.basis.y)) * half.y + absf(normal.dot(safe.basis.z)) * half.z
				var depth := radius - normal.dot(safe * center - contact.point)
				safe.origin += normal * maxf(depth + 0.002, 0.002)
				clear = fits(space, safe, anchor)
				if clear: break
			candidate = safe
		if clear:
			for step in SEARCH_STEPS:
				var middle := (low + high) * 0.5
				var test := between(desired, safe, middle)
				if fits(space, test, anchor):
					high = middle
					candidate = test
				else:
					low = middle
		trial = high
	amount = trial
	blocked = amount > 0.001 or not clear
	return candidate

static func scene_bounds(root: Node3D) -> AABB:
	var result := AABB()
	var first := true
	var inverse := root.global_transform.affine_inverse()
	for node: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		var box: AABB = (inverse * node.global_transform) * node.mesh.get_aabb()
		result = box if first else result.merge(box)
		first = false
	return result

static func skinned_bounds(root: Node3D, skeleton: Skeleton3D, bone: int) -> AABB:
	var result := AABB()
	var first := true
	for node: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if node.skin == null: continue
		for surface in node.mesh.get_surface_count():
			var arrays := node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			for vertex in vertices.size():
				for influence in 4:
					if weights[vertex * 4 + influence] <= 0: continue
					var bind := joints[vertex * 4 + influence]
					var bound_bone := node.skin.get_bind_bone(bind)
					if not node.skin.get_bind_name(bind).is_empty():
						bound_bone = skeleton.find_bone(node.skin.get_bind_name(bind))
					if bound_bone != bone: continue
					var point := skeleton.get_bone_global_rest(bone) * node.skin.get_bind_pose(bind) * vertices[vertex]
					result = AABB(point, Vector3.ZERO) if first else result.expand(point)
					first = false
	return result
