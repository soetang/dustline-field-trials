class_name FieldBot
extends CharacterBody3D

const Layout = preload("res://scripts/layout.gd")
const Weapons = preload("res://scripts/weapons.gd")
const Models = preload("res://scripts/models.gd")
var game: Node3D
var team := 1
var index := 0
var health := 100.0
var slot := 1
var ammo := 30
var cooldown := 0.0
var reload_left := 0.0
var think_left := 0.0
var reaction := 0.0
var burst_left := 3
var burst_pause := 0.0
var target: Node3D
var last_seen := Vector3.ZERO
var memory := 0.0
var heard := 0.0
var path := PackedVector3Array()
var path_goal := Vector3(999, 0, 999)
var mission := Vector3.ZERO
var look_goal := Vector3.ZERO
var route: Array[Vector3] = []
var stuck_time := 0.0
var progress_at := Vector3.ZERO
var progress_left := 0.4
var travel := 0.0
var shots := 0
var plant_progress := 0.0
var model: Node3D
var legs: Array[Node3D] = []
var rng := RandomNumberGenerator.new()

func _ready() -> void:
	rng.seed = 800 + index * 917
	collision_layer = 4
	collision_mask = 1 # Agents separate in steering; they never physically jam doorways.
	floor_snap_length = 0.45
	var collision := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.32
	capsule.height = 1.8
	collision.shape = capsule
	collision.position.y = 0.9
	add_child(collision)
	var packed: PackedScene = Models.ASSETS["ct_operator" if team == 0 else "t_operator"]
	model = packed.instantiate()
	model.position.y = 1.05
	add_child(model)
	Models.prepare(model)
	for node in model.find_children("leg_*", "Node3D", true, false):
		if node.name.begins_with("leg_l") or node.name.begins_with("leg_r"): legs.append(node)
	rotation.y = 0 if team == 1 else PI
	progress_at = position
	think_left = index * 0.018
	set_mission()

func set_mission() -> void:
	if team == 1:
		if index % 3 == 0:
			route = [Vector3(-27, 0, 28), Vector3(-32, 0, 18), Vector3(-32, 0, -10), Layout.SITE_B]
		elif index % 3 == 1:
			route = [Vector3(20, 0, 29), Vector3(28, 0, 18), Vector3(36, 0, 4), Vector3(37, 0, -18), Layout.SITE_A]
		else:
			route = [Vector3(0, 0, 22), Vector3(1, 0, 4), Vector3(14, 0, 0), Vector3(15, 0, -19), Layout.SITE_A]
		mission = Layout.on_floor(route[0])
	else:
		var anchors := [Vector3(-28, 0, -25), Vector3(28, 0, -26), Vector3(1, 0, -19), Vector3(15, 0, -15)]
		mission = Layout.on_floor(anchors[index % 4])
		var lanes := [Vector3(-33, 1.5, -9), Vector3(37, 3.5, -7), Vector3(1, 1.5, 14), Vector3(14, 2.0, 0)]
		look_goal = lanes[index % 4]

func eye() -> Vector3:
	return global_position + Vector3.UP * 1.52

func see(other: Node3D) -> bool:
	if other.health <= 0 or other.team == team: return false
	var delta: Vector3 = other.global_position + Vector3.UP * 1.35 - eye()
	if delta.length() > 58: return false
	var facing := -global_basis.z
	if delta.length() > 7 and facing.dot(delta.normalized()) < 0.22: return false
	var query := PhysicsRayQueryParameters3D.create(eye(), other.global_position + Vector3.UP * 1.3, 1)
	return get_world_3d().direct_space_state.intersect_ray(query).is_empty()

func hear(at: Vector3) -> void:
	if memory <= 0:
		last_seen = at
		heard = 2.0

func think() -> void:
	var closest := INF
	var candidate: Node3D = null
	for other in game.actors():
		if see(other):
			var distance := global_position.distance_squared_to(other.global_position)
			if distance < closest:
				closest = distance
				candidate = other
	if candidate != null:
		if target != candidate: reaction = rng.randf_range(0.28, 0.54)
		target = candidate
		last_seen = candidate.global_position
		memory = 2.2
		look_goal = last_seen + Vector3.UP * 1.3
	else:
		target = null
	if memory > 0 or heard > 0:
		look_goal = last_seen + Vector3.UP * 1.3
	if game.bomb_active:
		mission = game.bomb_at
	elif team == 1 and not route.is_empty():
		if Vector2(position.x, position.z).distance_to(Vector2(mission.x, mission.z)) < 1.5:
			route.pop_front()
		if not route.is_empty(): mission = Layout.on_floor(route[0])
	var destination := mission
	if memory > 0 or heard > 0:
		destination = last_seen
		if target != null and position.distance_to(last_seen) < 30:
			# Short, checked strafes from cover; never continue driving into a wall.
			var side := global_basis.x * (1.0 if (index + int(game.elapsed / 2.4)) % 2 == 0 else -1.0)
			var strafe := position + side * 1.1
			destination = strafe if game.layout.segment_clear(position, strafe) else position
			if health < 32:
				var retreat := position + (position - last_seen).normalized() * 4
				if game.layout.segment_clear(position, retreat): destination = retreat
	if game.bomb_active and team == 1 and position.distance_to(game.bomb_at) < 8 and memory <= 0:
		destination = position # Cover the planted objective; don't stack on top of it.
	if destination.distance_to(path_goal) > 1.5 or stuck_time > 0.7:
		path = game.layout.path(position, destination)
		path_goal = destination
		stuck_time = 0.0
	if target == null and memory <= 0 and heard <= 0 and not path.is_empty():
		look_goal = path[mini(3, path.size() - 1)] + Vector3.UP * 1.4

