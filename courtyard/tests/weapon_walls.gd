extends SceneTree

## Independent source-vertex/bind inspection and final-pose physics checks.
## Does not equate the gun attachment point or muzzle with full mesh clearance.
const Models = preload("res://scripts/models.gd")
const Rig = preload("res://scripts/operator_rig.gd")
const Layout = preload("res://scripts/layout.gd")
const Weapons = preload("res://scripts/weapons.gd")
const Clearance = preload("res://scripts/weapon_clearance.gd")
const ANGLES := [0, -30, 30, -60, 60, 90]
const PITCHES := [-1.48, -0.6, 0.0, 0.6, 1.48]
const EPSILON := 0.0002
const DT := 1.0 / 60.0

class ShotGame:
	extends "res://scripts/game.gd"
	var recorded_from := Vector3.ZERO
	var recorded_direction := Vector3.ZERO
	var recorded_hit := {}
	func fire_shot(shooter: Node3D, from: Vector3, direction: Vector3, weapon_slot: int, spread: float, vertical_scale: float = 1.0) -> Dictionary:
		recorded_from = from
		recorded_direction = direction
		recorded_hit = super.fire_shot(shooter, from, direction, weapon_slot, spread, vertical_scale)
		return recorded_hit

var game: ShotGame
var player: FieldPlayer
var checks := 0
var failures := 0
var player_cases := 0
var rig_cases := 0
var vertex_samples := 0
var failure_counts: Dictionary = {}
var failure_examples: Dictionary = {}
var unsafe_examples: Dictionary = {}
var gun_triangles := PackedVector3Array()
var gun_triangle_parts := PackedStringArray()
var last_near_parts: Dictionary = {}
var near_plane_examples: Array[Dictionary] = []
var near_plane_samples := 0
var maximum_near_cuts := 0
var faces: Array[Dictionary] = []
var query := PhysicsShapeQueryParameters3D.new()
var shape := BoxShape3D.new()

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		var kind := label.substr(label.rfind(": ") + 2) if label.contains(": ") else label
		failure_counts[kind] = int(failure_counts.get(kind, 0)) + 1
		if not failure_examples.has(kind): failure_examples[kind] = label
		# Keep a broken matrix diagnostic bounded without hiding the count.
		if failures <= 35: printerr("FAIL: ", label)

func source_vertices(node: Node3D, parent_transform: Transform3D, result: PackedVector3Array) -> PackedVector3Array:
	var at := parent_transform * node.transform
	if node is MeshInstance3D:
		check(node.skin == null, "viewmodel source mesh is rigid rather than skinned")
		for surface in node.mesh.get_surface_count():
			var points: PackedVector3Array = node.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
			for point in points: result.append(at * point)
	for child in node.get_children():
		if child is Node3D: result = source_vertices(child, at, result)
	return result

func point_bounds(points: PackedVector3Array) -> AABB:
	var result := AABB(points[0], Vector3.ZERO)
	for point in points: result = result.expand(point)
	return result

func source_gun_triangles(node: Node3D, parent_transform: Transform3D, result: PackedVector3Array) -> PackedVector3Array:
	# The hand/forearm meshes intentionally run back toward the camera. Check
	# actual weapon triangles separately; their enclosing hand AABB is not a
	# meaningful test for a visible chopped-off stock or receiver boundary.
	if "hand" in node.name.to_lower(): return result
	var at := parent_transform * node.transform
	if node is MeshInstance3D:
		for surface in node.mesh.get_surface_count():
			var arrays: Array = node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for index in indices: result.append(at * vertices[index])
			for i in range(0, indices.size(), 3): gun_triangle_parts.append(str(node.name))
	for child in node.get_children():
		if child is Node3D: result = source_gun_triangles(child, at, result)
	return result

