class_name FieldOperatorRig
extends RefCounted

const FootPlacement = preload("res://scripts/foot_placement.gd")
const Layout = preload("res://scripts/layout.gd")
const WeaponClearance = preload("res://scripts/weapon_clearance.gd")
const CORPSE_SETTLE_SECONDS := 1.0

class Limb:
	var upper: int
	var lower: int
	var end: int
	var first: float
	var second: float
	var upper_direction: Vector3
	var lower_direction: Vector3

## Eighteen cached bones, analytical two-link IK, no animation textures/clips,
## Visual poses never move an actor's hit capsule. Weapon clearance is a
## separate cached hull query; feet still use the analytical floor sampler.
var skeleton: Skeleton3D
var model: Node3D
var ids: Dictionary = {}
var rest: Array[Transform3D] = []
var local_rest: Array[Transform3D] = []
var pose: Array[Transform3D] = []
var parents: PackedInt32Array = []
var phase := 0.0
var motion := Vector3.ZERO
var aim := Vector2.ZERO
var recoil := 0.0
var reload_blend := 0.0
var fall := 0.0
var clock := 0.0
var last_yaw := 0.0
var turn := 0.0
var flash: MeshInstance3D
var flash_left := 0.0
var grounding := FootPlacement.new()
var foot_rests: Array[Transform3D] = []
var foot_targets: Array[Transform3D] = []
var arms: Array[Limb] = []
var legs: Array[Limb] = []
var weapon_rest_inverse: Transform3D
var weapon_clearance := WeaponClearance.new()
var corpse_sleeping := false
var corpse_time := 0.0
var corpse_body := Transform3D.IDENTITY
var corpse_model := Transform3D.IDENTITY
var root_pose_only := false

func setup(root: Node3D) -> void:
	model = root
	skeleton = root.find_children("*", "Skeleton3D", true, false)[0]
	for i in skeleton.get_bone_count():
		ids[skeleton.get_bone_name(i)] = i
		rest.append(skeleton.get_bone_global_rest(i))
		local_rest.append(skeleton.get_bone_rest(i))
		pose.append(rest[i])
		parents.append(skeleton.get_bone_parent(i))
	for side in ["l", "r"]:
		foot_rests.append(rest[ids["foot_" + side]])
		arms.append(cache_limb(ids["upperarm_" + side],ids["forearm_" + side],ids["hand_" + side]))
		legs.append(cache_limb(ids["thigh_" + side],ids["shin_" + side],ids["foot_" + side]))
	weapon_rest_inverse = rest[ids.weapon].affine_inverse()
	weapon_clearance.configure(WeaponClearance.skinned_bounds(root, skeleton, ids.weapon))
	flash = MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.025
	mesh.height = 0.05
	mesh.radial_segments = 8
	mesh.rings = 4
	flash.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color("ffd889")
	flash.material_override = material
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flash.visible = false
	model.add_child(flash)
	root_pose_only = can_reset_root_only()

func can_reset_root_only() -> bool:
	# update_pose writes every listed descendant before reading it. Unknown
	# accessories or parent relationships still use the full inherited pose.
	var expected := {"pelvis":"", "spine":"pelvis", "chest":"spine", "neck":"chest", "head":"neck", "weapon":"chest"}
	for side in ["l", "r"]:
		expected["upperarm_"+side] = "chest"
		expected["forearm_"+side] = "upperarm_"+side
		expected["hand_"+side] = "forearm_"+side
		expected["thigh_"+side] = "pelvis"
		expected["shin_"+side] = "thigh_"+side
		expected["foot_"+side] = "shin_"+side
	if ids.size() != expected.size() or parents.size() != expected.size(): return false
	for name: String in expected:
		if not ids.has(name): return false
		var parent_name: String = expected[name]
		if not parent_name.is_empty() and not ids.has(parent_name): return false
		if parents[ids[name]] != (-1 if parent_name.is_empty() else ids[parent_name]): return false
	return true

