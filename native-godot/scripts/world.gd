class_name FieldWorld
extends Node3D

const Layout = preload("res://scripts/layout.gd")
const Crate = preload("res://scripts/crate_mesh.gd")
const BATCH_CELL_SIZE := 8.0
# Experimental until repeated same-quality timings show a net benefit.
const CONSOLIDATE_STANDARD_COLORS := false
const PLASTER = preload("res://shaders/plaster.gdshader")
const SURFACE = preload("res://shaders/surface.gdshader")
const WALL_DIFF = preload("res://assets/textures/concrete_wall_001_diff_1k.jpg")
const WALL_NORMAL = preload("res://assets/textures/concrete_wall_001_nor_gl_1k.jpg")
const WALL_ARM = preload("res://assets/textures/concrete_wall_001_arm_1k.jpg")
const FLOOR_DIFF = preload("res://assets/textures/concrete_floor_diff_1k.jpg")
const FLOOR_NORMAL = preload("res://assets/textures/concrete_floor_nor_gl_1k.jpg")
const FLOOR_ARM = preload("res://assets/textures/concrete_floor_arm_1k.jpg")
var materials: Dictionary = {}
var rng := RandomNumberGenerator.new()
var batching: Dictionary = {}
var impact_mesh: BoxMesh

func material(color: Color, metal: float = 0.0) -> StandardMaterial3D:
	var key := str(color) + str(metal)
	if not materials.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.78 if metal == 0.0 else 0.42
		mat.metallic = metal
		materials[key] = mat
	return materials[key]

func stone(color: Color, masonry: float = 0.0) -> Material:
	var key := "stone/" + str(color) + "/" + str(masonry)
	if materials.has(key): return materials[key]
	if masonry > 0 and masonry < 1:
		var brick := ShaderMaterial.new()
		brick.shader = PLASTER
		brick.set_shader_parameter("tint", color)
		brick.set_shader_parameter("masonry", masonry)
		materials[key] = brick
		return brick
	var floor_surface := masonry == 1.0
	var mat := ShaderMaterial.new()
	mat.shader = SURFACE
	mat.set_shader_parameter("tint", color.lightened(0.15))
	mat.set_shader_parameter("diffuse_map", FLOOR_DIFF if floor_surface else WALL_DIFF)
	mat.set_shader_parameter("normal_map", FLOOR_NORMAL if floor_surface else WALL_NORMAL)
	mat.set_shader_parameter("arm_map", FLOOR_ARM if floor_surface else WALL_ARM)
	mat.set_shader_parameter("normal_strength", 0.55 if floor_surface else 0.5)
	mat.set_shader_parameter("texture_scale", 0.32 if floor_surface else 0.25)
	materials[key] = mat
	return mat

func box(at: Vector3, size: Vector3, mat: Material, solid: bool = false, parent: Node3D = self) -> Node3D:
	var root: Node3D = StaticBody3D.new() if solid else Node3D.new()
	root.position = at
	parent.add_child(root)
	var mesh := MeshInstance3D.new()
	var cube := BoxMesh.new()
	cube.size = size
	mesh.mesh = cube
	mesh.material_override = mat
	root.add_child(mesh)
	if solid:
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		collision.shape = shape
		root.add_child(collision)
	return root

func cylinder(at: Vector3, bottom: float, top: float, height: float, mat: Material, parent: Node3D = self) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = bottom
	mesh.top_radius = top
	mesh.height = height
	mesh.radial_segments = 20
	instance.mesh = mesh
	instance.material_override = mat
	instance.position = at
	parent.add_child(instance)
	return instance

func impact_box(at: Vector3, mat: Material) -> Node3D:
	# Identical immutable geometry for every mark; transforms, material overrides
	# and the owning game's eight-second lifetime remain per impact as before.
	if impact_mesh == null:
		impact_mesh = BoxMesh.new()
		impact_mesh.size = Vector3(0.055, 0.055, 0.016)
	var root := Node3D.new()
	root.position = at
	add_child(root)
	var mesh := MeshInstance3D.new()
	mesh.mesh = impact_mesh
	mesh.material_override = mat
	root.add_child(mesh)
	return root

