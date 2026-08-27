-- ============================================================================
-- Migração: apontamentos SANEAGO — itens 7, 8 e 9 da triagem
-- Data: 2026-08-25   (triagem: triagem_apontamentos_saneago.md)
--
-- 7) Modelo de veículo padronizado  (15 grafias -> 3 modelos reais)
-- 8) Limpeza de endereço            (número solto no início + Plus Code do Google)
-- 9) Hierarquia oficial regional -> superintendência (caso Palmeiras)
--
-- PRINCÍPIO: só ADITIVO nas colunas que o Power BI usa como chave/segmentação.
--   - modelo/marca/sup ORIGINAIS ficam intactos; entram colunas NOVAS
--     (marca_padrao, modelo_padrao, sup_oficial) para o BI migrar quando quiser.
--   - endereço É limpo no lugar: é texto de exibição, não chave — e limpá-lo é
--     justamente o que o cliente pediu.
--
-- Rollback: views_backup_2026-08-24.sql (views) + DROP das 3 funções/2 tabelas novas.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- ITEM 7 — MODELO CANÔNICO
-- Tabela de padrões (regex) -> nome oficial. Para incluir/ajustar um modelo,
-- basta INSERT/UPDATE aqui: nenhuma view precisa ser recriada.
-- Nomes canônicos conforme a lista da SANEAGO (pág. 4 do documento).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tb_modelo_canonico (
  id            serial PRIMARY KEY,
  prioridade    int  NOT NULL DEFAULT 100,   -- menor = avaliado primeiro
  padrao        text NOT NULL,               -- regex, case-insensitive, sobre "marca modelo"
  marca_padrao  text NOT NULL,
  modelo_padrao text NOT NULL,
  obs           text
);

TRUNCATE public.tb_modelo_canonico RESTART IDENTITY;
INSERT INTO public.tb_modelo_canonico (prioridade, padrao, marca_padrao, modelo_padrao, obs) VALUES
  (10, 'ARGO',      'FIAT',       'ARGO 1.0',         'cobre ARGO, ARGO 1.0, ARGO DRIVE, ARGO DRIVE 1.0 e o typo FITA'),
  (10, 'SAVEIRO',   'VOLKSWAGEN', 'SAVEIRO ROBUST',   'cobre SAVEIRO CS RB / CS / MF e os typos VOKSWAGEN, VW SAVEIRO. NÃO separa ROBUST-ADAPT: atributo inexistente na Geotab (item 13 da triagem)'),
  (10, 'POLO',      'VOLKSWAGEN', 'POLO CL',          'POLO CL AB'),
  (20, 'VIRTUS',    'VOLKSWAGEN', 'VIRTUS EXCLUSIVE', 'hoje em grupo excluído (OPE - DIRETORIA/GERÊNCIA) — pré-cadastrado p/ caso a Q2 libere'),
  (20, 'COMMANDER', 'JEEP',       'JEEP COMMANDER',   'nenhum registro na base hoje — pré-cadastrado p/ caso apareça'),
  (30, 'ATEGO',     'MERCEDES',   'ATEGO 1419',       'fora do contrato SANEAGO; mantido p/ não virar NULL em outras bases');

