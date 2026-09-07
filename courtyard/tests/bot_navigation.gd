extends SceneTree

# Route-gaze decisions, not aim/accuracy tuning. Real map rays independently
# demonstrate opaque corners; production uses only existing layout clearance.
const Bot = preload("res://scripts/bot.gd")
const Layout = preload("res://scripts/layout.gd")
const World = preload("res://scripts/world.gd")

class CountedLayout:
	extends RefCounted
	var real := Layout.new()
	var queries := 0
	var forced := false
	var visible: Array[Vector3] = []
	func segment_clear(from: Vector3, to: Vector3) -> bool:
		queries += 1
		return visible.has(to) if forced else real.segment_clear(from,to)
	func path(from: Vector3, to: Vector3) -> PackedVector3Array:
		return real.path(from,to)

class Objective:
	extends RefCounted
	var carrier: Node3D
	func assignment(_actor: Node3D) -> Dictionary: return {}
	func report_contact(_actor: Node3D, _at: Vector3) -> void: pass

class Game:
	extends Node3D
	var layout := CountedLayout.new()
	var objective := Objective.new()
	var bomb_active := false
	var elapsed := 0.0
	var opponents: Array[Node3D] = []
	func actors() -> Array[Node3D]: return opponents

class ProbeBot:
	extends Bot
	var route_looks := 0
	var visible_enemy := false
	func _ready() -> void: pass
	func see(_other: Node3D) -> bool: return visible_enemy
	func path_look_goal() -> Vector3:
		route_looks += 1
		return super.path_look_goal()

var checks := 0
var failures := 0
var game: Game
var bot: ProbeBot

func _initialize() -> void: call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("FAIL: ",label)

func function_checks() -> void:
	game.layout.forced = true
	bot.position = Vector3.ZERO
	bot.path = PackedVector3Array([Vector3(0,0,-1),Vector3(0,0,-2),Vector3(1,0,-3),Vector3(2,0,-3)])
	var original_path := bot.path.duplicate()
	for selected in [3,2,1,0]:
		game.layout.visible = [bot.path[selected]]
		game.layout.queries = 0
		check(bot.path_look_goal() == bot.path[selected]+Vector3.UP*1.4,"furthest clear look-ahead selected at index %d" % selected)
		check(game.layout.queries == mini(4-selected,3),"early exit / maximum three public clearance queries")
		check(bot.path == original_path and bot.position == Vector3.ZERO,"gaze does not mutate route or movement")
	bot.path = PackedVector3Array([Vector3(1,0,0)])
	game.layout.queries = 0
	check(bot.path_look_goal() == Vector3(1,1.4,0) and game.layout.queries == 0,"single remaining leg needs no new clearance query")
	bot.path.clear()
	bot.look_goal = Vector3(9,1,4)
	check(bot.path_look_goal() == bot.look_goal and game.layout.queries == 0,"empty route preserves existing look intent without queries")
	bot.path = original_path
	bot.mission = bot.path[-1]
	bot.path_goal = bot.mission
	bot.route.clear()
	bot.rng.seed = 44551
	game.layout.visible = [bot.path[1]]
	var state := bot.rng.state
	bot.think()
	check(bot.look_goal == bot.path[1]+Vector3.UP*1.4,"real think() uses route-aware gaze")
	check(bot.rng.state == state,"route awareness does not consume combat random samples")
	for cue in ["memory","heard"]:
		bot.memory = 2 if cue == "memory" else 0
		bot.heard = 2 if cue == "heard" else 0
		bot.last_seen = Vector3(4,0,4)
		bot.path_goal = bot.last_seen
		var looks := bot.route_looks
		bot.think()
		check(bot.look_goal == bot.last_seen+Vector3.UP*1.3 and bot.route_looks == looks,"%s cue overrides navigation gaze" % cue)
	bot.memory = 0
	bot.heard = 0
	bot.path.clear()
	bot.team = 0
	bot.path_goal = bot.mission
	bot.guard_look = Vector3(-3,1.5,-10)
	var looks := bot.route_looks
	bot.think()
	check(bot.look_goal == bot.guard_look and bot.route_looks == looks,"stationary anchor retains its assigned watching direction")
	var enemy := Node3D.new()
	game.add_child(enemy)
	enemy.position = Vector3(0,0,-10)
	game.opponents = [enemy]
	bot.visible_enemy = true
	bot.team = 1
	bot.path = original_path
	bot.think()
	check(bot.target == enemy and bot.look_goal == enemy.position+Vector3.UP*1.3 and bot.route_looks == looks,"visible contact overrides route gaze")
	check(bot.reaction >= 0.28 and bot.reaction <= 0.54 and bot.contact_age == 0 and not bot.higher_aim,"contact reaction and fresh body-focused aim are unchanged")
	bot.target = null
	game.opponents.clear()
	bot.visible_enemy = false
	enemy.free()
	game.layout.forced = false

