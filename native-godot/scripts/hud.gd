extends Control

const Layout = preload("res://scripts/layout.gd")
const Weapons = preload("res://scripts/weapons.gd")
var game: Node3D
var font: Font
var panel: PanelContainer
var column: VBoxContainer
var menu_title: Label
var menu_note: Label
var menu_buttons: Array[Button] = []
var background := Color(0.025, 0.05, 0.065, 0.89)
var white := Color("e8e7d9")
var accent := Color("ebba70")
var blue := Color("8cc9de")

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = ThemeDB.fallback_font
	panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(530, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.045, 0.06, 0.97)
	style.set_content_margin_all(30)
	style.border_color = Color("4d6874")
	style.set_border_width_all(1)
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	column = VBoxContainer.new()
	column.add_theme_constant_override("separation", 9)
	panel.add_child(column)
	menu_title = Label.new()
	menu_title.add_theme_font_size_override("font_size", 32)
	menu_title.add_theme_color_override("font_color", accent)
	column.add_child(menu_title)
	menu_note = Label.new()
	menu_note.add_theme_font_size_override("font_size", 16)
	column.add_child(menu_note)
	resized.connect(center_menu)
	sync_menu()

func button(text: String, callback: Callable) -> void:
	var control := Button.new()
	control.text = text
	control.custom_minimum_size.y = 40
	control.add_theme_font_size_override("font_size", 18)
	control.pressed.connect(callback)
	column.add_child(control)
	menu_buttons.append(control)

func sync_menu() -> void:
	if not is_instance_valid(panel): return
	for control in menu_buttons:
		column.remove_child(control)
		control.queue_free()
	menu_buttons.clear()
	panel.visible = game.paused or game.buy_open
	if game.buy_open:
		menu_title.text = "FIELD ARMORY"
		menu_note.text = "Buy phase only • movement is frozen • $%d" % game.money
		for i in Weapons.SPECS.size():
			button("%d  /  %s   ·   $%d" % [i + 1, Weapons.SPECS[i].name, Weapons.SPECS[i].price], func(): game.buy(i); sync_menu())
		button("Ready  /  B", game.toggle_buy)
	else:
		menu_title.text = "DUSTLINE / NATIVE"
		menu_note.text = "COURTYARD · Single-map tactical experiment\nOriginal map & assets • Sol + Astra run\nWASD move • Mouse aim • LMB fire • R reload\nB armory • E defuse • F8 save screenshot"
		if game.phase == "MATCH OVER":
			button("Match complete / Play again", game.restart_match)
		else:
			button("Deploy / Resume  ·  Enter", func(): game.set_paused(false))
		button("New match", game.restart_match)
		button("Sound: %s  /  test" % ("OFF" if game.sound.muted else "ON"), func():
			game.sound.muted = not game.sound.muted
			game.sound.play("start")
			sync_menu())
		button("Fullscreen / Windowed  ·  F11", game.toggle_fullscreen)
		button("Copy feedback details", func(): DisplayServer.clipboard_set(game.details()); game.notify("TEST DETAILS COPIED"))
		button("Open screenshots folder", func():
			var directory: String = OS.get_user_data_dir().path_join("screenshots")
			DirAccess.make_dir_recursive_absolute(directory)
			OS.shell_open(directory))
		button("Quit", func(): get_tree().quit())
	call_deferred("center_menu")

func center_menu() -> void:
	if not is_instance_valid(panel): return
	panel.reset_size()
	panel.position = (size - panel.size) * 0.5

func _process(_dt: float) -> void:
	queue_redraw()

func text(value: String, at: Vector2, color: Color = white, pixels: int = 20) -> void:
	draw_string(font, at, value, HORIZONTAL_ALIGNMENT_LEFT, -1, pixels, color)

func centered(value: String, y: float, color: Color = white, pixels: int = 20) -> void:
	text(value, Vector2((size.x - font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, pixels).x) * 0.5, y), color, pixels)