func segment_in_rect(a: Vector2, b: Vector2, rect: Rect2) -> bool:
	if rect.has_point(a) or rect.has_point(b): return true
	var corners := [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]
	for i in 4:
		if Geometry2D.segment_intersects_segment(a, b, corners[i], corners[(i + 1) % 4]) != null: return true
	return false

func gun_near_plane_cuts() -> int:
	last_near_parts.clear()
	if not player.held.visible: return 0
	var transform := player.camera.get_camera_transform().affine_inverse() * player.held.global_transform
	var half := player.camera.get_camera_projection().get_viewport_half_extents()
	var rect := Rect2(-half, half * 2)
	var plane_z := -player.camera.near
	var cuts := 0
	for i in range(0, gun_triangles.size(), 3):
		var triangle := [transform * gun_triangles[i], transform * gun_triangles[i + 1], transform * gun_triangles[i + 2]]
		var intersections := PackedVector2Array()
		for edge in 3:
			var a: Vector3 = triangle[edge]
			var b: Vector3 = triangle[(edge + 1) % 3]
			if (a.z < plane_z) == (b.z < plane_z): continue
			var at := a.lerp(b, (plane_z - a.z) / (b.z - a.z))
			intersections.append(Vector2(at.x, at.y))
		if intersections.size() == 2 and segment_in_rect(intersections[0], intersections[1], rect):
			cuts += 1
			var part := gun_triangle_parts[i / 3]
			last_near_parts[part] = int(last_near_parts.get(part, 0)) + 1
	return cuts

func body_at(face: Dictionary, distance: float = 0.326) -> Vector3:
	return Layout.on_floor(face.point + face.normal * distance) + Vector3.UP * 0.03

func yaw_at(face: Dictionary, angle: float) -> float:
	var forward: Vector3 = (-face.normal).rotated(Vector3.UP, deg_to_rad(angle))
	return atan2(-forward.x, -forward.z)

func hull_overlaps(bounds: AABB, at: Transform3D) -> bool:
	# Bake scale independently of the solver's canonical .54-scaled bounds.
	shape.size = bounds.size * at.basis.get_scale().abs()
	query.transform = Transform3D(at.basis.orthonormalized(), at * bounds.get_center())
	return not game.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()

func plane_clearance(points: PackedVector3Array, at: Transform3D, face: Dictionary) -> float:
	var minimum := INF
	for point in points:
		minimum = minf(minimum, face.normal.dot(at * point - face.point))
	return minimum

func bounds_corners(bounds: AABB) -> PackedVector3Array:
	var result := PackedVector3Array()
	for i in 8: result.append(bounds.get_endpoint(i))
	return result

func original_view_pose(bob: float) -> Transform3D:
	var at := Vector3(0.08 if player.aimed else 0.24, (-0.19 if player.aimed else -0.25) + bob, -0.55 + player.recoil.x * 2.1)
	var rotation := Vector3(player.recoil.x * 0.6, 0, sin(player.reload_left * 4.0) * 0.28 if player.reload_left > 0 else 0.0)
	at.y -= sin(clampf(player.reload_left / float(Weapons.SPECS[player.slot].reload), 0, 1) * PI) * 0.28
	return Transform3D(Basis.from_euler(rotation).scaled(Vector3.ONE * 0.54), at)

func player_pose(face: Dictionary, angle: float, pitch: float, crouched: bool, state: int) -> void:
	player.position = body_at(face)
	player.rotation = Vector3(0, yaw_at(face, angle), 0)
	player.crouched = crouched
	player.capsule.height = 1.25 if crouched else 1.8
	player.collision.position.y = player.capsule.height * 0.5
	player.head.position.y = 1.1 if crouched else 1.62
	player.camera.rotation = Vector3(pitch, 0, 0)
	player.pitch = pitch
	player.aimed = state == 1
	player.reload_left = float(Weapons.SPECS[player.slot].reload) * 0.5 if state == 2 else 0.0
	player.recoil = Vector2(0.025, -0.008) if state == 3 else Vector2.ZERO
	player.velocity = Vector3.ZERO