func sign_text(text: String, at: Vector3, yaw: float, color: Color, size: int = 96) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font_size = size
	label.pixel_size = 0.013
	label.position = at
	label.rotation.y = yaw
	label.modulate = color
	label.outline_size = 0
	label.no_depth_test = false
	add_child(label)
	return label

func _ready() -> void:
	rng.seed = 90127
	lighting()
	ground()
	buildings()
	landmarks()
	ct_house()
	doors()
	for index in Layout.COVERS.size():
		crate(Layout.COVERS[index], index)
	site("A", Layout.SITE_A, Color("db7a39"))
	site("B", Layout.SITE_B, Color("db7a39"))
	batch_static_boxes()

func batch_material(mat: Material, cache: Dictionary, variants: Array[Dictionary]) -> Dictionary:
	if cache.has(mat): return cache[mat]
	var result := {"material": mat, "color": Color.WHITE, "use_colors": false}
	# Keep custom shaders, transparent sorting, existing vertex-color semantics
	# and extra passes untouched. Our opaque scenery materials need only a tint.
	if mat is StandardMaterial3D and mat.get_script() == null and mat.next_pass == null \
			and mat.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED \
			and not mat.vertex_color_use_as_albedo and mat.albedo_color.a == 1.0:
		var state: Dictionary = {}
		for property in mat.get_property_list():
			if property.usage & PROPERTY_USAGE_STORAGE and property.name != "albedo_color":
				state[property.name] = mat.get(property.name)
		var shared: StandardMaterial3D
		for variant in variants:
			if variant.state == state:
				shared = variant.material
				break
		if shared == null:
			shared = mat.duplicate()
			shared.albedo_color = Color.WHITE
			shared.vertex_color_use_as_albedo = true
			# Match source_color albedo uniforms: sRGB in Compatibility, converted
			# to linear by StandardMaterial's vertex shader in Forward+/Mobile.
			shared.vertex_color_is_srgb = true
			variants.append({"state": state, "material": shared})
		result = {"material": shared, "color": mat.albedo_color, "use_colors": true}
	cache[mat] = result
	return result

func static_box_groups(consolidate_colors: bool = true) -> Dictionary:
	var groups: Dictionary = {}
	var cache: Dictionary = {}
	var variants: Array[Dictionary] = []
	for instance in find_children("*", "MeshInstance3D", true, false):
		if not instance.mesh is BoxMesh or instance.mesh.size.length() > 32: continue
		var transform := box_transform(instance)
		var mat: Material = instance.material_override
		var info := batch_material(mat, cache, variants) if consolidate_colors else {"material": mat, "color": Color.WHITE, "use_colors": false}
		mat = info.material
		var key := "%d/%d/%d/%d" % [mat.get_instance_id() if mat else 0, floori(transform.origin.x / BATCH_CELL_SIZE), floori(transform.origin.z / BATCH_CELL_SIZE), instance.cast_shadow]
		if not groups.has(key):
			groups[key] = {"material": mat, "transforms": [], "colors": [], "sources": [], "shadow": instance.cast_shadow, "use_colors": info.use_colors}
		groups[key].transforms.append(transform)
		groups[key].colors.append(info.color)
		groups[key].sources.append(instance)
	return groups

func batch_static_boxes(consolidate_colors: bool = CONSOLIDATE_STANDARD_COLORS) -> void:
	# Share opaque material state and put color in each instance. Spatial cells
	# and shadow modes stay independent; custom materials keep their identities.
	# The diagnostic flag allows a same-build rendered comparison with old batches.
	var enabled := (consolidate_colors or "--color-batching" in OS.get_cmdline_user_args()) and "--no-color-batching" not in OS.get_cmdline_user_args()
	var groups := static_box_groups(enabled)
	var unit := BoxMesh.new()
	unit.size = Vector3.ONE
	var count := 0
	var color_batches := 0
	var bodies_before := find_children("*", "StaticBody3D", true, false).size()
	for key in groups:
		var group: Dictionary = groups[key]
		var multi := MultiMesh.new()
		multi.transform_format = MultiMesh.TRANSFORM_3D
		multi.use_colors = group.use_colors
		multi.mesh = unit
		multi.instance_count = group.transforms.size()
		for i in group.transforms.size():
			multi.set_instance_transform(i, group.transforms[i])
			if group.use_colors: multi.set_instance_color(i, group.colors[i])
		var instance := MultiMeshInstance3D.new()
		instance.multimesh = multi
		instance.material_override = group.material
		instance.cast_shadow = group.shadow
		add_child(instance)
		count += group.sources.size()
		if group.use_colors: color_batches += 1
		for source in group.sources:
			source.get_parent().remove_child(source)
			source.queue_free()
	prune_empty(self)
	batching = {"source_boxes": count, "batches": groups.size(), "color_batches": color_batches, "cell_size": BATCH_CELL_SIZE, "bodies_before": bodies_before,
		"bodies_after": find_children("*", "StaticBody3D", true, false).size()}

