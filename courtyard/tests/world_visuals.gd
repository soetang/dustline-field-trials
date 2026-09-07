extends SceneTree

const Probe = preload("res://engine/experiments/world_visuals.gd")
const World = preload("res://scripts/world.gd")
const Budget = preload("res://scripts/render_budget.gd")
# Remote five-view approval, run 34154727752; no renderer test is implied here.
const APPROVED_SHADER_SHA256 := "c9914dc387ffbf199390e7ab3a0234f6305d41d44026bd64dd24646092ec9f9c"
var passed := 0
var failed := 0

class GameStub:
	extends Node3D
	var world: Node3D

class LegacyWorld:
	extends "res://scripts/world.gd"
	# Reconstruct only the reviewed legacy factories, not a second map. Reverse
	# the new authored literals, then run the frozen candidate on these sources.
	# A missed promotion callsite still gets restyled only on the reference side.
	func material(color: Color, metal: float = 0.0, _roughness_override: float = -1.0) -> StandardMaterial3D:
		for old: String in Probe.JOINERY_PALETTE:
			if color == Color(Probe.JOINERY_PALETTE[old]): color = Color(old); break
		for plank in 3:
			if color == Color("79563b").darkened(plank * 0.055):
				color = Color("816446").darkened(plank * 0.055)
				break
		return super.material(color, metal)

	func stone(color: Color, masonry: float = 0.0) -> Material:
		for old: String in Probe.WALL_PALETTE:
			if color == Color(Probe.WALL_PALETTE[old]): color = Color(old); break
		if color == Color("b5aa95"): color = Color("aaa18b")
		if color == Color("b6a58b"): color = Color("aa9276")
		if color == Color("cbbb9e"): color = Color("bda582")
		var key := "stone/" + str(color) + "/" + str(masonry)
		if materials.has(key): return materials[key]
		var mat := ShaderMaterial.new()
		if masonry > 0.0 and masonry < 1.0:
			mat.shader = Probe.LEGACY_PLASTER
			mat.set_shader_parameter("tint", color)
			mat.set_shader_parameter("masonry", masonry)
		else:
			var floor_surface := masonry == 1.0
			mat.shader = Probe.LEGACY_SURFACE
			mat.set_shader_parameter("tint", color.lightened(0.15))
			mat.set_shader_parameter("diffuse_map", FLOOR_DIFF if floor_surface else Probe.WALL_DIFF)
			mat.set_shader_parameter("normal_map", FLOOR_NORMAL if floor_surface else Probe.WALL_NORMAL)
			mat.set_shader_parameter("arm_map", FLOOR_ARM if floor_surface else Probe.WALL_ARM)
			mat.set_shader_parameter("texture_scale", 0.32 if floor_surface else 0.25)
			mat.set_shader_parameter("normal_strength", 0.55 if floor_surface else 0.5)
		materials[key] = mat
		return mat

	func lighting() -> void:
		super.lighting()
		var environment: Environment = find_children("*", "WorldEnvironment", true, false)[0].environment
		var sky: ProceduralSkyMaterial = environment.sky.sky_material
		sky.sky_top_color = Color("457599")
		sky.sky_horizon_color = Color("d6c8a3")
		sky.ground_bottom_color = Color("796b56")
		sky.ground_horizon_color = Color("cfbea0")
		environment.ambient_light_color = Color("adc5d2")
		environment.ambient_light_energy = 0.40
		environment.tonemap_exposure = 0.95
		environment.fog_light_color = Color("c4b493")
		environment.fog_density = 0.0016
		environment.fog_sky_affect = 0.15

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("WORLD_VISUALS_FAIL: ",label)

func material_state(material: Material) -> Array:
	if material is ShaderMaterial:
		var values: Array = [material.shader,material.next_pass]
		for name in ["tint","base_tint","diffuse_map","normal_map","arm_map","texture_scale","normal_strength","masonry","floor_surface"]:
			values.append(material.get_shader_parameter(name))
		return values
	return [material.albedo_color,material.roughness,material.metallic,material.next_pass]

