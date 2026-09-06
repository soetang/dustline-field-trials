# Browser performance: 0.4.3–0.4.5

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

We separate four kinds of evidence:

- Real keyboard/mouse browser smoke tests exercise startup, controls, audio,
  screenshots and pause. They do not represent a competitive human match.
- Fixed-camera render fixtures keep geometry, resolution and nine animated
  operators constant, without AI, physics, HUD or audio. Screenshots occur
  outside the timed region. These measure rendering, not full-match performance.
- Live feedback samples monotonic frame intervals, preserving stalls and
  excluding pause/buy gaps. p95/p99 describe slow frames, not just average FPS.
- An instrumented nine-bot round runs normal gameplay with an idle player and
  muted audio. Test-only nested probes identify costly callbacks; this is not
  human play or a pure GDScript-VM/GPU measurement.

## Live gameplay CPU attribution (before navigation clearance optimization)

2026-09-06, Windows headless Chrome on AMD integrated graphics, High, full-scale
1280×720, four shadow cascades and SSAO retained. Four 12-second windows reset
seed 512 and run recorder off → on → on → off. The idle player's camera stays
at CT spawn. Import, warmup, JSON and screenshots are outside timing. The engine
compiler was paused and no other agent-owned renderer ran during measurement.

| Scope | Measured self ms / rendered frame, two recorded windows |
|---|---:|
| AI path clearance (`layout.segment_clear`) | 13.56 / 13.31 |
| Bot physics, excluding nested scopes | 2.80 / 2.72 |
| Operator pose, excluding nested scopes | 0.53 / 0.53 |
| Player physics, excluding nested scopes | 0.42 / 0.41 |
| HUD drawing | 0.38 / 0.39 |
| Weapon clearance | 0.17 / 0.16 |

The recorded windows ran 720 / 722 physics ticks, 265 / 267 rendered frames,
35 bot shots and approximately 352 / 353 m aggregate bot travel. About 7,200
path-clearance calls consumed 3.55–3.59 seconds per window. This establishes a
substantial live-gameplay calculation target that render-only profiling missed.
The entire bot animation callback, including nested pose and weapon work, cost
about 1.01–1.02 ms per rendered frame. Do not add inclusive and nested costs.

Mean FPS in the four windows was 21.19 / 22.08 / 22.19 / 22.66; p95 intervals
were 79.3 / 76.0 / 75.3 / 72.8 ms. The disabled controls retain wrapper dispatch
overhead and are not pristine production code. This sequence checks recorder
impact, not an optimization speedup; warmup/host timing can explain differences.
"Self" subtracts nested instrumented scopes but still includes native calls and
some instrumentation overhead. The browser clock also has limited precision.
These are not pure VM times, total CPU time, or GPU timings. At ~22 rendered FPS
and 60 Hz physics there are ~2.7 physics ticks per rendered frame.

Local raw evidence: `artifacts/map-review-browser-NtfxdJ/captures.json`, with
scope counts, per-frame samples, renderer settings and instrumentation mapping.
Reproduce without accessing the desktop mouse:

```sh
node native-godot/tests/map-review-browser.js --gameplay-profile --windows-render-only --duration=12 --width=1280 --height=720 --capture
```

Omit `--windows-render-only` for Linux correctness runs; software-renderer FPS
does not predict hardware speed. The runner instruments only an isolated copy,
denies pointer lock/fullscreen and all host-input commands, and excludes probes
from the public pack. Fast checks cover nested timing, bounded storage and
enabled/disabled GDScript wrapper semantics.

## 0.4.5: exact navigation broad phase, unchanged graphics

The measured hotspot repeatedly checked five room-union samples, sixteen cover
rectangles, four rotated doors and four supports at every 0.22 m path sample.
The new 31,680-byte table records an answer only if a whole half-metre tile can
be proven clear or blocked. Clear tiles require their radius-expanded area to
lie entirely inside the room union and outside conservatively expanded obstacle
bounds. Mixed tiles still execute the original predicate. The table does not
quantize positions, change sample spacing, modify obstacles, reduce AI update
frequency or reuse stale results after movement. Other clearance radii and
unsupported future layouts retain the original calculation. Geometry is static;
future movable navigation obstacles would need invalidation or separate queries.

The fast differential test passes 595,069 checks, including 582,031 clearance
comparisons, 5,100 bidirectional/threshold segments and all 7,920 AStar cells.
It tests actual neighbouring float32 values at every half-cell corner, rotated
door edges, nine radii, nonfinite inputs and unsupported-layout fallback. There
are zero false-clear or false-blocked results. Four full seeded rounds also
retain identical timing, shots, survivors, aggregate travel and zero stall
windows compared with 0.4.4. Existing body and weapon wall regressions pass.
On this host the differential check takes ~5.7 seconds including its optional
native microbenchmark; cold lookup initialization took ~77 ms natively (not a
browser startup measurement). The byte table contains 14,470 clear, 13,076
blocked and 4,134 mixed cells. It is built once, not allocated per frame.

