extends RefCounted

# Test-only, lazy handoff from the current animated pose. Callers must stop
# procedural rig updates until disposal. No production hook or backend switch.
# Requires Jolt Physics with 5 mm slop and CCD movement threshold 0.25 at startup.
# The rifle falls independently; it is not constrained to either hand.
const BODY_NAMES := ["pelvis", "chest", "head", "upperarm_l", "forearm_l", "upperarm_r", "forearm_r", "thigh_l", "shin_l", "thigh_r", "shin_r", "weapon"]
const HULL_PAD := 0.012
const PENETRATION_SLOP := 0.005
const CCD_MOVEMENT_THRESHOLD := 0.25
const CCD_SETTING := "physics/jolt_physics_3d/simulation/continuous_cd_movement_threshold"

# Node references do not retain the RefCounted rig that may own this helper.
var model: Node3D
var skeleton: Skeleton3D
var simulator: PhysicalBoneSimulator3D
var bodies: Array[PhysicalBone3D] = []
# Skeleton-space global poses, captured while the modifier owns the bones.
var latest_global_poses: Array[Transform3D] = []
var active := false
var paused := false
var frozen := false
var engine_sleeping := false
var native_awake_observed := false
var body_count := 0
var joint_count := 0
var modifier_updates := 0
var activation_usec := 0
var last_error := ""
var _old_callback := Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_IDLE
var _paused_states: Array[Dictionary] = []

