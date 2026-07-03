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
- `atualizar_local.py` — orquestrador local: roda os 4 modos em subprocesso, seg-sex, 1x/dia (marcador `.ultima_atualizacao`). Disparado pela Tarefa `GeotabSyncLocal`. No fim, se todos OK, chama `_exportar_csv` (não-fatal).
- `exportar_csv.py` (2026-06-22) — exporta cada view p/ CSV e sobe no Supabase Storage (links de download p/ clientes externos). Ver seção "Download CSV externo".
- `powerbi_queries/*.m` (2026-07-01) — os 8 scripts M REAIS do usuário já adaptados p/ CSV público (fonte Web/Anônimo) = atualização agendada no Service SEM gateway, alternativa quando não dá p/ criar gateway (1 por view: cadastro/status/grupos/comportamento/motoristas/indicadores_mensal/resumo_frota_mensal/relatorio_viagens) + README. Cada script é AUTOSSUFICIENTE (sem funções auxiliares). Padrão `Web.Contents(base,[RelativePath=...])` p/ o Service aceitar URLs dinâmicas; viagens combinam todos os meses via index.html (aguenta `_p1`/`_p2`). Tipagem dobrada no passo `public_vw_*` (tipos de information_schema, cultura en-US); booleanos `t`/`f`→logical via `each _="t"`; `duracao_hhmm` fica texto (usuário converte p/ duration). Transformações originais (filtros OPE_*, Proper, etc.) intactas. (O guia `POWERBI_WEB_QUERIES.md` foi apagado pelo usuário 2026-07-01 — redundante, pois os scripts são autossuficientes.)
- `iniciar_postgres.bat` — sobe o Postgres local (pasta Inicializar/logon). Desde 2026-07-01: seta title da janela + banner explicando que a janela hospeda o banco (não fechar durante Power BI/sync; fechar = derruba o PG) + loop `timeout` p/ manter a janela aberta.
- `backup_geotab.bat` — pg_dump diário p/ `C:\Users\ygor.kouzak\backups` (mantém 14 dias; pasta Inicializar/logon).
- `views.sql` / `views_backup.sql` — definição/backup das views.
- (REMOVIDOS 2026-06-17: `app.py`, `render.yaml`, gunicorn/Flask/APScheduler.)

