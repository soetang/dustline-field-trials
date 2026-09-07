#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  ''|--source-only|--js-only) ;;
  *) echo "Usage: $0 [--source-only|--js-only]" >&2; exit 2 ;;
esac
if [[ "${1:-}" != "--js-only" ]]; then
  check_dir="$(mktemp -d /tmp/desert-strike-check.XXXXXX)"
  rustc --edition=2024 --test src/rules.rs -o "$check_dir/rules-tests"
  "$check_dir/rules-tests"
fi
node --check client.js
node --check touch-controls.js
node --input-type=module --check < boot.js
node tests/boot-streaming.js
if [[ -z "${1:-}" ]]; then node tests/client-check.js; else node tests/client-check.js --js-only; fi
node tests/client-input.js
node tests/touch-input.js
node tests/models-check.js
node tests/capture-tools.js
echo "Bevy checks passed. Browser integration: npm run test:browser:bevy (repository root)"