func shadow_state(world: Node3D) -> Array:
	var result: Array = []
	for node in world.find_children("*","Light3D",true,false):
		var value := [node,node.transform,node.light_color,node.light_energy,node.shadow_enabled,node.shadow_bias]
		if node is DirectionalLight3D:
			value.append_array([node.directional_shadow_mode,node.directional_shadow_max_distance,node.directional_shadow_blend_splits])
		elif node is OmniLight3D: value.append(node.omni_range)
		result.append(value)
	return result

func properties(resource: Resource) -> Dictionary:
	var result: Dictionary = {}
	for property in resource.get_property_list():
		if not (property.usage & PROPERTY_USAGE_STORAGE) or property.name.begins_with("resource_") or property.name in ["script", "metadata/_edit_lock_"]: continue
		var value: Variant = resource.get(property.name)
		if value is Shader: value = value.get_code()
		elif value is Resource and not value is Texture: value = properties(value)
		result[property.name] = value
	return result

func compare_production(reference: FieldWorld) -> void:
	var game := GameStub.new()
	game.world = World.new()
	game.add_child(game.world)
	root.add_child(game)
	var world := game.world as FieldWorld
	check(Probe.SHADER.get_code().sha256_text() == APPROVED_SHADER_SHA256, "reviewed candidate shader has not drifted since remote approval")
	check(World.SURFACE.get_code() == Probe.SHADER.get_code(), "production shader is byte-identical to the approved five-view candidate")
	check(Probe.state(world) == Probe.state(reference) and world.batching == reference.batching, "direct construction has exactly the approved scene inventory and batching")
	var expected := reference.find_children("*", "Node", true, false)
	var actual := world.find_children("*", "Node", true, false)
	check(actual.size() == expected.size(), "direct and reviewed world node counts match")
	var geometry := actual.size() == expected.size()
	var bindings := geometry
	var groups: Dictionary = {}
	var reverse_groups: Dictionary = {}
	var material_count := 0
	var differences: Array = []
	for i in mini(actual.size(), expected.size()):
		var a: Node = actual[i]
		var b: Node = expected[i]
		geometry = geometry and a.get_class() == b.get_class()
		if a is Node3D and b is Node3D: geometry = geometry and a.transform == b.transform
		if a is GeometryInstance3D and b is GeometryInstance3D:
			geometry = geometry and a.cast_shadow == b.cast_shadow and a.visible == b.visible
			var am: Material = a.material_override
			var bm: Material = b.material_override
			# Detailed crates bind their one material on the mesh surface itself.
			if a is MeshInstance3D and a.mesh != null and am == null: am = a.get_active_material(0)
			if b is MeshInstance3D and b.mesh != null and bm == null: bm = b.get_active_material(0)
			if am != null and bm != null:
				if properties(am) != properties(bm) and differences.size() < 4:
					var ap := properties(am)
					var bp := properties(bm)
					for key in ap:
						if ap[key] != bp.get(key): differences.append([i, key, str(ap[key]), str(bp.get(key))])
				bindings = bindings and properties(am) == properties(bm)
				if groups.has(am): bindings = bindings and groups[am] == bm
				if reverse_groups.has(bm): bindings = bindings and reverse_groups[bm] == am
				groups[am] = bm
				reverse_groups[bm] = am
				material_count += 1
			else: bindings = bindings and am == bm
		if a is MultiMeshInstance3D and b is MultiMeshInstance3D:
			geometry = geometry and a.multimesh.instance_count == b.multimesh.instance_count and a.multimesh.buffer == b.multimesh.buffer
		if a is CollisionShape3D and b is CollisionShape3D: geometry = geometry and properties(a.shape) == properties(b.shape)
		if a is Light3D and b is Light3D:
			for name in ["light_color", "light_energy", "shadow_enabled", "shadow_bias"]:
				geometry = geometry and a.get(name) == b.get(name)
	check(geometry, "direct construction preserves transforms, collision shapes, lights, shadows and instance buffers")
	if not bindings or material_count != 323: print("WORLD_VISUALS_BINDINGS ", material_count, " ", differences)
	check(bindings and material_count == 323, "all 323 material bindings/properties and sharing groups exactly match the reviewed candidate")
	var environment: Environment = world.find_children("*", "WorldEnvironment", true, false)[0].environment
	var approved: Environment = reference.find_children("*", "WorldEnvironment", true, false)[0].environment
	check(properties(environment) == properties(approved), "direct environment and sky properties exactly match the approved candidate")
	var before := Probe.geometry_signature(world)
	check(Probe.new().apply(game).error == "already_promoted" and before == Probe.geometry_signature(world), "legacy visual hook fails closed on promoted source")
	var budget := Budget.new()
	var original_environment := properties(environment)
	var shared := world.materials.values().duplicate()
	for level in [0, 1, 2]:
		budget.level = level
		budget.apply(game)
		check(world.materials.values() == shared, "quality %d retains authored material identities" % level)
	check(properties(environment) == original_environment and environment.ssao_enabled and root.scaling_3d_scale == 1.0, "High restores full SSAO/native resolution and the approved lighting")
	var generic := world.material(Color("486c72"))
	var rough := world.material(Color("486c72"), 0.0, 0.86)
	check(generic.albedo_color == Color("486c72") and is_equal_approx(generic.roughness, 0.78), "generic factory does not remap arbitrary colors or default roughness")
	check(rough != generic and rough == world.material(Color("486c72"), 0.0, 0.86) and is_equal_approx(rough.roughness, 0.86), "explicit roughness has a distinct reusable cache entry")
	game.free()

