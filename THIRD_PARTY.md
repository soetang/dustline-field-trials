# Open-source code and open assets

Original game code, procedural models, model-generation scripts, interface art,
map geometry, and project screenshots/recordings are under the root MIT license.
The Blender scripts are the editable source for the included GLB models.
Audio is synthesized in code; there are no sampled commercial sounds.
The interface uses system fonts, with no remote font service.

## External assets

- The six concrete JPEG textures are from **Poly Haven**, under **CC0-1.0**.
  Exact source URLs, sizes and checksums: [Bevy texture manifest](https://github.com/soetang/dustline-field-trials/blob/main/bevy/assets/textures/sources.json)
  and [Courtyard texture manifest](https://github.com/soetang/dustline-field-trials/blob/main/courtyard/assets/textures/sources.json).
  [Poly Haven license](https://polyhaven.com/license).
- Bevy's embedded **Fira Mono** font is under **SIL Open Font License 1.1**;
  its notice is included in `bevy/licenses/FiraMono-OFL.txt` (published at `licenses/`).
- Courtyard uses the MIT-licensed Godot engine. Its engine, dependency and font
  notices are in [Courtyard licenses](https://github.com/soetang/dustline-field-trials/tree/main/courtyard/licenses).
- No Counter-Strike/Valve models, maps, textures, logos, or sounds are included.
  Counter-Strike is mentioned only as an inspiration; this is an independent
  experiment, not an official or affiliated product.

An unused local `sandstone-plaster.png` experiment has no recorded provenance.
It is ignored by Git, unused by the game, and excluded from the website export.

## Software

Bevy is MIT/Apache-2.0, Rust is MIT/Apache-2.0, wasm-bindgen is MIT/Apache-2.0,
and the Playwright test tools are Apache-2.0. Blender (GPL-3.0-or-later) is an
optional authoring tool, not bundled with the game. Generated original artwork
is covered by this project's MIT license, not Blender's application license.
Third-party dependencies retain their own licenses; MIT does not relicense them.

`bevy/licenses/rust-dependencies.txt` records the resolved browser/build dependency
licenses and packaged notices. From `bevy/`, regenerate after changing `Cargo.lock`:

```sh
cargo metadata --locked --format-version=1 --filter-platform=wasm32-unknown-unknown | node scripts/license-report.js
```

The release exporter copies these notices with the playable website and copies
only Bevy assets explicitly listed in `bevy/assets/manifest.json`. Courtyard has
a separate verified runtime-file allowlist; its original assets and CC0 copies
are documented in `courtyard/licenses/ASSET-SOURCES.txt`.
