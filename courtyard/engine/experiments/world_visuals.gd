extends RefCounted

# Explicit test-only art direction, applied after the production world batches.
# Resource clones preserve original materials/sky for a paired remote review.
# No new nodes, lights, passes, textures, geometry or production hooks.
const World = preload("res://scripts/world.gd")
const SHADER = preload("res://engine/experiments/world_visuals.gdshader")
const NAME := "chalk-and-teal-courtyard-v1"
const WALL_PALETTE := {
	"c5af88":"d2c6b2", "b6a287":"c9bda9", "cab99b":"e0d4be",
	"d5c7b3":"e4dfd2", "adaba0":"a9b5b2", "bba580":"cabc9f",
	"ac9a7a":"aab0a4", "b5a07b":"b7aa92"}
const JOINERY_PALETTE := {
	"375967":"326a75", "486c72":"437c83", "28353c":"24353b",
	"303e43":"293e43", "dac6a0":"d4ccb9", "e1d7c3":"dedbd0",
	"695138":"634630", "735c41":"705039", "38403b":"3d4847"}
var _materials: Dictionary = {}
var _assignments: Array[Dictionary] = []
var _environment: Dictionary = {}
var last_result: Dictionary = {}

static func state(world: Node3D) -> Dictionary:
	var result := {"mesh_instances":0,"multimesh_instances":0,"multimesh_elements":0,
		"static_bodies":0,"lights":0,"shadow_lights":0,"surface_bindings":0,"bound_textures":0}
	var textures: Dictionary = {}
	for node in world.find_children("*","Node",true,false):
		if node is StaticBody3D: result.static_bodies += 1
		if node is Light3D:
			result.lights += 1
			if node.shadow_enabled: result.shadow_lights += 1
		var mesh: Mesh
		if node is MeshInstance3D:
			result.mesh_instances += 1
			mesh = node.mesh
		elif node is MultiMeshInstance3D:
			result.multimesh_instances += 1
			if node.multimesh != null:
				result.multimesh_elements += node.multimesh.instance_count
				mesh = node.multimesh.mesh
		if mesh == null: continue
		result.surface_bindings += mesh.get_surface_count()
		var material: Material = node.material_override
		if material is ShaderMaterial:
			for uniform in material.shader.get_shader_uniform_list():
				var value: Variant = material.get_shader_parameter(uniform.name)
				if value is Texture: textures[value] = true
	result.bound_textures = textures.size()
	return result

static func geometry_signature(world: Node3D) -> Array:
	# Exact native resource identity, local transforms and shadow modes, not
	# merely counts. These are preserved even though material colors change.
	var result: Array = []
	for node in world.find_children("*","Node",true,false):
		if node is MeshInstance3D:
			result.append([node,node.mesh,node.transform,node.cast_shadow,node.visible])
		elif node is MultiMeshInstance3D:
			var transforms: Array[Transform3D] = []
			for index in node.multimesh.instance_count: transforms.append(node.multimesh.get_instance_transform(index))
			result.append([node,node.multimesh,node.multimesh.mesh,node.transform,node.cast_shadow,node.visible,transforms])
		elif node is CollisionShape3D:
			result.append([node,node.shape,node.transform,node.disabled])
		elif node is Light3D:
			result.append([node,node.transform,node.shadow_enabled])
	return result

static func palette_color(original: Color) -> Color:
	for source: String in JOINERY_PALETTE:
		if original.is_equal_approx(Color(source)): return Color(JOINERY_PALETTE[source])
	for plank in 3:
		if original.is_equal_approx(Color("816446").darkened(plank * 0.055)):
			return Color("79563b").darkened(plank * 0.055)
	return original

static func wall_color(original: Color) -> Color:
	for source: String in WALL_PALETTE:
		if original.is_equal_approx(Color(source).lightened(0.15)): return Color(WALL_PALETTE[source])
	return original

func replacement(original: Material) -> Material:
	if original == null or original.get_script() != null or original.next_pass != null: return null
	if _materials.has(original): return _materials[original]
	var candidate: Material
	if original is ShaderMaterial:
		var is_surface: bool = original.shader == World.SURFACE
		var is_masonry: bool = original.shader == World.PLASTER
		if not is_surface and not is_masonry: return null # Crates/other shader families stay authored.
		var original_tint: Variant = original.get_shader_parameter("tint")
		if not original_tint is Color or original_tint.a != 1.0: return null
		var floor_surface: bool = is_surface and original.get_shader_parameter("diffuse_map") == World.FLOOR_DIFF
		if is_surface and not floor_surface and original.get_shader_parameter("diffuse_map") != World.WALL_DIFF: return null
		var tint: Color = wall_color(original_tint)
		var masonry := 0.0
		if floor_surface: tint = Color("b5aa95")
		if is_masonry:
			var amount: Variant = original.get_shader_parameter("masonry")
			if not amount is float or not is_finite(amount) or amount <= 0.0 or amount >= 1.0: return null
			masonry = amount
			tint = Color("b6a58b") if original_tint.is_equal_approx(Color("aa9276")) else Color("cbbb9e")
		candidate = original.duplicate(false)
		candidate.shader = SHADER
		candidate.set_shader_parameter("tint",tint)
		candidate.set_shader_parameter("base_tint",tint.lerp(Color("918c79"),0.48))
		# Reuse the already-loaded CC0 mineral maps; remove concrete formwork seams
		# from architecture without downloading another texture set.
		candidate.set_shader_parameter("diffuse_map",World.FLOOR_DIFF)
		candidate.set_shader_parameter("normal_map",World.FLOOR_NORMAL)
		candidate.set_shader_parameter("arm_map",World.FLOOR_ARM)
		candidate.set_shader_parameter("texture_scale",0.40 if floor_surface else 0.58)
		candidate.set_shader_parameter("normal_strength",0.64 if floor_surface else (0.42 if is_masonry else 0.30))
		candidate.set_shader_parameter("floor_surface",floor_surface)
		candidate.set_shader_parameter("masonry",masonry)
	elif original is StandardMaterial3D:
		if original.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED or original.vertex_color_use_as_albedo \
				or original.albedo_texture != null or original.albedo_color.a != 1.0: return null
		var tint := palette_color(original.albedo_color)
		if tint == original.albedo_color: return null
		candidate = original.duplicate(false)
		candidate.albedo_color = tint
		candidate.roughness = 0.66 if original.metallic > 0 else 0.86
	else:
		return null
	_materials[original] = candidate
	return candidate

