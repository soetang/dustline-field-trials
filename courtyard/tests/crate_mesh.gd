extends SceneTree

const Crate = preload("res://scripts/crate_mesh.gd")
const Layout = preload("res://scripts/layout.gd")
var passed := 0
var failed := 0

func check(ok: bool, label: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func _initialize() -> void:
	call_deferred("run")

func inspect_mesh(size: Vector3, seed_value: int) -> void:
	var mesh := Crate.build(size, Color("806e50"), seed_value)
	check(mesh.get_surface_count() == 1, "All prop details share one opaque surface")
	check(mesh.surface_get_material(0) == Crate.material(), "Props share one material resource")
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	check(vertices.size() == normals.size() and vertices.size() == colors.size(), "Every vertex has a normal and pigment")
	check(indices.size() > 100 and indices.size() / 3 < 850, "Detailed prop stays below 850 triangles")
	var half := size * 0.5 + Vector3.ONE * 0.00001
	var finite_inside := true
	var unit_normals := true
	var wood := 0
	var iron := 0
	for i in vertices.size():
		var p := vertices[i].abs()
		finite_inside = finite_inside and p.is_finite() and p.x <= half.x and p.y <= half.y and p.z <= half.z
		unit_normals = unit_normals and normals[i].is_finite() and absf(normals[i].length_squared() - 1.0) < 0.002
		if colors[i].a == 0.0: wood += 1
		if colors[i].a > 0.4: iron += 1
	check(finite_inside, "Whole visual stays inside original cover collider")
	check(unit_normals, "Baked normals stay finite and unit length")
	check(wood > 0 and iron > 0, "Wood and metal are represented without material passes")
	var clockwise := true
	for i in range(0, indices.size(), 3):
		var a := indices[i]
		var b := indices[i + 1]
		var c := indices[i + 2]
		var n := (vertices[c] - vertices[a]).cross(vertices[b] - vertices[a])
		clockwise = clockwise and n.length_squared() > 0.000000000001 and n.normalized().dot(normals[a]) > 0.998
	check(clockwise, "Triangles are nondegenerate, clockwise and agree with normals")
	var repeat := Crate.build(size, Color("806e50"), seed_value).surface_get_arrays(0)
	check(arrays[Mesh.ARRAY_VERTEX] == repeat[Mesh.ARRAY_VERTEX] and arrays[Mesh.ARRAY_COLOR] == repeat[Mesh.ARRAY_COLOR], "Identical seed produces identical geometry and colors")

func run() -> void:
	for i in Layout.COVERS.size():
		var rect: Rect2 = Layout.COVERS[i]
		inspect_mesh(Vector3(rect.size.x, 1.1 if i % 3 == 0 else 2.0, rect.size.y), 7000 + i)
	for size in [Vector3(0.4, 0.4, 0.4), Vector3(0.4, 2, 4), Vector3(4, 0.4, 0.4)]:
		inspect_mesh(size, 4)
	var body := StaticBody3D.new()
	var proxy := MeshInstance3D.new()
	proxy.mesh = BoxMesh.new()
	body.add_child(proxy)
	var collision := CollisionShape3D.new()
	collision.shape = BoxShape3D.new()
	body.add_child(collision)
	var shape := collision.shape
	Crate.replace_visual(body, Vector3.ONE, Color("806e50"), 1)
	check(collision.shape == shape and not collision.disabled, "Collision resource is retained unchanged")
	check(proxy.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY, "Original simple shadow silhouette is retained")
	check(body.get_node("SupplyCrateDetail").cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "Fine bevel vertices do not multiply across shadow cascades")
	body.free()
	print("CRATE_MESH: %d/%d passed" % [passed, passed + failed])
	quit(1 if failed else 0)
