-- ============================================================================
-- todos_grupos LIMPO em todas as views + quebra por nível SÓ na dimensão grupos
-- Data: 2026-08-25
--
-- DESENHO (definido pelo usuário):
--   * TODAS as views expõem `todos_grupos` já sem os rótulos que não são grupo
--     (Vehicle, Ethanol, Diesel, Manually Classified Powertrain, ...).
--     É essa coluna que serve de CHAVE para a dimensão de grupos.
--   * SOMENTE vw_saneago_grupos traz as colunas separadas por nível, com e sem
--     código (sup_nome/sup_cod_nome, reg_*, ulot_*).
--
-- MUDANÇAS DE APOIO:
--  1) tb_grupo_token_ignorado — lista dos rótulos a descartar, agora em TABELA
--     (antes era fixa dentro de arrumar_grupos). Descobri que
--     "Compressed Natural Gas" NÃO estava na lista antiga e vazava p/ o painel.
--     Novo combustível no futuro = 1 INSERT, sem mexer em função.
--  2) vw_saneago_grupos passa a ser a UNIÃO das combinações de VEÍCULOS e de
--     MOTORISTAS. Sem isso a dimensão não cobre os motoristas: só 263 das 1.348
--     combinações de motorista existem entre os veículos (19%) — 81% ficariam
--     sem superintendência/regional/lotação ao relacionar pela chave.
--
-- As views são DERRUBADAS e recriadas porque CREATE OR REPLACE não remove
-- coluna. Ordem de criação respeita as dependências.
-- Rollback: views_backup_2026-08-24.sql
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1) Rótulos que NÃO são grupo (combustível / tipo de veículo / powertrain)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tb_grupo_token_ignorado (
  token text PRIMARY KEY,
  obs   text
);

INSERT INTO public.tb_grupo_token_ignorado (token, obs) VALUES
  ('Vehicle',                        'tipo de ativo'),
  ('Diesel',                         'combustível'),
  ('Ethanol',                        'combustível'),
  ('Gasoline or Petrol',             'combustível'),
  ('Compressed Natural Gas',         'combustível — FALTAVA na lista antiga, vazava p/ o painel'),
  ('Hybrid',                         'powertrain'),
  ('Electric',                       'powertrain'),
  ('Manually Classified Powertrain', 'powertrain')
ON CONFLICT (token) DO UPDATE SET obs = EXCLUDED.obs;

-- arrumar_grupos passa a consultar a tabela (por isso STABLE, não IMMUTABLE).
-- Mantém a ORDEM original dos tokens e normaliza o separador para ' | '.
CREATE OR REPLACE FUNCTION public.arrumar_grupos(p_todos text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(string_agg(tok, ' | ' ORDER BY ord), '')
    FROM (
        SELECT btrim(t.tok) AS tok, t.ord
        FROM unnest(string_to_array(p_todos, '|')) WITH ORDINALITY AS t(tok, ord)
    ) s
    WHERE s.tok <> ''
      AND NOT EXISTS (SELECT 1 FROM public.tb_grupo_token_ignorado i WHERE i.token = s.tok);
$$;

-- ----------------------------------------------------------------------------
-- 2) Derruba as views (CREATE OR REPLACE não remove coluna)
-- ----------------------------------------------------------------------------
DROP VIEW IF EXISTS vw_saneago_grupos              CASCADE;
DROP VIEW IF EXISTS vw_saneago_motoristas_anual    CASCADE;
DROP VIEW IF EXISTS vw_saneago_motoristas          CASCADE;
DROP VIEW IF EXISTS vw_saneago_indicadores_mensal  CASCADE;
DROP VIEW IF EXISTS vw_saneago_resumo_frota_mensal CASCADE;
DROP VIEW IF EXISTS vw_saneago_relatorio_viagens   CASCADE;
DROP VIEW IF EXISTS vw_saneago_comportamento       CASCADE;
DROP VIEW IF EXISTS vw_saneago_status              CASCADE;
DROP VIEW IF EXISTS vw_saneago_cadastro            CASCADE;

-- ============================================================================
-- 3) VIEWS — todos_grupos limpo; sem colunas separadas (exceto em grupos)
-- ============================================================================

-- -------------------------------------------------------------- cadastro ---
-- sup/reg/ulot/operacao/outros MANTIDOS: o Power BI atual ainda os usa. Podem
-- ser removidos depois que o M passar a puxar tudo da dimensão de grupos.
CREATE VIEW vw_saneago_cadastro AS
 SELECT id, serial, placa, veiculo, marca, modelo, ano, tipo_veiculo,
        grupo,
        arrumar_grupos(todos_grupos) AS todos_grupos,
        ativo, atualizado_em,
        split_grupo(todos_grupos, 'OPE'::text)  AS operacao,
        split_grupo(todos_grupos, 'SUP'::text)  AS sup,
        split_grupo(todos_grupos, 'REG'::text)  AS reg,
        split_grupo(todos_grupos, 'ULOT'::text) AS ulot,
        split_outros(todos_grupos)              AS outros,
        marca_padrao(marca, modelo)  AS marca_padrao,
        modelo_padrao(marca, modelo) AS modelo_padrao,
        sup_oficial(split_grupo(todos_grupos, 'REG'::text),
                    split_grupo(todos_grupos, 'SUP'::text)) AS sup_oficial
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
          c.placa, c.marca, c.modelo, c.grupo AS uo_lotacao, c.todos_grupos,
          c.marca_padrao, c.modelo_padrao, c.sup_oficial,
          (LEAST((date_trunc('month', make_date(r.ano, r.mes, 1)) + interval '1 month' - interval '1 day')::date, CURRENT_DATE)
            - date_trunc('month', make_date(r.ano, r.mes, 1))::date + 1) AS dias_no_periodo
     FROM tb_resumo_mensal r JOIN vw_saneago_cadastro c ON c.id = r.device_id
    WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE)
 SELECT placa, marca, modelo, uo_lotacao, todos_grupos, ano, mes,
        to_char(make_date(ano, mes, 1), 'YYYY-MM') AS ano_mes,
        dias_no_periodo, dias_utilizados,
        round(km::numeric, 1) AS km_rodado,
        round((km / NULLIF(dias_utilizados,0))::numeric, 1) AS media_km_dia,
        round((duracao_segundos/3600.0)::numeric, 1) AS tempo_movimento_h,
        round(LEAST(dias_utilizados, dias_no_periodo)::numeric / NULLIF(dias_no_periodo,0) * 100, 0) AS taxa_utilizacao_pct,
        viagens,
        CASE WHEN modelo IS NULL OR modelo = '' THEN marca ELSE modelo END AS modelo2,
        marca_padrao, modelo_padrao, sup_oficial
   FROM base
  ORDER BY placa, ano, mes;

