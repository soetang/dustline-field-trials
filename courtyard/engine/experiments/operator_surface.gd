extends RefCounted

## TEST ONLY. Call apply(model) after Models.prepare(); an existing rig/flash
## is retained, so a test fixture can opt in after the operator is instantiated.
## Never mutates the imported mesh/materials, skin, skeleton or node transform.
## Only immutable load-time inputs are supported; mesh/skin.changed drops cache.
## Each source surface retains separate bone boxes via aliased Skin bindings.
## This avoids union-before-rotation expansion, not arbitrary float-roundoff
## differences in grouped AABB merges or LOD decisions exactly on a threshold.
const SHADER = preload("res://engine/experiments/operator_surface.gdshader")
# Godot 4.7.2's ARRAY_FLAG_FORMAT_VERSION_2 in rendering_server_enums.h.
const PACKED_FORMAT_VERSION := 1 << 35
static var cache: Dictionary = {}
static var defaults: StandardMaterial3D
static var shared_material: ShaderMaterial
static var last_error := ""

static func reject(reason: String) -> Dictionary:
	last_error = reason
	return {}

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

static func invalidate_skin(source_id: int) -> void:
	var source := instance_from_id(source_id)
	if source == null: return
	for mesh in cache.keys():
		cache[mesh].erase(source)
		if cache[mesh].is_empty(): cache.erase(mesh)

static func skin_supported(skin: Skin) -> bool:
	if skin == null or skin.get_script() != null or skin.get_bind_count() == 0: return false
	for bind in skin.get_bind_count():
		if skin.get_bind_name(bind).is_empty() and skin.get_bind_bone(bind) < 0: return false
		var pose := skin.get_bind_pose(bind)
		if not pose.is_finite() or is_zero_approx(pose.basis.determinant()): return false
	return true

static func valid_bounds(bounds: AABB) -> bool:
	return bounds.position.is_finite() and bounds.size.is_finite() \
		and (bounds.size == Vector3(-1, -1, -1) or (bounds.size.x >= 0 and bounds.size.y >= 0 and bounds.size.z >= 0))

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