func box_transform(instance: MeshInstance3D) -> Transform3D:
	var transform := global_transform.affine_inverse() * instance.global_transform
	transform.basis = transform.basis * Basis.from_scale(instance.mesh.size)
	return transform

func prune_empty(node: Node) -> void:
	for child in node.get_children(): prune_empty(child)
	if node != self and node.get_class() == "Node3D" and node.get_child_count() == 0:
		node.get_parent().remove_child(node)
		node.queue_free()

func lighting() -> void:
	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color("457599")
	sky_material.sky_horizon_color = Color("d6c8a3")
	sky_material.ground_bottom_color = Color("796b56")
	sky_material.ground_horizon_color = Color("cfbea0")
	sky_material.sun_angle_max = 4.0
	sky.sky_material = sky_material
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("adc5d2")
	environment.ambient_light_energy = 0.40
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 0.95
	environment.fog_enabled = true
	environment.fog_light_color = Color("c4b493")
	environment.fog_density = 0.0016
	environment.fog_sky_affect = 0.15
	# Compatibility gained SSAO in Godot 4.6: this is an expensive real
	# full-screen pass in our WebGL build, not a skipped desktop-only setting.
	# High is the default; lower-cost presets are explicit user choices.
	environment.ssao_enabled = true
	environment.ssao_radius = 1.3
	environment_node.environment = environment
	add_child(environment_node)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-49, -32, 0)
	sun.light_color = Color("fff0d6")
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 110.0
	sun.shadow_bias = 0.035
	sun.directional_shadow_blend_splits = true
	add_child(sun)

func ground() -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for x in range(-44, 44):
		for z in range(-44, 46):
			if not Layout.inside(Vector2(x + 0.5, z + 0.5)):
				continue
			var a := Layout.on_floor(Vector3(x, 0, z))
			var b := Layout.on_floor(Vector3(x + 1, 0, z))
			var c := Layout.on_floor(Vector3(x + 1, 0, z + 1))
			var d := Layout.on_floor(Vector3(x, 0, z + 1))
			for vertex in [a, b, c, a, c, d]:
				surface.add_vertex(vertex)
	surface.generate_normals()
	var ground_mesh := MeshInstance3D.new()
	ground_mesh.mesh = surface.commit()
	ground_mesh.material_override = stone(Color("aaa18b"), 1.0)
	add_child(ground_mesh)
	ground_mesh.create_trimesh_collision()
	box(Vector3(0, -1.1, 0), Vector3(160, 1, 160), stone(Color("b5a07b")), true)