func validate_player(points: PackedVector3Array, bounds: AABB, face: Dictionary, label: String, sample_vertices: bool = false) -> void:
	if not player.weapon_clearance.clear and not unsafe_examples.has(player.slot):
		var collisions := game.get_world_3d().direct_space_state.intersect_shape(player.weapon_clearance.query)
		var names: Array[String] = []
		for collision in collisions: names.append(str(collision.collider.get_path()))
		unsafe_examples[player.slot] = {"case": label, "body_at": str(player.position), "hull_center": str(player.weapon_clearance.query.transform.origin), "colliders": names}
	check(player.weapon_clearance.clear, label + ": a visible safe pose exists")
	check(player.held.visible == not (player.slot == 2 and player.aimed), label + ": only scoped AWP is hidden")
	check(player.held.global_transform.is_finite(), label + ": final viewmodel transform is finite")
	check(not hull_overlaps(bounds, player.held.global_transform), label + ": actual complete mesh hull avoids real static bodies")
	check(plane_clearance(bounds_corners(bounds), player.held.global_transform, face) >= -EPSILON,
		label + ": complete mesh remains on owner's side of wall/door")
	if face.has("second"):
		check(plane_clearance(bounds_corners(bounds), player.held.global_transform, face.second) >= -EPSILON,
			label + ": complete mesh also clears the second corner wall")
	if sample_vertices:
		check(plane_clearance(points, player.held.global_transform, face) >= -EPSILON, label + ": every source vertex remains on owner's side")
		vertex_samples += points.size()
		var near_cuts := gun_near_plane_cuts()
		maximum_near_cuts = maxi(maximum_near_cuts, near_cuts)
		near_plane_samples += 1
		if near_cuts > 0 and near_plane_examples.size() < 3:
			near_plane_examples.append({"case": label, "cuts": near_cuts, "parts": last_near_parts.duplicate(),
				"amount": player.weapon_clearance.amount, "held_camera_relative": str(player.held.transform),
				"camera_world_y": player.camera.global_position.y})
		check(near_cuts == 0, label + ": weapon triangles do not cut the visible camera near-plane rectangle")
	player_cases += 1

