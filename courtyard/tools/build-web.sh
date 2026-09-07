#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
godot_bin="${GODOT_BIN:-$project_dir/../.tools/godot/4.7.2/Godot_v4.7.2-stable_linux.x86_64}"
if [[ ! -f "$project_dir/../.tools/godot/4.7.2/templates/web_nothreads_release.zip" ]]; then
  echo 'Install web templates: bash courtyard/tools/setup.sh --web' >&2
  exit 1
fi
mkdir -p "$project_dir/builds/web-releases" "$project_dir/../artifacts"
release_dir="$(mktemp -d "$project_dir/builds/web-releases/courtyard-XXXXXX")"
log_dir="$(mktemp -d "$project_dir/../artifacts/godot-web-XXXXXX")"
"$godot_bin" --headless --path "$project_dir" --editor --import 2>&1 | tee "$log_dir/import.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:' "$log_dir/import.log"; then exit 1; fi
"$godot_bin" --headless --path "$project_dir" --export-release Web "$release_dir/index.html" 2>&1 | tee "$log_dir/export.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:' "$log_dir/export.log"; then exit 1; fi
cp "$project_dir/LICENSE" "$release_dir/"
mkdir -p "$release_dir/licenses"
cp "$project_dir/licenses/"*.txt "$release_dir/licenses/"
node "$project_dir/tools/web-release.js" "$release_dir"
printf '%s\n' "${release_dir##*/}" > "$project_dir/builds/web-candidate.txt"
echo "Web candidate (not published): $release_dir"
echo "Logs: $log_dir"
