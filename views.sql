-- Views do projeto Geotab -> Supabase (geradas do banco)
-- Coluna todos_grupos adicionada em status, comportamento, resumo_frota e indicadores.
-- Em vw_indicadores_produtividade o agrupamento passou a ser por todos_grupos.
--
-- Períodos de cada view (todas expõem datas):
--   vw_cadastro                  snapshot atual           (atualizado_em)
--   vw_status                    tempo real / snapshot     (snapshot_em, ultimo_contato)
--   vw_comportamento             últimos 6 meses           (periodo_ini, periodo_fim)
--   vw_relatorio_viagens         últimos 30 dias (por viagem) (data_partida, data_chegada, atualizado_em)
--   vw_resumo_frota              últimos 30 dias (janela móvel) (data_ini, data_fim)
--   vw_indicadores_produtividade últimos 30 dias (janela móvel) (data_ini, data_fim)
-- Views MENSAIS (filtráveis por ano/mes no BI; cobrem o ano sem guardar viagens cruas):
--   vw_comportamento_mensal      por mês, ~6 meses (dos buckets) (ano, mes, ano_mes)
--   vw_resumo_frota_mensal       por veículo×mês, ano 2026       (ano, mes, ano_mes)
--   vw_indicadores_mensal        por grupo×mês, ano 2026         (ano, mes, ano_mes)
-- NOTA: o DETALHE (vw_relatorio_viagens) é 30 dias porque o ano inteiro de viagens
-- cruas não cabe no free tier (500 MB). Os indicadores cobrem o ano via AGREGADO
-- mensal (tb_resumo_mensal, ~21k linhas/ano) — por isso filtram por mês sem o detalhe.

-- ============================================================
-- vw_cadastro
-- ============================================================
CREATE OR REPLACE VIEW vw_cadastro AS
 SELECT id,
    serial,
    placa,
    veiculo,
    marca,
    modelo,
    ano,
    tipo_veiculo,
    grupo,
    todos_grupos,
    ativo,
    atualizado_em
   FROM tb_cadastro
  WHERE todos_grupos !~~ '%OPE_SEINFRA%'::text AND todos_grupos !~~ '%OPE_COMURG%'::text AND todos_grupos !~~ '%P-CSB%'::text AND todos_grupos !~~ '%OPE_CS_BRASIL%'::text AND todos_grupos !~~ '%OPE_PEDREIRA%'::text AND todos_grupos !~~ '%OPE_SECRET. DA ECONOMIA - 018/2025%'::text AND todos_grupos !~~ '%OPE_SEPLANH%'::text AND todos_grupos !~~ '%OPE_SMT%'::text AND todos_grupos !~~ '%OPE - ADMINISTRATIVO%'::text AND todos_grupos !~~ '%OPE - ASSISTENCIA SOCIAL%'::text AND todos_grupos !~~ '%OPE - DIRETORIA/GERENCIA%'::text AND todos_grupos !~~ '%OPE - RECOLHIMENTO DE ANIMAIS%'::text AND todos_grupos !~~ '%OPE - SERVIÇOS EM CAMPO%'::text AND todos_grupos !~~ '%OPE_AGETUL%'::text AND todos_grupos !~~ '%OPE_AMMA%'::text AND todos_grupos !~~ '%OPE_SEMAD - 006/2020%'::text AND todos_grupos !~~ '%OPE - DIRETORIA/GERÊNCIA%'::text AND todos_grupos !~~ '%OPE_SECULT%'::text AND (grupo <> ALL (ARRAY['OPE - ADMINISTRATIVO'::text, 'OPE - ASSISTENCIA SOCIAL'::text, 'OPE - DIRETORIA/GERÊNCIA'::text, 'OPE - DIRETORIA/GERENCIA'::text, 'OPE - RECOLHIMENTO DE ANIMAIS'::text, 'OPE - SERVIÇOS EM CAMPO'::text, 'OPE_AGETUL'::text, 'OPE_AMMA'::text, 'OPE_SEMAD'::text, 'OPE_SEMAD - 006/2020'::text, 'REDEMOB CONSÓRCIO - 008/2025'::text]));

