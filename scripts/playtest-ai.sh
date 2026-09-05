#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
playtest_dir="$(mktemp -d /tmp/desert-strike-playtest.XXXXXX)"
rustc --edition=2024 -O tests/ai-playtest.rs -o "$playtest_dir/ai-playtest"
"$playtest_dir/ai-playtest"
