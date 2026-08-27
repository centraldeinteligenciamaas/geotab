-- ============================================================================
-- MIGRAÇÃO: views do cliente SEMAD  (2026-08-27)
-- ============================================================================
-- Espelha as 9 views da SANEAGO (vw_saneago_*) para o cliente SEMAD,
-- filtrando SOMENTE o contrato definido em tb_contrato_semad.
--
-- DIFERENÇAS CONSCIENTES em relação ao conjunto SANEAGO (ver MANUAL.md):
--   1. Filtro: `grupo_semad()` (inclusão por contrato) no lugar de
--      `grupo_visivel()` (exclusão por lista de terceiros).
--   2. Removida a exclusão das placas TFA2G98/TFN3B44/TFR4E14 — é correção
--      pontual da frota SANEAGO; nenhuma delas é veículo do SEMAD.
--   3. vw_semad_motoristas / _motoristas_anual filtram pelo VEÍCULO (frota do
--      contrato), não pelos grupos do motorista. Motivo: os usuários com o
--      grupo SEMAD são administrativos da MAAS e pertencem a TODOS os
--      contratos — filtrar pelo motorista traria viagens de outros clientes
--      para dentro do painel do SEMAD (medido em 2026-08-27: 29 viagens em
--      veículos da SANEAGO).
--   4. `arrumar_grupos_semad()` remove do texto de grupos os tokens de
--      contrato de OUTROS clientes (ex.: "OPE_SANEAGO - 30000070/2025",
--      "REDEMOB CONSÓRCIO - 008/2025"), que aparecem nos usuários da MAAS.
--
-- SEM ORDER BY nas views grandes (relatorio_viagens/motoristas/anual) —
-- ver seção de PERF no contexto: ORDER BY em view derruba o refresh do BI.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Contrato(s) do SEMAD — token exato, como aparece em todos_grupos
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tb_contrato_semad (
    token      text PRIMARY KEY,
    observacao text
);

INSERT INTO tb_contrato_semad (token, observacao)
VALUES ('OPE_SEMAD - 035/2026', 'Contrato definido pelo usuario em 2026-08-27')
ON CONFLICT (token) DO NOTHING;

-- Trocar de contrato = UPDATE/INSERT aqui. Nenhuma view precisa ser recriada.


-- ---------------------------------------------------------------------------
-- 2. Filtro de inclusão: o registro pertence ao contrato do SEMAD?
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION grupo_semad(p_todos text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM unnest(string_to_array(COALESCE(p_todos, ''), '|')) AS tok
        JOIN tb_contrato_semad c ON c.token = btrim(tok)
    );
$$;


