@echo off
title Rutas Mercado - Demo
cd /d "%~dp0demo_web"

echo Iniciando demo de Rutas Mercado...
echo.
echo No cierres esta ventana mientras hagas la demostracion.
echo Para terminar, cierra esta ventana o presiona Ctrl+C.
echo.

start "" /min powershell -NoProfile -Command "Start-Sleep -Seconds 2; Start-Process 'http://localhost:8765'"
python -m http.server 8765
