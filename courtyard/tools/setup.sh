#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tool_dir="$project_dir/../.tools/godot/4.7.2"
mkdir -p "$tool_dir" "$project_dir/../artifacts"
cd "$tool_dir"
base='https://github.com/godotengine/godot-builds/releases/download/4.7.2-stable'
fetch() {
  local filename="$1" expected="$2"
  if [[ ! -f "$filename" ]]; then
    curl -fL --retry 3 "$base/$filename" -o "$filename.part"
    mv -- "$filename.part" "$filename"
  fi
  local actual
  actual="$(sha512sum "$filename")"
  [[ "${actual%% *}" == "$expected" ]] || { echo "Checksum failed: $filename" >&2; exit 1; }
  echo "Verified: $filename"
}
fetch Godot_v4.7.2-stable_linux.x86_64.zip 9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65
unzip -n -q Godot_v4.7.2-stable_linux.x86_64.zip
if [[ -d /mnt/c/Windows || "${1:-}" == '--windows' || "${1:-}" == '--templates' ]]; then
  fetch Godot_v4.7.2-stable_win64.exe.zip 83decd58fdf67b9d657958a1ae6bf1929c20785315a81effe245874cdc57acb709bf868e00778a96984338c1b29dafdb453c6847747694621c6ecf5da2259993
  unzip -n -q Godot_v4.7.2-stable_win64.exe.zip
  chmod +x Godot_v4.7.2-stable_win64.exe Godot_v4.7.2-stable_win64_console.exe
fi
if [[ "${1:-}" == '--templates' || "${1:-}" == '--web' ]]; then
  # Verify the official archive before extracting the requested platform only.
  fetch Godot_v4.7.2-stable_export_templates.tpz ca4d71c4d7b81dfc15d1a98baa07534aa95b03fdda78a0075b06672e1648d2e5f40980c9adc28d23e1b92e732ee7bf3461997aa804af74ec2fcd7a93ccb84079
  if [[ "${1:-}" == '--web' ]]; then
    unzip -n -q Godot_v4.7.2-stable_export_templates.tpz templates/web_nothreads_release.zip templates/version.txt
  else
    unzip -n -q Godot_v4.7.2-stable_export_templates.tpz templates/windows_release_x86_64.exe templates/windows_release_x86_64_console.exe templates/linux_release.x86_64 templates/version.txt
  fi
fi
echo "Portable Godot is ready in $tool_dir; no account, service or registry changes."
