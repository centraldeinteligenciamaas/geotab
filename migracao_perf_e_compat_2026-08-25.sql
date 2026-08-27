-- ============================================================================
-- (A) PERFORMANCE: remove ORDER BY das views grandes
-- (B) COMPATIBILIDADE: devolve `operacao` cru à dimensão de grupos
-- Data: 2026-08-25
--
-- (A) MOTIVO: `ORDER BY` numa view obriga o Postgres a ordenar TODAS as linhas
--     antes de devolver a primeira. Em vw_saneago_relatorio_viagens (3,9M linhas)
--     medi 88 s só para ler 200 mil linhas — é isso que produz o
--     "PostgreSQL: Exception while reading from stream" no Power BI (timeout).
--     O BI ordena no próprio modelo; a ordenação na view não serve para nada.
--     Removido de relatorio_viagens, motoristas e motoristas_anual.
--     Mantido nas views pequenas (cadastro, resumo, indicadores, grupos), onde
--     o custo é irrelevante e ajuda na inspeção manual via psql/DBeaver.
--
-- (B) `operacao` (texto cru do grupo OPE_) havia saído quando entraram as
--     colunas ope_codigo/ope_nome/ope_cod_nome. O Power BI ainda a usa para
--     montar os rótulos legados (gruposemnumero, Outros.1), então volta —
--     conviven com as tratadas.
--
-- Rollback: views_backup_2026-08-24.sql
-- ============================================================================

BEGIN;

-- --------------------------------------------- (A) relatório de viagens -----
DROP VIEW IF EXISTS vw_saneago_relatorio_viagens CASCADE;
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
     LEFT JOIN tb_enderecos ec ON ec.lat = round(v.lat_chegada::numeric, 3) AND ec.lon = round(v.lon_chegada::numeric, 3);
-- sem ORDER BY (ver nota A)

-- ------------------------------------------------------ (A) motoristas -----
DROP VIEW IF EXISTS vw_saneago_motoristas CASCADE;
CREATE VIEW vw_saneago_motoristas
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
 SELECT m.nome          AS motorista_nome,
        m.nome_completo AS motorista_nome_completo,
        m.matricula     AS motorista_matricula,
        arrumar_grupos(m.todos_grupos) AS todos_grupos,
        COALESCE(vd.dia, ed.dia)                          AS data,
        EXTRACT(year  FROM COALESCE(vd.dia, ed.dia))::int AS ano,
        EXTRACT(month FROM COALESCE(vd.dia, ed.dia))::int AS mes,
        vd.qtd_veiculos, vd.veiculos, vd.viagens, vd.km,
        vd.horas_movimento, vd.horas_ocioso, vd.horas_parado,
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
  WHERE grupo_visivel(m.todos_grupos);
-- sem ORDER BY (ver nota A)

DROP VIEW IF EXISTS vw_saneago_motoristas_anual CASCADE;
CREATE VIEW vw_saneago_motoristas_anual
WITH (security_invoker = on) AS
 WITH viagens_mot AS (
   SELECT v.motorista_id,
          max(v.motorista_nome)       AS motorista_nome,
          max(v.motorista_matricula)  AS motorista_matricula,
          count(*)                     AS viagens,
          count(DISTINCT v.device_id)  AS qtd_veiculos,
          string_agg(DISTINCT c.placa, ', ' ORDER BY c.placa) AS veiculos,
          round(sum(v.distancia_km)::numeric, 1)                 AS km_total,
          round((sum(v.duracao_segundos)/3600.0)::numeric, 1)    AS horas_movimento,
          round((sum(v.tempo_ocioso_segundos)/3600.0)::numeric, 1)   AS horas_ocioso,
          round((sum(v.duracao_parada_segundos)/3600.0)::numeric, 1)  AS horas_parado
     FROM tb_viagens v
     LEFT JOIN tb_cadastro c ON c.id = v.device_id
    WHERE v.motorista_id <> ''
      AND v.motorista_nome NOT IN ('Nenhum', 'Desconhecido', '')
    GROUP BY v.motorista_id
 ),
 eventos_mot AS (
   SELECT motorista_id,
          COALESCE(sum(qtd) FILTER (WHERE tipo = 'excesso_velocidade'), 0) AS excesso_velocidade,
          COALESCE(sum(qtd) FILTER (WHERE tipo = 'aceleracao_brusca'),  0) AS aceleracao_brusca,
          COALESCE(sum(qtd) FILTER (WHERE tipo = 'frenagem_brusca'),    0) AS frenagem_brusca,
          COALESCE(sum(qtd) FILTER (WHERE tipo = 'curva_drastica'),     0) AS curva_drastica,
          COALESCE(sum(qtd), 0) AS total_eventos
     FROM tb_comportamento_motorista
    GROUP BY motorista_id
 )
 SELECT vm.motorista_nome,
        m.nome_completo AS motorista_nome_completo,
        vm.motorista_matricula,
        arrumar_grupos(m.todos_grupos) AS todos_grupos,
        vm.qtd_veiculos, vm.veiculos, vm.viagens, vm.km_total,
        vm.horas_movimento, vm.horas_ocioso, vm.horas_parado,
        COALESCE(em.excesso_velocidade, 0) AS excesso_velocidade,
        COALESCE(em.aceleracao_brusca,  0) AS aceleracao_brusca,
        COALESCE(em.frenagem_brusca,    0) AS frenagem_brusca,
        COALESCE(em.curva_drastica,     0) AS curva_drastica,
        COALESCE(em.total_eventos,      0) AS total_eventos,
        CASE WHEN vm.km_total >= 1 THEN round((
              GREATEST(0::numeric, 100 - COALESCE(em.excesso_velocidade, 0) * 1000.0 / vm.km_total)
            + GREATEST(0::numeric, 100 - COALESCE(em.aceleracao_brusca,  0) * 1000.0 / vm.km_total)
            + GREATEST(0::numeric, 100 - COALESCE(em.frenagem_brusca,    0) * 1000.0 / vm.km_total)
            + GREATEST(0::numeric, 100 - COALESCE(em.curva_drastica,     0) * 1000.0 / vm.km_total)
          ) / 4.0, 1) ELSE NULL END AS score_seguranca
   FROM viagens_mot vm
   LEFT JOIN eventos_mot em ON em.motorista_id = vm.motorista_id
   LEFT JOIN tb_motoristas m ON m.id = vm.motorista_id
  WHERE grupo_visivel(m.todos_grupos);
