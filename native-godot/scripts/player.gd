class_name FieldPlayer
extends CharacterBody3D

const Weapons = preload("res://scripts/weapons.gd")
const Models = preload("res://scripts/models.gd")
var game: Node3D
var team := 0
var health := 100.0
var armor := 100.0
var slot := 0
var ammo := 30
var reserve := 90
var cooldown := 0.0
var reload_left := 0.0
var heat := 0.0
var recoil := Vector2.ZERO
var pitch := 0.0
var aimed := false
var crouched := false
var shot_count := 0
var step_clock := 0.0
var flash_left := 0.0
var head: Node3D
var camera: Camera3D
var held: Node3D
var gun: Node3D
var muzzle: OmniLight3D
var capsule: CapsuleShape3D
var collision: CollisionShape3D
var sensitivity := 0.0018
var pending_fire := false

func _ready() -> void:
	collision_layer = 2
	collision_mask = 1
	floor_snap_length = 0.4
	floor_max_angle = deg_to_rad(48)
	capsule = CapsuleShape3D.new()
	capsule.radius = 0.32
	capsule.height = 1.8
	collision = CollisionShape3D.new()
	collision.shape = capsule
	collision.position.y = 0.9
	add_child(collision)
	head = Node3D.new()
	head.position.y = 1.62
	add_child(head)
	camera = Camera3D.new()
	camera.fov = 80.0
	camera.near = 0.045
	camera.far = 200.0
	camera.current = true
	head.add_child(camera)
	held = Node3D.new()
	held.position = Vector3(0.24, -0.25, -0.55)
	held.scale = Vector3.ONE * 0.54
	camera.add_child(held)
	muzzle = OmniLight3D.new()
	muzzle.light_color = Color("ffd593")
	muzzle.omni_range = 5.0
	muzzle.position = Vector3(0.24, -0.2, -1.1)
	muzzle.visible = false
	camera.add_child(muzzle)
	equip(0)

func equip(index: int) -> void:
	slot = index
	ammo = Weapons.SPECS[slot].mag
	reserve = ammo * 3
	reload_left = 0.0
	cooldown = 0.2
	heat = 0.0
	recoil = Vector2.ZERO
	pending_fire = false
	if is_instance_valid(gun):
		held.remove_child(gun)
		gun.queue_free()
	var scene: PackedScene = Models.ASSETS["view_" + str(Weapons.SPECS[slot].model)]
	gun = scene.instantiate()
	held.add_child(gun)
	Models.prepare(gun, true)

func _unhandled_input(event: InputEvent) -> void:
	if game.paused or health <= 0: return
	if event is InputEventMouseMotion and game.has_gameplay_input():
		rotation.y -= event.relative.x * sensitivity
		pitch = clampf(pitch - event.relative.y * sensitivity, -1.48, 1.48)
	if event.is_action_pressed("reload"): reload_weapon()
	if event.is_action_pressed("fire"): pending_fire = true

