extends "res://scripts/hud.gd"

## Isolated experiment: no production HUD hook. The browser fixture copies this
## resource into its temporary project. Retain the original draw calls, geometry
## and alpha order; only the static radar's command lifetime changes.
## Canvas order: HUD before radar -> static radar -> markers/overlays -> menu.
## Dynamic markers intentionally retain their original per-frame drawing path.

class DrawLayer extends Control:
	var paint: Callable

	func _draw() -> void:
		paint.call(self)

var static_radar_layer: DrawLayer
var radar_overlay_layer: DrawLayer
var _radar_background: Color
var _radar_accent: Color

func _ready() -> void:
	static_radar_layer = DrawLayer.new()
	static_radar_layer.name = "RetainedRadar"
	static_radar_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	static_radar_layer.paint = _draw_static_radar
	static_radar_layer.visible = is_instance_valid(game.player)
	add_child(static_radar_layer)
	radar_overlay_layer = DrawLayer.new()
	radar_overlay_layer.name = "RadarAndOverlays"
	radar_overlay_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	radar_overlay_layer.paint = _draw_after_radar
	radar_overlay_layer.visible = static_radar_layer.visible
	add_child(radar_overlay_layer)
	_radar_background = background
	_radar_accent = accent
	# The inherited menu is added AFTER both layers, exactly as it was above
	# all original HUD commands. Layers have identity transforms and no clip.
	super()

func _process(dt: float) -> void:
	super(dt)
	var available := is_instance_valid(game.player)
	if static_radar_layer.visible != available:
		static_radar_layer.visible = available
		radar_overlay_layer.visible = available
		if available: static_radar_layer.queue_redraw()
	if _radar_background != background or _radar_accent != accent:
		_radar_background = background
		_radar_accent = accent
		static_radar_layer.queue_redraw()
	# Never throttle markers, scoreboard, diagnostics or the pause overlay.
	radar_overlay_layer.queue_redraw()

func _text_on(canvas, value: String, at: Vector2, color: Color = white, pixels: int = 20) -> void:
	canvas.draw_string(font, at, value, HORIZONTAL_ALIGNMENT_LEFT, -1, pixels, color)

func _centered_on(canvas, value: String, y: float, color: Color = white, pixels: int = 20) -> void:
	_text_on(canvas, value, Vector2((size.x - font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, pixels).x) * 0.5, y), color, pixels)

func _draw() -> void:
	if not is_instance_valid(game.player): return
	var player: Node3D = game.player
	var subject: Node3D = game.spectator.target if game.spectator.active else player
	draw_rect(Rect2(size.x * 0.5 - 190, 16, 380, 106), background)
	centered("CT  %d     :     %d  T" % [game.ct_score, game.t_score], 46, white, 28)
	var timer: float = game.bomb_left if game.bomb_active else game.phase_left
	centered("%s   %02d:%02d   /   ROUND %d" % ["DEVICE" if game.bomb_active else game.phase, maxi(0, int(timer)) / 60, maxi(0, int(timer)) % 60, game.round_number], 74, accent, 17)
	var alive := [0, 0]
	for actor in game.actors():
		if actor.health > 0: alive[actor.team] += 1
	centered("%d DEFENDERS    /    %d ATTACKERS ALIVE" % alive, 110, blue, 15)
	draw_rect(Rect2(24, size.y - 106, 325, 81), background)
	text("%03d" % ceili(subject.health), Vector2(42, size.y - 54), white if subject.health > 30 else Color("e79273"), 38)
	text("HEALTH" if subject == player else game.actor_name(subject), Vector2(139, size.y - 57), blue, 14)
	text("$%d   /   %s" % [game.money, Layout.callout(subject.position)], Vector2(43, size.y - 35), accent, 15)
	draw_rect(Rect2(size.x - 334, size.y - 106, 310, 81), background)
	text("%02d / %03d" % [player.ammo, player.reserve] if subject == player else "%02d IN MAG" % subject.ammo, Vector2(size.x - 314, size.y - 59), white, 32)
	text(Weapons.SPECS[subject.slot].name, Vector2(size.x - 314, size.y - 34), blue, 16)
	if subject.reload_left > 0 and subject.health > 0: centered("RELOADING", size.y * 0.59, accent)
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
		if game.hit_flash > 0 or game.combat.kill_until > game.elapsed:
			var killed: bool = game.combat.kill_until > game.elapsed
			for direction in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]: draw_line(center + direction * 8, center + direction * (18 if killed else 14), Color("ef956e") if killed else accent, 2)
		damage_cues()
	if game.damage_flash > 0: draw_rect(Rect2(Vector2.ZERO, size), Color(0.7, 0.12, 0.04, game.damage_flash * 0.22))
	if game.banner_left > 0:
		centered(game.banner, 147, accent, 22)
	if game.phase == "BUY": centered("GET READY  /  B: BUY WEAPONS  /  MOVEMENT UNLOCKS AT ROUND START", size.y - 144, accent, 17)
	elif game.bomb_active:
		centered("DEVICE AT " + Layout.callout(game.bomb_at) + ("  /  HOLD E NEAR DEVICE" if player.health > 0 else "  /  RETAKE IN PROGRESS"), size.y - 144, accent, 17)
		if game.defuse_progress > 0:
			draw_rect(Rect2(size.x * 0.5 - 130, size.y * 0.65, 260, 8), background)
			draw_rect(Rect2(size.x * 0.5 - 130, size.y * 0.65, 260 * game.defuse_progress / 5.0, 8), blue)
	feed()
	if player.health <= 0: spectator_report()

