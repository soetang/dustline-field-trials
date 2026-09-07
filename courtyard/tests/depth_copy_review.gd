extends SceneTree

# Isolated, single-view WebGL correctness evidence. Fresh SubViewports make
# "cold" mean fresh render buffers, not cold shader caches or a timing sample.
# Only this one 3D view renders; the root displays its texture with 3D disabled.
const SETUP_FRAMES := 3
const STEADY_FRAMES := 12
const BASE_SIZE := Vector2i(640, 360)
const LARGE_SIZE := Vector2i(736, 414)
const NO_READER_SHADER := """shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform vec3 tint = vec3(0.08, 0.12, 0.35);
void fragment() { ALBEDO = tint; ALPHA = 1.0; }
"""
const DEPTH_SHADER := """shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
void fragment() {
	float raw = texture(scene_depth, SCREEN_UV).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw * 2.0 - 1.0, 1.0);
	float shade = clamp(abs(view.z) / max(abs(view.w), 0.0001) / 12.0, 0.0, 1.0);
	ALBEDO = mix(vec3(0.08, 0.12, 0.35), vec3(0.15, 0.9, 1.0), shade);
	ALPHA = 1.0;
}
"""
const SCREEN_SHADER := """shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform sampler2D scene_color : hint_screen_texture, repeat_disable, filter_nearest;
void fragment() {
	ALBEDO = texture(scene_color, SCREEN_UV).rgb * vec3(1.0, 0.62, 0.28);
	ALPHA = 1.0;
}
"""
const ALPHA_WRITER_SHADER := """shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_always;
void fragment() { ALBEDO = vec3(0.0); ALPHA = 0.0; }
"""

var view: SubViewport
var display: TextureRect
var scene: Node3D
var camera: Camera3D
var environment: Environment
var depth_panel: MeshInstance3D
var screen_panel: MeshInstance3D
var depth_source: MeshInstance3D
var screen_source: MeshInstance3D
var alpha_writer: MeshInstance3D
var depth_material: ShaderMaterial
var screen_material: ShaderMaterial
var depth_plain: ShaderMaterial
var screen_plain: ShaderMaterial
var reader := "none"
var sample_count := 0
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
		printerr("DEPTH_COPY_REVIEW_FAIL: ", label)

func audit_reset() -> void:
	JavaScriptBridge.eval("window.backbufferGlAudit.reset()", true)

func audit_snapshot() -> Dictionary:
	var data = JSON.parse_string(JavaScriptBridge.eval("JSON.stringify(window.backbufferGlAudit.snapshot())", true))
	return data if data is Dictionary else {}

func drain_errors() -> Dictionary:
	# Explicit boundary-only native error reads. The passive GL audit itself
	# still adds no queries and never consumes getError. Keep both facts visible.
	var source := """JSON.stringify((()=>{
	const gl=document.getElementById('canvas').getContext('webgl2');
	if(!gl)return {errors:[],drained:false,context_lost:true,reads:0};
	const errors=[];
	for(let reads=1;reads<=32;reads++){
		const error=gl.getError();
		if(error===gl.NO_ERROR)return {errors,drained:true,context_lost:gl.isContextLost(),reads};
		errors.push(error);
	}
	return {errors,drained:false,context_lost:gl.isContextLost(),reads:32};
	})())"""
	var data = JSON.parse_string(JavaScriptBridge.eval(source, true))
	return data if data is Dictionary else {}

func errors_clear(data: Dictionary) -> bool:
	return data.get("drained", false) and not data.get("context_lost", true) and data.get("errors", [1]).is_empty()

func shader_material(code: String) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = code
	var material := ShaderMaterial.new()
	material.shader = shader
	return material

