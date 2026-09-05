class_name FieldOperatorRig
extends RefCounted

var model: Node3D
var upper: Node3D
var head: Node3D
var weapon: Node3D
var hips: Array[Node3D] = []
var knees: Array[Node3D] = []
var upper_rest := Vector3.ZERO
var weapon_rest := Vector3.ZERO
var flash: MeshInstance3D
var shot_left := 0.0
var recoil := 0.0
var fall := 0.0

func setup(root: Node3D) -> void:
	model = root
	upper = root.find_child("upper_body", true, false)
	head = root.find_child("head_aim", true, false)
	weapon = root.find_child("weapon_aim", true, false)
	upper_rest = upper.position
	weapon_rest = weapon.position
	for side in ["l", "r"]:
		hips.append(root.find_child("leg_" + side, true, false))
		knees.append(root.find_child("leg_" + side + "_knee", true, false))
	flash = MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.033
	mesh.height = 0.066
	mesh.radial_segments = 8
	mesh.rings = 4
	flash.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color("ffdc86")
	flash.material_override = material
	flash.scale = Vector3(0.75, 0.75, 2.0)
	flash.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flash.visible = false
	root.find_child("muzzle_socket", true, false).add_child(flash)

func on_shot() -> void:
	shot_left = 0.045
	recoil = 1.0

func animate(dt: float, actor: Node3D) -> void:
	if actor.game.paused: return
	shot_left = maxf(0, shot_left - dt)
	recoil = move_toward(recoil, 0, dt * 10)
	flash.visible = shot_left > 0 and actor.health > 0
	if actor.health <= 0:
		fall = minf(1, fall + dt * 2.8)
		var eased := fall * fall * (3 - 2 * fall)
		model.rotation.z = (1 if actor.index % 2 == 0 else -1) * PI * 0.5 * eased
		model.position.y = 0.24 * eased
		return
	var speed := Vector2(actor.velocity.x, actor.velocity.z).length()
	var amount := minf(speed / 4.65, 1)
	var phase: float = actor.travel * TAU / 2.55
	var blend := 1 - exp(-dt * 16)
	for i in 2:
		var step := phase + i * PI
		hips[i].rotation.x = lerpf(hips[i].rotation.x, sin(step) * 0.52 * amount, blend)
		knees[i].rotation.x = lerpf(knees[i].rotation.x, -maxf(0, cos(step)) * 0.88 * amount, blend)
	upper.position = upper_rest + Vector3.UP * sin(phase * 2) * 0.012 * amount
	var relative: Vector3 = actor.global_basis.inverse() * (actor.look_goal - actor.eye())
	var pitch := clampf(atan2(relative.y, Vector2(relative.x, relative.z).length()), -0.65, 0.65)
	var working: bool = actor.role == "DEFUSE" and actor.game.defuser == actor
	if actor.game.objective.carrier == actor and actor.game.objective.plant_progress > 0: working = true
	upper.rotation.x = lerpf(upper.rotation.x, -0.23 if working else pitch * 0.68 - 0.035, blend)
	head.rotation.x = lerpf(head.rotation.x, pitch * 0.2, blend)
	head.rotation.y = lerp_angle(head.rotation.y, clampf(atan2(-relative.x, -relative.z), -0.6, 0.6) * 0.7, blend)
	weapon.rotation.x = (-0.32 if working or actor.reload_left > 0 else pitch * 0.32 + 0.035) + recoil * 0.045
	weapon.rotation.z = sin(actor.reload_left * 4) * 0.11 if actor.reload_left > 0 else 0
	weapon.position = weapon_rest + Vector3.BACK * recoil * 0.025