-- ---------------------------------------------------------------------------
-- 3. Limpeza de grupos: arrumar_grupos() + remove contratos de outros clientes
--    (token de contrato = termina em NNN/AAAA e não está em tb_contrato_semad)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION arrumar_grupos_semad(p_todos text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(string_agg(s.tok, ' | ' ORDER BY s.ord), '')
    FROM (
        SELECT btrim(t.tok) AS tok, t.ord
        FROM unnest(string_to_array(arrumar_grupos(p_todos), '|'))
             WITH ORDINALITY AS t(tok, ord)
    ) s
    WHERE s.tok <> ''
      AND (
            s.tok !~ '[0-9]+/[0-9]{4}$'
            OR EXISTS (SELECT 1 FROM tb_contrato_semad c WHERE c.token = s.tok)
          );
$$;


-- ---------------------------------------------------------------------------
-- 4. Views  (ordem respeita dependências: cadastro primeiro)
-- ---------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_semad_indicadores_mensal;
DROP VIEW IF EXISTS vw_semad_resumo_frota_mensal;
DROP VIEW IF EXISTS vw_semad_relatorio_viagens;
DROP VIEW IF EXISTS vw_semad_comportamento;
DROP VIEW IF EXISTS vw_semad_status;
DROP VIEW IF EXISTS vw_semad_motoristas_anual;
DROP VIEW IF EXISTS vw_semad_motoristas;
DROP VIEW IF EXISTS vw_semad_grupos;
DROP VIEW IF EXISTS vw_semad_cadastro;


-- 4.1 CADASTRO ---------------------------------------------------------------
CREATE VIEW vw_semad_cadastro AS
SELECT
    id,
    serial,
    placa,
    concat_ws(' | ', placa, marca_padrao(marca, modelo), modelo_padrao(marca, modelo)) AS veiculo,
    marca,
    modelo,
    ano,
    tipo_veiculo,
    arrumar_grupos_semad(todos_grupos)            AS todos_grupos,
    hashtext(arrumar_grupos_semad(todos_grupos))  AS grupo_id,
    ativo,
    atualizado_em,
    marca_padrao(marca, modelo)                   AS marca_padrao,
    modelo_padrao(marca, modelo)                  AS modelo_padrao
FROM tb_cadastro c
WHERE grupo_semad(todos_grupos);


-- 4.2 STATUS -----------------------------------------------------------------
CREATE VIEW vw_semad_status AS
SELECT
    s.id,
    s.serial,
    s.placa,
    c.veiculo,
    s.comunicando,
    s.ultimo_contato,
    s.latitude,
    s.longitude,
    s.velocidade,
    s.ignicao_ligada,
    s.motorista_nome,
    mo.nome_completo AS motorista_nome_completo,
    s.motorista_email,
    s.motorista_tel,
    s.viagem_inicio,
    s.snapshot_em,
    s.viagem_fim,
    c.todos_grupos,
    c.grupo_id
FROM tb_status s
JOIN vw_semad_cadastro c ON c.id = s.id
LEFT JOIN tb_motoristas mo ON mo.nome = s.motorista_nome;


-- 4.3 COMPORTAMENTO (device × dia) -------------------------------------------
CREATE VIEW vw_semad_comportamento AS
SELECT
    e.device_id AS id,
    c.serial,
    c.placa,
    c.veiculo,
    c.todos_grupos,
    c.grupo_id,
    e.dia AS data,
    EXTRACT(year  FROM e.dia)::integer AS ano,
    EXTRACT(month FROM e.dia)::integer AS mes,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'excesso_velocidade'), 0::bigint) AS excessos_velocidade,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'aceleracao_brusca'),  0::bigint) AS aceleracoes_bruscas,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'frenagem_brusca'),    0::bigint) AS frenagens_bruscas,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'curva_drastica'),     0::bigint) AS curvas_drasticas,
    COALESCE(sum(e.qtd), 0::bigint) AS total_eventos,
      COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'excesso_velocidade'), 0::bigint) * 3
    + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'aceleracao_brusca'),  0::bigint) * 2
    + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'frenagem_brusca'),    0::bigint) * 2
    + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'curva_drastica'),     0::bigint) * 1 AS score_risco,
    o.odometro,
    o.odometro_gps
FROM tb_comportamento_eventos e
JOIN vw_semad_cadastro c ON c.id = e.device_id
LEFT JOIN tb_odometro_dia o ON o.device_id = e.device_id AND o.dia = e.dia
GROUP BY e.device_id, c.serial, c.placa, c.veiculo, c.todos_grupos, c.grupo_id,
         e.dia, o.odometro, o.odometro_gps;


-- 4.4 RELATÓRIO DE VIAGENS (SEM ORDER BY) ------------------------------------
CREATE VIEW vw_semad_relatorio_viagens AS
SELECT
    c.placa,
    c.veiculo,
    c.todos_grupos,
    c.grupo_id,
    v.data_partida,
    v.data_chegada,
    v.duracao_segundos,
    to_char((v.duracao_segundos || ' seconds')::interval, 'HH24:MI') AS duracao_hhmm,
    v.tempo_ocioso_segundos,
    v.duracao_parada_segundos,
    v.distancia_km,
    v.hodometro_inicial,
    v.hodometro_final,
    v.velocidade_media,
    v.velocidade_maxima,
    limpar_endereco(ep.endereco) AS end_partida,
    limpar_endereco(ec.endereco) AS end_chegada,
    v.motorista_nome,
    mo.nome_completo AS motorista_nome_completo,
    v.motorista_matricula,
    CASE WHEN v.velocidade_media  > 150::double precision THEN 0::double precision
         ELSE v.velocidade_media  END AS velocidade_media_2,
    CASE WHEN v.velocidade_maxima > 200::double precision THEN 0::double precision
         ELSE v.velocidade_maxima END AS velo_max_2,
    c.marca_padrao,
    c.modelo_padrao
