extends SceneTree

# Test-only full production map, root Window and real player camera/viewmodel.
# The camera/counts come from a report, but bot positions are deterministic
# staging, not a match replay. Graphics transitions are user presets, not an
# optimization or FPS result. Never disable root 3D or substitute a SubViewport.
const SETUP_FRAMES := 3
const STEADY_FRAMES := 3
const BASE_SIZE := Vector2i(2560, 1242)
const SMALL_SIZE := Vector2i(1600, 900)
const MEASUREMENT := "full-map root-window render correctness; not gameplay or FPS"

var game: Node3D
var camera: Camera3D
var reported: RefCounted
var report: Dictionary
var environment: Environment
var initial_poses: Array
var initial_ai: Array
var skeleton_updates := 0
var checks := 0
var failures := 0
var stage_count := 0
var failure_labels: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		failure_labels.append(label)
		printerr("ENGINE_MAP_REVIEW_FAIL: ", label)

func freeze(node: Node) -> void:
	node.set_process(false)
	node.set_physics_process(false)
	node.set_process_input(false)
	node.set_process_unhandled_input(false)
	node.set_process_unhandled_key_input(false)
	for child in node.get_children(): freeze(child)

func frozen_callbacks(node: Node) -> Dictionary:
	var result := {"process_disabled":not node.is_processing(),"physics_disabled":not node.is_physics_processing(),
		"input_disabled":not node.is_processing_input() and not node.is_processing_unhandled_input() and not node.is_processing_unhandled_key_input()}
	for child in node.get_children():
		var child_state := frozen_callbacks(child)
		for key in result: result[key] = result[key] and child_state[key]
	return result

func _skeleton_updated() -> void:
	skeleton_updates += 1

func pose_snapshot() -> Array:
	var result: Array = []
	for bot in game.bots:
		var locals: Array[Transform3D] = []
		for bone in bot.rig.skeleton.get_bone_count(): locals.append(bot.rig.skeleton.get_bone_pose(bone))
		result.append([bot.index,bot.global_transform,bot.rig.clock,bot.rig.corpse_sleeping,bot.rig.pose.duplicate(),locals])
	return result

func ai_snapshot() -> Array:
	var result: Array = []
	for bot in game.bots:
		result.append([bot.index,bot.health,bot.ammo,bot.shots,bot.think_left,bot.memory,bot.heard,bot.reaction,
			bot.reload_left,bot.cooldown,bot.velocity,bot.path.duplicate(),bot.path_goal,bot.look_goal,
			bot.mission,bot.replans,str(bot.rng.state),bot.target == null])
	return result

func snapshot_hash(value: Array) -> String:
	return var_to_bytes(value).hex_encode().sha256_text()

func vector(value: Vector3) -> Array:
	return [value.x,value.y,value.z]

func color(value: Color) -> Array:
	return [value.r,value.g,value.b,value.a]

func transform_values(value: Transform3D) -> Array:
	return [value.basis.x.x,value.basis.x.y,value.basis.x.z,
		value.basis.y.x,value.basis.y.y,value.basis.y.z,
		value.basis.z.x,value.basis.z.y,value.basis.z.z,
		value.origin.x,value.origin.y,value.origin.z]

func resize_window(size: Vector2i) -> void:
	# Browser resize policy 0 gives this fixture ownership of backing dimensions.
	# Do not assume Window.size alone updates the native canvas drawing buffer.
	JavaScriptBridge.eval("(()=>{const c=document.getElementById('canvas');if(c.width!="+str(size.x)+")c.width="+str(size.x)+";if(c.height!="+str(size.y)+")c.height="+str(size.y)+";})()",true)
	root.size = size

func apply_quality(level: int) -> void:
	game.render_budget.level = level
	game.render_budget.apply(game)

func resize_high(size: Vector2i) -> void:
	resize_window(size)
	apply_quality(2)

