@ECHO OFF

ECHO : Updating :
if exist ComfyUI\.git\ (
  CD update
  ..\python_embeded\python.exe .\update.py ..\ComfyUI\ --stable
  if exist update_new.py (
    move /y update_new.py update.py
    echo Running updater again since it got updated.
    ..\python_embeded\python.exe .\update.py ..\ComfyUI\ --skip_self_update --stable
  )
) else (
  echo Updating disabled.
)

ECHO : Staring :
CD ..\
.\python_embeded\python.exe -s ComfyUI\main.py --windows-standalone-build --output-directory R:\ComfyUI\
pause
