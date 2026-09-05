class_name FieldObjective
extends Node3D

const Layout = preload("res://scripts/layout.gd")
const A_HOLDS := [Vector3(18, 0, -32), Vector3(17, 0, -22), Vector3(30, 0, -24), Vector3(29, 0, -36)]
const A_LANES := [Vector3(6, 0, -32), Vector3(15, 0, -10), Vector3(37, 0, -9), Vector3(37, 0, -25)]
const B_HOLDS := [Vector3(-36, 0, -26), Vector3(-20, 0, -29), Vector3(-28, 0, -34), Vector3(-18, 0, -35)]
const B_LANES := [Vector3(-33, 0, -9), Vector3(-10, 0, -27), Vector3(-33, 0, -16), Vector3(-19, 0, -25)]
const A_RETAKE := [Vector3(14, 0, -30), Vector3(32, 0, -22), Vector3(16, 0, -19), Vector3(10, 0, -33)]
const B_RETAKE := [Vector3(-17, 0, -28), Vector3(-32, 0, -17), Vector3(-23, 0, -34), Vector3(-14, 0, -27)]
var game: Node3D
var carrier: Node3D
var retriever: Node3D
var defuse_bot: Node3D
var dropped := false
var dropped_at := Vector3.ZERO
var attack_a := true
var plant_progress := 0.0
var plant_last := -100.0
var carried_mesh: Node3D
var dropped_mesh: Node3D
var plan_left := 0.0
var roles: Dictionary = {}
var pickups := 0
var plants := 0
var supporter: Node3D
var support_until := 0.0
var support_a := false
var support_contact := Vector3.ZERO

func reset_round() -> void:
	clear_models()
	carrier = null
	retriever = null
	defuse_bot = null
	dropped = false
	plant_progress = 0
	plant_last = -100
	roles.clear()
	plan_left = 0
	pickups = 0
	plants = 0
	supporter = null
	support_until = 0
	attack_a = (game.match_seed + game.round_number) % 2 == 0
	var attackers: Array[Node3D] = []
	for bot in game.bots:
		if bot.team == 1: attackers.append(bot)
	if not attackers.is_empty():
		carrier = attackers[(game.match_seed + game.round_number) % attackers.size()]
		show_carried_device()
	for bot in attackers:
		var support_index: int = attackers.find(bot)
		var route_name := "long" if attack_a else "tunnels"
		if bot != carrier and support_index == 0: route_name = "short"
		elif bot != carrier and support_index == 4: route_name = "tunnels" if attack_a else "long"
		bot.route = attack_route(route_name)
		bot.mission = Layout.on_floor(bot.route[0])
		bot.path.clear()
		bot.path_goal = Vector3(999, 0, 999)

static func attack_route(name: String) -> Array[Vector3]:
	match name:
		"tunnels": return [Vector3(-27, 0, 28), Vector3(-32, 0, 18), Vector3(-32, 0, -10), Layout.SITE_B]
		"short": return [Vector3(0, 0, 22), Vector3(1, 0, 4), Vector3(14, 0, 0), Vector3(15, 0, -19), Layout.SITE_A]
		_: return [Vector3(20, 0, 29), Vector3(28, 0, 18), Vector3(36, 0, 4), Vector3(37, 0, -18), Layout.SITE_A]

func clear_models() -> void:
	if is_instance_valid(carried_mesh): carried_mesh.queue_free()
	if is_instance_valid(dropped_mesh): dropped_mesh.queue_free()
	carried_mesh = null
	dropped_mesh = null

func show_carried_device() -> void:
	if not is_instance_valid(carrier): return
	carried_mesh = game.world.box(Vector3(0, 1.03, 0.26), Vector3(0.30, 0.40, 0.16), game.world.material(Color("7d6746")), false, carrier)

func drop(actor: Node3D) -> void:
	if actor != carrier or game.bomb_active: return
	dropped_at = Layout.on_floor(actor.position)
	if not Layout.clear(Vector2(dropped_at.x, dropped_at.z), 0.1):
		var cell: Vector2i = game.layout.nearest(actor.position)
		dropped_at = Layout.on_floor(Vector3(cell.x + 0.5, 0, cell.y + 0.5))
	clear_models()
	carrier = null
	retriever = null
	dropped = true
	plant_progress = 0
	plan_left = 0
	dropped_mesh = game.world.box(dropped_at + Vector3.UP * 0.15, Vector3(0.42, 0.26, 0.30), game.world.material(Color("7d6746")))

func recover(actor: Node3D) -> bool:
	if game.phase != "LIVE" or game.paused or not dropped or game.bomb_active or actor.team != 1 or actor.health <= 0: return false
	if actor.position.distance_to(dropped_at) > 1.15: return false
	var query := PhysicsRayQueryParameters3D.create(actor.position + Vector3.UP * 1.4, dropped_at + Vector3.UP * 0.18, 1)
	if not get_world_3d().direct_space_state.intersect_ray(query).is_empty(): return false
	clear_models()
	carrier = actor
	retriever = null
	dropped = false
	pickups += 1
	plan_left = 0
	show_carried_device()
	var route_name := "long" if attack_a else "tunnels"
	actor.route = attack_route(route_name)
	# Rejoin at the nearest remaining route waypoint, not back at spawn.
	var nearest_index := 0
	var nearest_distance := INF
	for i in actor.route.size():
		var distance: float = actor.position.distance_to(Layout.on_floor(actor.route[i]))
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_index = i
	actor.route = actor.route.slice(nearest_index)
	actor.mission = Layout.on_floor(actor.route[0])
	actor.path.clear()
	actor.path_goal = Vector3(999, 0, 999)
	return true

