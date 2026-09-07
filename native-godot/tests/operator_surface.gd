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

func inspect_geometry(team: String, source: ArrayMesh, result: ArrayMesh, materials: Array[Material]) -> void:
	check(result.get_surface_count() == 1, team + " one surface")
	var merged := result.surface_get_arrays(0)
	var offset := 0
	var expected_indices := PackedInt32Array()
	var data := RenderingServer.mesh_get_surface(result.get_rid(), 0)
	var originals := snapshot(source)
	var edges: Array[float] = []
	var original_lod_bytes := 0
	for surface in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface)
		var count: int = arrays[Mesh.ARRAY_VERTEX].size()
		for slot in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_COLOR, Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS]:
			var width := 4 if slot in [Mesh.ARRAY_TANGENT, Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS] else 1
			if arrays[slot] == null or arrays[slot].is_empty():
				check(merged[slot] == null or merged[slot].is_empty(), team + " retains absent attribute " + str(slot))
			else:
				check(merged[slot].slice(offset * width, (offset + count) * width) == arrays[slot],
					team + " exact source attribute %d surface %d" % [slot, surface])
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
	check(result.get_aabb() == source.get_aabb() and result.custom_aabb == source.custom_aabb, team + " identical mesh bounds")
	check(source.shadow_mesh == null and result.shadow_mesh == null, team + " retains skinned geometry for shadows")
	var exact_bone_bounds := true
	for bone in data.bone_aabbs.size():
		var expected := AABB(Vector3.ZERO, Vector3(-1, -1, -1))
		for surface in originals.size():
			if bone >= originals[surface].bone_aabbs.size(): continue
			var bounds: AABB = originals[surface].bone_aabbs[bone]
			if bounds.size.x >= 0: expected = bounds if expected.size.x < 0 else expected.merge(bounds)
		exact_bone_bounds = exact_bone_bounds and data.bone_aabbs[bone] == expected
	check(exact_bone_bounds, team + " retains union of original per-bone culling bounds")
	check(data.get("lods", []).size() == edges.size(), team + " retains all independent LOD thresholds")
	# Select the same exact index stream below, on and above every original
	# threshold, with multiple camera/model scales and pixel thresholds.
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

func check_rejections(source: ArrayMesh, materials: Array[Material]) -> void:
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
		check(Merge.merge(source, altered) == null, "unsupported material fails closed: " + str(change.keys()))
	var textured := materials.duplicate()
	textured[0] = materials[0].duplicate()
	textured[0].albedo_texture = GradientTexture1D.new()
	check(Merge.merge(source, textured) == null, "textured material fails closed")
	var altered_mesh := ArrayMesh.new()
	for surface in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface)
		var uv := PackedVector2Array()
		uv.resize(arrays[Mesh.ARRAY_VERTEX].size())
		arrays[Mesh.ARRAY_TEX_UV] = uv
		altered_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	check(Merge.merge(altered_mesh, materials) == null, "existing UV data is never overwritten")
	altered_mesh = source.duplicate()
	altered_mesh.shadow_mesh = ArrayMesh.new()
	check(Merge.merge(altered_mesh, materials) == null, "custom shadow mesh fails closed")
	altered_mesh = source.duplicate()
	var first := Merge.merge(altered_mesh, materials)
	altered_mesh.custom_aabb = AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4))
	var second := Merge.merge(altered_mesh, materials)
	check(first != null and second != null and first != second and second.custom_aabb == altered_mesh.custom_aabb, "source changes invalidate cached mesh")
	var reference: WeakRef = weakref(altered_mesh)
	Merge.invalidate(altered_mesh.get_instance_id())
	altered_mesh = null
	check(reference.get_ref() == null, "cache eviction leaves no source signal/reference cycle")

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
		var skeleton_path := node.skeleton
		var transform := node.transform
		var shadow_mode := node.cast_shadow
		var skeleton: Skeleton3D = candidate.find_children("*", "Skeleton3D", true, false)[0]
		var result := Merge.merge(source, materials)
		check(result != null, team + " current imported operator accepted: " + Merge.last_error)
		if result == null:
			baseline.free()
			candidate.free()
			continue
		inspect_geometry(team, source, result, materials)
		check(Merge.merge(source, materials) == result, team + " caches one merged mesh per source")
		check_rejections(source, materials)
		check(Merge.apply(candidate) and node.mesh == result, team + " opt-in applies cached mesh")
		check(node.skin == skin and node.skeleton == skeleton_path and node.transform == transform and node.cast_shadow == shadow_mode,
			team + " skin, skeleton path, instance transform and shadows unchanged")
		check(candidate.find_children("*", "Skeleton3D", true, false)[0] == skeleton, team + " original skeleton node retained")
		check(node.get_surface_override_material(0) == null and node.get_active_material(0) == Merge.material(), team + " source surface override cannot mask merged shader")
		check(snapshot(source) == source_data, team + " imported source geometry/material RIDs untouched")
		var rejected: Node3D = Models.ASSETS[team + "_operator"].instantiate()
		Models.prepare(rejected)
		var rejected_node: MeshInstance3D = rejected.find_children("*", "MeshInstance3D", true, false)[0]
		var override := materials[0].duplicate()
		override.vertex_color_is_srgb = true
		rejected_node.set_surface_override_material(0, override)
		check(not Merge.apply(rejected) and rejected_node.mesh == source and rejected_node.get_surface_override_material(0) == override,
			team + " failed apply leaves original node and materials untouched")
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
		baseline.free()
		candidate.free()
	print("OPERATOR_SURFACE: %d/%d passed" % [passed, passed + failed])
	quit(1 if failed else 0)
