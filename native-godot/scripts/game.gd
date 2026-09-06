extends Node3D

const Layout = preload("res://scripts/layout.gd")
const World = preload("res://scripts/world.gd")
const Player = preload("res://scripts/player.gd")
const Bot = preload("res://scripts/bot.gd")
const Weapons = preload("res://scripts/weapons.gd")
const Sound = preload("res://scripts/sound.gd")
const HUD = preload("res://scripts/hud.gd")
const Objective = preload("res://scripts/objective.gd")
const Combat = preload("res://scripts/combat.gd")
const Spectator = preload("res://scripts/spectator.gd")
const Browser = preload("res://scripts/browser.gd")
const BUILD := "courtyard-0.4.1-undercroft"
var match_seed := 512
var layout := Layout.new()
var world: FieldWorld
var player: FieldPlayer
var sound: FieldSound
var hud: Control
var objective: FieldObjective
var combat := Combat.new()
var spectator: FieldSpectator
var browser: FieldBrowser
var bots: Array[FieldBot] = []
var paused := true
var buy_open := false
var phase := "BUY"
var phase_left := 7.0
var round_number := 0
var ct_score := 0
var t_score := 0
var money := 3400
var elapsed := 0.0
var kills := 0
var deaths := 0
var hits := 0
var damage_flash := 0.0
var hit_flash := 0.0
var banner := "WELCOME TO COURTYARD"
var banner_left := 0.0
var bomb_active := false
var bomb_at := Vector3.ZERO
var bomb_left := 35.0
var bomb_mesh: Node3D
var defuser: Node3D
var defuse_progress := 0.0
var defuse_last := 0.0
var bomb_beep := 0.0
var kill_feed: Array[Dictionary] = []
var effects: Array[Node3D] = []
var rng := RandomNumberGenerator.new()
var diagnostics := false
var silent_test := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--seed="): match_seed = argument.trim_prefix("--seed=").to_int()
	rng.seed = match_seed
	configure_input()
	world = World.new()
	add_child(world)
	sound = Sound.new()
	sound.game = self
	add_child(sound)
	silent_test = "--test" in OS.get_cmdline_user_args()
	sound.muted = silent_test
	player = Player.new()
	player.game = self
	add_child(player)
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = HUD.new()
	hud.game = self
	layer.add_child(hud)
	objective = Objective.new()
	objective.game = self
	add_child(objective)
	combat.game = self
	spectator = Spectator.new()
	spectator.game = self
	add_child(spectator)
	new_round()
	set_paused(true)
	browser = Browser.new()
	browser.game = self
	add_child(browser)
	print("DUSTLINE_READY ", BUILD, " | ", RenderingServer.get_current_rendering_method(), " | ", RenderingServer.get_video_adapter_name())

func configure_input() -> void:
	var bindings := {"forward": KEY_W, "back": KEY_S, "left": KEY_A, "right": KEY_D, "jump": KEY_SPACE, "walk": KEY_SHIFT, "crouch": KEY_CTRL, "reload": KEY_R, "interact": KEY_E, "scoreboard": KEY_TAB}
	for action in bindings:
		if not InputMap.has_action(action): InputMap.add_action(action)
		var event := InputEventKey.new()
		event.physical_keycode = bindings[action]
		InputMap.action_add_event(action, event)
	for action in ["fire", "aim"]:
		if not InputMap.has_action(action): InputMap.add_action(action)
		var event := InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT if action == "fire" else MOUSE_BUTTON_RIGHT
		InputMap.action_add_event(action, event)

func _unhandled_input(event: InputEvent) -> void:
	if player.health <= 0 and has_gameplay_input():
		if event.is_action_pressed("fire") or event.is_action_pressed("jump"):
			spectator.cycle(1)
			get_viewport().set_input_as_handled()
		elif event.is_action_pressed("aim"):
			spectator.cycle(-1)
			get_viewport().set_input_as_handled()
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_ESCAPE:
				if buy_open: toggle_buy()
				else: set_paused(not paused)
			KEY_B:
				if not paused: toggle_buy()
			KEY_F8: screenshot()
			KEY_F3: diagnostics = not diagnostics
			KEY_F11: toggle_fullscreen()
			KEY_1, KEY_2, KEY_3, KEY_4:
				if buy_open or phase == "BUY": buy(event.physical_keycode - KEY_1)
			KEY_ENTER:
				if phase == "MATCH OVER": restart_match()
				elif paused: set_paused(false)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_instance_valid(player) and not silent_test:
		set_paused(true)

