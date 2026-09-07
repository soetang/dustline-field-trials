class_name FieldBrowser
extends Node

var game: Node3D
var publish_left := 0.0

func _ready() -> void:
	if not OS.has_feature("web"):
		set_process(false)
		return
	JavaScriptBridge.eval("""
		(() => {
			const canvas=document.getElementById('canvas');
			const gl=canvas?.getContext('webgl2');
			const ext=gl?.getExtension('WEBGL_debug_renderer_info');
			window.courtyardGraphicsBackend=ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : 'not exposed by browser';
		})();
		window.courtyardPauseRequested = false;
		window.courtyardWantsPointerLock = false;
		(() => {
			let captured = false;
			document.addEventListener('pointerlockchange', () => {
				if (captured && !document.pointerLockElement && window.courtyardWantsPointerLock) window.courtyardPauseRequested = true;
				captured = !!document.pointerLockElement;
			});
			document.addEventListener('visibilitychange', () => {
				if (document.hidden) window.courtyardPauseRequested = true;
			});
		})();
	""", true)

func _process(dt: float) -> void:
	publish_left -= dt
	if publish_left > 0: return
	publish_left = 0.2
	if JavaScriptBridge.eval("window.courtyardPauseRequested === true", true):
		JavaScriptBridge.eval("window.courtyardPauseRequested = false", true)
		game.set_paused(true)
	# Read-only, local diagnostic state. No remote uploads or gameplay commands.
	JavaScriptBridge.eval("window.courtyardState = Object.assign(" + game.details() + ", {graphics_backend:window.courtyardGraphicsBackend, device_pixel_ratio:window.devicePixelRatio})", true)

func expect_capture(value: bool) -> void:
	if OS.has_feature("web"):
		# Armory/menu intentionally release the mouse; only unexpected loss pauses.
		JavaScriptBridge.eval("window.courtyardWantsPointerLock = " + ("true" if value else "false"), true)

func feedback() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.courtyardFeedback && window.courtyardFeedback(JSON.stringify(Object.assign(" + game.details() + ", {graphics_backend:window.courtyardGraphicsBackend, device_pixel_ratio:window.devicePixelRatio}),null,2))", true)
	else:
		DisplayServer.clipboard_set(game.details())
		game.notify("TEST DETAILS COPIED")