FROM tb_viagens v
JOIN vw_semad_cadastro c ON c.id = v.device_id
LEFT JOIN tb_motoristas mo ON mo.id = v.motorista_id
LEFT JOIN tb_enderecos ep ON ep.lat = round(v.lat_partida::numeric, 3)
                         AND ep.lon = round(v.lon_partida::numeric, 3)
LEFT JOIN tb_enderecos ec ON ec.lat = round(v.lat_chegada::numeric, 3)
                         AND ec.lon = round(v.lon_chegada::numeric, 3);


-- 4.5 RESUMO DA FROTA MENSAL (veículo × mês) ---------------------------------
CREATE VIEW vw_semad_resumo_frota_mensal AS
WITH base AS (
    SELECT
        r.device_id, r.ano, r.mes, r.km, r.duracao_segundos,
        r.dias_utilizados, r.viagens,
        c.placa, c.veiculo, c.marca, c.modelo,
        c.todos_grupos, c.grupo_id, c.marca_padrao, c.modelo_padrao,
        LEAST((date_trunc('month', make_date(r.ano, r.mes, 1)::timestamptz)
               + '1 mon'::interval - '1 day'::interval)::date, CURRENT_DATE)
        - date_trunc('month', make_date(r.ano, r.mes, 1)::timestamptz)::date + 1 AS dias_no_periodo
    FROM tb_resumo_mensal r
    JOIN vw_semad_cadastro c ON c.id = r.device_id
    WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE
)
SELECT
    placa,
    veiculo,
    marca,
    modelo,
    todos_grupos,
    grupo_id,
    ano,
    mes,
    to_char(make_date(ano, mes, 1)::timestamptz, 'YYYY-MM') AS ano_mes,
    dias_no_periodo,
    dias_utilizados,
    round(km::numeric, 1) AS km_rodado,
    round((km / NULLIF(dias_utilizados, 0)::double precision)::numeric, 1) AS media_km_dia,
    round(duracao_segundos::numeric / 3600.0, 1) AS tempo_movimento_h,
    round(LEAST(dias_utilizados, dias_no_periodo)::numeric
          / NULLIF(dias_no_periodo, 0)::numeric * 100::numeric, 0) AS taxa_utilizacao_pct,
    viagens,
    CASE WHEN modelo IS NULL OR modelo = '' THEN marca ELSE modelo END AS modelo2,
    marca_padrao,
    modelo_padrao
FROM base
ORDER BY placa, ano, mes;


-- 4.6 INDICADORES MENSAIS (grupo × mês) --------------------------------------
CREATE VIEW vw_semad_indicadores_mensal AS
WITH base AS (
    SELECT
        r.device_id, r.ano, r.mes, r.km, r.duracao_segundos, r.dias_utilizados,
        c.todos_grupos, c.grupo_id,
        LEAST((date_trunc('month', make_date(r.ano, r.mes, 1)::timestamptz)
               + '1 mon'::interval - '1 day'::interval)::date, CURRENT_DATE)
        - date_trunc('month', make_date(r.ano, r.mes, 1)::timestamptz)::date + 1 AS dias_no_periodo
    FROM tb_resumo_mensal r
    JOIN vw_semad_cadastro c ON c.id = r.device_id
    WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE
)
SELECT
    todos_grupos,
    grupo_id,
    ano,
    mes,
    to_char(make_date(ano, mes, 1)::timestamptz, 'YYYY-MM') AS ano_mes,
    count(*) AS qtd_veiculos,
    round(sum(km)::numeric, 0) AS km_total,
    round((sum(km) / NULLIF(count(*), 0)::double precision)::numeric, 0) AS media_km_veiculo,
    round(sum(duracao_segundos) / 3600.0, 0) AS tempo_movimento_h,
    round(avg(LEAST(dias_utilizados, dias_no_periodo)::numeric
              / NULLIF(dias_no_periodo, 0)::numeric * 100::numeric), 0) AS taxa_media_utilizacao_pct
