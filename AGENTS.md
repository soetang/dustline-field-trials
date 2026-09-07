# Working map

- Active game: `courtyard/` (Godot). Earlier apps: `bevy/` (Rust/Wasm), `classic/` (JavaScript).
- Start scoped searches in the relevant app; do not scan caches, generated builds, binary assets or license bundles unless needed.
- Courtyard gameplay: `scripts/game.gd` coordinates; `bot.gd` AI; `operator_rig.gd` animation; `world.gd` geometry; `render_budget.gd` and `frame_metrics.gd` performance.
- Tests and build/authoring tools belong beside their app. Root `scripts/` contains shared browser isolation, local serving and site export only.
- Fast check: `npm run test:fast`. Focused Godot check: `npm run test:courtyard -- pose_reset`; discover names with `--list`. Full checks: `npm test`.
- Do not run GPU/browser tests or native compilers on this machine while the user may be playing. Use headless CPU checks and remote GitHub workflows; never capture the host mouse.
- Preserve public URLs independently of source-folder layout. Export allowlists, licenses and immutable JS/Wasm pairs must remain verified.
- Keep documentation concise. Prefer executable regression tests and ignored JSON evidence to new Markdown reports.
