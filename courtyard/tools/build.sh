#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
godot_bin="${GODOT_BIN:-$project_dir/../.tools/godot/4.7.2/Godot_v4.7.2-stable_linux.x86_64}"
bash "$project_dir/tools/check.sh"
if [[ ! -f "$project_dir/../.tools/godot/4.7.2/templates/windows_release_x86_64.exe" ]]; then
  echo 'Export templates missing. Run bash courtyard/tools/setup.sh --templates' >&2
  exit 1
fi
mkdir -p "$project_dir/builds/releases"
release_dir="$(mktemp -d "$project_dir/builds/releases/native-XXXXXX")"
mkdir -p "$release_dir/windows" "$release_dir/linux"
log_dir="$(mktemp -d "$project_dir/../artifacts/godot-build-XXXXXX")"
for preset in 'Windows Desktop' 'Linux'; do
  output="$release_dir/linux/DustlineNative.x86_64"
  if [[ "$preset" == 'Windows Desktop' ]]; then output="$release_dir/windows/DustlineNative.exe"; fi
  "$godot_bin" --headless --path "$project_dir" --export-release "$preset" "$output" 2>&1 | tee "$log_dir/export-${preset// /-}.log"
  if grep -Eq 'SCRIPT ERROR:|^ERROR:' "$log_dir/export-${preset// /-}.log"; then exit 1; fi
done
for platform in windows linux; do
  cp "$project_dir/LICENSE" "$project_dir/README.md" "$release_dir/$platform/"
  cp "$project_dir/tools/PLAY.txt" "$release_dir/$platform/READ_ME.txt"
  mkdir -p "$release_dir/$platform/licenses"
  cp "$project_dir/licenses/GODOT-LICENSE.txt" "$project_dir/licenses/GODOT-COPYRIGHT.txt" "$project_dir/licenses/ASSET-SOURCES.txt" "$release_dir/$platform/licenses/"
done
cp "$project_dir/tools/compatibility.cmd" "$release_dir/windows/Compatibility mode.cmd"
chmod +x "$release_dir/windows/DustlineNative.exe"
"$release_dir/linux/DustlineNative.x86_64" --headless --quit-after 120 -- --test 2>&1 | tee "$log_dir/package.log"
if grep -Eq 'SCRIPT ERROR:|^ERROR:' "$log_dir/package.log"; then exit 1; fi
grep -q 'DUSTLINE_READY' "$log_dir/package.log"
if [[ -d /mnt/c/Windows ]]; then
  "$release_dir/windows/DustlineNative.exe" --headless --quit-after 120 -- --test 2>&1 | tee "$log_dir/windows-package.log"
  if grep -Eq 'SCRIPT ERROR:|^ERROR:' "$log_dir/windows-package.log"; then exit 1; fi
  grep -q 'DUSTLINE_READY' "$log_dir/windows-package.log"
fi
# Publish only the pointer; existing executables and resource packs stay intact.
printf '%s\n' "${release_dir##*/}" > "$project_dir/builds/current.txt.new"
mv -- "$project_dir/builds/current.txt.new" "$project_dir/builds/current.txt"
echo "Desktop builds: $release_dir/{windows,linux}"
echo "Logs: $log_dir"