FROM base
GROUP BY todos_grupos, grupo_id, ano, mes
ORDER BY todos_grupos, ano, mes;


-- 4.7 MOTORISTAS — POR DIA (SEM ORDER BY) ------------------------------------
--     Escopo pelo VEÍCULO do contrato (ver diferença 3 no cabeçalho).
CREATE VIEW vw_semad_motoristas AS
WITH viagens_dia AS (
    SELECT
        v.motorista_id,
        v.data_partida::date AS dia,
        count(*) AS viagens,
        count(DISTINCT v.device_id) AS qtd_veiculos,
        string_agg(DISTINCT c.placa, ', ' ORDER BY c.placa) AS veiculos,
        round(sum(v.distancia_km)::numeric, 1) AS km,
        round(sum(v.duracao_segundos)::numeric / 3600.0, 1) AS horas_movimento,
        round(sum(v.tempo_ocioso_segundos)::numeric / 3600.0, 1) AS horas_ocioso,
        round(sum(v.duracao_parada_segundos)::numeric / 3600.0, 1) AS horas_parado
    FROM tb_viagens v
    JOIN vw_semad_cadastro c ON c.id = v.device_id
    WHERE v.motorista_id <> ''
      AND v.motorista_nome NOT IN ('Nenhum', 'Desconhecido', '')
    GROUP BY v.motorista_id, (v.data_partida::date)
), eventos_dia AS (
    SELECT
        cm.motorista_id,
        cm.dia,
        COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'excesso_velocidade'), 0::bigint) AS excessos_velocidade,
        COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'aceleracao_brusca'),  0::bigint) AS aceleracoes_bruscas,
        COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'frenagem_brusca'),    0::bigint) AS frenagens_bruscas,
        COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'curva_drastica'),     0::bigint) AS curvas_drasticas,
        COALESCE(sum(cm.qtd), 0::bigint) AS total_eventos
    FROM tb_comportamento_motorista cm
    JOIN vw_semad_cadastro c ON c.id = cm.device_id
    GROUP BY cm.motorista_id, cm.dia
)
SELECT
    m.nome                                          AS motorista_nome,
    m.nome_completo                                 AS motorista_nome_completo,
    m.matricula                                     AS motorista_matricula,
    arrumar_grupos_semad(m.todos_grupos)            AS todos_grupos,
    hashtext(arrumar_grupos_semad(m.todos_grupos))  AS grupo_id,
    COALESCE(vd.dia, ed.dia)                        AS data,
    EXTRACT(year  FROM COALESCE(vd.dia, ed.dia))::integer AS ano,
    EXTRACT(month FROM COALESCE(vd.dia, ed.dia))::integer AS mes,
    vd.qtd_veiculos,
    vd.veiculos,
    vd.viagens,
    vd.km,
    vd.horas_movimento,
    vd.horas_ocioso,
    vd.horas_parado,
    COALESCE(ed.excessos_velocidade, 0::bigint) AS excessos_velocidade,
    COALESCE(ed.aceleracoes_bruscas,  0::bigint) AS aceleracoes_bruscas,
    COALESCE(ed.frenagens_bruscas,    0::bigint) AS frenagens_bruscas,
    COALESCE(ed.curvas_drasticas,     0::bigint) AS curvas_drasticas,
    COALESCE(ed.total_eventos,        0::bigint) AS total_eventos,
      COALESCE(ed.excessos_velocidade, 0::bigint) * 3
    + COALESCE(ed.aceleracoes_bruscas,  0::bigint) * 2
    + COALESCE(ed.frenagens_bruscas,    0::bigint) * 2
    + COALESCE(ed.curvas_drasticas,     0::bigint) * 1 AS score_risco
FROM viagens_dia vd
FULL JOIN eventos_dia ed ON ed.motorista_id = vd.motorista_id AND ed.dia = vd.dia
LEFT JOIN tb_motoristas m ON m.id = COALESCE(vd.motorista_id, ed.motorista_id);


