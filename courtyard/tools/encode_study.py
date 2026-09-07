"""Encode an offline Godot animation study with Blender's bundled FFmpeg.

blender --background --python courtyard/tools/encode_study.py -- grounded-study
This is a six-second 60 fps posed asset study, not a live game performance video.
"""
import bpy
import sys
from pathlib import Path

label = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "grounded-study"
directory = Path(__file__).resolve().parents[1] / "builds" / "operator-gallery"
frames = [directory / f"{label}-frame-{i:04d}.png" for i in range(360)]
assert all(frame.is_file() for frame in frames), "Render all 360 study frames first"
destination = directory / f"{label}.webm"
assert not destination.exists(), "Choose a fresh label; do not overwrite an existing study"
scene = bpy.context.scene
scene.sequence_editor_create()
strip = scene.sequence_editor.strips.new_image("Godot renderer frames", str(frames[0]), 1, 1)
for frame in frames[1:]:
    strip.elements.append(frame.name)
scene.frame_start, scene.frame_end = 1, 360
scene.render.resolution_x, scene.render.resolution_y = 1280, 720
scene.render.resolution_percentage = 100
scene.render.fps = 60
scene.render.threads_mode = 'FIXED'
scene.render.threads = 2
scene.render.use_sequencer = True
scene.view_settings.view_transform = 'Standard'
scene.view_settings.look = 'None'
scene.render.image_settings.file_format = 'FFMPEG'
scene.render.ffmpeg.format = 'WEBM'
scene.render.ffmpeg.codec = 'WEBM'
scene.render.ffmpeg.constant_rate_factor = 'MEDIUM'
scene.render.ffmpeg.audio_codec = 'NONE'
scene.render.filepath = str(destination)
bpy.ops.render.render(animation=True)
print("ANIMATION_STUDY_ENCODED", destination, destination.stat().st_size)
