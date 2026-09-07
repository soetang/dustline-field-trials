extends RefCounted

# Explicit, reversible experiment: call apply() only after static world batching.
# There are no production hooks. Keep this instance alive until restore(). Static
# geometry/material parameters must remain unchanged during the comparison.
const SOURCE = preload("res://shaders/surface.gdshader")
const CANDIDATE = preload("res://engine/experiments/flat_surface.gdshader")
const SOURCE_SHA256 := "5e0181f07b1b408fcecc91d36b6cd91216d4200ac75792628860c2196c933a3b"
const WALL_DIFF = preload("res://assets/textures/concrete_wall_001_diff_1k.jpg")
const WALL_NORMAL = preload("res://assets/textures/concrete_wall_001_nor_gl_1k.jpg")
const WALL_ARM = preload("res://assets/textures/concrete_wall_001_arm_1k.jpg")
const UNIFORMS := [&"tint", &"diffuse_map", &"normal_map", &"arm_map", &"texture_scale", &"normal_strength"]
const AXES := [Vector3.RIGHT, Vector3.UP, Vector3.BACK]
var _materials: Dictionary = {}
var _assignments: Array[Dictionary] = []

static func transform_supported(value: Transform3D) -> bool:
	# Conservative prototype envelope, not an assertion that all other flat faces
	# are unsafe. Exclude shear, mirrors, singular/extreme scales and branch seams.
	if not value.is_finite(): return false
	if value.origin.abs()[value.origin.abs().max_axis_index()] > 100000.0: return false
	var basis := value.basis
	if basis.determinant() <= 0.0: return false
	var lengths := Vector3(basis.x.length(), basis.y.length(), basis.z.length())
	var low := lengths[lengths.min_axis_index()]
	var high := lengths[lengths.max_axis_index()]
	if low < 0.0001 or high > 10000.0 or high / low > 128.0: return false
	var x := basis.x / lengths.x
	var y := basis.y / lengths.y
	var z := basis.z / lengths.z
	if absf(x.dot(y)) > 0.00001 or absf(x.dot(z)) > 0.00001 or absf(y.dot(z)) > 0.00001: return false
	var normal_matrix := basis.inverse().transposed()
	for axis: Vector3 in AXES:
		var normal := (normal_matrix * axis).normalized()
		# Leave room for packed-normal and floating-point differences: at a
		# projection branch boundary even a tiny change can rotate the texture.
		if absf(absf(normal.y) - 0.6) < 0.02: return false
		if absf(normal.y) <= 0.6 and absf(absf(normal.z) - absf(normal.x)) < 0.02: return false
	return true

static func material_supported(material: Material) -> bool:
	if not material is ShaderMaterial or material.get_script() != null: return false
	if material.shader != SOURCE or material.next_pass != null: return false
	# Eligibility follows the concrete wall textures, not the object's purpose.
	# The large fallback floor uses these textures and qualifies as a flat box;
	# FLOOR_DIFF terrain and boxes retain their original shader.
	if material.get_shader_parameter("diffuse_map") != WALL_DIFF: return false
	if material.get_shader_parameter("normal_map") != WALL_NORMAL: return false
	if material.get_shader_parameter("arm_map") != WALL_ARM: return false
	for name: StringName in [&"texture_scale", &"normal_strength"]:
		var value: Variant = material.get_shader_parameter(name)
		if value != null and (not value is float or not is_finite(value)): return false
	return true

func _reason(instance: GeometryInstance3D) -> String:
	if not instance.is_inside_tree() or instance.is_queued_for_deletion() or instance.get_script() != null: return "instance"
	if instance.material_overlay != null or not material_supported(instance.material_override): return "material"
	var mesh: Mesh
	var multi: MultiMesh
	if instance is MeshInstance3D:
		if instance.skin != null: return "mesh"
		mesh = instance.mesh
	elif instance is MultiMeshInstance3D:
		multi = instance.multimesh
		if multi == null or multi.get_script() != null or multi.transform_format != MultiMesh.TRANSFORM_3D or multi.instance_count == 0: return "mesh"
		mesh = multi.mesh
	else:
		return "mesh"
	if not mesh is BoxMesh or mesh.get_script() != null: return "mesh"
	if not mesh.size.is_finite() or mesh.size.x <= 0.0 or mesh.size.y <= 0.0 or mesh.size.z <= 0.0: return "mesh"
	if not transform_supported(instance.global_transform): return "transform"
	if multi != null:
		for index in multi.instance_count:
			if not transform_supported(instance.global_transform * multi.get_instance_transform(index)): return "transform"
	return ""

func apply(root: Node3D) -> Dictionary:
	var result := {"changed": 0, "materials": 0, "boxes": 0, "multimeshes": 0, "instances": 0, "skipped": {}, "error": ""}
	if not _assignments.is_empty():
		result.error = "already_applied"
		return result
	if not is_instance_valid(root) or not root.is_inside_tree():
		result.error = "invalid_root"
		return result
	# Use the runtime getter: GDScript may fold properties of a const Resource.
	if SOURCE.get_code().sha256_text() != SOURCE_SHA256:
		result.error = "source_drift"
		return result
	var nodes: Array[Node] = root.find_children("*", "GeometryInstance3D", true, false)
	if root is GeometryInstance3D: nodes.push_front(root)
	for node in nodes:
		var instance := node as GeometryInstance3D
		var reason := _reason(instance)
		if not reason.is_empty():
			result.skipped[reason] = int(result.skipped.get(reason, 0)) + 1
			continue
		var original := instance.material_override as ShaderMaterial
		if not _materials.has(original):
			var candidate := original.duplicate(false) as ShaderMaterial
			candidate.shader = CANDIDATE
			for name: StringName in UNIFORMS:
				candidate.set_shader_parameter(name, original.get_shader_parameter(name))
			_materials[original] = candidate
		var replacement: ShaderMaterial = _materials[original]
		_assignments.append({"node": weakref(instance), "original": original, "replacement": replacement})
		instance.material_override = replacement
		result.changed += 1
		if instance is MultiMeshInstance3D:
			result.multimeshes += 1
			result.instances += instance.multimesh.instance_count
		else:
			result.boxes += 1
			result.instances += 1
	result.materials = _materials.size()
	return result

func restore() -> int:
	var restored := 0
	for entry in _assignments:
		var instance: GeometryInstance3D = entry.node.get_ref()
		if is_instance_valid(instance) and instance.material_override == entry.replacement:
			instance.material_override = entry.original
			restored += 1
	_assignments.clear()
	_materials.clear()
	return restored
