extends SceneTree

## Exact output regression plus a short informational CPU comparison.
## Neither measures rendered images, deferred engine work or browser FPS.
const Models = preload("res://scripts/models.gd")
const Rig = preload("res://scripts/operator_rig.gd")
const Layout = preload("res://scripts/layout.gd")

class CheckedRig:
	extends Rig
	var inherited := 0
	var origin_checks := 0
	var origins_equal := true
	var original_limb_start := false
	func inherit_pose() -> void:
		inherited += 1
		super.inherit_pose()
	func solve_limb(limb: Limb, goal: Transform3D, pole: Vector3) -> void:
		var a := limb.upper
		var original := (pose[parents[a]] * local_rest[a]).origin
		origins_equal = origins_equal and original == pose[parents[a]] * local_rest[a].origin
		origin_checks += 1
		if not original_limb_start:
			super.solve_limb(limb, goal, pole)
			return
		# Frozen pre-shortcut solver; the reference also forces the full reset.
		var b := limb.lower
		var c := limb.end
		var first := limb.first
		var second := limb.second
		var target := original + (goal.origin - original).limit_length(first + second - 0.001)
		var joint := joint_at(original, target, pole, first, second)
		pose[a] = Transform3D(Basis(Quaternion(limb.upper_direction, (joint - original).normalized())) * rest[a].basis, original)
		pose[b] = Transform3D(Basis(Quaternion(limb.lower_direction, (target - joint).normalized())) * rest[b].basis, joint)
		pose[c] = Transform3D(goal.basis, target)

var passed := 0
var failed := 0
var pose_pairs := 0
var world: Node3D

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func make_rig(team: String, altered := "") -> CheckedRig:
	var host := Node3D.new()
	world.add_child(host)
	var model: Node3D = Models.ASSETS[team + "_operator"].instantiate()
	host.add_child(model)
	Models.prepare(model)
	var skeleton: Skeleton3D = model.find_children("*", "Skeleton3D", true, false)[0]
	if altered == "extra":
		var bone := skeleton.get_bone_count()
		skeleton.add_bone("test_accessory")
		skeleton.set_bone_parent(bone, skeleton.find_bone("head"))
		skeleton.set_bone_rest(bone, Transform3D(Basis.IDENTITY, Vector3(0.03, 0.07, 0.02)))
	elif altered == "parent":
		skeleton.set_bone_parent(skeleton.find_bone("neck"), skeleton.find_bone("pelvis"))
	var rig := CheckedRig.new()
	rig.setup(model)
	return rig

func poison_descendants(rig: CheckedRig, frame: int) -> void:
	# Every non-root slot is deliberately wrong before each optimized update.
	# A missed write/read dependency must affect comparison with the reference.
	for bone in rig.pose.size():
		if rig.parents[bone] < 0: continue
		rig.pose[bone] = Transform3D(Basis(Vector3(2, 0.1, 0), Vector3(0.2, 3, 0.3), Vector3(0, 0.4, 4)),
			Vector3(100 + bone, -80 - frame, 200 + bone * 3))

func state(rig: CheckedRig) -> Array:
	var bones: Array[Transform3D] = []
	for bone in rig.skeleton.get_bone_count(): bones.append(rig.skeleton.get_bone_pose(bone))
	var feet := rig.grounding
	var clearance := rig.weapon_clearance
	return [rig.pose, bones, rig.model.transform, rig.foot_targets, rig.clock, rig.phase, rig.motion,
		rig.aim, rig.turn, rig.reload_blend, rig.recoil, rig.fall, rig.flash_left, rig.flash.visible,
		rig.flash.transform, clearance.amount, clearance.blocked, clearance.clear, clearance.queries,
		feet.initialized, feet.walking, feet.feet, feet.planted, feet.was_stance, feet.stance,
		feet.turn_foot, feet.turn_progress, feet.turn_start, feet.turn_goal, feet.next_foot]

