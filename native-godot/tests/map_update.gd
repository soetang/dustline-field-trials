extends SceneTree

const Layout = preload("res://scripts/layout.gd")
var game: Node3D
var passed := 0
var failed := 0

func check(ok: bool, label: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("FAIL: ",label)

func _initialize() -> void:
	call_deferred("run")

func ray(a: Vector3,b: Vector3) -> Dictionary:
	return game.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(a,b,1))

func clear_capsule(at: Vector3) -> bool:
	var query := PhysicsShapeQueryParameters3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.32
	capsule.height = 1.8
	query.shape = capsule
	query.transform.origin = Layout.on_floor(at) + Vector3.UP * 0.94
	query.collision_mask = 1
	return game.get_world_3d().direct_space_state.intersect_shape(query).is_empty()

func run() -> void:
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	for i in 3: await physics_frame
	var ceiling := ray(Layout.CT_SPAWN+Vector3.UP*1.65,Layout.CT_SPAWN+Vector3.UP*12)
	check(not ceiling.is_empty() and ceiling.collider.name == "CTUndercroftCeiling","CT spawn is physically under a building")
	check(not ceiling.is_empty() and ceiling.position.y > 3.5,"CT spawn has standing and jumping headroom")
	var ramp_clear := true
	for x in range(1,15): ramp_clear = ramp_clear and clear_capsule(Vector3(x,-0.0,-33))
	check(ramp_clear,"Standing capsule clears roof over the elevated A exit")
	check(not game.world.get_node("CTUndercroftSign").double_sided,"Mounted CT sign is not mirrored across the spawn exit")
	for route in [[Vector3(1.5,0,-24),Vector3(1.5,0,-17)], [Vector3(28.5,0,13),Vector3(28.5,0,21)]]:
		check(game.layout.segment_clear(route[0],route[1]),"Door gap remains navigable with bot clearance")
		var physical := true
		for i in 41: physical = physical and clear_capsule(route[0].lerp(route[1],i/40.0))
		check(physical,"Standing player capsule passes the narrow door gap")
		check(ray(Layout.on_floor(route[0])+Vector3.UP*1.4,Layout.on_floor(route[1])+Vector3.UP*1.4).is_empty(),"Narrow gap admits a real sight/shot ray")
	for i in Layout.DOORS.size():
		var door: Dictionary = Layout.DOORS[i]
		var frame: Node3D = game.world.get_node("DoorLeaf%d" % i)
		var middle := Vector3(door.side*door.width*0.5,1.4,0)
		check(not ray(frame.to_global(middle+Vector3.FORWARD),frame.to_global(middle+Vector3.BACK)).is_empty(),"Door leaf %d blocks real shots" % i)
		var rect := Layout.door_rect(door)
		var corners := Layout.door_corners(door)
		var matched := true
		var local := [rect.position,Vector2(rect.end.x,rect.position.y),rect.end,Vector2(rect.position.x,rect.end.y)]
		for j in 4:
			var world := frame.to_global(Vector3(local[j].x,0,local[j].y))
			matched = matched and Vector2(world.x,world.z).distance_to(corners[j]) < 0.0001
		check(matched,"Door leaf %d visual/collision/radar corners agree" % i)
		var center := frame.to_global(middle)
		check(not Layout.clear(Vector2(center.x,center.z)),"Door leaf %d also blocks navigation" % i)
		var grounded := true
		for j in 9:
			var bottom := frame.to_global(Vector3(door.side*door.width*j/8.0,0,0))
			grounded = grounded and bottom.y <= Layout.floor_height(Vector2(bottom.x,bottom.z))+0.02
		check(grounded,"Door leaf %d does not float above the sloped floor" % i)
	print("MAP_UPDATE: %d/%d passed" % [passed,passed+failed])
	game.queue_free()
	await process_frame
	quit(1 if failed else 0)