-- ============================================================
-- vw_status
-- ============================================================
CREATE OR REPLACE VIEW vw_status AS
 SELECT s.id,
    s.serial,
    s.placa,
    s.comunicando,
    s.ultimo_contato,
    s.latitude,
    s.longitude,
    s.velocidade,
    s.ignicao_ligada,
    s.motorista_nome,
    s.motorista_email,
    s.motorista_tel,
    s.viagem_inicio,
    s.snapshot_em,
    s.viagem_fim,
    s.todos_grupos
   FROM tb_status s
     JOIN vw_cadastro c ON c.id = s.id
  WHERE c.todos_grupos !~~ '%OPE_COMURG%'::text AND c.todos_grupos !~~ '%P-CSB%'::text AND c.todos_grupos !~~ '%OPE_CS_BRASIL%'::text AND c.todos_grupos !~~ '%OPE_PEDREIRA%'::text AND c.todos_grupos !~~ '%OPE_SECRET. DA ECONOMIA - 018/2025%'::text AND c.todos_grupos !~~ '%OPE_SEPLANH%'::text AND c.todos_grupos !~~ '%OPE_SMT%'::text AND c.todos_grupos !~~ '%OPE - ADMINISTRATIVO%'::text AND c.todos_grupos !~~ '%OPE - ASSISTENCIA SOCIAL%'::text AND c.todos_grupos !~~ '%OPE - ASSISTÊNCIA SOCIAL%'::text AND c.todos_grupos !~~ '%OPE - DIRETORIA/GERENCIA%'::text AND c.todos_grupos !~~ '%OPE - RECOLHIMENTO DE ANIMAIS%'::text AND c.todos_grupos !~~ '%OPE - SERVIÇOS EM CAMPO%'::text AND c.todos_grupos !~~ '%OPE_AGETUL%'::text AND c.todos_grupos !~~ '%OPE_AMMA%'::text AND c.todos_grupos !~~ '%OPE_SEMAD - 006/2020%'::text AND c.todos_grupos !~~ '%OPE - DIRETORIA/GERÊNCIA%'::text AND c.todos_grupos !~~ '%OPE_SECULT%'::text AND (c.grupo <> ALL (ARRAY['OPE - ADMINISTRATIVO'::text, 'OPE - ASSISTENCIA SOCIAL'::text, 'OPE - ASSISTÊNCIA SOCIAL'::text, 'OPE - DIRETORIA/GERÊNCIA'::text, 'OPE - DIRETORIA/GERENCIA'::text, 'OPE - RECOLHIMENTO DE ANIMAIS'::text, 'OPE - SERVIÇOS EM CAMPO'::text, 'OPE_AGETUL'::text, 'OPE_AMMA'::text, 'OPE_SEMAD'::text, 'OPE_SEMAD - 006/2020'::text, 'REDEMOB CONSÓRCIO - 008/2025'::text]));

