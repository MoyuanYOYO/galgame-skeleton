@echo off
setlocal
cd /d "%~dp0"

rem === GVS editor launcher ===
rem If Godot lives somewhere else, fix the GODOT path below.

set "GODOT=D:\Tools\Godot\Godot_v4.7.2-stable_win64.exe"

if not exist "project.godot" (
  echo [ERROR] project.godot not found in this folder.
  echo         Put this .bat inside the galgame folder and run it there.
  pause
  exit /b 1
)

if not exist "%GODOT%" (
  echo [ERROR] Godot not found at:
  echo         %GODOT%
  echo         Open this .bat in a text editor and fix the GODOT= line.
  pause
  exit /b 1
)

echo Starting GVS editor...
start "" "%GODOT%" --path . res://tools/editor/editor.tscn
exit /b 0
