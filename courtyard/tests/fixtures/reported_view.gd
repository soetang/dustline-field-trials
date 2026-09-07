extends RefCounted

## Test-only camera/workload reconstruction. Bot locations were not in the
## report: keep the benchmark's deterministic staging, not a claimed replay.
var report: Dictionary
var sleepers: Array = []
var sleeping_updates := 0
var initial_clocks: Array[float] = []
var initial_poses: Array = []

func configure(game: Node3D, camera: Camera3D, data: Dictionary) -> void:
	report = data
	var lens: Dictionary = report.camera
	var columns: Array = lens.basis
	camera.transform = Transform3D(Basis(vector(columns[0]), vector(columns[1]), vector(columns[2])), vector(lens.position_xyz))
	camera.fov = lens.fov_degrees
	camera.near = lens.near
	camera.far = lens.far
	camera.keep_aspect = lens.keep_aspect
	camera.make_current()
	for bot in game.bots:
		bot.health = 100 if bot.index < report.operators.alive else 0
		bot.velocity = Vector3.ZERO
		bot.reload_left = 0
		bot.look_goal = bot.eye() - bot.global_basis.z * 10
		if bot.health <= 0: sleepers.append(bot)
	# No process/physics frames run while temporarily unpaused. Only invoke
	# production animation, including its native corpse-sleep gate and queries.
	for frame in 180: animate(game)
	for bot in sleepers:
		assert(bot.rig.corpse_sleeping, "Reported-view corpse did not settle")
		bot.rig.skeleton.skeleton_updated.connect(_sleeping_updated)
		initial_clocks.append(bot.rig.clock)
		initial_poses.append(bot.rig.pose.duplicate())

static func vector(values: Array) -> Vector3:
	return Vector3(values[0], values[1], values[2])

func animate(game: Node3D) -> void:
	var paused: bool = game.paused
	game.paused = false
	for bot in game.bots: bot.rig.animate(1.0 / 60.0, bot)
	game.paused = paused

func _sleeping_updated() -> void:
	sleeping_updates += 1

func start_measurement() -> void:
	# Deferred skin updates from setup/warmup are outside measurement.
	sleeping_updates = 0

func details(game: Node3D) -> Dictionary:
	var unchanged := true
	for i in sleepers.size():
		var rig = sleepers[i].rig
		unchanged = unchanged and rig.clock == initial_clocks[i] and rig.pose == initial_poses[i]
	return {"source_build": report.build, "camera": game.camera_details(),
		"reported_operators": report.operators, "operators": game.operator_details(),
		"sleeping_skeleton_updates": sleeping_updates, "sleeping_poses_unchanged": unchanged,
		"limitations": "staged operator positions; no AI, audio, effects, HUD or first-person weapon; not a match replay"}
