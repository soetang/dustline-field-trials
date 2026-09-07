extends RefCounted

## TEST ONLY. Call apply(model) after Models.prepare(); an existing rig/flash
## is retained, so a test fixture can opt in after the operator is instantiated.
## Never mutates the imported mesh/materials, skin, skeleton or node transform.
## Only immutable load-time geometry is supported; source.changed drops cache.
const SHADER = preload("res://engine/experiments/operator_surface.gdshader")
# Godot 4.7.2's ARRAY_FLAG_FORMAT_VERSION_2 in rendering_server_enums.h.
const PACKED_FORMAT_VERSION := 1 << 35
static var cache: Dictionary = {}
static var defaults: StandardMaterial3D
static var shared_material: ShaderMaterial
static var last_error := ""

static func reject(reason: String) -> ArrayMesh:
	last_error = reason
	return null

static func material_supported(value: Material) -> bool:
	if not value is StandardMaterial3D or value.get_script() != null: return false
	if defaults == null:
		defaults = StandardMaterial3D.new()
		defaults.vertex_color_use_as_albedo = true
		defaults.vertex_color_is_srgb = false
	# Compare every stored property, including newly introduced engine features.
	# No texture, alpha, extra pass, vertex displacement or lighting exceptions.
	for property in value.get_property_list():
		if not (property.usage & PROPERTY_USAGE_STORAGE): continue
		if property.name in ["resource_name", "resource_local_to_scene", "roughness", "metallic"]: continue
		if value.get(property.name) != defaults.get(property.name): return false
	return is_finite(value.roughness) and value.roughness >= 0 and value.roughness <= 1 \
		and is_finite(value.metallic) and value.metallic >= 0 and value.metallic <= 1

static func material() -> ShaderMaterial:
	if shared_material == null:
		shared_material = ShaderMaterial.new()
		shared_material.shader = SHADER
	return shared_material

static func invalidate(source_id: int) -> void:
	# An ID binding cannot leave source -> signal -> source reference cycles.
	var source := instance_from_id(source_id)
	if source != null: cache.erase(source)

static func valid_indices(indices: PackedInt32Array, count: int) -> bool:
	if indices.is_empty() or indices.size() % 3: return false
	for index in indices:
		if index < 0 or index >= count: return false
	return true

static func shifted(indices: PackedInt32Array, offset: int) -> PackedInt32Array:
	var result := indices.duplicate()
	for i in result.size(): result[i] += offset
	return result

static func read_lods(data: Dictionary) -> Dictionary:
	# Public surface metadata preserves the importer's exact float thresholds
	# and index order. This mirrors the pinned server's 16/32-bit index decoding.
	var result: Dictionary = {}
	var stride := 2 if int(data.vertex_count) <= 65536 else 4
	var previous := 0.0
	for lod in data.get("lods", []):
		var edge := float(lod.edge_length)
		var bytes: PackedByteArray = lod.index_data
		if not is_finite(edge) or edge <= previous or bytes.size() % stride:
			return {"invalid": true}
		var indices := PackedInt32Array()
		indices.resize(bytes.size() / stride)
		for i in indices.size():
			indices[i] = bytes.decode_u16(i * stride) if stride == 2 else bytes.decode_u32(i * stride)
		if not valid_indices(indices, data.vertex_count): return {"invalid": true}
		result[edge] = indices
		previous = edge
	return result

