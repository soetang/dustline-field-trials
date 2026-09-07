extends SceneTree

const Models = preload("res://scripts/models.gd")
const Rig = preload("res://scripts/operator_rig.gd")
const Merge = preload("res://engine/experiments/operator_surface.gd")
var passed := 0
var failed := 0

func check(ok: bool, label: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func _initialize() -> void:
	call_deferred("run")

func active_materials(node: MeshInstance3D) -> Array[Material]:
	var result: Array[Material] = []
	for surface in node.mesh.get_surface_count(): result.append(node.get_active_material(surface))
	return result

func snapshot(source: ArrayMesh) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for surface in source.get_surface_count(): result.append(RenderingServer.mesh_get_surface(source.get_rid(), surface))
	return result

func skin_snapshot(skin: Skin) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for bind in skin.get_bind_count():
		result.append({"bone": skin.get_bind_bone(bind), "name": skin.get_bind_name(bind), "pose": skin.get_bind_pose(bind)})
	return result

func skin_transforms(skeleton: Skeleton3D, skin: Skin) -> Array[Transform3D]:
	# Actual Skeleton3D upload formula from pinned skeleton_3d.cpp. Headless
	# dummy RenderingServer returns identity matrices, so never use its palette
	# readback as evidence of equal animation/skinning.
	var result: Array[Transform3D] = []
	for bind in skin.get_bind_count():
		var name := skin.get_bind_name(bind)
		var bone := skeleton.find_bone(name) if not name.is_empty() else skin.get_bind_bone(bind)
		result.append(skeleton.get_bone_global_pose(bone) * skin.get_bind_pose(bind))
	return result

func buffer_bytes(surfaces: Array[Dictionary]) -> int:
	var size := 0
	for surface in surfaces:
		for key in ["vertex_data", "attribute_data", "skin_data", "index_data"]:
			size += surface.get(key, PackedByteArray()).size()
		for lod in surface.get("lods", []): size += lod.index_data.size()
	return size

func indices_at(data: Dictionary, distance: float, model_scale := 1.0, screen_threshold := 1.0) -> PackedInt32Array:
	# Independent transcription of pinned GLES3 MeshStorage::mesh_surface_get_lod:
	# strict `>` comparison and renderer float32 arithmetic at every operation.
	var bytes: PackedByteArray = data.index_data
	for lod in data.get("lods", []):
		var scaled := PackedFloat32Array([float(lod.edge_length) * model_scale])[0]
		var screen_size := PackedFloat32Array([scaled / distance])[0]
		if screen_size > screen_threshold: break
		bytes = lod.index_data
	var stride := 2 if int(data.vertex_count) <= 65536 else 4
	var result := PackedInt32Array()
	for i in range(0, bytes.size(), stride):
		result.append(bytes.decode_u16(i) if stride == 2 else bytes.decode_u32(i))
	return result

func posed_bounds(surfaces: Array[Dictionary], transforms: Array[Transform3D]) -> AABB:
	# Pinned GLES3 MeshStorage::mesh_get_aabb transforms each surface's bone
	# boxes BEFORE unioning them. Include both identity coordinate transforms
	# (they still round AABB end/size) and its zero-size fallback. The supported
	# operators have identity mesh->skeleton, not arbitrary transformed meshes.
	var result := AABB()
	var first := true
	for surface in surfaces:
		var local := AABB()
		var local_first := true
		for bind in surface.bone_aabbs.size():
			var bounds: AABB = surface.bone_aabbs[bind]
			if bounds.size == Vector3(-1, -1, -1): continue
			var posed: AABB = transforms[bind] * (Transform3D.IDENTITY * bounds)
			local = posed if local_first else local.merge(posed)
			local_first = false
		if not local_first: local = Transform3D.IDENTITY.affine_inverse() * local
		if local.size == Vector3.ZERO: local = surface.aabb
		result = local if first else result.merge(local)
		first = false
	return result

func box_distance(box: AABB, camera: Vector3) -> float:
	# rasterizer_scene_gles3.cpp's perspective distance to transformed_aabb.
	return Vector3.ZERO.max(box.position - camera).max(camera - box.end).length()

func lod_levels(surfaces: Array[Dictionary], distance: float) -> PackedInt32Array:
	var levels := PackedInt32Array()
	var threshold := PackedFloat32Array([0.01])[0]
	for surface in surfaces:
		var level := 0
		for lod in surface.get("lods", []):
			if PackedFloat32Array([float(lod.edge_length) / distance])[0] > threshold: break
			level += 1
		levels.append(level)
	return levels

func inspect_animated_bounds(team: String, source: ArrayMesh, original_skin: Skin, pair: Dictionary, rig: FieldOperatorRig) -> void:
	var originals := snapshot(source)
	var merged := snapshot(pair.mesh)
	var node: MeshInstance3D = rig.model.find_children("*", "MeshInstance3D", true, false)[0]
	check((rig.skeleton.global_transform.affine_inverse() * node.global_transform).is_equal_approx(Transform3D.IDENTITY), team + " bounds fixture uses identity mesh-to-skeleton transform")
	var conservative := true
	var different := 0
	var outside_tolerance := 0
	var exact_matrices := true
	var nonidentity_matrix := false
	var max_delta := 0.0
	var lod_probes := 0
	var boundary_lod_differences := 0
	var nearby_lod_differences := 0
	const EPSILON := 0.000002 # Allow float32 AABB merge/transform roundoff only.
	for mode in 4:
		for frame in 120:
			rig.update_pose(1.0 / 60, Vector3(0, 0, -2.1) if mode == 1 else Vector3.ZERO,
				Vector2(0.4, 0.5) if mode == 2 else Vector2(-0.3, -0.5) if mode == 3 else Vector2.ZERO,
				1.1 if mode == 3 else 0.0, false, false)
			var original_transforms := skin_transforms(rig.skeleton, original_skin)
			var merged_transforms := skin_transforms(rig.skeleton, node.get_skin_reference().get_skin())
			for bind in merged_transforms.size():
				exact_matrices = exact_matrices and merged_transforms[bind] == original_transforms[bind % original_skin.get_bind_count()]
				nonidentity_matrix = nonidentity_matrix or merged_transforms[bind] != Transform3D.IDENTITY
			var a := posed_bounds(originals, original_transforms)
			var b := posed_bounds(merged, merged_transforms)
			var delta := 0.0
			for axis in 3:
				conservative = conservative and b.position[axis] <= a.position[axis] + EPSILON and b.end[axis] >= a.end[axis] - EPSILON
				delta = maxf(delta, maxf(absf(a.position[axis] - b.position[axis]), absf(a.end[axis] - b.end[axis])))
			if delta > 0: different += 1
			if delta > EPSILON: outside_tolerance += 1
			max_delta = maxf(max_delta, delta)
			# Probe all six bound faces near each baseline threshold, at regular
			# poses AND every observed non-bit-exact pose. Equal-input geometry
			# tests below prove merged LOD indices represent these source levels.
			if delta > 0 or frame % 60 == 0:
				for lod in merged[0].get("lods", []):
					for axis in 3:
						for side: float in [-1.0, 1.0]:
							for margin: float in [-0.0001, 0.0, 0.0001]:
								var camera := a.get_center()
								camera[axis] = (a.end[axis] if side > 0 else a.position[axis]) + side * (float(lod.edge_length) / 0.01 + margin)
								if lod_levels(originals, box_distance(a, camera)) != lod_levels(originals, box_distance(b, camera)):
									if margin == 0: boundary_lod_differences += 1
									else: nearby_lod_differences += 1
								lod_probes += 1
	check(conservative, team + " merged animated bounds conservatively contain original bounds")
	check(outside_tolerance == 0, team + " all 480 actual-pose bounds equal within 2e-6 m")
	check(exact_matrices and nonidentity_matrix, team + " all 54 aliased matrices exactly retain real animated skinning")
	check(nearby_lod_differences == 0, team + " bounds-derived LOD selections match with 0.1 mm threshold clearance")
	# Separate boxes remove the old ~6 mm CT expansion, but grouped versus
	# flattened AABB merges can still differ by float32 roundoff. Neither these
	# sampled poses nor equal-input LOD tests prove arbitrary threshold equality.
	print("OPERATOR_SURFACE_BOUNDS ", team, " sampled_frames=480 non_bit_exact_frames=", different,
		" outside_2e_6_m=", outside_tolerance, " exact_skinning_matrices=", exact_matrices,
		" max_bound_delta_m=", max_delta, " conservative=", conservative,
		" bounds_lod_probes=", lod_probes, " threshold_lod_differences=", boundary_lod_differences,
		" nearby_lod_differences=", nearby_lod_differences,
		" (sampled bound tolerance does not prove bit-exact arbitrary LOD distances)")

func inspect_geometry(team: String, source: ArrayMesh, source_skin: Skin, pair: Dictionary, materials: Array[Material]) -> void:
	var result: ArrayMesh = pair.mesh
	check(result.get_surface_count() == 1, team + " one surface")
	var merged := result.surface_get_arrays(0)
	var offset := 0
	var expected_indices := PackedInt32Array()
	var data := RenderingServer.mesh_get_surface(result.get_rid(), 0)
	var originals := snapshot(source)
	var edges: Array[float] = []
	var original_lod_bytes := 0
	var raw_positions := PackedByteArray()
	var raw_normals := PackedByteArray()
	var raw_weights_match := true
	var raw_joints_match := true
	for surface in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface)
		var count: int = arrays[Mesh.ARRAY_VERTEX].size()
		for slot in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR, Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS]:
			var width := 4 if slot in [Mesh.ARRAY_TANGENT, Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS] else 1
			if arrays[slot] == null or arrays[slot].is_empty():
				check(merged[slot] == null or merged[slot].is_empty(), team + " retains absent attribute " + str(slot))
			else:
				var expected: Variant = arrays[slot]
				if slot == Mesh.ARRAY_BONES: expected = Merge.shifted(expected, surface * source_skin.get_bind_count())
				check(merged[slot].slice(offset * width, (offset + count) * width) == expected,
					team + " exact source attribute %d surface %d" % [slot, surface])
		var bytes: PackedByteArray = originals[surface].vertex_data
		raw_positions.append_array(bytes.slice(0, count * 12))
		raw_normals.append_array(bytes.slice(count * 12))
		var source_bytes: PackedByteArray = originals[surface].skin_data
		var merged_bytes: PackedByteArray = data.skin_data
		for vertex in count:
			var base := vertex * 16
			var merged_base := (offset + vertex) * 16
			raw_weights_match = raw_weights_match and source_bytes.slice(base + 8, base + 16) == merged_bytes.slice(merged_base + 8, merged_base + 16)
			for influence in 4:
				raw_joints_match = raw_joints_match and merged_bytes.decode_u16(merged_base + influence * 2) == source_bytes.decode_u16(base + influence * 2) + surface * source_skin.get_bind_count()
		var material_values_match := true
		for vertex in range(offset, offset + count):
			material_values_match = material_values_match and merged[Mesh.ARRAY_TEX_UV][vertex] == Vector2(materials[surface].roughness, materials[surface].metallic)
		check(material_values_match, team + " exact per-vertex material values surface " + str(surface))
		for index in arrays[Mesh.ARRAY_INDEX]: expected_indices.append(index + offset)
		for lod in originals[surface].get("lods", []):
			if not edges.has(lod.edge_length): edges.append(lod.edge_length)
			original_lod_bytes += lod.index_data.size()
		offset += count
	check(merged[Mesh.ARRAY_INDEX] == expected_indices, team + " exact base triangle order")
	check(merged[Mesh.ARRAY_VERTEX].size() == offset, team + " no added or discarded vertices")
	raw_positions.append_array(raw_normals)
	check(data.vertex_data == raw_positions, team + " exact packed position/normal/tangent bytes")
	check(raw_weights_match and raw_joints_match, team + " exact packed weight bytes and only joint indices remapped")
	check(result.get_aabb() == source.get_aabb() and result.custom_aabb == source.custom_aabb, team + " identical mesh bounds")
	check(source.shadow_mesh == null and result.shadow_mesh == null, team + " retains skinned geometry for shadows")
	var exact_bone_bounds: bool = data.bone_aabbs.size() == originals.size() * source_skin.get_bind_count()
	var exact_bindings: bool = pair.skin.get_bind_count() == originals.size() * source_skin.get_bind_count()
	for surface in originals.size():
		for bind in source_skin.get_bind_count():
			var expected: AABB = originals[surface].bone_aabbs[bind] if bind < originals[surface].bone_aabbs.size() else AABB(Vector3.ZERO, Vector3(-1, -1, -1))
			var alias := surface * source_skin.get_bind_count() + bind
			exact_bone_bounds = exact_bone_bounds and data.bone_aabbs[alias] == expected
			exact_bindings = exact_bindings and pair.skin.get_bind_bone(alias) == source_skin.get_bind_bone(bind) \
				and pair.skin.get_bind_name(alias) == source_skin.get_bind_name(bind) and pair.skin.get_bind_pose(alias) == source_skin.get_bind_pose(bind)
	check(exact_bone_bounds, team + " all per-surface bone boxes retained separately with unused padding")
	check(exact_bindings, team + " paired Skin duplicates all original binding names/bones/poses exactly")
	check(data.get("lods", []).size() == edges.size(), team + " retains all independent LOD thresholds")
	# Select the same exact index stream below, on and above every original
	# threshold, with multiple camera/model scales and pixel thresholds. These
	# shared input distances do NOT prove the animated AABBs produce identical
	# distances; inspect_animated_bounds measures the remaining float roundoff.
	var matching_lods := true
	var samples := 0
	for scale: float in [0.5, 1.0, 2.0]:
		for threshold: float in [0.5, 1.0, 2.0]:
			for edge in edges:
				for factor: float in [0.999999, 1.0, 1.000001]:
					var distance := PackedFloat32Array([edge * scale / threshold * factor])[0]
					var expected := PackedInt32Array()
					var base := 0
					for original in originals:
						for index in indices_at(original, distance, scale, threshold): expected.append(index + base)
						base += int(original.vertex_count)
					matching_lods = matching_lods and indices_at(data, distance, scale, threshold) == expected
					samples += 1
	check(matching_lods, team + " identical LOD triangles around all thresholds / scales")
	var merged_lod_bytes := 0
	for lod in data.get("lods", []): merged_lod_bytes += lod.index_data.size()
	print("OPERATOR_SURFACE_DATA ", team, " vertices=", offset, " base_indices=", expected_indices.size(),
		" lod_thresholds=", edges.size(), " lod_selection_checks=", samples,
		" original_lod_bytes=", original_lod_bytes, " merged_lod_bytes=", merged_lod_bytes,
		" original_buffer_bytes=", buffer_bytes(originals), " additional_cached_buffer_bytes=", buffer_bytes(snapshot(result)))

