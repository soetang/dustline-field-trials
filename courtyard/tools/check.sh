#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# name | kind | success sentinel | fixed FPS | user test flag | timeout | log
# Keep the default order and per-suite flags explicit.
suites=(
  'verify|gd|VERIFICATION|60|test|-|tests'
  'tactics|gd|TACTICS|60|test|-|tactics'
  'aim|gd|AIM|60|test|-|aim'
  'encounters|gd|ENCOUNTERS|60|test|-|encounters'
  'query_reuse|gd|QUERY_REUSE|60|test|-|query-reuse'
  'room_lookup|gd|ROOM_LOOKUP|60|test|-|room-lookup'
  'navigation_clearance|gd|NAVIGATION_CLEARANCE|-|test|-|navigation-clearance'
  'bot_navigation|gd|BOT_NAVIGATION|60|test|-|bot-navigation'
  'cpu_profile_check|gd|CPU_PROFILE|-|test|-|cpu-profile'
  'shot_effects|gd|SHOT_EFFECTS|-|test|-|shot-effects'
  'profile-instrumentation|js|-|-|-|-|profile-instrumentation'
  'presentation-state-cache|js|-|-|-|-|presentation-state-cache'
  'gpu-timer-probe|js|-|-|-|-|gpu-timer-probe'
  'backbuffer-gl-audit|js|-|-|-|-|backbuffer-gl-audit'
  'ssao-unroll|js|-|-|-|-|ssao-unroll'
  'hud-buffer-probe|js|-|-|-|-|hud-buffer-probe'
  'compare-operator-reviews|js|-|-|-|-|operator-review-comparison'
  'hud_retention|gd|HUD_RETENTION|60|test|-|hud-retention'
  'flat_surface|gd|FLAT_SURFACE|-|-|-|flat-surface'
  'wall_collision|gd|WALL_COLLISION|60|test|-|wall-collision'
  'weapon_walls|gd|WEAPON_WALLS|60|test|-|weapon-walls'
  'operators|gd|OPERATORS|60|test|-|operators'
  'pose_reset|gd|POSE_RESET|-|test|-|pose-reset'
  'corpse_sleep|gd|CORPSE_SLEEP|-|test|-|corpse-sleep'
  'operator_surface|gd|OPERATOR_SURFACE|-|-|-|operator-surface'
  'feet|gd|FEET|60|test|-|feet'
  'map_update|gd|MAP_UPDATE|60|test|-|map'
  'material_batches|gd|MATERIAL_BATCHES|60|test|-|material-batches'
  'crate_mesh|gd|CRATE_MESH|-|-|20s|crate-mesh'
  'input|gd|INPUT|60|test|-|input'
  'combat|gd|COMBAT|60|test|-|combat'
  'audio|gd|AUDIO|60|test|-|audio'
  'rounds|gd|SEEDED_ROUNDS|60|test|-|rounds'
  'performance|gd|PERFORMANCE|60|test|-|performance'
  'reported_view|gd|REPORTED_VIEW|60|test|-|reported-view'
  'reported-view|js|-|-|-|-|reported-view-input'
)
fast_suites=(verify aim input combat pose_reset corpse_sleep presentation-state-cache gpu-timer-probe)

suite_spec() {
  local spec
  for spec in "${suites[@]}"; do
    if [[ "${spec%%|*}" == "$1" ]]; then printf '%s\n' "$spec"; return 0; fi
  done
  return 1
}

selected=()
if (( $# == 0 )); then
  selected=("${suites[@]}")
elif [[ "$1" == --list && $# == 1 ]]; then
  for spec in "${suites[@]}"; do printf '%s\n' "${spec%%|*}"; done
  exit 0
else
  if [[ "$1" == --fast && $# == 1 ]]; then set -- "${fast_suites[@]}"; fi
  # Reject all unknown names before importing or running a partial selection.
  for name in "$@"; do
    if ! spec="$(suite_spec "$name")"; then
      echo "Unknown suite: $name. Use --list, --fast, or explicit suite names." >&2
      exit 2
    fi
    selected+=("$spec")
  done
fi

godot_bin="${GODOT_BIN:-$project_dir/../.tools/godot/4.7.2/Godot_v4.7.2-stable_linux.x86_64}"
if [[ ! -x "$godot_bin" ]]; then
  echo 'Install Godot first: bash courtyard/tools/setup.sh' >&2
  exit 1
fi
mkdir -p "$project_dir/../artifacts"
log_dir="$(mktemp -d "$project_dir/../artifacts/godot-check-XXXXXX")"
echo "Logs: $log_dir"

run_logged() {
  local log="$1"
  shift
  if ! "$@" 2>&1 | tee "$log"; then
    echo "Command failed; see $log" >&2
    return 1
  fi
}

# Godot can exit 0 after import or script errors. Import exactly once, before
# any selected suite, then check each GDScript log and its explicit sentinel.
run_logged "$log_dir/import.log" "$godot_bin" --headless --path "$project_dir" --editor --import
if grep -Eq 'SCRIPT ERROR:|^ERROR:' "$log_dir/import.log"; then exit 1; fi

for spec in "${selected[@]}"; do
  IFS='|' read -r name kind sentinel fps test_flag limit log_name <<< "$spec"
  log="$log_dir/$log_name.log"
  if [[ "$kind" == js ]]; then
    GODOT_BIN="$godot_bin" run_logged "$log" node "$project_dir/tests/$name-check.js"
    continue
  fi
  command=("$godot_bin" --headless --path "$project_dir")
  if [[ "$fps" != - ]]; then command+=(--fixed-fps "$fps"); fi
  command+=(--script "res://tests/$name.gd")
  if [[ "$test_flag" == test ]]; then command+=(-- --test); fi
  if [[ "$limit" != - ]]; then command=(timeout "$limit" "${command[@]}"); fi
  run_logged "$log" "${command[@]}"
  if grep -Eq 'SCRIPT ERROR:|^ERROR:|^FAIL:' "$log"; then exit 1; fi
  if ! grep -Eq "^${sentinel}: [0-9]+/[0-9]+ passed" "$log"; then
    echo "Missing success sentinel for $name; see $log" >&2
    exit 1
  fi
done
echo "Passed ${#selected[@]} suites. Logs: $log_dir"
