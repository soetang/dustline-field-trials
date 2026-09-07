extends SceneTree

func _initialize() -> void:
	for name in ["ct_operator", "view_m4"]:
		var scene: PackedScene = load("res://assets/models/" + name + ".glb")
		var instance := scene.instantiate()
		var seen: Dictionary = {}
		for node in instance.find_children("*", "MeshInstance3D", true, false):
			for surface in node.mesh.get_surface_count():
				var mat: BaseMaterial3D = node.get_active_material(surface)
				if seen.has(mat): continue
				seen[mat] = true
				var colors: PackedColorArray = node.mesh.surface_get_arrays(surface)[Mesh.ARRAY_COLOR]
				print(name, " / ", node.name, " / ", mat.resource_name, " vertex=", mat.vertex_color_use_as_albedo, " srgb=", mat.vertex_color_is_srgb, " albedo=", mat.albedo_color, " first=", colors[0] if not colors.is_empty() else "NONE")
		instance.free()
	quit()
