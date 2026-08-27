-- ============================================================================
-- Tratamento de SUPERINTENDÊNCIA / REGIONAL / LOTAÇÃO a partir de todos_grupos
-- Data: 2026-08-25
--
-- todos_grupos é a coluna que dita os 3 níveis de cada linha. O texto cru vem como
--   SUP_S0071 - SUPER.REGION. OPER.DO INTERIOR
-- e o painel precisa de duas leituras dele:
--   *_nome      -> "Super.Region. Oper.Do Interior"            (só o nome, capitalizado)
--   *_cod_nome  -> "S0071 - Super.Region. Oper.Do Interior"    (código + nome)
-- Incluí também *_codigo (só "S0071") — útil p/ ordenar e casar com planilha.
--
-- FORMATOS TRATADOS (levantados na base):
--   "SUP_S0071 - NOME"        -> padrão, com espaços ao redor do hífen  (3.057 linhas)
--   "REG_G0162-NOME"          -> hífen SEM espaços                     (36 linhas)
--   nomes com hífen próprio   -> "ULOT_T0171-DISTRITO-FLORES DE GOIAS"
--                                (o corte é no PRIMEIRO hífen, então "Distrito-Flores
--                                 De Goias" é preservado inteiro)
--   nível ausente             -> devolve NULL (28 sem sup, 34 sem reg, 31 sem ulot)
-- Isso dispensa os ReplaceValue manuais do Power BI para G0162 e T0171.
--
-- A superintendência é derivada de sup_oficial(), então a correção de hierarquia
-- (caso Palmeiras) já vem embutida nas colunas de exibição.
--
-- Rollback: views_backup_2026-08-24.sql
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- grupo_codigo: "SUP_S0071 - SUPER..." -> "S0071"
--   Pega o que vem depois do 1º "_" até o 1º hífen ou espaço.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.grupo_codigo(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(btrim(COALESCE(
    (regexp_match(COALESCE(p, ''), '^[A-Za-z]+_([^-\s]+)'))[1], '')), '');
$$;

-- ----------------------------------------------------------------------------
-- grupo_nome: "SUP_S0071 - SUPER.REGION. OPER" -> "Super.Region. Oper"
--   Corta no PRIMEIRO hífen (com ou sem espaços) e capitaliza.
--   initcap() equivale ao Text.Proper do Power Query.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.grupo_nome(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(initcap(btrim(COALESCE(
    (regexp_match(COALESCE(p, ''), '^[A-Za-z]+_[^-\s]+\s*-\s*(.*)$'))[1], ''))), '');
$$;

-- ----------------------------------------------------------------------------
-- grupo_cod_nome: "S0071 - Super.Region. Oper"  (concat_ws ignora NULL)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.grupo_cod_nome(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(concat_ws(' - ', grupo_codigo(p), grupo_nome(p)), '');
$$;

-- ============================================================================
-- VIEWS — colunas ADITIVAS (sup/reg/ulot originais preservados)
-- ============================================================================

-- ---------------------------------------------------------------- cadastro --
CREATE OR REPLACE VIEW vw_saneago_cadastro AS
 SELECT id, serial, placa, veiculo, marca, modelo, ano, tipo_veiculo,
        grupo, todos_grupos, ativo, atualizado_em,
        split_grupo(todos_grupos, 'OPE'::text)  AS operacao,
        split_grupo(todos_grupos, 'SUP'::text)  AS sup,
        split_grupo(todos_grupos, 'REG'::text)  AS reg,
        split_grupo(todos_grupos, 'ULOT'::text) AS ulot,
        split_outros(todos_grupos)              AS outros,
        marca_padrao(marca, modelo)  AS marca_padrao,
        modelo_padrao(marca, modelo) AS modelo_padrao,
        sup_oficial(split_grupo(todos_grupos, 'REG'::text),
                    split_grupo(todos_grupos, 'SUP'::text)) AS sup_oficial,
        -- NOVAS: exibição dos 3 níveis (sup já com a hierarquia corrigida)
        grupo_codigo  (sup_oficial(split_grupo(todos_grupos,'REG'), split_grupo(todos_grupos,'SUP'))) AS sup_codigo,
        grupo_nome    (sup_oficial(split_grupo(todos_grupos,'REG'), split_grupo(todos_grupos,'SUP'))) AS sup_nome,
        grupo_cod_nome(sup_oficial(split_grupo(todos_grupos,'REG'), split_grupo(todos_grupos,'SUP'))) AS sup_cod_nome,
        grupo_codigo  (split_grupo(todos_grupos,'REG'))  AS reg_codigo,
        grupo_nome    (split_grupo(todos_grupos,'REG'))  AS reg_nome,
        grupo_cod_nome(split_grupo(todos_grupos,'REG'))  AS reg_cod_nome,
        grupo_codigo  (split_grupo(todos_grupos,'ULOT')) AS ulot_codigo,
        grupo_nome    (split_grupo(todos_grupos,'ULOT')) AS ulot_nome,
        grupo_cod_nome(split_grupo(todos_grupos,'ULOT')) AS ulot_cod_nome
   FROM tb_cadastro c
  WHERE grupo_visivel(todos_grupos)
    AND placa NOT IN ('TFA2G98', 'TFN3B44', 'TFR4E14');

-- ------------------------------------------------------------------ grupos --
CREATE OR REPLACE VIEW vw_saneago_grupos AS
 SELECT DISTINCT todos_grupos,
    arrumar_grupos(todos_grupos) AS todos_grupos_arrumado,
    split_grupo(todos_grupos, 'OPE'::text) AS operacao,
    split_grupo(todos_grupos, 'SUP'::text) AS sup,
    split_grupo(todos_grupos, 'REG'::text) AS reg,
    split_grupo(todos_grupos, 'ULOT'::text) AS ulot,
    split_outros(todos_grupos) AS outros,
    sup_oficial(split_grupo(todos_grupos, 'REG'::text),
                split_grupo(todos_grupos, 'SUP'::text)) AS sup_oficial,
    grupo_codigo  (sup_oficial(split_grupo(todos_grupos,'REG'), split_grupo(todos_grupos,'SUP'))) AS sup_codigo,
    grupo_nome    (sup_oficial(split_grupo(todos_grupos,'REG'), split_grupo(todos_grupos,'SUP'))) AS sup_nome,
    grupo_cod_nome(sup_oficial(split_grupo(todos_grupos,'REG'), split_grupo(todos_grupos,'SUP'))) AS sup_cod_nome,
    grupo_codigo  (split_grupo(todos_grupos,'REG'))  AS reg_codigo,
    grupo_nome    (split_grupo(todos_grupos,'REG'))  AS reg_nome,
    grupo_cod_nome(split_grupo(todos_grupos,'REG'))  AS reg_cod_nome,
    grupo_codigo  (split_grupo(todos_grupos,'ULOT')) AS ulot_codigo,
    grupo_nome    (split_grupo(todos_grupos,'ULOT')) AS ulot_nome,
    grupo_cod_nome(split_grupo(todos_grupos,'ULOT')) AS ulot_cod_nome
   FROM tb_cadastro c
  WHERE todos_grupos IS NOT NULL
    AND grupo_visivel(todos_grupos)
  ORDER BY todos_grupos;

-- ------------------------------------------------- resumo de frota mensal --
CREATE OR REPLACE VIEW vw_saneago_resumo_frota_mensal
WITH (security_invoker = on) AS
 WITH base AS (
   SELECT r.device_id, r.ano, r.mes, r.km, r.duracao_segundos, r.dias_utilizados, r.viagens,
          c.placa, c.marca, c.modelo, c.grupo AS uo_lotacao, c.todos_grupos,
          c.marca_padrao, c.modelo_padrao, c.sup_oficial,
          c.sup_codigo, c.sup_nome, c.sup_cod_nome,
          c.reg_codigo, c.reg_nome, c.reg_cod_nome,
          c.ulot_codigo, c.ulot_nome, c.ulot_cod_nome,
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
        marca_padrao, modelo_padrao, sup_oficial,
        sup_codigo, sup_nome, sup_cod_nome,
        reg_codigo, reg_nome, reg_cod_nome,
        ulot_codigo, ulot_nome, ulot_cod_nome
   FROM base
  ORDER BY placa, ano, mes;

-- --------------------------------------------------- indicadores mensais --
CREATE OR REPLACE VIEW vw_saneago_indicadores_mensal
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
        round(avg(LEAST(dias_utilizados, dias_no_periodo)::numeric / NULLIF(dias_no_periodo,0) * 100), 0) AS taxa_media_utilizacao_pct,
        -- NOVAS (derivadas de todos_grupos, que já está no GROUP BY)
        grupo_codigo  (sup_oficial(split_grupo(todos_grupos,'REG'), split_grupo(todos_grupos,'SUP'))) AS sup_codigo,
        grupo_nome    (sup_oficial(split_grupo(todos_grupos,'REG'), split_grupo(todos_grupos,'SUP'))) AS sup_nome,
        grupo_cod_nome(sup_oficial(split_grupo(todos_grupos,'REG'), split_grupo(todos_grupos,'SUP'))) AS sup_cod_nome,
        grupo_codigo  (split_grupo(todos_grupos,'REG'))  AS reg_codigo,
        grupo_nome    (split_grupo(todos_grupos,'REG'))  AS reg_nome,
        grupo_cod_nome(split_grupo(todos_grupos,'REG'))  AS reg_cod_nome,
        grupo_codigo  (split_grupo(todos_grupos,'ULOT')) AS ulot_codigo,
        grupo_nome    (split_grupo(todos_grupos,'ULOT')) AS ulot_nome,
        grupo_cod_nome(split_grupo(todos_grupos,'ULOT')) AS ulot_cod_nome
   FROM base
  GROUP BY uo_lotacao, todos_grupos, ano, mes
  ORDER BY todos_grupos, ano, mes;

COMMIT;