The same-browser reference → lookup → lookup → reference test retained the
settings and 12-second seeded rounds above. All four windows had probes enabled.
Only the point predicate inside `segment_clear` switches; the reference executes
the original calculation. Both routes share the test-only dispatch branch.
The engine compiler remained paused; no other agent renderer or regression
process ran during the measurements. The idle player can die normally.

| Window | Mean FPS | p95 / p99 ms | Path µs / call | Frames >100 ms |
|---|---:|---:|---:|---:|
| Reference before | 19.47 | 100.9 / 112.0 | 565.2 | 13 |
| Lookup before | 28.74 | 43.9 / 48.9 | 98.4 | 0 |
| Lookup after | 30.45 | 38.7 / 44.6 | 88.8 | 0 |
| Reference after | 20.83 | 91.9 / 114.0 | 558.9 | 5 |

Across the two windows each, this is ~83% lower path-check cost per call and
~47% higher mean FPS in this fixture. Path cost per physics tick falls from
5.59–5.68 ms to 0.89–0.98 ms. Reporting per-call and per-tick avoids crediting
the higher rendered-frame count as extra computational savings. Draw calls stay
around 945; small averages differ because rendered frames sample moving actors
at different times. Every window fires 35 bot shots; physics ticks range from
705–722 because the windows end at render boundaries. There are no graphics
changes. This short, instrumented 720p test is not a 1080p/60 FPS result or proof
against thermal/long-session degradation. Host timing and instrumentation still
affect absolute numbers; the independent recorder-control run measured ~31 FPS.

[Raw frame intervals and CPU scopes](performance-navigation-abba.json) record
the actual renderer, High settings and sample counts. The candidate was measured
before its build label changed from 0.4.4 to 0.4.5. Reproduce with:

```sh
node native-godot/tests/map-review-browser.js --gameplay-profile --navigation-abba --windows-render-only --duration=12 --width=1280 --height=720 --capture
```

This removes redundant computation before considering a compiled port. The
remaining navigation cost is much smaller; a C++/Rust kernel should now be
judged against this optimized baseline, not the avoidably expensive old loop.

## 0.4.5 live feedback and remaining presentation waits

Two manual High 1920×882 feedback windows on AMD integrated graphics measured
28.51 / 28.48 mean FPS, p95 42.2 / 44.2 ms, and p99 48.4 / 72.8 ms over
53.5 / 63.2 seconds. Both included occasional >100 ms stalls. They are different
routes/views, not a controlled local-vs-Pages comparison or a long-run guarantee.
They support improved smoothness but do not meet the 60 FPS target.

A fresh four-window warmed browser CPU profile at that resolution kept the
engine compiler paused and used the normal AI fixture. In the later windows,
about 47% of sampled time was in `getParameter`, specifically Emscripten's
`blitOffscreenFramebuffer` during frame presentation, and about 19–20% in
`checkFramebufferStatus`. The path-check probe measured about 0.88 ms per
physics tick. These synchronous browser APIs can include GPU/driver waits;
their profile share is not a promise of equivalent removable computation.
Local evidence: `artifacts/map-review-browser-5KQv8t/`, with separate warmed
`.cpuprofile` files; startup and capture/summary work are outside the handshake.

The [test-only presentation cache](../engine/experiments/presentation-state-cache.js)
tracks scissor enable and draw-framebuffer binding through owned-context calls.
All unrelated queries, rendering, textures and GL errors stay native. It starts
disabled and is **not loaded by the public game**. A fast fake-WebGL state model
passes 2,857 checks, including numeric coercion, invalid/deleted/foreign handles,
borrowed receivers, pre-event context loss and restoration. Direct native-prototype
calls bypassing the wrappers require explicit invalidation; this is not a general
drop-in cache for arbitrary third-party WebGL clients.

The initial native → cache → cache → native trial passed real-context state
validation in all four windows. Native getters fell from roughly two per frame
to zero in cached windows, but framebuffer-check sampled time rose from ~21%
to ~50–52%: much of the wait moved rather than vanished. Mean FPS was
15.32 / 17.76 / 16.93 / 15.86; p99 remained about 145–153 ms. The lower absolute
rates differ substantially from the earlier profile, and host load was not
controlled. More importantly, screenshot review exposed another confound: the
idle player's death-camera height depends on simulation progress at the end of
each timed window. Those pictures are not identical-view comparisons.
**This trial does not justify shipping the cache or claiming a reliable speedup.**
Local artifacts: `artifacts/map-review-browser-AlnvCR/`.

