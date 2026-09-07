extends SceneTree

const ReferenceHUD = preload("res://tests/fixtures/hud_reference.gd")
# A frozen real game, not synthetic player input or an FPS benchmark. Alternate
# HUD implementations without changing camera, world, state or rendering.
var game: Node3D
var reference: Control
var retained: Control

func _initialize() -> void:
	call_deferred("run")

func freeze(node: Node) -> void:
	node.set_process(false)
	node.set_physics_process(false)
	for child in node.get_children(): freeze(child)

func capture(label: String, candidate: bool) -> void:
	reference.visible = not candidate
	retained.visible = candidate
	for i in 6: await RenderingServer.frame_post_draw
	JavaScriptBridge.eval("window.hudBufferProbe.reset()",true)
	for i in 8: await RenderingServer.frame_post_draw
	var data := {"name":label + ("-retained" if candidate else "-reference"),
		"frames":8,"render":game.render_budget.details(game.get_viewport()),
		"canvas_size":JSON.parse_string(JavaScriptBridge.eval("JSON.stringify([document.getElementById('canvas').width,document.getElementById('canvas').height])",true)),
		"buffers":JSON.parse_string(JavaScriptBridge.eval("JSON.stringify(window.hudBufferProbe.snapshot())",true)),
		"png":Marshalls.raw_to_base64(root.get_texture().get_image().save_png_to_buffer())}
	JavaScriptBridge.eval("window.mapReviewCaptures.push(" + JSON.stringify(data) + ")",true)
	print("HUD_CAPTURE ",data.name)

func run() -> void:
	root.size = Vector2i(960,540)
	game = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	freeze(game)
	retained = game.hud
	retained.set_process(true)
	reference = ReferenceHUD.new()
	reference.game = game
	retained.get_parent().add_child(reference)
	retained.visible = false
	game.elapsed = 50
	game.paused = false
	game.buy_open = false
	game.phase = "BUY"
	game.phase_left = 6
	for label in ["buy","live","damage","spectator","scoreboard","pause","resized"]:
		match label:
			"live":
				game.phase = "LIVE"
				game.phase_left = 90
				game.player.position = Vector3(-5,0,-30)
				game.player.rotation.y = 1.25
			"damage":
				game.damage_flash = 0.7
				game.hit_flash = 0.5
			"spectator":
				game.player.health = 0
				game.spectator.select_target()
				game.spectator.camera.transform = game.player.camera.global_transform
				game.spectator.target.position = Vector3(-7,0,-32)
			"scoreboard": Input.action_press("scoreboard")
			"pause": game.paused = true
			"resized":
				# Policy 0 gives this fixture ownership of the browser canvas size.
				JavaScriptBridge.eval("document.getElementById('canvas').width=1280;document.getElementById('canvas').height=720",true)
				root.size = Vector2i(1280,720)
		for hud in [reference,retained]: hud.sync_menu()
		await capture(label,false)
		await capture(label,true)
	Input.action_release("scoreboard")
	print("HUD_REVIEW_OK")
	JavaScriptBridge.eval("window.mapReviewComplete = true",true)
