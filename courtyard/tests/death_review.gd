extends SceneTree

const Models = preload("res://scripts/models.gd")
const Rig = preload("res://scripts/operator_rig.gd")
const Death = preload("res://engine/experiments/death_physics.gd")
const Geometry = preload("res://tests/fixtures/death_geometry.gd")
const CLIP_FRAMES := 90

# Record uninterrupted native simulation, then replay its completed skeleton
# snapshots for readback. Pausing physics for every PNG would change the fall.
# The resulting clip is an offline animation study, never gameplay/FPS evidence.
class Driver:
	extends Node
	var helper: RefCounted
	var started := 0
	var frames: Array[Dictionary] = []
	var done := false
	func begin(value: RefCounted) -> void:
		helper = value
		started = Engine.get_physics_frames()
		frames.append({"tick":0,"poses":helper.latest_global_poses.duplicate()})
		helper.simulator.modification_processed.connect(record_pose)
	func record_pose() -> void:
		var tick := Engine.get_physics_frames() - started
		var snapshot := {"tick":tick,"poses":helper.latest_global_poses.duplicate()}
		if frames[-1].tick == tick: frames[-1] = snapshot
		else: frames.append(snapshot)
	func _physics_process(dt: float) -> void:
		if helper == null or done: return
		helper.tick(dt)
		if helper.frozen:
			record_pose()
			done = true
	func at_tick(tick: int) -> Dictionary:
		var selected := frames[0]
		for frame in frames:
			if frame.tick > tick: break
			selected = frame
		return selected

var game: Node3D
var camera := Camera3D.new()
var failures := 0
var capture_count := 0
var failure_labels: Array[String] = []
var case_summaries: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	if not ok:
		failures += 1
		failure_labels.append(label)
		push_error("DEATH_REVIEW: " + label)

func transform_values(value: Transform3D) -> Array:
	return [value.basis.x.x,value.basis.x.y,value.basis.x.z,
		value.basis.y.x,value.basis.y.y,value.basis.y.z,
		value.basis.z.x,value.basis.z.y,value.basis.z.z,
		value.origin.x,value.origin.y,value.origin.z]

func write_pose(rig: FieldOperatorRig, poses: Array) -> void:
	for bone in poses.size():
		var parent: int = rig.parents[bone]
		rig.skeleton.set_bone_pose(bone, poses[bone] if parent < 0 else poses[parent].affine_inverse() * poses[bone])

func skin_snapshot(rig: FieldOperatorRig, poses: Array) -> Dictionary:
	var result := {"valid":true,"palettes":[],"poses":[],
		"model_transform":transform_values(rig.model.global_transform),
		"skeleton_transform":transform_values(rig.skeleton.global_transform)}
	for pose: Transform3D in poses:
		result.poses.append(transform_values(pose))
	for node: MeshInstance3D in rig.model.find_children("*", "MeshInstance3D", true, false):
		if node.skin == null: continue
		var reference := node.get_skin_reference()
		if reference == null:
			result.valid = false
			continue
		var palette := {"mesh":str(node.name),"bindings":node.skin.get_bind_count(),
			"rid":str(reference.get_skeleton().get_id()),"transforms":[]}
		for bind in node.skin.get_bind_count():
			var name := node.skin.get_bind_name(bind)
			var bone := rig.skeleton.find_bone(name) if not name.is_empty() else node.skin.get_bind_bone(bind)
			var expected: Transform3D = poses[bone] * node.skin.get_bind_pose(bind)
			var actual := RenderingServer.skeleton_bone_get_transform(reference.get_skeleton(), bind)
			result.valid = result.valid and actual.is_finite() and actual.is_equal_approx(expected)
			palette.transforms.append(transform_values(actual))
		result.palettes.append(palette)
	result.valid = result.valid and not result.palettes.is_empty()
	return result

func timeline_contact(driver: Driver, data: Dictionary, planes: Array) -> Dictionary:
	# CPU skinning happens after simulation stops, so evidence collection does
	# not change its scheduling. These are discrete modifier snapshots, not CCD.
	var result := {"minimum":[INF,INF],"bone":["",""],"plane":["",""],
		"tick":[-1,-1],"finite":true,"samples":driver.frames.size()}
	for frame in driver.frames:
		var sample := Geometry.clearance(Geometry.points(data,frame.poses),planes)
		result.finite = result.finite and sample.finite
		for group in 2:
			if sample.minimum[group] < result.minimum[group]:
				for key in ["minimum","bone","plane"]: result[key][group] = sample[key][group]
				result.tick[group] = frame.tick
	return result

