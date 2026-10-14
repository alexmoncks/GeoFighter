@echo off
rem GEO FIGHTER no openMSX (fork V9968 + geo3d), perfil 98h.
rem O jogo precisa do geo3d v2.0: usa o openmsx_geo3d_v2.exe (ramo geo3d-v2.0
rem do fork) de ..\openmsx-geo3d (C:\Projects\mmsoft\openmsx-geo3d); para outro
rem lugar, defina OPENMSX_DIR antes de chamar.
rem Teclas: cursores andam, cima pula, baixo agacha, ESPACO ou Z soco, X chute,
rem C defesa, RETURN volta ao titulo.
setlocal
if "%OPENMSX_DIR%"=="" set OPENMSX_DIR=%~dp0..\openmsx-geo3d
set EXE=openmsx_geo3d_v2.exe
if not exist "%OPENMSX_DIR%\%EXE%" (
  echo %EXE% nao encontrado em "%OPENMSX_DIR%"
  echo O GEO FIGHTER precisa do openMSX com o geo3d v2.0.
  pause
  exit /b 1
)
set ROM=%~dp0release\GEOFIGHTER_98.ROM
if not exist "%ROM%" set ROM=%~dp0out\GEOFIGHTER_98.ROM
cd /d "%OPENMSX_DIR%"
start "" %EXE% -machine C-BIOS_V9968_JP -ext geo3d -cart "%ROM%" -romtype ASCII16