func opaque_box(at: Vector3, size: Vector3, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	node.mesh = mesh
	node.position = at
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.85
	node.material_override = material
	scene.add_child(node)
	return node

func panel(at: Vector3) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(1.65, 1.9)
	node.mesh = mesh
	node.position = at
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene.add_child(node)
	return node

func set_readers(value: String) -> void:
	reader = value
	depth_panel.material_override = depth_material if value in ["depth", "both"] else depth_plain
	screen_panel.material_override = screen_material if value in ["screen", "both"] else screen_plain

func build_scene(value: String, ssao: bool, samples: int) -> void:
	view = SubViewport.new()
	view.size = BASE_SIZE
	view.own_world_3d = true
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	view.scaling_3d_scale = 1.0
	view.msaa_3d = Viewport.MSAA_DISABLED if samples == 0 else (Viewport.MSAA_2X if samples == 2 else Viewport.MSAA_4X)
	sample_count = samples
	root.add_child(view)
	display.texture = view.get_texture()
	scene = Node3D.new()
	view.add_child(scene)
	var world_environment := WorldEnvironment.new()
	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("263244")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.65
	environment.ssao_enabled = ssao
	environment.ssao_radius = 1.3
	world_environment.environment = environment
	scene.add_child(world_environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-48, -28, 0)
	light.light_energy = 1.3
	light.shadow_enabled = false # No unrelated shadow-map allocations in audit.
	scene.add_child(light)
	opaque_box(Vector3(0, -0.15, -1), Vector3(9, 0.3, 10), Color("8f9979"))
	depth_source = opaque_box(Vector3(-1.25, 0.85, -0.8), Vector3(1.6, 1.7, 1.3), Color("ce7250"))
	screen_source = opaque_box(Vector3(1.25, 1.25, -2), Vector3(1.6, 2.5, 1.3), Color("4fa693"))
	opaque_box(Vector3(0, 1.9, -4.5), Vector3(7, 3.8, 0.25), Color("cabd93"))
	camera = Camera3D.new()
	camera.position = Vector3(0, 1.5, 6)
	camera.fov = 60
	camera.near = 0.05
	camera.far = 30
	scene.add_child(camera)
	camera.look_at(Vector3(0, 1.5, 0))
	camera.current = true
	depth_material = shader_material(DEPTH_SHADER)
	screen_material = shader_material(SCREEN_SHADER)
	depth_plain = shader_material(NO_READER_SHADER)
	screen_plain = shader_material(NO_READER_SHADER)
	screen_plain.set_shader_parameter("tint", Vector3(0.35, 0.12, 0.04))
	depth_panel = panel(Vector3(-1.15, 1.5, 1.2))
	screen_panel = panel(Vector3(1.15, 1.5, 1.2))
	alpha_writer = null
	set_readers(value)

func close_scene() -> void:
	display.texture = null
	if is_instance_valid(view): view.free()
	view = null
	# Previous deletion commands and the empty root presentation are excluded
	# from the next setup audit. No old 3D viewport survives this boundary.
	for frame in 2: await RenderingServer.frame_post_draw

func add_alpha_writer() -> void:
	# Fit strictly between the opaque reader panels in projection. An invisible
	# depth writer must not hide a later alpha-queue panel and fake an AO change.
	alpha_writer = opaque_box(Vector3(0, 0.7, 1.1), Vector3(0.4, 1.2, 1.0), Color.BLACK)
	alpha_writer.material_override = shader_material(ALPHA_WRITER_SHADER)

func remove_alpha_writer() -> void:
	alpha_writer.free()
	alpha_writer = null

func resize_scene(size: Vector2i) -> void:
	view.size = size
	root.size = size
	display.size = root.get_visible_rect().size

func restore_empty_size() -> void:
	set_readers("none")
	resize_scene(BASE_SIZE)

func shift_depth_source() -> void:
	depth_source.position.z = -2.8

func tint_screen_source() -> void:
	(screen_source.material_override as StandardMaterial3D).albedo_color = Color("d044b8")

func transform_values(value: Transform3D) -> Array:
	return [value.basis.x.x,value.basis.x.y,value.basis.x.z,
		value.basis.y.x,value.basis.y.y,value.basis.y.z,
		value.basis.z.x,value.basis.z.y,value.basis.z.z,
		value.origin.x,value.origin.y,value.origin.z]

func panel_roi(node: MeshInstance3D) -> Array:
	# Inner rectangle, safely away from panel edges/MSAA coverage. Projection is
	# CPU-side; these pixels contain only the opaque buffer-sampling shader.
	var first := camera.unproject_position(node.global_position + Vector3(-0.5, 0.55, 0))
	var second := camera.unproject_position(node.global_position + Vector3(0.5, -0.55, 0))
	var low := Vector2i(first.ceil())
	var high := Vector2i(second.floor())
	return [low.x, low.y, high.x-low.x, high.y-low.y]

func visible_draws() -> int:
	return view.get_render_info(Viewport.RENDER_INFO_TYPE_VISIBLE, Viewport.RENDER_INFO_DRAW_CALLS_IN_FRAME)

func run_stage(name: String, kind: String, mutation: Callable, fresh: bool = false) -> void:
	print("DEPTH_COPY_REVIEW_BEGIN ", name)
	var checks_before := checks
	var failures_before := failures
	if fresh: await close_scene()
	var before_errors := drain_errors()
	audit_reset()
	mutation.call()
	var setup_draws: Array[int] = []
	for frame in SETUP_FRAMES:
		await RenderingServer.frame_post_draw
		setup_draws.append(visible_draws())
	var setup := audit_snapshot()
	var setup_errors := drain_errors()
	audit_reset()
	var steady_draws: Array[int] = []
	for frame in STEADY_FRAMES:
		await RenderingServer.frame_post_draw
		steady_draws.append(visible_draws())
	var steady := audit_snapshot()
	var steady_errors := drain_errors()
	check(errors_clear(before_errors) and errors_clear(setup_errors) and errors_clear(steady_errors), name + ": native GL error drains are clear")
	check(not setup.is_empty() and not steady.is_empty(), name + ": passive native audit available")
	if not setup.is_empty() and not steady.is_empty():
		for phase: Dictionary in [setup, steady]:
			check(int(phase.contexts) == 1, name + ": one owned WebGL2 context")
			check(int(phase.totals.exceptions) == 0 and int(phase.totals.incomplete) == 0, name + ": native FBO checks/calls succeed")
		check(int(steady.totals.texture_allocations) == 0 and int(steady.totals.renderbuffer_allocations) == 0, name + ": no steady storage allocations")
	for count in setup_draws + steady_draws:
		check(count > 0, name + ": single 3D view actually renders every observed frame")
	var uses_depth := depth_panel.material_override == depth_material
	var uses_screen := screen_panel.material_override == screen_material
	var has_writer := is_instance_valid(alpha_writer) and alpha_writer.visible
	var color := (screen_source.material_override as StandardMaterial3D).albedo_color
	var result := {"name":name,"kind":kind,"fresh_viewport":fresh,"reader":reader,
		"fixture":"minimal single-view native depth-copy correctness; no game/input/AI/audio; not FPS",
		"resolution":[view.size.x,view.size.y],"msaa":sample_count,"msaa_3d":view.msaa_3d,
		"ssao":environment.ssao_enabled,"depth_consumer":uses_depth,"screen_consumer":uses_screen,
		"alpha_depth_writer":has_writer,"depth_reader_count":int(uses_depth),"screen_reader_count":int(uses_screen),
		"alpha_depth_writer_count":int(has_writer),"alpha_writer_uses_sampler":false,
		"view_count":1,"own_world_3d":view.own_world_3d,"use_xr":view.use_xr,"root_3d_disabled":root.disable_3d,
		"viewport_update_mode":view.render_target_update_mode,"scale_3d":view.scaling_3d_scale,
		"setup_frames":SETUP_FRAMES,"steady_frames":STEADY_FRAMES,
		"setup_visible_draw_calls":setup_draws,"steady_visible_draw_calls":steady_draws,
		"setup_audit":setup,"steady_audit":steady,"before_errors":before_errors,
		"setup_errors":setup_errors,"steady_errors":steady_errors,
		"renderer":RenderingServer.get_current_rendering_method(),
		"camera":{"transform":transform_values(camera.global_transform),"fov":camera.fov,"near":camera.near,"far":camera.far},
		"environment":{"ssao_radius":environment.ssao_radius,"ssao_intensity":environment.ssao_intensity,
			"ambient_energy":environment.ambient_light_energy,"tonemap_mode":environment.tonemap_mode,"shadows":false},
		"materials":{"reader_alpha":1.0,"reader_depth_write":false,"alpha_writer_alpha":0.0,
			"alpha_writer_depth_write":true,"depth_source_transform":transform_values(depth_source.transform),
			"screen_source_color":[color.r,color.g,color.b,color.a]},
		"panel_rois":{"depth":panel_roi(depth_panel),"screen":panel_roi(screen_panel)},
		"counter_scope":"All owned-context calls; one UPDATE_ALWAYS 3D view plus root presentation, not uniquely backbuffer3d",
		"error_probe":"Explicit getError drains outside counter phases and after PNG; passive audit unchanged"}
	# Capture only after both counter windows; readback/encoding is not steady work.
	result.png = Marshalls.raw_to_base64(view.get_texture().get_image().save_png_to_buffer())
	result.final_errors = drain_errors()
	check(errors_clear(result.final_errors), name + ": readback leaves no native GL errors")
	result.checks = checks - checks_before
	result.failures = failures - failures_before
	JavaScriptBridge.eval("window.mapReviewCaptures.push("+JSON.stringify(result)+")", true)
	JavaScriptBridge.eval("window.saveMotionCapture(window.mapReviewCaptures.at(-1)).catch(console.error)", true)
	stage_count += 1
	print("DEPTH_COPY_REVIEW_STAGE ",name," failures=",result.failures)

func run() -> void:
	if not OS.has_feature("web") or DisplayServer.get_name() == "headless":
		printerr("DEPTH_COPY_REVIEW_FAIL: real isolated WebGL renderer required")
		quit(1)
		return
	var available = JavaScriptBridge.eval("window.backbufferGlAudit && window.mapReviewCaptures && typeof window.saveMotionCapture==='function' ? 1 : 0", true)
	if available != 1:
		printerr("DEPTH_COPY_REVIEW_FAIL: passive audit and incremental capture sink required")
		quit(1)
		return
	check(RenderingServer.get_current_rendering_method() == "gl_compatibility", "native Compatibility SSAO path")
	root.size = BASE_SIZE
	root.disable_3d = true
	display = TextureRect.new()
	display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(display)
	display.size = root.get_visible_rect().size
	for mode in ["none", "depth", "screen", "both"]:
		for ssao in [false, true]:
			for samples in [0, 2, 4]:
				var name := "cold-%s-ssao-%s-msaa-%d" % [mode,"on" if ssao else "off",samples]
				await run_stage(name,"cold",build_scene.bind(mode,ssao,samples),true)
	await run_stage("live-none-start","live",build_scene.bind("none",true,4),true)
	await run_stage("live-depth-added","live",set_readers.bind("depth"))
	await run_stage("live-both-added","live",set_readers.bind("both"))
	await run_stage("live-screen-only","live",set_readers.bind("screen"))
	await run_stage("live-none-restored","live",set_readers.bind("none"))
	await run_stage("live-alpha-writer","live",add_alpha_writer)
	await run_stage("live-alpha-removed","live",remove_alpha_writer)
	await run_stage("live-both-restored","live",set_readers.bind("both"))
	await run_stage("live-both-resized","live",resize_scene.bind(LARGE_SIZE))
	await run_stage("live-none-resized-back","live",restore_empty_size)
	await run_stage("control-both-reference","control",build_scene.bind("both",false,0),true)
	await run_stage("control-depth-shift","control",shift_depth_source)
	await run_stage("control-screen-tint","control",tint_screen_source)
	check(stage_count == 37,"all cold, lifecycle and buffer-positive-control captures")
	JavaScriptBridge.eval("window.depthCopyReviewSummary="+JSON.stringify({"stages":stage_count,"checks":checks,
		"failures":failures,"failure_labels":failure_labels,"cold_cases":24,"live_cases":10,"control_cases":3,
		"setup_frames":SETUP_FRAMES,"steady_frames":STEADY_FRAMES,"measurement":"native WebGL image/call correctness, not FPS"})+";window.mapReviewComplete=true", true)
	if failures == 0: print("DEPTH_COPY_REVIEW_OK ",checks,"/",checks," checks; 37 stages")
	else: printerr("DEPTH_COPY_REVIEW_FAIL: ",failures,"/",checks," checks failed")
