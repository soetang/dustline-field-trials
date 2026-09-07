extends SceneTree

const FootPlacement = preload("res://scripts/foot_placement.gd")
const WeaponClearance = preload("res://scripts/weapon_clearance.gd")
# Staged visual inspection, not gameplay or a performance benchmark. No host
# input: the browser runner rejects pointer capture and all input commands.
var game: Node3D
var camera := Camera3D.new()
var actor: Node3D
var resolution := Vector2i(960,441)
var report_position := Vector3(-7.674188,0.000625,-33.478039)
var operator_motion := false
var model_rests: Dictionary = {}
var companions: Array[Node3D] = []
var sleep_probe: Dictionary = {}
var death_wall_probe: Dictionary = {}

func transform_values(value: Transform3D) -> Array[float]:
	return [value.basis.x.x,value.basis.x.y,value.basis.x.z,
		value.basis.y.x,value.basis.y.y,value.basis.y.z,
		value.basis.z.x,value.basis.z.y,value.basis.z.z,
		value.origin.x,value.origin.y,value.origin.z]

func skin_snapshot(subject: Node3D = null) -> Dictionary:
	if subject == null: subject = actor
	var node: MeshInstance3D
	for child: MeshInstance3D in subject.model.find_children("*","MeshInstance3D",true,false):
		if child.skin != null: node = child
	var reference := node.get_skin_reference()
	var palette: Array = []
	var valid := reference != null
	if valid:
		for bind in node.skin.get_bind_count():
			var bone := node.skin.get_bind_bone(bind)
			if not node.skin.get_bind_name(bind).is_empty(): bone = subject.rig.skeleton.find_bone(node.skin.get_bind_name(bind))
			var expected: Transform3D = subject.rig.skeleton.get_bone_global_pose(bone) * node.skin.get_bind_pose(bind)
			# Actual renderer-side palette, not the headless backend's identities.
			# This getter reads CPU palette storage, not the GPU or rendered pixels.
			var actual := RenderingServer.skeleton_bone_get_transform(reference.get_skeleton(),bind)
			valid = valid and actual.is_equal_approx(expected)
			if bind < 18: palette.append(transform_values(actual))
	var poses: Array = []
	for pose: Transform3D in subject.rig.pose: poses.append(transform_values(pose))
	return {"palette_valid":valid,"palette":palette,"bindings":node.skin.get_bind_count(),
		"palette_rid":str(reference.get_skeleton().get_id()) if reference != null else "",
		"bones":subject.rig.skeleton.get_bone_count(),"poses":poses,
		"model_transform":transform_values(subject.model.transform)}

func _initialize() -> void:
	call_deferred("run")

func place(bot: Node3D, at: Vector3, yaw: float) -> void:
	for other in game.bots: other.visible = false
	actor = bot
	actor.position = game.Layout.on_floor(at)
	actor.rotation.y = yaw
	actor.velocity = Vector3.ZERO
	actor.rig.clock = 0
	actor.rig.phase = 0
	actor.rig.grounding = FootPlacement.new()
	actor.rig.weapon_clearance.amount = 0
	actor.visible = true