func check_rejections(source: ArrayMesh, skin: Skin, materials: Array[Material]) -> void:
	for change in [
		{"transparency": BaseMaterial3D.TRANSPARENCY_ALPHA},
		{"vertex_color_is_srgb": true}, {"vertex_color_use_as_albedo": false},
		{"cull_mode": BaseMaterial3D.CULL_DISABLED}, {"diffuse_mode": BaseMaterial3D.DIFFUSE_LAMBERT},
		{"specular_mode": BaseMaterial3D.SPECULAR_DISABLED}, {"metallic_specular": 0.2},
		{"albedo_color": Color(0.5, 1, 1)}, {"emission_enabled": true},
		{"next_pass": StandardMaterial3D.new()}, {"roughness": NAN},
	]:
		var altered := materials.duplicate()
		altered[0] = materials[0].duplicate()
		for property in change: altered[0].set(property, change[property])
		check(Merge.merge(source, skin, altered).is_empty(), "unsupported material fails closed: " + str(change.keys()))
	var textured := materials.duplicate()
	textured[0] = materials[0].duplicate()
	textured[0].albedo_texture = GradientTexture1D.new()
	check(Merge.merge(source, skin, textured).is_empty(), "textured material fails closed")
	var altered_mesh := ArrayMesh.new()
	for surface in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface)
		var uv := PackedVector2Array()
		uv.resize(arrays[Mesh.ARRAY_VERTEX].size())
		arrays[Mesh.ARRAY_TEX_UV] = uv
		altered_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	check(Merge.merge(altered_mesh, skin, materials).is_empty(), "existing UV data is never overwritten")
	altered_mesh = source.duplicate()
	altered_mesh.shadow_mesh = ArrayMesh.new()
	check(Merge.merge(altered_mesh, skin, materials).is_empty(), "custom shadow mesh fails closed")
	altered_mesh = source.duplicate()
	var altered_skin: Skin = skin.duplicate()
	var first := Merge.merge(altered_mesh, altered_skin, materials)
	altered_mesh.custom_aabb = AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4))
	var second := Merge.merge(altered_mesh, altered_skin, materials)
	check(not first.is_empty() and not second.is_empty() and first.mesh != second.mesh and first.skin != second.skin \
		and second.mesh.custom_aabb == altered_mesh.custom_aabb, "mesh changes invalidate the whole cached pair")
	var original_pair := Merge.merge(altered_mesh, skin, materials)
	check(original_pair.mesh != second.mesh and original_pair.skin != second.skin, "same mesh with distinct source Skin identities caches distinct pairs")
	var changed_pose := altered_skin.get_bind_pose(0)
	changed_pose.origin.x += 0.01
	altered_skin.set_bind_pose(0, changed_pose)
	var third := Merge.merge(altered_mesh, altered_skin, materials)
	check(third.mesh != second.mesh and third.skin != second.skin and third.skin.get_bind_pose(0) == changed_pose,
		"source Skin changes invalidate mesh and binding pair together")
	check(Merge.merge(altered_mesh, skin, materials) == original_pair, "Skin invalidation leaves other identity pairs cached")
	var reference: WeakRef = weakref(altered_mesh)
	var skin_reference: WeakRef = weakref(altered_skin)
	Merge.invalidate(altered_mesh.get_instance_id())
	altered_mesh = null
	altered_skin = null
	check(reference.get_ref() == null and skin_reference.get_ref() == null, "cache eviction leaves no mesh or Skin signal/reference cycle")
	check(Merge.merge(source, null, materials).is_empty(), "missing Skin fails closed")
	check(Merge.merge(source, Skin.new(), materials).is_empty(), "empty Skin fails closed")
	altered_skin = skin.duplicate()
	altered_skin.set_bind_count(1)
	check(Merge.merge(source, altered_skin, materials).is_empty(), "too few source bindings fails closed")
	altered_skin = skin.duplicate()
	altered_skin.set_bind_name(0, &"")
	altered_skin.set_bind_bone(0, -1)
	check(Merge.merge(source, altered_skin, materials).is_empty(), "unbound source joint fails closed")
	for pose in [Transform3D(Basis.IDENTITY, Vector3(NAN, 0, 0)), Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)]:
		altered_skin = skin.duplicate()
		altered_skin.set_bind_pose(0, pose)
		check(Merge.merge(source, altered_skin, materials).is_empty(), "nonfinite or singular bind pose fails closed")
	var excessive_skin := Skin.new()
	excessive_skin.set_bind_count(21846) # Three segments would exceed uint16.
	for bind in excessive_skin.get_bind_count():
		excessive_skin.set_bind_bone(bind, 0)
		excessive_skin.set_bind_pose(bind, Transform3D.IDENTITY)
	check(Merge.merge(source, excessive_skin, materials).is_empty(), "joint remap cannot overflow uint16")
	for malformed in ["missing", "oversized", "negative", "nonfinite", "unused", "point", "weighted_unused", "zero_weight_index"]:
		var packed: Array = source.get("_surfaces").duplicate(true)
		var boxes: Array = packed[0].bone_aabbs
		match malformed:
			"missing": boxes.clear()
			"oversized": boxes.resize(skin.get_bind_count() + 1)
			"negative": boxes[0] = AABB(Vector3.ZERO, Vector3(-1, 1, 1))
			"nonfinite": boxes[0] = AABB(Vector3(NAN, 0, 0), Vector3.ONE)
			"unused": boxes.fill(AABB(Vector3.ZERO, Vector3(-1, -1, -1)))
			"point": boxes.fill(AABB(Vector3.ZERO, Vector3.ZERO))
			"weighted_unused", "zero_weight_index":
				var bytes: PackedByteArray = packed[0].skin_data.duplicate()
				var found := false
				for vertex in packed[0].vertex_count:
					for influence in 4:
						var offset: int = vertex * 16 + influence * 2
						var weight := bytes.decode_u16(offset + 8)
						if (malformed == "weighted_unused" and weight > 0) or (malformed == "zero_weight_index" and weight == 0):
							if malformed == "weighted_unused": boxes[bytes.decode_u16(offset)] = AABB(Vector3.ZERO, Vector3(-1, -1, -1))
							else: bytes.encode_u16(offset, skin.get_bind_count())
							found = true
							break
					if found: break
				check(found, "malformed fixture contains required weight case")
				packed[0].skin_data = bytes
		packed[0].bone_aabbs = boxes
		# ArrayMesh exposes the pinned storage layout without modifying the GLB.
		altered_mesh = ArrayMesh.new()
		altered_mesh.set("_surfaces", packed)
		check(Merge.merge(altered_mesh, skin, materials).is_empty(), "malformed skin/bounds fails closed: " + malformed)