func buildings() -> void:
	var done: Dictionary = {}
	var wall_mats := [stone(Color("c5af88")), stone(Color("b6a287")), stone(Color("cab99b")), stone(Color("aa9276"), 0.6)]
	var trim := material(Color("dac6a0"))
	for z in range(-44, 46):
		for x in range(-44, 44):
			var p := Vector2i(x, z)
			if done.has(p) or Layout.inside(Vector2(x + 0.5, z + 0.5)):
				continue
			var width := 1
			while x + width < 44 and not done.has(Vector2i(x + width, z)) and not Layout.inside(Vector2(x + width + 0.5, z + 0.5)):
				width += 1
			var depth := 1
			while z + depth < 46:
				var valid := true
				for dx in width:
					if done.has(Vector2i(x + dx, z + depth)) or Layout.inside(Vector2(x + dx + 0.5, z + depth + 0.5)):
						valid = false
						break
				if not valid: break
				depth += 1
			for dx in width:
				for dz in depth:
					done[Vector2i(x + dx, z + dz)] = true
			var h := rng.randf_range(5.8, 8.7)
			var center := Vector3(x + width * 0.5, h * 0.5 - 0.5, z + depth * 0.5)
			box(center, Vector3(width, h + 1, depth), wall_mats[rng.randi_range(0, 3)], true)
			box(Vector3(center.x, h - 0.18, center.z), Vector3(width + 0.12, 0.25, depth + 0.12), trim)
	# Windows are placed on exposed facades, never loose floating props.
	var shutter := material(Color("375967"))
	var dark := material(Color("28353c"))
	for x in range(-42, 43):
		for z in range(-42, 44):
			if (x + z * 3) % 6 != 0 or not Layout.inside(Vector2(x + 0.5, z + 0.5)):
				continue
			for direction in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
				if Layout.inside(Vector2(x + 0.5, z + 0.5) + direction): continue
				var center := Vector3(x + 0.5 + direction.x * 0.49, 3.9, z + 0.5 + direction.y * 0.49)
				center.y += Layout.floor_height(Vector2(x, z)) * 0.3
				var facade := Node3D.new()
				add_child(facade)
				facade.position = center
				facade.rotation.y = 0 if direction.y != 0 else PI * 0.5
				box(Vector3.ZERO, Vector3(1.05, 1.5, 0.05), dark, false, facade)
				box(Vector3(0, -0.8, 0), Vector3(1.24, 0.14, 0.22), trim, false, facade)
				for side in [-1, 1]:
					box(Vector3(side * 0.27, 0, 0), Vector3(0.46, 1.4, 0.12), shutter, false, facade)
				for n in 5:
					box(Vector3(0, n * 0.24 - 0.5, 0), Vector3(0.98, 0.028, 0.15), dark, false, facade)

func crate(rect: Rect2, index: int) -> void:
	var center := rect.get_center()
	var height := 1.1 if index % 3 == 0 else 2.0
	var base := Layout.floor_height(center)
	var tint := Color("806e50") if index % 2 == 0 else Color("6d745d")
	var size := Vector3(rect.size.x, height, rect.size.y)
	var body := box(Vector3(center.x, base + height * 0.5, center.y), size, material(tint), true)
	Crate.replace_visual(body, size, tint, 7000 + index)

func arch(at: Vector3, yaw: float, width: float = 8.0) -> void:
	var parent := Node3D.new()
	add_child(parent)
	parent.position = at
	parent.rotation.y = yaw
	var mat := stone(Color("bda582"), 0.7)
	# Decorative arch stays outside the navigation clearance and above heads.
	for i in 13:
		var angle := float(i) / 12 * PI
		var block := box(Vector3(cos(angle) * width * 0.5, 3.0 + sin(angle) * width * 0.18, 0), Vector3(width * 0.13, 0.52, 0.58), mat, false, parent)
		block.rotation.z = atan2(cos(angle) * width * 0.18, -sin(angle) * width * 0.5)
	for side in [-1, 1]:
		box(Vector3(side * (width * 0.5 + 0.12), 1.5, 0), Vector3(0.35, 3, 0.58), mat, false, parent)

func site(letter: String, at: Vector3, color: Color) -> void:
	var base := Layout.on_floor(at) + Vector3.UP * 0.015
	var mat := material(color.darkened(0.16))
	for side in [-1, 1]:
		box(base + Vector3(side * 4, 0, 0), Vector3(0.10, 0.012, 8), mat)
		box(base + Vector3(0, 0, side * 4), Vector3(8, 0.012, 0.10), mat)
	var letter_node := sign_text(letter, base + Vector3.UP * 0.02, 0, color, 240)
	letter_node.rotation.x = -PI * 0.5