func capture(name: String, at: Vector3, target: Vector3, first_person: bool = false) -> void:
	game.player.visible = first_person
	if first_person:
		game.player.camera.current = true
	else:
		camera.position = at
		camera.look_at(target)
		camera.current = true
	# Let skinning, shadows and SSAO settle before the readback. No physics/AI
	# simulation, input injection or frame-time interpretation in this fixture.
	for i in (3 if operator_motion else 24):
		if not operator_motion and is_instance_valid(actor) and actor.visible:
			actor.rig.update_pose(1.0/60,Vector3.ZERO,Vector2.ZERO,0,false,false,0,actor.global_transform,game.Layout.floor_height,game.get_world_3d().direct_space_state)
		if first_person: game.player.update_weapon_pose(1.0/60)
		await RenderingServer.frame_post_draw
	var subject: Node3D = game.player if first_person else actor
	var data := {"name":name,"fixture":"staged wall/weapon inspection; no player input or live AI", "build":game.BUILD,
		"weapon_clear":subject.weapon_clearance.clear if first_person else subject.rig.weapon_clearance.clear,
		"weapon_withdrawal":subject.weapon_clearance.amount if first_person else subject.rig.weapon_clearance.amount,
		"render":game.render_budget.details(game.get_viewport()),
		"actor_position":[subject.position.x,subject.position.y,subject.position.z],"actor_yaw":subject.rotation.y,
		"png":Marshalls.raw_to_base64(root.get_texture().get_image().save_png_to_buffer())}
	if operator_motion:
		data.fixture = "deterministic animated operator poses; real skin palette; no live AI or host input"
		data.skin = skin_snapshot()
		data.companions = []
		for bot in companions:
			data.companions.append({"position":[bot.position.x,bot.position.y,bot.position.z],
				"yaw":bot.rotation.y,"skin":skin_snapshot(bot)})
		if not sleep_probe.is_empty():
			data.sleep = {"sleeping":actor.rig.corpse_sleeping,"corpse_time":actor.rig.corpse_time,
				"settle_ticks":sleep_probe.settle_ticks,"process_calls":sleep_probe.process_calls,
				"held_frames":sleep_probe.held_frames,"skeleton_updates":sleep_probe.skeleton_updates,
				"health":actor.health,"paused":game.paused,"game_elapsed":game.elapsed}
		if not death_wall_probe.is_empty(): data.death_wall = death_wall_snapshot()
	JavaScriptBridge.eval("window.mapReviewCaptures.push("+JSON.stringify(data)+")",true)
	if operator_motion:
		# Persist each completed image remotely even if a later stage fails.
		JavaScriptBridge.eval("window.saveMotionCapture(window.mapReviewCaptures.at(-1)).catch(console.error)",true)
	print("WALL_CAPTURE ",name)

func reset_motion(bot: Node3D, at: Vector3) -> void:
	place(bot,at,PI/2)
	bot.model.transform = model_rests[bot.get_instance_id()]
	bot.rig.motion = Vector3.ZERO
	bot.rig.aim = Vector2.ZERO
	bot.rig.turn = 0
	bot.rig.recoil = 0
	bot.rig.flash_left = 0
	bot.rig.reload_blend = 0
	bot.rig.fall = 0

func capture_motion(team: String, bot: Node3D) -> void:
	for entry in [
		["walk-first",24,Vector3(0,0,-1.5),Vector2(0.1,0.2),0.0,false],
		["walk-next",48,Vector3(0,0,-1.5),Vector2(0.1,0.2),0.0,false],
		["aim-high",45,Vector3.ZERO,Vector2(0.4,0.5),0.0,false],
		["reload",45,Vector3.ZERO,Vector2(-0.3,-0.5),1.1,false],
		["falling",8,Vector3.ZERO,Vector2.ZERO,0.0,true],
		["fallen",60,Vector3.ZERO,Vector2.ZERO,0.0,true],
	]:
		reset_motion(bot,Vector3(-5.6,0,-33.478039))
		# Simulate exact pose ticks without advancing the whole match. Only final
		# key poses are rendered; this is not a human playtest or FPS benchmark.
		for frame in entry[1]:
			actor.position = game.Layout.on_floor(actor.position + actor.basis * entry[2] / 60.0)
			actor.rig.update_pose(1.0/60,entry[2],entry[3],entry[4],false,entry[5],0,
				actor.global_transform,game.Layout.floor_height,game.get_world_3d().direct_space_state)
		await capture(team+"-"+entry[0],Vector3(-2.6,1.8,-30.7),Vector3(-5.9,0.95,-33.478039))