func activate(source_rig: RefCounted, velocity := Vector3.ZERO) -> bool:
	last_error = ""
	if active or is_instance_valid(simulator):
		return _reject("Death physics is already active")
	if ProjectSettings.get_setting_with_override("physics/3d/physics_engine") != "Jolt Physics":
		return _reject("Death physics requires Jolt Physics at engine startup")
	if not ProjectSettings.has_setting("physics/jolt_physics_3d/simulation/penetration_slop") or absf(float(ProjectSettings.get_setting_with_override("physics/jolt_physics_3d/simulation/penetration_slop")) - PENETRATION_SLOP) > 0.0000001:
		return _reject("Death physics requires 0.005 m Jolt penetration slop at engine startup")
	# The default 0.75 skips a forearm's ~50 mm impact translation at 60 Hz:
	# its threshold is ~65 mm, allowing a rotating corner through the floor.
	# This is an isolated test-project requirement, never a runtime mutation.
	if ProjectSettings.get_setting_with_override(CCD_SETTING) != CCD_MOVEMENT_THRESHOLD:
		return _reject("Death physics requires 0.25 Jolt CCD movement threshold at engine startup")
	if not is_instance_valid(source_rig) or not velocity.is_finite():
		return _reject("Death physics requires a valid rig and finite velocity")
	var source_model := source_rig.get("model") as Node3D
	var source_skeleton := source_rig.get("skeleton") as Skeleton3D
	if not is_instance_valid(source_model) or not is_instance_valid(source_skeleton) or not source_skeleton.is_inside_tree() or source_skeleton.is_queued_for_deletion():
		return _reject("Death physics requires an in-tree operator skeleton")
	# The generic PhysicsServer3D wrapper hides its backend. Its world's direct
	# space state identifies the actual implementation, including silent fallback.
	if source_skeleton.get_world_3d().direct_space_state.get_class() != "JoltPhysicsDirectSpaceState3D":
		return _reject("The operator world is not running Jolt Physics")
	if source_skeleton.get_bone_count() != 18:
		return _reject("Death physics supports the current 18-bone operator only")
	for name in BODY_NAMES:
		if source_skeleton.find_bone(name) < 0:
			return _reject("Missing operator bone: " + name)
	var owner_for_bone: Array[int] = []
	for bone in source_skeleton.get_bone_count():
		var owner := bone
		while owner >= 0 and source_skeleton.get_bone_name(owner) not in BODY_NAMES:
			owner = source_skeleton.get_bone_parent(owner)
		if owner < 0:
			return _reject("Operator bone has no supported physical ancestor")
		owner_for_bone.append(owner)

	var started := Time.get_ticks_usec()
	model = source_model
	skeleton = source_skeleton
	latest_global_poses.clear()
	for bone in skeleton.get_bone_count():
		latest_global_poses.append(skeleton.get_bone_global_pose(bone))
	var points := _skin_influence_points(owner_for_bone)
	for name in BODY_NAMES:
		if points[skeleton.find_bone(name)].is_empty():
			model = null
			skeleton = null
			latest_global_poses.clear()
			return _reject("Operator physical hull has no indexed skin vertices: " + name)

	body_count = 0
	joint_count = 0
	modifier_updates = 0
	activation_usec = 0
	frozen = false
	paused = false
	engine_sleeping = false
	native_awake_observed = false
	_paused_states.clear()
	_old_callback = skeleton.modifier_callback_mode_process
	skeleton.modifier_callback_mode_process = Skeleton3D.MODIFIER_CALLBACK_MODE_PROCESS_MANUAL
	simulator = PhysicalBoneSimulator3D.new()
	simulator.name = "DeathOnlyPhysics"
	simulator.active = false
	skeleton.add_child(simulator)
	for name in BODY_NAMES:
		var bone := skeleton.find_bone(name)
		var pb := PhysicalBone3D.new()
		pb.name = "Body_" + name
		pb.bone_name = name
		pb.collision_layer = 16
		pb.collision_mask = 1 # Static world only: never obstruct living actors.
		pb.mass = 12.0 if name == "pelvis" else (18.0 if name == "chest" else (7.0 if name.begins_with("thigh") else (4.0 if name == "head" or name.begins_with("shin") else 2.0)))
		pb.friction = 0.85
		pb.bounce = 0.0
		pb.linear_damp = 0.35
		pb.angular_damp = 1.3
		pb.can_sleep = true
		var vertices: PackedVector3Array = points[bone]
		var bounds := AABB(vertices[0], Vector3.ZERO)
		for point in vertices:
			bounds = bounds.expand(point)
		pb.body_offset = Transform3D(Basis.IDENTITY, bounds.get_center())
		var shape := BoxShape3D.new()
		shape.size = bounds.size + Vector3.ONE * HULL_PAD * 2
		var collision := CollisionShape3D.new()
		collision.shape = shape
		pb.add_child(collision)
		simulator.add_child(pb)
		if name not in ["pelvis", "weapon"]:
			pb.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
			pb.set("joint_constraints/swing_span", 35.0 if name in ["chest", "head"] else 80.0)
			pb.set("joint_constraints/twist_span", 20.0 if name in ["chest", "head"] else 35.0)
			joint_count += 1
		bodies.append(pb)
		PhysicsServer3D.body_set_enable_continuous_collision_detection(pb.get_rid(), true)
	simulator.modification_processed.connect(_capture_modified_pose)
	skeleton.tree_exiting.connect(dispose)
	simulator.active = true
	simulator.physical_bones_start_simulation()
	for pb in bodies:
		pb.linear_velocity = velocity
	active = true
	body_count = bodies.size()
	var flash := source_rig.get("flash") as MeshInstance3D
	if is_instance_valid(flash):
		flash.visible = false
	activation_usec = Time.get_ticks_usec() - started
	return true

func _reject(reason: String) -> bool:
	last_error = reason
	return false

func _skin_influence_points(owners: Array[int]) -> Dictionary:
	var unique: Dictionary = {}
	for name in BODY_NAMES:
		unique[skeleton.find_bone(name)] = {}
	for node: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if node.skin == null:
			continue
		var mapped: Array = []
		for bind in node.skin.get_bind_count():
			var bone := node.skin.get_bind_bone(bind)
			if not node.skin.get_bind_name(bind).is_empty():
				bone = skeleton.find_bone(node.skin.get_bind_name(bind))
			var owner: int = owners[bone]
			mapped.append({"owner": owner, "transform": latest_global_poses[owner].affine_inverse() * latest_global_poses[bone] * node.skin.get_bind_pose(bind)})
		for surface in node.mesh.get_surface_count():
			var arrays := node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			var indexed: Dictionary = {}
			for index in arrays[Mesh.ARRAY_INDEX]:
				indexed[index] = true
			for index: int in indexed:
				for influence in 4:
					if weights[index * 4 + influence] <= 0:
						continue
					var bind := joints[index * 4 + influence]
					var point: Vector3 = mapped[bind].transform * vertices[index]
					unique[mapped[bind].owner][point] = true
	var result := {}
	for bone: int in unique:
		var vertices := PackedVector3Array()
		for point: Vector3 in unique[bone]:
			vertices.append(point)
		result[bone] = vertices
	return result

