extends SceneTree

const Probe = preload("res://engine/experiments/world_visuals.gd")
const World = preload("res://scripts/world.gd")
var passed := 0
var failed := 0

class GameStub:
	extends Node3D
	var world: Node3D

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
		for name in ["tint","diffuse_map","normal_map","arm_map","texture_scale","normal_strength","masonry"]:
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
	game.world = World.new()
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
	check(result.error == "","real production world is supported")
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