-- sem ORDER BY (ver nota A)

-- ------------------------------------- (B) `operacao` cru volta à dimensão --
DROP VIEW IF EXISTS vw_saneago_grupos CASCADE;
CREATE VIEW vw_saneago_grupos AS
 WITH combos AS (
   SELECT todos_grupos FROM tb_cadastro   WHERE todos_grupos IS NOT NULL AND grupo_visivel(todos_grupos)
   UNION
   SELECT todos_grupos FROM tb_motoristas WHERE todos_grupos IS NOT NULL AND grupo_visivel(todos_grupos)
 ),
 base AS (
   SELECT todos_grupos                           AS orig,
          arrumar_grupos(todos_grupos)            AS tg,
          split_grupo(todos_grupos, 'OPE'::text)  AS ope_bruto,
          split_outros(todos_grupos)              AS outros,
          split_grupo(todos_grupos, 'REG'::text)  AS reg_bruto,
          split_grupo(todos_grupos, 'ULOT'::text) AS ulot_bruto,
          sup_oficial(split_grupo(todos_grupos, 'REG'::text),
                      split_grupo(todos_grupos, 'SUP'::text)) AS sup_bruto
     FROM combos
 ),
 agrupado AS (
   SELECT tg              AS todos_grupos,
          min(orig)       AS todos_grupos_original,
          min(sup_bruto)  AS sup_bruto,
          min(reg_bruto)  AS reg_bruto,
          min(ulot_bruto) AS ulot_bruto,
          min(ope_bruto)  AS ope_bruto,
          min(outros)     AS outros
     FROM base
    WHERE tg IS NOT NULL
    GROUP BY tg
 )
 SELECT todos_grupos_original,
        todos_grupos,
        ope_bruto AS operacao,          -- cru, p/ os rótulos legados do Power BI
        grupo_codigo  (ope_bruto)  AS ope_codigo,
        grupo_nome    (ope_bruto)  AS ope_nome,
        grupo_cod_nome(ope_bruto)  AS ope_cod_nome,
        grupo_codigo  (sup_bruto)  AS sup_codigo,
        grupo_nome    (sup_bruto)  AS sup_nome,
        grupo_cod_nome(sup_bruto)  AS sup_cod_nome,
        grupo_codigo  (reg_bruto)  AS reg_codigo,
        grupo_nome    (reg_bruto)  AS reg_nome,
        grupo_cod_nome(reg_bruto)  AS reg_cod_nome,
        grupo_codigo  (ulot_bruto) AS ulot_codigo,
        grupo_nome    (ulot_bruto) AS ulot_nome,
        grupo_cod_nome(ulot_bruto) AS ulot_cod_nome,
        outros,
        grupo_nome(outros) AS outros_nome
   FROM agrupado
  ORDER BY todos_grupos;

COMMIT;
