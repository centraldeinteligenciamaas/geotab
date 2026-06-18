@echo off
REM Abre o cliente nativo psql ja conectado no banco local geotab.
REM Duplo-clique ou rode no terminal. Saia com \q
set PGPASSWORD=geotab_iAGEz2pmgDhf
"C:\Users\ygor.kouzak\pgsql\pgsql\bin\psql.exe" -U postgres -h localhost -d geotab
