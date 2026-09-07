extends SceneTree

const Probe = preload("res://engine/experiments/flat_surface.gd")
const World = preload("res://scripts/world.gd")
var passed := 0
var failed := 0
var triangles := 0
var uv_samples := 0

class ScriptedBox:
	extends BoxMesh

class ScriptedMaterial:
	extends ShaderMaterial

func check(ok: bool, label: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func _initialize() -> void:
	call_deferred("run")

func wall() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = Probe.SOURCE
	material.set_shader_parameter("tint", Color(0.71, 0.52, 0.38, 0.9))
	material.set_shader_parameter("diffuse_map", Probe.WALL_DIFF)
	material.set_shader_parameter("normal_map", Probe.WALL_NORMAL)
	material.set_shader_parameter("arm_map", Probe.WALL_ARM)
	material.set_shader_parameter("texture_scale", 0.27)
	material.set_shader_parameter("normal_strength", 0.58)
	material.render_priority = 3
	return material

func add_mesh(parent: Node3D, mesh: Mesh, material: Material, pose := Transform3D.IDENTITY) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.transform = pose
	parent.add_child(instance)
	return instance

func projected_basis(normal: Vector3) -> Basis:
	var n := normal.normalized().normalized()
	var t := Vector3.RIGHT if absf(n.y) > 0.6 else (Vector3(signf(n.z), 0, 0) if absf(n.z) > absf(n.x) else Vector3(0, 0, -signf(n.x)))
	t = (t - n * n.dot(t)).normalized()
	return Basis(t, n.cross(t).normalized(), n)

func uv(point: Vector3, frame: Basis, scale: float) -> Vector2:
	return Vector2(point.dot(frame.x), point.dot(frame.y)) * scale

func check_triangles(mesh: BoxMesh, transform: Transform3D, label: String) -> void:
	var arrays := mesh.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var normal_matrix := transform.basis.inverse().transposed()
	var constant := true
	var matching_uv := true
	var distinct_faces: Dictionary = {}
	for i in range(0, indices.size(), 3):
		var ia := indices[i]
		var ib := indices[i + 1]
		var ic := indices[i + 2]
		constant = constant and normals[ia] == normals[ib] and normals[ia] == normals[ic]
		var frame := projected_basis(normal_matrix * normals[ia])
		constant = constant and frame == projected_basis(normal_matrix * normals[ib]) and frame == projected_basis(normal_matrix * normals[ic])
		distinct_faces[normals[ia]] = true
		var a := transform * vertices[ia]
		var b := transform * vertices[ib]
		var c := transform * vertices[ic]
		# Perspective-correct barycentrics: UV is affine in world position only
		# because the basis is constant over each triangle (not across the mesh).
		for reciprocal_w: Vector3 in [Vector3.ONE, Vector3(0.2, 1.3, 2.7)]:
			var weights := Vector3(0.2, 0.3, 0.5) * reciprocal_w
			weights /= weights.x + weights.y + weights.z
			for scale: float in [0.25, 0.32, -0.17]:
				var original := uv(a * weights.x + b * weights.y + c * weights.z, frame, scale)
				var hoisted := uv(a, frame, scale) * weights.x + uv(b, frame, scale) * weights.y + uv(c, frame, scale) * weights.z
				matching_uv = matching_uv and original.distance_to(hoisted) < 0.00005
				uv_samples += 1
		triangles += 1
	check(constant and distinct_faces.size() == 6, label + " has six distinct, per-triangle constant normal/basis groups")
	check(matching_uv, label + " perspective-correct UV projection matches within float tolerance")

func check_sources() -> void:
	var source: String = Probe.SOURCE.code
	var candidate: String = Probe.CANDIDATE.code
	check(source.sha256_text() == Probe.SOURCE_SHA256, "pinned source hash matches")
	var start := "\tvec2 xy = texture(normal_map, uv).rg * 2.0 - 1.0;"
	check(candidate.substr(candidate.find(start)) == source.substr(source.find(start)), "all fragment texture/normal/lighting arithmetic after UV remains byte-identical")
	var uniforms_match := true
	for line: String in source.split("\n"):
		if line.begins_with("uniform "): uniforms_match = uniforms_match and candidate.contains(line)
	check(uniforms_match and candidate.contains("render_mode diffuse_burley;"), "uniform declarations, samplers, color space and render mode unchanged")
	check(candidate.count("texture(") == 3 and candidate.count("varying flat vec3") == 3, "all three texture fetches retained; only face basis becomes flat")

func check_transforms() -> void:
	var box := BoxMesh.new()
	box.size = Vector3(2.0, 3.0, 0.4)
	var poses: Array[Transform3D] = [Transform3D.IDENTITY]
	for angles: Vector3 in [Vector3(0, 0.37, 0), Vector3(0.13, 0.37, 0.09), Vector3(1.2, 0.2, 0.1)]:
		var basis := Basis.from_euler(angles) * Basis.from_scale(Vector3(0.3, 2.0, 5.0))
		poses.append(Transform3D(basis, Vector3(17, 2, -31)))
	for i in poses.size():
		check(Probe.transform_supported(poses[i]), "rotation/nonuniform scale %d eligible" % i)
		check_triangles(box, poses[i], "box transform %d" % i)
	box.subdivide_width = 2
	box.subdivide_height = 1
	box.subdivide_depth = 3
	check_triangles(box, poses[1], "subdivided box")
	var rejects: Array[Transform3D] = [
		Transform3D(Basis.from_scale(Vector3(0, 1, 1)), Vector3.ZERO),
		Transform3D(Basis.from_scale(Vector3(-1, 1, 1)), Vector3.ZERO),
		Transform3D(Basis.from_scale(Vector3(0.00001, 1, 1)), Vector3.ZERO),
		Transform3D(Basis.from_scale(Vector3(1, 1, 129)), Vector3.ZERO),
		Transform3D(Basis(Vector3.RIGHT, Vector3(0.3, 1, 0), Vector3.BACK), Vector3.ZERO),
		Transform3D(Basis.IDENTITY, Vector3(INF, 0, 0)),
		Transform3D(Basis.IDENTITY, Vector3(NAN, 0, 0)),
		Transform3D(Basis.IDENTITY, Vector3(100001, 0, 0)),
		Transform3D(Basis(Vector3.UP, PI / 4), Vector3.ZERO),
		Transform3D(Basis(Vector3.RIGHT, acos(0.6)), Vector3.ZERO),
	]
	for i in rejects.size(): check(not Probe.transform_supported(rejects[i]), "unsupported transform/seam %d rejected" % i)
	var parent := Transform3D(Basis(Vector3.UP, 0.11), Vector3(3, 4, -7))
	check(Probe.transform_supported(parent * poses[1]), "MultiMesh effective parent/instance rotation and nonuniform scale eligible")
	check_triangles(box, parent * poses[1], "MultiMesh effective parent/instance transform")
	parent.basis = Basis.from_scale(Vector3(1, 2, 3))
	check(not Probe.transform_supported(parent * poses[1]), "MultiMesh effective shear from nonuniform parent and rotated instance rejected")
	check(not Probe.transform_supported(Transform3D.IDENTITY * rejects[1]), "MultiMesh mirrored instance rejected even with valid global transform")

func check_fixture() -> void:
	var fixture := Node3D.new()
	root.add_child(fixture)
	var material := wall()
	var other := wall()
	other.set_shader_parameter("tint", Color(0.3, 0.4, 0.5))
	var first := add_mesh(fixture, BoxMesh.new(), material)
	first.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var second := add_mesh(fixture, BoxMesh.new(), material, Transform3D(Basis(Vector3.UP, 0.37).scaled_local(Vector3(2, 3, 0.5)), Vector3(3, 2, 1)))
	var third := add_mesh(fixture, BoxMesh.new(), other)
	var unchanged: Array[GeometryInstance3D] = []
	unchanged.append(add_mesh(fixture, CylinderMesh.new(), material))
	var floor_mesh := ArrayMesh.new()
	floor_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, PlaneMesh.new().get_mesh_arrays())
	unchanged.append(add_mesh(fixture, floor_mesh, material))
	unchanged.append(add_mesh(fixture, PlaneMesh.new(), material))
	unchanged.append(add_mesh(fixture, ScriptedBox.new(), material))
	var floor_material: ShaderMaterial = material.duplicate(false)
	floor_material.set_shader_parameter("diffuse_map", World.FLOOR_DIFF)
	unchanged.append(add_mesh(fixture, BoxMesh.new(), floor_material))
	var plaster := ShaderMaterial.new()
	plaster.shader = World.PLASTER
	unchanged.append(add_mesh(fixture, BoxMesh.new(), plaster))
	unchanged.append(add_mesh(fixture, BoxMesh.new(), StandardMaterial3D.new()))
	var copied_source: ShaderMaterial = material.duplicate(false)
	copied_source.shader = Probe.SOURCE.duplicate()
	unchanged.append(add_mesh(fixture, BoxMesh.new(), copied_source))
	var extra: ShaderMaterial = material.duplicate(false)
	extra.next_pass = StandardMaterial3D.new()
	unchanged.append(add_mesh(fixture, BoxMesh.new(), extra))
	var overlay := add_mesh(fixture, BoxMesh.new(), material)
	overlay.material_overlay = StandardMaterial3D.new()
	unchanged.append(overlay)
	var skinned := add_mesh(fixture, BoxMesh.new(), material)
	skinned.skin = Skin.new()
	unchanged.append(skinned)
	unchanged.append(add_mesh(fixture, BoxMesh.new(), material, Transform3D(Basis(Vector3.UP, PI / 4), Vector3.ZERO)))
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.use_colors = true
	multi.use_custom_data = true
	multi.mesh = BoxMesh.new()
	multi.instance_count = 2
	multi.visible_instance_count = 1
	for i in 2:
		var pose := Transform3D(Basis(Vector3.UP, 0.21 + i * 0.17).scaled_local(Vector3(2, 3, 0.5)), Vector3(i * 3, 0, 0))
		multi.set_instance_transform(i, pose)
		multi.set_instance_color(i, Color(0.2 * i, 0.3, 0.4))
		multi.set_instance_custom_data(i, Color(0.5, 0.6, 0.7))
		check_triangles(multi.mesh, pose, "MultiMesh upload transform %d" % i)
	var batch := MultiMeshInstance3D.new()
	batch.multimesh = multi
	batch.material_override = material
	fixture.add_child(batch)
	var bad_batch := MultiMeshInstance3D.new()
	bad_batch.multimesh = multi
	bad_batch.material_override = material
	bad_batch.rotation.y = PI / 4
	fixture.add_child(bad_batch)
	unchanged.append(bad_batch)
	var originals: Array[Material] = []
	for node in unchanged: originals.append(node.material_override)
	var second_transform := second.global_transform
	var box_rid := first.mesh.get_rid()
	var buffer := multi.buffer
	var source_code: String = Probe.SOURCE.code
	var probe := Probe.new()
	var result := probe.apply(fixture)
	check(result.error == "" and result.changed == 4 and result.materials == 2 and result.boxes == 3 and result.multimeshes == 1 and result.instances == 5, "only three boxes and one batch change, preserving grouping")
	check(first.material_override == second.material_override and first.material_override == batch.material_override, "one clone reused by original material identity across boxes and batches")
	check(first.material_override != material and third.material_override != first.material_override, "distinct original materials remain distinct and unchanged")
	check(first.material_override.shader == Probe.CANDIDATE and material.shader == Probe.SOURCE and Probe.SOURCE.code == source_code, "candidate shader affects only cloned overrides")
	for name: StringName in Probe.UNIFORMS:
		check(first.material_override.get_shader_parameter(name) == material.get_shader_parameter(name), "exact copied uniform/resource identity " + name)
	check(first.material_override.render_priority == material.render_priority and first.material_override.next_pass == null, "non-shader material properties retained")
	var preserved := true
	for i in unchanged.size(): preserved = preserved and unchanged[i].material_override == originals[i]
	check(preserved, "floor-textured boxes, non-box geometry, shared siblings, alternate shader, skin, overlay and unsupported transforms untouched")
	check(second.global_transform == second_transform and first.mesh.get_rid() == box_rid and first.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "mesh identity, transforms and shadow mode untouched")
	check(batch.multimesh == multi and multi.buffer == buffer and multi.instance_count == 2 and multi.visible_instance_count == 1 and multi.use_colors and multi.use_custom_data, "MultiMesh object, buffer, visibility, color and custom-data settings untouched")
	check(probe.apply(fixture).error == "already_applied", "second application cannot allocate duplicate clones")
	third.material_override = material
	check(probe.restore() == 3 and first.material_override == material and second.material_override == material and batch.material_override == material and third.material_override == material, "restore returns owned overrides only and preserves external replacement")
	check(probe.restore() == 0, "restore is idempotent")
	check(probe.apply(first).changed == 1, "a geometry root itself is eligible")
	first.free()
	check(probe.restore() == 0, "freed instances do not keep nodes alive or break restoration")
	fixture.free()

