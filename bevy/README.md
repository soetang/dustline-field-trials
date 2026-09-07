# Dustline: Field Trials — earlier Rust edition

[Play desktop/mobile](https://soetang.github.io/dustline-field-trials/) ·
[Newest Courtyard edition](../courtyard/README.md)

Earlier experimental Sol + Astra tactical FPS built with Rust, Bevy and
WebAssembly. 5v5 bot defusal, four weapons, a three-lane desert arena and original
Blender models. This app is independent of Courtyard and keeps its existing URL.

## Build and test

Install rustup and Node.js; `rust-toolchain.toml` pins Rust and the Wasm target.
From this folder, install the matching generator once:

```sh
cargo install wasm-bindgen-cli --version 0.2.127 --locked
```

Then from the repository root:

```sh
npm ci
npm run build:bevy
npm run serve
# Open http://localhost:8765/bevy/bevy.html
npm run test:bevy
npm run test:browser:bevy -- --performance --playtest
```

`bash bevy/scripts/check.sh --js-only` skips Rust/Wasm compilation for quick UI,
input and asset checks. `bash bevy/scripts/playtest-ai.sh` runs seeded Rust matches.
Browser tests use the shared protected launcher and must not run on a busy GPU.
Immutable JS/Wasm pairs live in `web/builds/`; `web/current.json` switches only
after verification. No generated release or compiler cache belongs in Git.

## Play and feedback

WASD/mouse, left click fire, right click aim, R reload, B buy, E defuse,
Shift walk, Ctrl crouch, Escape pause. Phones: landscape, left movement stick,
swipe to look, tap to fire or drag FIRE while shooting. PAUSE → TEST SOUND
retries generated audio if needed. No recorded weapon sound files are used.
Escape → Copy test details supplies build/device/input diagnostics.

[Archived gameplay video](https://soetang.github.io/dustline-field-trials/watch.html?v=smooth-20260905)
([download](../docs/media/gameplay.webm)) shows this Bevy edition, **not Courtyard**.
It is a silent automated-input capture, not a performance guarantee.

Original code/models are covered by the root [MIT license](../LICENSE).
[Texture sources](assets/textures/sources.json) are Poly Haven CC0;
[third-party notices](licenses/) retain upstream licenses. Model generators live
in `scripts/make-operators.py` and `scripts/make-weapons.py`.