func map_corners() -> void:
	var world := World.new()
	game.add_child(world)
	for frame in 2: await physics_frame
	for pair in [
		[Vector3(13.62,0,-26.894),Layout.T_SPAWN],
		[Vector3(-16.82,0,-34.595),Layout.SITE_A],
		[Vector3(25.4035,0,19.025),Layout.SITE_B],
	]:
		bot.position = Layout.on_floor(pair[0])
		bot.path = game.layout.real.path(bot.position,pair[1])
		check(bot.path.size() >= 4,"real corner has at least four navigation waypoints")
		var old := bot.path[3]+Vector3.UP*1.4
		game.layout.queries = 0
		var selected := bot.path_look_goal()
		var space := world.get_world_3d().direct_space_state
		var blocked := space.intersect_ray(PhysicsRayQueryParameters3D.create(bot.eye(),old,1))
		var visible := space.intersect_ray(PhysicsRayQueryParameters3D.create(bot.eye(),selected,1))
		check(not blocked.is_empty(),"old fourth-waypoint gaze intersects a real opaque map wall")
		check(visible.is_empty() and selected != old,"new gaze watches the open route before rounding the corner")
		check(game.layout.queries <= 3,"real map look-ahead keeps the three-query budget")
		var old_direction := Vector2(old.x-bot.position.x,old.z-bot.position.z)
		var new_direction := Vector2(selected.x-bot.position.x,selected.z-bot.position.z)
		var turn := absf(rad_to_deg(old_direction.angle_to(new_direction)))
		if pair[0].x > 13 and pair[0].x < 14:
			check(turn > 45,"A-ramp corner corrects a visibly wrong heading by over 45 degrees")
		print("BOT_NAVIGATION_CORNER ",JSON.stringify({"position":bot.position,"old":old,"selected":selected,
			"heading_change_degrees":turn,"queries":game.layout.queries}))
	world.free()

func seeded_checks_and_benchmark() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 8319
	var cases: Array = []
	for sample in 400:
		var at := Layout.on_floor(Vector3(rng.randf_range(-38,40),0,rng.randf_range(-36,38)))
		if not Layout.clear(Vector2(at.x,at.z),0.43): continue
		var goal: Vector3 = [Layout.SITE_A,Layout.SITE_B,Layout.CT_SPAWN,Layout.T_SPAWN][sample%4]
		var route := game.layout.real.path(at,goal)
		if route.is_empty(): continue
		cases.append({"at":at,"route":route})
		bot.position = at
		bot.path = route
		var expected := mini(3,route.size()-1)
		while expected>0 and not game.layout.real.segment_clear(at,route[expected]): expected-=1
		game.layout.queries = 0
		check(bot.path_look_goal() == route[expected]+Vector3.UP*1.4,"seeded route picks furthest clear bounded waypoint")
		check(game.layout.queries <= 3 and bot.path == route,"seeded query budget and immutable path")
	check(cases.size() >= 100,"seeded routes cover at least 100 actual map paths")
	var times: Array[float] = []
	var total_queries := 0
	for repetition in 6:
		game.layout.queries = 0
		var started := Time.get_ticks_usec()
		for value in cases:
			bot.position = value.at
			bot.path = value.route
			bot.path_look_goal()
		var usec := float(Time.get_ticks_usec()-started)/cases.size()
		if repetition>0: times.append(usec)
		total_queries = game.layout.queries
	times.sort()
	print("BOT_NAVIGATION_BENCH ",JSON.stringify({"paths":cases.size(),"seed":8319,"median_usec_per_look":times[2],
		"min_usec":times[0],"max_usec":times[-1],"queries_per_look":float(total_queries)/cases.size(),
		"measurement":"native headless route-gaze helper, one warmup + five samples; includes assignment/counting; not browser FPS"}))

func run() -> void:
	game = Game.new()
	root.add_child(game)
	bot = ProbeBot.new()
	bot.game = game
	game.add_child(bot)
	bot.set_process(false)
	bot.set_physics_process(false)
	function_checks()
	await map_corners()
	seeded_checks_and_benchmark()
	print("BOT_NAVIGATION: %d/%d passed" % [checks-failures,checks])
	game.free()
	quit(1 if failures else 0)