func set_player_view(desired: Transform3D) -> void:
	# Keep the actual production Camera3D and its real held/gun children. Only
	# this test gives the camera a top-level transform, avoiding parent inverse
	# roundoff when transferring the reported world basis; native Camera3D still
	# applies its normal orthonormalization when submitting the rendered camera.
	game.player.position = desired.origin - Vector3.UP * game.player.head.position.y
	game.player.rotation = Vector3(0,atan2(desired.basis.z.x,desired.basis.z.z),0)
	game.player.pitch = asin(clampf(-desired.basis.z.y,-1.0,1.0))
	camera.global_transform = desired
	camera.make_current()
	game.player.update_weapon_pose(0.0,0.0)

func move_view(at: Vector3, target: Vector3) -> void:
	set_player_view(Transform3D(Basis.IDENTITY,at).looking_at(target))

func audit_reset() -> void:
	JavaScriptBridge.eval("window.backbufferGlAudit.reset()",true)

func audit_snapshot() -> Dictionary:
	var data = JSON.parse_string(JavaScriptBridge.eval("JSON.stringify(window.backbufferGlAudit.snapshot())",true))
	return data if data is Dictionary else {}

func drain_errors() -> Dictionary:
	# Boundary-only driver reads; the passive audit never queries/consumes errors.
	var data = JSON.parse_string(JavaScriptBridge.eval("""JSON.stringify((()=>{
	const gl=document.getElementById('canvas').getContext('webgl2');
	if(!gl)return {errors:[],drained:false,context_lost:true,reads:0};
	const errors=[];
	for(let reads=1;reads<=32;reads++){
		const error=gl.getError();
		if(error===gl.NO_ERROR)return {errors,drained:true,context_lost:gl.isContextLost(),reads};
		errors.push(error);
	}
	return {errors,drained:false,context_lost:gl.isContextLost(),reads:32};
	})())""",true))
	return data if data is Dictionary else {}

func errors_clear(data: Dictionary) -> bool:
	return data.get("drained",false) and not data.get("context_lost",true) and data.get("errors",[1]).is_empty()

func visible_draws() -> int:
	return root.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE,Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)

func redraw_hud() -> void:
	# Only redraw scheduling; no gameplay or elapsed-time callback is resumed.
	game.hud._process(0.0)

func environment_details() -> Dictionary:
	var sky_material: ProceduralSkyMaterial = environment.sky.sky_material
	return {"background_mode":environment.background_mode,"sky_class":environment.sky.get_class(),
		"sky_material_class":sky_material.get_class(),"tonemap_mode":environment.tonemap_mode,
		"tonemap_exposure":environment.tonemap_exposure,"fog_enabled":environment.fog_enabled,
		"fog_density":environment.fog_density,"fog_sky_affect":environment.fog_sky_affect,
		"fog_light_color":color(environment.fog_light_color),"ambient_energy":environment.ambient_light_energy,
		"ambient_color":color(environment.ambient_light_color),"ssao_enabled":environment.ssao_enabled,
		"ssao_radius":environment.ssao_radius,"ssao_intensity":environment.ssao_intensity,
		"sky_colors":{"top":color(sky_material.sky_top_color),"horizon":color(sky_material.sky_horizon_color),
			"ground_bottom":color(sky_material.ground_bottom_color),"ground_horizon":color(sky_material.ground_horizon_color)}}

func shadow_details() -> Array:
	var result: Array = []
	for light in game.world.find_children("*","DirectionalLight3D",true,false):
		result.append({"enabled":light.shadow_enabled,"mode":light.directional_shadow_mode,
			"distance":light.directional_shadow_max_distance,"blend_splits":light.directional_shadow_blend_splits,
			"bias":light.shadow_bias,"transform":transform_values(light.global_transform)})
	return result