func run() -> void:
	# Dummy renderer only: these verify resources/state, not shader compilation,
	# visual quality, rendering equivalence, driver costs or hardware FPS.
	var code: String = Probe.SHADER.get_code()
	check(code.count("texture(") == 3,"three existing material texture reads")
	check(not code.contains("ALPHA") and not code.contains("DEPTH") and not code.contains("VERTEX ="),"opaque, undisplaced single-pass shader")
	check(not code.contains("TIME") and not code.contains("hint_screen_texture") and not code.contains("hint_depth_texture"),"no animation or backbuffer readers")
	check(not code.contains("sin("),"new masonry has no old sine-noise loop")
	check(code.contains("source_color") and code.contains("hint_normal") and code.contains("filter_linear_mipmap_anisotropic"),"colour-space and filtering declarations preserved")
	check(Probe.new().apply(null).error == "invalid_game","invalid input fails without mutation")
	var game := GameStub.new()
	game.world = LegacyWorld.new()
	game.add_child(game.world)
	root.add_child(game)
	var world := game.world as FieldWorld
	var before := Probe.geometry_signature(world)
	var original_state := Probe.state(world)
	var original_batching := world.batching.duplicate(true)
	var shadows := shadow_state(world)
	var settings := [root.scaling_3d_scale,root.msaa_3d]
	var source_states: Dictionary = {}
	for material in world.materials.values(): source_states[material] = material_state(material)
	var environment_node: WorldEnvironment = world.find_children("*","WorldEnvironment",true,false)[0]
	var environment: Environment = environment_node.environment
	var sky: Sky = environment.sky
	var sky_material: ProceduralSkyMaterial = sky.sky_material
	var source_lighting := [environment.ambient_light_color,environment.ambient_light_energy,environment.fog_density,
		environment.tonemap_exposure,sky_material.sky_top_color,sky_material.sky_horizon_color]
	var probe := Probe.new()
	var result := probe.apply(game)
	check(result.error == "","reconstructed reviewed legacy world is supported")
	check(result.changed_materials >= 12 and result.changed_instances >= 100,"world-wide material treatment, not one prop")
	check(result.geometry_unchanged and before == Probe.geometry_signature(world),"all native meshes, transforms, colliders and shadow modes untouched")
	check(result.batching_unchanged and original_batching == world.batching,"existing batching retained exactly")
	check(result.quality_unchanged and settings == [root.scaling_3d_scale,root.msaa_3d],"native resolution and MSAA unchanged")
	check(shadows == shadow_state(world),"every light, colour, intensity, shadow split/range and transform unchanged")
	for field in original_state:
		if field == "bound_textures": continue
		check(result.before[field] == result.after[field] and result.before[field] == original_state[field],field+" count unchanged")
	check(result.new_texture_resources == 0 and result.extra_passes == 0,"no new texture resource or rendering pass")
	var originals_unchanged := true
	for material in source_states: originals_unchanged = originals_unchanged and material_state(material) == source_states[material]
	check(originals_unchanged,"source/cached materials never mutated in place")
	check(environment_node.environment != environment and environment_node.environment.sky != sky
		and environment_node.environment.sky.sky_material != sky_material,"environment, sky and sky material independently cloned")
	check(source_lighting == [environment.ambient_light_color,environment.ambient_light_energy,environment.fog_density,
		environment.tonemap_exposure,sky_material.sky_top_color,sky_material.sky_horizon_color],"original environment/sky remains intact")
	var current: Environment = environment_node.environment
	check(result.ssao_unchanged and current.ssao_enabled == environment.ssao_enabled
		and current.ssao_radius == environment.ssao_radius and current.ssao_intensity == environment.ssao_intensity,"full SSAO unchanged")
	check(current.fog_enabled == environment.fog_enabled and current.tonemap_mode == environment.tonemap_mode
		and current.reflected_light_source == environment.reflected_light_source,"fog, filmic and sky-reflection paths retained")
	var clones: Dictionary = {}
	var shared := true
	var existing_textures := true
	var opaque := true
	for entry in probe._assignments:
		if clones.has(entry.original): shared = shared and clones[entry.original] == entry.candidate
		clones[entry.original] = entry.candidate
		opaque = opaque and entry.candidate.next_pass == null
		if entry.candidate is ShaderMaterial:
			existing_textures = existing_textures and entry.candidate.shader == Probe.SHADER \
				and entry.candidate.get_shader_parameter("diffuse_map") == World.FLOOR_DIFF \
				and entry.candidate.get_shader_parameter("normal_map") == World.FLOOR_NORMAL \
				and entry.candidate.get_shader_parameter("arm_map") == World.FLOOR_ARM
		else: opaque = opaque and entry.candidate.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED
	check(shared and clones.size() == result.changed_materials,"one cached clone per original material preserves sharing")
	check(existing_textures,"all candidate sampled textures are the already-loaded CC0 maps")
	check(opaque,"no alpha/next-pass material added")
	compare_production(world)
	check(probe.apply(game).error == "already_applied","repeat application fails closed")
	var unsupported := StandardMaterial3D.new()
	unsupported.albedo_color = Color("375967")
	unsupported.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	check(probe.replacement(unsupported) == null,"transparent material untouched")
	unsupported.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	unsupported.next_pass = StandardMaterial3D.new()
	check(probe.replacement(unsupported) == null,"extra pass material untouched")
	check(probe.restore() == result.changed_instances,"all candidate assignments restore")
	check(environment_node.environment == environment and environment.sky == sky and sky.sky_material == sky_material,"exact original environment identity restores")
	check(Probe.state(world) == original_state and before == Probe.geometry_signature(world),"original world resources and inventory restore exactly")
	var restored := true
	for material in source_states: restored = restored and material_state(material) == source_states[material]
	check(restored and shadow_state(world) == shadows,"original materials and full light configuration intact after restore")
	check(probe.restore() == 0,"repeat restore harmless")
	environment.ssao_enabled = false
	check(probe.apply(game).error == "requires_unchanged_high","lower SSAO state cannot masquerade as High candidate")
	environment.ssao_enabled = true
	var second := probe.apply(game)
	check(second.error == "" and second.changed_instances == result.changed_instances,"reapplication gives same bounded candidate")
	game.free()
	check(probe.restore() == 0,"owner deletion leaves no unsafe node references")
	print("WORLD_VISUALS_STATS ",JSON.stringify(result))
	print("WORLD_VISUALS: ",passed,"/",passed+failed," passed; dummy-renderer resource checks only")
	quit(1 if failed else 0)
