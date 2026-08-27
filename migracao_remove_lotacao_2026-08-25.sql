-- ============================================================================
-- Remove a coluna de lotação (grupo / uo_lotacao)  — 2026-08-25
--
-- A pedido: as views de fato ficam SOMENTE com `todos_grupos` como coluna de
-- grupo. A lotação (e toda a hierarquia) passa a vir da dimensão
-- vw_saneago_grupos pelo relacionamento em todos_grupos → usar `ulot_nome` /
-- `ulot_cod_nome` / `ulot_codigo`.
--
-- ATENÇÃO: vw_saneago_indicadores_mensal AGRUPAVA por uo_lotacao. A coluna sai
-- do SELECT e TAMBÉM do GROUP BY — sem isso as linhas continuariam divididas
-- por uma coluna invisível. Isso agrega mais alto (menos linhas); os totais de
-- km e de veículos permanecem.
--
-- Rollback: views_backup_2026-08-24.sql
-- ============================================================================

BEGIN;

DROP VIEW IF EXISTS vw_saneago_indicadores_mensal  CASCADE;
DROP VIEW IF EXISTS vw_saneago_resumo_frota_mensal CASCADE;
DROP VIEW IF EXISTS vw_saneago_relatorio_viagens   CASCADE;
DROP VIEW IF EXISTS vw_saneago_comportamento       CASCADE;
DROP VIEW IF EXISTS vw_saneago_status              CASCADE;
DROP VIEW IF EXISTS vw_saneago_cadastro            CASCADE;

-- -------------------------------------------------------------- cadastro ---
CREATE VIEW vw_saneago_cadastro AS
 SELECT id, serial, placa, veiculo, marca, modelo, ano, tipo_veiculo,
        arrumar_grupos(todos_grupos) AS todos_grupos,
        ativo, atualizado_em,
        marca_padrao(marca, modelo)  AS marca_padrao,
        modelo_padrao(marca, modelo) AS modelo_padrao
   FROM tb_cadastro c
  WHERE grupo_visivel(todos_grupos)
    AND placa NOT IN ('TFA2G98', 'TFN3B44', 'TFR4E14');

-- ---------------------------------------------------------------- status ---
CREATE VIEW vw_saneago_status AS
 SELECT s.id, s.serial, s.placa, s.comunicando, s.ultimo_contato,
        s.latitude, s.longitude, s.velocidade, s.ignicao_ligada,
        s.motorista_nome, s.motorista_email, s.motorista_tel,
        s.viagem_inicio, s.snapshot_em, s.viagem_fim,
        c.todos_grupos
   FROM tb_status s
   JOIN vw_saneago_cadastro c ON c.id = s.id;

-- --------------------------------------------------------- comportamento ---
CREATE VIEW vw_saneago_comportamento
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
     JOIN vw_saneago_cadastro c ON c.id = e.device_id
     LEFT JOIN tb_odometro_dia o ON o.device_id = e.device_id AND o.dia = e.dia
  GROUP BY e.device_id, c.serial, c.placa, c.todos_grupos, e.dia, o.odometro, o.odometro_gps;

-- ----------------------------------------------------- relatório viagens ---
CREATE VIEW vw_saneago_relatorio_viagens
WITH (security_invoker = on) AS
 SELECT c.placa,
        c.veiculo,
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
        limpar_endereco(ep.endereco) AS end_partida,
        limpar_endereco(ec.endereco) AS end_chegada,
        v.motorista_nome,
        v.motorista_matricula,
        CASE WHEN v.velocidade_media  > 150 THEN 0 ELSE v.velocidade_media  END AS velocidade_media_2,
        CASE WHEN v.velocidade_maxima > 200 THEN 0 ELSE v.velocidade_maxima END AS velo_max_2,
        c.marca_padrao,
        c.modelo_padrao
   FROM tb_viagens v
     JOIN vw_saneago_cadastro c ON c.id = v.device_id
     LEFT JOIN tb_enderecos ep ON ep.lat = round(v.lat_partida::numeric, 3) AND ep.lon = round(v.lon_partida::numeric, 3)
     LEFT JOIN tb_enderecos ec ON ec.lat = round(v.lat_chegada::numeric, 3) AND ec.lon = round(v.lon_chegada::numeric, 3)
  ORDER BY c.placa, v.data_partida;

-- ------------------------------------------------ resumo de frota mensal ---
CREATE VIEW vw_saneago_resumo_frota_mensal
WITH (security_invoker = on) AS
 WITH base AS (
   SELECT r.device_id, r.ano, r.mes, r.km, r.duracao_segundos, r.dias_utilizados, r.viagens,
          c.placa, c.marca, c.modelo, c.todos_grupos, c.marca_padrao, c.modelo_padrao,
          (LEAST((date_trunc('month', make_date(r.ano, r.mes, 1)) + interval '1 month' - interval '1 day')::date, CURRENT_DATE)
            - date_trunc('month', make_date(r.ano, r.mes, 1))::date + 1) AS dias_no_periodo
     FROM tb_resumo_mensal r JOIN vw_saneago_cadastro c ON c.id = r.device_id
    WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE)
 SELECT placa, marca, modelo, todos_grupos, ano, mes,
        to_char(make_date(ano, mes, 1), 'YYYY-MM') AS ano_mes,
        dias_no_periodo, dias_utilizados,
        round(km::numeric, 1) AS km_rodado,
        round((km / NULLIF(dias_utilizados,0))::numeric, 1) AS media_km_dia,
        round((duracao_segundos/3600.0)::numeric, 1) AS tempo_movimento_h,
        round(LEAST(dias_utilizados, dias_no_periodo)::numeric / NULLIF(dias_no_periodo,0) * 100, 0) AS taxa_utilizacao_pct,
        viagens,
        CASE WHEN modelo IS NULL OR modelo = '' THEN marca ELSE modelo END AS modelo2,
        marca_padrao, modelo_padrao
   FROM base
  ORDER BY placa, ano, mes;

-- --------------------------------------------------- indicadores mensais ---
-- uo_lotacao saiu do SELECT e do GROUP BY (ver nota no topo).
CREATE VIEW vw_saneago_indicadores_mensal
WITH (security_invoker = on) AS
 WITH base AS (
   SELECT r.device_id, r.ano, r.mes, r.km, r.duracao_segundos, r.dias_utilizados,
          c.todos_grupos,
          (LEAST((date_trunc('month', make_date(r.ano, r.mes, 1)) + interval '1 month' - interval '1 day')::date, CURRENT_DATE)
            - date_trunc('month', make_date(r.ano, r.mes, 1))::date + 1) AS dias_no_periodo
     FROM tb_resumo_mensal r JOIN vw_saneago_cadastro c ON c.id = r.device_id
    WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE)
 SELECT todos_grupos, ano, mes,
        to_char(make_date(ano, mes, 1), 'YYYY-MM') AS ano_mes,
        count(*) AS qtd_veiculos,
        round(sum(km)::numeric, 0) AS km_total,
        round((sum(km) / NULLIF(count(*),0))::numeric, 0) AS media_km_veiculo,
        round((sum(duracao_segundos)/3600.0)::numeric, 0) AS tempo_movimento_h,
        round(avg(LEAST(dias_utilizados, dias_no_periodo)::numeric / NULLIF(dias_no_periodo,0) * 100), 0) AS taxa_media_utilizacao_pct
   FROM base
  GROUP BY todos_grupos, ano, mes
  ORDER BY todos_grupos, ano, mes;

COMMIT;