func _draw_after_radar(canvas) -> void:
	if not is_instance_valid(game.player): return
	_draw_radar_markers(canvas)
	if Input.is_action_pressed("scoreboard"):
		canvas.draw_rect(Rect2(size.x * 0.5 - 240, size.y * 0.5 - 100, 480, 200), background)
		_centered_on(canvas, "FIELD REPORT", size.y * 0.5 - 58, accent, 27)
		_centered_on(canvas, "YOU   %d kills   /   %d deaths" % [game.kills, game.deaths], size.y * 0.5 - 13)
		_centered_on(canvas, "FIRST TO 5 ROUNDS  /  DEFENDERS", size.y * 0.5 + 33, blue, 17)
	if game.diagnostics:
		_text_on(canvas, "%s   %d FPS   p95 %.1f ms   %d draws   %s" % [game.BUILD, Engine.get_frames_per_second(),
			game.frame_metrics.cached.get("p95_ms",0), Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			game.RenderBudget.NAMES[game.render_budget.level]], Vector2(24, size.y - 9), accent, 14)
	if game.paused: canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(0.015, 0.025, 0.03, 0.5))

func _draw_static_radar(canvas) -> void:
	if not is_instance_valid(game.player): return
	var origin := Vector2(24, 20)
	var scale := 2.1
	canvas.draw_rect(Rect2(origin, Vector2(190, 202)), background)
	for room in Layout.ROOMS:
		canvas.draw_rect(Rect2(origin + (room.position + Vector2(44, 44)) * scale, room.size * scale), Color("52616a"))
	for cover in Layout.COVERS:
		canvas.draw_rect(Rect2(origin + (cover.position + Vector2(44, 44)) * scale, cover.size * scale), Color("25363d"))
	for door in Layout.DOORS:
		var points := Layout.door_corners(door)
		for i in points.size(): points[i] = origin + (points[i] + Vector2(44,44)) * scale
		canvas.draw_colored_polygon(points,Color("ab895a"))
	for site_at in [Layout.SITE_A, Layout.SITE_B]:
		var at: Vector2 = origin + (Vector2(site_at.x, site_at.z) + Vector2(44, 44)) * scale
		canvas.draw_circle(at, 5, accent)

func _draw_radar_markers(canvas) -> void:
	var origin := Vector2(24, 20)
	var scale := 2.1
	for actor in game.actors():
		if actor.team != 0 or actor.health <= 0: continue
		var at := origin + (Vector2(actor.position.x, actor.position.z) + Vector2(44, 44)) * scale
		canvas.draw_circle(at, 3.4 if actor == game.player else 2.5, white if actor == game.player else blue)
		if actor == game.player or actor == game.spectator.target:
			canvas.draw_line(at, at + Vector2(-sin(actor.rotation.y), -cos(actor.rotation.y)) * 10, white, 1.5)
			if actor == game.spectator.target: canvas.draw_circle(at, 5.5, white, false, 1.5)

