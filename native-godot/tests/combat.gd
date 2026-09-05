extends SceneTree

const Layout = preload("res://scripts/layout.gd")
var game: Node3D
var checks := 0
var failures := 0

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

func shot(attacker: Node3D, victim: Node3D, height: float) -> void:
	var start := attacker.global_position + Vector3.UP * height
	var end := victim.global_position + Vector3.UP * height
	game.fire_shot(attacker, start, (end - start).normalized(), attacker.slot, 0)

func run() -> void:
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	for bot in game.bots: bot.set_physics_process(false)
	game.player.set_physics_process(false)
	game.set_paused(false)
	game.phase = "LIVE"
	game.phase_left = 100
	game.player.position = Vector3(1, 0, 4)
	var enemy: Node3D = game.bots[4]
	enemy.position = Vector3(1, 0, 9)
	await frames(3)
	check(game.player.camera.is_current() and not game.spectator.active, "Living player owns the camera")
	game.spectator.cycle()
	await frames(2)
	check(not game.spectator.active, "Living player cannot enter spectator mode")
	shot(game.player, enemy, 1.1)
	check(is_equal_approx(enemy.health, 71), "Actual body ray applies rifle damage")
	check(game.combat.exchanges[game.combat.key(game.player, enemy)].hits == 1, "Damage ledger records actual ray hit")
	shot(game.player, enemy, 1.66)
	check(enemy.health == 0 and game.kill_feed.size() == 1, "Actual head ray kills and creates one feed entry")
	check(game.kill_feed[0].headshot and game.kill_feed[0].slot == 0 and game.kill_feed[0].personal, "Feed identifies headshot, weapon and player involvement")
	check(game.combat.exchanges[game.combat.key(game.player, enemy)].damage == 100, "Damage recap counts health lost, not headshot overkill")
	check(game.combat.kill_until > game.elapsed, "Elimination has a distinct confirmation marker")
	enemy = game.bots[5]
	enemy.position = Vector3(1, 0, 9)
	await frames(2)
	shot(game.player, enemy, 1.1)
	shot(enemy, game.player, 1.1)
	check(game.player.health == 65 and game.combat.incoming.size() == 1, "Incoming ray records directional cue and health loss")
	var source: Vector3 = game.combat.incoming[0].from
	enemy.position.x += 1
	check(game.combat.incoming[0].from == source, "Damage cue retains hit-time position, not a moving enemy reference")
	enemy.position.x -= 1
	game.player.rotation.y = 0
	game.player.camera.rotation = Vector3.ZERO
	check(game.combat.bearing(game.player.camera.global_position + Vector3.FORWARD * 5, game.player.camera).is_equal_approx(Vector2.UP), "Front damage appears above crosshair")
	check(game.combat.bearing(game.player.camera.global_position + Vector3.RIGHT * 5, game.player.camera).is_equal_approx(Vector2.RIGHT), "Right damage appears right of crosshair")
	game.player.rotation.y = PI
	check(game.combat.bearing(game.player.camera.global_position + Vector3.FORWARD * 5, game.player.camera).is_equal_approx(Vector2.DOWN), "Turning updates damage bearing relative to camera")
	await frames(2)
	shot(enemy, game.player, 1.66)
	check(game.player.health == 0 and game.deaths == 1, "Lethal ray enters death state once")
	var report: Dictionary = game.combat.death_report
	check(not report.is_empty() and report.killer == game.actor_name(enemy) and report.headshot, "Death recap identifies actual killer and lethal hit type")
	check(report.received == 100 and report.received_hits == 2 and report.dealt == 29 and report.dealt_hits == 1, "Death recap distinguishes damage exchanged with this killer")
	check(not game.spectator.active and game.player.camera.is_current(), "Brief death view precedes automatic teammate follow")
	await frames(76)
	check(game.spectator.active and game.spectator.camera.is_current(), "Death automatically switches to spectator camera")
	var first: Node3D = game.spectator.target
	check(first.team == 0 and first.health > 0 and game.spectator.candidates().size() == 4, "Spectator only selects living teammates")
	var tap := InputEventAction.new()
	tap.action = "fire"
	tap.pressed = true
	game._unhandled_input(tap)
	await frames(2)
	check(game.spectator.target != first and game.spectator.target.team == 0, "Fire input cycles to next teammate while dead")
	tap.action = "aim"
	game._unhandled_input(tap)
	await frames(2)
	check(game.spectator.target == first, "Aim input cycles back to previous teammate")
	var before: int = game.player.shot_count
	check(not game.player.fire() and game.player.shot_count == before, "Spectating cannot shoot from dead player")
	game.set_paused(true)
	game.spectator.cycle()
	var camera_at: Vector3 = game.spectator.camera.global_position
	first.position.x += 1
	var elapsed: float = game.elapsed
	await frames(4)
	check(game.spectator.camera.global_position == camera_at and game.spectator.target == first and game.elapsed == elapsed, "Pause freezes spectator, target cycling and combat timers")
	game.set_paused(false)
	first.position = Vector3(1, 0, 2)
	first.rotation.y = 0
	await frames(3)
	check(game.spectator.camera.global_position.distance_to(first.eye()) > 2, "Open space gives a shoulder-follow view")
	var obstacle: Node3D = game.world.box(Vector3(1, 1.5, 3.2), Vector3(5, 3, 0.25), game.world.material(Color.GRAY), true)
	await frames(3)
	var anchor: Vector3 = first.eye()
	var camera: Camera3D = game.spectator.camera
	var ray := PhysicsRayQueryParameters3D.create(anchor, camera.global_position, 1)
	check(game.get_world_3d().direct_space_state.intersect_ray(ray).is_empty(), "Solid wall cannot separate followed teammate and camera")
	check(camera.global_position.z < 2.95 and camera.global_position.distance_to(anchor) < 1.5, "Camera volume retracts before a nearby wall")
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = game.spectator.probe
	query.collision_mask = 1
	query.transform = Transform3D(Basis.IDENTITY, camera.global_position)
	check(game.get_world_3d().direct_space_state.intersect_shape(query).is_empty(), "Retracted camera sphere does not intersect wall geometry")
	obstacle.queue_free()
	await frames(3)
	check(camera.global_position.distance_to(first.eye()) > 2, "Camera extends again when obstruction is removed")
	first.model.visible = false
	first.take_hit(500, enemy)
	await frames(3)
	check(game.spectator.target != first and game.spectator.target.health > 0 and first.model.visible, "Followed teammate death selects a survivor and restores model visibility")
	game.elapsed += 8
	game.combat.tick()
	check(game.kill_feed.is_empty() and game.combat.incoming.is_empty(), "Feed and damage cues expire on simulation time")
	for bot in game.bots:
		if bot.team == 0 and bot.health > 0: bot.take_hit(500, enemy)
	await frames(3)
	check(not game.spectator.active and game.spectator.target == null and game.player.camera.is_current(), "No surviving ally returns a valid waiting camera, never an enemy")
	game.new_round()
	await frames(3)
	check(game.player.health == 100 and game.player.camera.is_current() and not game.spectator.active, "New round restores living player camera")
	check(game.combat.exchanges.is_empty() and game.combat.death_report.is_empty() and game.kill_feed.is_empty(), "Round reset discards stale reports, ledger and feed")
	print("COMBAT: ", checks - failures, "/", checks, " passed")
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