func inspect(team: String, altered := "") -> void:
	var candidate := make_rig(team, altered)
	var reference := make_rig(team, altered)
	var supported := altered.is_empty()
	check(candidate.root_pose_only == supported and candidate.can_reset_root_only() == supported,
		team + " setup detects exact hierarchy / fallback: " + altered)
	reference.root_pose_only = false
	reference.original_limb_start = true
	var cases := ["idle", "walk", "run", "back", "strafe", "brake", "aim", "reload", "work", "shot", "slope", "contact", "affine", "death"]
	if not supported: cases = ["idle", "reload", "contact", "death"]
	var contact_queries := 0
	var contact_withdrawal := false
	for mode: String in cases:
		var same := true
		var finite := true
		for frame in 36:
			var dt: float = [1.0 / 20, 1.0 / 60, 1.0 / 144][frame % 3]
			var velocity := Vector3.ZERO
			match mode:
				"walk": velocity = Vector3(0, 0, -1.5)
				"run": velocity = Vector3(0, 0, -4.65)
				"back": velocity = Vector3(0, 0, 2.1)
				"strafe": velocity = Vector3(2.1, 0, 0)
				"brake": velocity = Vector3(0, 0, -2.1) if frame < 10 else Vector3.ZERO
				"slope": velocity = Vector3(1.2, 0, 0)
			var body := Transform3D(Basis(Vector3.UP, sin(frame * 0.08) * 0.5), Vector3(10 + frame * 0.01, 0, 8 - frame * 0.04))
			var height := Layout.floor_height
			var space: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state
			if mode in ["contact", "death"]: body.origin = Vector3.ZERO
			elif mode == "slope":
				body.origin = Vector3(6 + frame * 0.05, 0, -29)
				body.origin.y = Layout.floor_height(Vector2(body.origin.x, body.origin.z))
				space = null # Analytic terrain case, not the fixture's flat floor.
			elif mode == "affine":
				body.basis *= Basis(Vector3(1.2, 0.05, 0), Vector3(0.1, 0.9, 0.04), Vector3(0.03, 0, 1.1))
				space = null # Clearance intentionally accepts only rigid transforms.
				height = Callable()
			var look := Vector2(sin(frame * 0.2) * 0.9, cos(frame * 0.17) * 0.8)
			var reload_left := 2.1 - frame * 0.05 if mode == "reload" else 0.0
			for rig in [candidate, reference]:
				rig.model.get_parent().transform = body
				if mode in ["shot", "death"] and frame % 17 == 0: rig.on_shot()
			poison_descendants(candidate, frame)
			candidate.update_pose(dt, velocity, look, reload_left, mode == "work", mode == "death", sin(frame * 0.13), body, height, space)
			reference.update_pose(dt, velocity, look, reload_left, mode == "work", mode == "death", sin(frame * 0.13), body, height, space)
			same = same and state(candidate) == state(reference)
			for pose in candidate.pose: finite = finite and pose.is_finite()
			if mode == "contact":
				contact_queries += candidate.weapon_clearance.queries
				contact_withdrawal = contact_withdrawal or candidate.weapon_clearance.amount > 0
			pose_pairs += 1
		check(same and finite, team + " exact poisoned-pose/local-bone/flash/clearance outputs: " + altered + "/" + mode)
	var count := cases.size() * 36
	check(candidate.inherited == (0 if supported else count) and reference.inherited == count,
		team + " original full reset retained only where required: " + altered)
	check(candidate.origin_checks == count * 4 and candidate.origins_equal and reference.origins_equal,
		team + " origin-only shortcut equals original algebra for every real limb pose: " + altered)
	check(contact_queries > 0 and contact_withdrawal, team + " actual wall clearance path was exercised: " + altered)
	if not supported:
		check(not candidate.root_pose_only, team + " unsupported hierarchy never enters optimized reset: " + altered)
	candidate.model.get_parent().free()
	reference.model.get_parent().free()