func _physics_process(dt: float) -> void:
	if game.paused: return
	var fire_edge := pending_fire or Input.is_action_just_pressed("fire")
	pending_fire = false
	cooldown = maxf(0.0, cooldown - dt)
	heat = maxf(0.0, heat - dt * 4.8)
	recoil = recoil.lerp(Vector2.ZERO, 1.0 - exp(-dt * 6.5))
	if reload_left > 0:
		reload_left = maxf(0.0, reload_left - dt)
		if reload_left == 0.0:
			var amount := mini(int(Weapons.SPECS[slot].mag) - ammo, reserve)
			ammo += amount
			reserve -= amount
	if health <= 0:
		head.position.y = lerpf(head.position.y, 0.55, dt * 4)
		return
	aimed = Input.is_action_pressed("aim")
	crouched = Input.is_action_pressed("crouch")
	capsule.height = 1.25 if crouched else 1.8
	collision.position.y = capsule.height * 0.5
	head.position.y = lerpf(head.position.y, 1.10 if crouched else 1.62, 1.0 - exp(-dt * 15))
	var desired := Input.get_vector("left", "right", "forward", "back")
	var direction := global_basis * Vector3(desired.x, 0, desired.y)
	var speed: float = 5.0 * float(Weapons.SPECS[slot].speed)
	if Input.is_action_pressed("walk"): speed *= 0.52
	if crouched: speed *= 0.44
	if game.phase != "LIVE" or game.buy_open: direction = Vector3.ZERO
	var acceleration := 34.0 if is_on_floor() else 7.0
	velocity.x = move_toward(velocity.x, direction.x * speed, acceleration * dt)
	velocity.z = move_toward(velocity.z, direction.z * speed, acceleration * dt)
	if not is_on_floor(): velocity.y -= 16.0 * dt
	elif Input.is_action_just_pressed("jump") and game.phase == "LIVE" and not game.buy_open:
		velocity.y = 5.2
	move_and_slide()
	var flat_speed := Vector2(velocity.x, velocity.z).length()
	step_clock += flat_speed * dt
	if flat_speed > 2.6 and is_on_floor() and step_clock > 2.3:
		step_clock = 0
		game.sound.play("step", -12, randf_range(0.92, 1.06))
	camera.rotation = Vector3(pitch + recoil.x, recoil.y, 0)
	if Weapons.wants_fire(slot, Input.is_action_pressed("fire"), fire_edge) and game.phase == "LIVE" and game.has_gameplay_input():
		fire()
	if Input.is_action_pressed("interact") and game.phase == "LIVE": game.defuse(self, dt)

func _process(dt: float) -> void:
	if game.paused: return
	camera.rotation = Vector3(pitch + recoil.x, recoil.y, 0)
	camera.fov = lerpf(camera.fov, (30.0 if slot == 2 else 62.0) if aimed else 80.0, 1.0 - exp(-dt * 12))
	var moving := Vector2(velocity.x, velocity.z).length()
	var bob := sin(Time.get_ticks_msec() * 0.009) * minf(moving * 0.0017, 0.009)
	held.position = Vector3(0.08 if aimed else 0.24, (-0.19 if aimed else -0.25) + bob, -0.55 + recoil.x * 2.1)
	held.rotation = Vector3(recoil.x * 0.6, 0, sin(reload_left * 4.0) * 0.28 if reload_left > 0 else 0.0)
	held.position.y -= sin(clampf(reload_left / float(Weapons.SPECS[slot].reload), 0, 1) * PI) * 0.28
	held.visible = not (slot == 2 and aimed) and health > 0
	flash_left = maxf(0.0, flash_left - dt)
	muzzle.visible = flash_left > 0

func fire() -> bool:
	if cooldown > 0 or reload_left > 0 or health <= 0 or ammo <= 0 or game.phase != "LIVE":
		return false
	if game.bomb_active and game.defuser == self and game.defuse_progress > 0: return false
	var spec: Dictionary = Weapons.SPECS[slot]
	ammo -= 1
	shot_count += 1
	cooldown = spec.interval
	var speed := Vector2(velocity.x, velocity.z).length()
	var spread := Weapons.spread(slot, speed, not is_on_floor(), aimed, crouched, heat)
	game.fire_shot(self, camera.global_position, -camera.global_basis.z, slot, spread)
	recoil += Weapons.kick(slot, int(heat) + 1)
	heat += 1.0
	flash_left = 0.035
	muzzle.light_energy = 2.4
	game.sound.play(spec.model)
	return true

func reload_weapon() -> bool:
	if ammo >= int(Weapons.SPECS[slot].mag) or reserve <= 0 or reload_left > 0 or health <= 0: return false
	reload_left = Weapons.SPECS[slot].reload
	game.sound.play("reload", -2)
	return true

func take_hit(damage: float, attacker: Node3D) -> void:
	if health <= 0: return
	health = maxf(0, health - damage)
	game.damage_flash = 0.35
	game.sound.play("hit", -2)
	if health <= 0:
		collision_layer = 0
		game.killed(self, attacker)

func reset_at(at: Vector3) -> void:
	position = at + Vector3.UP * 0.06
	velocity = Vector3.ZERO
	health = 100.0
	collision_layer = 2
	pitch = 0
	rotation.y = PI
	head.position.y = 1.62
	equip(slot)