func state_details() -> Dictionary:
	var result := frozen_callbacks(game)
	var poses := pose_snapshot()
	var ai := ai_snapshot()
	result.merge({"paused":game.paused,"game_elapsed":game.elapsed,"phase":game.phase,"phase_left":game.phase_left,
		"silent_test":game.silent_test,"muted":game.sound.muted,"mouse_captured":Input.mouse_mode == Input.MOUSE_MODE_CAPTURED,
		"operators":game.operator_details(),"poses_unchanged":poses == initial_poses,"ai_unchanged":ai == initial_ai,
		"sleeping_skeleton_updates":reported.sleeping_updates,"skeleton_updates":skeleton_updates,
		"poses_sha256":snapshot_hash(poses),"ai_sha256":snapshot_hash(ai),"total_bots":game.bots.size(),
		"player_position":vector(game.player.global_position),"player_yaw":game.player.rotation.y,"pitch":game.player.pitch})
	return result

func viewmodel_details() -> Dictionary:
	var bounds: AABB = game.player.weapon_clearance.bounds
	return {"visible":game.player.held.is_visible_in_tree() and game.player.gun.is_visible_in_tree(),
		"camera_child":game.player.held.get_parent() == camera,"slot":game.player.slot,"gun_name":game.player.gun.name,
		"held_local":transform_values(game.player.held.transform),"held_world":transform_values(game.player.held.global_transform),
		"gun_local":transform_values(game.player.gun.transform),"bounds":vector(bounds.position)+vector(bounds.size),
		"clear":game.player.weapon_clearance.clear,"withdrawal":game.player.weapon_clearance.amount}