-- ============================================================
-- vw_comportamento
-- ============================================================
CREATE OR REPLACE VIEW vw_comportamento AS
 SELECT cmp.id,
    cmp.serial,
    cmp.placa,
    cmp.excessos_velocidade_6m,
    cmp.aceleracoes_bruscas_6m,
    cmp.frenagens_bruscas_6m,
    cmp.curvas_drasticas_6m,
    cmp.ultimo_excesso_vel,
    cmp.ultima_acel_brusca,
    cmp.ultima_fren_brusca,
    cmp.ultima_curva_drastica,
    cmp.score_risco,
    cmp.odometro,
    cmp.atualizado_em,
    -- Janela dos contadores *_6m: 6 meses até o momento da extração.
    (cmp.atualizado_em - '6 mons'::interval) AS periodo_ini,
    cmp.atualizado_em AS periodo_fim,
    cmp.odometro_gps,
    cmp.todos_grupos
   FROM tb_comportamento cmp
     JOIN vw_cadastro c ON c.id = cmp.id
  WHERE c.todos_grupos !~~ '%OPE_COMURG%'::text AND c.todos_grupos !~~ '%P-CSB%'::text AND c.todos_grupos !~~ '%OPE_CS_BRASIL%'::text AND c.todos_grupos !~~ '%OPE_PEDREIRA%'::text AND c.todos_grupos !~~ '%OPE_SECRET. DA ECONOMIA - 018/2025%'::text AND c.todos_grupos !~~ '%OPE_SEPLANH%'::text AND c.todos_grupos !~~ '%OPE_SMT%'::text AND c.todos_grupos !~~ '%OPE - ADMINISTRATIVO%'::text AND c.todos_grupos !~~ '%OPE - ASSISTENCIA SOCIAL%'::text AND c.todos_grupos !~~ '%OPE - ASSISTÊNCIA SOCIAL%'::text AND c.todos_grupos !~~ '%OPE - DIRETORIA/GERENCIA%'::text AND c.todos_grupos !~~ '%OPE - RECOLHIMENTO DE ANIMAIS%'::text AND c.todos_grupos !~~ '%OPE - SERVIÇOS EM CAMPO%'::text AND c.todos_grupos !~~ '%OPE_AGETUL%'::text AND c.todos_grupos !~~ '%OPE_AMMA%'::text AND c.todos_grupos !~~ '%OPE_SEMAD - 006/2020%'::text AND c.todos_grupos !~~ '%OPE - DIRETORIA/GERÊNCIA%'::text AND c.todos_grupos !~~ '%OPE_SECULT%'::text AND (c.grupo <> ALL (ARRAY['OPE - ADMINISTRATIVO'::text, 'OPE - ASSISTENCIA SOCIAL'::text, 'OPE - DIRETORIA/GERÊNCIA'::text, 'OPE - DIRETORIA/GERENCIA'::text, 'OPE - RECOLHIMENTO DE ANIMAIS'::text, 'OPE - SERVIÇOS EM CAMPO'::text, 'OPE_AGETUL'::text, 'OPE_AMMA'::text, 'OPE_SEMAD'::text, 'OPE_SEMAD - 006/2020'::text, 'REDEMOB CONSÓRCIO - 008/2025'::text]));

-- ============================================================
-- vw_relatorio_viagens
-- ============================================================
-- placa/veiculo/grupo/todos_grupos vêm de tb_cadastro (JOIN por device_id);
-- end_partida/end_chegada vêm de tb_enderecos (JOIN por coord arredondada a 3
-- casas = GEOCODE_CASAS). Nada de texto repetido em tb_viagens (free tier).
CREATE OR REPLACE VIEW vw_relatorio_viagens
WITH (security_invoker = on) AS
 SELECT c.placa,
    c.veiculo,
    c.grupo AS uo_lotacao,
    c.todos_grupos,
    v.data_partida,
    v.data_chegada,
    v.duracao_segundos,
    to_char((v.duracao_segundos || ' seconds'::text)::interval, 'HH24:MI'::text) AS duracao_hhmm,
    v.distancia_km,
    v.hodometro_inicial,
    v.hodometro_final,
    v.velocidade_media,
    v.velocidade_maxima,
    ep.endereco AS end_partida,
    ec.endereco AS end_chegada,
    v.motorista_nome,
    v.motorista_matricula
   FROM tb_viagens v
     LEFT JOIN tb_cadastro c  ON c.id  = v.device_id
     LEFT JOIN tb_enderecos ep ON ep.lat = round(v.lat_partida::numeric, 3) AND ep.lon = round(v.lon_partida::numeric, 3)
     LEFT JOIN tb_enderecos ec ON ec.lat = round(v.lat_chegada::numeric, 3) AND ec.lon = round(v.lon_chegada::numeric, 3)
  ORDER BY c.placa, v.data_partida;

