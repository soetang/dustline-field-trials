# Dustline: Courtyard

**[Play the newest version — Courtyard](https://soetang.github.io/dustline-field-trials/courtyard/)**

An experimental **Sol + Astra run**: an open-source tactical FPS inspired by
Counter-Strike. Courtyard is the actively developed Godot edition: one original
Dust2-inspired desert map, 5v5 bot matches, animated operators, four weapons,
economy and bomb defusal. Browser and native desktop builds share the game.
Independent of Valve; not an exact map reproduction or finished competitive game.

![Courtyard running in the browser](courtyard/docs/browser-preview.png)

Actual browser capture, not concept art. Courtyard currently needs a keyboard
and mouse; graphics, AI and browser performance are still experimental.
[Native play and controls](courtyard/README.md) ·
[Operator animation study](courtyard/docs/grounded-motion.webm) (offline render, not gameplay FPS).

## Three separate apps

| Folder | Status | Play |
| --- | --- | --- |
| [courtyard/](courtyard/) | Newest; Godot, desktop/browser | [Courtyard](https://soetang.github.io/dustline-field-trials/courtyard/) |
| [bevy/](bevy/README.md) | Earlier Rust/WebAssembly edition; desktop/mobile | [Earlier edition](https://soetang.github.io/dustline-field-trials/) |
| [classic/](classic/) | Original JavaScript prototype | [Classic](https://soetang.github.io/dustline-field-trials/classic.html) |

Source folders are separate from public URLs. Existing bookmarks still work.
Shared browser helpers and site export live in `scripts/`; app code, assets,
tests and build tools stay with their app. Generated builds/caches are ignored.

## Work locally

From the repository root, with Node.js and Bash installed:

```sh
npm ci
npm run setup:courtyard
npm run test:fast                         # no browser, GPU or Rust compilation
npm run play:courtyard                    # native game
```

For the browser, run `npm run setup:courtyard -- --web` once, then
`npm run build` and `npm run serve`. Open **http://localhost:8765/**.
The first web setup downloads Godot's large export-template archive; it is not
shipped to players. See [Bevy instructions](bevy/README.md) for the older app.

```sh
npm test                                  # full Courtyard headless suite
npm run test:courtyard -- pose_reset       # one relevant suite
npm run test:courtyard -- --list            # discover suites without running them
npm run test:classic                       # fast JavaScript prototype checks
```

Pushes to `main` build and test the published site in GitHub Actions. Browser
playtests run there before deployment; failed checks leave the previous site live.
This folder reorganization does not reduce graphics or claim higher gameplay FPS.

## Feedback and licensing

In Courtyard, **F3** shows performance, **F8** saves a screenshot, and
**Escape → Copy feedback details** includes build, camera and live frame timings.
Send that report with what you tried and what looked wrong. Nothing is uploaded
automatically. Use the same graphics settings/window size for performance comparisons.

Original code, models, map geometry and generated audio are **MIT licensed**.
External textures are **Poly Haven CC0**; engine/dependency notices retain their
own licenses. No Valve assets, proprietary engine, sampled weapon sounds or
recorded soundtrack are included. See [LICENSE](LICENSE),
[provenance](THIRD_PARTY.md) and [Courtyard asset notices](courtyard/licenses/ASSET-SOURCES.txt).