func stage(name: String, mutation: Callable) -> void:
	print("ENGINE_MAP_REVIEW_BEGIN ",name)
	var checks_before := checks
	var failures_before := failures
	var before_errors := drain_errors()
	audit_reset()
	mutation.call()
	var setup_draws: Array[int] = []
	for frame in SETUP_FRAMES:
		redraw_hud()
		await RenderingServer.frame_post_draw
		setup_draws.append(visible_draws())
	var setup := audit_snapshot()
	var setup_errors := drain_errors()
	reported.start_measurement()
	skeleton_updates = 0
	audit_reset()
	var steady_draws: Array[int] = []
	for frame in STEADY_FRAMES:
		redraw_hud()
		await RenderingServer.frame_post_draw
		steady_draws.append(visible_draws())
	var steady := audit_snapshot()
	var steady_errors := drain_errors()
	var render: Dictionary = game.render_budget.details(game.get_viewport())
	var actual_camera: Dictionary = game.camera_details()
	actual_camera.merge({"transform":transform_values(camera.global_transform),"top_level":camera.top_level,"current":camera.is_current()})
	var state := state_details()
	var viewmodel := viewmodel_details()
	var canvas_size = JSON.parse_string(JavaScriptBridge.eval("JSON.stringify([document.getElementById('canvas').width,document.getElementById('canvas').height])",true))
	check(errors_clear(before_errors) and errors_clear(setup_errors) and errors_clear(steady_errors),name+": clear native boundary errors")
	check(not setup.is_empty() and not steady.is_empty(),name+": passive GL audit exists")
	for phase: Dictionary in [setup,steady]:
		if phase.is_empty(): continue
		check(int(phase.contexts) == 1,name+": one owned WebGL2 context")
		check(int(phase.totals.exceptions) == 0 and int(phase.totals.incomplete) == 0,name+": native GL calls/FBO checks succeed")
	if not steady.is_empty():
		check(int(steady.totals.texture_allocations) == 0 and int(steady.totals.renderbuffer_allocations) == 0,name+": stable steady storage")
	for count in setup_draws+steady_draws: check(count > 0,name+": root renders every observed frame")
	check(root.get_class() == "Window" and not root.disable_3d and not root.use_xr,name+": ordinary single-view root Window")
	check(canvas_size == [root.size.x,root.size.y],name+": actual canvas matches physical Window")
	check(render.viewport_pixels == ([1600,900] if root.size == SMALL_SIZE else [2208,1242]),name+": actual drawable excludes pillarboxes")
	check(state.process_disabled and state.physics_disabled and state.input_disabled,name+": no automatic game callbacks/input")
	check(state.game_elapsed == 0.0 and state.phase_left == 100.0 and state.phase == "LIVE",name+": unchanged match clock")
	check(state.silent_test and state.muted and not state.mouse_captured,name+": test audio/focus/input isolation")
	check(state.operators == {"alive":2,"dead":7,"sleeping":7},name+": staged reported operator counts")
	check(state.poses_unchanged and state.ai_unchanged,name+": every rig/AI snapshot is frozen")
	check(state.skeleton_updates == 0 and state.sleeping_skeleton_updates == 0,name+": no steady Skeleton update callbacks; GPU skinning still renders")
	check(viewmodel.visible and viewmodel.camera_child and viewmodel.clear,name+": real first-person weapon is visible and clear")
	check(game.hud.visible and not game.hud.panel.visible and not game.diagnostics,name+": ordinary stable HUD, no diagnostics/pause overlay")
	check(camera == root.get_camera_3d() and actual_camera.mode == "player",name+": actual player camera renders")
	check(environment.background_mode == Environment.BG_SKY and environment.sky != null and environment.fog_enabled
		and environment.tonemap_mode == Environment.TONE_MAPPER_FILMIC,name+": production sky/fog/filmic path")
	var result := {"name":name,"fixture":MEASUREMENT,"build":game.BUILD,"renderer":RenderingServer.get_current_rendering_method(),"setup_frames":SETUP_FRAMES,"steady_frames":STEADY_FRAMES,
		"setup_visible_draw_calls":setup_draws,"steady_visible_draw_calls":steady_draws,"setup_audit":setup,"steady_audit":steady,
		"before_errors":before_errors,"setup_errors":setup_errors,"steady_errors":steady_errors,"render":render,
		"window":{"class":root.get_class(),"size":[root.size.x,root.size.y],"canvas_size":canvas_size,
			"root_3d_enabled":not root.disable_3d,"use_xr":root.use_xr,"subviewports":game.find_children("*","SubViewport",true,false).size()},
		"camera":actual_camera,"environment":environment_details(),"shadows":shadow_details(),"msaa_3d":root.msaa_3d,
		"hud":{"visible":game.hud.visible,"menu_visible":game.hud.panel.visible,"diagnostics":game.diagnostics,
			"manual_redraws":SETUP_FRAMES+STEADY_FRAMES,"size":[game.hud.size.x,game.hud.size.y]},
		"viewmodel":viewmodel,"state":state,"world":{"batching":game.world.batching,
			"static_bodies":game.world.find_children("*","StaticBody3D",true,false).size(),
			"mesh_instances":game.world.find_children("*","MeshInstance3D",true,false).size(),
			"multimesh_instances":game.world.find_children("*","MultiMeshInstance3D",true,false).size()},
		"counter_scope":"All owned-context calls, real root map/HUD/viewmodel and presentation; not uniquely backbuffer3d",
		"error_probe":"Native getError only at boundaries/after PNG; passive audit adds no queries"}
	# Readback and PNG encoding occur strictly after counters, never in steady.
	result.png = Marshalls.raw_to_base64(root.get_texture().get_image().save_png_to_buffer())
	result.final_errors = drain_errors()
	check(errors_clear(result.final_errors),name+": readback leaves no native GL errors")
	result.checks = checks-checks_before
	result.failures = failures-failures_before
	JavaScriptBridge.eval("window.mapReviewCaptures.push("+JSON.stringify(result)+")",true)
	JavaScriptBridge.eval("window.saveMotionCapture(window.mapReviewCaptures.at(-1)).catch(console.error)",true)
	stage_count += 1
	print("ENGINE_MAP_REVIEW_STAGE ",name," failures=",result.failures)

