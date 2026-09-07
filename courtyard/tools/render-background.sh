#!/usr/bin/env bash
# Off-screen renderer checks only. Never connect Godot to the user's display.
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
godot_bin="${GODOT_BIN:-$project_dir/../.tools/godot/4.7.2/Godot_v4.7.2-stable_linux.x86_64}"
portable="$project_dir/../.tools/xvfb"
test_script="res://tests/operator_gallery.gd"
sentinel=OPERATOR_GALLERY_OK
if [[ "${1:-}" == --map ]]; then
  test_script="res://tests/map_review.gd"
  sentinel=MAP_REVIEW_OK
  shift
fi
if command -v Xvfb >/dev/null && command -v xkbcomp >/dev/null; then
  server=(Xvfb)
elif [[ -x "$portable/usr/bin/Xvfb" && -x "$portable/usr/bin/xkbcomp" ]] && command -v bwrap >/dev/null; then
  # The distro binary expects /usr/bin/xkbcomp. Supply it in a private mount
  # namespace, without installing anything into the system or touching WSLg.
  portable="$(cd "$portable" && pwd)"
  server=(bwrap --die-with-parent --ro-bind / / --bind /tmp /tmp --tmpfs /usr/bin
    --ro-bind /usr/bin/dash /usr/bin/sh
    --ro-bind "$portable/usr/bin/xkbcomp" /usr/bin/xkbcomp
    --setenv LD_LIBRARY_PATH "$portable/usr/lib/x86_64-linux-gnu"
    -- "$portable/usr/bin/Xvfb")
else
  echo 'Off-screen review requires Xvfb and xkbcomp. No desktop fallback will be used.' >&2
  exit 1
fi
log_dir="$(mktemp -d "$project_dir/../artifacts/operator-render-XXXXXX")"
# Avoid low display numbers: WSLg may own their filesystem sockets even when
# the corresponding abstract socket is free. Refuse collisions, never replace.
requested_display=$((100 + RANDOM % 30000))
"${server[@]}" ":$requested_display" -displayfd 1 -screen 0 1280x720x24 -nolisten tcp -nolisten unix -ac >"$log_dir/display" 2>"$log_dir/display.log" &
display_pid=$!
trap 'kill "$display_pid" 2>/dev/null || true; wait "$display_pid" 2>/dev/null || true' EXIT
for attempt in {1..100}; do
  [[ -s "$log_dir/display" ]] && break
  if ! kill -0 "$display_pid" 2>/dev/null; then
    echo "Off-screen display failed; see $log_dir/display.log" >&2
    exit 1
  fi
  sleep 0.05
done
read -r display_number <"$log_dir/display"
[[ "$display_number" =~ ^[0-9]+$ ]] || exit 1
[[ "$display_number" == "$requested_display" ]] || exit 1
echo "Rendering on private display :$display_number. Logs: $log_dir"
# An invalid Wayland socket is intentional: unsetting it lets Godot try the
# user's default wayland-0 if X11 initialization fails.
DISPLAY=":$display_number" WAYLAND_DISPLAY=dustline-no-host-display LIBGL_ALWAYS_SOFTWARE=1 LP_NUM_THREADS=2 \
  "$godot_bin" --path "$project_dir" --display-driver x11 --rendering-method gl_compatibility \
  --script "$test_script" -- --test "$@" 2>&1 | tee "$log_dir/renderer.log"
if rg -q 'SCRIPT ERROR:|^ERROR:|falling back' "$log_dir/renderer.log"; then exit 1; fi
rg -q "^$sentinel" "$log_dir/renderer.log"
