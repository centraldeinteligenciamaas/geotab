-- ============================================================================
-- (1) `veiculo` = "placa | marca | modelo" em TODAS as views que têm placa
-- (2) `motorista_nome_completo` onde o motorista vinha como e-mail
-- Data: 2026-08-26
--
-- (1) Montado a partir das colunas JÁ PADRONIZADAS (marca_padrao/modelo_padrao),
--     não do texto cru de tb_cadastro — o cru traz as grafias erradas que o
--     cliente apontou (FITA por FIAT, VOKSWAGEN por VOLKSWAGEN, ARGO em 7
--     formas). Resultado: "SGZ5D49 | VOLKSWAGEN | SAVEIRO ROBUST".
--     concat_ws ignora NULL, então nunca sobra separador solto.
--     Views afetadas (as que têm placa): cadastro, status, comportamento,
--     relatorio_viagens, resumo_frota_mensal.
--
-- (2) tb_viagens.motorista_nome guarda o LOGIN (ex. clesio@saneago.com.br) —
--     74.377 das viagens dos últimos 7 dias. O nome da pessoa está em
--     tb_motoristas.nome_completo, alcançável por motorista_id (100% para
--     motorista identificado). Entra como TERCEIRA coluna, sem mexer nas duas
--     existentes (motorista_nome = login, motorista_matricula).
--     Custo: +108 MB na viagens (5,3M linhas). Também adicionada em status
--     (hoje 100% "Nenhum" ali, mas fica correto quando houver motorista).
--
-- Rollback: views_backup_2026-08-24.sql
-- ============================================================================

BEGIN;

DROP VIEW IF EXISTS vw_saneago_resumo_frota_mensal CASCADE;
DROP VIEW IF EXISTS vw_saneago_relatorio_viagens   CASCADE;
DROP VIEW IF EXISTS vw_saneago_comportamento       CASCADE;
DROP VIEW IF EXISTS vw_saneago_status              CASCADE;
DROP VIEW IF EXISTS vw_saneago_cadastro            CASCADE;

-- -------------------------------------------------------------- cadastro ---
CREATE VIEW vw_saneago_cadastro AS
 SELECT id, serial, placa,
        -- (1) nome completo do veículo, já padronizado
        concat_ws(' | ', placa, marca_padrao(marca, modelo), modelo_padrao(marca, modelo)) AS veiculo,
        marca, modelo, ano, tipo_veiculo,
        arrumar_grupos(todos_grupos) AS todos_grupos,
        hashtext(arrumar_grupos(todos_grupos)) AS grupo_id,
        ativo, atualizado_em,
        marca_padrao(marca, modelo)  AS marca_padrao,
        modelo_padrao(marca, modelo) AS modelo_padrao
   FROM tb_cadastro c
  WHERE grupo_visivel(todos_grupos)
    AND placa NOT IN ('TFA2G98', 'TFN3B44', 'TFR4E14');

-- ---------------------------------------------------------------- status ---
CREATE VIEW vw_saneago_status AS
 SELECT s.id, s.serial, s.placa,
        c.veiculo,
        s.comunicando, s.ultimo_contato,
        s.latitude, s.longitude, s.velocidade, s.ignicao_ligada,
        s.motorista_nome,
        mo.nome_completo AS motorista_nome_completo,   -- (2)
        s.motorista_email, s.motorista_tel,
        s.viagem_inicio, s.snapshot_em, s.viagem_fim,
        c.todos_grupos, c.grupo_id
   FROM tb_status s
   JOIN vw_saneago_cadastro c ON c.id = s.id
   LEFT JOIN tb_motoristas mo ON mo.nome = s.motorista_nome;

-- --------------------------------------------------------- comportamento ---
CREATE VIEW vw_saneago_comportamento
WITH (security_invoker = on) AS
 SELECT e.device_id AS id,
    c.serial, c.placa, c.veiculo, c.todos_grupos, c.grupo_id,
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
  GROUP BY e.device_id, c.serial, c.placa, c.veiculo, c.todos_grupos, c.grupo_id,
           e.dia, o.odometro, o.odometro_gps;

-- ----------------------------------------------------- relatório viagens ---
-- SEM ORDER BY (perf). Relacionamento por grupo_id.
CREATE VIEW vw_saneago_relatorio_viagens
WITH (security_invoker = on) AS
 SELECT c.placa,
        c.veiculo,                                     -- (1)
        c.grupo_id,
        v.data_partida,
        v.data_chegada,
        v.duracao_segundos,
        to_char((v.duracao_segundos || ' seconds'::text)::interval, 'HH24:MI'::text) AS duracao_hhmm,
        v.tempo_ocioso_segundos,
        v.duracao_parada_segundos,
        v.distancia_km,
        v.hodometro_inicial,
        v.hodometro_final,
        v.velocidade_media,
        v.velocidade_maxima,
        limpar_endereco(ep.endereco) AS end_partida,
        limpar_endereco(ec.endereco) AS end_chegada,
        v.motorista_nome,                              -- login/e-mail
        mo.nome_completo AS motorista_nome_completo,   -- (2) nome da pessoa
        v.motorista_matricula,
        CASE WHEN v.velocidade_media  > 150 THEN 0 ELSE v.velocidade_media  END AS velocidade_media_2,
        CASE WHEN v.velocidade_maxima > 200 THEN 0 ELSE v.velocidade_maxima END AS velo_max_2,
        c.marca_padrao,
        c.modelo_padrao
   FROM tb_viagens v
     JOIN vw_saneago_cadastro c ON c.id = v.device_id
     LEFT JOIN tb_motoristas mo ON mo.id = v.motorista_id
     LEFT JOIN tb_enderecos ep ON ep.lat = round(v.lat_partida::numeric, 3) AND ep.lon = round(v.lon_partida::numeric, 3)
     LEFT JOIN tb_enderecos ec ON ec.lat = round(v.lat_chegada::numeric, 3) AND ec.lon = round(v.lon_chegada::numeric, 3);

-- ------------------------------------------------ resumo de frota mensal ---
CREATE VIEW vw_saneago_resumo_frota_mensal
WITH (security_invoker = on) AS
 WITH base AS (
   SELECT r.device_id, r.ano, r.mes, r.km, r.duracao_segundos, r.dias_utilizados, r.viagens,
          c.placa, c.veiculo, c.marca, c.modelo, c.todos_grupos, c.grupo_id,
          c.marca_padrao, c.modelo_padrao,
          (LEAST((date_trunc('month', make_date(r.ano, r.mes, 1)) + interval '1 month' - interval '1 day')::date, CURRENT_DATE)
            - date_trunc('month', make_date(r.ano, r.mes, 1))::date + 1) AS dias_no_periodo
     FROM tb_resumo_mensal r JOIN vw_saneago_cadastro c ON c.id = r.device_id
    WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE)
 SELECT placa, veiculo, marca, modelo, todos_grupos, grupo_id, ano, mes,
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

COMMIT;