func player_matrix() -> void:
	for slot in 4:
		player.position = Vector3(0, 4, 0)
		player.equip(slot)
		var points := source_vertices(player.gun, Transform3D.IDENTITY, PackedVector3Array())
		gun_triangle_parts.clear()
		gun_triangles = source_gun_triangles(player.gun, Transform3D.IDENTITY, PackedVector3Array())
		check(not gun_triangles.is_empty() and gun_triangles.size() % 3 == 0, "slot%d has indexed weapon triangles for near-plane checks" % slot)
		var bounds := point_bounds(points)
		var covered := true
		for point in points:
			covered = covered and player.weapon_clearance.bounds.grow(EPSILON).has_point(point * 0.54)
		check(covered, "slot %d configured hull includes every bolt, magazine, gun and hand vertex" % slot)
		print("WEAPON_ASSET ", JSON.stringify({"slot": slot, "vertices": points.size(), "bounds": str(bounds)}))
		for face_index in faces.size():
			var face := faces[face_index]
			for angle_index in ANGLES.size():
				for crouched in [false, true]:
					for state in 4:
						# Full pitch/state product at CT; doors retain every angle,
						# stance/state with rotating pitch coverage to bound runtime.
						var pitches: Array = PITCHES if face_index == 0 else [PITCHES[(face_index + angle_index + state) % PITCHES.size()]]
						for pitch in pitches:
							player_pose(face, ANGLES[angle_index], pitch, crouched, state)
							var before_ammo := player.ammo
							player.update_weapon_pose(DT, 0.009)
							var label := "slot%d %s angle%d pitch%.2f crouch%s state%d" % [slot, face.label, ANGLES[angle_index], pitch, crouched, state]
							validate_player(points, bounds, face, label, player_cases % 47 == 0)
							check(player.ammo == before_ammo, label + ": visual resolution never consumes ammo")
		for face in [faces[0], faces[1], faces[2], faces[-1]]:
			for angle in [-120, 120, -150, 150, 180]:
				for crouched in [false, true]:
					player_pose(face, angle, 0, crouched, 0)
					player.update_weapon_pose(DT)
					validate_player(points, bounds, face, "slot%d behind %s angle%d crouch%s" % [slot, face.label, angle, crouched], true)
		for crouched in [false, true]:
			for state in 4:
				player_pose(faces[0], 0, -0.0666383, crouched, state)
				player.position = Vector3(-7.674188, 0.000625, -33.478039)
				player.rotation.y = 1.5849597
				player.update_weapon_pose(DT)
				validate_player(points, bounds, faces[0], "slot%d exact reported pose crouch%s state%d" % [slot, crouched, state], true)
		# Exit a contact while still checking every intermediate relaxed pose.
		player_pose(faces[0], 0, 0, false, 0)
		player.update_weapon_pose(DT)
		check(player.weapon_clearance.blocked, "slot%d close CT wall actually triggers withdrawal" % slot)
		for frame in 90:
			player.position = body_at(faces[0], 0.326 + frame * 0.025)
			player.update_weapon_pose(DT)
			validate_player(points, bounds, faces[0], "slot%d exit frame%d" % [slot, frame], frame % 15 == 0 or frame == 89)
		check(not player.weapon_clearance.blocked and player.weapon_clearance.amount == 0, "slot%d smoothly returns to unblocked pose" % slot)
		for state in 4:
			player_pose(faces[0], 0, 0.6, state % 2 == 0, state)
			player.position = Vector3(100, 5, 100)
			player.update_weapon_pose(DT, -0.009)
			var expected := player.camera.global_transform * original_view_pose(-0.009)
			check(player.held.global_transform.is_equal_approx(expected), "slot%d state%d open space preserves original view pose" % [slot, state])

func bind_bone(skin: Skin, bind: int, skeleton: Skeleton3D) -> int:
	var name := skin.get_bind_name(bind)
	return skeleton.find_bone(name) if not name.is_empty() else skin.get_bind_bone(bind)

func weapon_vertices(model: Node3D, rig: FieldOperatorRig) -> PackedVector3Array:
	var points := PackedVector3Array()
	var rigid := true
	for mesh: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if mesh.skin == null: continue
		for surface in mesh.mesh.get_surface_count():
			var arrays := mesh.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			for i in vertices.size():
				for influence in 4:
					var offset := i * 4 + influence
					if weights[offset] <= 0 or bind_bone(mesh.skin, joints[offset], rig.skeleton) != rig.ids.weapon: continue
					rigid = rigid and weights[offset] == 1.0
					# Actual mesh palette maps bind indices to named/indexed bones.
					# Keep bone-local points, not a guessed mesh/body AABB.
					points.append(mesh.skin.get_bind_pose(joints[offset]) * vertices[i])
	check(rigid and points.size() > 500, "operator gun vertices are fully weighted to the weapon bind")
	var enclosed := true
	for point in points:
		enclosed = enclosed and rig.weapon_clearance.bounds.grow(EPSILON).has_point(rig.rest[rig.ids.weapon] * point)
	check(enclosed, "rig configured rest-pose hull encloses all actual weapon-bound vertices")
	return points