func _capture_modified_pose() -> void:
	if not active or paused:
		return
	latest_global_poses.clear()
	for bone in skeleton.get_bone_count():
		latest_global_poses.append(skeleton.get_bone_global_pose(bone))
	modifier_updates += 1

func tick(dt: float) -> void:
	if not active or paused:
		return
	if not is_instance_valid(skeleton) or not is_instance_valid(simulator):
		dispose()
		return
	var all_sleeping := true
	for pb in bodies:
		if not PhysicsServer3D.body_get_state(pb.get_rid(), PhysicsServer3D.BODY_STATE_SLEEPING):
			all_sleeping = false
			native_awake_observed = true
			break
	# Jolt's newly added RIGID bodies report inactive before their first step.
	# An idle-frame activation can reach tick() in this state even after a
	# modifier callback. Observe the native awake -> asleep lifecycle instead
	# of interpreting startup inactivity as settlement or guessing a delay.
	engine_sleeping = native_awake_observed and all_sleeping
	if engine_sleeping:
		bake_and_stop()
	else:
		skeleton.advance(dt)

func set_paused(value: bool) -> void:
	if not active or paused == value:
		return
	paused = value
	if paused:
		# Drain ownership immediately: a queued modifier cannot move the visible
		# pose or readback after this call. Preserve the last complete snapshot.
		simulator.active = false
		_write_pose(latest_global_poses)
		_paused_states.clear()
		for pb in bodies:
			var rid := pb.get_rid()
			_paused_states.append({"transform": PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM), "linear": PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY), "angular": PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)})
			PhysicsServer3D.body_set_mode(rid, PhysicsServer3D.BODY_MODE_STATIC)
	else:
		for i in bodies.size():
			var rid := bodies[i].get_rid()
			PhysicsServer3D.body_set_mode(rid, PhysicsServer3D.BODY_MODE_RIGID)
			PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, _paused_states[i].transform)
			PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, _paused_states[i].linear)
			PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, _paused_states[i].angular)
			PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING, false)
		_paused_states.clear()
		engine_sleeping = false
		simulator.active = true

func _write_pose(global_poses: Array[Transform3D]) -> void:
	for bone in skeleton.get_bone_count():
		var parent := skeleton.get_bone_parent(bone)
		var local := global_poses[bone] if parent < 0 else global_poses[parent].affine_inverse() * global_poses[bone]
		skeleton.set_bone_pose(bone, local)

func bake_and_stop() -> void:
	if not active:
		return
	# Bake the last visible modifier snapshot, not a newer server transform.
	active = false
	paused = false
	if is_instance_valid(simulator):
		if simulator.modification_processed.is_connected(_capture_modified_pose):
			simulator.modification_processed.disconnect(_capture_modified_pose)
		simulator.physical_bones_stop_simulation()
		simulator.active = false
		if simulator.get_parent() != null:
			simulator.get_parent().remove_child(simulator)
		simulator.free()
	simulator = null
	bodies.clear()
	_paused_states.clear()
	if is_instance_valid(skeleton):
		if skeleton.tree_exiting.is_connected(dispose):
			skeleton.tree_exiting.disconnect(dispose)
		_write_pose(latest_global_poses)
		skeleton.modifier_callback_mode_process = _old_callback
	frozen = true

func dispose() -> void:
	bake_and_stop()
	model = null
	skeleton = null

func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or not active:
		return
	# RefCounted self already has zero references here. Calling a GDScript
	# method (or creating a Callable to self) resolves to a null instance.
	# Keep this final safety net inline; native Object destruction removes
	# our signal connections after this notification returns.
	active = false
	if is_instance_valid(simulator):
		simulator.physical_bones_stop_simulation()
		simulator.active = false
		if simulator.get_parent() != null:
			simulator.get_parent().remove_child(simulator)
		simulator.free()
	simulator = null
	bodies.clear()
	if is_instance_valid(skeleton):
		for bone in skeleton.get_bone_count():
			var parent := skeleton.get_bone_parent(bone)
			var local := latest_global_poses[bone] if parent < 0 else latest_global_poses[parent].affine_inverse() * latest_global_poses[bone]
			skeleton.set_bone_pose(bone, local)
		skeleton.modifier_callback_mode_process = _old_callback