func run() -> void:
	if not OS.has_feature("web") or DisplayServer.get_name() == "headless":
		printerr("ENGINE_MAP_REVIEW_FAIL: real isolated WebGL renderer required")
		quit(1)
		return
	var available = JavaScriptBridge.eval("window.backbufferGlAudit && window.mapReviewCaptures && typeof window.saveMotionCapture==='function' ? 1 : 0",true)
	if available != 1 or not "--test" in OS.get_cmdline_user_args():
		printerr("ENGINE_MAP_REVIEW_FAIL: --test, passive audit and incremental capture sink required")
		quit(1)
		return
	check(RenderingServer.get_current_rendering_method() == "gl_compatibility","production Web Compatibility renderer")
	resize_window(BASE_SIZE)
	check(not root.disable_3d,"root 3D starts enabled and remains enabled")
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	freeze(game)
	game.sound.stop_all()
	game.diagnostics = false
	game.buy_open = false
	game.phase = "LIVE"
	game.phase_left = 100.0
	game.banner_left = 0.0
	game.damage_flash = 0.0
	game.hit_flash = 0.0
	game.player.visible = true
	game.player.velocity = Vector3.ZERO
	game.player.recoil = Vector2.ZERO
	game.player.aimed = false
	game.player.crouched = false
	game.player.reload_left = 0.0
	game.player.flash_left = 0.0
	game.player.muzzle.visible = false
	for bot in game.bots:
		bot.position = game.Layout.on_floor(Vector3(-3+(bot.index%3)*3,0,-25+(bot.index/3)*3))
	var observer := Camera3D.new()
	game.add_child(observer)
	reported = load("res://_reported_view.gd").new()
	report = JSON.parse_string(FileAccess.get_file_as_string("res://_reported_view.json"))
	# Let initial real collision geometry register; every game callback is already
	# disabled. configure() then invokes only the bounded production rig poses.
	await physics_frame
	await process_frame
	reported.configure(game,observer,report)
	camera = game.player.camera
	camera.top_level = true
	camera.fov = observer.fov
	camera.near = observer.near
	camera.far = observer.far
	camera.keep_aspect = observer.keep_aspect
	set_player_view(observer.global_transform)
	observer.free()
	# Direct data assignment keeps the normal HUD/crosshair; do not call
	# set_paused(false), sync_pointer or any input-taking gameplay method.
	game.paused = false
	game.hud.sync_menu()
	freeze(game)
	initial_poses = pose_snapshot()
	initial_ai = ai_snapshot()
	for bot in game.bots: bot.rig.skeleton.skeleton_updated.connect(_skeleton_updated)
	var environments: Array = game.world.find_children("*","WorldEnvironment",true,false)
	check(environments.size() == 1,"one production world environment")
	environment = environments[0].environment
	await stage("reported-high",apply_quality.bind(2))
	await stage("reported-balanced",apply_quality.bind(0))
	await stage("reported-performance",apply_quality.bind(1))
	await stage("reported-high-restored",apply_quality.bind(2))
	await stage("reported-high-resized",resize_high.bind(SMALL_SIZE))
	await stage("reported-high-size-restored",resize_high.bind(BASE_SIZE))
	await stage("overview-high",move_view.bind(Vector3(1,1.65,-33),Vector3(1.5,1.6,-18)))
	await stage("a-site-high",move_view.bind(Vector3(29,4.05,-29),Vector3(36,3.5,-14)))
	check(stage_count == 8,"all eight full-map stages completed")
	var summary := {"stages":stage_count,"checks":checks,"failures":failures,"failure_labels":failure_labels,
		"setup_frames":SETUP_FRAMES,"steady_frames":STEADY_FRAMES,"measurement":MEASUREMENT,
		"reported_source_build":report.build,"reported_camera":report.camera,"reported_operators":report.operators}
	JavaScriptBridge.eval("window.engineMapReviewSummary="+JSON.stringify(summary)+";window.mapReviewComplete=true",true)
	if failures == 0: print("ENGINE_MAP_REVIEW_OK ",checks,"/",checks," checks; 8 stages")
	else: printerr("ENGINE_MAP_REVIEW_FAIL: ",failures,"/",checks," checks failed")