func set_paused(value: bool) -> void:
	paused = value
	if value:
		buy_open = false
		sound.stop_all()
		player.pending_fire = false
		spectator.pending_step = 0
		for action in ["fire", "aim", "forward", "back", "left", "right", "interact"]: Input.action_release(action)
	sync_pointer()
	if is_instance_valid(hud): hud.sync_menu()

func toggle_buy() -> void:
	if phase != "BUY":
		notify("ARMORY AVAILABLE DURING THE BUY PHASE")
		return
	buy_open = not buy_open
	sync_pointer()
	hud.sync_menu()

func sync_pointer() -> void:
	var capture := not paused and not buy_open
	if is_instance_valid(browser): browser.expect_capture(capture)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if capture else Input.MOUSE_MODE_VISIBLE

func has_gameplay_input() -> bool:
	# A headless process has no OS cursor to capture. Its synthetic input still
	# obeys the same pause/armory gates; desktop play additionally requires capture.
	return not paused and not buy_open and (DisplayServer.get_name() == "headless" or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)

func buy(index: int) -> bool:
	if phase != "BUY" or player.health <= 0 or index < 0 or index >= Weapons.SPECS.size(): return false
	if player.slot == index:
		notify("ALREADY EQUIPPED")
		return true
	var price: int = Weapons.SPECS[index].price
	if money < price:
		notify("NOT ENOUGH FUNDS")
		return false
	money -= price
	player.equip(index)
	notify("EQUIPPED  " + str(Weapons.SPECS[index].name))
	return true

func new_round() -> void:
	sound.stop_all()
	spectator.reset()
	combat.reset()
	kill_feed.clear()
	damage_flash = 0
	hit_flash = 0
	round_number += 1
	phase = "BUY"
	phase_left = 7.0
	buy_open = false
	bomb_active = false
	bomb_left = 35.0
	defuse_progress = 0
	defuser = null
	bomb_beep = 0
	if is_instance_valid(bomb_mesh): bomb_mesh.queue_free()
	for bot in bots:
		remove_child(bot)
		bot.queue_free()
	bots.clear()
	player.reset_at(Layout.on_floor(Layout.CT_SPAWN))
	for index in 9:
		var bot := Bot.new()
		bot.game = self
		bot.index = index
		bot.team = 0 if index < 4 else 1
		bot.slot = 0 if bot.team == 0 else 1
		var spawn := Layout.CT_SPAWN if bot.team == 0 else Layout.T_SPAWN
		spawn += Vector3((index % 3 - 1) * 2.0, 0, -2.0 if index < 4 else (index % 2) * 2.0)
		bot.position = Layout.on_floor(spawn) + Vector3.UP * 0.06
		add_child(bot)
		bots.append(bot)
	objective.reset_round()
	notify("ROUND %d  /  BUY & PREPARE" % round_number, 7.0)
	if is_instance_valid(hud): hud.sync_menu()

func restart_match() -> void:
	ct_score = 0
	t_score = 0
	round_number = 0
	money = 3400
	kills = 0
	deaths = 0
	kill_feed.clear()
	new_round()
	set_paused(false)