func try_plant(actor: Node3D, dt: float) -> bool:
	if game.phase != "LIVE" or game.paused or game.bomb_active or actor != carrier or actor.health <= 0 or actor.team != 1: return false
	var at: Vector3 = actor.position
	var in_site := minf(at.distance_to(Layout.on_floor(Layout.SITE_A)), at.distance_to(Layout.on_floor(Layout.SITE_B))) < 4.2
	if not in_site or Vector2(actor.velocity.x, actor.velocity.z).length() > 0.35:
		plant_progress = 0
		return false
	if game.elapsed - plant_last > 0.12: plant_progress = 0
	plant_last = game.elapsed
	plant_progress += dt
	if plant_progress >= 3.0: return game.plant(actor)
	return false

func on_planted() -> void:
	clear_models()
	carrier = null
	dropped = false
	retriever = null
	plants += 1
	plan_left = 0
	plan_roles()

func route_cost(actor: Node3D, to: Vector3) -> float:
	var path: PackedVector3Array = game.layout.path(actor.position, to)
	if path.is_empty(): return INF
	var cost := actor.position.distance_to(path[0])
	for i in range(1, path.size()): cost += path[i - 1].distance_to(path[i])
	return cost

func closest_bot(team: int, to: Vector3) -> Node3D:
	var chosen: Node3D = null
	var best := INF
	for bot in game.bots:
		if bot.team != team or bot.health <= 0: continue
		var cost := route_cost(bot, to)
		if cost < best:
			best = cost
			chosen = bot
	return chosen

func report_contact(reporter: Node3D, at: Vector3) -> void:
	# Called only after the reporter passes an actual FOV + occlusion sight test.
	if reporter.team != 0 or game.bomb_active or game.phase != "LIVE": return
	var is_a := at.x > 10 and at.z < -8
	var is_b := at.x < -16 and at.z < -12
	if not is_a and not is_b: return
	if game.elapsed < support_until and is_instance_valid(supporter) and supporter.health > 0:
		if support_a == is_a:
			support_until = game.elapsed + 5.0
			support_contact = at
		return
	support_a = is_a
	support_contact = at
	var rendezvous := Layout.on_floor(Vector3(16, 0, -24) if is_a else Vector3(-18, 0, -27))
	var best := INF
	supporter = null
	for bot in game.bots:
		if bot.team != 0 or bot == reporter or bot.health <= 0 or bot.target != null: continue
		var cost := route_cost(bot, rendezvous)
		if cost < best:
			best = cost
			supporter = bot
	if supporter != null:
		support_until = game.elapsed + 5.0
		plan_left = 0

func plan_roles() -> void:
	roles.clear()
	if not game.bomb_active and game.elapsed < support_until and is_instance_valid(supporter) and supporter.health > 0:
		var at := Layout.on_floor(Vector3(16, 0, -24) if support_a else Vector3(-18, 0, -27))
		roles[supporter.index] = {"role": "SUPPORT", "goal": at, "look": support_contact + Vector3.UP * 1.4}
	if dropped:
		if not is_instance_valid(retriever) or retriever.health <= 0: retriever = closest_bot(1, dropped_at)
		if is_instance_valid(retriever): roles[retriever.index] = {"role": "RECOVER", "goal": dropped_at, "look": dropped_at + Vector3.UP * 1.4}
	if not game.bomb_active: return
	if is_instance_valid(game.defuser) and game.defuser.health > 0:
		defuse_bot = game.defuser # Preserve a human or bot already doing the job.
	elif not is_instance_valid(defuse_bot) or defuse_bot.health <= 0:
		defuse_bot = closest_bot(0, game.bomb_at)
	var is_a: bool = game.bomb_at.x > 0
	var holds: Array = A_HOLDS if is_a else B_HOLDS
	var lanes: Array = A_LANES if is_a else B_LANES
	var retake: Array = A_RETAKE if is_a else B_RETAKE
	var ct_index := 0
	var t_index := 0
	for bot in game.bots:
		if bot.health <= 0: continue
		if bot == defuse_bot:
			roles[bot.index] = {"role": "DEFUSE", "goal": game.bomb_at, "look": game.bomb_at + Vector3.UP}
			continue
		var index := ct_index if bot.team == 0 else t_index
		if bot.team == 0: ct_index += 1
		else: t_index += 1
		var positions: Array = retake if bot.team == 0 else holds
		var goal := Layout.on_floor(positions[index % positions.size()])
		var look: Vector3 = game.bomb_at if bot.team == 0 else Layout.on_floor(lanes[index % lanes.size()])
		roles[bot.index] = {"role": "COVER" if bot.team == 0 else "HOLD", "goal": goal, "look": look + Vector3.UP * 1.4}

func assignment(actor: Node3D) -> Dictionary:
	return roles.get(actor.index, {})

func _physics_process(dt: float) -> void:
	if game.paused or game.phase != "LIVE": return
	if plant_progress > 0 and game.elapsed - plant_last > 0.12: plant_progress = 0
	if is_instance_valid(defuse_bot) and defuse_bot.health <= 0:
		defuse_bot = null
		plan_left = 0
	plan_left -= dt
	if plan_left <= 0:
		plan_left = 0.5
		plan_roles()
	if dropped:
		for bot in game.bots:
			if recover(bot): break
