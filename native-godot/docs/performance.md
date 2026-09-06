# Browser performance: 0.4.3

## Budget and method

The first desktop target is stable 1080p / 60 FPS: 16.67 ms per frame, preferably
12–13 ms sustained CPU and GPU work separately to leave fight headroom. 120 FPS
requires 8.33 ms and is not a promised result. A future mobile target starts at
720p / 30 FPS (33.33 ms), with sustained thermal tests before raising it.

An RTX 2060 Max-Q exists on the development laptop, but default headless Windows
Chrome selected its **integrated AMD Radeon graphics**. Always record the actual
WebGL backend: the old generic `WebKit WebGL` string did not identify it.
Linux headless SwiftShader is a software renderer, useful for correctness but
not a prediction of hardware FPS. No Windows GPU settings were changed.

We separate three kinds of evidence:

- Real keyboard/mouse browser smoke tests exercise startup, controls, audio,
  screenshots and pause. They do not represent a competitive human match.
- Fixed-camera render fixtures keep geometry, resolution and nine animated
  operators constant, without AI, physics, HUD or audio. Screenshots occur
  outside the timed region. These measure rendering, not full-match performance.
- Live feedback samples monotonic frame intervals, preserving stalls and
  excluding pause/buy gaps. p95/p99 describe slow frames, not just average FPS.

## Isolated ambient-occlusion diagnostic (not a same-quality fix)

