@echo off
REM Backup diario do banco geotab (formato custom -Fc). Nome por data: um arquivo/dia.
REM Roda no logon; espera o Postgres subir; mantem so os ultimos 14 dias.
ping -n 21 127.0.0.1 >nul
for /f %%i in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd"') do set DT=%%i
if not exist "C:\Users\ygor.kouzak\backups" mkdir "C:\Users\ygor.kouzak\backups"
set PGPASSWORD=geotab_iAGEz2pmgDhf
"C:\Users\ygor.kouzak\pgsql\pgsql\bin\pg_dump.exe" -U postgres -h localhost -Fc -f "C:\Users\ygor.kouzak\backups\geotab_%DT%.dump" geotab
forfiles /p "C:\Users\ygor.kouzak\backups" /m geotab_*.dump /d -14 /c "cmd /c del @path" 2>nul