## Tabelas e períodos
- `tb_cadastro` — snapshot atual da frota (full refresh; `atualizado_em`)
- `tb_status` — snapshot tempo real (`snapshot_em`); motorista vem das trips das últimas 24h
- `tb_comportamento` — janela móvel de 6 meses (contadores `*_6m`); incremental via buckets
- `tb_comportamento_eventos` — buckets diários device/dia/tipo; janela = ANO CORRENTE (DATA_CORTE), ALINHADA com tb_viagens (antes era 6 meses móveis; alinhado 2026-06-18 p/ o km do score não descasar dos eventos). Limpeza apaga < DATA_CORTE.
- `tb_comportamento_motorista` (2026-06-18) — MESMOS eventos, mas por motorista/device/dia/tipo (captura `ev["driver"]` no `processar()`, antes descartado). device_id é a CHAVE de ligação com tb_comportamento_eventos. Só eventos com motorista identificado (~40-57%). Janela = ano corrente (DATA_CORTE, igual aos eventos/viagens). Base da vw_motoristas. Backfill via env `COMPORTAMENTO_BACKFILL=1` (one-shot; força backfill mesmo com buckets existentes — re-upsert idempotente dos device buckets + preenche os por motorista).
- `tb_viagens` — JANELA MÓVEL DE 30 DIAS (`VIAGENS_DIAS=30`, fixado no free tier). `sincronizar_viagens` PODA (`DELETE data_partida < data_inicio`) quando `VIAGENS_DIAS>0` — sem isso o upsert nunca apaga e reenche o disco.
- VIAGENS INCREMENTAL (2026-06-18): no modo ano-corrente (`VIAGENS_DIAS=0`, atual no local) a sync NÃO rebaixa mais a janela p/ 1º/jan todo dia (re-buscava o ano inteiro, ~70 lotes/~1h30). `VIAGENS_INCREMENTAL=1` (default) + `_ultima_partida_gravada()` começam a janela em `max(data_partida) − VIAGENS_MARGEM_DIAS` (default 3d, cobre viagens em curso/revisadas; upsert por id não duplica). Vazio → cai p/ 1º/jan (primeira carga). Log mostra `[incremental ...]` / `[ano corrente]`. Nº de lotes (71) NÃO muda (é por device, 25/lote); o que cai é o volume/geocode por lote. Poda segue só com VIAGENS_DIAS>0 (incremental mantém o ano todo).
- GEOCODE por LOOKUP (2026-06-15): endereços ficam em `tb_enderecos` (coord arredondada→endereço), NÃO em tb_viagens. `vw_relatorio_viagens` traz `end_partida`/`end_chegada` por JOIN em `round(lat/lon, 3)`. `geocodificar_enderecos()` (chamada no fim de sincronizar_viagens se VIAGENS_GEOCODE on) é incremental: só geocodifica coords novas. `GEOCODE_CASAS=3` (~110m) dedup ~1,4M→83k coords (geocode trip-a-trip era inviável, dias). IMPORTANTE: o `round(...,3)` da view tem que casar com GEOCODE_CASAS.
- COLUNAS DE PARADA (2026-06-18): `tempo_ocioso_segundos` (Trip.idlingDuration = parado c/ motor ligado) e `duracao_parada_segundos` (Trip.stopDuration = tempo parado no destino) em tb_viagens, capturadas em `_montar_viagem_row`, migração ADD COLUMN em `migrar_colunas`. Expostas em `vw_relatorio_viagens` (+ `*_hhmm` via H:MM manual que suporta >24h). SÓ preenchem em viagens (re)sincronizadas — linhas antigas ficam NULL até um backfill total (VIAGENS_INCREMENTAL=0). Em 2026-06-18 só os ~3 dias recentes (~101k linhas) têm valor; resto NULL.
- tb_viagens ENXUTA (2026-06-15): removidas serial/placa/veiculo/grupo/todos_grupos/regional/superintendencia (~190 MB de texto repetido). placa/veiculo/grupo/todos_grupos agora vêm de tb_cadastro via JOIN (por device_id) nas views *_viagens; regional/superintendencia eram peso morto (nenhuma view usava). Resultado: banco 484→259 MB, tb_viagens 429→204 MB, ~241 MB de folga. 0 viagens órfãs (todo device casa com tb_cadastro). 709.767 viagens / 30 dias.

## Piso temporal: SOMENTE 2026 (2026-06-16)
- `DATA_CORTE`/`ANO_CORTE` (env `ANO_CORTE`, default 2026) em geotab_supabase.py. Nenhuma tabela guarda dados < 2026-01-01. Aplicado como floor nas janelas: comportamento (`janela_ini=max(6m, corte)`), viagens (`data_inicio>=corte`), odômetro (clamp + DELETE <corte), resumo mensal (skip `ts.year<corte`). Limpeza única feita: removidos 2025-12 de comportamento_eventos/odometro_dia/resumo_mensal. Para virar o ano, bump ANO_CORTE.