CREATE OR REPLACE FUNCTION public.modelo_padrao(p_marca text, p_modelo text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT c.modelo_padrao
    FROM public.tb_modelo_canonico c
   WHERE btrim(COALESCE(p_marca,'') || ' ' || COALESCE(p_modelo,'')) ~* c.padrao
   ORDER BY c.prioridade, c.id
   LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.marca_padrao(p_marca text, p_modelo text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT c.marca_padrao
    FROM public.tb_modelo_canonico c
   WHERE btrim(COALESCE(p_marca,'') || ' ' || COALESCE(p_modelo,'')) ~* c.padrao
   ORDER BY c.prioridade, c.id
   LIMIT 1;
$$;

-- ----------------------------------------------------------------------------
-- ITEM 8 — LIMPEZA DE ENDEREÇO
-- Remove do INÍCIO do texto:
--   (a) Plus Code do Google (ex. "CRXH+M7 - ", "FFQ6+JH, ") — coordenada
--       codificada que o geocodificador devolve quando o ponto não tem
--       endereço formal. 3.296 casos.
--   (b) número de imóvel solto, sem rua (ex. "100 - ", "44, "). 1.121 casos.
-- O resto do texto (bairro, cidade, UF, CEP) é preservado.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.limpar_endereco(p text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT NULLIF(btrim(
           regexp_replace(
             regexp_replace(COALESCE(p, ''), '^[0-9A-Z]{4,}\+[0-9A-Z]+\s*(-|,)\s*', '', 'i'),
             '^[0-9]+\s*(-|,)\s*', '', ''
           )
         ), '');
$$;

-- ----------------------------------------------------------------------------
-- ITEM 9 — HIERARQUIA OFICIAL regional -> superintendência
-- Corrige vínculo errado vindo do cadastro da Geotab. Só entram aqui os casos
-- CONFIRMADOS pela SANEAGO; o resto passa direto (COALESCE devolve o original).
--
-- PENDENTE (não incluído de propósito, falta confirmação):
--   REG_G0341 - GER DESENV TEC OPERACIONAL aparece sob S0071 (2 veículos) e
--   S0060 (1 veículo). Maioria fraca, cliente não citou — NÃO adivinhamos.
--   Para corrigir depois: INSERT nesta tabela, sem recriar view.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.tb_hierarquia_grupo (
  reg         text PRIMARY KEY,
  sup_oficial text NOT NULL,
  obs         text
);

INSERT INTO public.tb_hierarquia_grupo (reg, sup_oficial, obs) VALUES
  ('REG_G0155 - GER.REG.SERV.PALMEIRAS GOIAS',
   'SUP_S0071 - SUPER.REGION. OPER.DO INTERIOR',
   'SANEAGO 12/08/2026: "Palmeiras não pertence à S0062 (SULOG)", "Palmeiras é da S0071". 1 veículo vinha errado sob S0062.')
ON CONFLICT (reg) DO UPDATE
  SET sup_oficial = EXCLUDED.sup_oficial, obs = EXCLUDED.obs;

CREATE OR REPLACE FUNCTION public.sup_oficial(p_reg text, p_sup text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
           (SELECT h.sup_oficial FROM public.tb_hierarquia_grupo h WHERE h.reg = btrim(p_reg)),
           p_sup
         );
$$;

-- ============================================================================
-- VIEWS — só colunas NOVAS (exceto endereço, limpo no lugar)
-- ============================================================================

-- vw_saneago_cadastro: + marca_padrao, modelo_padrao, sup_oficial
CREATE OR REPLACE VIEW vw_saneago_cadastro AS
 SELECT id, serial, placa, veiculo, marca, modelo, ano, tipo_veiculo,
        grupo, todos_grupos, ativo, atualizado_em,
        split_grupo(todos_grupos, 'OPE'::text)  AS operacao,
        split_grupo(todos_grupos, 'SUP'::text)  AS sup,
        split_grupo(todos_grupos, 'REG'::text)  AS reg,
        split_grupo(todos_grupos, 'ULOT'::text) AS ulot,
        split_outros(todos_grupos)              AS outros,
        -- NOVAS (itens 7 e 9):
        marca_padrao(marca, modelo)  AS marca_padrao,
        modelo_padrao(marca, modelo) AS modelo_padrao,
        sup_oficial(split_grupo(todos_grupos, 'REG'::text),
                    split_grupo(todos_grupos, 'SUP'::text)) AS sup_oficial
   FROM tb_cadastro c
  WHERE grupo_visivel(todos_grupos)
    AND placa NOT IN ('TFA2G98', 'TFN3B44', 'TFR4E14');

-- vw_saneago_relatorio_viagens: + modelo_padrao/marca_padrao; endereços LIMPOS
CREATE OR REPLACE VIEW vw_saneago_relatorio_viagens
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
        -- ITEM 8: endereço limpo (tira Plus Code e número solto do início)
        limpar_endereco(ep.endereco) AS end_partida,
        limpar_endereco(ec.endereco) AS end_chegada,
        v.motorista_nome,
        v.motorista_matricula,
        CASE WHEN v.velocidade_media  > 150 THEN 0 ELSE v.velocidade_media  END AS velocidade_media_2,
        CASE WHEN v.velocidade_maxima > 200 THEN 0 ELSE v.velocidade_maxima END AS velo_max_2,
        -- ITEM 7:
        marca_padrao(c.marca, c.modelo)  AS marca_padrao,
        modelo_padrao(c.marca, c.modelo) AS modelo_padrao
   FROM tb_viagens v
     JOIN vw_saneago_cadastro c ON c.id = v.device_id
     LEFT JOIN tb_enderecos ep ON ep.lat = round(v.lat_partida::numeric, 3) AND ep.lon = round(v.lon_partida::numeric, 3)
     LEFT JOIN tb_enderecos ec ON ec.lat = round(v.lat_chegada::numeric, 3) AND ec.lon = round(v.lon_chegada::numeric, 3)
  ORDER BY c.placa, v.data_partida;

-- vw_saneago_resumo_frota_mensal: + marca_padrao, modelo_padrao, sup_oficial
CREATE OR REPLACE VIEW vw_saneago_resumo_frota_mensal
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
        -- NOVAS (itens 7 e 9):
        marca_padrao, modelo_padrao, sup_oficial
   FROM base
  ORDER BY placa, ano, mes;

-- vw_saneago_grupos: + sup_oficial (dimensão de grupos)
CREATE OR REPLACE VIEW vw_saneago_grupos AS
 SELECT DISTINCT todos_grupos,
    arrumar_grupos(todos_grupos) AS todos_grupos_arrumado,
    split_grupo(todos_grupos, 'OPE'::text) AS operacao,
    split_grupo(todos_grupos, 'SUP'::text) AS sup,
    split_grupo(todos_grupos, 'REG'::text) AS reg,
    split_grupo(todos_grupos, 'ULOT'::text) AS ulot,
    split_outros(todos_grupos) AS outros,
    -- NOVA (item 9):
    sup_oficial(split_grupo(todos_grupos, 'REG'::text),
                split_grupo(todos_grupos, 'SUP'::text)) AS sup_oficial
   FROM tb_cadastro c
  WHERE todos_grupos IS NOT NULL
    AND grupo_visivel(todos_grupos)
  ORDER BY todos_grupos;

COMMIT;
