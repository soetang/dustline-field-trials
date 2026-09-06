# Isolated engine experiment — not the public runtime

The public export continues to use the verified official Godot 4.7.2 template.
Nothing here changes graphics quality, replaces installed templates or enables
browser threading. Patch contributions use this project's MIT license; Godot
retains its upstream MIT license and third-party notices.

`patches/cache-backbuffer-validation.patch` targets the exact
[Godot 4.7.2 source](https://github.com/godotengine/godot/tree/4.7.2-stable).
It validates framebuffer completeness on allocation/attachment changes instead
of repeating the query on every frame. Allocation, texture contents, rendering,
bind/unbind operations and allocation-time completeness handling remain unchanged.
Normal viewport reconfiguration clears
the IDs, so resizing and changing MSAA/format/view count require validation again.
Adding color to a depth-only buffer also validates. This does not add context-loss
recovery: unlike the original repeated query, it does not detect incompleteness
after successful allocation without an attachment change. The existing Web loss
handler requests reload, not recovery. Future attachment-storage mutations or
context restoration must invalidate this assumption. `configure_for_probe()`
does not clear IDs, but its only current caller uses a freshly allocated object;
reuse would need separate validation. "Unchanged storage" is a current source
invariant, not immutable GL storage enforced by the API.

## Reproducible comparison

Use an isolated source checkout with Emscripten **4.0.20** and SCons **4.9.1**.
Do not patch the official installed template or pair mismatched JS and Wasm.

```sh
scons platform=web target=template_release threads=no production=yes -j6
```

Keep the resulting baseline template ZIP separately. Apply the patch from this
directory to that source checkout with `git apply`, then repeat the same command
and keep a separate patched ZIP. Both must use identical toolchain/build flags;
comparing a custom compile only against the official binary would confound the
patch with build differences. The local scratch toolchain lives under ignored
`.tools/engine-lab/`, not in the distributed game.

The isolated render runner accepts `--engine-template=/absolute/path/to/template.zip`
alongside `--benchmark` or `--engine-lifecycle`. It exports a separate matched JS/Wasm runtime inside its
artifact directory, never overwrites the candidate or installed template, and
records both binary hashes in `captures.json`. Keep all other arguments identical
between baseline and patched runs. See [profiling instructions](../docs/performance.md).

Before considering release, test first allocation, depth-only → color+depth,
resize, MSAA/quality changes and failures. Compare warmed, alternating whole-frame
timings and screenshots at unchanged High settings. Removing one blocking query
may simply move GPU waiting to another call, so a shorter function profile is
not enough to demonstrate a speedup. This patch is currently an experiment,
not a deployed improvement.

## Fast regression checks and real WebGL lifecycle

```sh
node native-godot/tests/backbuffer-gl-audit-check.js
node native-godot/tests/engine-backbuffer-check.js --source /absolute/path/to/godot-4.7.2-stable
node native-godot/tests/map-review-browser.js --engine-lifecycle --capture --engine-template=/absolute/path/to/baseline.zip
node native-godot/tests/map-review-browser.js --engine-lifecycle --expect-cached-backbuffer --presentation-cache --capture --engine-template=/absolute/path/to/patched.zip
```

The optional C++ check pins the pristine source SHA-256, extracts the **actual**
original/patched `check_backbuffer()` and `_clear_back_buffers()` bodies, and
compiles a tiny GL-mock executable. It does not build Godot or change the source
checkout. It accepts the exact patch already applied, reversing it in memory;
missing source reports **SKIP**, never a fake pass or automatic download.
Eleven baseline-equivalence scenarios pass, plus an explicit test of the known
context-loss divergence. These include both attachment orders, unchanged storage,
clear/reallocation, failed allocations and null names. Full `configure()` ordering
is checked statically, not executed by the mock. This is not a driver test.

The separate browser fixture observes native calls without extra GL queries or
consuming `getError()`. Its observer has 154 fast forwarding/counter checks in
normal CI. Six rendered stages cover depth-only, adding color, resize, 2× MSAA,
4× MSAA and restoration. Counts describe the whole owned context, not uniquely
the patched backbuffer. Completeness does not prove correct draws; compare PNGs
as well. Restoration combines MSAA-off and resize; it does not test context loss
or hardware multiview. The optional `scene=engine` remote review checks the
official runtime; no custom compiler or runtime is installed in CI.

In the first local Windows/AMD run, both configurations passed 62 assertions.
Baseline steady validation was 12 checks per stage versus zero with the patch;
setup/reconfiguration still validated. All six baseline/patched+presentation-cache
PNGs were byte-identical. Restored matched depth-and-color as well. Later checks
also require retained depth storage, actual MSAA sample-count calls and resized
PNG dimensions. These correctness results do not establish an FPS gain.

## First matched-engine measurements

Both templates use Emscripten 4.0.20, SCons 4.9.1 and the flags above. Preserved
ZIP SHA-256 values:

- Baseline: `83c4b6013ecd98b13d8cbdbe6fdb5e514be5f48644f93490024497bfe9839656`
- Patched: `170919d88ceb777efc7f97ce836769327fdf1369735d78a93953bc59bc8d3c69`

The patched Wasm is 39,512,683 bytes, just 43 bytes larger; its JS is unchanged.
This custom build is not directly size-comparable to the official release.
The first 90-frame, three-view High 1920×882 comparison used warmed CPU sampling
and sparse GPU intervals, with the crate prototype disabled. The C++ patch alone
removed the repeated validation from the hot profile, but **did not show a clear
whole-frame gain**: mean FPS was 27.39/29.23/25.64 baseline versus
26.12/30.11/25.80 patched (spawn/A site/long doors). All three PNGs were identical.
Much of the sampled wait moved to presentation-state `getParameter` calls.
Only one baseline then patched pass was taken, separated by compilation; this
is diagnostic evidence, not a controlled speedup claim.

`--presentation-cache` additionally enables the test-only state cache for a
render/lifecycle fixture and validates it against native state after the run.
Combining it with the patch gave 28.87/35.24/29.24 FPS in a first instrumented
pass. This needs alternating, uninstrumented controls: the GPU observer itself
uses native disjoint-state queries and can change synchronization. See
[performance notes](../docs/performance.md); neither experiment is public.