func capture_squad() -> void:
	var squad: Array[Node3D] = []
	for bot in game.bots:
		if bot.team == 0 and squad.size() < 3: squad.append(bot)
	var positions := [Vector3(-5.6,0,-33.478039),Vector3(-5.6,0,-31.4),Vector3(-3.7,0,-33.478039)]
	for i in squad.size(): reset_motion(squad[i],positions[i])
	for bot in squad: bot.visible = true
	actor = squad[0]
	companions.assign(squad.slice(1))
	# Shared source meshes, separate simultaneous palettes/poses. This probes
	# actual multi-rig rendering in addition to the analytical bounds tests.
	for frame in 60:
		for i in squad.size():
			var bot: Node3D = squad[i]
			bot.rig.update_pose(1.0/60,Vector3(0,0,-1.5) if i == 0 else Vector3.ZERO,
				Vector2(0.4,0.5) if i == 2 else Vector2.ZERO,0,false,i == 1,0,
				bot.global_transform,game.Layout.floor_height,game.get_world_3d().direct_space_state)
	await capture("ct-squad",Vector3(-1,1.8,-29),Vector3(-5.1,1,-32.8))
	await capture("ct-squad-edge",Vector3(-2.6,1.8,-30.7),Vector3(-2.5,1,-33.478039))
	await capture("ct-squad-distance",Vector3(1.3,2,-27.5),Vector3(-5.1,1,-32.8))
	companions.clear()

func process_corpse(bot: Node3D) -> void:
	# Only this actor's real animation callback runs while unpaused. Restore the
	# paused match synchronously, before any rendered frame or other callback.
	game.paused = false
	bot._process(1.0/60)
	game.paused = true
	sleep_probe.process_calls += 1

func capture_sleep(bot: Node3D) -> void:
	reset_motion(bot,Vector3(-5.6,0,-33.478039))
	bot.health = 0
	bot.reload_left = 0
	bot.look_goal = bot.eye() - bot.global_basis.z * 8
	bot.rig.last_yaw = bot.rotation.y
	bot.rig.corpse_sleeping = false
	bot.rig.corpse_time = 0
	sleep_probe = {"settle_ticks":0,"process_calls":0,"held_frames":0,"skeleton_updates":0}
	var count_update := func(): sleep_probe.skeleton_updates += 1
	bot.rig.skeleton.skeleton_updated.connect(count_update)
	while not bot.rig.corpse_sleeping and sleep_probe.settle_ticks < 180:
		process_corpse(bot)
		sleep_probe.settle_ticks += 1
	var at := Vector3(-2.6,1.8,-30.7)
	var target := Vector3(-5.9,0.95,-33.478039)
	# capture() drains pending skeleton updates before sampling the entry count.
	# Save evidence even if sleeping failed; the Node validators reject that state.
	await capture("ct-sleep-entry",at,target)
	for frame in 8:
		process_corpse(bot)
		await RenderingServer.frame_post_draw
		sleep_probe.held_frames += 1
	await capture("ct-sleep-hold",at,target)
	bot.position.x += 0.2
	process_corpse(bot)
	await capture("ct-sleep-moved",at,target)
	bot.rig.skeleton.skeleton_updated.disconnect(count_update)
	sleep_probe.clear()

func vector_values(value: Vector3) -> Array[float]:
	return [value.x,value.y,value.z]