-- 4.8 MOTORISTAS — AGREGADO ANUAL (SEM ORDER BY) -----------------------------
CREATE VIEW vw_semad_motoristas_anual AS
WITH viagens_mot AS (
    SELECT
        v.motorista_id,
        max(v.motorista_nome)       AS motorista_nome,
        max(v.motorista_matricula)  AS motorista_matricula,
        count(*) AS viagens,
        count(DISTINCT v.device_id) AS qtd_veiculos,
        string_agg(DISTINCT c.placa, ', ' ORDER BY c.placa) AS veiculos,
        round(sum(v.distancia_km)::numeric, 1) AS km_total,
        round(sum(v.duracao_segundos)::numeric / 3600.0, 1) AS horas_movimento,
        round(sum(v.tempo_ocioso_segundos)::numeric / 3600.0, 1) AS horas_ocioso,
        round(sum(v.duracao_parada_segundos)::numeric / 3600.0, 1) AS horas_parado
    FROM tb_viagens v
    JOIN vw_semad_cadastro c ON c.id = v.device_id
    WHERE v.motorista_id <> ''
      AND v.motorista_nome NOT IN ('Nenhum', 'Desconhecido', '')
    GROUP BY v.motorista_id
), eventos_mot AS (
    SELECT
        cm.motorista_id,
        COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'excesso_velocidade'), 0::bigint) AS excesso_velocidade,
        COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'aceleracao_brusca'),  0::bigint) AS aceleracao_brusca,
        COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'frenagem_brusca'),    0::bigint) AS frenagem_brusca,
        COALESCE(sum(cm.qtd) FILTER (WHERE cm.tipo = 'curva_drastica'),     0::bigint) AS curva_drastica,
        COALESCE(sum(cm.qtd), 0::bigint) AS total_eventos
    FROM tb_comportamento_motorista cm
    JOIN vw_semad_cadastro c ON c.id = cm.device_id
    GROUP BY cm.motorista_id
)
SELECT
    vm.motorista_nome,
    m.nome_completo AS motorista_nome_completo,
    vm.motorista_matricula,
    arrumar_grupos_semad(m.todos_grupos)           AS todos_grupos,
    hashtext(arrumar_grupos_semad(m.todos_grupos)) AS grupo_id,
    vm.qtd_veiculos,
    vm.veiculos,
    vm.viagens,
    vm.km_total,
    vm.horas_movimento,
    vm.horas_ocioso,
    vm.horas_parado,
    COALESCE(em.excesso_velocidade, 0::bigint) AS excesso_velocidade,
    COALESCE(em.aceleracao_brusca,  0::bigint) AS aceleracao_brusca,
    COALESCE(em.frenagem_brusca,    0::bigint) AS frenagem_brusca,
    COALESCE(em.curva_drastica,     0::bigint) AS curva_drastica,
    COALESCE(em.total_eventos,      0::bigint) AS total_eventos,
    CASE WHEN vm.km_total >= 1::numeric THEN
        round((  GREATEST(0::numeric, 100::numeric - COALESCE(em.excesso_velocidade, 0::bigint)::numeric * 1000.0 / vm.km_total)
               + GREATEST(0::numeric, 100::numeric - COALESCE(em.aceleracao_brusca,  0::bigint)::numeric * 1000.0 / vm.km_total)
               + GREATEST(0::numeric, 100::numeric - COALESCE(em.frenagem_brusca,    0::bigint)::numeric * 1000.0 / vm.km_total)
               + GREATEST(0::numeric, 100::numeric - COALESCE(em.curva_drastica,     0::bigint)::numeric * 1000.0 / vm.km_total)
              ) / 4.0, 1)
        ELSE NULL::numeric
    END AS score_seguranca
FROM viagens_mot vm
LEFT JOIN eventos_mot em ON em.motorista_id = vm.motorista_id
LEFT JOIN tb_motoristas m ON m.id = vm.motorista_id;


