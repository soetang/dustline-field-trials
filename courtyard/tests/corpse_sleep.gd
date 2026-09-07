extends SceneTree

## Real pose/IK/physics work, counted rather than timed. No renderer is used.
const Models = preload("res://scripts/models.gd")
const Rig = preload("res://scripts/operator_rig.gd")
const Layout = preload("res://scripts/layout.gd")
const Clearance = preload("res://scripts/weapon_clearance.gd")
const DT := 1.0 / 60.0

class CountingClearance:
	extends Clearance
	var calls := 0
	var total_queries := 0
	func resolve(space: PhysicsDirectSpaceState3D, desired: Transform3D, safe: Transform3D, anchor: Vector3, dt: float) -> Transform3D:
		calls += 1
		var result := super.resolve(space, desired, safe, anchor, dt)
		total_queries += queries
		return result

class CountingRig:
	extends Rig
	var updates := 0
	var flushes := 0
	var bone_writes := 0
	var limb_solves := 0
	var skeleton_updates := 0
	func _init() -> void:
		weapon_clearance = CountingClearance.new()
	func update_pose(dt: float, velocity: Vector3, look: Vector2, reload_left: float, working: bool, dead: bool, yaw_rate: float = 0,
			body := Transform3D.IDENTITY, height := Callable(), space: PhysicsDirectSpaceState3D = null) -> void:
		updates += 1
		super.update_pose(dt, velocity, look, reload_left, working, dead, yaw_rate, body, height, space)
	func flush() -> void:
		flushes += 1
		bone_writes += pose.size()
		super.flush()
	func solve_limb(limb: Limb, goal: Transform3D, pole: Vector3) -> void:
		limb_solves += 1
		super.solve_limb(limb, goal, pole)
	func skeleton_updated() -> void:
		skeleton_updates += 1

class Fixture:
	extends Node3D
	var paused := false
	var phase := "LIVE"
	var defuser: Node3D
	var objective := {"carrier": null, "plant_progress": 0.0}

class Actor:
	extends CharacterBody3D
	var game: Fixture
	var health := 100.0
	var look_goal := Vector3(0, 1.52, -10)
	var role := "ATTACK"
	var reload_left := 0.0
	var eye_calls := 0
	var model: Node3D
	var rig := CountingRig.new()
	func eye() -> Vector3:
		eye_calls += 1
		return global_position + Vector3.UP * 1.52

var passed := 0
var failed := 0
var fixture: Fixture

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("FAIL: ", message)

func actor_for(team: String) -> Actor:
	var actor := Actor.new()
	actor.game = fixture
	actor.collision_layer = 4
	actor.collision_mask = 1
	fixture.add_child(actor)
	var collision := CollisionShape3D.new()
	collision.shape = CapsuleShape3D.new()
	collision.position.y = 0.9
	actor.add_child(collision)
	actor.model = Models.ASSETS[team + "_operator"].instantiate()
	actor.add_child(actor.model)
	Models.prepare(actor.model)
	actor.rig.setup(actor.model)
	actor.rig.skeleton.skeleton_updated.connect(actor.rig.skeleton_updated)
	return actor