The fixture now pins a separate observer camera before rendering, retaining
normal actor, death and spectator callbacks. It records the pose and asserts
that all windows have identical camera metadata. Historical captures above
predate this correction; navigation's differential geometry/per-call evidence
still stands, but future whole-frame comparisons should use the fixed view.

```sh
node native-godot/tests/presentation-state-cache-check.js
node native-godot/tests/map-review-browser.js --gameplay-profile --presentation-abba --profile-steady --windows-render-only --duration=12 --width=1920 --height=882 --capture
```

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

Room-union membership now uses an exact 7,920-byte lookup for the current
integer-edged layout, replacing repeated 16-rectangle scans. Negative coordinates
and half-open room edges retain the original semantics; fractional or unsupported
future layouts fall back to the original predicate. Tests compare 38,255 points,
five clearance radii and every navigation cell. This changes neither collision
geometry nor path sampling, and is not yet a measured browser-FPS improvement.

## Weapon clearance: correctness cost, not a performance optimization

The 0.4.4 wall fix reuses one box and two query parameter objects per weapon.
It checks the entire weapon hull plus a connection ray, with a bounded search
only at contact. No scene nodes, textures or draw calls are added. A contact-plane
correction handles diagonal walls and uphill ground without hiding the weapon.
Open operator poses bypass the world/local round-trip and remain unchanged.

On this host, the final five warmed 240-frame native grounded-idle samples measured
40.64 → 44.21 µs per operator in open space (two queries), and 41.40 → 72.32 µs
at wall contact (12 queries). An earlier run measured 39.70 → 51.24 and
40.40 → 71.86 µs respectively: host timing varies, particularly for small deltas.
That is approximately 0.03–0.10 ms added across nine open-space operators and
0.28 ms across nine contact poses. These are sequential native implementation-cost
samples, not browser FPS, a whole-match measurement or a worst-case GPU budget.
The full geometric weapon test plus optional `--cpu-sample` takes about 3.8 seconds
on this host; 26,398 assertions cover 3,240 player and 1,300 rig poses.

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

Prefer `--profile-steady` (without `--profile`) with `--benchmark` or
`--gameplay-profile` to save one named `.cpuprofile`
per measured segment. A handshake starts sampling after warmup and stops it before
JSON/PNG work. It still includes a small boundary wait around the timed section;
use `samples_ms` for frame-time statistics, not total CPU-profile duration.

An optional `Courtyard visual review (no deployment)` GitHub workflow renders
on the remote runner, not the development machine. Dispatch with `scene=map`
for five views, `scene=walls` for twelve wall checks, or `scene=cpu` for a short
fixed-camera profiling-fixture check. Download that run's screenshot/JSON/log
artifact. Its software renderer is for correctness and visual review, never
hardware performance claims. It has no Pages write/deployment permission.
The short CPU-fixture CI mode uses three warmup frames; normal profiling defaults
to thirty. Gameplay windows collect at least twelve real frames, extending a
short requested duration on very slow software renderers. Actual wall duration,
requested duration and warmup count are recorded; no missing frames are invented.

Use `--compare` for a High/Balanced ABBA comparison; `--batch-cell=8|16|24` changes
only the temporary benchmark project. Test resources, profiles and documentation
are excluded from public game packs. No benchmark entry point enters the release.

After the 0.4.5 Pages deployment succeeds, refresh and confirm
`courtyard-0.4.5-navigation-lookup`, play for 30–60 seconds on High, press Escape,
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

The engine executes as WebAssembly; JavaScript is mostly browser glue. **Our
GDScript does not thereby become compiled WebAssembly:** its bytecode still runs
in the engine's script VM. See the [pinned GDScript architecture](https://github.com/godotengine/godot/blob/4.7.2-stable/modules/gdscript/README.md).
Heavy script loops are legitimate candidates for compiled C++ or Rust. Godot's
built-in rendering/physics operations already run in the compiled engine, however;
changing their calling language does not make those operations faster. A useful
experiment moves a measured script-heavy batch across the boundary and compares
whole-frame timings, not just a standalone arithmetic loop. See
[Godot's CPU optimization guidance](https://docs.godotengine.org/en/stable/tutorials/performance/cpu_optimization.html).

Godot 4 C# projects currently cannot export to the web. GDExtension web projects
need Extension Support enabled and a matching web-compiled extension; the current
release has extension support disabled. A compiled experiment therefore needs
its own compatible runtime/package, or a statically built engine module. It must
retain the working release until startup, size, behavior and frame-time comparisons
pass. Compiled gameplay does not remove post effects, material switches or draw
submissions. Compatibility skinning already uses GPU
transform feedback. CPU/GPU rendering times overlap, so they cannot simply be
added to predict FPS. Browser threading also requires a threaded template and
cross-origin isolation; it cannot safely wrap scene-tree/physics calls wholesale.
See [Godot web export](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_web.html)
and [thread-safe APIs](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html).