func cache_limb(upper: int, lower: int, end: int) -> Limb:
	var limb := Limb.new()
	limb.upper = upper
	limb.lower = lower
	limb.end = end
	var first := rest[lower].origin - rest[upper].origin
	var second := rest[end].origin - rest[lower].origin
	limb.first = first.length()
	limb.second = second.length()
	limb.upper_direction = first.normalized()
	limb.lower_direction = second.normalized()
	return limb

func on_shot() -> void:
	corpse_sleeping = false
	corpse_time = 0.0
	recoil = 1
	flash_left = 0.045

func inherit_pose() -> void:
	for i in pose.size():
		pose[i] = local_rest[i] if parents[i] < 0 else pose[parents[i]] * local_rest[i]

func rotate_bone(bone: String, rotation: Vector3) -> void:
	var id: int = ids[bone]
	pose[id] = pose[parents[id]] * local_rest[id] * Transform3D(Basis.from_euler(rotation), Vector3.ZERO)

static func joint_at(start: Vector3, end: Vector3, pole: Vector3, first: float, second: float) -> Vector3:
	var offset := end - start
	var distance := offset.length()
	var length := clampf(distance, 0.001, first + second - 0.001)
	var direction := offset / distance if distance > 0.001 else Vector3.DOWN
	var along := (first * first - second * second + length * length) / (2 * length)
	var perpendicular := pole - start
	perpendicular -= direction * perpendicular.dot(direction)
	if perpendicular.length_squared() < 0.00001:
		perpendicular = direction.cross(Vector3.RIGHT)
		if perpendicular.length_squared() < 0.00001: perpendicular = direction.cross(Vector3.UP)
	return start + direction * along + perpendicular.normalized() * sqrt(maxf(0, first * first - along * along))

func solve_limb(limb: Limb, goal: Transform3D, pole: Vector3) -> void:
	var a := limb.upper
	var b := limb.lower
	var c := limb.end
	# Only the joint position is used; do not multiply and discard two bases.
	var start := pose[parents[a]] * local_rest[a].origin
	var first := limb.first
	var second := limb.second
	var target := start + (goal.origin - start).limit_length(first + second - 0.001)
	var joint := joint_at(start, target, pole, first, second)
	pose[a] = Transform3D(Basis(Quaternion(limb.upper_direction, (joint - start).normalized())) * rest[a].basis, start)
	pose[b] = Transform3D(Basis(Quaternion(limb.lower_direction, (target - joint).normalized())) * rest[b].basis, joint)
	pose[c] = Transform3D(goal.basis, target)

func flush() -> void:
	# Compute locally once; avoid per-bone dirty global-pose recalculations.
	for i in pose.size():
		var local := pose[i] if parents[i] < 0 else pose[parents[i]].affine_inverse() * pose[i]
		skeleton.set_bone_pose(i, local)

func animate(dt: float, actor: Node3D) -> void:
	if actor.game.paused: return
	var dead: bool = actor.health <= 0
	var body := actor.global_transform
	# Corpses no longer need breathing/IK or repeated static-map weapon queries
	# once the fall and clearance have settled. Keep _process enabled so moving
	# the actor/model or changing health wakes it on the next unpaused frame.
	if not dead or body != corpse_body or model.transform != corpse_model or not weapon_clearance.clear:
		corpse_sleeping = false
		corpse_time = 0.0
	if corpse_sleeping: return
	var inverse_basis: Basis = actor.global_basis.inverse()
	var relative: Vector3 = inverse_basis * (actor.look_goal - actor.eye())
	var look := Vector2(atan2(relative.y, Vector2(relative.x, relative.z).length()), atan2(-relative.x, -relative.z))
	var moving: Vector3 = inverse_basis * actor.velocity if actor.game.phase == "LIVE" else Vector3.ZERO
	var yaw_rate := angle_difference(last_yaw, actor.rotation.y) / maxf(dt, 0.001)
	last_yaw = actor.rotation.y
	var working: bool = actor.role == "DEFUSE" and actor.game.defuser == actor
	if actor.game.objective.carrier == actor and actor.game.objective.plant_progress > 0: working = true
	update_pose(dt, moving, look, actor.reload_left, working, dead, yaw_rate,
		body, Layout.floor_height, actor.get_world_3d().direct_space_state)
	if dead:
		corpse_body = body
		corpse_model = model.transform
		corpse_time += maxf(dt, 0)
		corpse_sleeping = corpse_time >= CORPSE_SETTLE_SECONDS and fall == 1 \
			and weapon_clearance.clear and flash_left == 0 and not flash.visible