func landmarks() -> void:
	arch(Layout.on_floor(Vector3(28, 0, 18)), 0)
	arch(Vector3(-33, 0, -15), 0, 9.0)
	arch(Vector3(1, 0, -21), 0, 9.0)
	var sandstone := stone(Color("bba580"))
	# Roofed tunnel with warm lamps and real cover from the sun.
	box(Vector3(-33, 4.8, 2), Vector3(10, 0.55, 32), sandstone, true)
	box(Vector3(-17, 4.2, 6), Vector3(22, 0.4, 8), sandstone, true)
	for z in [-10, 0, 10]:
		arch(Vector3(-33, 0, z), 0, 9.2)
		var lamp := OmniLight3D.new()
		lamp.position = Vector3(-33, 3.8, z)
		lamp.light_color = Color("ffcd8b")
		lamp.light_energy = 2.8
		lamp.omni_range = 9.0
		add_child(lamp)
		var glow := material(Color("f5ddac"))
		box(lamp.position + Vector3.UP * 0.35, Vector3(0.65, 0.12, 0.3), glow)
	# Low catwalk parapet: collision and navigation share the same outer walls.
	box(Vector3(18.78, 3.1, -12), Vector3(0.3, 0.8, 13), sandstone)
	sign_text("A  →", Vector3(5.92, 2.9, 7), -PI * 0.5, Color("8b3e27"))
	sign_text("B  ←", Vector3(-4.03, 3.0, 17), PI * 0.5, Color("8b3e27"))
	sign_text("COURTYARD", Vector3(0, 4.5, -37.92), 0, Color("555949"), 62)
	sign_text("A", Vector3(27, 5.2, -37.92), 0, Color("a74528"), 220)
	sign_text("B", Vector3(-29, 3.4, -37.92), 0, Color("a74528"), 220)
	# Original skyline silhouettes; no imported buildings, photos or textures.
	for index in 22:
		var angle := float(index) / 22 * TAU
		var at := Vector3(cos(angle) * 68, 0, sin(angle) * 67)
		var height := rng.randf_range(8, 18)
		var mountain := cylinder(at + Vector3.UP * (height * 0.5 - 2), rng.randf_range(12, 20), 1, height, stone(Color("ac9a7a")))
		mountain.scale.z = 0.7
		mountain.rotation.y = angle
	cylinder(Vector3(-45, 8, -32), 2.0, 1.7, 16, sandstone)
	cylinder(Vector3(-45, 15.8, -32), 2.8, 2.8, 0.6, material(Color("e0c89c")))
	cylinder(Vector3(-45, 17.4, -32), 1.4, 1.2, 3, sandstone)
	cylinder(Vector3(-45, 20, -32), 1.6, 0, 2.4, material(Color("46787c"), 0.25))
	for at in [Vector3(20, 0, 37), Vector3(-41, 0, 26), Vector3(43, 0, -23)]:
		palm(at)

func palm(at: Vector3) -> void:
	var trunk := material(Color("776044"))
	cylinder(at + Vector3.UP * 3.5, 0.27, 0.17, 7, trunk)
	var leaf := material(Color("5c7552"))
	for i in 8:
		var angle := float(i) / 8 * TAU
		var branch := box(at + Vector3(sin(angle) * 1.4, 6.8, cos(angle) * 1.4), Vector3(0.6, 0.08, 3.8), leaf)
		branch.rotation = Vector3(0.2, angle, 0)

func doors() -> void:
	# Partly open reinforced leaves, with shared rotated collision/nav footprints.
	var iron := material(Color("38403b"), 0.62)
	for index in Layout.DOORS.size():
		var door: Dictionary = Layout.DOORS[index]
		var hinge: Vector2 = door.hinge
		var width: float = door.width
		var center_x: float = door.side * width * 0.5
		var base := Layout.door_floor(door)
		var frame := Node3D.new()
		add_child(frame)
		frame.name = "DoorLeaf%d" % index
		frame.position = Vector3(hinge.x,base,hinge.y)
		frame.rotation.y = door.yaw
		var wood := material(Color("695138") if index % 2 == 0 else Color("735c41"))
		box(Vector3(center_x,1.55,0),Vector3(width,3.1,0.30),wood,true,frame)
		for i in 7:
			var x := center_x + (float(i)+0.5)*width/7.0-width*0.5
			var plank := material(Color("816446").darkened(float(i % 3) * 0.055))
			box(Vector3(x,1.55,0),Vector3(width/7-0.025,3.03,0.312),plank,false,frame)
			for height in [0.4, 2.45]:
				for side in [-1,1]: box(Vector3(x,height,side*0.18),Vector3(0.085,0.085,0.035),iron,false,frame)
		for height in [0.4,2.45]: box(Vector3(center_x,height,0),Vector3(width+0.02,0.16,0.34),iron,false,frame)
		for side in [-1,1]:
			box(Vector3(door.side*(width-0.3),1.32,side*0.195),Vector3(0.07,0.25,0.055),iron,false,frame)

