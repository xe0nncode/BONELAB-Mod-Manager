@echo off
echo "|-----------------------------|"
echo "|BONELAB Mod Manager v1.0    |"
echo "|-----------------------------|"
echo "Update check complete."
echo "Launching Mod Manager..."
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0manager.ps1"
if errorlevel 1 pause
