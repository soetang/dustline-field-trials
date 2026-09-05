#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
godot_bin="${GODOT_BIN:-$project_dir/../.tools/godot/4.7.2/Godot_v4.7.2-stable_linux.x86_64}"
bash "$project_dir/tools/check.sh"
if [[ ! -f "$project_dir/../.tools/godot/4.7.2/templates/windows_release_x86_64.exe" ]]; then
  echo 'Export templates missing. Run bash native-godot/tools/setup.sh --templates' >&2
  exit 1
fi
mkdir -p "$project_dir/builds/windows" "$project_dir/builds/linux"
log_dir="$(mktemp -d "$project_dir/../artifacts/godot-build-XXXXXX")"
for preset in 'Windows Desktop' 'Linux'; do
  "$godot_bin" --headless --path "$project_dir" --export-release "$preset" 2>&1 | tee "$log_dir/export-${preset// /-}.log"
  if grep -Eq 'SCRIPT ERROR:|^ERROR:' "$log_dir/export-${preset// /-}.log"; then exit 1; fi
done
for platform in windows linux; do
  cp "$project_dir/LICENSE" "$project_dir/README.md" "$project_dir/builds/$platform/"
  mkdir -p "$project_dir/builds/$platform/licenses"
  cp "$project_dir/licenses/GODOT-LICENSE.txt" "$project_dir/licenses/GODOT-COPYRIGHT.txt" "$project_dir/builds/$platform/licenses/"
done
cp "$project_dir/tools/compatibility.cmd" "$project_dir/builds/windows/Compatibility mode.cmd"
chmod +x "$project_dir/builds/windows/DustlineNative.exe"
"$project_dir/builds/linux/DustlineNative.x86_64" --headless --quit-after 120 -- --test 2>&1 | tee "$log_dir/package.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:' "$log_dir/package.log"; then exit 1; fi
grep -q 'DUSTLINE_READY' "$log_dir/package.log"
echo "Desktop builds: $project_dir/builds/{windows,linux}"
echo "Logs: $log_dir"
