extends RefCounted

## Independent CPU skinning of the actual indexed mesh, never collision hulls or
## procedural rig.pose. Caller supplies completed Skeleton modifier snapshots.
## Plane distances are discrete samples, not continuous triangle/edge CCD.

static func capture(rig: RefCounted) -> Dictionary:
	var result := {"surfaces": [], "counts": [0, 0], "weight_error": 0.0, "errors": []}
	if rig == null or not is_instance_valid(rig.skeleton) or not is_instance_valid(rig.model):
		result.errors.append("missing rig/skeleton/model")
		return result
	for node: MeshInstance3D in rig.model.find_children("*", "MeshInstance3D", true, false):
		if node.skin == null or node.mesh == null:
			# The rig also owns an unskinned muzzle-flash mesh, not body/rifle.
			continue
		var binds: Array = []
		for index in node.skin.get_bind_count():
			var name := node.skin.get_bind_name(index)
			var bone: int = rig.skeleton.find_bone(name) if not name.is_empty() else node.skin.get_bind_bone(index)
			if bone < 0 or bone >= rig.skeleton.get_bone_count():
				result.errors.append("unresolved Skin binding")
			binds.append({"bone": bone, "pose": node.skin.get_bind_pose(index)})
		for surface in node.mesh.get_surface_count():
			var arrays := node.mesh.surface_get_arrays(surface)
			if arrays.size() != Mesh.ARRAY_MAX or arrays[Mesh.ARRAY_INDEX] == null or arrays[Mesh.ARRAY_INDEX].is_empty():
				result.errors.append("expected indexed geometry")
				continue
			if arrays[Mesh.ARRAY_VERTEX] == null or arrays[Mesh.ARRAY_WEIGHTS] == null or arrays[Mesh.ARRAY_BONES] == null:
				result.errors.append("missing skin arrays")
				continue
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			if weights.size() != vertices.size() * 4 or joints.size() != weights.size():
				result.errors.append("expected four influences per vertex")
				continue
			var used := {}
			var sampled: Array = []
			for index: int in arrays[Mesh.ARRAY_INDEX]:
				if used.has(index): continue
				used[index] = true
				if index < 0 or index >= vertices.size() or not vertices[index].is_finite():
					result.errors.append("invalid indexed vertex")
					continue
				var influences: Array = []
				var weapon := false
				var total := 0.0
				var greatest := -1.0
				var label := ""
				for influence in 4:
					var weight := weights[index * 4 + influence]
					var bind_index := joints[index * 4 + influence]
					if not is_finite(weight) or weight < 0 or bind_index < 0 or bind_index >= binds.size():
						result.errors.append("invalid skin influence")
						continue
					total += weight
					if weight == 0: continue
					var bind: Dictionary = binds[bind_index]
					if bind.bone < 0 or bind.bone >= rig.skeleton.get_bone_count(): continue
					influences.append({"bone": bind.bone, "point": bind.pose * vertices[index], "weight": weight})
					weapon = weapon or bind.bone == rig.ids.weapon
					if weight > greatest:
						greatest = weight
						label = rig.skeleton.get_bone_name(bind.bone)
				result.weight_error = maxf(result.weight_error, absf(total - 1.0))
				if influences.is_empty(): result.errors.append("vertex has no positive valid skin influence")
				var group := 1 if weapon else 0
				result.counts[group] += 1
				sampled.append({"influences": influences, "group": group, "bone": label})
			result.surfaces.append({"node": node, "vertices": sampled})
	return result

static func points(data: Dictionary, global_poses: Array) -> Array:
	var result: Array = []
	for surface in data.surfaces:
		var world: Transform3D = surface.node.global_transform
		for vertex in surface.vertices:
			var point := Vector3.ZERO
			for influence in vertex.influences:
				point += (global_poses[influence.bone] * influence.point) * influence.weight
			result.append({"point": world * point, "group": vertex.group, "bone": vertex.bone})
	return result

static func clearance(vertices: Array, planes: Array) -> Dictionary:
	var result := {"minimum": [INF, INF], "bone": ["", ""], "plane": ["", ""], "finite": true}
	for vertex in vertices:
		if not vertex.point.is_finite(): result.finite = false
		for plane in planes:
			var distance: float = plane.normal.dot(vertex.point - plane.point)
			if distance < result.minimum[vertex.group]:
				result.minimum[vertex.group] = distance
				result.bone[vertex.group] = vertex.bone
				result.plane[vertex.group] = plane.name
	result.finite = result.finite and is_finite(result.minimum[0]) and is_finite(result.minimum[1])
	return result

static func poses(rig: RefCounted) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	for bone in rig.skeleton.get_bone_count(): result.append(rig.skeleton.get_bone_global_pose(bone))
	return result

static func max_delta(before: Array, after: Array) -> float:
	if before.size() != after.size(): return INF
	var result := 0.0
	for index in before.size():
		if not before[index].point.is_finite() or not after[index].point.is_finite(): return INF
		result = maxf(result, before[index].point.distance_to(after[index].point))
	return result