func box(at: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	fixture.add_child(body)
	body.position = at
	return body

func legacy_animate(dt: float, actor: Actor) -> void:
	# Frozen pre-sleep animate path, calling the same actual update_pose body.
	# This checks live/transition outputs independently of the new sleep gate.
	if actor.game.paused: return
	var rig := actor.rig
	var inverse_basis: Basis = actor.global_basis.inverse()
	var relative: Vector3 = inverse_basis * (actor.look_goal - actor.eye())
	var look := Vector2(atan2(relative.y, Vector2(relative.x, relative.z).length()), atan2(-relative.x, -relative.z))
	var moving: Vector3 = inverse_basis * actor.velocity if actor.game.phase == "LIVE" else Vector3.ZERO
	var yaw_rate := angle_difference(rig.last_yaw, actor.rotation.y) / maxf(dt, 0.001)
	rig.last_yaw = actor.rotation.y
	var working: bool = actor.role == "DEFUSE" and actor.game.defuser == actor
	if actor.game.objective.carrier == actor and actor.game.objective.plant_progress > 0: working = true
	rig.update_pose(dt, moving, look, actor.reload_left, working, actor.health <= 0, yaw_rate,
		actor.global_transform, Layout.floor_height, actor.get_world_3d().direct_space_state)

func counters(actor: Actor) -> PackedInt64Array:
	var rig := actor.rig
	return PackedInt64Array([rig.updates, rig.flushes, rig.bone_writes, rig.limb_solves,
		rig.weapon_clearance.calls, rig.weapon_clearance.total_queries, actor.eye_calls])

func local_bones(rig: CountingRig) -> Array[Transform3D]:
	var result: Array[Transform3D] = []
	for bone in rig.skeleton.get_bone_count(): result.append(rig.skeleton.get_bone_pose(bone))
	return result

func pose_state(actor: Actor) -> Array:
	var rig := actor.rig
	return [rig.pose.duplicate(), local_bones(rig), actor.model.transform, rig.clock, rig.phase,
		rig.motion, rig.aim, rig.turn, rig.reload_blend, rig.recoil, rig.flash_left,
		rig.flash.visible, rig.flash.transform, rig.fall, rig.weapon_clearance.amount, rig.weapon_clearance.clear]

func settle(actor: Actor) -> int:
	var frames := 0
	while not actor.rig.corpse_sleeping and frames < 180:
		actor.rig.animate(DT, actor)
		frames += 1
	return frames

func final_hull_clear(actor: Actor) -> bool:
	# Independent final stored-pose query, not the cached `clear` flag. Include
	# the solver's padding and connection ray against the real floor/wall.
	var rig := actor.rig
	var query := PhysicsShapeQueryParameters3D.new()
	var shape := BoxShape3D.new()
	shape.size = rig.weapon_clearance.bounds.size + Vector3.ONE * Clearance.SKIN * 2
	query.shape = shape
	query.collision_mask = 1
	query.collide_with_areas = false
	query.margin = 0
	var gun := rig.skeleton.global_transform * rig.pose[rig.ids.weapon] * rig.rest[rig.ids.weapon].affine_inverse()
	query.transform = Transform3D(gun.basis, gun * rig.weapon_clearance.bounds.get_center())
	var space := actor.get_world_3d().direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(actor.global_transform * Vector3(0, 1.4, 0), query.transform.origin, 1)
	ray.hit_from_inside = true
	return space.intersect_shape(query, 1).is_empty() and space.intersect_ray(ray).is_empty()

func inspect(team: String) -> void:
	var actor := actor_for(team)
	var original := actor_for(team)
	var same_live := true
	for frame in 120:
		fixture.paused = frame % 9 == 4
		fixture.phase = "BUY" if frame < 10 else "LIVE"
		for current in [actor, original]:
			current.rotation.y = sin(frame * 0.01) * 0.3
			current.velocity = Vector3(1.2, 0, -1.5) if frame < 60 else Vector3.ZERO
			current.look_goal = Vector3(sin(frame * 0.02), 1.52 + cos(frame * 0.03), -10)
			current.reload_left = 1.1 if frame > 40 and frame < 80 else 0.0
			current.role = "DEFUSE" if frame > 100 else "ATTACK"
			fixture.defuser = current
			fixture.objective.carrier = current if frame > 85 and frame < 95 else null
			fixture.objective.plant_progress = 0.5
			if frame == 5 or frame == 90: current.rig.on_shot()
			if current == actor: current.rig.animate(DT, current)
			else: legacy_animate(DT, current)
		same_live = same_live and pose_state(actor) == pose_state(original) and counters(actor) == counters(original)
	check(same_live and not actor.rig.corpse_sleeping, team + " live walk/aim/reload/work/shot/pause outputs and all calls exactly unchanged")
	fixture.paused = false
	fixture.defuser = null
	fixture.objective.carrier = null
	for current in [actor, original]:
		current.health = 0
		current.velocity = Vector3.ZERO
		current.rig.on_shot()
	var same_transition := true
	var death_frames := 0
	var paused_frames := 0
	for frame in 150:
		fixture.paused = frame % 7 == 2
		var before := counters(actor)
		var age := actor.rig.corpse_time
		actor.rig.animate(DT, actor)
		legacy_animate(DT, original)
		if fixture.paused:
			paused_frames += 1
			check(counters(actor) == before and actor.rig.corpse_time == age, team + " paused death does not advance work or settling time")
		else: death_frames += 1
		same_transition = same_transition and pose_state(actor) == pose_state(original) and counters(actor) == counters(original)
		if actor.rig.corpse_sleeping: break
	check(same_transition and death_frames >= 60 and death_frames <= 61 and paused_frames > 0,
		team + " full one-second death transition exactly matches old animation")
	check(actor.rig.corpse_sleeping and actor.rig.fall == 1 and not actor.rig.flash.visible and actor.rig.flash_left == 0,
		team + " settled corpse sleeps only after completed fall and expired flash")
	check(actor.rig.weapon_clearance.clear and final_hull_clear(actor), team + " final frozen weapon hull and connection ray are physically clear")
	var asleep := counters(actor)
	var stored_pose := pose_state(actor)
	var legacy_start := counters(original)
	for frame in 240:
		fixture.paused = frame % 2 == 0
		actor.rig.animate(DT, actor)
		legacy_animate(DT, original)
	check(counters(actor) == asleep and pose_state(actor) == stored_pose, team + " 240 alternating pause/resume frames do zero pose/flush/IK/query/eye work and preserve every stored bone")
	check(original.rig.updates - legacy_start[0] == 120 and original.rig.bone_writes - legacy_start[2] == 2160,
		team + " original path still performs 120 updates and 2160 bone writes in same window")
	check(actor.health == 0 and actor.collision_layer == 4 and actor.collision_mask == 1 and actor.velocity == Vector3.ZERO,
		team + " animation sleep never mutates health, hitbox layers or movement state")
	print("CORPSE_SLEEP_COUNTS ", team, " skipped_unpaused_frames=120 updates=120->0 bone_writes=2160->0 limb_solves=480->0 queries=",
		original.rig.weapon_clearance.total_queries - legacy_start[5], "->0 (no FPS claim; rendered corpse remains drawn)")
	fixture.paused = false
	for change in ["translation", "rotation", "model", "paused_move"]:
		var before := counters(actor)
		if change == "rotation": actor.rotation.y += 0.1
		elif change == "model": actor.model.position.x += 0.02
		else: actor.position.x += 0.1
		if change == "paused_move":
			fixture.paused = true
			actor.rig.animate(2.0, actor)
			check(counters(actor) == before and actor.rig.corpse_sleeping, team + " paused teleport waits until resume")
			fixture.paused = false
		actor.rig.animate(DT, actor)
		check(actor.rig.updates == before[0] + 1 and not actor.rig.corpse_sleeping, team + " transform change wakes pose/clearance: " + change)
		check(settle(actor) >= 59 and actor.rig.corpse_sleeping and final_hull_clear(actor), team + " changed transform rechecks clear final pose before sleeping: " + change)
	var before := counters(actor)
	actor.rig.weapon_clearance.clear = false
	actor.rig.animate(DT, actor)
	check(not actor.rig.corpse_sleeping and actor.rig.updates == before[0] + 1 and actor.rig.flushes == before[1] + 1 \
		and actor.rig.weapon_clearance.calls == before[4] + 1 and actor.rig.weapon_clearance.total_queries > before[5],
		team + " cached clearance invalidation wakes a sleeping corpse and performs real pose/physics work")
	check(actor.rig.weapon_clearance.clear and is_equal_approx(actor.rig.corpse_time, DT), team + " successful clearance recompute starts fresh settling time")
	check(settle(actor) >= 59 and actor.rig.corpse_sleeping and final_hull_clear(actor), team + " invalidated clearance resettles with independently clear final hull")
	before = counters(actor)
	actor.health = 100
	actor.rig.animate(DT, actor)
	check(actor.rig.updates == before[0] + 1 and not actor.rig.corpse_sleeping and actor.rig.corpse_time == 0, team + " live health immediately wakes animation without inventing resurrection behavior")
	actor.health = 0
	check(settle(actor) >= 60 and actor.rig.corpse_sleeping, team + " later death starts a fresh settling interval")
	before = counters(actor)
	actor.rig.update_pose(DT, Vector3.ZERO, Vector2.ZERO, 0, false, true)
	check(actor.rig.updates == before[0] + 1 and not actor.rig.corpse_sleeping, team + " direct pose fixture call always runs and invalidates sleep")
	check(settle(actor) >= 60 and actor.rig.corpse_sleeping, team + " explicit pose mutation is rechecked before sleeping")
	actor.rig.on_shot()
	actor.rig.animate(DT, actor)
	check(not actor.rig.corpse_sleeping and not actor.rig.flash.visible, team + " explicit effect invalidation wakes without flashing a dead actor")
	check(settle(actor) >= 59 and actor.rig.corpse_sleeping, team + " expired effect permits resettling")
	actor.free()
	original.free()
	# Round reset really discards bot/model/rig nodes; new rigs inherit no sleep.
	var respawn := actor_for(team)
	check(not respawn.rig.corpse_sleeping and respawn.rig.corpse_time == 0 and respawn.rig.fall == 0 and respawn.rig.clock == 0,
		team + " replacement round-reset actor starts entirely fresh")
	respawn.rig.animate(DT, respawn)
	check(respawn.rig.updates == 1 and respawn.rig.flushes == 1 and not respawn.rig.corpse_sleeping, team + " replacement actor animates normally")
	respawn.free()

func inspect_frame_deltas(team: String) -> void:
	for rate in [20, 30, 144, 0]:
		var actor := actor_for(team)
		var original := actor_for(team)
		actor.health = 0
		original.health = 0
		actor.rig.on_shot()
		original.rig.on_shot()
		var elapsed := 0.0
		var largest_dt := 0.0
		var frames := 0
		var guards := true
		var same_transition := true
		var label := "%s %s" % [team, str(rate) + " Hz" if rate else "30 Hz with 700 ms stutter"]
		while not actor.rig.corpse_sleeping and frames < 300:
			var dt: float = 1.0 / rate if rate else (0.7 if frames == 7 else 1.0 / 30)
			largest_dt = maxf(largest_dt, dt)
			elapsed += dt
			actor.rig.animate(dt, actor)
			legacy_animate(dt, original)
			same_transition = same_transition and pose_state(actor) == pose_state(original) and counters(actor) == counters(original)
			guards = guards and (not actor.rig.corpse_sleeping or (elapsed >= Rig.CORPSE_SETTLE_SECONDS \
				and actor.rig.fall == 1 and actor.rig.flash_left == 0 and not actor.rig.flash.visible and actor.rig.weapon_clearance.clear))
			frames += 1
		check(same_transition, label + " matches every original transition pose/call through final stored pose")
		check(guards and actor.rig.corpse_sleeping and elapsed <= Rig.CORPSE_SETTLE_SECONDS + largest_dt + 0.00000001,
			label + " waits at least one simulated second plus completed fall/flash/clearance guards")
		check(final_hull_clear(actor), label + " independently checked final weapon hull and connection remain clear")
		var before := counters(actor)
		var stored := pose_state(actor)
		actor.rig.animate(0.7, actor)
		check(counters(actor) == before and pose_state(actor) == stored, label + " a later long frame does not disturb sleeping pose")
		print("CORPSE_SLEEP_DT ", label, " transition_frames=", frames, " simulated_seconds=", elapsed)
		actor.free()
		original.free()

func run() -> void:
	fixture = Fixture.new()
	root.add_child(fixture)
	box(Vector3(0, -0.25, 0), Vector3(20, 0.5, 20))
	box(Vector3(0, 2, -0.8), Vector3(8, 4, 0.2))
	for i in 2: await physics_frame
	for team in ["ct", "t"]:
		inspect(team)
		inspect_frame_deltas(team)
	# Let actual deferred Skeleton3D notifications execute, not merely script
	# counters. This signal precedes the pinned engine's skin-palette writes;
	# headless does not measure GL uploads or eliminate vertex skinning/draws.
	var sleeping := actor_for("ct")
	var updating := actor_for("ct")
	sleeping.health = 0
	updating.health = 0
	settle(sleeping)
	for frame in 60: legacy_animate(DT, updating)
	for i in 2: await process_frame
	sleeping.rig.skeleton_updates = 0
	updating.rig.skeleton_updates = 0
	for frame in 8:
		sleeping.rig.animate(DT, sleeping)
		legacy_animate(DT, updating)
		await process_frame
	for i in 2: await process_frame
	check(sleeping.rig.skeleton_updates == 0 and updating.rig.skeleton_updates == 8,
		"settled sleep avoids actual deferred Skeleton3D/palette update path while old animation updates each frame")
	print("CORPSE_SLEEP_SKELETON deferred_update_frames=8->0 (headless signal; GL upload saving is source-derived)")
	sleeping.free()
	updating.free()
	var trapped := actor_for("ct")
	trapped.health = 0
	var obstruction := box(Vector3(0, 1, 0), Vector3(10, 10, 10))
	for i in 2: await physics_frame
	for frame in 120: trapped.rig.animate(DT, trapped)
	check(not trapped.rig.weapon_clearance.clear and not trapped.rig.corpse_sleeping and trapped.rig.updates == 120,
		"unclear corpse keeps real clearance/IK work running even after two seconds")
	obstruction.free()
	for i in 2: await physics_frame
	check(settle(trapped) >= 60 and trapped.rig.corpse_sleeping and final_hull_clear(trapped), "previously blocked corpse can settle only after physics clearance succeeds")
	trapped.free()
	fixture.free()
	print("CORPSE_SLEEP: %d/%d passed" % [passed, passed + failed])
	quit(1 if failed else 0)
