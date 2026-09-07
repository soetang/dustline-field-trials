extends SceneTree

## Test-only Jolt contact/lifetime coverage. The caller must select the backend;
## this script never changes physics configuration. No renderer or timing gate.
const Models = preload("res://scripts/models.gd")
const Rig = preload("res://scripts/operator_rig.gd")
const Controller = preload("res://engine/experiments/death_physics.gd")
const Geometry = preload("res://tests/fixtures/death_geometry.gd")
const STEP := 1.0 / 60.0
const MAX_TICKS := 600 # Failure deadline only: never force a sleeping/frozen pose.
const EXPECTED_COUNTS := {"ct": [3182, 551], "t": [3129, 564]}

class Fixture:
	extends Node3D
	var paused := false
	var phase := "LIVE"
	var defuser: Node3D
	var objective := {"carrier": null, "plant_progress": 0.0}

class Actor:
	extends Node3D
	var game: Fixture
	var health := 100.0
	var velocity := Vector3.ZERO
	var look_goal := Vector3(0, 1.52, -8)
	var role := "ATTACK"
	var reload_left := 0.0
	var model: Node3D
	var rig: FieldOperatorRig
	func eye() -> Vector3:
		return global_position + Vector3.UP * 1.52

var passed := 0
var failed := 0
var rows: Array = []
var readiness_rows: Array = []
var completed: Dictionary = {}
var fixture: Fixture
var backend := ""

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("FAIL: ", message)

func add_box(at: Transform3D, size: Vector3) -> void:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	fixture.add_child(body)
	body.transform = at

func prepare(team: String, scene: String, yaw: float, distance := 0.326) -> Dictionary:
	fixture = Fixture.new()
	root.add_child(fixture)
	var at := Vector3(-8 + distance, 0, -33.478)
	var planes: Array = [{"name": "floor", "point": Vector3.ZERO, "normal": Vector3.UP}]
	if scene == "ramp":
		at = Vector3(8, 1.1, -29)
		var slope := Basis(Vector3.BACK, atan(0.275))
		add_box(Transform3D(slope, at - slope.y * 0.25), Vector3(8 / cos(atan(0.275)), 0.5, 10))
		planes = [{"name": "A-ramp", "point": at, "normal": slope.y}]
	else:
		add_box(Transform3D(Basis.IDENTITY, Vector3(-8, -0.25, -33.478)), Vector3(30, 0.5, 30))
		if scene == "wall":
			add_box(Transform3D(Basis.IDENTITY, Vector3(-8.25, 2, -33.478)), Vector3(0.5, 4, 20))
			planes.append({"name": "wall", "point": Vector3(-8, 0, 0), "normal": Vector3.RIGHT})
	var actor := Actor.new()
	actor.game = fixture
	fixture.add_child(actor)
	actor.position = at
	actor.rotation.y = deg_to_rad(yaw)
	actor.model = Models.ASSETS[team + "_operator"].instantiate()
	actor.add_child(actor.model)
	Models.prepare(actor.model)
	actor.rig = Rig.new()
	actor.rig.setup(actor.model)
	actor.rig.last_yaw = actor.rotation.y
	actor.look_goal = actor.eye() - actor.global_basis.z * 8
	for frame in 2: await physics_frame
	for frame in 60: actor.rig.animate(STEP, actor)
	return {"actor": actor, "planes": planes}

func body_states(helper: RefCounted) -> Array:
	var result: Array = []
	for body: PhysicalBone3D in helper.bodies:
		var rid := body.get_rid()
		result.append({"transform": PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM),
			"linear": PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY),
			"angular": PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)})
	return result

