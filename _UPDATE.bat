@ECHO OFF
CD /d "%~dp0"

if exist .git (
  echo Error: Root .git is in wrong sate.
  exit /B 1
)
if not exist ComfyUI/.git (
  echo Error: ComfyUI/.git is in wrong sate.
  exit /B 2
)
CD update
:: Based on "update_comfyui_stable.bat"
..\python_embeded\python.exe .\update.py ..\ComfyUI\ --stable
if exist update_new.py (
  move /y update_new.py update.py
  echo Running updater again since it got updated.
  ..\python_embeded\python.exe .\update.py ..\ComfyUI\ --skip_self_update --stable
)
