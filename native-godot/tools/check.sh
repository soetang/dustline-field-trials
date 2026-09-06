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
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/aim.gd -- --test 2>&1 | tee "$log_dir/aim.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/aim.log"; then exit 1; fi
grep -Eq '^AIM: [0-9]+/[0-9]+ passed' "$log_dir/aim.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/encounters.gd -- --test 2>&1 | tee "$log_dir/encounters.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/encounters.log"; then exit 1; fi
grep -Eq '^ENCOUNTERS: [0-9]+/[0-9]+ passed' "$log_dir/encounters.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/query_reuse.gd -- --test 2>&1 | tee "$log_dir/query-reuse.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/query-reuse.log"; then exit 1; fi
grep -Eq '^QUERY_REUSE: [0-9]+/[0-9]+ passed' "$log_dir/query-reuse.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/room_lookup.gd -- --test 2>&1 | tee "$log_dir/room-lookup.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/room-lookup.log"; then exit 1; fi
grep -Eq '^ROOM_LOOKUP: [0-9]+/[0-9]+ passed' "$log_dir/room-lookup.log"
"$godot_bin" --headless --path "$project_dir" --script res://tests/navigation_clearance.gd -- --test 2>&1 | tee "$log_dir/navigation-clearance.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/navigation-clearance.log"; then exit 1; fi
grep -Eq '^NAVIGATION_CLEARANCE: [0-9]+/[0-9]+ passed' "$log_dir/navigation-clearance.log"
"$godot_bin" --headless --path "$project_dir" --script res://tests/cpu_profile_check.gd -- --test 2>&1 | tee "$log_dir/cpu-profile.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/cpu-profile.log"; then exit 1; fi
grep -Eq '^CPU_PROFILE: [0-9]+/[0-9]+ passed' "$log_dir/cpu-profile.log"
GODOT_BIN="$godot_bin" node "$project_dir/tests/profile-instrumentation-check.js" 2>&1 | tee "$log_dir/profile-instrumentation.log"
node "$project_dir/tests/presentation-state-cache-check.js" 2>&1 | tee "$log_dir/presentation-state-cache.log"
node "$project_dir/tests/gpu-timer-probe-check.js" 2>&1 | tee "$log_dir/gpu-timer-probe.log"
node "$project_dir/tests/backbuffer-gl-audit-check.js" 2>&1 | tee "$log_dir/backbuffer-gl-audit.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/wall_collision.gd -- --test 2>&1 | tee "$log_dir/wall-collision.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/wall-collision.log"; then exit 1; fi
grep -Eq '^WALL_COLLISION: [0-9]+/[0-9]+ passed' "$log_dir/wall-collision.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/weapon_walls.gd -- --test 2>&1 | tee "$log_dir/weapon-walls.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/weapon-walls.log"; then exit 1; fi
grep -Eq '^WEAPON_WALLS: [0-9]+/[0-9]+ passed' "$log_dir/weapon-walls.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/operators.gd -- --test 2>&1 | tee "$log_dir/operators.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/operators.log"; then exit 1; fi
grep -Eq '^OPERATORS: [0-9]+/[0-9]+ passed' "$log_dir/operators.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/feet.gd -- --test 2>&1 | tee "$log_dir/feet.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/feet.log"; then exit 1; fi
grep -Eq '^FEET: [0-9]+/[0-9]+ passed' "$log_dir/feet.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/map_update.gd -- --test 2>&1 | tee "$log_dir/map.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/map.log"; then exit 1; fi
grep -Eq '^MAP_UPDATE: [0-9]+/[0-9]+ passed' "$log_dir/map.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/material_batches.gd -- --test 2>&1 | tee "$log_dir/material-batches.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/material-batches.log"; then exit 1; fi
grep -Eq '^MATERIAL_BATCHES: [0-9]+/[0-9]+ passed' "$log_dir/material-batches.log"
timeout 20s "$godot_bin" --headless --path "$project_dir" --script res://tests/crate_mesh.gd 2>&1 | tee "$log_dir/crate-mesh.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/crate-mesh.log"; then exit 1; fi
grep -Eq '^CRATE_MESH: [0-9]+/[0-9]+ passed' "$log_dir/crate-mesh.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/input.gd -- --test 2>&1 | tee "$log_dir/input.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/input.log"; then exit 1; fi
grep -Eq '^INPUT: [0-9]+/[0-9]+ passed' "$log_dir/input.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/combat.gd -- --test 2>&1 | tee "$log_dir/combat.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/combat.log"; then exit 1; fi
grep -Eq '^COMBAT: [0-9]+/[0-9]+ passed' "$log_dir/combat.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/audio.gd -- --test 2>&1 | tee "$log_dir/audio.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/audio.log"; then exit 1; fi
grep -Eq '^AUDIO: [0-9]+/[0-9]+ passed' "$log_dir/audio.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/rounds.gd -- --test 2>&1 | tee "$log_dir/rounds.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/rounds.log"; then exit 1; fi
grep -Eq '^SEEDED_ROUNDS: [0-9]+/[0-9]+ passed' "$log_dir/rounds.log"
"$godot_bin" --headless --path "$project_dir" --fixed-fps 60 --script res://tests/performance.gd -- --test 2>&1 | tee "$log_dir/performance.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log_dir/performance.log"; then exit 1; fi
grep -Eq '^PERFORMANCE: [0-9]+/[0-9]+ passed' "$log_dir/performance.log"
echo "Logs: $log_dir"
