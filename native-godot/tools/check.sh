#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
godot_bin="${GODOT_BIN:-$project_dir/../.tools/godot/4.7.2/Godot_v4.7.2-stable_linux.x86_64}"
if [[ ! -x "$godot_bin" ]]; then
  echo 'Install Godot first: bash native-godot/tools/setup.sh' >&2
  exit 1
fi
log_dir="$(mktemp -d "$project_dir/../artifacts/godot-check-XXXXXX")"
# Godot may exit 0 after script parse errors. Check both logs and explicit sentinel.
"$godot_bin" --headless --path "$project_dir" --editor --import 2>&1 | tee "$log_dir/import.log"
if rg -q 'SCRIPT ERROR:|^ERROR:' "$log_dir/import.log"; then exit 1; fi
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/verify.gd -- --test 2>&1 | tee "$log_dir/tests.log"
if rg -q 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/tests.log"; then exit 1; fi
rg -q '^VERIFICATION: [0-9]+/[0-9]+ passed' "$log_dir/tests.log"
echo "Logs: $log_dir"