-- ============================================================
-- vw_resumo_frota
-- ============================================================
CREATE OR REPLACE VIEW vw_resumo_frota
WITH (security_invoker = on) AS
 WITH params AS (
         SELECT CURRENT_DATE - '30 days'::interval AS data_ini,
            CURRENT_DATE::timestamp without time zone AS data_fim
        )
 SELECT c.placa,
    c.grupo AS uo_lotacao,
    EXTRACT(day FROM p.data_fim - p.data_ini)::integer AS dias_no_periodo,
    count(DISTINCT v.data_partida::date) AS dias_utilizados,
    round(sum(v.distancia_km)::numeric, 1) AS km_rodado,
    round((sum(v.distancia_km) / NULLIF(count(DISTINCT v.data_partida::date), 0)::double precision)::numeric, 1) AS media_km_dia,
    round(sum(v.duracao_segundos)::numeric / 3600.0, 1) AS tempo_movimento_h,
    round(count(DISTINCT v.data_partida::date)::numeric / NULLIF(EXTRACT(day FROM p.data_fim - p.data_ini), 0::numeric) * 100::numeric, 0) AS taxa_utilizacao_pct,
    c.todos_grupos
   FROM tb_viagens v
     LEFT JOIN tb_cadastro c ON c.id = v.device_id
     CROSS JOIN params p
  WHERE v.data_partida >= p.data_ini AND v.data_partida <= p.data_fim
  GROUP BY c.placa, c.grupo, c.todos_grupos, p.data_ini, p.data_fim
  ORDER BY c.placa;

-- ============================================================
-- vw_indicadores_produtividade
-- ============================================================
CREATE OR REPLACE VIEW vw_indicadores_produtividade
WITH (security_invoker = on) AS
 WITH params AS (
         SELECT CURRENT_DATE - '30 days'::interval AS data_ini,
            CURRENT_DATE::timestamp without time zone AS data_fim
        ), por_veiculo AS (
         SELECT c.grupo AS uo_lotacao,
            c.todos_grupos,
            c.placa,
            sum(v.distancia_km) AS km_veiculo,
            sum(v.duracao_segundos) AS seg_veiculo,
            count(DISTINCT v.data_partida::date) AS dias_utilizados,
            EXTRACT(day FROM p.data_fim - p.data_ini) AS dias_periodo
           FROM tb_viagens v
             LEFT JOIN tb_cadastro c ON c.id = v.device_id
             CROSS JOIN params p
          WHERE v.data_partida >= p.data_ini AND v.data_partida <= p.data_fim
          GROUP BY c.grupo, c.todos_grupos, c.placa, p.data_ini, p.data_fim
        )
 SELECT uo_lotacao,
    count(*) AS qtd_veiculos,
    round(sum(km_veiculo)::numeric, 0) AS km_total,
    round((sum(km_veiculo) / NULLIF(count(*), 0)::double precision)::numeric, 0) AS media_km_veiculo,
    round(sum(seg_veiculo) / 3600.0, 0) AS tempo_movimento_h,
    round(avg(dias_utilizados::numeric / NULLIF(dias_periodo, 0::numeric) * 100::numeric), 0) AS taxa_media_utilizacao_pct,
    todos_grupos
   FROM por_veiculo
  GROUP BY uo_lotacao, todos_grupos
  ORDER BY todos_grupos;

