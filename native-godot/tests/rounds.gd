extends SceneTree

const Bot = preload("res://scripts/bot.gd")
const Layout = preload("res://scripts/layout.gd")
const SEEDS := [31, 512, 901, 4821]
var failures := 0
var game: Node3D

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.player.set_physics_process(false)
	game.player.set_process(false)
	for seed in SEEDS:
		game.match_seed = seed
		game.rng.seed = seed
		game.round_number = 0
		game.ct_score = 0
		game.t_score = 0
		game.new_round()
		# Replace the human with a fifth defender for equal-team observation.
		game.player.health = 0
		game.player.collision_layer = 0
		var substitute := Bot.new()
		substitute.game = game
		substitute.team = 0
		substitute.index = 9
		substitute.slot = 0
		substitute.position = Layout.on_floor(Layout.CT_SPAWN + Vector3.RIGHT * 4) + Vector3.UP * 0.06
		game.add_child(substitute)
		game.bots.append(substitute)
		game.objective.reset_round()
		game.set_paused(false)
		game.phase = "LIVE"
		game.phase_left = 100
		var frames := 0
		var start: float = game.elapsed
		var sampled_positions: Dictionary = {}
		var stalled_windows: Dictionary = {}
		var worst_stall := 0
		while game.phase == "LIVE" and frames < 8400:
			await physics_frame
			frames += 1
			if frames % 120 != 0: continue
			for bot in game.bots:
				var needs_to_move: bool = bot.health > 0 and bot.target == null and not bot.path.is_empty() and bot.position.distance_to(bot.path_goal) > 2.0
				if needs_to_move and sampled_positions.has(bot.index) and bot.position.distance_to(sampled_positions[bot.index]) < 0.3:
					stalled_windows[bot.index] = int(stalled_windows.get(bot.index, 0)) + 1
					worst_stall = maxi(worst_stall, stalled_windows[bot.index])
				else: stalled_windows[bot.index] = 0
				sampled_positions[bot.index] = bot.position
		var travel := 0.0
		var shots := 0
		var friendly_blocks := 0
		var ct_alive := 0
		var t_alive := 0
		for bot in game.bots:
			travel += bot.travel
			shots += bot.shots
			friendly_blocks += bot.friendly_blocks
			if bot.health > 0:
				if bot.team == 0: ct_alive += 1
				else: t_alive += 1
		var valid: bool = game.phase == "OVER" and travel > 150 and shots > 5 and worst_stall < 3
		if not valid: failures += 1
		print("SEEDED_ROUND ", JSON.stringify({"seed": seed, "valid": valid, "seconds": game.elapsed - start, "ct_win": game.ct_score == 1, "ct_alive": ct_alive, "t_alive": t_alive, "travel": travel, "shots": shots, "friendly_blocks": friendly_blocks, "plants": game.objective.plants, "recoveries": game.objective.pickups, "longest_stall_seconds": worst_stall * 2}))
		if not valid:
			for bot in game.bots: print("BOT_DIAGNOSTIC ", bot.index, " ", bot.health, " ", bot.position, " role=", bot.role, " goal=", bot.path_goal, " path=", bot.path.size())
	print("SEEDED_ROUNDS: ", SEEDS.size() - failures, "/", SEEDS.size(), " passed")
	game.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
