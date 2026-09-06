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
alongside `--benchmark`. It exports a separate matched JS/Wasm runtime inside its
artifact directory, never overwrites the candidate or installed template, and
records both binary hashes in `captures.json`. Keep all other arguments identical
between baseline and patched runs. See [profiling instructions](../docs/performance.md).

Before considering release, test first allocation, depth-only → color+depth,
resize, MSAA/quality changes and failures. Compare warmed, alternating whole-frame
timings and screenshots at unchanged High settings. Removing one blocking query
may simply move GPU waiting to another call, so a shorter function profile is
not enough to demonstrate a speedup. This patch is currently an experiment,
not a measured or deployed improvement.
