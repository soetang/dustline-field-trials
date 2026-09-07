extends SceneTree

## Duplicate-query removal: count calls and compare the old decisions, shot
## arguments and RNG state. Failed LOS now deliberately clears precision focus;
## all other shot state stays identical. No wall-clock performance test.
const Bot = preload("res://scripts/bot.gd")

class CountingLayout:
	extends RefCounted
	var blocked := PackedVector3Array()
	var segments: Array[Array] = []
	var replans: Array[Array] = []
	var replacement := PackedVector3Array([Vector3(8, 0, 0)])
	func segment_clear(from: Vector3, to: Vector3) -> bool:
		segments.append([from, to])
		return not blocked.has(to)
	func path(from: Vector3, to: Vector3) -> PackedVector3Array:
		replans.append([from, to])
		return replacement.duplicate()

class Objective:
	extends RefCounted
	var carrier: Node3D
	var plants := 0
	func try_plant(_bot: Node3D, _dt: float) -> void:
		plants += 1

class Sound:
	extends RefCounted
	var calls: Array[Array] = []
	func play_at(kind: String, at: Vector3, volume: float, pitch: float) -> void:
		calls.append([kind, at, volume, pitch])

class Actor:
	extends CharacterBody3D
	var health := 100.0
	var team := 0
	var crouched := false
	func take_hit(_damage: float, _attacker: Node3D, _headshot: bool = false) -> void:
		pass

class Fixture:
	extends Node3D
	var layout := CountingLayout.new()
	var objective := Objective.new()
	var sound := Sound.new()
	var player: Actor
	var bots: Array[Node3D] = []
	var paused := false
	var phase := "LIVE"
	var elapsed := 0.0
	var bomb_active := false
	var bomb_at := Vector3.ZERO
	var bomb_left := 35.0
	var defuses := 0
	var fires: Array[Array] = []
	func defuse(_bot: Node3D, _dt: float) -> void:
		defuses += 1
	func fire_shot(_bot: Node3D, from: Vector3, direction: Vector3, slot: int, spread: float, vertical_scale: float) -> void:
		fires.append([from, direction, slot, spread, vertical_scale])

class CountingBot:
	extends Bot
	var sight_calls := 0
	func _ready() -> void:
		# Keep real CharacterBody3D movement and physics sight/shot rays, without
		# a render model, autonomous ticks, or unrelated match setup.
		collision_layer = 4
		collision_mask = 0
		set_process(false)
		set_physics_process(false)
	func see(other: Node3D) -> bool:
		sight_calls += 1
		return super.see(other)

var checks := 0
var failures := 0
var fixture: Fixture
var bot: CountingBot
var wall: StaticBody3D
var buddy: Actor

func _initialize() -> void:
	call_deferred("run")

func check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: ", label)

func reset_bot() -> void:
	bot.position = Vector3.ZERO
	bot.rotation = Vector3.ZERO
	bot.velocity = Vector3.ZERO
	bot.health = 100
	bot.slot = 1
	bot.ammo = 30
	bot.cooldown = 0
	bot.reload_left = 0
	bot.reaction = 0
	bot.burst_pause = 0
	bot.burst_left = 3
	bot.burst_shots = 0
	bot.contact_age = 1.7
	bot.higher_aim = true
	bot.aim_sample = 0
	bot.tracking_sample = 0
	bot.memory = 0
	bot.heard = 0
	bot.blocked_fire = 0
	bot.friendly_blocks = 0
	bot.shots = 0
	bot.think_left = 10
	bot.progress_left = 10
	bot.path = PackedVector3Array()
	bot.path_goal = Vector3(12, 0, 0)
	bot.target = null
	bot.look_goal = Vector3(0, 1.52, -10)
	bot.role = "ATTACK"
	bot.mission = Vector3.ZERO
	bot.route.clear()
	bot.sight_calls = 0
	bot.rig.recoil = 0
	bot.rig.flash_left = 0
	bot.rng.seed = 7321
	fixture.layout = CountingLayout.new()
	fixture.fires.clear()
	fixture.sound.calls.clear()
	fixture.objective.carrier = null
	fixture.objective.plants = 0
	fixture.defuses = 0
	fixture.bomb_active = false
	fixture.paused = false
	fixture.phase = "LIVE"
	fixture.player.health = 100
	fixture.player.crouched = false
	fixture.player.velocity = Vector3.ZERO
	fixture.player.position = Vector3(0, 0, -18)