-- 4.9 GRUPOS (DIMENSÃO) ------------------------------------------------------
CREATE VIEW vw_semad_grupos AS
WITH combos AS (
    SELECT todos_grupos FROM tb_cadastro
     WHERE todos_grupos IS NOT NULL AND grupo_semad(todos_grupos)
    UNION
    SELECT todos_grupos FROM tb_motoristas
     WHERE todos_grupos IS NOT NULL AND grupo_semad(todos_grupos)
), base AS (
    SELECT
        combos.todos_grupos                          AS orig,
        arrumar_grupos_semad(combos.todos_grupos)    AS tg
    FROM combos
), niveis AS (
    SELECT
        orig,
        tg,
        split_grupo(tg, 'OPE')  AS ope_bruto,
        split_outros(tg)        AS outros,
        split_grupo(tg, 'REG')  AS reg_bruto,
        split_grupo(tg, 'ULOT') AS ulot_bruto,
        sup_oficial(split_grupo(tg, 'REG'), split_grupo(tg, 'SUP')) AS sup_bruto
    FROM base
), agrupado AS (
    SELECT
        tg AS todos_grupos,
        min(orig)       AS todos_grupos_original,
        min(sup_bruto)  AS sup_bruto,
        min(reg_bruto)  AS reg_bruto,
        min(ulot_bruto) AS ulot_bruto,
        min(ope_bruto)  AS ope_bruto,
        min(outros)     AS outros
    FROM niveis
    WHERE tg IS NOT NULL
    GROUP BY tg
), codigos AS (
    SELECT a.*,
        grupo_codigo(a.sup_bruto)  AS c_sup,
        grupo_codigo(a.reg_bruto)  AS c_reg,
        grupo_codigo(a.ulot_bruto) AS c_ulot
    FROM agrupado a
), limpo AS (
    SELECT c.*,
        CASE WHEN c.c_reg IS NOT NULL AND c.c_reg = c.c_sup
             THEN NULL::text ELSE c.reg_bruto END AS reg_ok,
        CASE WHEN c.c_ulot IS NOT NULL AND (c.c_ulot = c.c_sup OR c.c_ulot = c.c_reg)
             THEN NULL::text ELSE c.ulot_bruto END AS ulot_ok
    FROM codigos c
)
SELECT
    hashtext(todos_grupos) AS grupo_id,
    todos_grupos_original,
    todos_grupos,
    ope_bruto                   AS operacao,
    grupo_codigo(ope_bruto)     AS ope_codigo,
    grupo_nome(ope_bruto)       AS ope_nome,
    grupo_cod_nome(ope_bruto)   AS ope_cod_nome,
    grupo_codigo(sup_bruto)     AS sup_codigo,
    grupo_nome(sup_bruto)       AS sup_nome,
    grupo_cod_nome(sup_bruto)   AS sup_cod_nome,
    grupo_codigo(reg_ok)        AS reg_codigo,
    grupo_nome(reg_ok)          AS reg_nome,
    grupo_cod_nome(reg_ok)      AS reg_cod_nome,
    grupo_codigo(ulot_ok)       AS ulot_codigo,
    grupo_nome(ulot_ok)         AS ulot_nome,
    grupo_cod_nome(ulot_ok)     AS ulot_cod_nome,
    outros,
    grupo_nome(outros)          AS outros_nome
FROM limpo
ORDER BY todos_grupos;


-- ---------------------------------------------------------------------------
-- 5. security_invoker (mesmo padrão das views da SANEAGO)
-- ---------------------------------------------------------------------------
ALTER VIEW vw_semad_cadastro             SET (security_invoker = on);
ALTER VIEW vw_semad_status               SET (security_invoker = on);
ALTER VIEW vw_semad_comportamento        SET (security_invoker = on);
ALTER VIEW vw_semad_relatorio_viagens    SET (security_invoker = on);
ALTER VIEW vw_semad_resumo_frota_mensal  SET (security_invoker = on);
ALTER VIEW vw_semad_indicadores_mensal   SET (security_invoker = on);
ALTER VIEW vw_semad_motoristas           SET (security_invoker = on);
ALTER VIEW vw_semad_motoristas_anual     SET (security_invoker = on);
ALTER VIEW vw_semad_grupos               SET (security_invoker = on);

COMMIT;
