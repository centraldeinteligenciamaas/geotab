-- ============================================================================
-- Migração: empurrar filtros/limpezas do Power BI para dentro das views
-- Data: 2026-08-24
-- Rollback: psql ... -f views_backup_2026-08-24.sql
--
-- Princípio (decidido com o usuário): move-se para o SQL tudo que só REMOVE
-- LINHAS (filtros de grupo/palavra/placa) ou ADICIONA COLUNAS NOVAS (limpezas
-- de dado). NÃO se mexe em valores de colunas existentes (Text.Proper,
-- normalização do 'veiculo', renomeações "amigáveis", duração) — isso fica no
-- M para não quebrar relacionamentos/medidas do modelo do Power BI.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1) Função central da lista de exclusão de grupos.
--    grupo_visivel(todos_grupos) = FALSE se QUALQUER grupo do veículo casar com
--    um prefixo da lista. Prefixo (left(...)) evita depender do nº do contrato
--    (ex.: "OPE_COMURG - 003/2026" casa por "OPE_COMURG").
--    OPE_SANEAGO NÃO está na lista de propósito (é o contrato principal).
--    Para mudar a regra no futuro, edite SÓ esta função.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.grupo_visivel(p_todos text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NOT EXISTS (
    SELECT 1
    FROM unnest(string_to_array(COALESCE(p_todos, ''), '|')) AS tok
    CROSS JOIN (VALUES
      ('OPE_COMURG'),
      ('OPE_SEINFRA'),
      ('OPE_PEDREIRA'),
      ('OPE_CS_BRASIL'),
      ('P-CSB'),
      ('OPE_AGETUL'),
      ('OPE_SMT'),
      ('OPE_SEPLANH'),
      ('OPE_AMMA'),
      ('OPE_SEMAD'),
      ('OPE_SECULT'),
      ('OPE_SECRET. DA ECONOMIA'),
      ('OPE - SERVIÇOS EM CAMPO'),
      ('OPE - ADMINISTRATIVO'),
      ('OPE - ASSISTÊNCIA SOCIAL'),
      ('OPE - RECOLHIMENTO DE ANIMAIS'),
      ('OPE - DIRETORIA/GERÊNCIA'),
      ('OPE - ATERRO SANITÁRIO'),
      ('REDEMOB')
    ) AS ex(prefixo)
    WHERE left(btrim(tok), length(ex.prefixo)) = ex.prefixo
  );
$$;

-- ----------------------------------------------------------------------------
-- 2) vw_cadastro  — filtro unificado via grupo_visivel + exclusão das 3 placas
--    (o M tinha bug: "not A or not B or not C" nunca exclui nada; aqui exclui
--    de fato as 3 placas, que era a intenção). Colunas inalteradas.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_cadastro AS
 SELECT id, serial, placa, veiculo, marca, modelo, ano, tipo_veiculo,
        grupo, todos_grupos, ativo, atualizado_em,
        split_grupo(todos_grupos, 'OPE'::text)  AS operacao,
        split_grupo(todos_grupos, 'SUP'::text)  AS sup,
        split_grupo(todos_grupos, 'REG'::text)  AS reg,
        split_grupo(todos_grupos, 'ULOT'::text) AS ulot,
        split_outros(todos_grupos)              AS outros
   FROM tb_cadastro c
  WHERE grupo_visivel(todos_grupos)
    AND placa NOT IN ('TFA2G98', 'TFN3B44', 'TFR4E14');

-- ----------------------------------------------------------------------------
-- 3) vw_status  — filtro herdado do JOIN vw_cadastro (não repete a lista).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_status AS
 SELECT s.id, s.serial, s.placa, s.comunicando, s.ultimo_contato,
        s.latitude, s.longitude, s.velocidade, s.ignicao_ligada,
        s.motorista_nome, s.motorista_email, s.motorista_tel,
        s.viagem_inicio, s.snapshot_em, s.viagem_fim, s.todos_grupos
   FROM tb_status s
   JOIN vw_cadastro c ON c.id = s.id;

-- ----------------------------------------------------------------------------
-- 4) vw_relatorio_viagens  — PLUGA O FURO: JOIN vw_cadastro (antes era LEFT JOIN
--    tb_cadastro, sem filtro nenhum). + colunas NOVAS de sanitização de
--    velocidade (velocidade_media_2 / velo_max_2), que o M criava.
--    Aterro já sai pela grupo_visivel. Colunas existentes preservadas na ordem.
-- ----------------------------------------------------------------------------
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
        v.motorista_matricula,
        -- NOVAS (limpeza de outliers, antes feita no M):
        CASE WHEN v.velocidade_media  > 150 THEN 0 ELSE v.velocidade_media  END AS velocidade_media_2,
        CASE WHEN v.velocidade_maxima > 200 THEN 0 ELSE v.velocidade_maxima END AS velo_max_2
   FROM tb_viagens v
     JOIN vw_cadastro c ON c.id = v.device_id
     LEFT JOIN tb_enderecos ep ON ep.lat = round(v.lat_partida::numeric, 3) AND ep.lon = round(v.lon_partida::numeric, 3)
     LEFT JOIN tb_enderecos ec ON ec.lat = round(v.lat_chegada::numeric, 3) AND ec.lon = round(v.lon_chegada::numeric, 3)
  ORDER BY c.placa, v.data_partida;