func old_waypoints(layout: CountingLayout, at: Vector3, route: PackedVector3Array, goal: Vector3) -> PackedVector3Array:
	# Original branch order, including the redundant successful shortcut query.
	while not route.is_empty() and Vector2(at.x - route[0].x, at.z - route[0].z).length() < 0.25:
		route.remove_at(0)
	if route.size() > 1 and layout.segment_clear(at, route[1]): route.remove_at(0)
	if not route.is_empty() and not layout.segment_clear(at, route[0]):
		route = layout.path(at, goal)
	return route

func waypoint_case(label: String, route: PackedVector3Array, blocked: PackedVector3Array, old_calls: int, new_calls: int) -> void:
	reset_bot()
	bot.path = route.duplicate()
	fixture.layout.blocked = blocked
	var original := CountingLayout.new()
	original.blocked = blocked
	var expected := old_waypoints(original, bot.position, route.duplicate(), bot.path_goal)
	bot._physics_process(0)
	check(bot.path == expected, label + ": identical waypoints")
	check(fixture.layout.replans == original.replans, label + ": identical replan arguments")
	check(original.segments.size() == old_calls and fixture.layout.segments.size() == new_calls, label + ": expected segment call reduction")
	var expected_queries := original.segments.duplicate()
	if old_calls != new_calls: expected_queries.remove_at(1)
	check(fixture.layout.segments == expected_queries, label + ": no other segment query removed")

func shot_state() -> Dictionary:
	return {"ammo": bot.ammo, "cooldown": bot.cooldown, "reload": bot.reload_left,
		"burst_left": bot.burst_left, "burst_shots": bot.burst_shots, "burst_pause": bot.burst_pause,
		"contact_age": bot.contact_age, "higher_aim": bot.higher_aim,
		"aim_sample": bot.aim_sample, "tracking_sample": bot.tracking_sample,
		"shots": bot.shots, "blocked_fire": bot.blocked_fire, "friendly_blocks": bot.friendly_blocks,
		"think_left": bot.think_left, "rng_state": bot.rng.state,
		"recoil": bot.rig.recoil, "flash_left": bot.rig.flash_left,
		"fires": fixture.fires.duplicate(true), "sounds": fixture.sound.calls.duplicate(true)}

func old_outer_fire() -> void:
	# Historical gate for query-count/state comparison. Its stale precision on
	# failed LOS is the explicit fairness exception recorded in shot_case().
	if is_instance_valid(bot.target) and bot.target.health > 0 and bot.reaction <= 0 and bot.cooldown <= 0 and bot.burst_pause <= 0 and bot.reload_left <= 0 and bot.see(bot.target):
		bot.shoot()

func configure_shot(settings: Dictionary) -> void:
	reset_bot()
	bot.target = fixture.player
	for property in settings:
		if property == "seed": bot.rng.seed = settings[property]
		elif property == "crouched": fixture.player.crouched = settings[property]
		elif property == "target_speed": fixture.player.velocity.x = settings[property]
		else: bot.set(property, settings[property])

func shot_case(label: String, settings: Dictionary, old_calls: int, new_calls: int, resets_focus: bool = false) -> void:
	configure_shot(settings)
	old_outer_fire()
	var expected := shot_state()
	var original_calls := bot.sight_calls
	if resets_focus:
		# Only these two fields intentionally differ from the historical gate.
		# Keep ammo, sound, burst state, samples, RNG and all other fields strict.
		expected.contact_age = 0.0
		expected.higher_aim = false
	configure_shot(settings)
	bot._physics_process(0)
	check(shot_state() == expected, label + ": exact shot, sound, burst, RNG and intended contact state")
	check(original_calls == old_calls and bot.sight_calls == new_calls, label + ": expected sight call reduction")

func add_capsule(actor: Actor) -> void:
	actor.collision_layer = 2
	actor.collision_mask = 0
	var shape := CollisionShape3D.new()
	shape.shape = CapsuleShape3D.new()
	shape.shape.radius = 0.32
	shape.shape.height = 1.8
	shape.position.y = 0.9
	actor.add_child(shape)