## Views e períodos (UMA por tema; header de views.sql) — reorg 2026-06-16
- `vw_cadastro` — snapshot atual (`atualizado_em`)
- `vw_status` — tempo real (`snapshot_em`, `ultimo_contato`)
- `vw_comportamento` — POR DIA (device×dia), ~6 meses (`data`, `ano`, `mes`); eventos dos buckets + `odometro`/`odometro_gps` do dia (JOIN tb_odometro_dia). 129k linhas.
- `vw_relatorio_viagens` — últimos 30 dias, por viagem (`data_partida`, `data_chegada`)
- `tb_motoristas` (2026-06-18) — dimensão de motoristas (entidade User). `nome` = login/e-mail (User.name); `nome_completo` (2026-06-19) = nome próprio (User.firstName, 100% preenchido; lastName é lixo numérico, ignorado); `matricula` = User.employeeNo (~98%); `lotacao` (grupo ULOT_), `regional` (REG_), `superintendencia` (SUP_), `todos_grupos`. Populada no modo `cadastro` (`extrair_motoristas`, mesma fonte de Group do cadastro). 3.630 motoristas; companyGroups vem 100% preenchido.
- `vw_motoristas` (2026-06-18) — POR DIA (motorista × `data`), espelha vw_comportamento; BI agrega no período. Cols: motorista_nome/matricula, `lotacao`/`regional`/`superintendencia` (JOIN tb_motoristas), data/ano/mes, qtd_veiculos, `veiculos` (string_agg placas), viagens, km, horas movimento/ocioso/parado, contadores de eventos e `score_risco` (ponderado: excesso×3+acel×2+fren×2+curva×1, igual vw_comportamento). FULL JOIN viagens_dia × eventos_dia (não perde dia). Janelas alinhadas (ambas ano/DATA_CORTE). O score 0-100 estilo Geotab (Event Count: `100 - SUM(total_eventos)*1000/SUM(km)`, piso de km a gosto) vira MEDIDA no BI sobre o período — por dia não faz sentido (km baixo). Era anual c/ score_seguranca 0-100 até virar diária em 2026-06-18.
- `vw_resumo_frota_mensal` — por veículo×mês, ano 2026 (`ano`, `mes`, `ano_mes`). Cols `marca`+`modelo` (de tb_cadastro via JOIN) add 2026-06-19, logo após `placa`. Recriada com DROP+CREATE (CREATE OR REPLACE não aceita coluna no meio da lista). NOTA: a view NÃO expõe device_id (PK real = tb_cadastro.id); 152 equipamentos sem placa ficam indistinguíveis no BI.
- `vw_motoristas_anual` (2026-06-19) — versão AGREGADA NO ANO da vw_motoristas (1 linha/motorista). Restaurada do git (commit 4ce68c4) p/ o Power BI legado, que foi feito no formato antigo ANTES de a vw_motoristas virar diária (2026-06-18). Mantém os nomes antigos: `km_total` (não `km`), `excesso_velocidade`/`aceleracao_brusca`/`frenagem_brusca`/`curva_drastica` (singular, não plural) e `score_seguranca` 0-100 Event Count (não `score_risco` ponderado). 2.639 motoristas. A vw_motoristas (diária) segue intacta p/ análise por período.
- COL `todos_grupos` add às DUAS views de motoristas (vw_motoristas e vw_motoristas_anual) em 2026-06-19, após `superintendencia` (vem de m.todos_grupos / tb_motoristas, que já tinha a coluna). DROP+CREATE nas duas.
- COL `motorista_nome_completo` (= m.nome_completo / User.firstName) add às DUAS views em 2026-06-19, logo após `motorista_nome` (que segue sendo o e-mail/login). Resolve a queixa de "nome" — agora há o nome próprio. No BI, usar `motorista_nome_completo` como display.
- MATRÍCULA (investigado 2026-06-19): NÃO há "metade sem matrícula" — cobertura real ~98% em todas as fontes (tb_motoristas 83/3630=2,3% vazias; vw_motoristas 0,4%; vw_motoristas_anual 0,6%). O campo `nome` guarda o LOGIN/e-mail (`User.name`, ex. fabiosm@saneago.com.br), NÃO o nome próprio; a matrícula é `employeeNo` (ex. M140040). Os poucos sem matrícula são contas genéricas/reserva sem employeeNo na Geotab. Se o Power BI mostra ~metade, o problema é no modelo do BI (relacionamento/fan-out/cache), não no banco.
- `vw_indicadores_mensal` — por grupo×mês, ano 2026 (`ano`, `mes`, `ano_mes`)
- REMOVIDAS (2026-06-16): views `vw_comportamento_mensal`/`vw_resumo_frota`/`vw_indicadores_produtividade` (1 view por tema) e a TABELA `tb_comportamento` (dropada). vw_comportamento usa os buckets; odômetro migrou p/ tb_odometro_dia.
- `tb_odometro_dia` — odômetro POR DIA (device×dia, último valor do dia, físico+GPS). Preenchido por `sincronizar_odometro_dia` (chamado no fim de sincronizar_comportamento; incremental = dias novos). Substitui o odômetro que vivia em tb_comportamento. Funções antigas buscar_odo_gps/fisico/_com_fallback_ano/_reconstruir/_ler_odo_anterior TODAS removidas (limpeza 2026-06-17).
- `tb_resumo_mensal` — agregado km/tempo/dias/viagens por device×mês (~21k linhas/ano). Mês corrente: atualizado no sync de viagens via `atualizar_resumo_mes_corrente` (SQL de tb_viagens, sem Geotab). Meses passados: `backfill_resumo_mensal` (Geotab, uma vez). placa/grupo via JOIN tb_cadastro nas views.
- NOTA: as views VIVAS já estavam em 30 dias; o `views.sql` estava DESATUALIZADO (dizia "ano corrente"). Arquivo sincronizado com o banco em 2026-06-15. Sempre conferir com `pg_get_viewdef` antes de assumir o que o arquivo diz.

