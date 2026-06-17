# Contexto — geotab (sync Geotab → Supabase)

## Stack
- Python (Flask + APScheduler + SQLAlchemy/psycopg2 + pandas + requests)
- Banco: **PostgreSQL LOCAL 18.4** (portátil em `C:\Users\ygor.kouzak\pgsql\pgsql\bin`, dados em `C:\Users\ygor.kouzak\pgdata`, porta 5432, sslmode=disable). Migrado do Supabase em 2026-06-17.
- Deploy: **LOCAL** (Render aposentado — IP era bloqueado pelo WAF da Geotab). Sync via `atualizar_local.py` no logon.
- Config via .env (credenciais Geotab + conexão local nas mesmas chaves SUPABASE_*)

## Como rodar (LOCAL — não há mais servidor web)
- Postgres local sobe no logon via `iniciar_postgres.bat` (pasta Inicializar). Manual: `pg_ctl -D C:\Users\ygor.kouzak\pgdata start`.
- Sync: `python geotab_supabase.py <modo>` (cadastro | status | comportamento | viagens). O orquestrador é `atualizar_local.py` (roda os 4 em sequência, seg-sex, 1x/dia).
- Agendamento: Tarefa `GeotabSyncLocal` — gatilho no logon + seg-sex 08:00 com `WakeToRun` (acorda do sleep/hibernate; wake timers habilitados no plano de energia). NÃO acorda do desligado.
- app.py/Flask/APScheduler/endpoints /run /status: REMOVIDOS (2026-06-17). Status agora = SQL direto (DBeaver/psql).

## Arquitetura (mapa de arquivos)
- `geotab_supabase.py` — extração da API Geotab (JSON-RPC) e gravação no Postgres; cria/migra tabelas; throttle de quota (4500 sub-chamadas/60s). Conexão lê `SUPABASE_*` do .env (agora apontam p/ localhost) + `SUPABASE_SSLMODE`.
- `atualizar_local.py` — orquestrador local: roda os 4 modos em subprocesso, seg-sex, 1x/dia (marcador `.ultima_atualizacao`). Disparado pela Tarefa `GeotabSyncLocal`.
- `iniciar_postgres.bat` — sobe o Postgres local (pasta Inicializar/logon).
- `backup_geotab.bat` — pg_dump diário p/ `C:\Users\ygor.kouzak\backups` (mantém 14 dias; pasta Inicializar/logon).
- `views.sql` / `views_backup.sql` — definição/backup das views.
- (REMOVIDOS 2026-06-17: `app.py`, `render.yaml`, gunicorn/Flask/APScheduler.)

## Tabelas e períodos
- `tb_cadastro` — snapshot atual da frota (full refresh; `atualizado_em`)
- `tb_status` — snapshot tempo real (`snapshot_em`); motorista vem das trips das últimas 24h
- `tb_comportamento` — janela móvel de 6 meses (contadores `*_6m`); incremental via buckets
- `tb_comportamento_eventos` — buckets diários device/dia/tipo; mantém só os últimos 6 meses (limpeza automática)
- `tb_viagens` — JANELA MÓVEL DE 30 DIAS (`VIAGENS_DIAS=30`, fixado no free tier). `sincronizar_viagens` PODA (`DELETE data_partida < data_inicio`) quando `VIAGENS_DIAS>0` — sem isso o upsert nunca apaga e reenche o disco.
- GEOCODE por LOOKUP (2026-06-15): endereços ficam em `tb_enderecos` (coord arredondada→endereço), NÃO em tb_viagens. `vw_relatorio_viagens` traz `end_partida`/`end_chegada` por JOIN em `round(lat/lon, 3)`. `geocodificar_enderecos()` (chamada no fim de sincronizar_viagens se VIAGENS_GEOCODE on) é incremental: só geocodifica coords novas. `GEOCODE_CASAS=3` (~110m) dedup ~1,4M→83k coords (geocode trip-a-trip era inviável, dias). IMPORTANTE: o `round(...,3)` da view tem que casar com GEOCODE_CASAS.
- tb_viagens ENXUTA (2026-06-15): removidas serial/placa/veiculo/grupo/todos_grupos/regional/superintendencia (~190 MB de texto repetido). placa/veiculo/grupo/todos_grupos agora vêm de tb_cadastro via JOIN (por device_id) nas views *_viagens; regional/superintendencia eram peso morto (nenhuma view usava). Resultado: banco 484→259 MB, tb_viagens 429→204 MB, ~241 MB de folga. 0 viagens órfãs (todo device casa com tb_cadastro). 709.767 viagens / 30 dias.

## Piso temporal: SOMENTE 2026 (2026-06-16)
- `DATA_CORTE`/`ANO_CORTE` (env `ANO_CORTE`, default 2026) em geotab_supabase.py. Nenhuma tabela guarda dados < 2026-01-01. Aplicado como floor nas janelas: comportamento (`janela_ini=max(6m, corte)`), viagens (`data_inicio>=corte`), odômetro (clamp + DELETE <corte), resumo mensal (skip `ts.year<corte`). Limpeza única feita: removidos 2025-12 de comportamento_eventos/odometro_dia/resumo_mensal. Para virar o ano, bump ANO_CORTE.

