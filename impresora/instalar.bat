@echo off
rem Sistema La Merced - instalacion del servicio de impresion (computadora de caja)
chcp 65001 >nul
cd /d "%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo.
  echo Falta Node.js. Descargalo de https://nodejs.org ^(version LTS^), instalalo y vuelve a abrir este archivo.
  echo.
  pause
  exit /b 1
)
echo Instalando lo necesario...
call npm install --omit=dev
if errorlevel 1 (
  echo No se pudo instalar. Revisa la conexion a internet.
  pause
  exit /b 1
)
node src\configurar.mjs
pause
