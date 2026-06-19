-- Views do projeto Geotab -> Supabase (geradas do banco)
-- Coluna todos_grupos adicionada em status, comportamento, resumo_frota e indicadores.
-- Em vw_indicadores_produtividade o agrupamento passou a ser por todos_grupos.
--
-- UMA view por tema. Granularidade na menor disponível p/ o BI agregar (dia/mês/período):
--   vw_cadastro             snapshot atual                 (atualizado_em)
--   vw_status               tempo real / snapshot          (snapshot_em, ultimo_contato)
--   vw_comportamento        POR DIA (device×dia), ~6 meses (data, ano, mes)  ← dos buckets
--   vw_relatorio_viagens    últimos 30 dias (por viagem)   (data_partida, data_chegada)
--   vw_resumo_frota_mensal  por veículo×mês, ano 2026      (ano, mes, ano_mes)
--   vw_indicadores_mensal   por grupo×mês, ano 2026        (ano, mes, ano_mes)
--   vw_motoristas           POR DIA (motorista×dia), ano 2026 (data, ano, mes; veículos+eventos)
-- Comportamento é diário (tb_comportamento_eventos tem 'dia'); resumo/indicadores são
-- mensais porque só guardamos o agregado mensal do ano (tb_resumo_mensal) — o detalhe
-- de viagens do ano inteiro não cabe no free tier (500 MB), só os últimos 30 dias.
-- REMOVIDAS (2026-06-16): vw_comportamento_mensal, vw_resumo_frota, vw_indicadores_produtividade.

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
-- POR DIA: 1 linha por device×dia com os eventos daquele dia (dos buckets de 6 meses)
-- + o odômetro do dia (último valor lido), via JOIN em tb_odometro_dia.
-- O BI agrega por dia/mês/período. score_risco = exc*3 + acel*2 + fren*2 + curva*1.
CREATE OR REPLACE VIEW vw_comportamento
WITH (security_invoker = on) AS
 SELECT e.device_id AS id,
    c.serial, c.placa, c.todos_grupos,
    e.dia AS data,
    EXTRACT(year  FROM e.dia)::int AS ano,
    EXTRACT(month FROM e.dia)::int AS mes,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo='excesso_velocidade'),0) AS excessos_velocidade,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo='aceleracao_brusca'),0)  AS aceleracoes_bruscas,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo='frenagem_brusca'),0)    AS frenagens_bruscas,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo='curva_drastica'),0)     AS curvas_drasticas,
    COALESCE(sum(e.qtd),0) AS total_eventos,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo='excesso_velocidade'),0)*3
      + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo='aceleracao_brusca'),0)*2
      + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo='frenagem_brusca'),0)*2
      + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo='curva_drastica'),0)*1 AS score_risco,
    o.odometro, o.odometro_gps
   FROM tb_comportamento_eventos e
     JOIN vw_cadastro c ON c.id = e.device_id
     LEFT JOIN tb_odometro_dia o ON o.device_id = e.device_id AND o.dia = e.dia
  GROUP BY e.device_id, c.serial, c.placa, c.todos_grupos, e.dia, o.odometro, o.odometro_gps;
/* Bloco antigo (agregado de 6 meses) — substituído pela agregação DIÁRIA acima:
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
*/

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
    v.tempo_ocioso_segundos,
    ((v.tempo_ocioso_segundos / 3600))::text || ':' || lpad((((v.tempo_ocioso_segundos % 3600) / 60))::text, 2, '0') AS tempo_ocioso_hhmm,
    v.duracao_parada_segundos,
    ((v.duracao_parada_segundos / 3600))::text || ':' || lpad((((v.duracao_parada_segundos % 3600) / 60))::text, 2, '0') AS duracao_parada_hhmm,
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
-- vw_resumo_frota_mensal  (por veículo × mês, ano 2026; filtra por ano/mes)
-- Fonte: tb_resumo_mensal (agregado). dias_no_periodo = dias do mês até hoje.
-- ============================================================
CREATE OR REPLACE VIEW vw_resumo_frota_mensal
WITH (security_invoker = on) AS
 WITH base AS (
   SELECT r.device_id, r.ano, r.mes, r.km, r.duracao_segundos, r.dias_utilizados, r.viagens,
          c.placa, c.marca, c.modelo, c.grupo AS uo_lotacao, c.todos_grupos,
          (LEAST((date_trunc('month', make_date(r.ano, r.mes, 1)) + interval '1 month' - interval '1 day')::date, CURRENT_DATE)
            - date_trunc('month', make_date(r.ano, r.mes, 1))::date + 1) AS dias_no_periodo
     FROM tb_resumo_mensal r JOIN vw_cadastro c ON c.id = r.device_id
    -- Ignora meses que ainda não começaram (linha de mês futuro daria dias_no_periodo
    -- ≤ 0 e taxa > 100%; pode surgir de data_partida vazada p/ o mês seguinte).
    WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE)
 SELECT placa, marca, modelo, uo_lotacao, todos_grupos, ano, mes,
        to_char(make_date(ano, mes, 1), 'YYYY-MM') AS ano_mes,
        dias_no_periodo, dias_utilizados,
        round(km::numeric, 1) AS km_rodado,
        round((km / NULLIF(dias_utilizados,0))::numeric, 1) AS media_km_dia,
        round((duracao_segundos/3600.0)::numeric, 1) AS tempo_movimento_h,
        -- LEAST blinda contra dias_utilizados > dias_no_periodo (taxa nunca passa de 100).
        round(LEAST(dias_utilizados, dias_no_periodo)::numeric / NULLIF(dias_no_periodo,0) * 100, 0) AS taxa_utilizacao_pct,
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
     FROM tb_resumo_mensal r JOIN vw_cadastro c ON c.id = r.device_id
    -- Ignora meses que ainda não começaram (ver vw_resumo_frota_mensal).
    WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE)
 SELECT uo_lotacao, todos_grupos, ano, mes,
        to_char(make_date(ano, mes, 1), 'YYYY-MM') AS ano_mes,
        count(*) AS qtd_veiculos,
        round(sum(km)::numeric, 0) AS km_total,
        round((sum(km) / NULLIF(count(*),0))::numeric, 0) AS media_km_veiculo,
        round((sum(duracao_segundos)/3600.0)::numeric, 0) AS tempo_movimento_h,
        round(avg(LEAST(dias_utilizados, dias_no_periodo)::numeric / NULLIF(dias_no_periodo,0) * 100), 0) AS taxa_media_utilizacao_pct
   FROM base
  GROUP BY uo_lotacao, todos_grupos, ano, mes
  ORDER BY todos_grupos, ano, mes;