func _physics_process(dt: float) -> void:
	if game.paused or health <= 0 or game.phase != "LIVE": return
	cooldown = maxf(0, cooldown - dt)
	reaction = maxf(0, reaction - dt)
	burst_pause = maxf(0, burst_pause - dt)
	memory = maxf(0, memory - dt)
	heard = maxf(0, heard - dt)
	if reload_left > 0:
		reload_left = maxf(0, reload_left - dt)
		if reload_left == 0: ammo = Weapons.SPECS[slot].mag
	think_left -= dt
	if think_left <= 0:
		think_left = 0.16 + rng.randf() * 0.04
		think()
	var facing := look_goal - eye()
	if facing.length_squared() > 0.01:
		var desired_yaw := atan2(-facing.x, -facing.z)
		if target == null and path.is_empty(): desired_yaw += sin(game.elapsed * 0.75 + index) * 0.42
		rotation.y = lerp_angle(rotation.y, desired_yaw, 1.0 - exp(-dt * 8.0))
	# Pop all reached waypoints before movement: no lost frame at each grid cell.
	while not path.is_empty() and Vector2(position.x - path[0].x, position.z - path[0].z).length() < 0.25:
		path.remove_at(0)
	if path.size() > 1 and game.layout.segment_clear(position, path[1]): path.remove_at(0)
	if not path.is_empty() and not game.layout.segment_clear(position, path[0]):
		path = game.layout.path(position, path_goal)
	var desired := Vector3.ZERO
	if not path.is_empty():
		desired = path[0] - position
		desired.y = 0
		desired = desired.normalized()
		# Only separate if the modified direction has actual body clearance.
		for other in game.bots:
			if other == self or other.health <= 0: continue
			var away: Vector3 = position - other.position
			away.y = 0
			var distance := away.length()
			if distance > 0.01 and distance < 0.85:
				var steering := (desired + away.normalized() * (0.85 - distance)).normalized()
				if game.layout.segment_clear(position, position + steering * 0.65): desired = steering
	var speed := 4.65 if target == null else 2.1
	if team == 0 and game.bomb_active and position.distance_to(game.bomb_at) < 1.8:
		if game.defuser == null or game.defuser == self:
			desired = Vector3.ZERO
			game.defuse(self, dt)
	if team == 1 and not game.bomb_active and route.is_empty() and position.distance_to(mission) < 2.0:
		desired = Vector3.ZERO
		if target == null: plant_progress += dt
		else: plant_progress = 0
		if plant_progress >= 3.0: game.plant(position)
	velocity.x = desired.x * speed
	velocity.z = desired.z * speed
	if not is_on_floor(): velocity.y -= 16 * dt
	var before := position
	move_and_slide()
	travel += position.distance_to(before)
	progress_left -= dt
	if progress_left <= 0:
		if desired.length_squared() > 0.1 and position.distance_to(progress_at) < 0.35: stuck_time += 0.4
		else: stuck_time = 0
		progress_at = position
		progress_left = 0.4
	for i in legs.size():
		legs[i].rotation.x = sin(game.elapsed * 11.0 + i * PI) * desired.length() * 0.43
	if is_instance_valid(target) and target.health > 0 and reaction <= 0 and cooldown <= 0 and burst_pause <= 0 and reload_left <= 0 and see(target):
		shoot()

func shoot() -> void:
	if ammo <= 0:
		reload_left = Weapons.SPECS[slot].reload
		return
	# Aim is based on a currently visible target; wall hits still stop the ray.
	var aim: Vector3 = target.global_position + Vector3.UP * rng.randf_range(1.05, 1.5)
	var direction := (aim - eye()).normalized()
	if (-global_basis.z).dot(direction) < 0.94: return
	game.fire_shot(self, eye(), direction, slot, deg_to_rad(0.75 + Vector2(velocity.x, velocity.z).length() * 0.23))
	shots += 1
	ammo -= 1
	cooldown = Weapons.SPECS[slot].interval
	burst_left -= 1
	if burst_left <= 0:
		burst_left = rng.randi_range(2, 4)
		burst_pause = rng.randf_range(0.28, 0.65)
	var distance: float = position.distance_to(game.player.position)
	if distance < 55: game.sound.play(Weapons.SPECS[slot].model, -6.0 - distance * 0.35, 0.97)

func take_hit(damage: float, attacker: Node3D) -> void:
	if health <= 0: return
	health = maxf(0, health - damage)
	hear(attacker.position)
	if health <= 0:
		collision_layer = 0
		model.rotation.z = PI * 0.5
		model.position.y = 0.2
		game.killed(self, attacker)
