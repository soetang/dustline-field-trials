extends SceneTree

## Actual bot opening bursts against the real player collision/damage model.
## Fixture positions/times isolate accuracy, not a claim about whole-match balance.
const ENCOUNTERS := 600
var game: Node3D
var shooter: Node3D
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool,label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: ",label)

func measure(distance: float,elevation: float,crouched: bool,slot: int) -> void:
	game.player.position = Vector3(100,0,100)
	game.player.crouched = crouched
	game.player.capsule.height = 1.25 if crouched else 1.8
	game.player.collision.position.y = game.player.capsule.height*0.5
	shooter.position = Vector3(100,elevation,100+distance)
	shooter.rotation.y = 0
	shooter.slot = slot
	shooter.target = game.player
	shooter.rng.seed = 7321
	game.rng.seed = 98271
	for i in 2: await physics_frame
	var shots := 0
	var first_shot_heads := 0
	var first_hits := 0
	var first_hit_heads := 0
	var hits := 0
	for encounter in ENCOUNTERS:
		var hit_yet := false
		shooter.burst_shots = 0
		shooter.burst_left = 3
		shooter.higher_aim = false
		shooter.ammo = 30
		for shot in 3:
			shooter.cooldown = 0
			shooter.contact_age = 0.35+shot*0.105
			game.player.health = 1000
			if shooter.shoot(): shots += 1
			var damage: float = 1000-game.player.health
			if damage <= 0: continue
			hits += 1
			var headshot := damage > 70
			if shot == 0 and headshot: first_shot_heads += 1
			if not hit_yet:
				first_hits += 1
				if headshot: first_hit_heads += 1
				hit_yet = true
	var label := "slot%d %dm y%+.1f %s" % [slot,distance,elevation,"crouched" if crouched else "standing"]
	var head_fraction := float(first_hit_heads)/maxi(first_hits,1)
	print("OPENING_SAMPLE ",JSON.stringify({"case":label,"encounters":ENCOUNTERS,"shots":shots,
		"hits":hits,"first_shot_heads":first_shot_heads,"first_hits":first_hits,
		"first_hit_heads":first_hit_heads,"first_hit_head_fraction":head_fraction}))
	check(shots == ENCOUNTERS*3,label+" actually fires every tested shot")
	check(first_shot_heads < ENCOUNTERS*0.05,label+" opening bullets rarely become headshots")
	check(head_fraction < 0.12,label+" first connecting hit is not head-biased")

func run() -> void:
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.set_paused(false)
	game.phase = "LIVE"
	game.set_physics_process(false)
	game.player.set_physics_process(false)
	for bot in game.bots: bot.set_physics_process(false)
	shooter = game.bots[4]
	for slot in [0,1]:
		for distance in [5,18,35,50]: await measure(distance,0,false,slot)
		for distance in [18,35,50]: await measure(distance,0,true,slot)
		await measure(8,2.2,false,slot)
		await measure(3,2.2,false,slot)
		await measure(18,-2.2,false,slot)
	print("ENCOUNTERS: %d/%d passed" % [checks-failures,checks])
	game.queue_free()
	await process_frame
	quit(1 if failures else 0)