func run() -> void:
	for team in ["ct", "t"]:
		var baseline: Node3D = Models.ASSETS[team + "_operator"].instantiate()
		var candidate: Node3D = Models.ASSETS[team + "_operator"].instantiate()
		root.add_child(baseline)
		root.add_child(candidate)
		Models.prepare(baseline)
		Models.prepare(candidate)
		var node: MeshInstance3D = candidate.find_children("*", "MeshInstance3D", true, false)[0]
		var source: ArrayMesh = node.mesh
		var source_data := snapshot(source)
		var materials := active_materials(node)
		var skin := node.skin
		var skin_data := skin_snapshot(skin)
		var skeleton_path := node.skeleton
		var transform := node.transform
		var shadow_mode := node.cast_shadow
		var skeleton: Skeleton3D = candidate.find_children("*", "Skeleton3D", true, false)[0]
		var result := Merge.merge(source, skin, materials)
		check(not result.is_empty(), team + " current imported operator accepted: " + Merge.last_error)
		if result.is_empty():
			baseline.free()
			candidate.free()
			continue
		inspect_geometry(team, source, skin, result, materials)
		check(Merge.merge(source, skin, materials) == result, team + " caches paired mesh and Skin by both source identities")
		check_rejections(source, skin, materials)
		var baseline_node: MeshInstance3D = baseline.find_children("*", "MeshInstance3D", true, false)[0]
		check(baseline_node.mesh == source and baseline_node.skin == skin, team + " instances share both original source identities")
		var original_reference: WeakRef = weakref(node.get_skin_reference())
		var actor_transform := candidate.transform
		candidate.transform = Transform3D(Basis.from_euler(Vector3(0.1, 0.23, -0.07)).scaled(Vector3.ONE * 0.7), Vector3(13, 2, -17))
		check(Merge.apply(candidate) and node.mesh == result.mesh and node.skin == result.skin, team + " opt-in applies cached mesh and Skin together")
		candidate.transform = actor_transform
		check(original_reference.get_ref() == null, team + " replaced SkinReference is released, not kept as a second palette")
		check(node.skin != skin and node.skin.get_bind_count() == 54 and node.get_skin_reference().get_skin() == result.skin,
			team + " exactly one expanded 54-binding Skin registered on mesh")
		check(node.skeleton == skeleton_path and node.transform == transform and node.cast_shadow == shadow_mode,
			team + " skeleton path, instance transform and shadows unchanged")
		check(candidate.find_children("*", "Skeleton3D", true, false)[0] == skeleton and skeleton.get_bone_count() == 18, team + " original 18-bone skeleton node retained")
		check(node.get_surface_override_material(0) == null and node.get_active_material(0) == Merge.material(), team + " source surface override cannot mask merged shader")
		check(snapshot(source) == source_data, team + " imported source geometry/material RIDs untouched")
		check(skin_snapshot(skin) == skin_data, team + " original Skin names, bone indices and poses untouched")
		var rejected: Node3D = Models.ASSETS[team + "_operator"].instantiate()
		root.add_child(rejected)
		Models.prepare(rejected)
		var rejected_node: MeshInstance3D = rejected.find_children("*", "MeshInstance3D", true, false)[0]
		var override := materials[0].duplicate()
		override.vertex_color_is_srgb = true
		rejected_node.set_surface_override_material(0, override)
		check(not Merge.apply(rejected) and rejected_node.mesh == source and rejected_node.skin == skin and rejected_node.get_surface_override_material(0) == override,
			team + " failed apply leaves original node, Skin and materials untouched")
		rejected_node.set_surface_override_material(0, null)
		for malformed in ["name", "index", "top_level", "disable_scale", "transform"]:
			var bad_skin: Skin = skin.duplicate()
			if malformed == "name": bad_skin.set_bind_name(0, &"missing_bone")
			if malformed == "index":
				bad_skin.set_bind_name(0, &"")
				bad_skin.set_bind_bone(0, 18)
			if malformed == "top_level": rejected_node.top_level = true
			if malformed == "disable_scale": rejected_node.set_disable_scale(true)
			if malformed == "transform": rejected_node.position.x += 0.1
			rejected_node.skin = bad_skin
			check(not Merge.apply(rejected) and rejected_node.skin == bad_skin and rejected_node.mesh == source,
				team + " apply rejects unresolved binding/unsupported frame: " + malformed)
			rejected_node.top_level = false
			rejected_node.set_disable_scale(false)
		rejected_node.skin = skin
		rejected.free()
		var baseline_rig := Rig.new()
		var candidate_rig := Rig.new()
		baseline_rig.setup(baseline)
		candidate_rig.setup(candidate)
		check(candidate_rig.weapon_clearance.bounds == baseline_rig.weapon_clearance.bounds, team + " exact weapon skin bounds")
		var same_pose := true
		for frame in 120:
			for rig in [baseline_rig, candidate_rig]:
				rig.update_pose(1.0 / 60, Vector3(0, 0, -2.1), Vector2(0.2, 0.3), 1.1 if frame > 40 else 0.0, false, frame > 90)
			same_pose = same_pose and candidate_rig.pose == baseline_rig.pose
		check(same_pose, team + " exact walk/aim/reload/death bone poses")
		var flash := baseline_rig.flash
		var old_pose := baseline_rig.pose.duplicate()
		check(Merge.apply(baseline) and baseline_rig.flash == flash and baseline_rig.pose == old_pose,
			team + " late fixture opt-in preserves existing rig pose and muzzle flash")
		check(baseline_node.mesh == node.mesh and baseline_node.skin == node.skin, team + " actors share both cached resources without sharing Skeleton3D")
		inspect_animated_bounds(team, source, skin, result, baseline_rig)
		check(snapshot(source) == source_data and skin_snapshot(skin) == skin_data, team + " source resources remain unchanged after animated regressions")
		baseline.free()
		candidate.free()
	print("OPERATOR_SURFACE: %d/%d passed" % [passed, passed + failed])
	quit(1 if failed else 0)
