extends RefCounted

## Original static prop, built once into one indexed surface. Details remain
## inside the existing solid cover box; no new navigation/collision geometry.
const SHADER = preload("res://engine/experiments/crate.gdshader")
static var shared_material: ShaderMaterial

static func material() -> ShaderMaterial:
	if shared_material == null:
		shared_material = ShaderMaterial.new()
		shared_material.shader = SHADER
	return shared_material

static func replace_visual(body: Node3D, size: Vector3, tint: Color, seed_value: int) -> void:
	# Retain the original solid box and its exact shadow silhouette. Fine plank
	# bevels don't multiply vertex work across four cascaded shadow passes.
	var proxy: MeshInstance3D = body.get_child(0)
	assert(proxy.mesh is BoxMesh)
	proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	var detail := MeshInstance3D.new()
	detail.name = "SupplyCrateDetail"
	detail.mesh = build(size, tint, seed_value)
	detail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(detail)

static func triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, outward: Vector3, color: Color) -> void:
	# Godot front faces are clockwise. Bake flat normals rather than recalculating
	# bevels or grain in a fragment shader. Degenerate input is never emitted.
	var normal := (c - a).cross(b - a)
	if normal.length_squared() < 0.000000000001: return
	if normal.dot(outward) < 0:
		var swap := b
		b = c
		c = swap
		normal = -normal
	st.set_normal(normal.normalized())
	st.set_color(color)
	for point in [a, b, c]: st.add_vertex(point)

static func quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3, color: Color) -> void:
	triangle(st, a, b, c, normal, color)
	triangle(st, a, c, d, normal, color)

static func bevel_box(st: SurfaceTool, half: Vector3, bevel: float, color: Color) -> void:
	var inner := half - Vector3.ONE * bevel
	for axis in 3:
		var u_axis := (axis + 1) % 3
		var v_axis := (axis + 2) % 3
		for side: float in [-1.0, 1.0]:
			var n := Vector3.ZERO
			var u := Vector3.ZERO
			var v := Vector3.ZERO
			n[axis] = side
			u[u_axis] = inner[u_axis]
			v[v_axis] = inner[v_axis]
			var center := n * half[axis]
			quad(st, center - u - v, center + u - v, center + u + v, center - u + v, n, color)
		for su: float in [-1.0, 1.0]:
			for sv: float in [-1.0, 1.0]:
				var a := Vector3.ZERO
				var b := Vector3.ZERO
				var edge := Vector3.ZERO
				var n := Vector3.ZERO
				a[u_axis] = su * half[u_axis]
				a[v_axis] = sv * inner[v_axis]
				b[u_axis] = su * inner[u_axis]
				b[v_axis] = sv * half[v_axis]
				edge[axis] = inner[axis]
				n[u_axis] = su
				n[v_axis] = sv
				quad(st, a - edge, a + edge, b + edge, b - edge, n, color)
	for x: float in [-1.0, 1.0]:
		for y: float in [-1.0, 1.0]:
			for z: float in [-1.0, 1.0]:
				var signs := Vector3(x, y, z)
				triangle(st, Vector3(half.x, inner.y, inner.z) * signs,
					Vector3(inner.x, half.y, inner.z) * signs,
					Vector3(inner.x, inner.y, half.z) * signs, signs, color)

static func panel(st: SurfaceTool, center: Vector3, u: Vector3, v: Vector3, extent: Vector2, depth: float, bevel: float, color: Color) -> void:
	# A closed body's cladding needs only the exposed cap and four sloped edges,
	# not hidden back faces or separate box nodes/material surfaces.
	var n := u.cross(v)
	var outside: Array[Vector3] = []
	var inside: Array[Vector3] = []
	for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		outside.append(center + u * corner.x * extent.x + v * corner.y * extent.y - n * depth)
		inside.append(center + u * corner.x * (extent.x - bevel) + v * corner.y * (extent.y - bevel))
	quad(st, inside[0], inside[1], inside[2], inside[3], n, color)
	for i in 4:
		var next := (i + 1) % 4
		quad(st, outside[i], outside[next], inside[next], inside[i], n, color)

static func build(size: Vector3, tint: Color, seed_value: int) -> ArrayMesh:
	assert(size.is_finite() and size.x >= 0.4 and size.y >= 0.4 and size.z >= 0.4)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var half := size * 0.5
	var body := tint.darkened(0.24)
	body.a = 0.0
	bevel_box(st, half - Vector3.ONE * 0.025, 0.024, body)
	# Four sides and lid use deterministic plank variation, seams and bevels.
	# The solid bottom is part of the base mesh; no unseen plank work underneath.
	for axis: int in [0, 2, 1]:
		var u := Vector3.RIGHT if axis != 0 else Vector3.FORWARD
		var v := Vector3.UP if axis != 1 else Vector3.FORWARD
		var width := size.x if axis != 0 else size.z
		var height := size.y if axis != 1 else size.z
		var count := clampi(ceili(width / 0.48), 2, 9)
		var pitch := (width - 0.065) / count
		for side: float in ([1.0] if axis == 1 else [-1.0, 1.0]):
			var tangent := u * side
			var normal := tangent.cross(v)
			var center := normal * (half[axis] - 0.004)
			for i in count:
				var wood := tint.lightened(rng.randf_range(-0.045, 0.065))
				wood.a = 0.0
				var at := center + tangent * ((i + 0.5) * pitch - (width - 0.065) * 0.5)
				panel(st, at, tangent, v, Vector2((pitch - 0.015) * 0.5, (height - 0.065) * 0.5), 0.030, 0.006, wood)
			# Wraparound straps: their whole visible hull stays within the cover.
			var iron := Color(0.25, 0.29, 0.27, 0.55)
			for offset: float in [-0.32, 0.32]:
				var at := normal * (half[axis] - 0.001) + tangent * width * offset
				panel(st, at, tangent, v, Vector2(0.047, height * 0.5 - 0.026), 0.009, 0.004, iron)
				if axis == 1: continue
				for y: float in [-0.34, 0.34]:
					var rivet := at + v * height * y + normal * 0.0005
					panel(st, rivet, tangent, v, Vector2(0.019, 0.019), 0.002, 0.006, Color(0.43, 0.46, 0.40, 0.6))
	# A small, original upright shipping mark. Opaque geometry, no label node.
	var ink := Color(0.79, 0.75, 0.60, 0.0)
	var mark_scale := minf(1.0, size.y)
	for side: float in [-1.0, 1.0]:
		var n := Vector3.BACK * side
		var u := Vector3.RIGHT * side
		for x: float in [-0.055, 0.055]:
			var at := n * (half.z - 0.002) + u * (half.x * 0.39 + x) + Vector3.UP * half.y * 0.27
			quad(st, at + u * -0.014, at + u * 0.014, at + u * 0.014 + Vector3.UP * 0.13 * mark_scale, at + u * -0.014 + Vector3.UP * 0.13 * mark_scale, n, ink)
			triangle(st, at + Vector3.UP * 0.19 * mark_scale, at + Vector3.UP * 0.12 * mark_scale + u * 0.047, at + Vector3.UP * 0.12 * mark_scale - u * 0.047, n, ink)
	st.index()
	var mesh := st.commit()
	mesh.surface_set_material(0, material())
	return mesh
