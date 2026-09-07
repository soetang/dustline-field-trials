class_name FieldBot
extends CharacterBody3D

const Layout = preload("res://scripts/layout.gd")
const Weapons = preload("res://scripts/weapons.gd")
const Models = preload("res://scripts/models.gd")
const Aim = preload("res://scripts/bot_aim.gd")
const OperatorRig = preload("res://scripts/operator_rig.gd")
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
var contact_age := 0.0
var burst_shots := 0
var higher_aim := false
var aim_sample := 0.0
var tracking_sample := 0.0
var target: Node3D
var last_seen := Vector3.ZERO
var memory := 0.0
var heard := 0.0
var path := PackedVector3Array()
var path_goal := Vector3(999, 0, 999)
var mission := Vector3.ZERO
var look_goal := Vector3.ZERO
var guard_look := Vector3.ZERO
var role := "ATTACK"
var route: Array[Vector3] = []
var stuck_time := 0.0
var progress_at := Vector3.ZERO
var progress_left := 0.4
var travel := 0.0
var shots := 0
var step_clock := 0.0
var blocked_fire := 0.0
var friendly_blocks := 0
var replans := 0
var model: Node3D
var rig := OperatorRig.new()
var rng := RandomNumberGenerator.new()

func _ready() -> void:
	rng.seed = game.match_seed + game.round_number * 800 + index * 917
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
	add_child(model)
	Models.prepare(model)
	rig.setup(model)
	rig.clock = index * 0.73
	rig.grounding.next_foot = index % 2
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
		guard_look = look_goal
		role = "ANCHOR"

func eye() -> Vector3:
	return global_position + Vector3.UP * 1.52

func _process(dt: float) -> void:
	rig.animate(dt, self)

func see(other: Node3D) -> bool:
	if other.health <= 0 or other.team == team: return false
	var height := 0.86 if other == game.player and game.player.crouched else 1.30
	var seen_at: Vector3 = other.global_position + Vector3.UP * height
	var delta: Vector3 = seen_at - eye()
	if delta.length() > 58: return false
	var facing := -global_basis.z
	if delta.length() > 7 and facing.dot(delta.normalized()) < 0.22: return false
	var query := PhysicsRayQueryParameters3D.create(eye(), seen_at, 1)
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
		if target != candidate:
			reaction = rng.randf_range(0.28, 0.54)
			contact_age = 0
			higher_aim = false
		target = candidate
		last_seen = candidate.global_position
		memory = 2.2
		look_goal = last_seen + Vector3.UP * 1.3
		game.objective.report_contact(self, last_seen)
	else:
		target = null
		contact_age = 0
		higher_aim = false
	if memory > 0 or heard > 0:
		look_goal = last_seen + Vector3.UP * 1.3
	if not game.bomb_active and team == 1 and not route.is_empty():
		if Vector2(position.x, position.z).distance_to(Vector2(mission.x, mission.z)) < 1.5:
			route.pop_front()
		if not route.is_empty(): mission = Layout.on_floor(route[0])
	var job: Dictionary = game.objective.assignment(self)
	role = str(job.role) if not job.is_empty() else ("CARRIER" if game.objective.carrier == self else ("ANCHOR" if team == 0 else "ATTACK"))
	var destination: Vector3 = job.goal if not job.is_empty() else mission
	if not job.is_empty(): guard_look = job.look
	var committed_defuse: bool = role == "DEFUSE" and (target == null or position.distance_to(last_seen) > 5.0 or game.bomb_left < 9.0)
	if (memory > 0 or heard > 0) and not committed_defuse:
		destination = last_seen
		if target != null and position.distance_to(last_seen) < 30:
			# Short, checked strafes from cover; never continue driving into a wall.
			var side := global_basis.x * (1.0 if (index + int(game.elapsed / 2.4)) % 2 == 0 else -1.0)
			var strafe := position + side * 1.1
			destination = strafe if game.layout.segment_clear(position, strafe) else position
			if health < 32:
				var retreat := position + (position - last_seen).normalized() * 4
				if game.layout.segment_clear(position, retreat): destination = retreat
	# A covering bot responds locally; it does not abandon the device to chase
	# an old contact across the map. Attack routes resume when memory expires.
	if role in ["COVER", "HOLD"] and target == null:
		destination = job.goal
	if destination.distance_to(path_goal) > 0.7 or stuck_time > 0.7:
		path = game.layout.path(position, destination)
		path_goal = destination
		stuck_time = 0.0
		replans += 1
	if target == null and memory <= 0 and heard <= 0 and not path.is_empty():
		look_goal = path[mini(3, path.size() - 1)] + Vector3.UP * 1.4
	elif target == null and memory <= 0 and heard <= 0 and (team == 0 or game.bomb_active):
		look_goal = guard_look

