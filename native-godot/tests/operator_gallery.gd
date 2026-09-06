extends SceneTree

## An unobstructed, consistently lit asset review, not a gameplay screenshot.
const Models = preload("res://scripts/models.gd")
const Rig = preload("res://scripts/operator_rig.gd")
var scene := Node3D.new()
var camera := Camera3D.new()
var folder := "res://builds/operator-gallery"
var label := "current"
var actors: Array[Node3D] = []
var rigs: Array[FieldOperatorRig] = []

func _initialize() -> void:
	call_deferred("run")

func frames(count: int) -> void:
	for i in count: await process_frame

func capture(view: String, from: Vector3, at: Vector3) -> void:
	camera.position = from
	camera.look_at(at)
	await frames(8)
	await RenderingServer.frame_post_draw
	var filename := ProjectSettings.globalize_path(folder).path_join(label + "-" + view + ".png")
	var error := root.get_texture().get_image().save_png(filename)
	print("GALLERY_CAPTURE ", filename, " result=", error)
	assert(error == OK)

func run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("Operator gallery needs a real renderer")
		quit(1)
		return
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-dir="): folder = arg.trim_prefix("--capture-dir=")
		if arg.begins_with("--label="): label = arg.trim_prefix("--label=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	root.add_child(scene)
	current_scene = scene
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("b2c1c6")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("c0cfda")
	environment.environment.ambient_light_energy = 0.65
	scene.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-43, 152, 0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	scene.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, -35, 0)
	fill.light_color = Color("c1d5e7")
	fill.light_energy = 0.4
	scene.add_child(fill)
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.mesh = PlaneMesh.new()
	floor_mesh.mesh.size = Vector2(200, 200)
	var floor_mat := StandardMaterial3D.new()
	floor_mat.albedo_color = Color("51524d")
	floor_mat.roughness = 0.95
	floor_mesh.material_override = floor_mat
	scene.add_child(floor_mesh)
	for i in 2:
		var actor: Node3D = Models.ASSETS["ct_operator" if i == 0 else "t_operator"].instantiate()
		scene.add_child(actor)
		Models.prepare(actor)
		if "--dump-bones" in OS.get_cmdline_user_args():
			for skeleton in actor.find_children("*", "Skeleton3D", true, false):
				print("GALLERY_SKELETON ", skeleton.global_transform)
				for bone in skeleton.get_bone_count():
					print(skeleton.get_bone_name(bone), " ", skeleton.get_bone_global_rest(bone))
		var low := INF
		var triangles := 0
		var surfaces := 0
		for mesh in actor.find_children("*", "MeshInstance3D", true, false):
			var bounds: AABB = mesh.global_transform * mesh.get_aabb()
			low = minf(low, bounds.position.y)
			for surface in mesh.mesh.get_surface_count():
				var arrays: Array = mesh.mesh.surface_get_arrays(surface)
				triangles += arrays[Mesh.ARRAY_INDEX].size() / 3
				surfaces += 1
		actor.position += Vector3(-0.60 if i == 0 else 0.60, -low, 0)
		actors.append(actor)
		var rig := Rig.new()
		rig.setup(actor)
		rigs.append(rig)
		print("GALLERY_ASSET ", i, " triangles=", triangles, " surfaces=", surfaces, " foot_offset=", -low)
	camera.fov = 40
	camera.current = true
	scene.add_child(camera)
	await frames(20)
	await capture("front", Vector3(0, 1.10, -4.7), Vector3(0, 1.04, 0))
	await capture("quarter", Vector3(3, 1.65, -4.5), Vector3(0, 1, 0))
	await capture("back", Vector3(0, 1.35, 4.7), Vector3(0, 1, 0))
	await capture("ct-close", Vector3(-0.45, 1.55, -1.60), Vector3(-0.60, 1.45, 0))
	await capture("t-close", Vector3(0.72, 1.55, -1.60), Vector3(0.60, 1.45, 0))
	for frame in 60:
		for rig in rigs: rig.update_pose(1.0/60, Vector3(0,0,-4.65),Vector2.ZERO,0,false,false)
	for frame in 8:
		for rig in rigs:
			for tick in 4: rig.update_pose(1.0/60,Vector3(0,0,-4.65),Vector2.ZERO,0,false,false)
		await capture("stride-%02d" % frame,Vector3(2.8,1.4,-4.2),Vector3(0,1,0))
	for frame in 45:
		for rig in rigs: rig.update_pose(1.0/60,Vector3.ZERO,Vector2(0.18,0.2),1.1,false,false)
	await capture("reload",Vector3(2.8,1.4,-4.2),Vector3(0,1,0))
	print("OPERATOR_GALLERY_OK")
	scene.queue_free()
	await process_frame
	quit()
