#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

bash scripts/check.sh --source-only
cargo build --release --target wasm32-unknown-unknown
node tests/engine-features.js
mkdir -p web/builds
build_dir="$(mktemp -d web/builds/release-XXXXXXXX)"
bindgen_options=()
if [[ "${KEEP_WASM_NAMES:-0}" != "1" ]]; then bindgen_options+=(--remove-name-section); fi
wasm-bindgen \
  --target web \
  --no-typescript \
  "${bindgen_options[@]}" \
  --out-dir "$build_dir" \
  target/wasm32-unknown-unknown/release/desert_strike.wasm

# Publish a complete, immutable JS/Wasm pair. A player refreshing during a build
# continues using the previous release until this atomic manifest replacement.
node tests/client-check.js "./$build_dir/desert_strike.js"
node -e 'const fs = require("node:fs"); const entry = "./" + process.argv[1] + "/desert_strike.js"; fs.writeFileSync("web/current.json.tmp", JSON.stringify({entry})); fs.renameSync("web/current.json.tmp", "web/current.json");' "$build_dir"

echo "Built playable Rust/Bevy client: http://localhost:8765/bevy.html"
