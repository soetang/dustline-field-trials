extends SceneTree

## Exported only as an isolated test entry point by the review runner. No game,
## actors, input, audio, SSAO, shadow maps, or additional screen/depth readers.
## Audit snapshots count the whole owned context, not just backbuffer3d.
const SETUP_FRAMES := 3
const STEADY_FRAMES := 12
const DEPTH_SHADER := """shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
void fragment() {
	float raw = texture(scene_depth, SCREEN_UV).r;
	vec4 view = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, raw * 2.0 - 1.0, 1.0);
	float shade = clamp(abs(view.z) / max(abs(view.w), 0.0001) / 12.0, 0.0, 1.0);
	ALBEDO = mix(vec3(0.08, 0.12, 0.35), vec3(0.15, 0.9, 1.0), shade);
	ALPHA = 0.94;
}
"""
const SCREEN_SHADER := """shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
uniform sampler2D scene_color : hint_screen_texture, repeat_disable, filter_nearest;
void fragment() {
	ALBEDO = texture(scene_color, SCREEN_UV).rgb * vec3(1.0, 0.62, 0.28);
	ALPHA = 0.94;
}
"""
var scene: Node3D
var screen_consumer: MeshInstance3D
var resolution := Vector2i(640, 360)
var expect_cached := false
var capture_png := false
var checks := 0
var failures := 0
var stage_count := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("ENGINE_LIFECYCLE_FAIL: ", label)

func audit_reset() -> void:
	JavaScriptBridge.eval("window.backbufferGlAudit.reset()", true)

func audit_snapshot() -> Dictionary:
	var data = JSON.parse_string(JavaScriptBridge.eval("JSON.stringify(window.backbufferGlAudit.snapshot())", true))
	return data if data is Dictionary else {}

func opaque_box(position: Vector3, size: Vector3, color: Color) -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = position
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.85
	mesh.material_override = material
	scene.add_child(mesh)

func consumer(code: String, position: Vector3) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(1.65, 1.9)
	mesh.mesh = quad
	mesh.position = position
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var shader := Shader.new()
	shader.code = code
	var material := ShaderMaterial.new()
	material.shader = shader
	mesh.material_override = material
	scene.add_child(mesh)
	return mesh

func build_depth_scene() -> void:
	root.size = resolution
	root.msaa_3d = Viewport.MSAA_DISABLED
	scene = Node3D.new()
	root.add_child(scene)
	var world_environment := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("263244")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.65
	environment.ssao_enabled = false
	world_environment.environment = environment
	scene.add_child(world_environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-48, -28, 0)
	light.light_energy = 1.3
	light.shadow_enabled = false
	scene.add_child(light)
	opaque_box(Vector3(0, -0.15, -1), Vector3(9, 0.3, 10), Color("8f9979"))
	opaque_box(Vector3(-1.25, 0.85, -0.8), Vector3(1.6, 1.7, 1.3), Color("ce7250"))
	opaque_box(Vector3(1.25, 1.25, -2), Vector3(1.6, 2.5, 1.3), Color("4fa693"))
	opaque_box(Vector3(0, 1.9, -4.5), Vector3(7, 3.8, 0.25), Color("cabd93"))
	var camera := Camera3D.new()
	camera.position = Vector3(0, 2.1, 6)
	camera.fov = 60
	camera.near = 0.05
	camera.far = 30
	scene.add_child(camera)
	camera.look_at(Vector3(0, 1.2, -1))
	camera.current = true
	consumer(DEPTH_SHADER, Vector3(-1.15, 1.4, 1.2))

func add_screen_consumer() -> void:
	screen_consumer = consumer(SCREEN_SHADER, Vector3(1.15, 1.4, 1.2))

func resize_scene() -> void:
	root.size = resolution + Vector2i(96, 54)

func use_msaa_2x() -> void:
	root.msaa_3d = Viewport.MSAA_2X

func use_msaa_4x() -> void:
	root.msaa_3d = Viewport.MSAA_4X

func restore_scene() -> void:
	root.msaa_3d = Viewport.MSAA_DISABLED
	root.size = resolution