func capture(name: String, rig: FieldOperatorRig, frame: Dictionary, data: Dictionary,
		planes: Array, summary: Dictionary, requested_tick: int) -> void:
	check(not root.disable_3d, name + " replay restores the real 3D renderer")
	write_pose(rig, frame.poses)
	# Keep all replay frames equally warmed; static world and High graphics.
	for i in 3: await RenderingServer.frame_post_draw
	var skin := skin_snapshot(rig, frame.poses)
	check(skin.valid, name + " actual renderer palette matches recorded pose")
	var recorded_vertices := Geometry.points(data,frame.poses)
	var actual_vertices := Geometry.points(data,Geometry.poses(rig))
	var replay_delta := Geometry.max_delta(recorded_vertices,actual_vertices)
	var coordinate_scale := 1.0
	for vertex in recorded_vertices:
		coordinate_scale = maxf(coordinate_scale,vertex.point.abs()[vertex.point.abs().max_axis_index()])
	# Two world-space float ULPs at this scene position; contact limits below
	# remain millimeter bounds and are never relaxed by this replay tolerance.
	var replay_tolerance := maxf(0.000002,2 * coordinate_scale * pow(2.0,-23))
	check(replay_delta <= replay_tolerance, name + " replay preserves recorded indexed vertices")
	var contact := Geometry.clearance(actual_vertices, planes)
	var render: Dictionary = game.render_budget.details(game.get_viewport())
	check(render.quality == "High" and render.scale_3d == 1.0 and render.render_3d == render.viewport_pixels,
		name + " unchanged full-resolution High graphics")
	var result := {"name":name,"png":Marshalls.raw_to_base64(root.get_texture().get_image().save_png_to_buffer()),
		"fixture":"recorded native-physics pose replay; no AI/input; not gameplay or FPS",
		"tick":frame.tick,"requested_tick":requested_tick,"palette_valid":skin.valid,"bones":rig.skeleton.get_bone_count(),
		"skin":skin,"replay_vertex_delta":replay_delta,"replay_vertex_tolerance":replay_tolerance,
		"contact":contact,"simulation":summary,"render":render,"build":game.BUILD,
		"camera":{"transform":transform_values(camera.global_transform),"fov":camera.fov},
		"paused":game.paused,"game_elapsed":game.elapsed,"replay_3d_enabled":not root.disable_3d}
	JavaScriptBridge.eval("window.mapReviewCaptures.push("+JSON.stringify(result)+")", true)
	# Persist each image during the run, including before a later assertion fails.
	JavaScriptBridge.eval("window.saveMotionCapture(window.mapReviewCaptures.at(-1)).catch(console.error)", true)
	capture_count += 1
	print("DEATH_CAPTURE ",name," tick=",frame.tick)

