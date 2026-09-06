extends RefCounted

## Temporary exported-fixture adapter. Not loaded by the public game.
## The interval brackets RenderingServer signals, not browser composition.
var bridge: JavaScriptObject
var frame_id := 0
var segment := ""

func _init() -> void:
	JavaScriptBridge.eval("window.renderGpuProbe = window.GpuTimerProbe.createProbe(document.getElementById('canvas').getContext('webgl2'), {trackBlits: true})", true)
	bridge = JavaScriptBridge.get_interface("renderGpuProbe")
	RenderingServer.frame_pre_draw.connect(begin_frame)
	RenderingServer.frame_post_draw.connect(end_frame)

func begin_frame() -> void:
	frame_id += 1
	bridge.beginFrame(frame_id, segment)

func end_frame() -> void:
	bridge.endFrame()

func start(name: String, enabled: bool) -> void:
	segment = name
	bridge.reset()
	bridge.setEnabled(enabled)

func stop() -> void:
	bridge.setEnabled(false)

func collect(tree: SceneTree) -> Dictionary:
	# No result readback or waiting in a measured window. The pool is bounded;
	# unresolved queries at this deadline are reported, not treated as 0 ms.
	var deadline := Time.get_ticks_usec() + 1000000
	while not bridge.drain().done and Time.get_ticks_usec() < deadline:
		await tree.process_frame
	return JSON.parse_string(JavaScriptBridge.eval("JSON.stringify(window.renderGpuProbe.snapshot())", true))

func dispose() -> void:
	RenderingServer.frame_pre_draw.disconnect(begin_frame)
	RenderingServer.frame_post_draw.disconnect(end_frame)
	bridge.dispose()
