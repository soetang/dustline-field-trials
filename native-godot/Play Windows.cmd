@echo off
setlocal
pushd "%~dp0"
if not exist "builds\current.txt" goto legacy
set /p dustline_release=<"builds\current.txt"
if not exist "builds\releases\%dustline_release%\windows\DustlineNative.exe" goto legacy
"builds\releases\%dustline_release%\windows\DustlineNative.exe" %*
goto done
:legacy
if exist "builds\windows\DustlineNative.exe" (
  "builds\windows\DustlineNative.exe" %*
) else if exist "..\.tools\godot\4.7.2\Godot_v4.7.2-stable_win64.exe" (
  "..\.tools\godot\4.7.2\Godot_v4.7.2-stable_win64.exe" --path "%CD%" %*
) else (
  echo Godot is not installed here. Open project.godot with Godot 4.7.2,
  echo or run bash native-godot/tools/setup.sh from WSL first.
  pause
)
:done
popd