func run() -> void:
	fixture = Fixture.new()
	root.add_child(fixture)
	fixture.player = Actor.new()
	fixture.add_child(fixture.player)
	add_capsule(fixture.player)
	bot = CountingBot.new()
	bot.game = fixture
	fixture.add_child(bot)
	fixture.bots.append(bot)
	buddy = Actor.new()
	buddy.team = bot.team
	buddy.position = Vector3(100, 0, 0)
	fixture.add_child(buddy)
	add_capsule(buddy)
	wall = StaticBody3D.new()
	wall.position = Vector3(100, 1, -9)
	var wall_shape := CollisionShape3D.new()
	wall_shape.shape = BoxShape3D.new()
	wall_shape.shape.size = Vector3(4, 4, 0.5)
	wall.add_child(wall_shape)
	fixture.add_child(wall)
	reset_bot()
	for i in 2: await physics_frame

	var a := Vector3(2, 0, 0)
	var b := Vector3(4, 0, 0)
	waypoint_case("empty", [], [], 0, 0)
	waypoint_case("all reached", [Vector3(0.1, 0, 0), Vector3(0.2, 0, 0)], [], 0, 0)
	waypoint_case("single clear", [a], [], 1, 1)
	waypoint_case("single blocked", [a], [a], 1, 1)
	waypoint_case("clear shortcut", [a, b], [], 2, 1)
	waypoint_case("reached then clear shortcut", [Vector3(0.1, 0, 0), Vector3(0.2, 0, 0), a, b], [], 2, 1)
	waypoint_case("blocked shortcut", [a, b], [b], 2, 2)
	waypoint_case("both blocked", [a, b], [a, b], 2, 2)
	waypoint_case("just inside arrival radius", [Vector3(0.2499, 0, 0), a], [a], 1, 1)
	waypoint_case("exact arrival radius", [Vector3(0.25, 0, 0), a], [a], 2, 2)
	waypoint_case("just outside arrival radius", [Vector3(0.2501, 0, 0), a], [a], 2, 2)

	# Deterministic seeded opening/sustained bursts exercise all weapon slots,
	# both stances, tracking error, higher aim and end-of-burst RNG draws.
	for seed in [31, 512, 901, 4821]:
		for slot in 4:
			for burst in [0, 2]:
				shot_case("seed %d slot %d burst %d" % [seed, slot, burst],
					{"seed": seed, "slot": slot, "burst_shots": burst, "burst_left": 1 if burst else 3,
					"crouched": slot % 2 == 0, "target_speed": 4.5 if seed % 2 else 0.0}, 2, 1)
	shot_case("empty magazine", {"ammo": 0}, 2, 1)
	shot_case("waiting reaction", {"reaction": 1.0}, 0, 0)
	shot_case("waiting cooldown", {"cooldown": 1.0}, 0, 0)
	shot_case("waiting burst pause", {"burst_pause": 1.0}, 0, 0)
	shot_case("waiting reload", {"reload_left": 1.0}, 0, 0)
	shot_case("outside FOV", {"rotation": Vector3(0, PI, 0)}, 1, 1, true)

	configure_shot({})
	check(bot.shoot() and bot.sight_calls == 1 and bot.ammo == 29, "direct shoot still validates sight and fires")
	configure_shot({"cooldown": 1.0})
	check(not bot.shoot() and bot.sight_calls == 0 and bot.contact_age == 1.7 and bot.higher_aim, "direct shoot retains early invalid-state guard")

	wall.position.x = 0
	for i in 2: await physics_frame
	shot_case("wall blocks outer fire", {}, 1, 1, true)
	check(bot.contact_age == 0 and not bot.higher_aim and bot.shots == 0, "outer failed LOS clears precision focus without firing")
	var expected_blocked := shot_state()
	expected_blocked.think_left -= 1.0 / 60.0
	bot.sight_calls = 0
	bot._physics_process(1.0 / 60.0)
	check(shot_state() == expected_blocked and bot.sight_calls == 1, "continued failed LOS prevents focus aging without changing shot, sound, burst, RNG or query count")
	configure_shot({})
	check(not bot.shoot() and bot.sight_calls == 1 and bot.contact_age == 0 and not bot.higher_aim, "direct failed LOS still resets contact and aim")
	wall.position.x = 100
	buddy.position = Vector3(0, 0, -3)
	for i in 2: await physics_frame
	shot_case("friendly muzzle obstruction", {}, 2, 1)
	check(bot.friendly_blocks == 1 and bot.ammo == 30 and bot.shots == 0, "reusing world LOS preserves friendly shot obstruction checks")
	buddy.position.x = 100
	for i in 2: await physics_frame

	configure_shot({})
	fixture.bomb_active = true
	fixture.bomb_left = 5
	bot.role = "DEFUSE"
	bot._physics_process(0)
	check(bot.sight_calls == 0 and bot.shots == 0 and fixture.defuses == 1, "working defuser still cannot fire")
	configure_shot({})
	bot.target = null
	fixture.objective.carrier = bot
	bot._physics_process(0)
	check(bot.sight_calls == 0 and bot.shots == 0 and fixture.objective.plants == 1, "working planter still cannot fire")
	print("QUERY_REUSE: %d/%d passed" % [checks - failures, checks])
	fixture.queue_free()
	await process_frame
	quit(1 if failures else 0)
