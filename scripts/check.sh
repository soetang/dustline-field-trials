#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
node tests/workspace-check.js
node tests/serve-check.js
node tests/check-runner.js
node tests/browser-options.js
node classic/tests/smoke.js
bash bevy/scripts/check.sh --js-only
if (($# == 0)); then set -- --fast; fi
bash courtyard/tools/check.sh "$@"