func check_guards() -> void:
	var fixture := Node3D.new()
	root.add_child(fixture)
	var material := ShaderMaterial.new()
	material.shader = Probe.SOURCE
	material.set_shader_parameter("diffuse_map", Probe.WALL_DIFF)
	material.set_shader_parameter("normal_map", Probe.WALL_NORMAL)
	material.set_shader_parameter("arm_map", Probe.WALL_ARM)
	var box := add_mesh(fixture, BoxMesh.new(), material)
	var probe := Probe.new()
	check(probe.apply(fixture).changed == 1, "default scalar/color uniforms remain eligible")
	for name: StringName in Probe.UNIFORMS:
		check(box.material_override.get_shader_parameter(name) == material.get_shader_parameter(name), "unset/default uniform preserved " + name)
	probe.restore()
	material.set_shader_parameter("texture_scale", NAN)
	check(not Probe.material_supported(material), "nonfinite material scale rejected")
	material.set_shader_parameter("texture_scale", 0.25)
	material.set_shader_parameter("normal_strength", INF)
	check(not Probe.material_supported(material), "nonfinite normal strength rejected")
	var scripted := ScriptedMaterial.new()
	check(not Probe.material_supported(scripted), "scripted material rejected")
	var source: Shader = Probe.SOURCE
	var old: String = source.code
	source.code = old + "\n// simulated source drift\n"
	var drift := probe.apply(fixture)
	check(drift.error == "source_drift" and box.material_override == material, "source drift fails closed without a partial application: " + JSON.stringify(drift))
	source.code = old
	check(probe.apply(null).error == "invalid_root", "missing root rejected")
	var detached := Node3D.new()
	check(probe.apply(detached).error == "invalid_root", "detached root rejected")
	detached.free()
	fixture.free()

