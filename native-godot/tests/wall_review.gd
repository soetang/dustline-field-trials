extends SceneTree

const FootPlacement = preload("res://scripts/foot_placement.gd")
# Staged visual inspection, not gameplay or a performance benchmark. No host
# input: the browser runner rejects pointer capture and all input commands.
var game: Node3D
var camera := Camera3D.new()
var actor: Node3D
var resolution := Vector2i(960,441)
var report_position := Vector3(-7.674188,0.000625,-33.478039)

func _initialize() -> void:
	call_deferred("run")

func place(bot: Node3D, at: Vector3, yaw: float) -> void:
	for other in game.bots: other.visible = false
	actor = bot
	actor.position = game.Layout.on_floor(at)
	actor.rotation.y = yaw
	actor.velocity = Vector3.ZERO
	actor.rig.clock = 0
	actor.rig.phase = 0
	actor.rig.grounding = FootPlacement.new()
	actor.rig.weapon_clearance.amount = 0
	actor.visible = true

func capture(name: String, at: Vector3, target: Vector3, first_person: bool = false) -> void:
	game.player.visible = first_person
	if first_person:
		game.player.camera.current = true
	else:
		camera.position = at
		camera.look_at(target)
		camera.current = true
	# Let skinning, shadows and SSAO settle before the readback. No physics/AI
	# simulation, input injection or frame-time interpretation in this fixture.
	for i in 24:
		if is_instance_valid(actor) and actor.visible:
			actor.rig.update_pose(1.0/60,Vector3.ZERO,Vector2.ZERO,0,false,false,0,actor.global_transform,game.Layout.floor_height,game.get_world_3d().direct_space_state)
		if first_person: game.player.update_weapon_pose(1.0/60)
		await RenderingServer.frame_post_draw
	var subject: Node3D = game.player if first_person else actor
	var data := {"name":name,"fixture":"staged wall/weapon inspection; no player input or live AI", "build":game.BUILD,
		"weapon_clear":subject.weapon_clearance.clear if first_person else subject.rig.weapon_clearance.clear,
		"weapon_withdrawal":subject.weapon_clearance.amount if first_person else subject.rig.weapon_clearance.amount,
		"render":game.render_budget.details(game.get_viewport()),
		"actor_position":[subject.position.x,subject.position.y,subject.position.z],"actor_yaw":subject.rotation.y,
		"png":Marshalls.raw_to_base64(root.get_texture().get_image().save_png_to_buffer())}
	JavaScriptBridge.eval("window.mapReviewCaptures.push("+JSON.stringify(data)+")",true)
	print("WALL_CAPTURE ",name)

func run() -> void:
	root.size = resolution
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	game.hud.visible = false
	game.player.visible = false
	game.add_child(camera)
	camera.fov = 62
	camera.near = 0.045
	camera.far = 200
	var ct: Node3D
	var attacker: Node3D
	for bot in game.bots:
		bot.visible = false
		if bot.team == 0 and ct == null: ct = bot
		if bot.team == 1 and attacker == null: attacker = bot
	place(ct,Vector3(-6.1,0,-33.478039),PI/2)
	await capture("ct-clear",Vector3(-3.9,1.7,-31.0),Vector3(-6.3,1.15,-33.478039))
	for entry in [["ct",ct],["t",attacker]]:
		for angle in [["zero",0.0],["thirty",30.0],["sixty",60.0],["ninety",90.0]]:
			place(entry[1],report_position,PI/2+deg_to_rad(angle[1]))
			await capture(entry[0]+"-angle-"+angle[0],Vector3(-5.45,1.65,-31.1),Vector3(-7.6,1.05,-33.5))
	# Thin mid-door leaf: inspect both sides so a weapon that goes through the
	# wood cannot hide solely behind normal depth testing from the owner's side.
	var door: Dictionary = game.Layout.DOORS[2]
	var hinge: Vector2 = door.hinge
	var center := Vector2(door.side*door.width*0.5,0)
	var normal := Vector2.DOWN.rotated(-float(door.yaw))
	var contact := hinge + center.rotated(-float(door.yaw)) + normal*0.476
	place(attacker,Vector3(contact.x,0,contact.y),float(door.yaw))
	var focus := actor.position+Vector3.UP*1.15
	var outward := Vector3(normal.x,0,normal.y)
	var tangent := Vector3(outward.z,0,-outward.x)
	await capture("door-near",focus+outward*2.8+tangent*1.3+Vector3.UP*0.25,focus)
	await capture("door-far",focus-outward*2.8+tangent*0.5+Vector3.UP*0.20,focus)
	for bot in game.bots: bot.visible = false
	game.player.position = report_position
	game.player.rotation.y = 1.5849597454071
	game.player.pitch = -0.0666382837057114
	game.player.head.position.y = 1.62
	game.player.camera.rotation = Vector3(game.player.pitch,0,0)
	game.player.equip(1)
	await capture("player-reported",Vector3.ZERO,Vector3.ZERO,true)
	print("WALL_REVIEW_OK")
	JavaScriptBridge.eval("window.mapReviewComplete = true",true)