-- ----------------------------------------------------------------------------
-- 5) vw_resumo_frota_mensal  — filtro herdado do JOIN vw_cadastro. + coluna
--    NOVA modelo2 (modelo vazio -> marca), que o M criava.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_resumo_frota_mensal
WITH (security_invoker = on) AS
 WITH base AS (
   SELECT r.device_id, r.ano, r.mes, r.km, r.duracao_segundos, r.dias_utilizados, r.viagens,
          c.placa, c.marca, c.modelo, c.grupo AS uo_lotacao, c.todos_grupos,
          (LEAST((date_trunc('month', make_date(r.ano, r.mes, 1)) + interval '1 month' - interval '1 day')::date, CURRENT_DATE)
            - date_trunc('month', make_date(r.ano, r.mes, 1))::date + 1) AS dias_no_periodo
     FROM tb_resumo_mensal r JOIN vw_cadastro c ON c.id = r.device_id
    WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE)
 SELECT placa, marca, modelo, uo_lotacao, todos_grupos, ano, mes,
        to_char(make_date(ano, mes, 1), 'YYYY-MM') AS ano_mes,
        dias_no_periodo, dias_utilizados,
        round(km::numeric, 1) AS km_rodado,
        round((km / NULLIF(dias_utilizados,0))::numeric, 1) AS media_km_dia,
        round((duracao_segundos/3600.0)::numeric, 1) AS tempo_movimento_h,
        round(LEAST(dias_utilizados, dias_no_periodo)::numeric / NULLIF(dias_no_periodo,0) * 100, 0) AS taxa_utilizacao_pct,
        viagens,
        -- NOVA (modelo vazio -> marca, antes feita no M):
        CASE WHEN modelo IS NULL OR modelo = '' THEN marca ELSE modelo END AS modelo2
   FROM base
  ORDER BY placa, ano, mes;

-- ----------------------------------------------------------------------------
-- 6) vw_indicadores_mensal  — filtro herdado do JOIN vw_cadastro. Sem mudança
--    de colunas (só o filtro sai do M).
-- ----------------------------------------------------------------------------
-- (inalterada estruturalmente; recriada só para garantir a versão do arquivo)
CREATE OR REPLACE VIEW vw_indicadores_mensal
WITH (security_invoker = on) AS
 WITH base AS (
   SELECT r.device_id, r.ano, r.mes, r.km, r.duracao_segundos, r.dias_utilizados,
          c.grupo AS uo_lotacao, c.todos_grupos,
          (LEAST((date_trunc('month', make_date(r.ano, r.mes, 1)) + interval '1 month' - interval '1 day')::date, CURRENT_DATE)
            - date_trunc('month', make_date(r.ano, r.mes, 1))::date + 1) AS dias_no_periodo
     FROM tb_resumo_mensal r JOIN vw_cadastro c ON c.id = r.device_id
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

-- ----------------------------------------------------------------------------
-- 7) vw_motoristas  — ANTES sem filtro de grupo. Agora aplica grupo_visivel
--    (cobre os OPE_COMURG/OPE_SEMAD/etc. que o M filtrava no fim). Motorista
--    sem grupo (todos_grupos NULL) continua visível. Colunas inalteradas.
-- ----------------------------------------------------------------------------
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
 SELECT m.nome          AS motorista_nome,
        m.nome_completo AS motorista_nome_completo,
        m.matricula     AS motorista_matricula,
        m.lotacao,
        m.regional,
        m.superintendencia,
        m.todos_grupos,
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
  WHERE grupo_visivel(m.todos_grupos)
  ORDER BY m.matricula, data;

-- ----------------------------------------------------------------------------
-- 8) vw_motoristas_anual  — idem: aplica grupo_visivel. Colunas inalteradas.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_motoristas_anual
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
        m.lotacao,
        m.regional,
        m.superintendencia,
        m.todos_grupos,
        vm.qtd_veiculos,
        vm.veiculos,
        vm.viagens,
        vm.km_total,
        vm.horas_movimento,
        vm.horas_ocioso,
        vm.horas_parado,
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
  WHERE grupo_visivel(m.todos_grupos)
  ORDER BY score_seguranca ASC NULLS LAST;

-- ----------------------------------------------------------------------------
-- 9) vw_grupos  — lê tb_cadastro cru; aplica grupo_visivel (o M filtrava aqui).
--    Value-shaping (renomeações amigáveis, splits) continua no M.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_grupos AS
 SELECT DISTINCT todos_grupos,
    arrumar_grupos(todos_grupos) AS todos_grupos_arrumado,
    split_grupo(todos_grupos, 'OPE'::text) AS operacao,
    split_grupo(todos_grupos, 'SUP'::text) AS sup,
    split_grupo(todos_grupos, 'REG'::text) AS reg,
    split_grupo(todos_grupos, 'ULOT'::text) AS ulot,
    split_outros(todos_grupos) AS outros
   FROM tb_cadastro c
  WHERE todos_grupos IS NOT NULL
    AND grupo_visivel(todos_grupos)
  ORDER BY todos_grupos;

COMMIT;
