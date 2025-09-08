@ECHO OFF
CD /d "%~dp0"

ECHO : Staring :
imdisk.exe -a -s 256M -o awe -m R: -p "/fs:ntfs /v:RamDisk /q /y"
if %ERRORLEVEL% NEQ 0 (
	pause >nul
	exit
)

SET key=ComfyUI %DATE% %TIME%
START "%key%" .\python_embeded\python.exe -s ComfyUI\main.py --windows-standalone-build --output-directory R:\ComfyUI\ %*

ECHO.
ECHO    ^|--------------------------------------------------^|
ECHO    ^|               Waiting for clean up               ^|
ECHO    ^|--------------------------------------------------^|
ECHO    ^|                                                  ^|
ECHO    ^|   Do not close this window!                      ^|
ECHO    ^|   This window will close by it self when done.   ^|
ECHO    ^|                                                  ^|
ECHO    ^|--------------------------------------------------^|
ECHO.
:Watcher
TIMEOUT /T 1 /nobreak >nul
TASKLIST /v|find "%key%" >nul &&goto Watcher

ECHO : Cleaning up :
imdisk.exe -D -m R: