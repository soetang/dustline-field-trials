extends SceneTree

## Real map bodies and the production player capsule/camera. These checks do
## not assert that an uncollidable weapon or animated operator fits its capsule.
const World = preload("res://scripts/world.gd")
const Player = preload("res://scripts/player.gd")
const Layout = preload("res://scripts/layout.gd")
const ANGLES := [0, -30, 30, -60, 60, 90]
const REPORTED_AT := Vector3(-7.674188, 0.000625, -33.478039)
const REPORTED_YAW := 1.5849597
const REPORTED_PITCH := -0.0666383
const EPSILON := 0.00005

var checks := 0
var failures := 0
var scene: Node3D
var world: FieldWorld
var player: FieldPlayer
var tested_sweeps := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ", label)

func ray(from: Vector3, to: Vector3) -> Dictionary:
	return world.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, to, 1))

func overlaps(shape: Shape3D, at: Transform3D) -> Array[Dictionary]:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = at
	query.collision_mask = 1
	query.margin = 0
	return world.get_world_3d().direct_space_state.intersect_shape(query)

func set_stance(crouched: bool) -> void:
	player.crouched = crouched
	player.capsule.height = 1.25 if crouched else 1.8
	player.collision.position.y = player.capsule.height * 0.5
	# Probe each settled camera height; this does not run or alter crouch timing.
	player.head.position.y = 1.10 if crouched else 1.62

func capsule_clearance(face: Vector3, normal: Vector3) -> float:
	return normal.dot(player.global_position - face) - player.capsule.radius

func camera_clearance(face: Vector3, normal: Vector3) -> Dictionary:
	var camera := player.camera
	var projection := camera.get_camera_projection()
	var half := projection.get_viewport_half_extents()
	var transform := camera.get_camera_transform()
	var minimum := INF
	var rays_clear := true
	for x in [-1, 1]:
		for y in [-1, 1]:
			var corner := transform * Vector3(x * half.x, y * half.y, -camera.near)
			minimum = minf(minimum, normal.dot(corner - face))
			rays_clear = rays_clear and ray(transform.origin, corner).is_empty()
	var plane := BoxShape3D.new()
	plane.size = Vector3(half.x * 2, half.y * 2, 0.0001)
	var near_transform := transform * Transform3D(Basis.IDENTITY, Vector3(0, 0, -camera.near))
	var eye := SphereShape3D.new()
	eye.radius = 0.001
	return {"near_plane_clearance": minimum,
		"near_plane_overlaps": overlaps(plane, near_transform).size(),
		"eye_overlaps": overlaps(eye, Transform3D(Basis.IDENTITY, transform.origin)).size(),
		"corner_rays_clear": rays_clear}

func assert_camera_clear(result: Dictionary, label: String) -> void:
	check(result.near_plane_clearance > 0, label + ": all near-plane corners remain outside the solid face")
	check(result.near_plane_overlaps == 0 and result.eye_overlaps == 0 and result.corner_rays_clear,
		label + ": camera eye, near plane and intervening corner rays avoid real static bodies")

func probe_face(label: String, face: Vector3, normal: Vector3, body: StaticBody3D, feet_y: float) -> void:
	for crouched in [false, true]:
		set_stance(crouched)
		var minimum_capsule := INF
		var minimum_camera := INF
		var blocked_angles: Array[int] = []
		for angle in ANGLES:
			var case_label := "%s %s angle=%d" % [label, "crouched" if crouched else "standing", angle]
			var forward := (-normal).rotated(Vector3.UP, deg_to_rad(angle))
			player.rotation = Vector3(0, atan2(-forward.x, -forward.z), 0)
			player.camera.rotation = Vector3.ZERO
			player.global_position = face + normal * 0.60
			player.global_position.y = feet_y
			player.velocity = Vector3.ZERO
			check(overlaps(player.capsule, player.collision.global_transform).is_empty(), case_label + ": sweep starts without overlap")
			var from := player.global_transform
			var motion := forward # One metre deliberately exceeds a gameplay tick.
			var predicted := KinematicCollision3D.new()
			var blocked := player.test_move(from, motion, predicted, player.safe_margin)
			check(player.global_transform == from, case_label + ": test_move is non-mutating")
			var actual := player.move_and_collide(motion, false, player.safe_margin)
			var should_block: bool = angle != 90
			check(blocked == should_block and (actual != null) == should_block, case_label + ": normal/oblique motion blocks while parallel motion clears")
			if actual != null:
				blocked_angles.append(angle)
				check(actual.get_collider() == body and predicted.get_collider() == body, case_label + ": target wall/door is the stopping collider")
				check(actual.get_normal().dot(normal) > 0.999, case_label + ": contact normal agrees with the real rotated face")
				check(actual.get_travel().is_equal_approx(predicted.get_travel()), case_label + ": physical sweep and motion query agree")
			var clearance := capsule_clearance(face, normal)
			minimum_capsule = minf(minimum_capsule, clearance)
			check(clearance >= -EPSILON, case_label + ": capsule never crosses the solid face")
			check(overlaps(player.capsule, player.collision.global_transform).is_empty(), case_label + ": final capsule does not overlap static geometry")
			var camera := camera_clearance(face, normal)
			minimum_camera = minf(minimum_camera, camera.near_plane_clearance)
			assert_camera_clear(camera, case_label)
			tested_sweeps += 1
		print("WALL_COLLISION_SAMPLE ", JSON.stringify({"face": label, "crouched": crouched,
			"angles": ANGLES, "blocked_angles": blocked_angles,
			"minimum_capsule_clearance_m": minimum_capsule, "minimum_near_plane_clearance_m": minimum_camera}))

