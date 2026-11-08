@echo off
rem Sistema La Merced - reinicia el servicio de impresion (por ejemplo, despues de cambiar una impresora de lugar).
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*iniciar-oculto.vbs*' -or $_.CommandLine -like '*servicio.mjs*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
schtasks /Run /TN "La Merced Impresion"
echo Servicio de impresion reiniciado.
pause