-- ============================================================
-- vw_comportamento_mensal  (eventos por mês, dos buckets; filtra por ano/mes)
-- ============================================================
CREATE OR REPLACE VIEW vw_comportamento_mensal
WITH (security_invoker = on) AS
 SELECT e.device_id AS id,
    c.serial, c.placa, c.todos_grupos,
    EXTRACT(year  FROM date_trunc('month', e.dia))::int AS ano,
    EXTRACT(month FROM date_trunc('month', e.dia))::int AS mes,
    to_char(date_trunc('month', e.dia), 'YYYY-MM') AS ano_mes,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo='excesso_velocidade'),0) AS excessos_velocidade,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo='aceleracao_brusca'),0)  AS aceleracoes_bruscas,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo='frenagem_brusca'),0)    AS frenagens_bruscas,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo='curva_drastica'),0)     AS curvas_drasticas,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo='excesso_velocidade'),0)*3
      + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo='aceleracao_brusca'),0)*2
      + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo='frenagem_brusca'),0)*2
      + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo='curva_drastica'),0)*1 AS score_risco
   FROM tb_comportamento_eventos e
     JOIN vw_cadastro c ON c.id = e.device_id
  GROUP BY e.device_id, c.serial, c.placa, c.todos_grupos, date_trunc('month', e.dia);

-- ============================================================
-- vw_resumo_frota_mensal  (por veículo × mês, ano 2026; filtra por ano/mes)
-- Fonte: tb_resumo_mensal (agregado). dias_no_periodo = dias do mês até hoje.
-- ============================================================
CREATE OR REPLACE VIEW vw_resumo_frota_mensal
WITH (security_invoker = on) AS
 WITH base AS (
   SELECT r.device_id, r.ano, r.mes, r.km, r.duracao_segundos, r.dias_utilizados, r.viagens,
          c.placa, c.grupo AS uo_lotacao, c.todos_grupos,
          (LEAST((date_trunc('month', make_date(r.ano, r.mes, 1)) + interval '1 month' - interval '1 day')::date, CURRENT_DATE)
            - date_trunc('month', make_date(r.ano, r.mes, 1))::date + 1) AS dias_no_periodo
     FROM tb_resumo_mensal r JOIN vw_cadastro c ON c.id = r.device_id)
 SELECT placa, uo_lotacao, todos_grupos, ano, mes,
        to_char(make_date(ano, mes, 1), 'YYYY-MM') AS ano_mes,
        dias_no_periodo, dias_utilizados,
        round(km::numeric, 1) AS km_rodado,
        round((km / NULLIF(dias_utilizados,0))::numeric, 1) AS media_km_dia,
        round((duracao_segundos/3600.0)::numeric, 1) AS tempo_movimento_h,
        round(dias_utilizados::numeric / NULLIF(dias_no_periodo,0) * 100, 0) AS taxa_utilizacao_pct,
        viagens
   FROM base
  ORDER BY placa, ano, mes;

-- ============================================================
-- vw_indicadores_mensal  (por grupo × mês, ano 2026; filtra por ano/mes)
-- ============================================================
CREATE OR REPLACE VIEW vw_indicadores_mensal
WITH (security_invoker = on) AS
 WITH base AS (
   SELECT r.device_id, r.ano, r.mes, r.km, r.duracao_segundos, r.dias_utilizados,
          c.grupo AS uo_lotacao, c.todos_grupos,
          (LEAST((date_trunc('month', make_date(r.ano, r.mes, 1)) + interval '1 month' - interval '1 day')::date, CURRENT_DATE)
            - date_trunc('month', make_date(r.ano, r.mes, 1))::date + 1) AS dias_no_periodo
     FROM tb_resumo_mensal r JOIN vw_cadastro c ON c.id = r.device_id)
 SELECT uo_lotacao, todos_grupos, ano, mes,
        to_char(make_date(ano, mes, 1), 'YYYY-MM') AS ano_mes,
        count(*) AS qtd_veiculos,
        round(sum(km)::numeric, 0) AS km_total,
        round((sum(km) / NULLIF(count(*),0))::numeric, 0) AS media_km_veiculo,
        round((sum(duracao_segundos)/3600.0)::numeric, 0) AS tempo_movimento_h,
        round(avg(dias_utilizados::numeric / NULLIF(dias_no_periodo,0) * 100), 0) AS taxa_media_utilizacao_pct
   FROM base
  GROUP BY uo_lotacao, todos_grupos, ano, mes
  ORDER BY todos_grupos, ano, mes;