static func merge(source: ArrayMesh, materials: Array[Material]) -> ArrayMesh:
	last_error = ""
	var version := Engine.get_version_info()
	if version.major != 4 or version.minor != 7 or version.patch != 2:
		return reject("Packed layout and LOD semantics are verified only for Godot 4.7.2")
	if source == null or source.get_surface_count() < 2 or materials.size() != source.get_surface_count():
		return reject("Expected multiple material surfaces")
	if source.get_blend_shape_count() or source.shadow_mesh != null or source.get_script() != null:
		return reject("Blend shapes, custom shadow mesh or scripted mesh require a separate implementation")
	var parameters: Array[Vector2] = []
	for value in materials:
		if not material_supported(value): return reject("Unsupported material properties")
		parameters.append(Vector2(value.roughness, value.metallic))
	if cache.has(source) and cache[source].parameters == parameters:
		return cache[source].mesh

	var combined: Array = []
	combined.resize(Mesh.ARRAY_MAX)
	var offsets: Array[int] = []
	var originals: Array[Array] = []
	var levels: Array[Dictionary] = []
	var edges: Array[float] = []
	var vertex_count := 0
	var tangents := false
	var raw_positions := PackedByteArray()
	var raw_normals := PackedByteArray()
	var raw_skin := PackedByteArray()
	var bone_bounds: Array[AABB] = []
	for surface in source.get_surface_count():
		if source.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			return reject("Only indexed triangles are supported")
		var format := source.surface_get_format(surface)
		var expected_format := PACKED_FORMAT_VERSION | Mesh.ARRAY_FORMAT_VERTEX | Mesh.ARRAY_FORMAT_NORMAL \
			| Mesh.ARRAY_FORMAT_COLOR | Mesh.ARRAY_FORMAT_BONES | Mesh.ARRAY_FORMAT_WEIGHTS | Mesh.ARRAY_FORMAT_INDEX
		if (format & ~Mesh.ARRAY_FORMAT_TANGENT) != expected_format:
			return reject("Only the pinned uncompressed, four-influence vertex layout is supported")
		var arrays := source.surface_get_arrays(surface)
		var count: int = arrays[Mesh.ARRAY_VERTEX].size()
		if count == 0: return reject("Empty vertex array")
		for slot in [Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]:
			if arrays[slot] != null and not arrays[slot].is_empty(): return reject("UV/custom channels must be unused")
		for slot in [Mesh.ARRAY_NORMAL, Mesh.ARRAY_COLOR, Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS]:
			var size := count * (4 if slot in [Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS] else 1)
			if arrays[slot] == null or arrays[slot].size() != size: return reject("Incomplete vertex/skin attributes")
		var has_tangents: bool = arrays[Mesh.ARRAY_TANGENT] != null and not arrays[Mesh.ARRAY_TANGENT].is_empty()
		if surface == 0: tangents = has_tangents
		if has_tangents != tangents or (has_tangents and arrays[Mesh.ARRAY_TANGENT].size() != count * 4):
			return reject("Inconsistent tangent layout")
		if arrays[Mesh.ARRAY_INDEX] == null or not valid_indices(arrays[Mesh.ARRAY_INDEX], count):
			return reject("Invalid triangle indices")
		var data := RenderingServer.mesh_get_surface(source.get_rid(), surface)
		var split := RenderingServer.mesh_surface_get_format_offset(format, count, Mesh.ARRAY_NORMAL)
		var bytes: PackedByteArray = data.vertex_data
		if split != count * 12 or bytes.size() != split + count * (8 if tangents else 4) or data.skin_data.size() != count * 16:
			return reject("Unexpected source vertex/skin packing")
		# Imported normals/tangents are octahedrally packed even when positions
		# are uncompressed. Decode/re-encode is lossy: retain their exact bytes.
		raw_positions.append_array(bytes.slice(0, split))
		raw_normals.append_array(bytes.slice(split))
		raw_skin.append_array(data.skin_data)
		for bone in data.bone_aabbs.size():
			var bounds: AABB = data.bone_aabbs[bone]
			if bone >= bone_bounds.size(): bone_bounds.append(bounds)
			elif bounds.size.x >= 0:
				bone_bounds[bone] = bounds if bone_bounds[bone].size.x < 0 else bone_bounds[bone].merge(bounds)
		var lods := read_lods(data)
		if lods.has("invalid"): return reject("Invalid imported LOD data")
		for edge: float in lods:
			if not edges.has(edge): edges.append(edge)
		levels.append(lods)
		offsets.append(vertex_count)
		originals.append(arrays)
		for slot in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR, Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS]:
			if arrays[slot] == null: continue
			if combined[slot] == null: combined[slot] = arrays[slot].duplicate()
			else: combined[slot].append_array(arrays[slot])
		var uv := PackedVector2Array()
		uv.resize(count)
		uv.fill(parameters[surface])
		if combined[Mesh.ARRAY_TEX_UV] == null: combined[Mesh.ARRAY_TEX_UV] = uv
		else: combined[Mesh.ARRAY_TEX_UV].append_array(uv)
		var indices := shifted(arrays[Mesh.ARRAY_INDEX], vertex_count)
		if combined[Mesh.ARRAY_INDEX] == null: combined[Mesh.ARRAY_INDEX] = indices
		else: combined[Mesh.ARRAY_INDEX].append_array(indices)
		vertex_count += count

	# GLES3 uses one instance distance/model scale for all surfaces. At every
	# union threshold retain each source's latest eligible LOD (or base indices).
	# Thus distant silhouettes stay unchanged; no LOD is discarded/regenerated.
	edges.sort()
	var merged_lods: Dictionary = {}
	for edge in edges:
		var indices := PackedInt32Array()
		for surface in originals.size():
			var selected: PackedInt32Array = originals[surface][Mesh.ARRAY_INDEX]
			for source_edge: float in levels[surface]:
				if source_edge > edge: break
				selected = levels[surface][source_edge]
			indices.append_array(shifted(selected, offsets[surface]))
		merged_lods[edge] = indices
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, combined, [], merged_lods)
	if result.get_surface_count() != 1: return reject("Mesh creation failed")
	# Pinned Godot 4.7.2 ArrayMesh storage: reuse exact packed vertex/skin data
	# and imported bounds. Public array creation supplies the new UV/index/LOD
	# packing; do not round-trip normals or regenerate conservative bone bounds.
	var packed: Array = result.get("_surfaces")
	raw_positions.append_array(raw_normals)
	if packed[0].vertex_data.size() != raw_positions.size() or packed[0].skin_data.size() != raw_skin.size():
		return reject("Unexpected packed vertex/skin layout")
	packed[0].vertex_data = raw_positions
	packed[0].skin_data = raw_skin
	packed[0].aabb = source.get_aabb()
	packed[0].bone_aabbs = bone_bounds
	result.set("_surfaces", packed)
	result.custom_aabb = source.custom_aabb
	result.surface_set_material(0, material())
	cache[source] = {"parameters": parameters, "mesh": result}
	var changed := invalidate.bind(source.get_instance_id())
	if not source.changed.is_connected(changed): source.changed.connect(changed)
	return result

static func apply(model: Node3D) -> bool:
	last_error = ""
	var meshes: Array[MeshInstance3D] = []
	for child: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if child.skin != null: meshes.append(child)
	if meshes.size() != 1:
		last_error = "Expected exactly one skinned operator mesh"
		return false
	var node: MeshInstance3D = meshes[0]
	if not node.mesh is ArrayMesh or node.skin == null or node.material_override != null or node.material_overlay != null:
		last_error = "Expected a skinned ArrayMesh without whole-instance material overrides"
		return false
	var materials: Array[Material] = []
	for surface in node.mesh.get_surface_count(): materials.append(node.get_active_material(surface))
	var result := merge(node.mesh, materials)
	if result == null: return false
	# Only commit after every check and complete construction has succeeded.
	for surface in node.mesh.get_surface_count(): node.set_surface_override_material(surface, null)
	node.mesh = result
	return true