func update_pose(dt: float, velocity: Vector3, look: Vector2, reload_left: float, working: bool, dead: bool, yaw_rate: float = 0,
		body := Transform3D.IDENTITY, height := Callable(), space: PhysicsDirectSpaceState3D = null) -> void:
	# Explicit pose fixtures/callers remain unconditional and invalidate sleep.
	if corpse_sleeping:
		corpse_sleeping = false
		corpse_time = 0.0
	clock += dt
	var blend := 1 - exp(-dt * 12)
	motion = motion.lerp(Vector3(velocity.x, 0, velocity.z), blend)
	aim = aim.lerp(Vector2(clampf(look.x, -0.6, 0.6), clampf(look.y, -0.65, 0.65)), blend)
	turn = lerpf(turn, clampf(yaw_rate, -3, 3), blend)
	reload_blend = move_toward(reload_blend, 1 if reload_left > 0 else 0, dt * 5)
	recoil = move_toward(recoil, 0, dt * 9)
	flash_left = maxf(0, flash_left - dt)
	flash.visible = flash_left > 0 and not dead
	var speed := Vector2(motion.x, motion.z).length()
	var motion_direction := motion.normalized()
	var amount := clampf(speed / 4.65, 0, 1)
	# A slow walk uses shorter steps. Phase follows real movement, not wall time.
	var stride := lerpf(0.55, 1.95, amount)
	if height.is_valid() and speed > 0.18 and not grounding.walking:
		# Begin with a short first stance. Otherwise an accelerating actor can
		# travel an entire half-stride past a foot still planted at its spawn.
		phase = 0.30 + (0.5 if grounding.next_foot == 1 else 0)
	phase = fposmod(phase + speed * dt / stride, 1)
	foot_targets.clear()
	for i in 2:
		var foot := foot_rests[i]
		var step := fposmod(phase + (0.5 if i == 0 else 0), 1)
		var along: float
		var lift := 0.0
		if step < 0.46:
			along = 0.5 - step / 0.46
		else:
			var swing := (step - 0.46) / 0.54
			along = -0.5 + smoothstep(0, 1, swing)
			lift = sin(swing * PI) * 0.15 * amount
		foot.origin += motion_direction * along * stride * 0.46 * minf(speed / 0.5, 1)
		foot.origin.y += lift
		foot.basis = Basis(Vector3.RIGHT, -lift * 0.8) * foot.basis
		foot_targets.append(foot)
	if height.is_valid() and not dead:
		foot_targets = grounding.update(dt, body, foot_targets, foot_rests, phase, speed, height)
	if root_pose_only: pose[ids.pelvis] = local_rest[ids.pelvis]
	else: inherit_pose()
	var pelvis: int = ids.pelvis
	pose[pelvis].origin.y -= 0.025 + amount * (0.10 + absf(sin(phase * TAU * 2)) * 0.018)
	# Let the lower foot reach downhill ground without stretching the leg.
	var ground_drop := minf(foot_targets[0].origin.y-foot_rests[0].origin.y,
		foot_targets[1].origin.y-foot_rests[1].origin.y)
	pose[pelvis].origin.y += clampf(ground_drop, -0.18, 0)
	if height.is_valid():
		var reachable_y := pose[pelvis].origin.y
		for i in 2:
			var leg := legs[i]
			var hip: Transform3D = rest[leg.upper]
			var length := leg.first + leg.second - 0.003
			var across := Vector2(foot_targets[i].origin.x-hip.origin.x,foot_targets[i].origin.z-hip.origin.z).length_squared()
			reachable_y = minf(reachable_y,foot_targets[i].origin.y+sqrt(maxf(0,length*length-across)))
		# Small weight shifts keep accelerating strides reachable without either
		# stretching a knee or silently lifting a planted sole off the floor.
		pose[pelvis].origin.y = maxf(reachable_y,pose[pelvis].origin.y-0.08)
	pose[pelvis].basis = Basis.from_euler(Vector3(-amount * 0.07, -turn * 0.025, -motion.x * 0.008))
	rotate_bone("spine", Vector3(aim.x * 0.3 - (0.12 if working else 0), aim.y * 0.35, sin(phase * TAU) * amount * 0.025))
	rotate_bone("chest", Vector3(aim.x * 0.35, aim.y * 0.3, 0))
	rotate_bone("neck", Vector3(aim.x * 0.1, aim.y * 0.15, 0))
	rotate_bone("head", Vector3(aim.x * 0.15 + sin(clock * 2.2) * 0.007, aim.y * 0.2, 0))
	var chest: int = ids.chest
	var weapon: int = ids.weapon
	var weapon_rest := pose[chest] * local_rest[weapon]
	# Rotate the whole weapon + both hand targets about the shoulder, not its muzzle.
	var shoulder := pose[chest] * Vector3(0.13, 0.10, 0)
	var gun_rotation := Basis.from_euler(Vector3(aim.x * 0.25 + recoil * 0.045 - reload_blend * 0.28 - (0.2 if working else 0), 0, reload_blend * 0.3))
	pose[weapon] = Transform3D(gun_rotation * weapon_rest.basis,
		shoulder + gun_rotation * (weapon_rest.origin - shoulder) + Vector3(0, sin(clock * 2.2) * 0.004, recoil * 0.018))
	var gun_delta := pose[weapon] * weapon_rest_inverse
	if dead:
		fall = minf(1, fall + dt * 2.4)
		var eased := smoothstep(0, 1, fall)
		model.rotation.x = -eased * PI * 0.5
		model.position.y = eased * 0.2
	if space != null:
		var basis := body.basis * Basis(Vector3.RIGHT, -PI * 0.5)
		var center := body * Vector3(0.08, 1.15, -0.04)
		var safe := Transform3D(basis, center - basis * weapon_clearance.bounds.get_center())
		var frame := skeleton.global_transform
		var resolved := weapon_clearance.resolve(space, frame * gun_delta, safe, body * Vector3(0, 1.4, 0), dt)
		if weapon_clearance.amount > 0 or not weapon_clearance.clear:
			gun_delta = frame.affine_inverse() * resolved
			pose[weapon] = gun_delta * rest[weapon]
		flash.visible = flash.visible and weapon_clearance.clear
	for i in 2:
		var hand := gun_delta * rest[arms[i].end]
		if i == 0 and reload_blend > 0:
			# Support hand reaches toward the magazine, trigger hand stays on grip.
			var reload_reach := sin(clampf(reload_left / 2.2, 0, 1) * PI) * reload_blend
			hand.origin = hand.origin.lerp(gun_delta * Vector3(0.13, 1.20, -0.335), reload_reach)
		var sign := -1.0 if i == 0 else 1.0
		var pole := pose[chest] * Vector3(sign * 0.45, -0.32, -0.05)
		solve_limb(arms[i], hand, pole)
		solve_limb(legs[i], foot_targets[i], Vector3(sign * 0.13, 0.5, -1))
	flash.position = gun_delta * Vector3(0.13, 1.425, -0.795)
	flash.basis = gun_delta.basis.scaled(Vector3(0.8, 0.8, 2))
	flush()
