-- ============================================================================
-- Níveis repetidos na hierarquia de grupos  — 2026-08-26
--
-- PROBLEMA (dado de origem, não da função): no cadastro da Geotab a MESMA
-- unidade aparece sob vários prefixos. Ex.:
--   REG_S0021 - SUPERIN. DE ESTUDOS E PROJETOS |
--   ULOT_S0021 - SUPERIN. DE ESTUDOS E PROJETOS |
--   SUP_S0021 - SUPERIN. DE ESTUDOS E PROJETOS
-- Resultado: a coluna "regional" exibia o nome da SUPERINTENDÊNCIA, e a de
-- lotação exibia superintendência ou regional. split_grupo() estava certo —
-- pegava o token REG_/ULOT_ correto; o token é que carrega conteúdo do nível
-- de cima. Mesmo sintoma do caso Palmeiras.
--
-- REGRA APLICADA: um nível que apenas REPETE o código do nível acima não
-- carrega informação — vira NULL.
--   regional  -> NULL quando reg_codigo  = sup_codigo
--   lotação   -> NULL quando ulot_codigo = sup_codigo OU = reg_codigo
-- Medido antes: 50 grupos com regional repetida (24 veículos) e 335 com
-- lotação repetida (208 veículos), de 1.721 grupos / 1.062 veículos.
--
-- Só vw_saneago_grupos muda, e a lista de colunas é a mesma -> CREATE OR
-- REPLACE (sem DROP, portanto sem lock exclusivo travando com refresh do BI).
-- O texto cru continua auditável em `todos_grupos_original`.
-- ============================================================================
BEGIN;
CREATE OR REPLACE VIEW vw_saneago_grupos AS
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
 ),
 codigos AS (
   SELECT a.*,
          grupo_codigo(sup_bruto)  AS c_sup,
          grupo_codigo(reg_bruto)  AS c_reg,
          grupo_codigo(ulot_bruto) AS c_ulot
     FROM agrupado a
 ),
 limpo AS (
   SELECT c.*,
          CASE WHEN c_reg IS NOT NULL AND c_reg = c_sup
               THEN NULL ELSE reg_bruto END AS reg_ok,
          CASE WHEN c_ulot IS NOT NULL AND (c_ulot = c_sup OR c_ulot = c_reg)
               THEN NULL ELSE ulot_bruto END AS ulot_ok
     FROM codigos c
 )
 SELECT hashtext(todos_grupos) AS grupo_id,
        todos_grupos_original,
        todos_grupos,
        ope_bruto AS operacao,
        grupo_codigo  (ope_bruto)  AS ope_codigo,
        grupo_nome    (ope_bruto)  AS ope_nome,
        grupo_cod_nome(ope_bruto)  AS ope_cod_nome,
        grupo_codigo  (sup_bruto)  AS sup_codigo,
        grupo_nome    (sup_bruto)  AS sup_nome,
        grupo_cod_nome(sup_bruto)  AS sup_cod_nome,
        grupo_codigo  (reg_ok)     AS reg_codigo,
        grupo_nome    (reg_ok)     AS reg_nome,
        grupo_cod_nome(reg_ok)     AS reg_cod_nome,
        grupo_codigo  (ulot_ok)    AS ulot_codigo,
        grupo_nome    (ulot_ok)    AS ulot_nome,
        grupo_cod_nome(ulot_ok)    AS ulot_cod_nome,
        outros,
        grupo_nome(outros) AS outros_nome
   FROM limpo
  ORDER BY todos_grupos;
COMMIT;
