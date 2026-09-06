class_name FieldRenderBudget
extends RefCounted

const NAMES := ["Balanced", "Performance", "High"]
var level := 2

static func pixel_size(viewport: Viewport) -> Vector2:
	# Window.size is the physical framebuffer. get_visible_rect() is logical
	# HUD size under canvas_items stretching; ViewportTexture.get_size() can
	# include its content stretch and over-report the main window's pixels.
	return viewport.size if viewport is Window else viewport.get_texture().get_size()

static func scale_for(size: Vector2, quality: int) -> float:
	# The HUD stays at full display resolution. Bound only 3D fill cost on
	# high-DPI/4K screens; the default High is uncapped.
	if quality == 2: return 1.0
	var pixels := 1280.0 * 720.0 if quality == 1 else 1920.0 * 1080.0
	return clampf(sqrt(pixels / maxf(size.x * size.y,1.0)),0.25,1.0)

func apply(game: Node3D) -> void:
	var viewport := game.get_viewport()
	viewport.scaling_3d_scale = scale_for(pixel_size(viewport),level)
	viewport.msaa_3d = Viewport.MSAA_DISABLED if level == 1 else Viewport.MSAA_2X
	for node in game.world.find_children("*","WorldEnvironment",true,false):
		node.environment.ssao_enabled = level == 2
	for light in game.world.find_children("*","DirectionalLight3D",true,false):
		light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS if level == 2 else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		light.directional_shadow_max_distance = 110.0 if level == 2 else (50.0 if level == 1 else 70.0)
		light.directional_shadow_blend_splits = level == 2

func details(viewport: Viewport) -> Dictionary:
	var size := pixel_size(viewport)
	var logical := viewport.get_visible_rect().size
	return {"quality": NAMES[level], "ssao": level == 2, "viewport": [size.x,size.y], "logical_size": [logical.x,logical.y], "scale_3d": viewport.scaling_3d_scale,
		"render_3d": [roundi(size.x * viewport.scaling_3d_scale), roundi(size.y * viewport.scaling_3d_scale)],
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)}