func _physics_process(dt: float) -> void:
	if paused: return
	elapsed += dt
	phase_left -= dt
	banner_left = maxf(0, banner_left - dt)
	hit_flash = maxf(0, hit_flash - dt)
	damage_flash = maxf(0, damage_flash - dt)
	combat.tick()
	if phase == "BUY" and phase_left <= 0:
		phase = "LIVE"
		phase_left = 100.0
		buy_open = false
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		hud.sync_menu()
		notify("ROUND LIVE  /  DEFEND THE SITES", 3.0)
		sound.play("start")
	elif phase == "OVER" and phase_left <= 0:
		if maxi(ct_score, t_score) >= 5:
			phase = "MATCH OVER"
			set_paused(true)
		else: new_round()
	elif phase == "LIVE":
		if is_instance_valid(defuser) and (elapsed - defuse_last > 0.12 or defuser.health <= 0 or defuser.position.distance_to(bomb_at) > 2.2):
			defuser = null
			defuse_progress = 0
		if bomb_active:
			bomb_left -= dt
			bomb_beep -= dt
			if bomb_beep <= 0:
				bomb_beep = 0.22 if bomb_left < 8 else 0.85
				sound.play_at("beep", bomb_at + Vector3.UP * 0.3, -3)
			if bomb_left <= 0: finish_round(1, "DEVICE DETONATED")
		var ct_alive := 1 if player.health > 0 else 0
		var t_alive := 0
		for bot in bots:
			if bot.health > 0:
				if bot.team == 0: ct_alive += 1
				else: t_alive += 1
		if ct_alive == 0: finish_round(1, "ATTACKERS WIN")
		elif t_alive == 0 and not bomb_active: finish_round(0, "DEFENDERS WIN")
		elif phase_left <= 0 and not bomb_active: finish_round(0, "SITES SECURED")

func actors() -> Array[Node3D]:
	var result: Array[Node3D] = [player]
	for bot in bots: result.append(bot)
	return result

func fire_shot(shooter: Node3D, from: Vector3, direction: Vector3, slot: int, spread: float) -> Dictionary:
	var ray := Weapons.direction_with_spread(direction, spread, rng)
	var query := PhysicsRayQueryParameters3D.create(from, from + ray * 140, 7, [shooter.get_rid()])
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	var end: Vector3 = result.position if not result.is_empty() else from + ray * 90
	if not result.is_empty():
		var victim: Object = result.collider
		if victim.has_method("take_hit") and victim.team != shooter.team:
			var damage: float = Weapons.SPECS[slot].damage
			var head_height := 0.98 if victim == player and player.crouched else 1.48
			var headshot: bool = result.position.y - victim.global_position.y > head_height
			if headshot: damage *= 3.4
			victim.take_hit(damage, shooter, headshot)
			if shooter == player:
				hits += 1
				hit_flash = 0.11
		elif not victim.has_method("take_hit"):
			impact(end, result.normal)
	trace(from + ray * 0.5, end)
	for bot in bots:
		if bot.team != shooter.team and bot.health > 0 and bot.position.distance_to(from) < 22: bot.hear(from)
	return result

func trace(from: Vector3, to: Vector3) -> void:
	if silent_test: return
	var distance := from.distance_to(to)
	var node := world.cylinder((from + to) * 0.5, 0.007, 0.007, distance, world.material(Color("ebbf79")))
	node.quaternion = Quaternion(Vector3.UP, (to - from).normalized())
	effects.append(node)
	get_tree().create_timer(0.045).timeout.connect(func():
		effects.erase(node)
		if is_instance_valid(node): node.queue_free())

func impact(at: Vector3, normal: Vector3) -> void:
	if silent_test: return
	var node := world.box(at + normal * 0.014, Vector3(0.055, 0.055, 0.016), world.material(Color("39372f")))
	if absf(normal.dot(Vector3.UP)) < 0.99: node.look_at(at + normal, Vector3.UP)
	else: node.rotation.x = PI * 0.5
	get_tree().create_timer(8.0).timeout.connect(func():
		if is_instance_valid(node): node.queue_free())

func actor_name(actor: Node3D) -> String:
	return "YOU" if actor == player else ("CT %02d" if actor.team == 0 else "T %02d") % actor.index

func view_position() -> Vector3:
	return spectator.camera.global_position if spectator.active else player.camera.global_position

func killed(victim: Node3D, attacker: Node3D, headshot: bool = false) -> void:
	objective.drop(victim)
	combat.on_kill(victim, attacker, headshot)
	kill_feed.push_front({"killer": actor_name(attacker), "victim": actor_name(victim), "slot": attacker.slot,
		"headshot": headshot, "team": attacker.team, "personal": attacker == player or victim == player, "until": elapsed + 7.0})
	if kill_feed.size() > 4: kill_feed.pop_back()
	if attacker == player:
		kills += 1
		money += 300
	if victim == player:
		deaths += 1
		spectator.begin()
		notify("YOU ARE DOWN  /  FOLLOWING YOUR SQUAD", 2.0)

