@echo off
REM Sobe o PostgreSQL local no logon (idempotente: se ja estiver rodando, nao faz nada).
REM A JANELA hospeda o banco: fecha-la = derruba o Postgres (gotcha 0xC000013A).
title BANCO GEOTAB (Postgres local) -- NAO FECHE ENQUANTO USAR O POWER BI
"C:\Users\ygor.kouzak\pgsql\pgsql\bin\pg_ctl.exe" -D "C:\Users\ygor.kouzak\pgdata" -l "C:\Users\ygor.kouzak\pgdata\server.log" start

cls
echo ============================================================
echo   BANCO DE DADOS GEOTAB  (PostgreSQL local - porta 5432)
echo ============================================================
echo.
echo   O QUE ESTA JANELA FAZ:
echo   Ela mantem o banco de dados LOCAL no ar. O Power BI e a
echo   sincronizacao diaria se conectam a ele por localhost:5432.
echo.
echo   NAO FECHE ESTA JANELA ENQUANTO:
echo     - estiver usando / atualizando o Power BI;
echo     - a sincronizacao estiver rodando (dias uteis, ~08:00).
echo   Fechar esta janela DERRUBA o banco e o Power BI passa a dar
echo   o erro "a maquina de destino as recusou ativamente".
echo.
echo   QUANDO PODE FECHAR (com seguranca):
echo     - quando terminar de usar o Power BI E a sync do dia ja
echo       tiver rodado (ou voce nao precisar mais dos dados hoje).
echo     - ao desligar/reiniciar o PC (normal).
echo   O banco volta a subir sozinho no proximo LOGON.
echo.
echo   Se fechar sem querer: abra este mesmo arquivo de novo
echo   (iniciar_postgres.bat) que o banco religa.
echo ============================================================
echo.
echo   [Banco no ar] Deixe esta janela minimizada. Log do servidor:
echo   C:\Users\ygor.kouzak\pgdata\server.log
echo.

REM Mantem a janela aberta (ela hospeda o banco). Feche-a so quando puder.
:keepalive
timeout /t 3600 /nobreak >nul
goto keepalive