## Views e períodos (UMA por tema; header de views.sql) — reorg 2026-06-16
- `vw_cadastro` — snapshot atual (`atualizado_em`)
- `vw_status` — tempo real (`snapshot_em`, `ultimo_contato`)
- `vw_comportamento` — POR DIA (device×dia), ~6 meses (`data`, `ano`, `mes`); eventos dos buckets + `odometro`/`odometro_gps` do dia (JOIN tb_odometro_dia). 129k linhas.
- `vw_relatorio_viagens` — últimos 30 dias, por viagem (`data_partida`, `data_chegada`)
- `vw_resumo_frota_mensal` — por veículo×mês, ano 2026 (`ano`, `mes`, `ano_mes`)
- `vw_indicadores_mensal` — por grupo×mês, ano 2026 (`ano`, `mes`, `ano_mes`)
- REMOVIDAS (2026-06-16): views `vw_comportamento_mensal`/`vw_resumo_frota`/`vw_indicadores_produtividade` (1 view por tema) e a TABELA `tb_comportamento` (dropada). vw_comportamento usa os buckets; odômetro migrou p/ tb_odometro_dia.
- `tb_odometro_dia` — odômetro POR DIA (device×dia, último valor do dia, físico+GPS). Preenchido por `sincronizar_odometro_dia` (chamado no fim de sincronizar_comportamento; incremental = dias novos). Substitui o odômetro que vivia em tb_comportamento. Funções antigas buscar_odo_gps/fisico/_com_fallback_ano/_reconstruir/_ler_odo_anterior TODAS removidas (limpeza 2026-06-17).
- `tb_resumo_mensal` — agregado km/tempo/dias/viagens por device×mês (~21k linhas/ano). Mês corrente: atualizado no sync de viagens via `atualizar_resumo_mes_corrente` (SQL de tb_viagens, sem Geotab). Meses passados: `backfill_resumo_mensal` (Geotab, uma vez). placa/grupo via JOIN tb_cadastro nas views.
- NOTA: as views VIVAS já estavam em 30 dias; o `views.sql` estava DESATUALIZADO (dizia "ano corrente"). Arquivo sincronizado com o banco em 2026-06-15. Sempre conferir com `pg_get_viewdef` antes de assumir o que o arquivo diz.

## Decisões importantes
- TIMESTAMP sem timezone, valores em BRT (Brasil sem horário de verão desde 2019)
- NullPool + pooler transaction mode → evita "max clients reached"
- Uma tabela por job/horário — rodar tudo junto estoura RAM do free tier
- UA de navegador nas chamadas Geotab → evita bloqueio WAF/Cloudflare (403)
- Views filtram grupos OPE_*/terceiros via `todos_grupos NOT LIKE`

## Gotchas / armadilhas
- 403 não-JSON na autenticação Geotab = bloqueio WAF (IP do Render), não credencial
- Quota Geotab: 5000 sub-chamadas/min — throttle proativo em 4500
- Fuso na busca de eventos: BRT rotulado como UTC "vaza" ~3h p/ dia anterior (floor_dia descarta)
- `_lock` é POR PROCESSO e cobre TODOS os modos: enquanto um modo roda (ex.: comportamento, que é longo), `/run/<outro>` é descartado. Antes respondia "iniciado" falso; agora responde 409 "ocupado". Se um modo trava (banco lento), starva os demais → tabelas congelam todas juntas.
- `GEOTAB_PROXY` (env): alterna o IP de saída das chamadas Geotab. Vazio = direto (local, IP limpo). Preenchido (`http://user:senha@host:porta`) = via proxy (Render, p/ furar o bloqueio de WAF). Só afeta requests da Geotab, não o Supabase (psycopg2). Modo ativo aparece em `/status` e `/health` no campo `saida_geotab` (credenciais mascaradas).

## Próximos passos
- [x] Banco Supabase estrangulado de IO (2026-06-12): RESOLVIDO — banco suspenso no fim de semana + reiniciado em 2026-06-15, voltou ao normal
- [ ] **CAUSA REAL da defasagem desde 04/jun = bloqueio de WAF (Cloudflare) da Geotab no IP de saída do Render (403 na auth).** Revelado pelo /status após a correção (antes ficava ultimo_erro=null por causa do sys.exit). Banco saudável NÃO resolve — auth falha antes. Soluções: (a) allowlist dos IPs de saída estáticos do Render no Geotab (pegar IPs no painel Render → Connect/Outbound; pedir liberação ao suporte/admin Geotab); (b) rotear chamadas Geotab por proxy com IP confiável; (c) rodar a sync de outro host cujo IP não esteja flagado (GitHub Action, VPS, máquina local agendada). UA de navegador já está no código e não basta — bloqueio é por IP.
- [ ] Confirmar RLS das tabelas após recuperação (views já corrigidas: security_invoker=on confirmado nas 7)
- [ ] Rerun linter no Advisors após recuperação (painel congelado — linter não roda com banco lento)
- [ ] Definir VIAGENS_DIAS=7 no Render antes de religar (sync diário regrava ano inteiro = provável causa do dreno de IO)
- [ ] Exportar definição de vw_grupos para views.sql (existe no banco, falta no arquivo)
- [ ] Considerar WITH (security_invoker = on) nas views do views.sql (CREATE OR REPLACE sem a opção pode resetar)