func validate_rig(rig: FieldOperatorRig, points: PackedVector3Array, bounds: AABB, face: Dictionary, label: String, check_grips: bool = true) -> void:
	var weapon: int = rig.ids.weapon
	var at := rig.skeleton.global_transform * rig.skeleton.get_bone_global_pose(weapon)
	check(rig.weapon_clearance.clear, label + ": safe weapon pose exists")
	check(at.is_finite(), label + ": actual rendered bone transform is finite")
	check(not hull_overlaps(bounds, at), label + ": complete posed gun hull avoids real static bodies")
	check(plane_clearance(points, at, face) >= -EPSILON, label + ": every skinned weapon vertex remains on owner's side")
	if face.has("second"):
		check(plane_clearance(points, at, face.second) >= -EPSILON, label + ": skinned weapon also clears the second corner wall")
	vertex_samples += points.size()
	if check_grips:
		var delta: Transform3D = rig.pose[weapon] * rig.rest[weapon].affine_inverse()
		for arm in rig.arms:
			var grip: Vector3 = delta * rig.rest[arm.end].origin
			check(rig.pose[arm.end].origin.distance_to(grip) < 0.004, label + ": IK hand follows resolved gun grip")
	rig_cases += 1

func rig_matrix() -> void:
	for team in ["ct", "t"]:
		var model: Node3D = Models.ASSETS[team + "_operator"].instantiate()
		game.add_child(model)
		var rig := Rig.new()
		rig.setup(model)
		var points := weapon_vertices(model, rig)
		var bounds := point_bounds(points)
		for face in faces:
			for angle in ANGLES:
				for pitch in [-0.6, 0.0, 0.6]:
					for reload_left in [0.0, 1.1]:
						model.position = body_at(face)
						model.rotation = Vector3(0, yaw_at(face, angle), 0)
						rig.aim = Vector2(pitch, 0)
						rig.reload_blend = 1 if reload_left else 0
						rig.update_pose(DT, Vector3.ZERO, Vector2(pitch, 0), reload_left, false, false, 0,
							model.global_transform, Callable(), game.get_world_3d().direct_space_state)
						validate_rig(rig, points, bounds, face, "%s %s angle%d pitch%.1f reload%.1f" % [team, face.label, angle, pitch, reload_left], reload_left == 0)
		for face in [faces[0], faces[1], faces[2], faces[-1]]:
			for angle in [-120, 120, -150, 150, 180]:
				model.position = body_at(face)
				model.rotation = Vector3(0, yaw_at(face, angle), 0)
				rig.aim = Vector2.ZERO
				rig.reload_blend = 0
				rig.update_pose(DT, Vector3.ZERO, Vector2.ZERO, 0, false, false, 0,
					model.global_transform, Callable(), game.get_world_3d().direct_space_state)
				validate_rig(rig, points, bounds, face, "%s behind %s angle%d" % [team, face.label, angle])
		model.position = body_at(faces[0])
		model.rotation = Vector3(0, yaw_at(faces[0], 0), 0)
		rig.aim = Vector2.ZERO
		rig.reload_blend = 0
		rig.update_pose(DT, Vector3.ZERO, Vector2.ZERO, 0, false, false, 0, model.global_transform, Callable(), game.get_world_3d().direct_space_state)
		check(rig.weapon_clearance.blocked, team + " close CT wall triggers gun withdrawal")
		for frame in 90:
			model.position = body_at(faces[0], 0.326 + frame * 0.025)
			rig.update_pose(DT, Vector3.ZERO, Vector2.ZERO, 0, false, false, 0, model.global_transform, Callable(), game.get_world_3d().direct_space_state)
			validate_rig(rig, points, bounds, faces[0], "%s exit frame%d" % [team, frame])
		check(not rig.weapon_clearance.blocked and rig.weapon_clearance.amount == 0, team + " recovers normal gun pose away from wall")
		model.queue_free()
		await process_frame

func corpse_cases() -> void:
	for team in ["ct", "t"]:
		for face in [faces[0], faces[-1]]:
			for angle in [0, 60, 180]:
				var actor := Node3D.new()
				game.add_child(actor)
				actor.position = body_at(face)
				actor.rotation.y = yaw_at(face, angle)
				var model: Node3D = Models.ASSETS[team + "_operator"].instantiate()
				actor.add_child(model)
				var rig := Rig.new()
				rig.setup(model)
				var points := weapon_vertices(model, rig)
				var bounds := point_bounds(points)
				for frame in 30:
					rig.update_pose(DT, Vector3.ZERO, Vector2.ZERO, 0, false, true, 0, actor.global_transform, Callable(), game.get_world_3d().direct_space_state)
					validate_rig(rig, points, bounds, face, "%s corpse %s angle%d frame%d" % [team, face.label, angle, frame], false)
				actor.queue_free()
				await process_frame