func death_wall_snapshot() -> Dictionary:
	# Independent final-pose diagnostics. Negative mesh distances / excessive
	# grip errors are evidence to inspect, not hidden by a passing clear flag.
	var space := game.get_world_3d().direct_space_state
	var face := Vector3(-8,1.4,report_position.z)
	var normal := Vector3.RIGHT
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(face+normal,face-normal,1))
	var wall_shape: Shape3D
	if not hit.is_empty():
		var owner: int = hit.collider.shape_find_owner(hit.shape)
		wall_shape = hit.collider.shape_owner_get_shape(owner,0)
	var collision: CollisionShape3D = actor.find_children("*","CollisionShape3D",false,false)[0]
	var capsule: CapsuleShape3D = collision.shape
	var query := PhysicsShapeQueryParameters3D.new()
	query.collision_mask = 1
	query.collide_with_areas = false
	query.margin = 0
	query.shape = capsule
	query.transform = collision.global_transform
	var capsule_overlaps := space.intersect_shape(query).size()
	var rig = actor.rig
	var frame: Transform3D = rig.skeleton.global_transform
	var gun: Transform3D = rig.pose[rig.ids.weapon] * rig.rest[rig.ids.weapon].affine_inverse()
	var hull := BoxShape3D.new()
	hull.size = rig.weapon_clearance.bounds.size + Vector3.ONE * WeaponClearance.SKIN * 2
	var gun_world := frame * gun
	query.shape = hull
	query.transform = Transform3D(gun_world.basis,gun_world * rig.weapon_clearance.bounds.get_center())
	var hull_overlaps := space.intersect_shape(query).size()
	var ray := PhysicsRayQueryParameters3D.create(actor.global_transform * Vector3(0,1.4,0),query.transform.origin,1)
	ray.hit_from_inside = true
	var connection_clear := space.intersect_ray(ray).is_empty()
	var grips: Array[float] = []
	for side in ["l","r"]:
		var hand: int = rig.ids["hand_"+side]
		grips.append((frame * rig.pose[hand].origin).distance_to(frame * (gun * rig.rest[hand].origin)))
	var distances := [INF,INF]
	var counts := [0,0]
	for node: MeshInstance3D in actor.model.find_children("*","MeshInstance3D",true,false):
		if node.skin == null: continue
		var matrices: Array[Transform3D] = []
		var weapon_binds: Array[bool] = []
		for bind in node.skin.get_bind_count():
			var bone := node.skin.get_bind_bone(bind)
			if not node.skin.get_bind_name(bind).is_empty(): bone = rig.skeleton.find_bone(node.skin.get_bind_name(bind))
			matrices.append(rig.skeleton.get_bone_global_pose(bone) * node.skin.get_bind_pose(bind))
			weapon_binds.append(bone == rig.ids.weapon)
		for surface in node.mesh.get_surface_count():
			var arrays := node.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var joints: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var visited := PackedByteArray()
			visited.resize(vertices.size())
			for vertex in indices:
				if visited[vertex]: continue
				visited[vertex] = 1
				var point := Vector3.ZERO
				var weapon := false
				for influence in 4:
					var slot := vertex * 4 + influence
					point += (matrices[joints[slot]] * vertices[vertex]) * weights[slot]
					weapon = weapon or (weights[slot] > 0 and weapon_binds[joints[slot]])
				var group := 1 if weapon else 0
				distances[group] = minf(distances[group],normal.dot(node.global_transform * point - face))
				counts[group] += 1
	var result := death_wall_probe.duplicate()
	result.merge({"health":actor.health,"paused":game.paused,"fall":rig.fall,"sleeping":rig.corpse_sleeping,
		"wall":{"found":not hit.is_empty(),"point":vector_values(hit.position if not hit.is_empty() else face),
			"normal":vector_values(hit.normal if not hit.is_empty() else Vector3.ZERO),
			"body_class":hit.collider.get_class() if not hit.is_empty() else "",
			"shape_class":wall_shape.get_class() if wall_shape != null else "",
			"shape_size":vector_values(wall_shape.size) if wall_shape is BoxShape3D else []},
		"capsule":{"shape_class":capsule.get_class(),"radius":capsule.radius,"height":capsule.height,
			"center_distance_m":normal.dot(actor.global_position-face),
			"wall_margin_m":normal.dot(actor.global_position-face)-capsule.radius,"overlaps":capsule_overlaps},
		"weapon":{"bounds_position":vector_values(rig.weapon_clearance.bounds.position),
			"bounds_size":vector_values(rig.weapon_clearance.bounds.size),"shape_size":vector_values(hull.size),
			"hull_transform":transform_values(query.transform),"hull_overlaps":hull_overlaps,
			"connection_clear":connection_clear,"grip_error_m":grips},
		"vertices":{"body_count":counts[0],"weapon_count":counts[1],
			"body_min_wall_m":distances[0],"weapon_min_wall_m":distances[1]},
		"measurement":"CPU posed referenced base-LOD vertices (weapon-influenced vs body), not GPU/selected-LOD readback; contact findings are diagnostic"})
	return result