func check_world() -> void:
	var world := World.new()
	root.add_child(world)
	await process_frame # Finish the world's queued source-box deletion after batching.
	var batches := world.batching.duplicate(true)
	var bodies := world.find_children("*", "StaticBody3D", true, false)
	var saved: Array[Dictionary] = []
	for node in world.find_children("*", "GeometryInstance3D", true, false):
		saved.append({"node": node, "material": node.material_override, "transform": node.global_transform, "shadow": node.cast_shadow})
	var probe := Probe.new()
	var result := probe.apply(world)
	check(result.error == "" and result.changed > 0 and result.multimeshes > 0, "authored world has eligible wall batches")
	check(world.batching == batches and world.find_children("*", "StaticBody3D", true, false) == bodies and bodies.size() == 53, "all authored batches and 53 collider identities retained")
	var all_preserved := true
	var floor_preserved := true
	var floor_count := 0
	var smooth_count := 0
	var fallback_count := 0
	var fallback_eligible := true
	for item in saved:
		var node: GeometryInstance3D = item.node
		all_preserved = all_preserved and node.global_transform == item.transform and node.cast_shadow == item.shadow
		if item.material is ShaderMaterial and item.material.shader == Probe.SOURCE and item.material.get_shader_parameter("diffuse_map") == World.FLOOR_DIFF:
			floor_count += 1
			floor_preserved = floor_preserved and node.material_override == item.material
		if node is MeshInstance3D and node.mesh is CylinderMesh:
			smooth_count += 1
			all_preserved = all_preserved and node.material_override == item.material
		# The real fallback floor uses wall textures, unlike the terrain mesh.
		if node is MeshInstance3D and node.mesh is BoxMesh and node.mesh.size == Vector3(160, 1, 160):
			fallback_count += 1
			fallback_eligible = fallback_eligible and Probe.material_supported(item.material) and node.material_override is ShaderMaterial and node.material_override != item.material and node.material_override.shader == Probe.CANDIDATE
	check(all_preserved and smooth_count > 0, "authored smooth cylinders, transforms and shadow modes unchanged")
	check(floor_preserved and floor_count > 0, "authored FLOOR_DIFF terrain materials retain original identities")
	check(fallback_count == 1 and fallback_eligible, "real 160x1x160 fallback floor is eligible because it uses concrete wall textures")
	check(probe.restore() == result.changed, "all authored overrides restored")
	for item in saved: all_preserved = all_preserved and item.node.material_override == item.material
	check(all_preserved, "complete world returns to original material identities")
	print("FLAT_SURFACE_WORLD ", JSON.stringify(result))
	world.free()

func run() -> void:
	check_sources()
	check_transforms()
	check_fixture()
	check_guards()
	await check_world()
	print("FLAT_SURFACE_GEOMETRY ", JSON.stringify({"triangles": triangles, "perspective_uv_samples": uv_samples, "note": "CPU geometry proof within float tolerance; no rendered equivalence or speed claim"}))
	print("FLAT_SURFACE: %d/%d passed" % [passed, passed + failed])
	quit(1 if failed else 0)