func pause_probe(helper: RefCounted, actor: Actor, label: String) -> Dictionary:
	var native_before := body_states(helper)
	var before: Array = helper.latest_global_poses.duplicate()
	var updates: int = helper.modifier_updates
	helper.set_paused(true)
	var paused_bones := Geometry.poses(actor.rig)
	var still := true
	for frame in 12:
		await physics_frame
		helper.tick(STEP)
		still = still and helper.latest_global_poses == before and Geometry.poses(actor.rig) == paused_bones
		var native_after := body_states(helper)
		for index in native_after.size():
			still = still and native_after[index].transform == native_before[index].transform
	check(still and helper.paused and helper.active and not helper.frozen and helper.modifier_updates == updates,
		label + " active pause holds actual body transforms and both visible/stored poses")
	helper.set_paused(false)
	var resumed := body_states(helper)
	var origin_delta := 0.0
	var basis_delta := 0.0
	var velocity_delta := 0.0
	for index in resumed.size():
		origin_delta = maxf(origin_delta, resumed[index].transform.origin.distance_to(native_before[index].transform.origin))
		for axis in 3:
			basis_delta = maxf(basis_delta, resumed[index].transform.basis[axis].distance_to(native_before[index].transform.basis[axis]))
		velocity_delta = maxf(velocity_delta, resumed[index].linear.distance_to(native_before[index].linear))
		velocity_delta = maxf(velocity_delta, resumed[index].angular.distance_to(native_before[index].angular))
	# Native Jolt set_transform decomposes the matrix into a quaternion, so a
	# basis roundtrip is not bit-exact. Translation and both velocities must be.
	check(not helper.paused and resumed.size() == native_before.size() and origin_delta == 0.0
		and velocity_delta == 0.0 and basis_delta <= 0.000001, label + " resume restores every body transform and velocity; deltas="
		+ str([origin_delta, basis_delta, velocity_delta]))
	return {"paused_pose_exact": still, "resume_origin_delta_m": origin_delta,
		"resume_basis_delta": basis_delta, "resume_velocity_delta": velocity_delta}

func frozen_probe(helper: RefCounted, actor: Actor, data: Dictionary, signals: Dictionary, label: String) -> Dictionary:
	# Flush the one legitimate final bake notification before counting steady work.
	await process_frame
	await process_frame
	var before := Geometry.poses(actor.rig)
	var points := Geometry.points(data, before)
	var bake_delta := Geometry.max_delta(points, Geometry.points(data, helper.latest_global_poses))
	var coordinate := 1.0
	for point in points:
		coordinate = maxf(coordinate, point.point.abs()[point.point.abs().max_axis_index()])
	# set_bone_pose decomposes/rebuilds rotation and scale. At z=-33 m a single
	# world float ULP is 3.8 um: use a coordinate-derived bound, not a contact
	# allowance, and independently bound the un-translated bone-space difference.
	var world_roundoff := maxf(0.000002, 2.0 * coordinate * pow(2.0, -23.0))
	var bone_origin_delta := 0.0
	var bone_basis_delta := 0.0
	for index in before.size():
		bone_origin_delta = maxf(bone_origin_delta, before[index].origin.distance_to(helper.latest_global_poses[index].origin))
		for axis in 3:
			bone_basis_delta = maxf(bone_basis_delta, before[index].basis[axis].distance_to(helper.latest_global_poses[index].basis[axis]))
	check(bake_delta <= world_roundoff and bone_origin_delta <= 0.000002 and bone_basis_delta <= 0.000002,
		label + " baked actual Skeleton agrees with modifier within float roundoff; deltas="
		+ str([bake_delta, bone_origin_delta, bone_basis_delta]))
	var updates: int = signals.count
	var modifiers: int = helper.modifier_updates
	for frame in 24:
		await physics_frame
		helper.set_paused(frame % 2 == 0)
		helper.tick(STEP)
	check(Geometry.poses(actor.rig) == before and signals.count == updates and helper.modifier_updates == modifiers,
		label + " frozen pause/resume performs zero residual Skeleton or modifier updates")
	check(helper.frozen and not helper.active and helper.bodies.is_empty()
		and actor.rig.skeleton.find_children("*", "PhysicalBone3D", true, false).is_empty(), label + " bake releases all physical nodes")
	return {"vertex_delta_m": bake_delta, "vertex_roundoff_bound_m": world_roundoff,
		"bone_origin_delta_m": bone_origin_delta, "bone_basis_delta": bone_basis_delta,
		"steady_skeleton_updates": signals.count - updates, "steady_modifier_updates": helper.modifier_updates - modifiers}

