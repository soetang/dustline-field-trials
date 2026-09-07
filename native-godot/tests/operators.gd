extends SceneTree

const Models = preload("res://scripts/models.gd")
const Rig = preload("res://scripts/operator_rig.gd")
const Layout = preload("res://scripts/layout.gd")
var passed := 0
var failed := 0

func check(ok: bool, message: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("FAIL: ", message)

func _initialize() -> void:
	call_deferred("run")

func grounded_cpu_sample(team: String, rig: FieldOperatorRig) -> void:
	# Precompute a repeatable slope walk/idle-turn fixture, so the sample measures
	# the same terrain-aware pose work used in gameplay, without fixture setup.
	var bodies: Array[Transform3D] = []
	var velocities: Array[Vector3] = []
	var rates: Array[float] = []
	var at := Vector3(6,0,-29)
	var yaw := 0.0
	for frame in 600:
		var velocity := Vector3(1.5,0,0) if frame < 120 else (Vector3(-1.5,0,0) if frame < 240 else Vector3.ZERO)
		var rate := 0.8 if frame >= 240 and frame < 420 else -0.8 if frame >= 420 else 0.0
		at += velocity / 60.0
		at.y = Layout.floor_height(Vector2(at.x,at.z))
		yaw += rate / 60.0
		var body := Transform3D(Basis(Vector3.UP,yaw),at)
		bodies.append(body)
		velocities.append(body.basis.inverse() * velocity)
		rates.append(rate)
	var samples: Array[float] = []
	for run in 6:
		var started := Time.get_ticks_usec()
		for frame in bodies.size():
			rig.update_pose(1.0/60,velocities[frame],Vector2(0.1,0.2),0,false,false,rates[frame],bodies[frame],Layout.floor_height)
		if run > 0: samples.append((Time.get_ticks_usec()-started)/float(bodies.size()))
	samples.sort()
	print("OPERATOR_GROUNDED_CPU_SAMPLE ",team," median_us_per_unit=",samples[2],
		" min_us=",samples[0]," max_us=",samples[4]," frames_per_sample=600 samples=5",
		" (headless animation code only, not browser or game frame time)")

func run() -> void:
	for team in ["ct", "t"]:
		var model: Node3D = Models.ASSETS[team + "_operator"].instantiate()
		root.add_child(model)
		Models.prepare(model)
		var rig := Rig.new()
		rig.setup(model)
		check(rig.skeleton.get_bone_count() == 18, team + " compact skeleton")
		var meshes := model.find_children("*", "MeshInstance3D", true, false)
		var mesh: MeshInstance3D = meshes[0]
		check(mesh.mesh.get_surface_count() == 3, team + " three material surfaces")
		check(mesh.skin != null, team + " skinned mesh")
		var vertices := 0
		var valid_weights := true
		for surface in mesh.mesh.get_surface_count():
			var arrays := mesh.mesh.surface_get_arrays(surface)
			vertices += arrays[Mesh.ARRAY_VERTEX].size()
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			for offset in range(0, weights.size(), 4):
				var total := 0.0
				for i in 4:
					total += weights[offset+i]
					valid_weights = valid_weights and weights[offset+i] >= 0 and is_finite(weights[offset+i])
				valid_weights = valid_weights and absf(total - 1) < 0.001
		check(valid_weights and vertices < 9000, team + " normalized skin weights / vertex budget")
		var modes := {
			"idle": Vector3.ZERO, "walk": Vector3(0,0,-1.5),
			"run": Vector3(0,0,-4.65), "back": Vector3(0,0,2.1), "strafe": Vector3(2.1,0,0),
		}
		for mode in modes:
			var finite := true
			var lengths_ok := true
			var feet_grounded := true
			var hand_contact := true
			var start_phase := rig.phase
			for frame in 120:
				rig.update_pose(1.0/60, modes[mode], Vector2(0.25,0.35), 0, false, false)
				for bone in rig.pose.size():
					finite = finite and rig.pose[bone].is_finite() and absf(rig.pose[bone].basis.determinant()-1) < 0.001
				for side in ["l","r"]:
					for chain in [["thigh_","shin_","foot_"],["upperarm_","forearm_","hand_"]]:
						for i in 2:
							var a: int = rig.ids[chain[i]+side]
							var b: int = rig.ids[chain[i+1]+side]
							lengths_ok = lengths_ok and absf(rig.pose[a].origin.distance_to(rig.pose[b].origin)-rig.rest[a].origin.distance_to(rig.rest[b].origin)) < 0.002
					var foot: int = rig.ids["foot_"+side]
					feet_grounded = feet_grounded and rig.pose[foot].origin.y >= 0.137 and rig.pose[foot].origin.y < 0.31
					var hand: int = rig.ids["hand_"+side]
					var weapon: int = rig.ids.weapon
					var grip: Vector3 = rig.pose[weapon] * rig.rest[weapon].affine_inverse() * rig.rest[hand].origin
					hand_contact = hand_contact and rig.pose[hand].origin.distance_to(grip) < 0.004
			check(finite, team+" "+mode+" finite orthonormal bone poses")
			check(lengths_ok, team+" "+mode+" limbs keep anatomical lengths")
			check(feet_grounded, team+" "+mode+" feet stay above the floor")
			check(hand_contact, team+" "+mode+" hands stay on weapon")
			if mode == "idle": check(rig.phase == start_phase, team+" idle does not march")
		var stand_phase := rig.phase
		for frame in 180: rig.update_pose(1.0/60,Vector3.ZERO,Vector2.ZERO,1.1,false,false)
		check(rig.motion.length() < 0.001, team+" stops smoothly")
		check(rig.pose[rig.ids.hand_l].origin.y < rig.pose[rig.ids.hand_r].origin.y, team+" support hand reaches magazine")
		check(rig.phase != stand_phase, team+" braking finishes step")
		rig.on_shot()
		rig.update_pose(1.0/60,Vector3.ZERO,Vector2.ZERO,0,false,false)
		check(rig.recoil > 0 and rig.flash.visible, team+" shot kick and muzzle flash")
		var dead_grips_attached := true
		for frame in 60:
			# A killed bot can retain its reload timer. It must stop reaching for
			# the magazine and keep both hands on the weapon during the fall.
			rig.update_pose(1.0/60,Vector3.ZERO,Vector2.ZERO,1.1,false,true)
			var gun_delta := rig.pose[rig.ids.weapon] * rig.weapon_rest_inverse
			for arm in rig.arms:
				dead_grips_attached = dead_grips_attached and rig.pose[arm.end].origin.distance_to(gun_delta * rig.rest[arm.end].origin) < 0.004
		check(dead_grips_attached, team+" death interrupts magazine reach throughout the fall")
		check(not rig.flash.visible and rig.fall == 1, team+" death settles and stops muzzle flash")
		var started := Time.get_ticks_usec()
		for frame in 600:
			rig.update_pose(1.0/60,Vector3(0,0,-4.65),Vector2(0.1,0.2),0,false,false)
		print("OPERATOR_CPU_SAMPLE ",team," mean_us_per_unit=", (Time.get_ticks_usec()-started)/600.0,
			" (headless animation code only, not game frame time)")
		grounded_cpu_sample(team,rig)
		model.queue_free()
		await process_frame
	print("OPERATORS: %d/%d passed" % [passed,passed+failed])
	quit(1 if failed else 0)