Godot 4.7.2 Compatibility **does run SSAO**. An old source comment incorrectly
said it would be skipped. The effect adds a depth-buffer/post-processing path;
see the [exact engine renderer](https://github.com/godotengine/godot/blob/4.7.2-stable/drivers/gles3/rasterizer_scene_gles3.cpp).

2026-09-06, Windows headless Chrome, AMD integrated GPU, 1920×1080, two shadow
cascades, 16 m batching cells. Each view used SSAO on → off → off → on in the
same browser, 30 warmup frames and 90 recorded frames per segment. CPU sampling
was enabled throughout. Only SSAO changed. Ranges below cover both segments.

| View | SSAO on, mean FPS | SSAO off, mean FPS | On p95, ms | Off p95, ms |
|---|---:|---:|---:|---:|
| CT spawn | 22.1–22.4 | 40.3–41.2 | 59.7–85.7 | 29.4–29.7 |
| A site | 30.5–30.8 | 59.3–59.9 | 35.3–43.6 | 18.1–18.3 |
| Long doors | 22.8–23.8 | 48.0–49.3 | 52.5–54.9 | 25.1–26.3 |

All six SSAO-off segments had zero frames above 50 ms; this is a short fixture,
not a long-session stability guarantee. [Raw per-frame samples](performance-ssao-samples.json)
include p99, render counters and backend. **This quality reduction was rejected
as the default fix.** High remains the default and preserves SSAO, original
shadow settings and full resolution. Lower-cost presets remain explicit choices.
The experiment identifies a costly rendering path to optimize; it is not evidence
of a same-quality speedup.

Earlier shadow-only ABBA tests showed smaller gains (roughly 7–13% in these
views). These are also visual tradeoffs, not computational fixes.

## Same-quality batching experiment: disabled by default

Increasing local batch cells from 8 m to 16 m reduced 298 batches to 190.
Consolidating color-only opaque materials then reduced those 190 to 92. The same
1,376 boxes and 53 collision bodies remain. Three same-pose 1080p image comparisons
found a maximum RGB channel difference of 1/255; fewer than 1% of pixels changed.
Instance-color packing explains these tiny differences; no effects were removed.

However, one consecutive baseline/optimized pair on AMD at High, 60 warmup and
120 recorded frames per view, with steady CPU sampling enabled, was mixed:

| View | Separate colors FPS | Consolidated FPS | Separate p95 ms | Consolidated p95 ms | Draw calls |
|---|---:|---:|---:|---:|---:|
| CT spawn | 25.9 | 26.6 | 50.5 | 40.6 | 678 → 440 |
| A site | 31.1 | 29.1 | 35.4 | 40.6 | 297 → 191 |
| Long doors | 30.4 | 27.2 | 42.0 | 49.0 | 649 → 418 |

This was not an alternating-order test or a controlled thermal/host-load study.
It does **not** establish a speedup. Original 8 m cells and separate materials
remain the shipping defaults. The temporary benchmark can enable experiments
with `--batch-cell=16 --color-batching`; `--no-color-batching` forces the baseline.
Artifacts: `map-review-browser-UEXfZf` and `map-review-browser-41ShZX`.

## Profile-guided computational work

The warmed CT-spawn baseline CPU profile (4.80 seconds) attributed approximately
61% of sampled time to WebGL `getParameter` and 19% to `checkFramebufferStatus`.
These synchronous calls may include GPU/driver waiting; the numbers are neither
JavaScript-arithmetic cost nor whole-match CPU attribution. Startup shader
compilation and screenshot readbacks are excluded by an explicit handshake.

An [isolated engine patch](../engine/README.md) investigates validating framebuffer
completeness only when attachments change. It retains rendering quality and is
not installed in the public engine. A shorter query profile would not suffice:
whole-frame improvements must be demonstrated because waiting can move elsewhere.

Operator invariant caching and selective terrain sampling reduced grounded pose
CPU time by about 17% in alternating native headless tests: about 0.08 ms total
across nine operators on this host. Foot sampling drops from 20 to 10 calls in
normal updates. Full animation cadence is preserved. This is not browser FPS
and cannot explain a roughly 29 ms frame by itself.

Bot updates now reuse two immediately repeated query results: successful path
shortcuts need one clearance scan instead of two, and the physics firing path
needs one world-sight check instead of two. Sight is never reused across movement
or ticks. Direct `shoot()` callers still validate sight, failed-contact semantics
remain unchanged, and friendly muzzle-obstruction checks remain. Focused tests
compare waypoint/replan decisions, shot arguments, contact state and RNG state.
This reduces actual computation without reducing AI cadence or changing aim;
it cannot explain a render-only fixture with AI disabled.

## Reproduce and inspect

From the repository root, with the official Godot web templates installed:

```sh
bash native-godot/tools/check.sh
bash native-godot/tools/build-web.sh
node native-godot/tests/browser.js
node native-godot/tests/map-review-browser.js --benchmark --compare-ssao --samples=90 --warmup=30 --width=1920 --height=1080 --capture --profile
```

The last command defaults to isolated Linux/software rendering. On WSL with
Windows Chrome, append `--windows-render-only` for a separate headless profile
with immutable pointer-lock/fullscreen denial and no input commands. Optional
`--high-performance-gpu` requests the discrete GPU only for that test process;
confirm `backend` in the results. Never enable host-input flags for profiling.

`artifacts/map-review-browser-*/` stores the separately exported test project,
raw `captures.json`, optional PNGs and `render.cpuprofile`. Load the CPU profile
in Chrome DevTools' JavaScript profiler. It includes startup, warmup and captures;
do not mistake loading/PNG-encoding work for steady gameplay cost. Release Wasm
symbols may limit attribution. The renderer's CPU timer includes driver waits;
zero GPU time means unavailable in this WebGL build, **not a free GPU**.

Prefer `--profile-steady` (without `--profile`) to save one named `.cpuprofile`
per measured segment. A handshake starts sampling after warmup and stops it before
JSON/PNG work. It still includes a small boundary wait around the timed section;
use `samples_ms` for frame-time statistics, not total CPU-profile duration.

Use `--compare` for a High/Balanced ABBA comparison; `--batch-cell=8|16|24` changes
only the temporary benchmark project. Test resources, profiles and documentation
are excluded from public game packs. No benchmark entry point enters the release.

Once 0.4.3 is deployed (it is currently a development candidate), refresh and confirm
`courtyard-0.4.3-frame-budget`, play for 30–60 seconds on High, press Escape,
and copy feedback details. Note the scene and whether slowdowns occur during
fights or grow over time. A 12-round accelerated lifetime check verifies that
round resets do not accumulate scene nodes; longer rendered matches still need
live measurements.

For screenshot-guided UI play, `node native-godot/tests/play-session.js` accepts
one JSON command per input line, for example `{"press":["Enter"]}` followed by
`{"keys":["KeyW"],"look":[60,0],"ms":800}` or `{"fire":true,"ms":400}`.
Commands are capped at two seconds; `{"quit":true}` closes the isolated browser,
and a six-minute watchdog bounds the session. The agent chooses actions from
screenshots, without enemy-position inspection or automatic aim. Software
rendering and screenshot turnaround limit responsiveness; this is not evidence
of human-level competitive play.

## Why not start with Rust or threads?

The engine already executes as WebAssembly; JavaScript is mostly browser glue.
Rust could help a demonstrated GDScript hotspot but does not remove post effects,
material switches or draw submissions. Compatibility skinning already uses GPU
transform feedback. CPU/GPU rendering times overlap, so they cannot simply be
added to predict FPS. Browser threading also requires a threaded template and
cross-origin isolation; it cannot safely wrap scene-tree/physics calls wholesale.
See [Godot web export](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)
and [thread-safe APIs](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html).