func measure_case(team: String, scene: String, yaw: float, distance := 0.326) -> void:
	var label := "%s/%s/%s/%s" % [team, scene, yaw, distance]
	check(not completed.has(label), label + " unique case")
	var setup: Dictionary = await prepare(team, scene, yaw, distance)
	var actor: Actor = setup.actor
	var data := Geometry.capture(actor.rig)
	check(data.errors.is_empty() and data.counts == EXPECTED_COUNTS[team] and data.weight_sum_supported,
		label + " complete original indexed body/rifle Skin geometry: " + str(data.errors))
	if not data.errors.is_empty():
		fixture.free()
		return
	var before := Geometry.points(data, Geometry.poses(actor.rig))
	var initial := Geometry.clearance(before, setup.planes)
	var starting_withdrawal := actor.rig.weapon_clearance.amount
	var old_callback := actor.rig.skeleton.modifier_callback_mode_process
	var signals := {"count": 0}
	actor.rig.skeleton.skeleton_updated.connect(func(): signals.count += 1)
	actor.health = 0
	actor.rig.on_shot() # A previously active live flash must not survive death.
	var helper := Controller.new()
	check(helper.activate(actor.rig, actor.velocity), label + " physical activation succeeds")
	if not helper.active:
		fixture.free()
		return
	var activation_delta := Geometry.max_delta(before, Geometry.points(data, helper.latest_global_poses))
	check(activation_delta == 0.0 and not actor.rig.flash.visible, label + " exact visible activation and flash hidden")
	var body_layout_ok := helper.body_count == 12 and helper.bodies.size() == 12 and helper.joint_count == 10
	for body: PhysicalBone3D in helper.bodies:
		var shapes := body.find_children("*", "CollisionShape3D", false, false)
		body_layout_ok = body_layout_ok and shapes.size() == 1 and shapes[0].shape is BoxShape3D
		body_layout_ok = body_layout_ok and body.collision_layer == 16 and body.collision_mask == 1 and body.can_sleep
		body_layout_ok = body_layout_ok and not body.has_method("configure_sweep")
		if body.bone_name == "weapon": body_layout_ok = body_layout_ok and body.joint_type == PhysicalBone3D.JOINT_TYPE_NONE
		# Diagnostic contact records only; no solver or collision setting changes.
		PhysicsServer3D.body_set_max_contacts_reported(body.get_rid(), 4)
	check(body_layout_ok, label + " twelve unswept isolated box bodies with freely released rifle")
	var transition := {"minimum": [INF, INF], "bone": ["", ""], "plane": ["", ""], "frame": [-1, -1]}
	var finite := true
	var contacts := 0
	var native_sleep := false
	var resumed_motion := false
	var paused_pose: Array = []
	var pause_result: Dictionary = {}
	var first_frozen := -1
	var sampled_ticks := 0
	var last_tick := -1
	var maximum_tick_gap := 0
	var previous := Geometry.points(data, helper.latest_global_poses)
	for frame in MAX_TICKS:
		await physics_frame # Every native physics tick, including catch-up ticks.
		var tick := Engine.get_physics_frames()
		if last_tick >= 0: maximum_tick_gap = maxi(maximum_tick_gap, tick - last_tick)
		last_tick = tick
		sampled_ticks += 1
		var all_sleeping: bool = helper.bodies.size() == 12
		for body: PhysicalBone3D in helper.bodies:
			var rid := body.get_rid()
			all_sleeping = all_sleeping and PhysicsServer3D.body_get_mode(rid) == PhysicsServer3D.BODY_MODE_RIGID
			all_sleeping = all_sleeping and bool(PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING))
			var state := PhysicsServer3D.body_get_direct_state(rid)
			if state != null:
				contacts = maxi(contacts, state.get_contact_count())
				finite = finite and str(state.get_class()) == "JoltPhysicsDirectBodyState3D"
		helper.tick(STEP)
		var actual := Geometry.points(data, helper.latest_global_poses)
		var sample := Geometry.clearance(actual, setup.planes)
		finite = finite and sample.finite
		for group in 2:
			if sample.minimum[group] < transition.minimum[group]:
				for key in ["minimum", "bone", "plane"]: transition[key][group] = sample[key][group]
				transition.frame[group] = frame
		if not paused_pose.is_empty(): resumed_motion = resumed_motion or helper.latest_global_poses != paused_pose
		previous = actual
		if helper.frozen:
			first_frozen = frame
			native_sleep = all_sleeping and helper.engine_sleeping and helper.native_awake_observed
			break
		if frame == 12:
			paused_pose = helper.latest_global_poses.duplicate()
			pause_result = await pause_probe(helper, actor, label)
			last_tick = Engine.get_physics_frames() # Twelve intentionally stationary ticks were independently checked.
	var final := Geometry.clearance(previous, setup.planes)
	check(finite and initial.finite and final.finite and maximum_tick_gap == 1, label + " finite original vertices sampled every unpaused native tick")
	check(contacts > 0, label + " actual native contacts exercised")
	check(final.minimum[0] >= -0.005 and final.minimum[1] >= -0.002, label + " final actual body/rifle contact bounds")
	check(transition.minimum[0] >= minf(-0.01, initial.minimum[0] - 0.005), label + " no new deep body penetration (initial violation separate)")
	check(transition.minimum[1] >= minf(-0.01, initial.minimum[1] - 0.005), label + " no rifle tunneling")
	check(first_frozen >= 0 and native_sleep and resumed_motion, label + " native sleep only, after resumed physical motion, within test deadline")
	var bake_result: Dictionary = {}
	if helper.frozen: bake_result = await frozen_probe(helper, actor, data, signals, label)
	var row := {"team": team, "scene": scene, "yaw": yaw, "wall_distance": distance,
		"vertices": data.counts, "initial": initial, "initial_violation": initial.minimum[0] < 0 or initial.minimum[1] < 0,
		"geometry": {"errors":data.errors,"weight_error":data.weight_error,"weight_error_limit":data.weight_error_limit,
			"weight_sum_min":data.weight_sum_min,"weight_sum_max":data.weight_sum_max,"weight_sum_supported":data.weight_sum_supported},
		"starting_withdrawal": starting_withdrawal, "activation_max_vertex_delta": activation_delta,
		"transition": transition, "final": final, "native_sleep": native_sleep, "frozen_frame": first_frozen,
		"sampled_physics_ticks": sampled_ticks, "maximum_tick_gap": maximum_tick_gap, "max_reported_contacts_per_body": contacts,
		"pause": pause_result, "bake": bake_result}
	rows.append(row)
	completed[label] = true
	print("DEATH_PHYSICS_CASE ", JSON.stringify(row))
	helper.dispose()
	check(actor.rig.skeleton.modifier_callback_mode_process == old_callback, label + " original Skeleton callback restored")
	fixture.free()
	await process_frame

