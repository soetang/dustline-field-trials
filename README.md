# Dustline: Field Trials

A browser-based tactical FPS inspired by **Counter-Strike**, built with Rust, WebAssembly and the open-source Bevy engine. An experimental **Sol + Astra run**: an evolving AI-assisted game-development experiment, not a finished commercial game. This is an independent project, not affiliated with Valve.

Original code and procedural art are **MIT licensed**. External textures are **CC0**; dependency and font licenses are documented in [THIRD_PARTY.md](THIRD_PARTY.md). No proprietary game assets are included.

## Play

Serve this directory with any static web server:

```bash
python3 -m http.server 8765
```

Then open:

- `http://localhost:8765/bevy.html` — Rust + Bevy 3D preview
- `http://localhost:8765/` — original JavaScript gameplay build

The Bevy client now plays complete first-to-five matches. Four friendly bots and five attackers navigate the three lanes, fight with line-of-sight checks, recover dropped bombs, plant, retake, and defuse. The player has four purchasable weapons, automatic and semi-automatic fire, accurate headshots, reloads, aiming and an AWP scope, walking, crouching, round rewards, and spectating after death.

Bots now use a forward/peripheral view, short-lived last-seen and gunfire contacts, nearby teammate callouts, cover-aware repositioning, short bursts with reaction delays, and separate bomb recovery/defuse/cover roles. They stop tracking hidden targets and their bullets respect actual cover and crossing teammates. Routes use radius-aware corner smoothing and local spacing. Tab shows your surviving squadmates' current tasks, without exposing enemy tasks. Each new match has a fresh seed, included in the feedback report.

Wounded bots now finish their retreat and briefly hold cover before investigating
again. A passing teammate no longer interrupts an active defuse or resets its progress.

The browser interface includes a mission briefing, tactical radar, live kill feed, a ten-player scoreboard, clickable armory, hit and damage feedback, synthesized audio, match results, and a pause menu with saved sensitivity and volume. Escape and switching away from the browser pause the simulation.

