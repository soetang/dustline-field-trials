extends SceneTree

const Models = preload("res://scripts/models.gd")
const Rig = preload("res://scripts/operator_rig.gd")
const Layout = preload("res://scripts/layout.gd")
var passed := 0
var failed := 0

func check(ok: bool, label: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var cases := [
		["flat run", Vector3(0,0,0), Vector3(0,0,-4.65), 0.0],
		["up A ramp", Vector3(5.5,0,-29), Vector3(1.5,0,0), 0.0],
		["down A ramp", Vector3(10.5,0,-29), Vector3(-1.5,0,0), 0.0],
		["south slope", Vector3(-9,0,17), Vector3(0,0,2.1), 0.0],
		["turn on slope", Vector3(8,0,-29), Vector3.ZERO, 0.8],
		["flat turn", Vector3.ZERO, Vector3.ZERO, -1.2],
		["start stop turn on slope", Vector3(6,0,-29), Vector3.ZERO, 0.0],
	]
	for entry in cases:
		var model: Node3D = Models.ASSETS.ct_operator.instantiate()
		root.add_child(model)
		var rig := Rig.new()
		rig.setup(model)
		var at: Vector3 = entry[1]
		var velocity: Vector3 = entry[2]
		var yaw := 0.0
		var worst_reach := 0.0
		var worst_slide := 0.0
		var lowest_sole := INF
		var highest_stance := -INF
		var lifted := false
		var worst_at := {}
		var previous: Array[Vector3] = [Vector3.ZERO,Vector3.ZERO]
		var previous_stance: Array[bool] = [false,false]
		for frame in 240:
			var dt := 1.0/60
			var yaw_rate: float = entry[3]
			if entry[0] == "start stop turn on slope":
				velocity = Vector3(1.5,0,0) if frame >= 60 and frame < 120 else Vector3(-1.5,0,0) if frame >= 180 else Vector3.ZERO
				yaw_rate = 0.8 if velocity == Vector3.ZERO else 0.0
			at += velocity * dt
			at.y = Layout.floor_height(Vector2(at.x,at.z))
			yaw += yaw_rate * dt
			var body := Transform3D(Basis(Vector3.UP,yaw),at)
			rig.update_pose(dt,body.basis.inverse()*velocity,Vector2.ZERO,0,false,false,yaw_rate,body,Layout.floor_height)
			for i in 2:
				var foot: int = rig.ids["foot_l" if i==0 else "foot_r"]
				var posed := body * rig.pose[foot]
				var reach := rig.pose[foot].origin.distance_to(rig.foot_targets[i].origin)
				if reach > worst_reach:
					worst_reach = reach
					worst_at = {"frame":frame,"side":i,"phase":rig.phase,"goal":str(rig.foot_targets[i].origin),"hip":str(rig.pose[rig.ids["thigh_l" if i==0 else "thigh_r"]].origin)}
				if frame > 0 and previous_stance[i] and rig.grounding.stance[i]:
					worst_slide = maxf(worst_slide,posed.origin.distance_to(previous[i]))
				previous[i] = posed.origin
				previous_stance[i] = rig.grounding.stance[i]
				lifted = lifted or not rig.grounding.stance[i]
				for x in [-0.073,0.073]:
					for z in [-0.17,0.076]:
						var original := Vector3(rig.rest[foot].origin.x+x,0.003,rig.rest[foot].origin.z+z)
						var sole := posed * rig.rest[foot].affine_inverse() * original
						var above := sole.y-Layout.floor_height(Vector2(sole.x,sole.z))
						lowest_sole = minf(lowest_sole,above)
						if rig.grounding.stance[i]: highest_stance = maxf(highest_stance,above)
		print("FOOT_SAMPLE ",entry[0]," reach=",worst_reach," slide=",worst_slide," sole_min=",lowest_sole," stance_max=",highest_stance)
		if worst_reach > 0.01: print("FOOT_REACH_CASE ",worst_at)
		check(worst_reach < 0.01,entry[0]+" feet stay within leg reach")
		check(worst_slide < 0.015,entry[0]+" planted soles do not slide")
		check(lowest_sole > -0.02,entry[0]+" soles do not sink into terrain")
		check(highest_stance < 0.035,entry[0]+" planted soles touch terrain")
		check(lifted,entry[0]+" feet lift during movement or turns")
		model.queue_free()
		await process_frame
	print("FEET: %d/%d passed" % [passed,passed+failed])
	quit(1 if failed else 0)