func cleanup_case(team: String, mode: String) -> void:
	var setup: Dictionary = await prepare(team, "flat", 0)
	var actor: Actor = setup.actor
	var old_callback := actor.rig.skeleton.modifier_callback_mode_process
	var helper = Controller.new()
	check(helper.activate(actor.rig, Vector3(0.3, 0, 0)), team + " " + mode + " cleanup activation")
	if not helper.active:
		fixture.free()
		return
	for frame in 8:
		await physics_frame
		helper.tick(STEP)
	check(helper.active and not helper.frozen, team + " " + mode + " cleanup occurs midfall")
	var weak_bodies: Array = []
	for body in helper.bodies: weak_bodies.append(weakref(body))
	if mode == "owner_free": actor.free()
	elif mode == "owner_remove": fixture.remove_child(actor)
	elif mode == "refcount":
		var weak_controller: WeakRef = weakref(helper)
		helper = null
		check(weak_controller.get_ref() == null, team + " controller reference drops without a signal cycle")
	else:
		helper.dispose()
		helper.dispose() # Idempotent explicit disposal is part of round reset.
	await process_frame
	await physics_frame
	var released := true
	for weak_body in weak_bodies: released = released and weak_body.get_ref() == null
	check(released, team + " " + mode + " releases every PhysicalBone")
	if helper != null:
		check(not helper.active and helper.bodies.is_empty(), team + " " + mode + " controller inactive after cleanup")
		helper.tick(STEP)
		helper.dispose()
	if is_instance_valid(actor):
		check(actor.rig.skeleton.modifier_callback_mode_process == old_callback, team + " " + mode + " restores callback")
		if mode == "dispose":
			for frame in 60: actor.rig.animate(STEP, actor)
			check(helper.activate(actor.rig, Vector3.ZERO) and helper.body_count == 12
				and helper.joint_count == 10 and helper.modifier_updates == 0,
				team + " same controller can restart with reset counters and only twelve new bodies")
			helper.dispose()
		if mode == "owner_remove": actor.free()
	fixture.free()
	await process_frame

func readiness_case(team: String, idle_activation: bool) -> void:
	var label := team + (" idle activation" if idle_activation else " physics activation")
	var setup: Dictionary = await prepare(team,"flat",0)
	var actor: Actor = setup.actor
	if idle_activation: await process_frame
	check(Engine.is_in_physics_frame() != idle_activation, label + " exercises the intended activation phase")
	var helper := Controller.new()
	check(helper.activate(actor.rig,Vector3.ZERO), label + " starts twelve native bodies")
	var initially_inactive := true
	for body in helper.bodies:
		initially_inactive = initially_inactive and PhysicsServer3D.body_get_mode(body.get_rid()) == PhysicsServer3D.BODY_MODE_RIGID
		initially_inactive = initially_inactive and PhysicsServer3D.body_get_state(body.get_rid(),PhysicsServer3D.BODY_STATE_SLEEPING)
	check(initially_inactive and not helper.native_awake_observed, label + " reproduces Jolt pre-step inactivity")
	var initial := helper.latest_global_poses.duplicate()
	# Repeated calls without a physics step must not turn a guessed frame delay
	# into apparent readiness. No native simulation time elapses in this loop.
	for call in 4: helper.tick(STEP)
	check(helper.active and not helper.frozen and not helper.engine_sleeping and not helper.native_awake_observed,
		label + " startup inactivity never counts as settled sleep")
	var signals := {"count":0}
	actor.rig.skeleton.skeleton_updated.connect(func(): signals.count += 1)
	var moved := false
	var frozen_frame := -1
	for frame in MAX_TICKS:
		await physics_frame
		helper.tick(STEP)
		moved = moved or helper.latest_global_poses != initial
		if helper.frozen:
			frozen_frame = frame
			break
	check(frozen_frame >= 0 and moved and helper.native_awake_observed and helper.engine_sleeping,
		label + " real native awake/fall/sleep completes within the bounded deadline")
	if helper.frozen: await frozen_probe(helper,actor,Geometry.capture(actor.rig),signals,label)
	readiness_rows.append({"team":team,"idle_activation":idle_activation,"initially_inactive":initially_inactive,
		"calls_before_step":4,"native_awake_observed":helper.native_awake_observed,"moved":moved,"frozen_frame":frozen_frame})
	helper.dispose()
	fixture.free()
	await process_frame

