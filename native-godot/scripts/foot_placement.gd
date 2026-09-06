class_name FieldFootPlacement
extends RefCounted

## Small world-space stance cache. Terrain sampling is a height function, not
## a physics ray. Idle turns alternate feet instead of rotating both soles.
var initialized := false
var walking := false
var feet: Array[Transform3D] = []
var planted: Array[Transform3D] = []
var was_stance: Array[bool] = [false, false]
var turn_foot := -1
var turn_progress := 0.0
var turn_start := Transform3D.IDENTITY
var turn_goal := Transform3D.IDENTITY
var next_foot := 0
var stance: Array[bool] = [true, true]

static func ground_target(body: Transform3D, foot: Transform3D, rest: Transform3D, height: Callable) -> Transform3D:
	var ground := body * Vector3(foot.origin.x, 0, foot.origin.z)
	ground.y = height.call(Vector2(ground.x, ground.z))
	var p := Vector2(ground.x, ground.z)
	var normal := Vector3(
		float(height.call(p - Vector2(0.08,0))) - float(height.call(p + Vector2(0.08,0))),
		0.16,
		float(height.call(p - Vector2(0,0.08))) - float(height.call(p + Vector2(0,0.08)))
	).normalized()
	var align := Basis(Quaternion(Vector3.UP, normal))
	return Transform3D(align * body.basis * foot.basis,
		ground + normal * rest.origin.y + Vector3.UP * maxf(0, foot.origin.y - rest.origin.y))

func update(dt: float, body: Transform3D, raw: Array[Transform3D], rests: Array[Transform3D], phase: float, speed: float, height: Callable) -> Array[Transform3D]:
	var desired: Array[Transform3D] = []
	var neutral: Array[Transform3D] = []
	for i in 2:
		desired.append(ground_target(body, raw[i], rests[i], height))
		neutral.append(ground_target(body, rests[i], rests[i], height))
	if not initialized:
		feet = neutral.duplicate()
		planted = neutral.duplicate()
		initialized = true
	var moving := speed > 0.18
	if moving:
		turn_foot = -1
		for i in 2:
			var step := fposmod(phase + (0.5 if i == 0 else 0), 1)
			stance[i] = step < 0.46
			if stance[i]:
				if not was_stance[i]: planted[i] = desired[i]
				feet[i] = planted[i]
			else:
				feet[i] = desired[i]
			was_stance[i] = stance[i]
	else:
		# Finish any raised foot when stopping; then take short alternate steps
		# only when the body has turned or moved away from its planted stance.
		if turn_foot < 0:
			for j in 2:
				var i := (next_foot + j) % 2
				var separation := feet[i].origin.distance_to(neutral[i].origin)
				var angle := feet[i].basis.get_rotation_quaternion().angle_to(neutral[i].basis.get_rotation_quaternion())
				if separation > 0.055 or angle > 0.26:
					turn_foot = i
					turn_progress = 0
					turn_start = feet[i]
					turn_goal = neutral[i]
					next_foot = 1 - i
					break
		stance = [true, true]
		if turn_foot >= 0:
			turn_progress = minf(1, turn_progress + dt / 0.18)
			# Adapt the landing point during a continuing turn, not after planting.
			turn_goal = turn_goal.interpolate_with(neutral[turn_foot], 1 - exp(-dt * 20))
			feet[turn_foot] = turn_start.interpolate_with(turn_goal, smoothstep(0,1,turn_progress))
			feet[turn_foot].origin.y += sin(turn_progress * PI) * 0.055
			stance[turn_foot] = turn_progress >= 1
			if turn_progress >= 1:
				planted[turn_foot] = feet[turn_foot]
				turn_foot = -1
		was_stance = stance.duplicate()
	walking = moving
	var local: Array[Transform3D] = []
	var inverse := body.affine_inverse()
	for foot in feet: local.append(inverse * foot)
	return local
