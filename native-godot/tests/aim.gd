extends SceneTree

const Aim = preload("res://scripts/bot_aim.gd")
var game: Node3D
var shooter: Node3D
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, label: String) -> void:
	checks += 1
	if condition: print("PASS: ", label)
	else:
		failures += 1
		printerr("FAIL: ", label)

func frames(count: int) -> void:
	for i in count: await physics_frame

func stance(crouched: bool) -> void:
	game.player.crouched = crouched
	game.player.capsule.height = 1.25 if crouched else 1.8
	game.player.collision.position.y = game.player.capsule.height * 0.5

func measure(crouched: bool, old: bool, settled: bool, moving: bool = false) -> Dictionary:
	stance(crouched)
	await frames(2)
	var random := RandomNumberGenerator.new()
	random.seed = 44551
	game.rng.seed = 1827
	var hits := 0
	var heads := 0
	var high := false
	var offset := 0.0
	var track := 0.0
	var damage := 0.0
	for i in 2400:
		if i % 3 == 0:
			high = settled and not moving and random.randf() < 0.08
			offset = random.randf_range(-1, 1)
			track = random.randf_range(-1, 1)
		var height: float = random.randf_range(1.05, 1.5) if old else Aim.aim_height(crouched, high, offset)
		var age := 2.0 if settled else 0.35
		var spread: float = deg_to_rad(0.75) if old else Aim.spread(1, age, 0, i % 3)
		var aim: Vector3 = game.player.position + Vector3.UP * height
		if not old: aim.x += Aim.lateral_error(age, 4.5 if moving else 0, 18, track)
		game.player.health = 1000
		var result: Dictionary = game.fire_shot(shooter, shooter.eye(), (aim - shooter.eye()).normalized(), 1, spread)
		if result.get("collider") == game.player:
			hits += 1
			damage += 1000 - game.player.health
			if result.position.y - game.player.position.y > (0.98 if crouched else 1.48): heads += 1
	var result := {"crouched": crouched, "old": old, "settled": settled, "moving": moving,
		"shots": 2400, "hits": hits, "heads": heads, "damage": damage,
		"head_fraction": float(heads) / maxi(hits, 1), "hit_fraction": hits / 2400.0}
	print("AIM_SAMPLE ", JSON.stringify(result))
	return result

func run() -> void:
	check(not Aim.higher_aim_allowed(0.5, 0, 0, 10), "A fresh contact cannot trigger deliberate higher aim")
	check(not Aim.higher_aim_allowed(2, 2, 0, 10), "A moving shooter cannot take a deliberate precision burst")
	check(not Aim.higher_aim_allowed(2, 0, 4, 10), "A running target is not instantly tracked for a precision burst")
	check(not Aim.higher_aim_allowed(2, 0, 0, 35), "Long-range bots normally aim at center mass")
	check(Aim.higher_aim_allowed(2, 0, 0, 15), "A settled bot can still punish a stationary exposed target")
	check(Aim.aim_height(true, false, 1) < 0.98 and Aim.aim_height(false, false, 1) < 1.48, "Normal aim stays below the head threshold for both stances")
	check(Aim.spread(1, 0.3, 0, 0) > Aim.spread(1, 2, 0, 0), "New contacts need time to settle")
	check(Aim.lateral_error(2, 4, 18, 1) > Aim.lateral_error(2, 0, 18, 1), "Moving targets are harder to track sideways")
	check(Aim.spread(1, 2, 0, 3) > Aim.spread(0, 2, 0, 3), "Weapon type and firing cadence affect bot precision")
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.set_paused(false)
	game.phase = "LIVE"
	game.set_physics_process(false)
	game.player.set_physics_process(false)
	for bot in game.bots: bot.set_physics_process(false)
	# Isolate from map geometry, but use the real player capsule, bullet rays,
	# headshot threshold and damage calculation. No analytic hit approximation.
	game.player.position = Vector3(100, 0, 100)
	shooter = game.bots[4]
	shooter.position = Vector3(100, 0, 118)
	shooter.rotation.y = 0
	shooter.target = game.player
	await frames(2)
	var standing_old := await measure(false, true, false)
	var standing_first := await measure(false, false, false)
	var standing_settled := await measure(false, false, true)
	var running := await measure(false, false, true, true)
	var crouched_old := await measure(true, true, false)
	var crouched_first := await measure(true, false, false)
	check(standing_first.head_fraction < standing_old.head_fraction * 0.7, "First-contact standing headshots are materially less frequent")
	check(crouched_first.head_fraction < crouched_old.head_fraction * 0.4, "Crouching no longer turns almost every hit into a headshot")
	check(crouched_first.head_fraction < 0.12, "Reference crouched burst stays body-focused, not head-biased")
	check(standing_settled.hit_fraction > 0.65 and standing_settled.heads > 40, "Settled fire remains dangerous, with occasional genuine headshots")
	check(running.hit_fraction < standing_settled.hit_fraction, "Running disrupts tracking without granting immunity")
	check(running.heads < standing_settled.heads, "Tracking error does not increase stray headshot counts")
	check(crouched_first.hit_fraction > 0.35 and standing_first.hit_fraction > 0.45, "Body-focused bursts still connect and punish exposure")
	stance(false)
	await frames(2)
	var high_bursts := 0
	for i in 1000:
		shooter.contact_age = 2
		shooter.burst_shots = 0
		shooter.burst_left = 3
		shooter.cooldown = 0
		shooter.ammo = 30
		game.player.health = 1000
		shooter.shoot()
		if shooter.higher_aim: high_bursts += 1
	check(high_bursts > 35 and high_bursts < 140, "Real bot firing chooses occasional, not constant, precision bursts")
	print("HIGHER_AIM_BURSTS ", high_bursts, "/1000")
	var cover: Node3D = game.world.box(Vector3(100, 0.56, 101.3), Vector3(2, 1.12, 0.35), game.world.material(Color.GRAY), true)
	await frames(2)
	check(shooter.see(game.player), "Standing chest remains visible above low cover")
	stance(true)
	await frames(2)
	check(not shooter.see(game.player), "Crouched chest is occluded by the same cover")
	shooter.cooldown = 0
	shooter.contact_age = 3
	shooter.higher_aim = true
	check(not shooter.shoot() and shooter.contact_age == 0 and not shooter.higher_aim, "Losing sight clears precision focus and cannot fire through cover")
	cover.queue_free()
	print("AIM: ", checks - failures, "/", checks, " passed")
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
