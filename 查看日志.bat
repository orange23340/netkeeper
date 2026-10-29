@echo off
set D=%ProgramData%\NetKeeper\logs
if not exist "%D%" mkdir "%D%"
start "" "%D%"
pause
