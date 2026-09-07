#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo_dir="$(cd .. && pwd)"
# Keep the playable manifest untouched; capture tooling explicitly opts into
# this separate, feature-gated build. Normal Pages exports never select it.
cargo build --release --target wasm32-unknown-unknown --features offline-capture
mkdir -p web/builds "$repo_dir/artifacts"
capture_dir="$(mktemp -d web/builds/release-capture-XXXXXXXX)"
wasm-bindgen --target web --no-typescript --remove-name-section --out-dir "$capture_dir" target/wasm32-unknown-unknown/release/desert_strike.wasm
node tests/client-check.js "./$capture_dir/desert_strike.js"
node -e 'const fs=require("node:fs");fs.writeFileSync(process.argv[2],JSON.stringify({entry:"./"+process.argv[1]+"/desert_strike.js"}));' "$capture_dir" "$repo_dir/artifacts/capture-engine.json"
echo "Capture-only engine ready. The normal playable release has not changed."
