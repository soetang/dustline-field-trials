extends SceneTree

const Layout = preload("res://scripts/layout.gd")
const Weapons = preload("res://scripts/weapons.gd")
const Models = preload("res://scripts/models.gd")
var failures := 0
var checks := 0
var game: Node3D

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: ", description)
	else: print("PASS: ", description)

func frames(count: int) -> void:
	for i in count: await physics_frame

func run() -> void:
	for asset in ["ct_operator", "t_operator", "view_m4", "view_ak", "view_awp", "view_deagle"]:
		var model_scene: PackedScene = Models.ASSETS[asset]
		var model := model_scene.instantiate()
		root.add_child(model)
		Models.prepare(model)
		await process_frame
		var valid := true
		for node in model.find_children("*", "MeshInstance3D", true, false):
			for surface in node.mesh.get_surface_count():
				valid = valid and node.get_active_material(surface).vertex_color_use_as_albedo
		check(valid, asset + " preserves original vertex-colour palette")
		model.queue_free()
		await process_frame
	var layout := Layout.new()
	var landmarks := [Layout.CT_SPAWN, Layout.T_SPAWN, Layout.SITE_A, Layout.SITE_B, Vector3(-33, 0, 12), Vector3(37, 0, 0), Vector3(15, 0, -14)]
	for a in landmarks:
		for b in landmarks:
			if a == b: continue
			var route := layout.path(Layout.on_floor(a), Layout.on_floor(b))
			check(not route.is_empty(), "Route %s → %s" % [a, b])
			for i in range(1, route.size()):
				if not layout.segment_clear(route[i - 1], route[i]):
					check(false, "Route body clearance")
					break
	check(Layout.floor_height(Vector2(27, -29)) > 2.0, "A site is elevated")
	check(not layout.segment_clear(Layout.CT_SPAWN, Layout.T_SPAWN), "Spawns are not connected by a straight open corridor")
	for slot in 4:
		var still := Weapons.spread(slot, 0, false, true, false, 0)
		check(Weapons.spread(slot, 5, false, true, false, 0) > still * 2, "Weapon %d movement hurts precision" % slot)
		check(Weapons.spread(slot, 0, true, true, false, 0) > still * 3, "Weapon %d jumping hurts precision" % slot)
		check(Weapons.spread(slot, 0, false, true, false, 8) > still, "Weapon %d sustained fire blooms" % slot)
		check(Weapons.spread(slot, 0, false, true, true, 0) < still, "Weapon %d crouching helps precision" % slot)
	var packed: PackedScene = load("res://main.tscn")
	game = packed.instantiate()
	root.add_child(game)
	current_scene = game
	await frames(3)
	check(game.bots.size() == 9, "5 versus 5 actors spawned")
	game.set_paused(false)
	var initial: Vector3 = game.player.position
	var bot_initial: Vector3 = game.bots[0].position
	Input.action_press("forward")
	await frames(90)
	check(Vector2(game.player.position.x - initial.x, game.player.position.z - initial.z).length() < 0.01, "Buy phase freezes player movement")
	check(game.bots[0].position == bot_initial, "Buy phase freezes bots")
	check(game.player.is_on_floor() and absf(game.player.position.y) < 0.12, "Player stands on actual terrain collision")
	check(not game.player.fire(), "Cannot shoot during buy phase")
	Input.action_release("forward")
	check(not game.buy(2), "Cannot buy unaffordable AWP")
	check(game.buy(1) and game.player.slot == 1 and game.money == 700, "Buy updates weapon and economy")
	game.phase = "LIVE"
	game.phase_left = 100
	Input.action_press("forward")
	await frames(60)
	Input.action_release("forward")
	check(game.player.position.distance_to(initial) > 3.0, "Live physical WASD input moves player")
	await frames(15)
	var old_ammo: int = game.player.ammo
	check(game.player.fire(), "Live player can shoot")
	check(game.player.ammo == old_ammo - 1 and game.player.recoil.x > 0, "Shot consumes ammo and adds recoil")
	check(not game.player.fire(), "Rate limiter blocks simultaneous shot")
	check(game.player.reload_weapon(), "Reload starts")
	await frames(165)
	check(game.player.ammo == 30 and game.player.reserve == 89, "Timed reload transfers reserve correctly")
	var paused_position: Vector3 = game.player.position
	game.set_paused(true)
	var time_before: float = game.phase_left
	Input.action_press("forward")
	await frames(30)
	check(game.phase_left == time_before and game.player.position == paused_position, "Pause freezes movement and round timer")
	Input.action_release("forward")
	game.set_paused(false)
	var probe: Node3D = game.bots[4]
	probe.position = Layout.on_floor(Layout.T_SPAWN)
	game.player.position = Layout.on_floor(Layout.CT_SPAWN)
	await frames(2)
	check(not probe.see(game.player), "Bot cannot see player through spawn buildings")
	# Exercise real collision rays with isolated actors, not a mocked combat system.
	for actor in game.bots:
		actor.set_physics_process(false)
		actor.position = Vector3(-38 + actor.index * 1.2, 0.03, -36)
	game.player.position = Vector3(37, Layout.floor_height(Vector2(37, 0)) + 0.03, 0)
	probe.position = Vector3(37, Layout.floor_height(Vector2(37, -5)) + 0.03, -5)
	probe.health = 100
	probe.collision_layer = 4
	await frames(2)
	var from: Vector3 = game.player.position + Vector3.UP * 1.4
	var to: Vector3 = probe.position + Vector3.UP * 1.4
	var hit: Dictionary = game.fire_shot(game.player, from, (to - from).normalized(), 0, 0)
	check(not hit.is_empty() and hit.collider == probe and probe.health == 71, "Hitscan ray damages visible enemy")
	var wall_hit: Dictionary = game.fire_shot(game.player, from, Vector3.LEFT, 0, 0)
	check(not wall_hit.is_empty() and not wall_hit.collider.has_method("take_hit"), "Wall blocks hitscan ray")
	game.player.position = Layout.on_floor(Layout.SITE_A) + Vector3.UP * 0.05
	game.player.velocity = Vector3.ZERO
	var carrier: Node3D = game.objective.carrier
	carrier.position = Layout.on_floor(Layout.SITE_A)
	carrier.velocity = Vector3.ZERO
	game.objective.try_plant(carrier, 3.0)
	check(game.bomb_active, "Plant creates active objective at a site")
	game.defuse(game.player, 2.0)
	game.defuse(game.bots[0], 2.0)
	check(game.defuser == game.player and game.defuse_progress == 2.0, "Another defender cannot steal defuse ownership")
	game.defuse(game.player, 3.0)
	check(not game.bomb_active and game.ct_score == 1 and game.phase == "OVER", "Five-second defuse wins round")
	for type in game.sound.samples:
		var data: PackedByteArray = game.sound.samples[type].data
		var energy := 0.0
		for i in range(0, data.size(), 2): energy += absf(data.decode_s16(i))
		check(energy > 0, "Generated %s sound contains PCM energy" % type)
	# Long-run live bot test. No teleporting during navigation measurement.
	game.new_round()
	game.phase = "LIVE"
	game.phase_left = 100
	game.player.health = 0 # Observe; no invulnerable human target changes combat.
	game.player.collision_layer = 0
	for i in 1800:
		await physics_frame
		if game.phase != "LIVE": break
	var bot_travel := 0.0
	var bot_shots := 0
	var stuck := 0
	for actor in game.bots:
		bot_travel += actor.travel
		bot_shots += actor.shots
		if actor.health > 0 and actor.stuck_time > 0.5: stuck += 1
		check(actor.position.y > -0.2, "Bot %d stays on terrain" % actor.index)
	print("AI_METRICS travel=", bot_travel, " shots=", bot_shots, " stuck=", stuck, " phase=", game.phase)
	check(bot_travel > 150, "Bots traverse routes in live physics")
	check(bot_shots > 5, "Bots acquire targets and fire during live play")
	check(stuck < 3, "No broad bot wall-sticking")
	print("VERIFICATION: ", checks - failures, "/", checks, " passed")
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
