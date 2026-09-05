class_name FieldModels
extends RefCounted

# Keep native models resident: this small local asset set needs no network/lazy
# loading and avoids file reads and material teardown during weapon changes.
const ASSETS := {
	"ct_operator": preload("res://assets/models/ct_operator.glb"),
	"t_operator": preload("res://assets/models/t_operator.glb"),
	"view_m4": preload("res://assets/models/view_m4.glb"),
	"view_ak": preload("res://assets/models/view_ak.glb"),
	"view_awp": preload("res://assets/models/view_awp.glb"),
	"view_deagle": preload("res://assets/models/view_deagle.glb"),
}

static func prepare(root: Node3D, first_person: bool = false) -> void:
	# Godot's importer can disable vertex colour on shared materials. Our GLBs
	# deliberately store their original palette in COLOR_0, not image textures.
	var copies: Dictionary = {}
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if first_person: node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		for surface in node.mesh.get_surface_count():
			var original: Material = node.get_active_material(surface)
			if not original is BaseMaterial3D: continue
			var colors: PackedColorArray = node.mesh.surface_get_arrays(surface)[Mesh.ARRAY_COLOR]
			if colors.is_empty(): continue
			if not copies.has(original):
				var mat: BaseMaterial3D = original.duplicate()
				mat.vertex_color_use_as_albedo = true
				mat.vertex_color_is_srgb = false # glTF COLOR_0 is linear, not sRGB.
				copies[original] = mat
			node.set_surface_override_material(surface, copies[original])