func apply(game: Node3D) -> Dictionary:
	var result := {"name":NAME,"error":"","changed_materials":0,"changed_instances":0,
		"new_texture_resources":0,"extra_passes":0,"surface_texture_reads":3,
		"texture_scope":"existing sampled Texture2D assets only; cloned Sky regenerates renderer-owned radiance during setup",
		"masonry_cost":"three existing texture reads replace the old procedural sine-noise shader; not a measured speedup"}
	if not _assignments.is_empty() or not _environment.is_empty():
		result.error = "already_applied"
		return result
	if not is_instance_valid(game) or not game.is_inside_tree() or not game.get("world") is Node3D:
		result.error = "invalid_game"
		return result
	var world: Node3D = game.world
	var environments := world.find_children("*","WorldEnvironment",true,false)
	if environments.size() != 1 or environments[0].environment == null \
			or environments[0].environment.sky == null or not environments[0].environment.sky.sky_material is ProceduralSkyMaterial:
		result.error = "unsupported_environment"
		return result
	var source_environment: Environment = environments[0].environment
	if not source_environment.ssao_enabled or source_environment.tonemap_mode != Environment.TONE_MAPPER_FILMIC:
		result.error = "requires_unchanged_high"
		return result
	var before := geometry_signature(world)
	var viewport := game.get_viewport()
	var render_settings := [viewport.scaling_3d_scale,viewport.msaa_3d]
	result.before = state(world)
	result.batching = world.batching.duplicate(true)
	for node in world.find_children("*","GeometryInstance3D",true,false):
		if not (node is MeshInstance3D or node is MultiMeshInstance3D) or node.material_overlay != null: continue
		var original: Material = node.material_override
		var candidate := replacement(original)
		if candidate == null: continue
		_assignments.append({"node":weakref(node),"original":original,"candidate":candidate})
		node.material_override = candidate
		result.changed_instances += 1
	var candidate_environment := source_environment.duplicate(false) as Environment
	var sky := source_environment.sky.duplicate(false) as Sky
	var sky_material := sky.sky_material.duplicate(false) as ProceduralSkyMaterial
	sky_material.sky_top_color = Color("407aa0")
	sky_material.sky_horizon_color = Color("ded5bf")
	sky_material.ground_bottom_color = Color("817d6b")
	sky_material.ground_horizon_color = Color("c7bea8")
	sky.sky_material = sky_material
	candidate_environment.sky = sky
	candidate_environment.ambient_light_color = Color("b7cbd5")
	candidate_environment.ambient_light_energy = 0.48
	candidate_environment.tonemap_exposure = 0.98
	candidate_environment.fog_light_color = Color("cec5b1")
	candidate_environment.fog_density = 0.0018
	candidate_environment.fog_sky_affect = 0.18
	_environment = {"node":weakref(environments[0]),"original":source_environment,"candidate":candidate_environment}
	environments[0].environment = candidate_environment
	result.changed_materials = _materials.size()
	result.after = state(world)
	result.geometry_unchanged = before == geometry_signature(world)
	result.batching_unchanged = result.batching == world.batching
	result.quality_unchanged = render_settings == [viewport.scaling_3d_scale,viewport.msaa_3d]
	result.ssao_unchanged = source_environment.ssao_enabled == candidate_environment.ssao_enabled \
		and source_environment.ssao_radius == candidate_environment.ssao_radius and source_environment.ssao_intensity == candidate_environment.ssao_intensity
	last_result = result.duplicate(true)
	return result

func restore() -> int:
	var restored := 0
	for entry in _assignments:
		var node: GeometryInstance3D = entry.node.get_ref()
		if is_instance_valid(node) and node.material_override == entry.candidate:
			node.material_override = entry.original
			restored += 1
	if not _environment.is_empty():
		var node: WorldEnvironment = _environment.node.get_ref()
		if is_instance_valid(node) and node.environment == _environment.candidate:
			node.environment = _environment.original
	_assignments.clear()
	_environment.clear()
	_materials.clear()
	return restored