-- --------------------------------------------------- indicadores mensais ---
CREATE VIEW vw_saneago_indicadores_mensal
WITH (security_invoker = on) AS
 WITH base AS (
   SELECT r.device_id, r.ano, r.mes, r.km, r.duracao_segundos, r.dias_utilizados,
          c.grupo AS uo_lotacao, c.todos_grupos,
          (LEAST((date_trunc('month', make_date(r.ano, r.mes, 1)) + interval '1 month' - interval '1 day')::date, CURRENT_DATE)
            - date_trunc('month', make_date(r.ano, r.mes, 1))::date + 1) AS dias_no_periodo
     FROM tb_resumo_mensal r JOIN vw_saneago_cadastro c ON c.id = r.device_id
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

-- ------------------------------------------------------------ motoristas ---
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
        m.lotacao,
        m.regional,
        m.superintendencia,
        arrumar_grupos(m.todos_grupos) AS todos_grupos,
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
       + COALESCE(ed.curvas_drasticas,     0) * 1) AS score_risco,
        sup_oficial(m.regional, m.superintendencia) AS superintendencia_oficial
   FROM viagens_dia vd
   FULL JOIN eventos_dia ed ON ed.motorista_id = vd.motorista_id AND ed.dia = vd.dia
   LEFT JOIN tb_motoristas m ON m.id = COALESCE(vd.motorista_id, ed.motorista_id)
  WHERE grupo_visivel(m.todos_grupos)
  ORDER BY m.matricula, data;

-- ----------------------------------------------------- motoristas anual ---
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
        m.lotacao,
        m.regional,
        m.superintendencia,
        arrumar_grupos(m.todos_grupos) AS todos_grupos,
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
          ) / 4.0, 1) ELSE NULL END AS score_seguranca,
        sup_oficial(m.regional, m.superintendencia) AS superintendencia_oficial
   FROM viagens_mot vm
   LEFT JOIN eventos_mot em ON em.motorista_id = vm.motorista_id
   LEFT JOIN tb_motoristas m ON m.id = vm.motorista_id
  WHERE grupo_visivel(m.todos_grupos)
  ORDER BY score_seguranca ASC NULLS LAST;

-- ---------------------------------------------------------------- grupos ---
-- DIMENSÃO. Única view com a quebra por nível (com e sem código).
-- UNIÃO de veículos + motoristas: sem os motoristas, 81% deles não achariam
-- correspondência ao relacionar por todos_grupos.
CREATE VIEW vw_saneago_grupos AS
 WITH combos AS (
   SELECT todos_grupos FROM tb_cadastro   WHERE todos_grupos IS NOT NULL AND grupo_visivel(todos_grupos)
   UNION
   SELECT todos_grupos FROM tb_motoristas WHERE todos_grupos IS NOT NULL AND grupo_visivel(todos_grupos)
 ),
 limpos AS (
   SELECT DISTINCT arrumar_grupos(todos_grupos) AS todos_grupos,
          split_grupo(todos_grupos, 'OPE'::text)  AS operacao,
          split_grupo(todos_grupos, 'SUP'::text)  AS sup,
          split_grupo(todos_grupos, 'REG'::text)  AS reg,
          split_grupo(todos_grupos, 'ULOT'::text) AS ulot,
          split_outros(todos_grupos)              AS outros,
          sup_oficial(split_grupo(todos_grupos, 'REG'::text),
                      split_grupo(todos_grupos, 'SUP'::text)) AS sup_oficial
     FROM combos
 )
 SELECT todos_grupos,
        todos_grupos AS todos_grupos_arrumado,   -- compatibilidade com o M atual
        operacao, sup, reg, ulot, outros, sup_oficial,
        grupo_codigo  (sup_oficial) AS sup_codigo,
        grupo_nome    (sup_oficial) AS sup_nome,
        grupo_cod_nome(sup_oficial) AS sup_cod_nome,
        grupo_codigo  (reg)  AS reg_codigo,
        grupo_nome    (reg)  AS reg_nome,
        grupo_cod_nome(reg)  AS reg_cod_nome,
        grupo_codigo  (ulot) AS ulot_codigo,
        grupo_nome    (ulot) AS ulot_nome,
        grupo_cod_nome(ulot) AS ulot_cod_nome
   FROM limpos
  WHERE todos_grupos IS NOT NULL
  ORDER BY todos_grupos;

COMMIT;
