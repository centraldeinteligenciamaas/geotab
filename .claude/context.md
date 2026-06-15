# Contexto — geotab (sync Geotab → Supabase)

## Stack
- Python (Flask + APScheduler + SQLAlchemy/psycopg2 + pandas + requests)
- Banco: Supabase (Postgres, pooler transaction mode porta 6543, NullPool)
- Deploy: Render free tier (512 MB) — render.yaml
- Config via .env (credenciais Geotab + Supabase)

## Como rodar
- `python app.py` — sobe Flask na porta 5000 com scheduler
- Sync manual: `GET /run/<modo>` (cadastro | status | comportamento | viagens) com `?key=SYNC_API_KEY`
  - Responde `{"status":"iniciado"}` se conseguiu o lock; `409 {"status":"ocupado", ...}` se outra sync já está rodando (NÃO mais "iniciado" falso)
- `GET /status` — últimas atualizações + próximas execuções (ver `ultimo_erro`)

## Arquitetura (mapa de arquivos)
- `app.py` — Flask + agendamento (BRT, seg-sex): cadastro 04h, status 05h, comportamento 06h, viagens 21h; lock impede syncs simultâneos
- `geotab_supabase.py` — extração da API Geotab (JSON-RPC) e gravação no Supabase; cria/migra tabelas; throttle de quota (4500 sub-chamadas/60s)
- `views.sql` — definição atual das 6 views (com períodos documentados no header)
- `views_backup.sql` — backup das views
- `render.yaml` — config do deploy no Render

## Tabelas e períodos
- `tb_cadastro` — snapshot atual da frota (full refresh; `atualizado_em`)
- `tb_status` — snapshot tempo real (`snapshot_em`); motorista vem das trips das últimas 24h
- `tb_comportamento` — janela móvel de 6 meses (contadores `*_6m`); incremental via buckets
- `tb_comportamento_eventos` — buckets diários device/dia/tipo; mantém só os últimos 6 meses (limpeza automática)
- `tb_viagens` — ano corrente por padrão (`VIAGENS_DIAS=0`); `VIAGENS_DIAS>0` = janela móvel de N dias (smoke test)

## Views e períodos (header de views.sql)
- `vw_cadastro` — snapshot atual (`atualizado_em`)
- `vw_status` — tempo real (`snapshot_em`, `ultimo_contato`)
- `vw_comportamento` — últimos 6 meses (`periodo_ini`, `periodo_fim` = atualizado_em − 6m)
- `vw_relatorio_viagens` — ano corrente, por viagem (`data_partida`, `data_chegada`)
- `vw_resumo_frota` — ano corrente (`data_ini` = 1º jan, `data_fim` = hoje)
- `vw_indicadores_produtividade` — ano corrente; agrupado por `todos_grupos`

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
- `check_lints.py` (raiz) — script de diagnóstico de conexão/lints; rodar com PYTHONIOENCODING=utf-8 (console cp1252 quebra com "→")
- Lints corrigidos com: ALTER VIEW ... SET (security_invoker = on) + ALTER TABLE ... ENABLE ROW LEVEL SECURITY (sem policies — consumo é só conexão direta como owner)

## Última sessão
- Data: 2026-06-15
- Resumo: Banco recuperado (suspenso no fim de semana + reiniciado hoje). Diagnosticado o "rodei /run/cadastro e não atualizou": no momento da chamada o comportamento segurava o `_lock`, a thread do cadastro foi descartada, mas `/run` respondia "iniciado" falso (sem registrar erro). Correções aplicadas:
  - `app.py`: `executar_sync` → `_disparar` (adquire lock e passa p/ thread) + `_executar_com_lock` (captura BaseException). `/run/<modo>` agora responde 409 "ocupado" quando o lock está tomado.
  - `geotab_supabase.py`: `autenticar()` levanta `GeotabAuthError` em vez de `sys.exit(1)` (SystemExit escapava do except do worker); `extrair_cadastro` aborta com erro se a Geotab retorna 0 devices (não grava vazio em silêncio).
