extends SceneTree

const Game = preload("res://scripts/game.gd")
const World = preload("res://scripts/world.gd")

class EmptyWorld:
	extends World
	func _ready() -> void:
		pass

class Fixture:
	extends Game
	func _ready() -> void:
		# Exercise real effect methods/timers without map generation, audio or AI.
		world = EmptyWorld.new()
		add_child(world)
		silent_test = true
		set_process(false)
		set_physics_process(false)

class Shooter:
	extends CharacterBody3D
	var team := 0

var passed := 0
var failed := 0

func check(ok: bool, label: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func _initialize() -> void:
	call_deferred("run")

func old_impact(world: FieldWorld, at: Vector3, normal: Vector3, parent: Node3D) -> Node3D:
	var node := world.box(at + normal * 0.014, Vector3(0.055, 0.055, 0.016), world.material(Color("39372f")), false, parent)
	if absf(normal.dot(Vector3.UP)) < 0.99: node.look_at(at + normal, Vector3.UP)
	else: node.rotation.x = PI * 0.5
	return node

func mesh_of(node: Node3D) -> MeshInstance3D:
	return node.get_child(0)

func run() -> void:
	var game := Fixture.new()
	root.add_child(game)
	game.impact(Vector3.ZERO, Vector3.UP)
	game.trace(Vector3.ZERO, Vector3.FORWARD)
	check(game.world.get_child_count() == 0 and game.effects.is_empty() and game.world.impact_mesh == null and game.world.materials.is_empty(),
		"silent-test gates still allocate no effects, geometry or materials")
	var wall := game.world.box(Vector3(0, 1, -3), Vector3(2, 2, 0.2), game.world.material(Color.WHITE), true)
	var shooter := Shooter.new()
	game.add_child(shooter)
	for i in 2: await physics_frame
	game.rng.seed = 1981
	var silent_hit := game.fire_shot(shooter, Vector3(0, 1, 0), Vector3.FORWARD, 0, 0.0)
	var rng_after := game.rng.state
	check(not silent_hit.is_empty() and silent_hit.collider == wall and game.world.get_child_count() == 1 and game.world.impact_mesh == null,
		"real wall-hit ray stays silent under the existing test gate")
	# Only this fixture opts into real VFX; production --test semantics are not
	# changed. Main-scene load and rendered VFX fixtures are separate checks.
	game.silent_test = false
	game.rng.seed = 1981
	var visible_hit := game.fire_shot(shooter, Vector3(0, 1, 0), Vector3.FORWARD, 0, 0.0)
	check(visible_hit == silent_hit and game.rng.state == rng_after, "real VFX preserve exact shot hit and RNG state")
	check(game.world.get_child_count() == 3 and game.effects.size() == 1, "real wall hit creates one impact and one trace")
	var shot_mark: Node3D = game.world.get_child(1)
	await create_timer(0.05).timeout
	await process_frame
	check(game.effects.is_empty() and is_instance_valid(shot_mark), "wall-hit trace retires while impact remains")
	# Leave the mark to its real timer; freeing a captured node early would
	# exercise an unrelated pre-existing timer-lambda teardown warning.
	wall.free()
	shooter.free()
	var original_time_scale := Engine.time_scale
	Engine.time_scale = 16.0
	var early := create_timer(7.0)
	var expiry := create_timer(8.0)
	var reference_parent := Node3D.new()
	game.world.add_child(reference_parent)
	var originals: Array[Node3D] = []
	var impacts: Array[Node3D] = []
	var original_meshes: Dictionary = {}
	var shared_meshes: Dictionary = {}
	var normals := [Vector3.LEFT, Vector3.RIGHT, Vector3.UP, Vector3.DOWN, Vector3.FORWARD,
		Vector3(1, 2, 3).normalized(), Vector3(0.01, 1, 0).normalized(), Vector3(0.2, 1, 0).normalized()]
	for i in 128:
		var at := Vector3((i % 8) * 0.3, 1.0 + (i / 8) * 0.1, -4)
		var normal: Vector3 = normals[i % normals.size()]
		game.impact(at, normal)
		var actual: Node3D = game.world.get_child(game.world.get_child_count() - 1)
		var original := old_impact(game.world, at, normal, reference_parent)
		impacts.append(actual)
		originals.append(original)
		var a := mesh_of(actual)
		var b := mesh_of(original)
		original_meshes[b.mesh.get_instance_id()] = true
		shared_meshes[a.mesh.get_instance_id()] = true
		check(actual.transform == original.transform and a.transform == b.transform, "impact %d exact position/orientation, including floor/ceiling" % i)
		check(a.mesh.surface_get_arrays(0) == b.mesh.surface_get_arrays(0) and a.mesh.get_aabb() == b.mesh.get_aabb(), "impact %d exact geometry/bounds" % i)
		check(a.material_override == b.material_override and a.cast_shadow == b.cast_shadow and a.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
			"impact %d same cached material and shadow behavior" % i)
		check(actual.get_class() == "Node3D" and actual.get_child_count() == 1 and a.get_class() == "MeshInstance3D", "impact %d same noncolliding two-node shape" % i)
	check(original_meshes.size() == 128 and shared_meshes.size() == 1, "128 simultaneous impacts reuse one mesh instead of 128")
	check(game.effects.is_empty(), "impact marks do not enter the tracer-only effects list")
	var material: StandardMaterial3D = mesh_of(impacts[0]).material_override
	check(material.albedo_color == Color("39372f") and is_equal_approx(material.roughness, 0.78) and material.metallic == 0.0,
		"impact keeps original opaque dark material values")
	var saved_transform := impacts[1].transform
	impacts[0].rotation.y += 0.7
	check(impacts[1].transform == saved_transform and game.world.impact_mesh.size == Vector3(0.055, 0.055, 0.016), "independent transforms cannot mutate shared geometry or other impacts")
	for node in originals: node.free()
	reference_parent.free()

	var from := Vector3(-1, 1.5, 0)
	var to := Vector3(2, 2, -5)
	game.trace(from, to)
	var tracer: MeshInstance3D = game.effects[0]
	check(tracer.mesh is CylinderMesh and is_equal_approx(tracer.mesh.bottom_radius, 0.007) and is_equal_approx(tracer.mesh.top_radius, 0.007) and tracer.mesh.height == from.distance_to(to) and tracer.mesh.radial_segments == 20,
		"trace retains variable-length twenty-segment cylinder")
	check(tracer.position == (from + to) * 0.5 and tracer.quaternion.is_equal_approx(Quaternion(Vector3.UP, (to - from).normalized())), "trace transform remains unchanged")
	check(tracer.material_override == game.world.material(Color("ebbf79")) and tracer.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "trace material and shadow mode remain unchanged")
	await create_timer(0.045).timeout
	await process_frame
	check(not is_instance_valid(tracer) and game.effects.is_empty(), "real 45ms trace timer retires node and effects entry")
	await early.timeout
	var alive := 0
	for node in impacts:
		if is_instance_valid(node): alive += 1
	check(alive == 128, "all impact nodes still exist before eight seconds")
	await expiry.timeout
	for i in 2: await process_frame
	alive = 0
	for node in impacts:
		if is_instance_valid(node): alive += 1
	check(alive == 0 and game.world.get_child_count() == 0, "real eight-second timers retire every impact node")
	var cached := game.world.impact_mesh
	game.impact(Vector3.ZERO, Vector3.UP)
	check(mesh_of(game.world.get_child(0)).mesh == cached, "later impacts reuse mesh after previous marks expire")
	check(game.paused, "timer lifetime verification also retains existing game-paused behavior")
	var geometry_reference: WeakRef = weakref(cached)
	cached = null
	Engine.time_scale = original_time_scale
	game.free()
	check(geometry_reference.get_ref() == null, "shared impact mesh is released with its owning world")
	print("SHOT_EFFECT_ALLOCATIONS impacts=128 baseline_box_meshes=128 shared_box_meshes=1 saved=127; nodes/materials/timers unchanged")
	print("SHOT_EFFECTS: %d/%d passed" % [passed, passed + failed])
	quit(1 if failed else 0)
