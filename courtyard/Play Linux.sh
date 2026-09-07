#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$project_dir/builds/current.txt" ]]; then
  read -r dustline_release < "$project_dir/builds/current.txt"
  if [[ "$dustline_release" =~ ^native-[a-zA-Z0-9]+$ && -x "$project_dir/builds/releases/$dustline_release/linux/DustlineNative.x86_64" ]]; then
    exec "$project_dir/builds/releases/$dustline_release/linux/DustlineNative.x86_64" "$@"
  fi
fi
if [[ -x "$project_dir/builds/linux/DustlineNative.x86_64" ]]; then
  exec "$project_dir/builds/linux/DustlineNative.x86_64" "$@"
fi
exec "$project_dir/../.tools/godot/4.7.2/Godot_v4.7.2-stable_linux.x86_64" --path "$project_dir" "$@"
