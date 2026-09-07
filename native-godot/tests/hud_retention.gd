extends SceneTree

const Candidate = preload("res://engine/experiments/hud_retained.gd")
const Layout = preload("res://scripts/layout.gd")
var passed := 0
var failed := 0

# Record the exact public CanvasItem arguments without invoking a renderer.
# Independent reference routines below retain the baseline radar formulas.
class CanvasRecorder extends RefCounted:
	var commands: Array = []

	func draw_rect(rect: Rect2, color: Color, filled := true, width := -1.0, antialiased := false) -> void:
		commands.append(["rect", rect, color, filled, width, antialiased])

	func draw_colored_polygon(points: PackedVector2Array, color: Color) -> void:
		commands.append(["polygon", points.duplicate(), color])

	func draw_circle(at: Vector2, radius: float, color: Color, filled := true, width := -1.0, antialiased := false) -> void:
		commands.append(["circle", at, radius, color, filled, width, antialiased])

	func draw_line(from: Vector2, to: Vector2, color: Color, width := -1.0, antialiased := false) -> void:
		commands.append(["line", from, to, color, width, antialiased])

	func draw_string(font: Font, at: Vector2, value: String, alignment: int, width: float, pixels: int, color: Color) -> void:
		commands.append(["string", font, at, value, alignment, width, pixels, color])

func check(ok: bool, label: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)

func _initialize() -> void:
	call_deferred("run")

func reference_static(canvas: CanvasRecorder, hud: Control) -> void:
	var origin := Vector2(24, 20)
	var scale := 2.1
	canvas.draw_rect(Rect2(origin, Vector2(190, 202)), hud.background)
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
		canvas.draw_circle(at, 5, hud.accent)

func reference_markers(canvas: CanvasRecorder, hud: Control) -> void:
	var game: Node3D = hud.game
	var origin := Vector2(24, 20)
	var scale := 2.1
	for actor in game.actors():
		if actor.team != 0 or actor.health <= 0: continue
		var at := origin + (Vector2(actor.position.x, actor.position.z) + Vector2(44, 44)) * scale
		canvas.draw_circle(at, 3.4 if actor == game.player else 2.5, hud.white if actor == game.player else hud.blue)
		if actor == game.player or actor == game.spectator.target:
			canvas.draw_line(at, at + Vector2(-sin(actor.rotation.y), -cos(actor.rotation.y)) * 10, hud.white, 1.5)
			if actor == game.spectator.target: canvas.draw_circle(at, 5.5, hud.white, false, 1.5)

func reference_centered(canvas: CanvasRecorder, hud: Control, value: String, y: float, color: Color, pixels: int) -> void:
	canvas.draw_string(hud.font, Vector2((hud.size.x - hud.font.get_string_size(value, HORIZONTAL_ALIGNMENT_LEFT, -1, pixels).x) * 0.5, y), value, HORIZONTAL_ALIGNMENT_LEFT, -1, pixels, color)

func reference_after(canvas: CanvasRecorder, hud: Control) -> void:
	var game: Node3D = hud.game
	reference_markers(canvas, hud)
	if Input.is_action_pressed("scoreboard"):
		canvas.draw_rect(Rect2(hud.size.x * 0.5 - 240, hud.size.y * 0.5 - 100, 480, 200), hud.background)
		reference_centered(canvas, hud, "FIELD REPORT", hud.size.y * 0.5 - 58, hud.accent, 27)
		reference_centered(canvas, hud, "YOU   %d kills   /   %d deaths" % [game.kills, game.deaths], hud.size.y * 0.5 - 13, hud.white, 20)
		reference_centered(canvas, hud, "FIRST TO 5 ROUNDS  /  DEFENDERS", hud.size.y * 0.5 + 33, hud.blue, 17)
	if game.diagnostics:
		canvas.draw_string(hud.font, Vector2(24, hud.size.y - 9), "%s   %d FPS   p95 %.1f ms   %d draws   %s" % [game.BUILD, Engine.get_frames_per_second(),
			game.frame_metrics.cached.get("p95_ms",0), Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			game.RenderBudget.NAMES[game.render_budget.level]], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, hud.accent)
	if game.paused: canvas.draw_rect(Rect2(Vector2.ZERO, hud.size), Color(0.015, 0.025, 0.03, 0.5))

func frame_steps(count: int) -> void:
	for i in count: await process_frame

func compare_commands(hud: Control, label: String) -> void:
	var actual := CanvasRecorder.new()
	var expected := CanvasRecorder.new()
	hud._draw_static_radar(actual)
	reference_static(expected, hud)
	check(actual.commands == expected.commands, label + ": static coordinates/colors/draw order exactly match")
	check(actual.commands.size() == 39, label + ": retains all 33 rectangles and six polygon/circle commands")
	actual.commands.clear()
	expected.commands.clear()
	hud._draw_after_radar(actual)
	reference_after(expected, hud)
	check(actual.commands == expected.commands, label + ": marker/overlay coordinates, styles and order exactly match")
	if hud.game.paused:
		check(actual.commands[-1] == ["rect", Rect2(Vector2.ZERO, hud.size), Color(0.015,0.025,0.03,0.5), true, -1.0, false], label + ": pause tint remains above the complete radar")