func solver_open_pose() -> void:
	var solver := Clearance.new()
	solver.configure(AABB(Vector3(-0.05, -0.1, -0.6), Vector3(0.1, 0.2, 0.8)))
	var desired := Transform3D(Basis.from_euler(Vector3(0.1, 0.2, 0.3)), Vector3(100, 5, 100))
	var safe := Transform3D(Basis(Vector3.RIGHT, -PI * 0.5), Vector3(100, 4.5, 100))
	var resolved := solver.resolve(game.get_world_3d().direct_space_state, desired, safe, desired.origin + Vector3.BACK, DT)
	check(resolved == desired and not solver.blocked and solver.clear, "fresh solver leaves open-space desired transform exactly unchanged")
	# Keep an identical no-space reference rig, comparing all 18 bone poses.
	var models: Array[Node3D] = []
	var rigs: Array[FieldOperatorRig] = []
	for i in 2:
		var model: Node3D = Models.ASSETS.ct_operator.instantiate()
		game.add_child(model)
		model.position = Vector3(100, 5, 100)
		models.append(model)
		var rig := Rig.new()
		rig.setup(model)
		rigs.append(rig)
	var identical := true
	var max_origin_error := 0.0
	var max_basis_error := 0.0
	for frame in 120:
		for i in 2:
			rigs[i].update_pose(DT, Vector3(0.8, 0, -1.5), Vector2(0.3, -0.2), 0.8 if frame >= 60 else 0.0, false, false, 0,
				models[i].global_transform, Callable(), game.get_world_3d().direct_space_state if i else null)
		for bone in rigs[0].pose.size():
			identical = identical and rigs[0].pose[bone].is_equal_approx(rigs[1].pose[bone])
			max_origin_error = maxf(max_origin_error, rigs[0].pose[bone].origin.distance_to(rigs[1].pose[bone].origin))
			for axis in 3: max_basis_error = maxf(max_basis_error, rigs[0].pose[bone].basis[axis].distance_to(rigs[1].pose[bone].basis[axis]))
	print("WEAPON_OPEN_RIG_ERROR ", JSON.stringify({"max_origin_m": max_origin_error, "max_basis_axis_error": max_basis_error}))
	check(identical, "open-space clearance preserves complete no-space rig animation")
	for model in models: model.queue_free()
	await process_frame

func bullets() -> void:
	var enemy: FieldBot = game.bots[4]
	for slot in 4:
		player.equip(slot)
		player_pose(faces[0], 0, 0, false, 0)
		player.update_weapon_pose(DT)
		player.cooldown = 0
		player.reload_left = 0
		game.phase = "LIVE"
		game.rng.seed = 731
		enemy.position = Vector3(-9, 0.03, faces[0].point.z)
		enemy.health = 1000
		enemy.collision_layer = 4
		for i in 2: await physics_frame
		var camera_at := player.camera.global_position
		var camera_direction := -player.camera.global_basis.z
		var ammo := player.ammo
		check(player.fire() and player.ammo == ammo - 1, "slot%d firing at a wall still consumes exactly one round" % slot)
		check(game.recorded_from == camera_at and game.recorded_direction == camera_direction, "slot%d bullet still originates from camera, not withdrawn weapon" % slot)
		check(game.recorded_hit.get("collider") == faces[0].body and enemy.health == 1000, "slot%d real bullet hits wall without damaging actor behind it" % slot)
		check(not player.fire() and player.ammo == ammo - 1, "slot%d existing cooldown blocks a duplicate shot" % slot)

