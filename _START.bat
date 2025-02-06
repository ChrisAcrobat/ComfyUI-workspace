@ECHO OFF

ECHO : Updating :
attrib -h .git
attrib -h ComfyUI\.git-
RENAME .git .git-
RENAME ComfyUI\.git- .git
CD update
:: Based on "update_comfyui_stable.bat"
..\python_embeded\python.exe .\update.py ..\ComfyUI\ --stable
if exist update_new.py (
  move /y update_new.py update.py
  echo Running updater again since it got updated.
  ..\python_embeded\python.exe .\update.py ..\ComfyUI\ --skip_self_update --stable
)
:: /Based on "update_comfyui_stable.bat"
CD ..\
RENAME .git- .git
RENAME ComfyUI\.git .git-
attrib +h .git
attrib +h ComfyUI\.git-

ECHO : Staring :
:: imdisk.exe -a -s 256M -o awe -m R: -p "/fs:ntfs /v:RamDisk /q /y"
.\python_embeded\python.exe -s ComfyUI\main.py --windows-standalone-build --output-directory R:\ComfyUI\

ECHO : Cleaning up :
:: imdisk.exe -D R:
pause