func run() -> void:
	# Guard the copied pre-radar portion against future baseline changes; no
	# unrelated HUD content is silently omitted while the experiment evolves.
	var baseline := FileAccess.get_file_as_string("res://scripts/hud.gd")
	var candidate := FileAccess.get_file_as_string("res://engine/experiments/hud_retained.gd")
	var before := baseline.split("\nfunc _draw() -> void:\n")[1].split("\tradar()\n")[0].strip_edges()
	var retained_before := candidate.split("\nfunc _draw() -> void:\n")[1].split("\nfunc _draw_after_radar")[0].strip_edges()
	check(before == retained_before, "All pre-radar HUD commands, including damage tint, stay byte-identical")
	check(not baseline.contains("RetainedRadar"), "Production HUD does not opt into the experiment")
	var game: Node3D = load("res://main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	# Freeze simulation, not HUD updates. No rendered/native window is opened.
	game.process_mode = Node.PROCESS_MODE_DISABLED
	var original: Control = game.hud
	original.hide()
	var hud := Candidate.new()
	hud.game = game
	hud.process_mode = Node.PROCESS_MODE_ALWAYS
	original.get_parent().add_child(hud)
	game.hud = hud
	var draws := {"hud": 0, "static": 0, "dynamic": 0}
	hud.draw.connect(func(): draws.hud += 1)
	hud.static_radar_layer.draw.connect(func(): draws.static += 1)
	hud.radar_overlay_layer.draw.connect(func(): draws.dynamic += 1)
	await frame_steps(4)
	check(draws.static == 1, "Static radar creates draw commands once after entry")
	check(hud.static_radar_layer.get_index() < hud.radar_overlay_layer.get_index() and hud.radar_overlay_layer.get_index() < hud.panel.get_index(), "Compositing order is static radar, markers/overlays, then existing menu")
	for layer in [hud.static_radar_layer, hud.radar_overlay_layer]:
		check(layer.z_index == 0 and not layer.show_behind_parent and not layer.clip_contents, "Layer preserves ordinary parent-before-child order without clipping")
		check(layer.get_transform() == Transform2D.IDENTITY and layer.mouse_filter == Control.MOUSE_FILTER_IGNORE, "Layer preserves HUD coordinates and cannot capture input")
	var earlier: Dictionary = draws.duplicate()
	await frame_steps(12)
	check(draws.static == earlier.static, "Steady frames do not rebuild any of the six static polygons")
	check(draws.hud - earlier.hud == 12 and draws.dynamic - earlier.dynamic == 12, "Every frame still redraws dynamic HUD, markers and overlays")
	compare_commands(hud, "BUY/paused")
	game.phase = "LIVE"
	game.paused = false
	compare_commands(hud, "LIVE")
	var markers_before := CanvasRecorder.new()
	hud._draw_radar_markers(markers_before)
	game.player.position = Vector3(-23.125, 0, 24.875)
	game.player.rotation.y = -1.17
	game.bots[0].position = Vector3(17.75, 2.2, -28.125)
	game.bots[0].rotation.y = 0.67
	game.damage_flash = 0.7
	compare_commands(hud, "Moving/turning with damage")
	var markers_after := CanvasRecorder.new()
	hud._draw_radar_markers(markers_after)
	check(markers_after.commands != markers_before.commands, "Markers use current positions/orientations without a cached simulation sample")
	game.player.health = 0
	game.bots[1].health = 0
	game.spectator.target = game.bots[0]
	game.spectator.active = true
	compare_commands(hud, "Deaths/spectator ring")
	Input.action_press("scoreboard")
	compare_commands(hud, "Scoreboard over spectator radar")
	game.paused = true
	game.diagnostics = true
	compare_commands(hud, "Diagnostics/scoreboard/pause layering")
	Input.action_release("scoreboard")
	for viewport_size in [Vector2(1600,900), Vector2(500,360), Vector2(900,1600)]:
		hud.size = viewport_size
		compare_commands(hud, "HUD size %s" % viewport_size)
	await frame_steps(3)
	check(draws.static == earlier.static, "Resizing and gameplay-state changes leave static map geometry retained")
	var static_before: int = draws.static
	hud.background = Color(0.04,0.08,0.1,0.75)
	hud.accent = Color(0.8,0.6,0.4,0.9)
	await frame_steps(3)
	check(draws.static == static_before + 1, "A palette change invalidates static commands exactly once")
	compare_commands(hud, "Changed palette")
	var player: Node3D = game.player
	game.player = null
	await frame_steps(3)
	check(not hud.static_radar_layer.visible and not hud.radar_overlay_layer.visible, "Missing player hides previously retained geometry during teardown")
	var absent := CanvasRecorder.new()
	hud._draw_static_radar(absent)
	hud._draw_after_radar(absent)
	check(absent.commands.is_empty(), "Missing-player callbacks have no stale draw commands")
	game.player = player
	await frame_steps(3)
	check(hud.static_radar_layer.visible and hud.radar_overlay_layer.visible and draws.static == static_before + 2, "Player replacement restores static commands exactly once")
	compare_commands(hud, "Restored player")
	var static_ref: WeakRef = weakref(hud.static_radar_layer)
	var dynamic_ref: WeakRef = weakref(hud.radar_overlay_layer)
	game.hud = original
	hud.free()
	check(static_ref.get_ref() == null and dynamic_ref.get_ref() == null, "Freeing the HUD frees both retained layers")
	print("HUD_RETENTION_COUNTS ", JSON.stringify(draws), " static_polygons=6 unchanged_dynamic_actor_dots=true")
	game.queue_free()
	await frame_steps(2)
	print("HUD_RETENTION: ", passed, "/", passed + failed, " passed")
	quit(0 if failed == 0 else 1)
