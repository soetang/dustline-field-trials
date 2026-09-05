class_name FieldSpectator
extends Node3D

var game: Node3D
var camera: Camera3D
var target: FieldBot
var active := false
var begin_at := 0.0
var pending_step := 0
var probe := SphereShape3D.new()

func _ready() -> void:
	probe.radius = 0.2
	camera = Camera3D.new()
	camera.fov = 80
	camera.near = 0.045
	camera.far = 200
	add_child(camera)

func reset() -> void:
	if is_instance_valid(target): target.model.visible = true
	target = null
	active = false
	begin_at = 0
	pending_step = 0
	game.player.camera.make_current()

func begin() -> void:
	begin_at = game.elapsed + 1.2
	game.player.pending_fire = false

func candidates() -> Array[FieldBot]:
	var result: Array[FieldBot] = []
	for bot in game.bots:
		if is_instance_valid(bot) and bot.team == game.player.team and bot.health > 0: result.append(bot)
	return result

func cycle(step: int = 1) -> void:
	if game.player.health > 0 or game.paused or not game.has_gameplay_input(): return
	pending_step = step
	begin_at = game.elapsed

func select_target(step: int = 1) -> void:
	var available := candidates()
	var previous := available.find(target)
	if is_instance_valid(target): target.model.visible = true
	target = null if available.is_empty() else available[posmod(previous + step, available.size()) if previous >= 0 else (0 if step > 0 else available.size() - 1)]
	active = target != null
	if active: camera.make_current()
	else: game.player.camera.make_current()

func safe_position(anchor: Vector3, desired: Vector3) -> Vector3:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = probe
	query.collision_mask = 1
	query.margin = 0.025
	query.transform = Transform3D(Basis.IDENTITY, anchor)
	var space := get_world_3d().direct_space_state
	# cast_motion ignores initial overlaps, so explicitly guard the starting volume.
	if not space.intersect_shape(query, 1).is_empty(): return anchor
	query.motion = desired - anchor
	var travel := space.cast_motion(query)
	return anchor + query.motion * maxf(0, travel[0] - 0.015)

func _physics_process(_dt: float) -> void:
	if game.paused: return
	if game.player.health > 0:
		if active or begin_at > 0: reset()
		return
	if pending_step != 0:
		select_target(pending_step)
		pending_step = 0
	elif (not active and game.elapsed >= begin_at) or (active and (not is_instance_valid(target) or target.health <= 0)):
		select_target()
	if not active: return
	var anchor := target.eye()
	var desired := anchor + target.global_basis * Vector3(0.62, 0.65, 2.6)
	camera.global_position = safe_position(anchor, desired)
	var focus := anchor - target.global_basis.z * 8.0
	camera.look_at(focus, Vector3.UP)
	# In a tight corner the camera falls back to eye level; hide only the followed
	# model there. Restore it on cycling, death or round reset.
	target.model.visible = camera.global_position.distance_to(anchor) > 0.8