The expanded Dustline arena is 64 × 48 metres (four times the original footprint). Staggered walls break the mid spawn sightline; the three routes, bot waypoints, radar, and sites use the same enlarged layout. Weapons, movement speeds, and operator sizes remain human-scale. Concrete floor and wall materials include normal maps and packed occlusion/roughness/metalness maps from [Poly Haven](https://polyhaven.com), under [CC0](https://polyhaven.com/license). Source URLs and checksums are recorded in `assets/textures/sources.json`.

Gentle rises now shape Long A, B tunnels and mid. The rendered ground, camera/operator heights, line of sight and bullet collisions share the same terrain triangles. Spawns and bomb sites remain flat. Try walking both side lanes and shooting uphill/downhill; report any sinking props, camera jolts or shots that disagree with visible cover.

The operator models are original Blender-authored GLBs with helmets, goggles, plate carriers, pouches, carbines, boots and hip-pivoted legs. They use four material primitives each; see `assets/models/README.md` for regeneration and validation. A gradient sky and batched sandstone ridges add depth beyond the arena. These are stylised models, not photorealistic scanned assets.

While testing, press Escape → **Copy test details** and paste the report into chat. Add what you did, what you expected, and what happened. A screenshot or short recording is useful. The report identifies the exact build and map, browser, render resolution, recent frame rate, and player position; nothing is uploaded automatically. The classic build remains at `/` for comparison.

For screenshots, press **F8** while playing, or choose **Screenshot view** in the pause menu. This pauses the match and hides the HUD and menu, even when a screenshot tool takes focus. Take the screenshot normally, then press Escape/F8 or click the small return button to get back to the pause menu. Choose Return to action when ready. If your chat/terminal cannot paste images, save the PNG/JPG locally and share its full file path instead.

For the expanded map, try both side routes as well as mid. Check that attackers are hidden at deployment, rotations are not excessively long, and you have useful cover when the first fight starts. Keep a playing tab open while development continues; refresh when you want the next published build.

## Build the Bevy client

The repository pins Rust 1.95 with the WebAssembly target. Install `wasm-bindgen-cli` 0.2.127, then run:

```bash
bash scripts/build-wasm.sh
```

Generated browser files are written to unique `web/builds/release-*` directories. `web/current.json` is updated only after a complete build, so a refresh during development cannot mix JavaScript and WebAssembly from different releases. Keep the release directory, its `snippets/` subdirectory, and the manifest together when copying the game to a static server.

The build now runs source/input/model checks before compiling and verifies the candidate JS/Wasm import pair before publishing it. A failed check leaves the previous release selected. Old unversioned Wasm files are not required by the release loader or build verification.

If startup fails, the error panel shows the specific cause and a retry button. Use an HTTP server, not a `file://` URL. The initial WebAssembly download is about 57 MB; the loader shows progress.

## Verify

Fast checks, without starting the renderer:

```bash
bash scripts/check.sh
```

These cover map connectivity, spawn separation/occlusion, every bot route to both sites, collision, weapon and economy rules, wall occlusion and headshots, bomb recovery and defusal, scored round resets, a complete autonomous match, HUD bindings, texture integrity, and every JavaScript function imported by the published WebAssembly module. The fast grid raycaster is compared against an exhaustive geometry reference for 2,000 deterministic rays.

After Rust rendering or browser-bridge changes, also run `cargo check --target wasm32-unknown-unknown --offline`. This catches integration/type errors without a full release build (fast once dependencies are cached).

For a fast real-browser check of the screenshot controls and focus-loss behaviour, run `npm run test:browser -- --ui-only`. It exercises the real HTML/CSS and mouse capture with a sample HUD packet, without loading the 3D renderer. It does not verify rendering or gameplay.

Use `npm run test:browser -- --startup-only` for the narrower 3D startup/material check without a full automated match interaction. The fast rules suite also checks that lamps have physical supports and that sky shots cannot create surface impacts.

Run `bash scripts/playtest-ai.sh` for 24 complete seeded simulation matches, alternating a spectator and a simple scripted test player. It checks collision/finite-state safety and match completion, exercises AI/bomb behaviour, and writes `artifacts/ai-playtest.json`. This harness is not a human difficulty rating and does not exercise the browser or GPU.

On a software-only GPU, use `npm run test:browser -- --performance` to run the real gameplay interaction suite with shadows disabled. The browser driver injects explicit relative mouse deltas to avoid its pointer-lock recentering warps; keyboard, clicks, captures and the actual Wasm simulation remain real. The normal in-game default keeps dynamic shadows. You can change this under Escape → Graphics.

Add `--playtest` to continue until the rendered match shows bot travel, combat damage and repositioning, and write `artifacts/browser-playtest.json`. Add `--capture-spawn` for a paused in-game screenshot at `artifacts/dustline-operators-spawn.png`.

For real browser interaction checks:

```bash
npm install
npx playwright install chromium
npm run test:browser
```

The browser test starts and closes its own local server. It verifies deployment, expanded-map metadata, texture loading, pointer capture, purchases, movement, shooting, reloads, aiming, scoreboard, pause/resume, feedback reports, restart, saved settings, and startup error handling. Use `CAPTURE=1 npm run test:browser` to save screenshots in `artifacts/`. Software-rendered browser tests are functional checks, not representative hardware-GPU performance measurements.

Run the original gameplay smoke test with:

```bash
node tests/smoke.js
```

## Controls

- `WASD` — move
- Mouse — aim
- Left click — fire
- Right click — aim / AWP scope
- `Shift` — walk
- `Ctrl` — crouch
- `R` — reload
- `E` — hold to defuse (5 seconds with your kit)
- `B` — open/close the armory; `1`–`4` or click to purchase
- `Tab` — hold for the scoreboard
- `C` — switch surviving squadmates while spectating
- `Esc` — release the mouse / pause
- `F8` — paused screenshot view (Escape/F8 returns to the menu)

Buy at CT spawn during the first 20 seconds of each round. The initial 7 seconds are preparation time. Friendly fire is off. Eliminating the attackers does not end a round while a planted bomb is still active.

Weapon accuracy depends on the weapon, movement, aiming, and recent firing. The M4 stays tighter during bursts than the AK; rapid Desert Eagle shots lose precision, while a stationary, scoped AWP is much more accurate than a moving or unscoped one. Sustained fire widens the crosshair and shot grouping, with a small upward bias; pausing between bursts restores precision. Test this against a wall from a fixed position: compare ten rapid shots with ten shots spaced about half a second apart.

## Desktop

The Rust source also has a native entry point (`cargo run --release`) and keyboard HUD. The browser is the primary tested client; the native UI is simpler. A native Linux build requires Bevy's system development dependencies, including Wayland, ALSA, and udev. The current workspace lacks the Wayland development library, so native compilation has not been verified here.