func inspect_affine_algebra() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 811903
	var exact := true
	for sample in 512:
		var basis := Basis.from_euler(Vector3(rng.randf_range(-PI, PI), rng.randf_range(-PI, PI), rng.randf_range(-PI, PI)))
		basis *= Basis(Vector3(rng.randf_range(0.2, 3), rng.randf_range(-0.3, 0.3), 0),
			Vector3(0, rng.randf_range(0.2, 3), rng.randf_range(-0.3, 0.3)), Vector3(rng.randf_range(-0.3, 0.3), 0, -1.0 if sample % 2 else 1.0))
		var parent := Transform3D(basis, Vector3(rng.randf_range(-100, 100), rng.randf_range(-100, 100), rng.randf_range(-100, 100)))
		var local := Transform3D(Basis.from_euler(Vector3(0.4, -0.7, 0.2)), Vector3(rng.randf_range(-3, 3), rng.randf_range(-3, 3), rng.randf_range(-3, 3)))
		exact = exact and (parent * local).origin == parent * local.origin
	check(exact, "512 seeded finite rotated/scaled/sheared/reflected affine origins remain exactly equal")

func box(at: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	var collider := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collider.shape = shape
	body.add_child(collider)
	world.add_child(body)
	body.position = at

func cpu_sample(team: String) -> void:
	# Informational only. All four windows begin from fresh, identically warmed
	# state; only root_pose_only differs. No correctness subclass/counters,
	# poisoning, GL rendering, deferred skin upload or fixture setup is timed.
	var velocities: Array[Vector3] = []
	var looks: Array[Vector2] = []
	var reloads: Array[float] = []
	for frame in 400:
		velocities.append(Vector3(0, 0, -1.5) if frame < 120 else Vector3(2.1, 0, 0) if frame < 240 else Vector3.ZERO)
		looks.append(Vector2(sin(frame * 0.03) * 0.4, cos(frame * 0.02) * 0.4))
		reloads.append(1.1 if frame >= 260 and frame < 330 else 0.0)
	var body := Transform3D(Basis.IDENTITY, Vector3(10, 0, 8))
	var space := world.get_world_3d().direct_space_state
	var reference: Array[float] = []
	var optimized: Array[float] = []
	var blocks: Array = []
	for block in 3:
		var windows: Array[float] = []
		for root_only: bool in [false, true, true, false]:
			var model: Node3D = Models.ASSETS[team + "_operator"].instantiate()
			world.add_child(model)
			model.transform = body
			Models.prepare(model)
			var rig := Rig.new()
			rig.setup(model)
			rig.root_pose_only = root_only
			for frame in 120:
				rig.update_pose(1.0 / 60, velocities[frame], looks[frame], reloads[frame], false, false, 0, body, Layout.floor_height, space)
			var started := Time.get_ticks_usec()
			for frame in 400:
				rig.update_pose(1.0 / 60, velocities[frame], looks[frame], reloads[frame], false, false, 0, body, Layout.floor_height, space)
			var per_pose := (Time.get_ticks_usec() - started) / 400.0
			windows.append(per_pose)
			if root_only: optimized.append(per_pose)
			else: reference.append(per_pose)
			model.free()
		blocks.append(windows)
	reference.sort()
	optimized.sort()
	var before := (reference[2] + reference[3]) * 0.5
	var after := (optimized[2] + optimized[3]) * 0.5
	print("POSE_RESET_CPU ", team, " ", JSON.stringify({"order": "full/root/root/full", "blocks_us_per_pose": blocks,
		"full_median_us": before, "root_median_us": after, "root_over_full": after / before,
		"warmup_poses_per_window": 120, "measured_poses_per_window": 400,
		"measurement": "headless immediate update_pose; fixed-body grounded mixed poses + real clearance; not deferred engine/GPU work or browser FPS"}))

func run() -> void:
	world = Node3D.new()
	root.add_child(world)
	box(Vector3(0, -0.25, 0), Vector3(80, 0.5, 80))
	box(Vector3(0, 2, -0.8), Vector3(8, 4, 0.2))
	for i in 2: await physics_frame
	inspect_affine_algebra()
	for team in ["ct", "t"]:
		inspect(team)
		inspect(team, "extra")
		inspect(team, "parent")
		cpu_sample(team)
	world.free()
	print("POSE_RESET_PAIRS ", pose_pairs, " (exact output regression, not rendered-image/GPU proof)")
	print("POSE_RESET: %d/%d passed" % [passed, passed + failed])
	quit(1 if failed else 0)
