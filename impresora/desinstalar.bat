@echo off
rem Sistema La Merced - detiene el servicio de impresion y quita su arranque automatico.
schtasks /Delete /F /TN "La Merced Impresion"
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*iniciar-oculto.vbs*' -or $_.CommandLine -like '*servicio.mjs*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
echo Servicio de impresion detenido.
pause