func ct_house() -> void:
	# Original modern desert residence over a shaded, open CT undercroft.
	# Upper mass is real cover; all ground supports also exist in Layout.clear.
	var plaster := stone(Color("d5c7b3"))
	var lower := stone(Color("adaba0"))
	var teal := material(Color("486c72"))
	var trim := material(Color("e1d7c3"))
	var dark := material(Color("303e43"))
	var iron := material(Color("475458"),0.35)
	# The east end crosses the 2.2 m A ramp: retain full standing clearance.
	var slab := box(Vector3(2,4.95,-32.5),Vector3(20,0.45,9.5),lower,true)
	slab.name = "CTUndercroftCeiling"
	var residence := box(Vector3(2,6.7,-32.5),Vector3(19.5,3.1,9.0),plaster,true)
	residence.name = "CTResidence"
	for support in Layout.CT_SUPPORTS:
		var p: Vector2 = support.get_center()
		var base := Layout.floor_height(p)
		box(Vector3(p.x,(base+4.95)*0.5,p.y),Vector3(support.size.x,4.95-base,support.size.y),lower,true)
	box(Vector3(2,8.32,-32.5),Vector3(20,0.22,9.5),trim)
	box(Vector3(2,8.65,-36.9),Vector3(19.5,0.6,0.18),plaster)
	for x in [-7.65,11.65]: box(Vector3(x,8.65,-32.5),Vector3(0.18,0.6,9.0),plaster)
	# Deep window frames and inset shutters give the upper storey readable scale.
	for x in [-4.8,-0.4,4.0,8.4]:
		box(Vector3(x,6.75,-27.96),Vector3(1.65,1.85,0.08),dark)
		for side in [-1,1]:
			box(Vector3(x+side*0.81,6.75,-27.88),Vector3(0.16,2.1,0.18),trim)
			box(Vector3(x+side*0.43,6.75,-27.82),Vector3(0.69,1.70,0.13),teal)
		for n in 6: box(Vector3(x,6.07+n*0.25,-27.73),Vector3(1.38,0.045,0.06),dark)
		box(Vector3(x,5.75,-27.80),Vector3(1.95,0.16,0.40),trim)
	# Narrow projecting balcony above the spawn exit; never an invisible wall.
	box(Vector3(2,5.48,-27.42),Vector3(6.8,0.18,1.1),trim)
	for x in range(-1,6): box(Vector3(x,6.1,-26.94),Vector3(0.045,1.10,0.045),iron)
	box(Vector3(2,6.65,-26.94),Vector3(6.8,0.065,0.065),iron)
	for z in [-35.8,-29.2]:
		box(Vector3(2,4.68,z),Vector3(19.5,0.16,0.22),trim)
		var light := OmniLight3D.new()
		light.position = Vector3(2,4.3,z)
		light.omni_range = 8.5
		light.light_color = Color("c6e0e1")
		light.light_energy = 1.6
		light.shadow_enabled = false
		add_child(light)
		box(Vector3(2,4.60,z),Vector3(1.1,0.07,0.20),material(Color("dce9df")))
	# Mounted fascia sign, not floating double-sided text across the exit view.
	box(Vector3(2,4.35,-27.72),Vector3(6.4,0.74,0.10),dark)
	var label := sign_text("CT  /  UNDERCROFT",Vector3(2,4.35,-27.655),0,Color("d3dfd6"),38)
	label.name = "CTUndercroftSign"
	label.double_sided = false