func case_review(team: String, placement: String) -> void:
	var at := Vector3(-4,0,-30)
	var yaw := 0.0
	var planes: Array = [{"name":"floor","point":Vector3.ZERO,"normal":Vector3.UP}]
	var camera_at := Vector3(-1.4,2.1,-27)
	var target := Vector3(-4,0.7,-30.3)
	if placement == "wall":
		at = Vector3(-8+0.326,0,-33.478)
		yaw = PI/2
		planes.append({"name":"wall","point":Vector3(-8,0,0),"normal":Vector3.RIGHT})
		camera_at = Vector3(-4.4,1.9,-30.9)
		target = Vector3(-7.2,0.7,-33.478)
	elif placement == "ramp":
		at = Vector3(8,1.1,-29)
		yaw = PI/2
		planes = [{"name":"ramp","point":at,"normal":Vector3(-0.275,1,0).normalized()}]
		camera_at = Vector3(12,3.6,-25.5)
		target = Vector3(8,1.6,-29)
	var actor := Node3D.new()
	game.add_child(actor)
	actor.position = at
	actor.rotation.y = yaw
	var model: Node3D = Models.ASSETS[team+"_operator"].instantiate()
	actor.add_child(model)
	Models.prepare(model)
	var rig := Rig.new()
	rig.setup(model)
	for i in 60:
		rig.update_pose(1.0/60,Vector3.ZERO,Vector2.ZERO,0,false,false,0,
			actor.global_transform,game.Layout.floor_height,game.get_world_3d().direct_space_state)
	var geometry := Geometry.capture(rig)
	var geometry_info := {"case":team+"-"+placement,"errors":geometry.errors,"weight_error":geometry.weight_error,
		"weight_error_limit":geometry.weight_error_limit,"weight_sum_min":geometry.weight_sum_min,
		"weight_sum_max":geometry.weight_sum_max,"weight_sum_supported":geometry.weight_sum_supported}
	print("DEATH_GEOMETRY ",JSON.stringify(geometry_info))
	check(geometry.errors.is_empty() and geometry.weight_sum_supported
		and geometry.counts[0] > 0 and geometry.counts[1] > 0, "original model geometry is supported")
	var before := Geometry.points(geometry,Geometry.poses(rig))
	var initial := Geometry.clearance(before,planes)
	var controller := Death.new()
	if not controller.activate(rig,Vector3.ZERO):
		check(false,controller.last_error)
		actor.queue_free()
		return
	var activation_delta := Geometry.max_delta(before,Geometry.points(geometry,controller.latest_global_poses))
	check(activation_delta == 0.0, "activation preserves every original vertex exactly")
	var driver := Driver.new()
	game.add_child(driver)
	# This phase only records native physics/modifier poses. Headless A/B checks
	# preserve every recorded bone transform with 3D disabled; images are replayed
	# with the real High renderer restored and warmed below, not timed as FPS.
	root.disable_3d = true
	driver.begin(controller)
	while not driver.done and Engine.get_physics_frames() - driver.started < 900:
		await physics_frame
	var native_sleep: bool = driver.done and controller.frozen and controller.engine_sleeping and controller.native_awake_observed
	check(native_sleep, "real corpse reaches native sleep within 15 seconds")
	# A timeout remains a failure, but its final recorded state and PNG evidence
	# still survive. Disposing for replay is not reported as native settlement.
	driver.done = true
	var max_gap := 0
	for i in range(1,driver.frames.size()): max_gap = maxi(max_gap,driver.frames[i].tick-driver.frames[i-1].tick)
	check(max_gap <= 2, "visible modifier snapshots are at most two native ticks apart")
	var summary := {"team":team,"placement":placement,"body_count":controller.body_count,"joint_count":controller.joint_count,
		"native_sleep":native_sleep,"sleep_tick":driver.frames[-1].tick if native_sleep else -1,
		"last_recorded_tick":driver.frames[-1].tick,"recorded_frames":driver.frames.size(),
		"maximum_tick_gap":max_gap,"activation_vertex_delta":activation_delta,"initial":initial,
		"initial_violation":initial.minimum[0] < 0 or initial.minimum[1] < 0,"vertices":geometry.counts,
		"geometry":geometry_info,"native_awake_observed":controller.native_awake_observed,
		"recording_3d_disabled":root.disable_3d,"modifier_updates":controller.modifier_updates,
		"activation_usec":controller.activation_usec,"backend":game.get_world_3d().direct_space_state.get_class(),
		"slop":ProjectSettings.get_setting_with_override("physics/jolt_physics_3d/simulation/penetration_slop"),
		"physics_fps":Engine.physics_ticks_per_second,"contact_sampling":"recorded modifier snapshots; not continuous CCD"}
	controller.dispose()
	root.disable_3d = false
	check(model.find_children("*","PhysicalBone3D",true,false).is_empty(), "replay has no surviving physical bodies")
	var transition := timeline_contact(driver,geometry,planes)
	var final := Geometry.clearance(Geometry.points(geometry,driver.frames[-1].poses),planes)
	check(initial.finite and transition.finite and final.finite, "all recorded original body/rifle vertices are finite")
	check(final.minimum[0] >= -0.005 and final.minimum[1] >= -0.002, "final original body/rifle contact bounds")
	check(transition.minimum[0] >= minf(-0.01,initial.minimum[0]-0.005), "no new deep body penetration in recorded timeline")
	check(transition.minimum[1] >= minf(-0.01,initial.minimum[1]-0.005), "no rifle tunneling in recorded timeline")
	summary.transition = transition
	summary.final = final
	case_summaries.append(summary)
	camera.position = camera_at
	camera.look_at(target)
	camera.current = true
	var id := team+"-"+placement
	await capture(id+"-early",rig,driver.at_tick(8),geometry,planes,summary,8)
	await capture(id+"-impact",rig,driver.at_tick(45),geometry,planes,summary,45)
	await capture(id+"-rest",rig,driver.frames[-1],geometry,planes,summary,driver.frames[-1].tick)
	if id == "ct-wall":
		for frame in CLIP_FRAMES:
			await capture("ct-wall-motion-%03d" % frame,rig,driver.at_tick(frame*2),geometry,planes,summary,frame*2)
	driver.queue_free()
	actor.queue_free()
	await process_frame

func run() -> void:
	if DisplayServer.get_name() == "headless" or not OS.has_feature("web"):
		printerr("Death review requires the isolated browser renderer")
		quit(1)
		return
	root.size = Vector2i(960,540)
	check(Engine.physics_ticks_per_second == 60, "clip sample spacing assumes native 60 Hz physics")
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.set_paused(true)
	game.set_process(false)
	game.set_physics_process(false)
	game.set_process_input(false)
	game.set_process_unhandled_input(false)
	game.hud.visible = false
	game.player.visible = false
	game.player.set_process(false)
	game.player.set_physics_process(false)
	game.player.set_process_unhandled_input(false)
	for bot in game.bots:
		bot.visible = false
		bot.set_process(false)
		bot.set_physics_process(false)
	game.add_child(camera)
	camera.fov = 75
	camera.far = 200
	camera.current = true
	for team in ["ct","t"]:
		for placement in ["flat","wall","ramp"]: await case_review(team,placement)
	check(capture_count == 18+CLIP_FRAMES, "all expected stills and clip frames captured")
	JavaScriptBridge.eval("window.deathReviewSummary="+JSON.stringify({"failures":failures,"failure_labels":failure_labels,
		"captures":capture_count,"cases":case_summaries,"clip_fps":30,"clip_requested_ticks":[0,178],
		"clip_note":"first three seconds replayed at original 60 Hz timing, followed separately by the rest still; not gameplay FPS"})+";window.mapReviewComplete=true",true)
	print("DEATH_REVIEW_OK captures=",capture_count," failures=",failures)