## Taxa de utilização > 100% / dias_utilizados > dias_no_periodo (corrigido 2026-06-18)
- CAUSA: `dias_no_periodo` é calculado AO VIVO na view (`LEAST(fim_mes, CURRENT_DATE) - ini_mes + 1`). Linha de tb_resumo_mensal p/ um MÊS FUTURO (relativo a hoje) → dias_no_periodo ≤ 0 com dias_utilizados ≥ 1 → taxa > 100. Mês futuro surgia porque `atualizar_resumo_mes_corrente` só tinha limite INFERIOR (`data_partida >= ini do mês`); viagem com data vazada p/ o mês seguinte criava a linha. Intermitente (some quando os dados são reescritos).
- FIX: (1) código — `atualizar_resumo_mes_corrente` ganhou limite SUPERIOR (`AND data_partida < ini_mes + 1 mês`), confinando ao mês corrente. (2) views `vw_resumo_frota_mensal` e `vw_indicadores_mensal` — `WHERE make_date(ano,mes,1) <= CURRENT_DATE` (ignora meses não iniciados) + taxa com `LEAST(dias_utilizados, dias_no_periodo)` (nunca passa de 100). Power BI: dar refresh p/ limpar valores cacheados.

## Download CSV externo (exportar_csv.py → Supabase Storage) (2026-06-22)
- OBJETIVO: clientes externos baixam cada view via link público estável, SEM depender do notebook ligado (snapshot diário, não ao vivo — a máquina dorme/sem admin/GPO).
- DESENHO: após a sync, `exportar_csv.py` (via `psql \copy`, NÃO carrega na RAM) gera 1 arquivo de NOME FIXO por view e sobe no Storage com `x-upsert` (link nunca muda). Gera um `index.html` com todos os links = O link que se manda ao cliente. Pasta `exports/` (gitignored, recriada a cada run).
- 8 views "dashboard" → `.csv` inteiro (maior: vw_motoristas 39 MB). `vw_relatorio_viagens` (1,6 GB / 3,58M linhas, ano inteiro) → DIVIDIDA POR MÊS + gzip, PARTICIONADA POR TAMANHO (`_gzip_particionado`): cada parte tem CSV cru <= ALVO_CSV (180 MB) → gzip ~35 MB. Mês pequeno = `_YYYY-MM.csv.gz`; mês grande = `_YYYY-MM_p1/_p2.csv.gz`. ORDER BY data_partida piora a compressão vs arquivo único (gz por mês ~46-63 MB se inteiro, por isso o split).
- LIMITE FREE TIER: Supabase Storage = **50 MB POR ARQUIVO** no plano grátis (não-negociável). Mês inteiro gzipado passava de 50 MB e dava HTTP 400 → daí o particionamento (LIMITE_ARQUIVO/ALVO_CSV em exportar_csv.py). Storage total free = 1 GB (snapshot ~369 MB cabe).
- REFRESH: `limpar_bucket()` apaga TODOS os objetos antes de subir o snapshot do dia (evita órfãos quando um mês muda de nº de partes). Upload com `x-upsert`.
- ENCODING: `PGCLIENTENCODING=UTF8` é OBRIGATÓRIO no \copy — sem isso o psql assume WIN1252 do console e aborta no 1º acento.
- SUPABASE: o projeto antigo (dyqrxszogdcsjnhodmrv) foi DELETADO (DNS não resolve) após a migração p/ local. Criado projeto NOVO `geotab-export` (ref `ldhelbygqrjqchistrgp`, org ygormaas's/gsfnitfhyiwxoefcmojk, free, sa-east-1) só p/ Storage. URL + service_role key JÁ no .env; pipeline VALIDADO ao vivo 2026-06-22 (21 arquivos no ar, downloads públicos HTTP 200). Caveat free tier: projeto pausa após ~7d sem atividade (upload diário mantém acordado).
- LINK P/ O CLIENTE (índice de todos): `https://ldhelbygqrjqchistrgp.supabase.co/storage/v1/object/public/geotab-csv/index.html`. Arquivo direto: `{STORAGE_URL}/storage/v1/object/public/geotab-csv/<arquivo>`.
- BUG CORRIGIDO (2026-06-23): no fluxo automático o export era PULADO todo dia (`export CSV pulado (sem SUPABASE_SERVICE_KEY no .env)`). Causa: `atualizar_local.py` checava a chave via `os.environ` mas NÃO carregava o `.env` (só os modos/`exportar_csv.py` faziam `load_dotenv` por conta própria). Fix: `load_dotenv(BASE/".env")` no topo do orquestrador. Por isso só funcionava quando se rodava o `exportar_csv.py` na mão.

## Decisões importantes
- TIMESTAMP sem timezone, valores em BRT (Brasil sem horário de verão desde 2019)
- NullPool + pooler transaction mode → evita "max clients reached"
- Uma tabela por job/horário — rodar tudo junto estoura RAM do free tier
- UA de navegador nas chamadas Geotab → evita bloqueio WAF/Cloudflare (403)
- Views filtram grupos OPE_*/terceiros via `todos_grupos NOT LIKE`

## Gotchas / armadilhas
- POSTGRES CAI com 0xC000013A se FECHAREM A JANELA que o hospeda (2026-06-18; recorrente). Causa = STATUS_CONTROL_C_EXIT: fechar o terminal/console manda CTRL_CLOSE ao postmaster (que está pendurado nesse console) → "desligamento rápido". Derrubou a sync no meio (viagens → "connection refused localhost:5432"). Diagnóstico em `C:\Users\ygor.kouzak\pgdata\server.log`. Religar manual: `pg_ctl -D C:\Users\ygor.kouzak\pgdata -l ...\server.log start`.
- NÃO dá pra rodar o PG sem console nesta máquina: WSH/wscript BLOQUEADO (testado, .vbs não dispara) e `Start-Process -WindowStyle Hidden` BLOQUEADO ("operação cancelada"); serviço do Windows exige admin (GPO). Por isso a defesa é na SYNC, não no launcher.
- MITIGAÇÃO (2026-06-18): `atualizar_local.py` agora AUTO-CURA — `garantir_postgres()` (socket check 127.0.0.1:5432 + `pg_ctl start` + espera) roda ANTES da sync e DE NOVO se uma fase falhar, repetindo a fase 1×. Caminhos por env: `PG_CTL`/`PGDATA`/`PG_HOST`/`PG_PORT`. Validado ao vivo (porta fechada→religou). Regra p/ o usuário: nunca subir o banco por um terminal que vai fechar; deixar o logon (iniciar_postgres.bat no Startup) cuidar. Mesmo que feche e o PG morra, a próxima sync religa.
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
- Data: 2026-06-24
- Resumo: Sync diária de 24/jun OK (rodou 08:22, 4 fases, 93.220 viagens, marcador gravado). O export CSV automático rodou (load_dotenv do dia 23 funcionou — não foi mais "pulado") mas FALHOU não-fatal na etapa da vw_relatorio_viagens (1ª query psql, exit 0xC000013A = gotcha do PG/console). Rodado `exportar_csv.py` na mão logo depois: exit 0, snapshot público atualizado p/ 24/jun (8 views + viagens 2025-12..2026-06 em 2 partes/mês + index.html). Falha do automático considerada TRANSITÓRIA (mesmo script passou limpo na mão). Se recorrer no automático: blindar com retry na query do export ou respiro entre sync e export. Não commitado (sem mudança de código).
- Data: 2026-06-23
- Resumo: Sync diária de 23/jun OK (rodou às 08:23, 90.707 viagens, marcador gravado). Descoberto que o export CSV automático vinha sendo PULADO todo dia desde a criação (guard sem `load_dotenv` no orquestrador — ver BUG CORRIGIDO na seção Download CSV). Corrigido com `load_dotenv(BASE/".env")` em `atualizar_local.py`; guard validado (passa True). Rodado `exportar_csv.py` na mão p/ atualizar o snapshot público (estava de 22/jun): 21 arquivos no ar, snapshot de 23/jun. Commitado o pipeline CSV + o fix (era trabalho não-commitado de 22/jun).
- Data: 2026-06-22
- Resumo: Sync diária de 22/jun OK (marcador gravado). Criado pipeline de DOWNLOAD CSV EXTERNO (ver seção própria): `exportar_csv.py` + integração não-fatal no `atualizar_local.py` + template no .env + `exports/` no .gitignore. Medidos os tamanhos reais das 9 views (viagens = 1,6 GB, resto leve). Descoberto que o projeto Supabase do geotab foi deletado; criado projeto novo `geotab-export` via MCP (ACTIVE_HEALTHY, domínio responde 401=ok). Usuário colou a service_role key; pipeline LIGADO e VALIDADO ao vivo: bucket público `geotab-csv` criado, 21 arquivos no ar (8 views + viagens por mês particionada <50MB + index.html), downloads públicos HTTP 200. Descoberto/contornado o limite de 50 MB/arquivo do free tier (particionamento por tamanho) + limpeza do bucket por refresh. NÃO commitado.
- Data: 2026-06-19
- Resumo: Sync diária de 19/jun rodou OK (4 fases, 135.656 viagens, marcador gravado). Adicionadas `marca`+`modelo` à `vw_resumo_frota_mensal` (só nessa view, a pedido) — em views.sql e no banco local (DROP+CREATE p/ inserir após `placa`). vw_indicadores_mensal não mexida. Criada `vw_motoristas_anual` (formato antigo, `km_total`/nomes legados) p/ destravar o Power BI que quebrava com `42703: coluna km_total não existe` (modelo feito na vw_motoristas anual, que virou diária em 18/jun). Add `todos_grupos` às duas views de motoristas. Investigada a queixa de "metade sem matrícula": é falso — cobertura real ~98% (ver seção views); `nome`=login/e-mail, matrícula=employeeNo. Add coluna `nome_completo` (User.firstName, 100% preenchido) em tb_motoristas + extrair_motoristas + migração; exposta como `motorista_nome_completo` nas duas views. PG caiu no meio (gotcha 0xC000013A) e foi religado. NÃO commitado.
- Data: 2026-06-18
- Resumo: Implementado modo INCREMENTAL nas viagens (`VIAGENS_INCREMENTAL`/`VIAGENS_MARGEM_DIAS` + `_ultima_partida_gravada`) — ver seção tb_viagens. VALIDADO ao vivo: janela caiu p/ 3 dias, 100k viagens (vs ~700k) e geocode 226 coords; fase viagens ~7min (vs ~1h30). A sync das 08h FALHOU (Postgres caiu às 08:21, ver gotcha abaixo) — religuei o banco e re-rodei o orquestrador OK (marcador 2026-06-18 gravado).
- Tratada a fragilidade do Postgres a fechamento de janela (0xC000013A): auto-cura no orquestrador (ver gotcha). WSH e janela-oculta confirmados bloqueados pelo ambiente; serviço exige admin. Startup voltou ao iniciar_postgres.bat.
- Data: 2026-06-17 (migração concluída; antes: 2026-06-15)
- Resumo: Banco recuperado (suspenso no fim de semana + reiniciado hoje). Diagnosticado o "rodei /run/cadastro e não atualizou": no momento da chamada o comportamento segurava o `_lock`, a thread do cadastro foi descartada, mas `/run` respondia "iniciado" falso (sem registrar erro). Correções aplicadas:
  - `app.py`: `executar_sync` → `_disparar` (adquire lock e passa p/ thread) + `_executar_com_lock` (captura BaseException). `/run/<modo>` agora responde 409 "ocupado" quando o lock está tomado.
  - `geotab_supabase.py`: `autenticar()` levanta `GeotabAuthError` em vez de `sys.exit(1)` (SystemExit escapava do except do worker); `extrair_cadastro` aborta com erro se a Geotab retorna 0 devices (não grava vazio em silêncio).