-- ============================================================
-- vw_motoristas  (por MOTORISTA × DIA, ano 2026)
-- ============================================================
-- POR DIA (motorista × data), espelhando a vw_comportamento — o BI agrega no
-- período que quiser. km/horas/veículos do dia vêm de tb_viagens (por motorista×dia);
-- os eventos do dia, de tb_comportamento_motorista. As duas fontes cobrem o ANO
-- (DATA_CORTE), então as janelas ficam ALINHADAS. FULL JOIN para não perder dias com
-- só viagens (sem evento) nem só eventos (sem viagem). lotacao/regional/superint. de
-- tb_motoristas. Cobertura limitada a motorista identificado (login/chaveiro).
--
-- score_risco = soma PONDERADA de eventos do dia (excesso×3 + acel×2 + fren×2 +
-- curva×1), igual à vw_comportamento (maior = mais arriscado). O score 0-100 estilo
-- Geotab (Event Count) é uma MEDIDA no BI sobre o período: 100 - SUM(total_eventos)
-- *1000/SUM(km) (com piso de km a critério). Por dia ele não faz sentido (km baixo).
CREATE OR REPLACE VIEW vw_motoristas
WITH (security_invoker = on) AS
 WITH viagens_dia AS (
   SELECT v.motorista_id, v.data_partida::date AS dia,
          count(*)                     AS viagens,
          count(DISTINCT v.device_id)  AS qtd_veiculos,
          string_agg(DISTINCT c.placa, ', ' ORDER BY c.placa) AS veiculos,
          round(sum(v.distancia_km)::numeric, 1)                      AS km,
          round((sum(v.duracao_segundos)/3600.0)::numeric, 1)         AS horas_movimento,
          round((sum(v.tempo_ocioso_segundos)/3600.0)::numeric, 1)    AS horas_ocioso,
          round((sum(v.duracao_parada_segundos)/3600.0)::numeric, 1)  AS horas_parado
     FROM tb_viagens v
     LEFT JOIN tb_cadastro c ON c.id = v.device_id
    WHERE v.motorista_id <> ''
      AND v.motorista_nome NOT IN ('Nenhum', 'Desconhecido', '')
    GROUP BY v.motorista_id, v.data_partida::date
 ),
 eventos_dia AS (
   SELECT motorista_id, dia,
          COALESCE(sum(qtd) FILTER (WHERE tipo = 'excesso_velocidade'), 0) AS excessos_velocidade,
          COALESCE(sum(qtd) FILTER (WHERE tipo = 'aceleracao_brusca'),  0) AS aceleracoes_bruscas,
          COALESCE(sum(qtd) FILTER (WHERE tipo = 'frenagem_brusca'),    0) AS frenagens_bruscas,
          COALESCE(sum(qtd) FILTER (WHERE tipo = 'curva_drastica'),     0) AS curvas_drasticas,
          COALESCE(sum(qtd), 0) AS total_eventos
     FROM tb_comportamento_motorista
    GROUP BY motorista_id, dia
 )
 SELECT m.nome       AS motorista_nome,
        m.matricula  AS motorista_matricula,
        m.lotacao,
        m.regional,
        m.superintendencia,
        COALESCE(vd.dia, ed.dia)                          AS data,
        EXTRACT(year  FROM COALESCE(vd.dia, ed.dia))::int AS ano,
        EXTRACT(month FROM COALESCE(vd.dia, ed.dia))::int AS mes,
        vd.qtd_veiculos,
        vd.veiculos,
        vd.viagens,
        vd.km,
        vd.horas_movimento,
        vd.horas_ocioso,
        vd.horas_parado,
        COALESCE(ed.excessos_velocidade, 0) AS excessos_velocidade,
        COALESCE(ed.aceleracoes_bruscas,  0) AS aceleracoes_bruscas,
        COALESCE(ed.frenagens_bruscas,    0) AS frenagens_bruscas,
        COALESCE(ed.curvas_drasticas,     0) AS curvas_drasticas,
        COALESCE(ed.total_eventos,        0) AS total_eventos,
        (COALESCE(ed.excessos_velocidade, 0) * 3
       + COALESCE(ed.aceleracoes_bruscas,  0) * 2
       + COALESCE(ed.frenagens_bruscas,    0) * 2
       + COALESCE(ed.curvas_drasticas,     0) * 1) AS score_risco
   FROM viagens_dia vd
   FULL JOIN eventos_dia ed ON ed.motorista_id = vd.motorista_id AND ed.dia = vd.dia
   LEFT JOIN tb_motoristas m ON m.id = COALESCE(vd.motorista_id, ed.motorista_id)
  ORDER BY m.matricula, data;