func reported_position(face: Vector3, normal: Vector3, body: StaticBody3D) -> void:
	for crouched in [false, true]:
		set_stance(crouched)
		player.position = REPORTED_AT
		player.rotation = Vector3(0, REPORTED_YAW, 0)
		player.camera.rotation = Vector3(REPORTED_PITCH, 0, 0)
		var clearance := capsule_clearance(face, normal)
		check(clearance > 0.0057 and clearance < 0.0059, "reported pose: capsule has approximately 5.812 mm wall clearance")
		check(overlaps(player.capsule, player.collision.global_transform).is_empty(), "reported pose: standing/crouched capsule has no actual static overlap")
		var camera := camera_clearance(face, normal)
		assert_camera_clear(camera, "reported pose %s" % crouched)
		var hit := player.move_and_collide(-normal * 0.1, true, player.safe_margin)
		check(hit != null and hit.get_collider() == body, "reported pose: another 10 cm toward the wall is stopped")
		check(player.position == REPORTED_AT, "reported pose: test-only motion does not relocate the player")
		# These are attachment POINTS, not a skinned-mesh penetration measurement.
		# A negative value explains why visual gun contact needs its own review;
		# body collision protects neither the held weapon nor the muzzle light.
		print("WALL_COLLISION_REPORTED ", JSON.stringify({"crouched": crouched,
			"capsule_clearance_m": clearance, "camera": camera,
			"held_anchor_signed_distance_m": normal.dot(player.held.global_position - face),
			"muzzle_anchor_signed_distance_m": normal.dot(player.muzzle.global_position - face),
			"attempted_motion_m": 0.1, "allowed_travel_m": hit.get_travel().length() if hit != null else 0.1}))

func run() -> void:
	# Production camera projection at a repeatable browser-like aspect ratio.
	root.size = Vector2i(1920, 1080)
	scene = Node3D.new()
	root.add_child(scene)
	world = World.new()
	scene.add_child(world)
	player = Player.new()
	# _ready builds the real capsule/camera/weapon; disable callbacks AFTER
	# entering the tree, since the engine enables script callbacks on entry.
	scene.add_child(player)
	player.set_process(false)
	player.set_physics_process(false)
	player.set_process_unhandled_input(false)
	player.position = Vector3(1, 0.05, -33)
	for i in 3: await physics_frame
	check(is_equal_approx(player.capsule.radius, 0.32) and is_equal_approx(player.camera.near, 0.045), "production capsule radius and camera near plane are the intended probe geometry")
	check(is_equal_approx(player.camera.get_camera_projection().get_aspect(), 1920.0 / 1080.0), "camera uses the requested 16:9 projection")
	var face := Vector3(-8, 1.4, REPORTED_AT.z)
	var wall_hit := ray(face + Vector3.RIGHT, face + Vector3.LEFT)
	check(not wall_hit.is_empty() and wall_hit.collider is StaticBody3D, "CT west wall is a real StaticBody3D")
	if wall_hit.is_empty():
		finish()
		return
	check(absf(wall_hit.position.x + 8) < EPSILON and wall_hit.normal.dot(Vector3.RIGHT) > 0.999, "CT west collision face is x=-8 with inward +X normal")
	reported_position(face, Vector3.RIGHT, wall_hit.collider)
	probe_face("CT west wall", face, Vector3.RIGHT, wall_hit.collider, 0.05)
	for index in Layout.DOORS.size():
		var door: Dictionary = Layout.DOORS[index]
		var frame: Node3D = world.get_node("DoorLeaf%d" % index)
		var local_center := Vector3(door.side * door.width * 0.5, 1.4, 0)
		for side in [-1, 1]:
			var normal: Vector3 = frame.global_basis.z * side
			var door_face := frame.to_global(local_center + Vector3.BACK * side * 0.15)
			var hit := ray(door_face + normal * 0.4, door_face - normal * 0.4)
			check(not hit.is_empty() and hit.collider is StaticBody3D and hit.collider.get_parent() == frame,
				"door %d side %d has its own real rotated body" % [index, side])
			if hit.is_empty(): continue
			check(hit.position.distance_to(door_face) < EPSILON and hit.normal.dot(normal) > 0.999,
				"door %d side %d authored leaf box face and collision face agree" % [index, side])
			# Raise the foot slightly to isolate horizontal leaf sweeps from the
			# sloping ground; camera/capsule still fit within the 3.1 m tall leaf.
			probe_face("door %d side %d" % [index, side], door_face, normal, hit.collider, frame.global_position.y + 0.45)
	check(tested_sweeps == 108, "both stances cover six angles at the CT wall and both faces of all four doors")
	finish()

func finish() -> void:
	print("WALL_COLLISION: %d/%d passed; %d sweeps" % [checks - failures, checks, tested_sweeps])
	scene.queue_free()
	await process_frame
	quit(1 if failures else 0)