func capture_wall_death(team: String, bot: Node3D) -> void:
	for entry in [["into",0.0],["oblique",45.0],["parallel",90.0]]:
		reset_motion(bot,Vector3(-8+0.326,0,report_position.z))
		bot.rotation.y = PI/2 + deg_to_rad(entry[1])
		bot.health = 100
		bot.collision_layer = 4
		bot.role = "ATTACK"
		bot.reload_left = 0
		bot.look_goal = bot.eye() - bot.global_basis.z * 8
		bot.rig.last_yaw = bot.rotation.y
		bot.rig.corpse_sleeping = false
		bot.rig.corpse_time = 0
		bot.rig.flash.visible = false
		bot.rig.weapon_clearance.configure(bot.rig.weapon_clearance.bounds)
		# Withdrawal history is part of the real death pose: first reach the
		# same live wall contact for a full second. Other match callbacks stay off.
		for tick in 60:
			game.paused = false
			bot._process(1.0/60)
			game.paused = true
		bot.health = 0
		bot.collision_layer = 0
		death_wall_probe = {"schema":1,"team":team,"angle_degrees":entry[1],"prewarm_ticks":60,"death_ticks":0,"phase":"falling",
			"starting_withdrawal":bot.rig.weapon_clearance.amount,"starting_cached_clear":bot.rig.weapon_clearance.clear}
		for tick in 60:
			game.paused = false
			bot._process(1.0/60)
			game.paused = true
			death_wall_probe.death_ticks = tick+1
			if tick+1 in [8,60]:
				death_wall_probe.phase = "falling" if tick+1 == 8 else "settled"
				await capture(team+"-wall-death-"+entry[0]+"-"+death_wall_probe.phase,
					Vector3(-5.0,1.6,-30.9),Vector3(-7.55,0.7,report_position.z))
		death_wall_probe.clear()

func run() -> void:
	operator_motion = "--operator-motion" in OS.get_cmdline_user_args()
	root.size = resolution
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.hud.visible = false
	game.player.visible = false
	game.add_child(camera)
	camera.fov = 62
	camera.near = 0.045
	camera.far = 200
	var ct: Node3D
	var attacker: Node3D
	for bot in game.bots:
		bot.visible = false
		model_rests[bot.get_instance_id()] = bot.model.transform
		if bot.team == 0 and ct == null: ct = bot
		if bot.team == 1 and attacker == null: attacker = bot
	if operator_motion:
		await capture_motion("ct",ct)
		await capture_motion("t",attacker)
		await capture_squad()
		await capture_sleep(ct)
		await capture_wall_death("ct",ct)
		await capture_wall_death("t",attacker)
		print("WALL_REVIEW_OK")
		JavaScriptBridge.eval("window.mapReviewComplete = true",true)
		return
	place(ct,Vector3(-6.1,0,-33.478039),PI/2)
	await capture("ct-clear",Vector3(-3.9,1.7,-31.0),Vector3(-6.3,1.15,-33.478039))
	for entry in [["ct",ct],["t",attacker]]:
		for angle in [["zero",0.0],["thirty",30.0],["sixty",60.0],["ninety",90.0]]:
			place(entry[1],report_position,PI/2+deg_to_rad(angle[1]))
			await capture(entry[0]+"-angle-"+angle[0],Vector3(-5.45,1.65,-31.1),Vector3(-7.6,1.05,-33.5))
	# Thin mid-door leaf: inspect both sides so a weapon that goes through the
	# wood cannot hide solely behind normal depth testing from the owner's side.
	var door: Dictionary = game.Layout.DOORS[2]
	var hinge: Vector2 = door.hinge
	var center := Vector2(door.side*door.width*0.5,0)
	var normal := Vector2.DOWN.rotated(-float(door.yaw))
	var contact := hinge + center.rotated(-float(door.yaw)) + normal*0.476
	place(attacker,Vector3(contact.x,0,contact.y),float(door.yaw))
	var focus := actor.position+Vector3.UP*1.15
	var outward := Vector3(normal.x,0,normal.y)
	var tangent := Vector3(outward.z,0,-outward.x)
	await capture("door-near",focus+outward*2.8+tangent*1.3+Vector3.UP*0.25,focus)
	await capture("door-far",focus-outward*2.8+tangent*0.5+Vector3.UP*0.20,focus)
	for bot in game.bots: bot.visible = false
	game.player.position = report_position
	game.player.rotation.y = 1.5849597454071
	game.player.pitch = -0.0666382837057114
	game.player.head.position.y = 1.62
	game.player.camera.rotation = Vector3(game.player.pitch,0,0)
	game.player.equip(1)
	await capture("player-reported",Vector3.ZERO,Vector3.ZERO,true)
	print("WALL_REVIEW_OK")
	JavaScriptBridge.eval("window.mapReviewComplete = true",true)
