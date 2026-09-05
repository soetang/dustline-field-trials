@echo off
setlocal
pushd "%~dp0"
if exist "builds\windows\DustlineNative.exe" (
  "builds\windows\DustlineNative.exe" %*
) else if exist "..\.tools\godot\4.7.2\Godot_v4.7.2-stable_win64.exe" (
  "..\.tools\godot\4.7.2\Godot_v4.7.2-stable_win64.exe" --path "%CD%" %*
) else (
  echo Godot is not installed here. Open project.godot with Godot 4.7.2,
  echo or run bash native-godot/tools/setup.sh from WSL first.
  pause
)
popd
