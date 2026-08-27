-- ============================================================================
-- Tratamento de grupos nas views de MOTORISTAS  (2026-08-25)
--
-- tb_motoristas guarda lotacao/regional/superintendencia com o MESMO formato de
-- tb_cadastro, mas com duas diferenças que exigem ajuste:
--
--  1) FALLBACK na lotação: extrair_motoristas() usa o 1º grupo útil quando o
--     motorista não tem grupo ULOT_. Por isso `lotacao` às vezes traz REG_/SUP_/
--     OPE_/PRE_. Depois do filtro de grupos são 2.994 de 159.792 linhas (1,9%).
--     É exatamente o que a coluna `lot3` do Power BI contornava.
--
--  2) Dois formatos especiais:
--       "PRE _ D2000 - PRESIDENCIA"    -> espaço ANTES do underscore
--       "OPE_SANEAGO - 30000070/2025"  -> nome é o nº do contrato
--     Ambos tinham ReplaceValue manual no Power BI.
--
-- Ajustes feitos aqui:
--   - grupo_codigo/grupo_nome aceitam espaço ao redor do "_"
--   - grupo_nome ganha FALLBACK: se não achar código/hífen, devolve o texto
--     capitalizado (em vez de NULL) — mesmo comportamento do `lot3`
--   - exceções D2000 -> "Presidência" e SANEAGO -> "CT. 30000070/2025"
--   - colunas *_codigo / *_nome / *_cod_nome nas 2 views de motoristas
--
-- Rollback: views_backup_2026-08-24.sql
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------- funções --
-- Aceita "SUP_S0071" e também "PRE _ D2000".
CREATE OR REPLACE FUNCTION public.grupo_codigo(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(btrim(COALESCE(
    (regexp_match(COALESCE(p, ''), '^[A-Za-z]+\s*_\s*([^-\s]+)'))[1], '')), '');
$$;

-- Ordem: exceção cadastrada -> nome após o 1º hífen -> texto cru capitalizado.
CREATE OR REPLACE FUNCTION public.grupo_nome(p text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    (SELECT e.nome_exibicao FROM public.tb_grupo_nome_excecao e
      WHERE e.codigo = grupo_codigo(p)),
    NULLIF(initcap(btrim(COALESCE(
      (regexp_match(COALESCE(p, ''), '^[A-Za-z]+\s*_\s*[^-\s]+\s*-\s*(.*)$'))[1], ''))), ''),
    NULLIF(initcap(btrim(COALESCE(p, ''))), '')
  );
$$;

-- ------------------------------------------------------------- exceções --
INSERT INTO public.tb_grupo_nome_excecao (codigo, nome_exibicao, obs) VALUES
  ('D2000',   'Presidência',        'grupo vem como "PRE _ D2000 - PRESIDENCIA"; equivale ao ReplaceValue do Power BI'),
  ('SANEAGO', 'CT. 30000070/2025',  'grupo "OPE_SANEAGO - 30000070/2025" = contrato principal; nome de exibição pedido pelo usuário')
ON CONFLICT (codigo) DO UPDATE
  SET nome_exibicao = EXCLUDED.nome_exibicao, obs = EXCLUDED.obs;

-- ============================================================================
-- vw_saneago_motoristas  (motorista × dia) — colunas ADITIVAS
-- ============================================================================
CREATE OR REPLACE VIEW vw_saneago_motoristas
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
       + COALESCE(ed.curvas_drasticas,     0) * 1) AS score_risco,
        -- NOVAS: substituem lot3 e os ReplaceValue do Power BI
        grupo_codigo  (m.lotacao) AS lotacao_codigo,
        grupo_nome    (m.lotacao) AS lotacao_nome,
        grupo_cod_nome(m.lotacao) AS lotacao_cod_nome,
        grupo_codigo  (m.regional) AS regional_codigo,
        grupo_nome    (m.regional) AS regional_nome,
        grupo_cod_nome(m.regional) AS regional_cod_nome,
        -- superintendência já com a hierarquia corrigida (caso Palmeiras)
        sup_oficial(m.regional, m.superintendencia)                 AS superintendencia_oficial,
        grupo_codigo  (sup_oficial(m.regional, m.superintendencia)) AS superintendencia_codigo,
        grupo_nome    (sup_oficial(m.regional, m.superintendencia)) AS superintendencia_nome,
        grupo_cod_nome(sup_oficial(m.regional, m.superintendencia)) AS superintendencia_cod_nome
   FROM viagens_dia vd
   FULL JOIN eventos_dia ed ON ed.motorista_id = vd.motorista_id AND ed.dia = vd.dia
   LEFT JOIN tb_motoristas m ON m.id = COALESCE(vd.motorista_id, ed.motorista_id)
  WHERE grupo_visivel(m.todos_grupos)
  ORDER BY m.matricula, data;

-- ============================================================================
-- vw_saneago_motoristas_anual  (1 linha por motorista) — colunas ADITIVAS
-- ============================================================================
CREATE OR REPLACE VIEW vw_saneago_motoristas_anual
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
          ) / 4.0, 1) ELSE NULL END AS score_seguranca,
        -- NOVAS:
        grupo_codigo  (m.lotacao) AS lotacao_codigo,
        grupo_nome    (m.lotacao) AS lotacao_nome,
        grupo_cod_nome(m.lotacao) AS lotacao_cod_nome,
        grupo_codigo  (m.regional) AS regional_codigo,
        grupo_nome    (m.regional) AS regional_nome,
        grupo_cod_nome(m.regional) AS regional_cod_nome,
        sup_oficial(m.regional, m.superintendencia)                 AS superintendencia_oficial,
        grupo_codigo  (sup_oficial(m.regional, m.superintendencia)) AS superintendencia_codigo,
        grupo_nome    (sup_oficial(m.regional, m.superintendencia)) AS superintendencia_nome,
        grupo_cod_nome(sup_oficial(m.regional, m.superintendencia)) AS superintendencia_cod_nome
   FROM viagens_mot vm
   LEFT JOIN eventos_mot em ON em.motorista_id = vm.motorista_id
   LEFT JOIN tb_motoristas m ON m.id = vm.motorista_id
  WHERE grupo_visivel(m.todos_grupos)
  ORDER BY score_seguranca ASC NULLS LAST;

COMMIT;
