#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d /tmp/desert-strike-check.XXXXXX)"
rustc --edition=2024 --test src/rules.rs -o "$check_dir/rules-tests"
"$check_dir/rules-tests"
node --check client.js
node --check touch-controls.js
node --input-type=module --check < boot.js
node tests/boot-streaming.js
if [[ "${1:-}" != "--source-only" ]]; then node tests/client-check.js; fi
node tests/client-input.js
node tests/touch-input.js
node tests/models-check.js
node tests/capture-tools.js
node tests/browser-options.js
node tests/smoke.js
echo "Fast checks passed. Browser integration: npm run test:browser"