## Gotchas / armadilhas (sessão 2026-06-12)
- Projeto Supabase do geotab (ref dyqrxszogdcsjnhodmrv) está em OUTRA conta — integração MCP só vê "automultas"
- (check_lints.py / est_volume.py: REMOVIDOS 2026-06-17 — eram diagnósticos da era Supabase/free-tier, sem sentido no local.)
- Lints corrigidos com: ALTER VIEW ... SET (security_invoker = on) + ALTER TABLE ... ENABLE ROW LEVEL SECURITY (sem policies — consumo é só conexão direta como owner)

## LIMITE DE DISCO ESTOURADO (2026-06-15) — banco em READ-ONLY
- Supabase free tier = 500 MB. Carga de viagens do ANO inteiro (geocode off) levou o banco a 890 MB e o Supabase forçou `default_transaction_read_only=on` (bloqueia INSERT/DELETE/TRUNCATE/DROP).
- Culpado: `tb_viagens` = 1.295.267 linhas / 834 MB (carga parou no lote 26/70; ano completo seria ~3,4M). As outras tabelas são pequenas (~1 MB cada; eventos = 42 MB) e foram atualizadas OK ANTES de encher.
- tb_viagens ano-corrente é INCOMPATÍVEL com o free tier. Caminhos: (a) no painel Supabase desativar read-only temporariamente → trim/TRUNCATE tb_viagens → usar VIAGENS_DIAS curto (ex.: 30-90d) p/ nunca reencher; (b) upgrade Pro (8 GB) se precisa do ano todo. Decisão pendente do usuário (custo x retenção) + ação no painel (só o dono faz).

## Bug corrigido (2026-06-15)
- `_limpar_buckets_antigos` e `_reconstruir_comportamento` usavam bind colado no cast PG (`:lim::date`, `:ini::date`). SQLAlchemy 2.0/psycopg2 não substitui o bind nesse formato → "syntax error at or near :". Corrigido p/ `CAST(:param AS date)`. (A contagem + upsert de buckets já tinha rodado; o erro era só na limpeza/reconstrução.)

## MIGRAÇÃO Supabase → Postgres LOCAL (2026-06-17)
- MOTIVO: Supabase free 500 MB estourado (banco a 671 MB) + RAM 512 MB do Render + IP do Render bloqueado pelo WAF da Geotab. Local resolve os 3 de graça.
- FEITO: PG 18.4 portátil (sem admin, zip já extraído). `initdb` em `C:\Users\ygor.kouzak\pgdata`, senha postgres = `geotab_iAGEz2pmgDhf`. Banco `geotab` criado. Dump do Supabase (session pooler porta 5432, `-n public --no-owner --no-acl`) → restore local. 7 tabelas + 7 views migradas; tb_enderecos (83k, cache geocode) e tb_viagens (2,1M) preservados.
- CÓDIGO: `criar_engine()` agora lê `SUPABASE_SSLMODE` de env (default require p/ nuvem; local=disable). Única mudança.
- .env repontado p/ localhost:5432/geotab; `VIAGENS_DIAS=0` (ano inteiro, sem limite de disco). Supabase antigo comentado p/ rollback.
- AUTOMAÇÃO (sem admin — criar tarefa no Agendador dá "Acesso negado" por GPO): `iniciar_postgres.bat` + `backup_geotab.bat` na pasta Inicializar (`shell:startup`) → rodam no logon. Sync continua na task `GeotabSyncLocal` (já existia). Backup diário (1/dia por data, mantém 14d) em `C:\Users\ygor.kouzak\backups`.
- LIGAR SOZINHO: inviável (notebook corporativo, sem admin/BIOS, GPO trava wake timers). Modelo é "liga o PC num dia útil → sync roda no logon".
- FEITO (usuário, 2026-06-17): On-premises Data Gateway configurado + dataset Power BI repontado p/ localhost; serviço do Render deletado. Inspeção via DBeaver (localhost:5432/geotab/postgres).

## Última sessão
- Data: 2026-06-17 (migração concluída; antes: 2026-06-15)
- Resumo: Banco recuperado (suspenso no fim de semana + reiniciado hoje). Diagnosticado o "rodei /run/cadastro e não atualizou": no momento da chamada o comportamento segurava o `_lock`, a thread do cadastro foi descartada, mas `/run` respondia "iniciado" falso (sem registrar erro). Correções aplicadas:
  - `app.py`: `executar_sync` → `_disparar` (adquire lock e passa p/ thread) + `_executar_com_lock` (captura BaseException). `/run/<modo>` agora responde 409 "ocupado" quando o lock está tomado.
  - `geotab_supabase.py`: `autenticar()` levanta `GeotabAuthError` em vez de `sys.exit(1)` (SystemExit escapava do except do worker); `extrair_cadastro` aborta com erro se a Geotab retorna 0 devices (não grava vazio em silêncio).
