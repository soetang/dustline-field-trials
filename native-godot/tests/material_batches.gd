extends SceneTree

const World = preload("res://scripts/world.gd")
var passed := 0
var failed := 0

class Fixture:
	extends "res://scripts/world.gd"
	func _ready() -> void:
		pass

class OptimizedWorld:
	extends "res://scripts/world.gd"
	func batch_static_boxes(_consolidate_colors: bool = true) -> void:
		super.batch_static_boxes(true)

func check(ok: bool, label: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("FAIL: ",label)

func _initialize() -> void:
	call_deferred("run")

func check_materials(fixture: FieldWorld) -> void:
	var cache: Dictionary = {}
	var variants: Array[Dictionary] = []
	var red := fixture.material(Color("806e50"))
	var blue := fixture.material(Color("486c72"))
	var a := fixture.batch_material(red,cache,variants)
	var b := fixture.batch_material(blue,cache,variants)
	check(a.material == b.material and a.material != red,"Color-only materials share a new batch material")
	check(a.color == red.albedo_color and b.color == blue.albedo_color,"Instance colors retain the original source colors")
	check(a.material.albedo_color == Color.WHITE and a.material.vertex_color_use_as_albedo,"White shared albedo uses the per-instance color")
	check(a.material.vertex_color_is_srgb,"Instance colors retain source-color sRGB conversion across renderers")
	check(red.albedo_color == Color("806e50") and blue.albedo_color == Color("486c72") and not red.vertex_color_use_as_albedo,"Batching does not change shared source materials")
	for entry in [["roughness",0.33],["metallic",0.35],["metallic_specular",0.15],
			["cull_mode",BaseMaterial3D.CULL_DISABLED],["shading_mode",BaseMaterial3D.SHADING_MODE_UNSHADED],
			["disable_fog",true],["render_priority",1],["albedo_texture",ImageTexture.new()]]:
		var changed: StandardMaterial3D = red.duplicate()
		changed.set(entry[0],entry[1])
		var separate := fixture.batch_material(changed,cache,variants)
		check(separate.material != a.material and separate.material.get(entry[0]) == changed.get(entry[0]),"Different %s stays in a separate material group" % entry[0])
	var transparent: StandardMaterial3D = red.duplicate()
	transparent.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var alpha: StandardMaterial3D = red.duplicate()
	alpha.albedo_color.a = 0.5
	var vertex_colors: StandardMaterial3D = red.duplicate()
	vertex_colors.vertex_color_use_as_albedo = true
	var extra_pass: StandardMaterial3D = red.duplicate()
	extra_pass.next_pass = StandardMaterial3D.new()
	for original in [transparent,alpha,vertex_colors,extra_pass,fixture.stone(Color("cab99b"))]:
		var preserved := fixture.batch_material(original,cache,variants)
		check(preserved.material == original and not preserved.use_colors,"Unsupported material keeps its original identity and color behavior")

func check_geometry(fixture: FieldWorld) -> void:
	fixture.position = Vector3(7,0,-5)
	fixture.rotation.y = 0.4
	var red := fixture.material(Color("806e50"))
	var blue := fixture.material(Color("486c72"))
	fixture.box(Vector3(1,1,1),Vector3(1,2,1),red,true)
	var rotated := fixture.box(Vector3(3,1,1),Vector3(1,2,0.4),blue,true)
	rotated.rotation = Vector3(0.2,0.3,0.1)
	rotated.scale = Vector3(0.7,1.1,2)
	var no_shadow := fixture.box(Vector3(5,1,1),Vector3.ONE,red)
	no_shadow.get_child(0).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fixture.box(Vector3(World.BATCH_CELL_SIZE+1,1,1),Vector3.ONE,blue)
	fixture.box(Vector3(7,1,1),Vector3.ONE,fixture.stone(Color("cab99b")))
	fixture.box(Vector3(8,1,1),Vector3.ONE,fixture.stone(Color("cab99b")).duplicate())
	fixture.box(Vector3(9,1,1),Vector3.ONE,fixture.material(Color("475458"),0.35))
	var old_groups := fixture.static_box_groups(false)
	var groups := fixture.static_box_groups(true)
	check(old_groups.size() == 7 and groups.size() == 6,"Only color-only, same-cell, same-shadow batches combine")
	var corners_match := true
	var colors_match := true
	var shadow_modes_match := true
	var count := 0
	for group in groups.values():
		for i in group.sources.size():
			var source: MeshInstance3D = group.sources[i]
			var expected := source.global_transform * Transform3D(Basis.from_scale(source.mesh.size),Vector3.ZERO)
			var actual: Transform3D = fixture.global_transform * group.transforms[i]
			for x in [-0.5,0.5]:
				for y in [-0.5,0.5]:
					for z in [-0.5,0.5]:
						var corner := Vector3(x,y,z)
						corners_match = corners_match and (expected*corner).is_equal_approx(actual*corner)
			if group.use_colors: colors_match = colors_match and group.colors[i] == source.material_override.albedo_color
			else: colors_match = colors_match and group.material == source.material_override
			shadow_modes_match = shadow_modes_match and group.shadow == source.cast_shadow
			count += 1
	check(count == 7 and corners_match,"Every rotated and nonuniformly scaled box keeps all eight world corners")
	check(colors_match,"Each planned instance retains its source material color or custom material")
	check(shadow_modes_match,"Every box preserves its shadow mode")
	fixture.batch_static_boxes(true)
	check(fixture.batching.bodies_before == 2 and fixture.batching.bodies_after == 2,"Batch upload preserves fixture collision bodies")
	var instances := 0
	var color_enabled := true
	for batch in fixture.find_children("*","MultiMeshInstance3D",true,false):
		instances += batch.multimesh.instance_count
		if batch.material_override is StandardMaterial3D:
			color_enabled = color_enabled and batch.multimesh.use_colors and batch.material_override.vertex_color_use_as_albedo
	check(instances == 7 and color_enabled,"Every source gets one render instance with color storage enabled when needed")
	# The headless rendering server does not retain GPU instance color/transform
	# buffers. Check the upload plan here; rendered image comparisons verify color.

func run() -> void:
	var fixture := Fixture.new()
	root.add_child(fixture)
	check_materials(fixture)
	check_geometry(fixture)
	fixture.queue_free()
	await process_frame
	var original := World.new()
	root.add_child(original)
	check(original.batching.batches == 265 and original.batching.color_batches == 0,"Crate integration retains original cell size and disables experimental color consolidation")
	check(original.find_children("SupplyCrateDetail", "MeshInstance3D", true, false).size() == 16,"All sixteen detailed crates survive scenery batching")
	original.queue_free()
	await process_frame
	var world := OptimizedWorld.new()
	root.add_child(world)
	check(world.batching.source_boxes == 1248,"Scenery retains source boxes except 128 bands replaced by detailed crate surfaces")
	check(world.batching.bodies_before == 53 and world.batching.bodies_after == 53,"Full scenery preserves all 53 static collision bodies")
	check(world.batching.batches < 265,"Color consolidation reduces current spatial/material batches")
	print("MATERIAL_BATCH_SAMPLE ",JSON.stringify(world.batching))
	print("MATERIAL_BATCHES: %d/%d passed" % [passed,passed+failed])
	world.queue_free()
	await process_frame
	quit(1 if failed else 0)
