-- ============================================================================
-- Correção: padronizar SOMENTE erros de escrita, preservando modelos distintos
-- Data: 2026-08-26
--
-- ERRO DA VERSÃO ANTERIOR: `tb_modelo_canonico` casava por regex e colapsava
-- TODAS as variantes num nome só (ARGO DRIVE 1.0 / ARGO / ARGO 1.0 / ARGO DRIVE
-- -> "ARGO 1.0"; as 7 grafias de Saveiro -> "SAVEIRO ROBUST"). Isso apagava
-- distinções REAIS de versão do veículo.
--
-- AGORA: de-para explícito por par (marca, modelo). Corrige apenas:
--   * erro de digitação na marca ...... FITA -> FIAT | VOKSWAGEN -> VOLKSWAGEN
--   * caixa inconsistente ............ Fiat -> FIAT | VW Saveiro -> VOLKSWAGEN
--   * marca abreviada ................ VW SAVEIRO -> VOLKSWAGEN
--   * modelo gravado no campo da marca (modelo vazio):
--       "ARGO DRIVE 1.0"   -> marca FIAT,       modelo ARGO DRIVE 1.0
--       "SAVEIRO CS RB MF" -> marca VOLKSWAGEN, modelo SAVEIRO CS RB MF
--       "FIAT/ARGO DRIVE 1.0" -> marca FIAT,    modelo ARGO DRIVE 1.0
--       "VW SAVEIRO"       -> marca VOLKSWAGEN, modelo SAVEIRO
-- O NOME DO MODELO É PRESERVADO como estava. Resultado: 9 modelos distintos
-- (antes da minha alteração indevida eram esses; eu havia reduzido a 3).
--
-- Só as FUNÇÕES mudam — as views chamam marca_padrao()/modelo_padrao() e
-- absorvem a correção sem precisar ser recriadas.
--
-- Par novo que apareça no futuro (veículo novo, grafia nova): sem linha na
-- tabela, o fallback devolve o texto cru em maiúsculas. Basta um INSERT aqui.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS public.tb_veiculo_correcao (
  marca_raw  text NOT NULL,
  modelo_raw text NOT NULL,
  marca_ok   text NOT NULL,
  modelo_ok  text NOT NULL,
  obs        text,
  PRIMARY KEY (marca_raw, modelo_raw)
);

TRUNCATE public.tb_veiculo_correcao;
INSERT INTO public.tb_veiculo_correcao (marca_raw, modelo_raw, marca_ok, modelo_ok, obs) VALUES
  ('VOLKSWAGEN',           'SAVEIRO CS RB',  'VOLKSWAGEN', 'SAVEIRO CS RB',    'ok, sem correção'),
  ('FIAT',                 'ARGO DRIVE 1.0', 'FIAT',       'ARGO DRIVE 1.0',   'ok, sem correção'),
  ('VOLKSWAGEN',           'POLO CL AB',     'VOLKSWAGEN', 'POLO CL AB',       'ok, sem correção'),
  ('VOLKSWAGEN',           'SAVEIRO CS',     'VOLKSWAGEN', 'SAVEIRO CS',       'ok, sem correção'),
  ('FIAT',                 'ARGO DRIVE',     'FIAT',       'ARGO DRIVE',       'ok, sem correção'),
  ('FIAT',                 'ARGO',           'FIAT',       'ARGO',             'ok, sem correção'),
  ('FITA',                 'ARGO DRIVE 1.0', 'FIAT',       'ARGO DRIVE 1.0',   'typo de marca: FITA -> FIAT'),
  ('VOKSWAGEN',            'SAVEIRO',        'VOLKSWAGEN', 'SAVEIRO',          'typo de marca: VOKSWAGEN -> VOLKSWAGEN'),
  ('Fiat',                 'ARGO 1.0',       'FIAT',       'ARGO 1.0',         'caixa da marca'),
  ('VW SAVEIRO',           'SAVEIRO CS RB',  'VOLKSWAGEN', 'SAVEIRO CS RB',    'marca abreviada'),
  ('VW SAVEIRO',           '',               'VOLKSWAGEN', 'SAVEIRO',          'modelo estava no campo da marca'),
  ('VW Saveiro',           '',               'VOLKSWAGEN', 'SAVEIRO',          'modelo no campo da marca + caixa'),
  ('ARGO DRIVE 1.0',       '',               'FIAT',       'ARGO DRIVE 1.0',   'modelo no campo da marca'),
  ('SAVEIRO CS RB MF',     '',               'VOLKSWAGEN', 'SAVEIRO CS RB MF', 'modelo no campo da marca'),
  ('FIAT/ARGO DRIVE 1.0',  '',               'FIAT',       'ARGO DRIVE 1.0',   'marca e modelo juntos no campo da marca');

-- ----------------------------------------------------------------------------
-- Funções: lookup exato pelo par cru; sem linha, devolve o cru em maiúsculas.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.marca_padrao(p_marca text, p_modelo text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    (SELECT c.marca_ok FROM public.tb_veiculo_correcao c
      WHERE c.marca_raw  = COALESCE(p_marca, '')
        AND c.modelo_raw = COALESCE(p_modelo, '')),
    NULLIF(btrim(upper(COALESCE(p_marca, ''))), '')
  );
$$;

CREATE OR REPLACE FUNCTION public.modelo_padrao(p_marca text, p_modelo text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT COALESCE(
    (SELECT c.modelo_ok FROM public.tb_veiculo_correcao c
      WHERE c.marca_raw  = COALESCE(p_marca, '')
        AND c.modelo_raw = COALESCE(p_modelo, '')),
    NULLIF(btrim(upper(COALESCE(p_modelo, ''))), '')
  );
$$;

-- tb_modelo_canonico ficou obsoleta (era o casamento por regex que colapsava).
-- NÃO dropada aqui: o DROP exige lock exclusivo e trava enquanto houver refresh
-- do Power BI lendo as views. Não é usada por nada; remover depois com:
--   DROP TABLE IF EXISTS public.tb_modelo_canonico;

COMMIT;