func _draw() -> void:
	if not is_instance_valid(game.player): return
	var player: Node3D = game.player
	draw_rect(Rect2(size.x * 0.5 - 190, 16, 380, 73), background)
	centered("CT  %d     :     %d  T" % [game.ct_score, game.t_score], 46, white, 28)
	var timer: float = game.bomb_left if game.bomb_active else game.phase_left
	centered("%s   %02d:%02d   /   ROUND %d" % ["DEVICE" if game.bomb_active else game.phase, maxi(0, int(timer)) / 60, maxi(0, int(timer)) % 60, game.round_number], 74, accent, 17)
	draw_rect(Rect2(24, size.y - 106, 325, 81), background)
	text("%03d" % ceili(player.health), Vector2(42, size.y - 54), white if player.health > 30 else Color("e79273"), 38)
	text("HEALTH", Vector2(139, size.y - 57), blue, 14)
	text("$%d   /   %s" % [game.money, Layout.callout(player.position)], Vector2(43, size.y - 35), accent, 15)
	draw_rect(Rect2(size.x - 334, size.y - 106, 310, 81), background)
	text("%02d / %03d" % [player.ammo, player.reserve], Vector2(size.x - 314, size.y - 59), white, 32)
	text(Weapons.SPECS[player.slot].name, Vector2(size.x - 314, size.y - 34), blue, 16)
	if player.reload_left > 0: centered("RELOADING", size.y * 0.66, accent)
	if player.health > 0 and not game.paused:
		var center := size * 0.5
		if player.aimed and player.slot == 2:
			var radius := size.y * 0.42
			draw_circle(center, radius + size.x, Color(0, 0, 0, 0.6), false, size.x * 2)
			draw_line(center - Vector2(radius, 0), center + Vector2(radius, 0), Color.BLACK, 1.5)
			draw_line(center - Vector2(0, radius), center + Vector2(0, radius), Color.BLACK, 1.5)
		else:
			var spread: float = Weapons.spread(player.slot, Vector2(player.velocity.x, player.velocity.z).length(), not player.is_on_floor(), player.aimed, player.crouched, player.heat)
			var gap := 4.0 + spread * 350
			for direction in [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]:
				draw_line(center + direction * gap, center + direction * (gap + 7), Color(0, 0, 0, 0.7), 3)
				draw_line(center + direction * gap, center + direction * (gap + 7), white, 1.5)
		if game.hit_flash > 0:
			for direction in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]: draw_line(center + direction * 8, center + direction * 14, accent, 2)
	if game.damage_flash > 0: draw_rect(Rect2(Vector2.ZERO, size), Color(0.7, 0.12, 0.04, game.damage_flash * 0.35))
	if game.banner_left > 0:
		centered(game.banner, 135, accent, 22)
	if game.phase == "BUY": centered("GET READY  /  B: BUY WEAPONS  /  MOVEMENT UNLOCKS AT ROUND START", size.y - 144, accent, 17)
	elif game.bomb_active:
		centered("DEVICE AT " + Layout.callout(game.bomb_at) + "  /  HOLD E NEAR DEVICE", size.y - 144, accent, 17)
		if game.defuse_progress > 0:
			draw_rect(Rect2(size.x * 0.5 - 130, size.y * 0.65, 260, 8), background)
			draw_rect(Rect2(size.x * 0.5 - 130, size.y * 0.65, 260 * game.defuse_progress / 5.0, 8), blue)
	for i in game.kill_feed.size():
		text(game.kill_feed[i], Vector2(size.x - 260, 126 + i * 27), white, 16)
	radar()
	if Input.is_action_pressed("scoreboard"):
		draw_rect(Rect2(size.x * 0.5 - 240, size.y * 0.5 - 100, 480, 200), background)
		centered("FIELD REPORT", size.y * 0.5 - 58, accent, 27)
		centered("YOU   %d kills   /   %d deaths" % [game.kills, game.deaths], size.y * 0.5 - 13)
		centered("FIRST TO 5 ROUNDS  /  DEFENDERS", size.y * 0.5 + 33, blue, 17)
	if game.diagnostics: text("%s   %d FPS   %s" % [game.BUILD, Engine.get_frames_per_second(), RenderingServer.get_current_rendering_method()], Vector2(24, size.y - 9), accent, 14)
	if game.paused: draw_rect(Rect2(Vector2.ZERO, size), Color(0.015, 0.025, 0.03, 0.5))

func radar() -> void:
	var origin := Vector2(24, 20)
	var scale := 2.1
	draw_rect(Rect2(origin, Vector2(190, 202)), background)
	for room in Layout.ROOMS:
		draw_rect(Rect2(origin + (room.position + Vector2(44, 44)) * scale, room.size * scale), Color("52616a"))
	for cover in Layout.COVERS:
		draw_rect(Rect2(origin + (cover.position + Vector2(44, 44)) * scale, cover.size * scale), Color("25363d"))
	for door in Layout.DOORS:
		draw_rect(Rect2(origin + (door.position + Vector2(44, 44)) * scale, door.size * scale), Color("ab895a"))
	for site_at in [Layout.SITE_A, Layout.SITE_B]:
		var at: Vector2 = origin + (Vector2(site_at.x, site_at.z) + Vector2(44, 44)) * scale
		draw_circle(at, 5, accent)
	for actor in game.actors():
		if actor.team != 0 or actor.health <= 0: continue
		var at := origin + (Vector2(actor.position.x, actor.position.z) + Vector2(44, 44)) * scale
		draw_circle(at, 3.4 if actor == game.player else 2.5, white if actor == game.player else blue)
		if actor == game.player:
			draw_line(at, at + Vector2(-sin(actor.rotation.y), -cos(actor.rotation.y)) * 10, white, 1.5)