func _physics_process(dt: float) -> void:
	if game.paused or health <= 0 or game.phase != "LIVE": return
	cooldown = maxf(0, cooldown - dt)
	reaction = maxf(0, reaction - dt)
	burst_pause = maxf(0, burst_pause - dt)
	blocked_fire = maxf(0, blocked_fire - dt)
	memory = maxf(0, memory - dt)
	heard = maxf(0, heard - dt)
	if reload_left > 0:
		reload_left = maxf(0, reload_left - dt)
		if reload_left == 0: ammo = Weapons.SPECS[slot].mag
	think_left -= dt
	if think_left <= 0:
		think_left = 0.16 + rng.randf() * 0.04
		think()
	if is_instance_valid(target): contact_age += dt
	var facing := look_goal - eye()
	if facing.length_squared() > 0.01:
		var desired_yaw := atan2(-facing.x, -facing.z)
		if target == null and path.is_empty(): desired_yaw += sin(game.elapsed * 0.75 + index) * 0.42
		rotation.y = lerp_angle(rotation.y, desired_yaw, 1.0 - exp(-dt * 8.0))
	# Pop all reached waypoints before movement: no lost frame at each grid cell.
	while not path.is_empty() and Vector2(position.x - path[0].x, position.z - path[0].z).length() < 0.25:
		path.remove_at(0)
	var shortcut_clear: bool = path.size() > 1 and game.layout.segment_clear(position, path[1])
	if shortcut_clear: path.remove_at(0)
	# A successful shortcut just checked this exact position -> new path[0].
	if not shortcut_clear and not path.is_empty() and not game.layout.segment_clear(position, path[0]):
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
	var working_defuse: bool = role == "DEFUSE" and game.bomb_active and position.distance_to(game.bomb_at) < 1.8 and (target == null or position.distance_to(last_seen) > 5.0 or game.bomb_left < 9.0)
	var working_plant: bool = game.objective.carrier == self and not game.bomb_active and route.is_empty() and position.distance_to(mission) < 2.0 and target == null
	if working_defuse or working_plant:
		desired = Vector3.ZERO
	elif target != null and reaction <= 0 and burst_pause <= 0 and reload_left <= 0 and blocked_fire <= 0:
		# Settle for a burst, then move during its pause instead of spraying while
		# continuously shuffling. Friendly fire obstructions force a new peek.
		desired = Vector3.ZERO
	velocity.x = desired.x * speed
	velocity.z = desired.z * speed
	if not is_on_floor(): velocity.y -= 16 * dt
	var before := position
	move_and_slide()
	if working_defuse: game.defuse(self, dt)
	elif working_plant: game.objective.try_plant(self, dt)
	travel += position.distance_to(before)
	step_clock += Vector2(position.x - before.x, position.z - before.z).length()
	if step_clock > 2.3 and is_on_floor():
		step_clock = 0
		game.sound.play_at("step", position + Vector3.UP * 0.2, -5, 0.96 + (index % 3) * 0.03)
	progress_left -= dt
	if progress_left <= 0:
		if desired.length_squared() > 0.1 and position.distance_to(progress_at) < 0.35: stuck_time += 0.4
		else: stuck_time = 0
		progress_at = position
		progress_left = 0.4
	if not working_defuse and not working_plant and is_instance_valid(target) and target.health > 0 and reaction <= 0 and cooldown <= 0 and burst_pause <= 0 and reload_left <= 0:
		if see(target):
			_shoot_visible_target()
		else:
			# A brief cover break can fall between think() scans. Drop precision
			# here too, so the first re-peek cannot inherit settled higher aim.
			contact_age = 0
			higher_aim = false

func shoot() -> bool:
	if not is_instance_valid(target) or target.health <= 0 or health <= 0 or game.phase != "LIVE" or cooldown > 0 or reload_left > 0: return false
	if not see(target):
		contact_age = 0
		higher_aim = false
		return false
	return _shoot_visible_target()

func _shoot_visible_target() -> bool:
	# Internal continuation only: both callers validate the live shot state and
	# LOS immediately above. Never reuse sight across movement or physics ticks.
	if ammo <= 0:
		reload_left = Weapons.SPECS[slot].reload
		return false
	var shooter_speed := Vector2(velocity.x, velocity.z).length()
	var target_speed := Vector2(target.velocity.x, target.velocity.z).length()
	var distance := global_position.distance_to(target.global_position)
	if burst_shots == 0:
		# One intent per burst: mostly center mass, occasionally a deliberate
		# higher shot at a settled, continuously visible and slow-moving target.
		higher_aim = Aim.higher_aim_allowed(contact_age, shooter_speed, target_speed, distance) and rng.randf() < 0.08
		aim_sample = rng.randf_range(-1, 1)
		tracking_sample = rng.randf_range(-1, 1)
	var precise := higher_aim and Aim.higher_aim_allowed(contact_age, shooter_speed, target_speed, distance)
	var crouched: bool = target == game.player and game.player.crouched
	var aim := Aim.aim_point(eye(),target.global_position,crouched,precise,aim_sample)
	var lateral: Vector3 = (aim - eye()).cross(Vector3.UP).normalized()
	aim += lateral * Aim.lateral_error(contact_age, target_speed, distance, tracking_sample)
	var direction := (aim - eye()).normalized()
	if (-global_basis.z).dot(Vector3(direction.x, 0, direction.z).normalized()) < 0.94: return false
	var query := PhysicsRayQueryParameters3D.create(eye(), aim, 7, [get_rid()])
	var first_hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not first_hit.is_empty() and first_hit.collider.has_method("take_hit") and first_hit.collider.team == team:
		blocked_fire = 0.45
		cooldown = 0.08
		friendly_blocks += 1
		think_left = 0
		return false
	blocked_fire = 0
	game.fire_shot(self, eye(), direction, slot, Aim.spread(slot, contact_age, shooter_speed, burst_shots), Aim.vertical_scale(precise))
	shots += 1
	ammo -= 1
	cooldown = Weapons.SPECS[slot].interval
	burst_left -= 1
	burst_shots += 1
	if burst_left <= 0:
		burst_shots = 0
		burst_left = rng.randi_range(2, 4)
		burst_pause = rng.randf_range(0.28, 0.65)
	game.sound.play_at(Weapons.SPECS[slot].model, eye(), 0, 0.97)
	rig.on_shot()
	return true

func take_hit(damage: float, attacker: Node3D, headshot: bool = false) -> void:
	if health <= 0: return
	game.combat.record(self, attacker, damage)
	health = maxf(0, health - damage)
	hear(attacker.position)
	if health <= 0:
		collision_layer = 0
		velocity = Vector3.ZERO
		game.killed(self, attacker, headshot)