static func merge(source: ArrayMesh, source_skin: Skin, materials: Array[Material]) -> Dictionary:
	last_error = ""
	var version := Engine.get_version_info()
	if version.major != 4 or version.minor != 7 or version.patch != 2:
		return reject("Packed layout and LOD semantics are verified only for Godot 4.7.2")
	if source == null or source.get_surface_count() < 2 or materials.size() != source.get_surface_count():
		return reject("Expected multiple material surfaces")
	if source.get_blend_shape_count() or source.shadow_mesh != null or source.get_script() != null:
		return reject("Blend shapes, custom shadow mesh or scripted mesh require a separate implementation")
	if not skin_supported(source_skin): return reject("Invalid source Skin bindings or poses")
	var bind_count := source_skin.get_bind_count()
	if bind_count * source.get_surface_count() > 65536:
		return reject("Aliased bindings exceed the pinned uint16 joint layout")
	var parameters: Array[Vector2] = []
	for value in materials:
		if not material_supported(value): return reject("Unsupported material properties")
		parameters.append(Vector2(value.roughness, value.metallic))
	if cache.has(source) and cache[source].has(source_skin) and cache[source][source_skin].parameters == parameters:
		return cache[source][source_skin].pair

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
		var skin_bytes: PackedByteArray = data.skin_data.duplicate()
		var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES].duplicate()
		var source_bounds: Array = data.get("bone_aabbs", [])
		if source_bounds.is_empty() or source_bounds.size() > bind_count:
			return reject("Missing or oversized source bone bounds")
		var used_bounds := false
		for bounds: AABB in source_bounds:
			if not valid_bounds(bounds): return reject("Malformed source bone bounds")
			used_bounds = used_bounds or (bounds.size.x > 0 and bounds.size.y > 0 and bounds.size.z > 0)
		if not used_bounds: return reject("Unbounded skin requires per-surface fallback bounds")
		for vertex in count:
			for influence in 4:
				var offset := vertex * 16 + influence * 2
				var bind := skin_bytes.decode_u16(offset)
				# Check even zero-weight influences: the vertex shader fetches all four.
				if bind >= bind_count or bind != joints[vertex * 4 + influence]:
					return reject("Vertex references an invalid source Skin binding")
				if skin_bytes.decode_u16(offset + 8) > 0 and (bind >= source_bounds.size() or source_bounds[bind].size == Vector3(-1, -1, -1)):
					return reject("Weighted joint is missing its source bone bounds")
				var aliased := bind + surface * bind_count
				skin_bytes.encode_u16(offset, aliased)
				joints[vertex * 4 + influence] = aliased
		raw_skin.append_array(skin_bytes) # The eight weight bytes are never rewritten.
		arrays[Mesh.ARRAY_BONES] = joints
		for bind in bind_count:
			bone_bounds.append(source_bounds[bind] if bind < source_bounds.size() else AABB(Vector3.ZERO, Vector3(-1, -1, -1)))
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
	# No LOD is discarded/regenerated. Selection matches at an EQUAL input
	# distance/scale; this alone does not prove animated-bound distances match.
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
	var skin := Skin.new()
	skin.set_bind_count(bind_count * source.get_surface_count())
	for surface in source.get_surface_count():
		for bind in bind_count:
			var alias := surface * bind_count + bind
			skin.set_bind_bone(alias, source_skin.get_bind_bone(bind))
			skin.set_bind_name(alias, source_skin.get_bind_name(bind))
			skin.set_bind_pose(alias, source_skin.get_bind_pose(bind))
	# Retain only resources, never SkinReferences (which would keep old palettes
	# registered on individual skeletons after replacing their instance Skin).
	var pair := {"mesh": result, "skin": skin}
	if not cache.has(source): cache[source] = {}
	cache[source][source_skin] = {"parameters": parameters, "pair": pair}
	var changed := invalidate.bind(source.get_instance_id())
	if not source.changed.is_connected(changed): source.changed.connect(changed)
	var skin_changed := invalidate_skin.bind(source_skin.get_instance_id())
	if not source_skin.changed.is_connected(skin_changed): source_skin.changed.connect(skin_changed)
	return pair

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
	if not node.is_inside_tree():
		last_error = "Operator must be in the scene tree"
		return false
	var skeleton := node.get_node_or_null(node.skeleton) as Skeleton3D
	if skeleton == null or not skin_supported(node.skin):
		last_error = "Missing skeleton or invalid Skin"
		return false
	# Actual imported operators are identity children of their Skeleton3D.
	# Check the local relationship: inverse(world) * world introduces rounding
	# for perfectly valid rotated/scaled actor ancestors. Pinned 3D ArrayMesh
	# import also leaves the surface mesh_to_skeleton_xform at identity.
	if node.get_parent() != skeleton or node.transform != Transform3D.IDENTITY or node.top_level or node.is_scale_disabled():
		last_error = "Nonidentity mesh-to-skeleton transform is unsupported"
		return false
	for bind in node.skin.get_bind_count():
		var name := node.skin.get_bind_name(bind)
		var bone := skeleton.find_bone(name) if not name.is_empty() else node.skin.get_bind_bone(bind)
		if bone < 0 or bone >= skeleton.get_bone_count():
			last_error = "Skin binding cannot resolve to this Skeleton3D"
			return false
	var materials: Array[Material] = []
	for surface in node.mesh.get_surface_count(): materials.append(node.get_active_material(surface))
	var result := merge(node.mesh, node.skin, materials)
	if result.is_empty(): return false
	# Only commit after every check and complete construction has succeeded.
	for surface in node.mesh.get_surface_count(): node.set_surface_override_material(surface, null)
	node.skin = result.skin
	node.mesh = result.mesh
	return true