func cpu_samples() -> void:
	# Optional native implementation-cost sample, never browser/FPS evidence.
	for contact in [false, true]:
		for enabled in [false, true]:
			var model: Node3D = Models.ASSETS.ct_operator.instantiate()
			game.add_child(model)
			model.position = body_at(faces[0]) if contact else Layout.CT_SPAWN + Vector3.UP * 0.03
			model.rotation.y = yaw_at(faces[0], 0)
			var rig := Rig.new()
			rig.setup(model)
			var space := game.get_world_3d().direct_space_state if enabled else null
			var samples: Array[float] = []
			var total_queries := 0
			for run in 6:
				var started := Time.get_ticks_usec()
				for frame in 240:
					rig.update_pose(DT, Vector3.ZERO, Vector2(0.1, 0.05), 0, false, false, 0, model.global_transform, Layout.floor_height, space)
					if run > 0: total_queries += rig.weapon_clearance.queries if enabled else 0
				if run > 0: samples.append((Time.get_ticks_usec() - started) / 240.0)
			samples.sort()
			print("WEAPON_CPU_SAMPLE ", JSON.stringify({"contact": contact, "space_enabled": enabled,
				"median_us_per_pose": samples[2], "min_us_per_pose": samples[0], "max_us_per_pose": samples[4],
				"mean_queries_per_pose": total_queries / 1200.0, "frames_per_sample": 240, "samples": 5,
				"grounded": true,
				"scope": "native headless animation/query cost only, not browser FPS"}))
			model.queue_free()
			await process_frame

func run() -> void:
	game = ShotGame.new()
	root.add_child(game)
	current_scene = game
	game.set_paused(true)
	game.set_process(false)
	game.set_physics_process(false)
	player = game.player
	player.set_process(false)
	player.set_physics_process(false)
	for bot in game.bots:
		bot.set_process(false)
		bot.set_physics_process(false)
		bot.collision_layer = 0
	query.shape = shape
	query.collision_mask = 1
	query.margin = 0
	for i in 3: await physics_frame
	var at := Vector3(-8, 1.4, -33.478039)
	var wall_hit := game.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(at + Vector3.RIGHT, at + Vector3.LEFT, 1))
	faces.append({"label": "CT wall", "point": at, "normal": Vector3.RIGHT, "body": wall_hit.collider})
	for index in Layout.DOORS.size():
		var door: Dictionary = Layout.DOORS[index]
		var frame: Node3D = game.world.get_node("DoorLeaf%d" % index)
		for side in [-1, 1]:
			faces.append({"label": "door%d side%d" % [index, side],
				"point": frame.to_global(Vector3(door.side * door.width * 0.5, 1.4, side * 0.15)),
				"normal": frame.global_basis.z * side})
	faces.append({"label": "CT inner corner", "point": Vector3(-8, 1.4, -37.674), "normal": Vector3.RIGHT,
		"second": {"point": Vector3(-7.674, 1.4, -38), "normal": Vector3.BACK}})
	await solver_open_pose()
	player_matrix()
	await rig_matrix()
	await corpse_cases()
	await bullets()
	if "--cpu-sample" in OS.get_cmdline_user_args(): await cpu_samples()
	if failures:
		print("WEAPON_FAILURES ", JSON.stringify({"counts": failure_counts, "examples": failure_examples, "unsafe_player": unsafe_examples}))
	print("WEAPON_NEAR_PLANE ", JSON.stringify({"sampled_poses": near_plane_samples, "max_weapon_triangle_cuts": maximum_near_cuts, "examples": near_plane_examples, "scope": "actual non-hand triangles crossing the projected near-plane rectangle; not a rendered screenshot"}))
	print("WEAPON_WALLS: %d/%d passed; player_poses=%d rig_poses=%d sampled_vertices=%d" % [checks - failures, checks, player_cases, rig_cases, vertex_samples])
	game.queue_free()
	await process_frame
	quit(1 if failures else 0)
