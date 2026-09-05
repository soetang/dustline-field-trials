#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
godot_bin="${GODOT_BIN:-$project_dir/../.tools/godot/4.7.2/Godot_v4.7.2-stable_linux.x86_64}"
if [[ ! -x "$godot_bin" ]]; then
  echo 'Install Godot first: bash native-godot/tools/setup.sh' >&2
  exit 1
fi
mkdir -p "$project_dir/../artifacts"
log_dir="$(mktemp -d "$project_dir/../artifacts/godot-check-XXXXXX")"
# Godot may exit 0 after script parse errors. Check both logs and explicit sentinel.
"$godot_bin" --headless --path "$project_dir" --editor --import 2>&1 | tee "$log_dir/import.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:' "$log_dir/import.log"; then exit 1; fi
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/verify.gd -- --test 2>&1 | tee "$log_dir/tests.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/tests.log"; then exit 1; fi
grep -Eq '^VERIFICATION: [0-9]+/[0-9]+ passed' "$log_dir/tests.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/tactics.gd -- --test 2>&1 | tee "$log_dir/tactics.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/tactics.log"; then exit 1; fi
grep -Eq '^TACTICS: [0-9]+/[0-9]+ passed' "$log_dir/tactics.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/input.gd -- --test 2>&1 | tee "$log_dir/input.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/input.log"; then exit 1; fi
grep -Eq '^INPUT: [0-9]+/[0-9]+ passed' "$log_dir/input.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/combat.gd -- --test 2>&1 | tee "$log_dir/combat.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/combat.log"; then exit 1; fi
grep -Eq '^COMBAT: [0-9]+/[0-9]+ passed' "$log_dir/combat.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/rounds.gd -- --test 2>&1 | tee "$log_dir/rounds.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/rounds.log"; then exit 1; fi
grep -Eq '^SEEDED_ROUNDS: [0-9]+/[0-9]+ passed' "$log_dir/rounds.log"
echo "Logs: $log_dir"