func geometry_weight_checks() -> void:
	check(Geometry.weight_sum_supported(1.0), "normalized weight sum is supported")
	var halves := PackedFloat32Array([32767.0/65535.0,32767.0/65535.0])
	check(absf(halves[0]+halves[1]-1.0) > 0.00001 and Geometry.weight_sum_supported(halves[0]+halves[1]),
		"actual two-weight UNORM16 truncation exceeds obsolete 1e-5 but remains valid")
	check(Geometry.weight_sum_supported(4.0*16383.0/65535.0), "four truncated normalized weights stay supported")
	check(not Geometry.weight_sum_supported(1.0-5.0/65535.0), "excess weight deficit is not hidden by quantization allowance")
	check(not Geometry.weight_sum_supported(1.001) and not Geometry.weight_sum_supported(0.0)
		and not Geometry.weight_sum_supported(INF) and not Geometry.weight_sum_supported(NAN), "invalid weight sums remain rejected")

func run() -> void:
	var started := Time.get_ticks_usec()
	var probe := Node3D.new()
	root.add_child(probe)
	backend = str(probe.get_world_3d().direct_space_state.get_class())
	probe.free()
	var configured := str(ProjectSettings.get_setting("physics/3d/physics_engine"))
	var slop := float(ProjectSettings.get_setting("physics/jolt_physics_3d/simulation/penetration_slop"))
	check(backend == "JoltPhysicsDirectSpaceState3D" and configured == "Jolt Physics" and slop == 0.005,
		"caller supplies actual Jolt backend with 5 mm penetration slop")
	check(Engine.physics_ticks_per_second == 60, "caller supplies 60 Hz physics")
	if failed > 0:
		print("DEATH_PHYSICS: ", passed, "/", passed + failed, " passed; cases=0/22")
		quit(1)
		return
	geometry_weight_checks()
	for team in ["ct", "t"]:
		for idle_activation in [false,true]: await readiness_case(team,idle_activation)
	check(readiness_rows.size() == 4, "all sequential physics/idle startup regression cases completed")
	for team in ["ct", "t"]:
		await measure_case(team, "flat", 0)
		for distance in [0.326, 0.476]:
			for yaw in [90, 135, 180]: await measure_case(team, "wall", yaw, distance)
		for yaw in [0, 90, 180, 270]: await measure_case(team, "ramp", yaw)
		for mode in ["dispose", "owner_free", "owner_remove", "refcount"]: await cleanup_case(team, mode)
	check(rows.size() == 22 and completed.size() == 22, "all exact 22 requested contact cases completed")
	var output := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="): output = argument.trim_prefix("--output=")
	if not output.is_empty():
		var file := FileAccess.open(output, FileAccess.WRITE)
		check(file != null, "optional artifact output opens")
		if file != null:
			file.store_string(JSON.stringify({"backend": backend, "penetration_slop": slop, "cases": rows,"readiness_cases":readiness_rows,
				"passed": passed, "failed": failed, "elapsed_seconds": (Time.get_ticks_usec() - started) / 1000000.0,
				"measurement": "Original indexed skinned body/rifle vertices at native physics tick snapshots; supporting planes, not continuous CCD. Initial live-pose violations separate. Elapsed time is whole-suite runtime, not solver cost or FPS."}, "  "))
			file.close()
	print("DEATH_PHYSICS: ", passed, "/", passed + failed, " passed; cases=", rows.size(), "/22; elapsed_s=", (Time.get_ticks_usec() - started) / 1000000.0)
	quit(1 if failed else 0)
