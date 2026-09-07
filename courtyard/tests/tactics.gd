extends SceneTree

const Layout = preload("res://scripts/layout.gd")
const Objective = preload("res://scripts/objective.gd")
var checks := 0
var failures := 0
var game: Node3D

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, message: String) -> void:
	checks += 1
	if condition: print("PASS: ", message)
	else:
		failures += 1
		printerr("FAIL: ", message)

func frames(count: int) -> void:
	for i in count: await physics_frame

func run() -> void:
	for hold in Objective.A_HOLDS + Objective.B_HOLDS + Objective.A_RETAKE + Objective.B_RETAKE:
		check(Layout.clear(Vector2(hold.x, hold.z), 0.43), "Tactical hold has actual body clearance: " + str(hold))
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.set_paused(false)
	game.phase = "LIVE"
	game.phase_left = 100
	for bot in game.bots: bot.set_physics_process(false)
	await frames(3)
	var objective: Node3D = game.objective
	var carrier: Node3D = objective.carrier
	check(is_instance_valid(carrier) and carrier.team == 1 and not objective.dropped, "Round has one living attacking carrier")
	var other: Node3D = game.bots[4] if carrier != game.bots[4] else game.bots[5]
	var reporter: Node3D = game.bots[0]
	reporter.think()
	check(objective.supporter == null, "Hidden spawn opponents do not trigger a squad rotation")
	reporter.position = Layout.on_floor(Vector3(-30, 0, -22))
	reporter.rotation.y = PI
	other.position = Layout.on_floor(Vector3(-33, 0, -14))
	await frames(2)
	reporter.think()
	objective.plan_roles()
	check(objective.supporter != null and objective.supporter != reporter and objective.assignment(objective.supporter).role == "SUPPORT", "Confirmed site contact calls one nearby backup defender")
	var backup: Node3D = objective.supporter
	game.elapsed = objective.support_until + 0.1
	objective.plan_roles()
	check(objective.assignment(backup).is_empty(), "Unrefreshed radio contact expires instead of tracking an enemy")
	reporter.target = null
	reporter.memory = 0
	reporter.position = Layout.on_floor(Layout.CT_SPAWN)
	carrier.position = Layout.on_floor(Layout.SITE_A)
	other.position = carrier.position + Vector3.RIGHT * 0.5
	carrier.velocity = Vector3.ZERO
	other.velocity = Vector3.ZERO
	check(not objective.try_plant(other, 3) and not game.plant(other) and not game.bomb_active, "Non-carrier cannot create another bomb")
	check(not objective.try_plant(carrier, 1) and objective.plant_progress == 1, "Plant requires continuous time")
	carrier.velocity.x = 1
	objective.try_plant(carrier, 0.2)
	check(objective.plant_progress == 0, "Moving cancels a plant")
	carrier.velocity = Vector3.ZERO
	objective.try_plant(carrier, 1)
	game.elapsed += 0.2
	objective._physics_process(0.2)
	check(objective.plant_progress == 0, "Interrupted plant does not retain progress")
	carrier.take_hit(200, game.player)
	check(objective.carrier == null and objective.dropped and is_instance_valid(objective.dropped_mesh), "Carrier death drops a recoverable physical device")
	game.player.position = objective.dropped_at
	check(not objective.recover(game.player) and not objective.recover(carrier), "Defender and dead carrier cannot recover device")
	other.position = Layout.on_floor(Layout.T_SPAWN)
	check(not objective.recover(other), "Device cannot be recovered remotely")
	other.position = objective.dropped_at + Vector3.RIGHT * 0.5
	await frames(2)
	# The production proximity updater may already recover it during these frames.
	if objective.dropped: objective.recover(other)
	check(objective.carrier == other and not objective.dropped and objective.pickups == 1, "Nearby living attacker recovers exactly one device")
	check(not objective.recover(game.bots[8]), "Recovered device cannot be duplicated")
	other.velocity = Vector3.ZERO
	check(objective.try_plant(other, 3) and game.bomb_active and objective.plants == 1, "Recovered carrier can complete a legal plant")
	check(not objective.try_plant(other, 3) and not game.plant(other), "A planted device cannot be planted twice")
	objective.plan_roles()
	var designated := 0
	var cover_goals: Array[Vector3] = []
	for bot in game.bots:
		if bot.team != 0 or bot.health <= 0: continue
		var job: Dictionary = objective.assignment(bot)
		if job.role == "DEFUSE": designated += 1
		else:
			check(not cover_goals.has(job.goal), "Defenders have distinct cover assignments")
			cover_goals.append(job.goal)
			check(job.goal.distance_to(game.bomb_at) > 3, "Cover role stays clear of the defuser")
	check(designated == 1 and cover_goals.size() == 3, "Exactly one bot defuses while three cover")
	game.player.velocity = Vector3.ZERO
	game.player.position = game.bomb_at
	game.defuse(game.player, 1)
	game.bots[0].position = game.bomb_at + Vector3.RIGHT * 0.6
	game.bots[0].velocity = Vector3.ZERO
	game.defuse(game.bots[0], 1)
	check(game.defuser == game.player and game.defuse_progress == 1, "Nearby teammate cannot steal active human defuse")
	objective.plan_roles()
	designated = 0
	for bot in game.bots:
		if bot.team == 0 and objective.assignment(bot).role == "DEFUSE": designated += 1
	check(designated == 0 and objective.defuse_bot == game.player, "All AI defenders cover an active human defuser")
	game.player.cooldown = 0
	check(not game.player.fire(), "Defusing player cannot fire simultaneously")
	game.player.velocity.x = 1
	game.defuse(game.player, 1)
	check(game.defuse_progress == 1, "Walking cannot advance a defuse")
	game.elapsed += 0.3
	game._physics_process(0.016)
	check(game.defuser == null and game.defuse_progress == 0, "Interrupted defuse loses progress")
	game.player.velocity = Vector3.ZERO
	# Real physics bodies: a friendly blocks the muzzle line, but not vision.
	var shooter: Node3D = game.bots[4]
	var buddy: Node3D = game.bots[5]
	for bot in game.bots:
		bot.position = Layout.on_floor(Layout.T_SPAWN) + Vector3.RIGHT * (bot.index * 0.7)
	shooter.health = 100
	shooter.collision_layer = 4
	buddy.health = 100
	buddy.collision_layer = 4
	shooter.position = Layout.on_floor(Vector3(37, 0, 0))
	shooter.rotation.y = 0
	buddy.position = Layout.on_floor(Vector3(37, 0, -3))
	game.player.position = Layout.on_floor(Vector3(37, 0, -7))
	game.player.health = 100
	shooter.target = game.player
	shooter.cooldown = 0
	shooter.ammo = 30
	await frames(2)
	check(not shooter.shoot() and shooter.ammo == 30 and shooter.friendly_blocks > 0, "Bot holds fire when a teammate blocks the shot")
	buddy.position.x = 40
	shooter.cooldown = 0
	await frames(2)
	check(shooter.shoot() and shooter.ammo == 29, "Bot fires when the friendly obstruction clears")
	shooter.cooldown = 2
	shooter.reaction = 0
	shooter.burst_pause = 0
	shooter.think_left = 2
	shooter.blocked_fire = 0
	shooter.path = PackedVector3Array([shooter.position + Vector3.RIGHT * 2])
	shooter.path_goal = shooter.path[0]
	shooter.set_physics_process(true)
	await frames(3)
	check(Vector2(shooter.velocity.x, shooter.velocity.z).length() < 0.1, "Bot settles its movement during a firing burst")
	shooter.burst_pause = 0.5
	await frames(3)
	check(Vector2(shooter.velocity.x, shooter.velocity.z).length() > 1, "Bot repositions during the burst pause")
	shooter.set_physics_process(false)
	print("TACTICS: ", checks - failures, "/", checks, " passed")
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