func plant(actor: Node3D) -> bool:
	if paused or bomb_active or phase != "LIVE" or actor != objective.carrier or actor.health <= 0 or actor.team != 1 or objective.plant_progress < 3: return false
	var at: Vector3 = actor.position
	if minf(at.distance_to(Layout.on_floor(Layout.SITE_A)), at.distance_to(Layout.on_floor(Layout.SITE_B))) > 4.2: return false
	bomb_active = true
	bomb_at = Layout.on_floor(at)
	bomb_left = 35.0
	defuse_progress = 0
	bomb_mesh = world.box(bomb_at + Vector3.UP * 0.18, Vector3(0.48, 0.32, 0.30), world.material(Color("434b3e")))
	world.box(Vector3(0, 0.18, 0), Vector3(0.20, 0.025, 0.13), world.material(Color("f38b42")), false, bomb_mesh)
	objective.on_planted()
	notify("DEVICE PLANTED AT " + Layout.callout(at) + "  /  HOLD E TO DEFUSE", 5.0)
	return true

func defuse(actor: Node3D, dt: float) -> void:
	if phase != "LIVE" or not bomb_active or actor.team != 0 or actor.health <= 0 or actor.position.distance_to(bomb_at) > 2.0: return
	if Vector2(actor.velocity.x, actor.velocity.z).length() > 0.35: return
	if is_instance_valid(defuser) and defuser != actor: return
	defuser = actor
	defuse_last = elapsed
	defuse_progress += dt
	if defuse_progress >= 5.0:
		bomb_active = false
		finish_round(0, "DEVICE DEFUSED")

func finish_round(winner: int, message: String) -> void:
	if phase != "LIVE": return
	phase = "OVER"
	phase_left = 5.0
	if winner == 0: ct_score += 1
	else: t_score += 1
	money = mini(16000, money + (3250 if winner == 0 else 1900))
	notify(message, 5.0)
	sound.play("start", -2, 0.8 if winner == 1 else 1.2)

func notify(message: String, seconds: float = 2.5) -> void:
	banner = message
	banner_left = seconds

func details() -> String:
	return JSON.stringify({"build": BUILD, "seed": match_seed, "engine": Engine.get_version_info().string, "os": OS.get_name(), "renderer": RenderingServer.get_current_rendering_method(), "gpu": RenderingServer.get_video_adapter_name(), "fps": Engine.get_frames_per_second(), "round": round_number, "phase": phase, "phase_left": phase_left, "paused": paused, "buy_open": buy_open, "elapsed": elapsed, "position": str(player.position), "position_xyz": [player.position.x, player.position.y, player.position.z], "yaw": player.rotation.y, "pitch": player.pitch, "ammo": player.ammo, "reload_left": player.reload_left, "location": Layout.callout(player.position), "view_location": Layout.callout(view_position()), "spectating": actor_name(spectator.target) if spectator.active else "", "last_death": combat.death_report, "weapon": Weapons.SPECS[player.slot].name, "health": player.health, "shots": player.shot_count, "hits": hits, "muted": sound.muted}, "  ")

func screenshot() -> void:
	if DisplayServer.get_name() == "headless": return
	if OS.has_feature("web"):
		await RenderingServer.frame_post_draw
		JavaScriptBridge.download_buffer(get_viewport().get_texture().get_image().save_png_to_buffer(), "courtyard.png", "image/png")
		notify("SCREENSHOT DOWNLOADED")
		return
	var directory := OS.get_user_data_dir().path_join("screenshots")
	DirAccess.make_dir_recursive_absolute(directory)
	var filename := directory.path_join("courtyard-%d.png" % Time.get_ticks_msec())
	await RenderingServer.frame_post_draw
	var error := get_viewport().get_texture().get_image().save_png(filename)
	notify("SCREENSHOT SAVED  /  PAUSE → OPEN SCREENSHOTS" if error == OK else "SCREENSHOT SAVE FAILED")
	print("SCREENSHOT ", filename, " ", error)

func toggle_fullscreen() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN else DisplayServer.WINDOW_MODE_FULLSCREEN)
