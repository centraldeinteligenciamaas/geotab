@echo off
REM Sobe o PostgreSQL local no logon (idempotente: se ja estiver rodando, nao faz nada).
"C:\Users\ygor.kouzak\pgsql\pgsql\bin\pg_ctl.exe" -D "C:\Users\ygor.kouzak\pgdata" -l "C:\Users\ygor.kouzak\pgdata\server.log" start