func run_stage(name: String, mutation: Callable) -> void:
	print("ENGINE_LIFECYCLE_BEGIN ", name)
	var checks_before := checks
	var failures_before := failures
	audit_reset()
	mutation.call()
	for frame in SETUP_FRAMES: await RenderingServer.frame_post_draw
	var setup := audit_snapshot()
	audit_reset()
	for frame in STEADY_FRAMES: await RenderingServer.frame_post_draw
	var steady := audit_snapshot()
	check(not setup.is_empty() and not steady.is_empty(), name + ": native GL audit available")
	if not setup.is_empty() and not steady.is_empty():
		check(int(steady.contexts) == 1, name + ": exactly one owned canvas WebGL2 context")
		check(int(setup.totals.exceptions) == 0 and int(steady.totals.exceptions) == 0, name + ": native calls did not throw")
		check(int(setup.totals.incomplete) == 0 and int(steady.totals.incomplete) == 0, name + ": all observed native FBO checks complete")
		check(int(setup.totals.checks) > 0, name + ": reconfiguration still performs native validation")
		check(int(setup.totals.texture_allocations) > 0, name + ": setup allocates texture storage")
		check(int(setup.totals.attachments) > 0, name + ": setup attaches framebuffer storage")
		check(int(steady.totals.texture_allocations) == 0 and int(steady.totals.attachments) == 0, name + ": steady storage stays unchanged")
		check(int(steady.totals.blits) > 0, name + ": frames continue producing native blits")
		if expect_cached:
			check(int(steady.totals.checks) == 0, name + ": patched simple fixture has no recurring FBO checks")
		else:
			check(int(steady.totals.checks) >= STEADY_FRAMES, name + ": baseline repeats native FBO validation")
		if name == "depth-only":
			check(int(setup.totals.depth_texture_allocations) > 0 and int(setup.totals.depth_attachments) > 0, name + ": depth storage created")
		elif name == "depth-and-color":
			check(int(setup.totals.color_texture_allocations) > 0 and int(setup.totals.color_attachments) > 0, name + ": adding screen reader creates color storage")
			check(int(setup.calls.createFramebuffer) == 0 and int(setup.calls.deleteFramebuffer) == 0 and int(setup.totals.depth_texture_allocations) == 0, name + ": color is added without replacing the depth framebuffer")
		if name == "msaa-2x" or name == "msaa-4x":
			var sample_count := "2" if name == "msaa-2x" else "4"
			check(int(setup.multisample_samples[sample_count]) > 0, name + ": native storage receives requested sample count")
	var result := {"name": name, "fixture": "isolated native framebuffer lifecycle; no game, input, AI, HUD, audio, SSAO or shadows",
		"expect_cached_backbuffer": expect_cached, "resolution": [root.size.x, root.size.y],
		"msaa_3d": root.msaa_3d, "depth_consumer": true, "screen_consumer": screen_consumer != null,
		"setup_frames": SETUP_FRAMES, "steady_frames": STEADY_FRAMES,
		"setup_audit": setup, "steady_audit": steady,
		"checks": checks - checks_before, "failures": failures - failures_before,
		"counter_scope": "All owned-context framebuffer checks, not uniquely the patched backbuffer. This simple fixture removes unrelated effects.",
		"renderer": RenderingServer.get_current_rendering_method()}
	if capture_png:
		# Readback/PNG encoding is after both audit snapshots, not in steady work.
		result.png = Marshalls.raw_to_base64(root.get_texture().get_image().save_png_to_buffer())
	print("ENGINE_LIFECYCLE_STAGE ", name, " checks=", result.checks, " failures=", result.failures,
		" setup_checks=", setup.get("totals", {}).get("checks", -1), " steady_checks=", steady.get("totals", {}).get("checks", -1))
	JavaScriptBridge.eval("window.mapReviewCaptures.push(" + JSON.stringify(result) + ")", true)
	stage_count += 1

func run() -> void:
	print("ENGINE_LIFECYCLE_START")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--width="): resolution.x = clampi(arg.get_slice("=", 1).to_int(), 160, 1920)
		if arg.begins_with("--height="): resolution.y = clampi(arg.get_slice("=", 1).to_int(), 90, 1080)
		expect_cached = expect_cached or arg == "--expect-cached-backbuffer"
		capture_png = capture_png or arg == "--capture"
	if not OS.has_feature("web"):
		printerr("ENGINE_LIFECYCLE_FAIL: WebGL export and backbufferGlAudit init hook required; native/dummy renderer is not evidence")
		quit(1)
		return
	# The Web bridge marshals JavaScript booleans as integer 0/1. Comparing
	# that Variant directly to a GDScript bool can abort this release fixture.
	var available = JavaScriptBridge.eval("window.backbufferGlAudit && window.mapReviewCaptures ? 1 : 0", true)
	if available != 1:
		printerr("ENGINE_LIFECYCLE_FAIL: missing backbufferGlAudit init hook or capture sink")
		quit(1)
		return
	await run_stage("depth-only", build_depth_scene)
	await run_stage("depth-and-color", add_screen_consumer)
	await run_stage("resized", resize_scene)
	await run_stage("msaa-2x", use_msaa_2x)
	await run_stage("msaa-4x", use_msaa_4x)
	await run_stage("restored", restore_scene)
	JavaScriptBridge.eval("window.engineLifecycleSummary=" + JSON.stringify({"stages": stage_count, "checks": checks, "failures": failures}) + "; window.mapReviewComplete=true", true)
	if failures == 0:
		print("ENGINE_LIFECYCLE_OK ", checks, "/", checks, " checks; six stages; native framebuffer audit")
	else:
		printerr("ENGINE_LIFECYCLE_FAIL: ", failures, "/", checks, " checks failed")
