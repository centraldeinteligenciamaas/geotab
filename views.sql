-- Views do projeto Geotab (geradas do banco em 2026-08-26)
-- ============================================================================
-- HIERARQUIA DE GRUPOS — níveis repetidos são zerados (2026-08-26)
--   No cadastro da Geotab a MESMA unidade aparece sob vários prefixos, ex.:
--     REG_S0021 - SUPERIN. DE ESTUDOS E PROJETOS |
--     ULOT_S0021 - SUPERIN. DE ESTUDOS E PROJETOS |
--     SUP_S0021 - SUPERIN. DE ESTUDOS E PROJETOS
--   Efeito: a coluna "regional" exibia SUPERINTENDÊNCIA; a de lotação exibia
--   sup ou reg. split_grupo() estava CERTO (pegava o token REG_/ULOT_); o token
--   é que carrega o conteúdo do nível de cima. Mesmo sintoma do caso Palmeiras.
--   REGRA: nível que só REPETE o código do nível acima vira NULL.
--     regional -> NULL se reg_codigo  = sup_codigo
--     lotação  -> NULL se ulot_codigo = sup_codigo OU = reg_codigo
--   Antes: 50 grupos c/ regional repetida (24 veículos) e 335 c/ lotação
--   repetida (208 veículos). Depois: 0. Hierarquias reais preservadas
--   (ex. S0021 -> G0123 -> V0123). Texto cru auditável em todos_grupos_original.
--   RESSALVA: 2 grupos têm SÓ um token ULOT_ com código de superintendência
--   (ULOT_S0086, ULOT_S0090) e NADA acima — não é repetição, é a sup cadastrada
--   no campo de lotação. MANTIDOS: zerar apagaria a única informação de grupo
--   desses veículos. Corrigir isso é no cadastro da Geotab.
--
-- MARCA / MODELO — corrigir SÓ erro de escrita, PRESERVANDO modelos distintos.
--   De-para por par (marca, modelo) em `tb_veiculo_correcao` (15 linhas).
--   9 modelos distintos. NÃO colapsar: ARGO / ARGO 1.0 / ARGO DRIVE /
--   ARGO DRIVE 1.0 são versões DIFERENTES. Divergimos de propósito da sugestão
--   da SANEAGO (pág. 4 pedia nomes canônicos) — decisão do usuário.
--   PENDÊNCIA: tb_modelo_canonico segue no banco (obsoleta). DROP trava com
--   refresh do BI ativo — rodar depois.
--
-- REGRA DO USUÁRIO: TODAS as 9 views expõem `todos_grupos` (tratado).
--   NÃO remover de nenhuma. `grupo_id` (int) fica ao lado como chave leve
--   OPCIONAL. 1.721 grupos -> 1.721 ids, 0 colisão, 0 órfãos.
--
-- COLUNAS DE EXIBIÇÃO
--   `veiculo` = concat_ws(' | ', placa, marca_padrao, modelo_padrao), nas 5
--      views que têm placa.
--   `motorista_nome_completo` (3ª col.) em viagens e status — motorista_nome
--      guarda o LOGIN; o nome vem de tb_motoristas via motorista_id (100%).
--
-- PERFORMANCE DA VIAGENS (5,3M linhas / ~2,5 GB)
--   SEM ORDER BY (crítico): custava 88 s p/ ler 200 mil linhas e derrubava a
--   conexão do BI ("Exception while reading from stream"). Depois: 0,77 s.
--   NÃO reintroduzir (idem motoristas). No M: remover Table.AddIndexColumn
--   (bufferiza a tabela toda) e definir CommandTimeout.
--
-- COLUNAS DE GRUPO: só vw_saneago_grupos tem a quebra por nível. UNIÃO de
--   veículos E motoristas (sem os motoristas, 81% ficariam órfãos).
--   ARMADILHA: NUNCA transformar todos_grupos/grupo_id nas tabelas de FATO.
--
-- HISTÓRICO  2026-08-24 rename + grupo_visivel | 2026-08-25 itens_7a9,
--   grupos_tratados, grupos_motoristas, todos_grupos_limpo, grupos_organizados,
--   remove_lotacao, perf_e_compat | 2026-08-26 grupo_id, veiculo_e_motorista,
--   modelo_so_typos, restauro de todos_grupos, niveis_repetidos
--   Backups: views_backup_2026-08-24.sql
-- TABELAS DE APOIO: tb_veiculo_correcao, tb_hierarquia_grupo,
--   tb_grupo_nome_excecao, tb_grupo_token_ignorado
-- ============================================================================

-- ============================================================
-- Funções auxiliares
-- ============================================================
CREATE OR REPLACE FUNCTION public.grupo_visivel(p_todos text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
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
$function$
;

CREATE OR REPLACE FUNCTION public.split_grupo(p_todos text, p_prefixo text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT trim(tok)
    FROM unnest(string_to_array(p_todos, '|')) AS tok
    WHERE trim(tok) LIKE p_prefixo || '\_%'
    LIMIT 1;
$function$
;

CREATE OR REPLACE FUNCTION public.split_outros(p_todos text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT NULLIF(string_agg(trim(tok), ' | '), '')
    FROM unnest(string_to_array(p_todos, '|')) AS tok
    WHERE trim(tok) <> ''
      AND trim(tok) NOT LIKE 'OPE\_%'
      AND trim(tok) NOT LIKE 'SUP\_%'
      AND trim(tok) NOT LIKE 'REG\_%'
      AND trim(tok) NOT LIKE 'ULOT\_%'
      AND trim(tok) NOT IN (
          'Vehicle', 'Diesel', 'Ethanol', 'Gasoline or Petrol',
          'Hybrid', 'Electric', 'Manually Classified Powertrain'
      );
$function$
;

CREATE OR REPLACE FUNCTION public.arrumar_grupos(p_todos text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
    SELECT NULLIF(string_agg(tok, ' | ' ORDER BY ord), '')
    FROM (
        SELECT btrim(t.tok) AS tok, t.ord
        FROM unnest(string_to_array(p_todos, '|')) WITH ORDINALITY AS t(tok, ord)
    ) s
    WHERE s.tok <> ''
      AND NOT EXISTS (SELECT 1 FROM public.tb_grupo_token_ignorado i WHERE i.token = s.tok);
$function$
;

CREATE OR REPLACE FUNCTION public.modelo_padrao(p_marca text, p_modelo text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
    (SELECT c.modelo_ok FROM public.tb_veiculo_correcao c
      WHERE c.marca_raw  = COALESCE(p_marca, '')
        AND c.modelo_raw = COALESCE(p_modelo, '')),
    NULLIF(btrim(upper(COALESCE(p_modelo, ''))), '')
  );
$function$
;

CREATE OR REPLACE FUNCTION public.marca_padrao(p_marca text, p_modelo text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
    (SELECT c.marca_ok FROM public.tb_veiculo_correcao c
      WHERE c.marca_raw  = COALESCE(p_marca, '')
        AND c.modelo_raw = COALESCE(p_modelo, '')),
    NULLIF(btrim(upper(COALESCE(p_marca, ''))), '')
  );
$function$
;

CREATE OR REPLACE FUNCTION public.limpar_endereco(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT NULLIF(btrim(
           regexp_replace(
             regexp_replace(COALESCE(p, ''), '^[0-9A-Z]{4,}\+[0-9A-Z]+\s*[-,]?\s*', ''),
             '^[0-9]+(-[0-9]+)*\s*[-,]\s*', ''
           )
         ), '');
$function$
;

CREATE OR REPLACE FUNCTION public.sup_oficial(p_reg text, p_sup text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
           (SELECT h.sup_oficial FROM public.tb_hierarquia_grupo h WHERE h.reg = btrim(p_reg)),
           p_sup
         );
$function$
;

CREATE OR REPLACE FUNCTION public.grupo_codigo(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT NULLIF(btrim(COALESCE(
    (regexp_match(COALESCE(p, ''), '^[A-Za-z]+\s*_\s*([^-\s]+)'))[1], '')), '');
$function$
;

CREATE OR REPLACE FUNCTION public.grupo_nome(p text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT COALESCE(
    (SELECT e.nome_exibicao FROM public.tb_grupo_nome_excecao e
      WHERE e.codigo = grupo_codigo(p)),
    NULLIF(initcap(btrim(COALESCE(
      (regexp_match(COALESCE(p, ''), '^[A-Za-z]+\s*_\s*[^-\s]+\s*-\s*(.*)$'))[1], ''))), ''),
    NULLIF(initcap(btrim(COALESCE(p, ''))), '')
  );
$function$
;

CREATE OR REPLACE FUNCTION public.grupo_cod_nome(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT NULLIF(concat_ws(' - ', grupo_codigo(p), grupo_nome(p)), '');
$function$
;

-- ============================================================
-- vw_saneago_cadastro
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_cadastro AS
 SELECT id,
    serial,
    placa,
    concat_ws(' | '::text, placa, marca_padrao(marca, modelo), modelo_padrao(marca, modelo)) AS veiculo,
    marca,
    modelo,
    ano,
    tipo_veiculo,
    arrumar_grupos(todos_grupos) AS todos_grupos,
    hashtext(arrumar_grupos(todos_grupos)) AS grupo_id,
    ativo,
    atualizado_em,
    marca_padrao(marca, modelo) AS marca_padrao,
    modelo_padrao(marca, modelo) AS modelo_padrao
   FROM tb_cadastro c
  WHERE grupo_visivel(todos_grupos) AND (placa <> ALL (ARRAY['TFA2G98'::text, 'TFN3B44'::text, 'TFR4E14'::text]));
;

-- ============================================================
-- vw_saneago_status
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_status AS
 SELECT s.id,
    s.serial,
    s.placa,
    c.veiculo,
    s.comunicando,
    s.ultimo_contato,
    s.latitude,
    s.longitude,
    s.velocidade,
    s.ignicao_ligada,
    s.motorista_nome,
    mo.nome_completo AS motorista_nome_completo,
    s.motorista_email,
    s.motorista_tel,
    s.viagem_inicio,
    s.snapshot_em,
    s.viagem_fim,
    c.todos_grupos,
    c.grupo_id
   FROM tb_status s
     JOIN vw_saneago_cadastro c ON c.id = s.id
     LEFT JOIN tb_motoristas mo ON mo.nome = s.motorista_nome;
;

-- ============================================================
-- vw_saneago_comportamento
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_comportamento AS
 SELECT e.device_id AS id,
    c.serial,
    c.placa,
    c.veiculo,
    c.todos_grupos,
    c.grupo_id,
    e.dia AS data,
    EXTRACT(year FROM e.dia)::integer AS ano,
    EXTRACT(month FROM e.dia)::integer AS mes,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'excesso_velocidade'::text), 0::bigint) AS excessos_velocidade,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'aceleracao_brusca'::text), 0::bigint) AS aceleracoes_bruscas,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'frenagem_brusca'::text), 0::bigint) AS frenagens_bruscas,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'curva_drastica'::text), 0::bigint) AS curvas_drasticas,
    COALESCE(sum(e.qtd), 0::bigint) AS total_eventos,
    COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'excesso_velocidade'::text), 0::bigint) * 3 + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'aceleracao_brusca'::text), 0::bigint) * 2 + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'frenagem_brusca'::text), 0::bigint) * 2 + COALESCE(sum(e.qtd) FILTER (WHERE e.tipo = 'curva_drastica'::text), 0::bigint) * 1 AS score_risco,
    o.odometro,
    o.odometro_gps
   FROM tb_comportamento_eventos e
     JOIN vw_saneago_cadastro c ON c.id = e.device_id
     LEFT JOIN tb_odometro_dia o ON o.device_id = e.device_id AND o.dia = e.dia
  GROUP BY e.device_id, c.serial, c.placa, c.veiculo, c.todos_grupos, c.grupo_id, e.dia, o.odometro, o.odometro_gps;
;

-- ============================================================
-- vw_saneago_relatorio_viagens
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_relatorio_viagens AS
 SELECT c.placa,
    c.veiculo,
    c.todos_grupos,
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
    v.motorista_nome,
    mo.nome_completo AS motorista_nome_completo,
    v.motorista_matricula,
        CASE
            WHEN v.velocidade_media > 150::double precision THEN 0::double precision
            ELSE v.velocidade_media
        END AS velocidade_media_2,
        CASE
            WHEN v.velocidade_maxima > 200::double precision THEN 0::double precision
            ELSE v.velocidade_maxima
        END AS velo_max_2,
    c.marca_padrao,
    c.modelo_padrao
   FROM tb_viagens v
     JOIN vw_saneago_cadastro c ON c.id = v.device_id
     LEFT JOIN tb_motoristas mo ON mo.id = v.motorista_id
     LEFT JOIN tb_enderecos ep ON ep.lat = round(v.lat_partida::numeric, 3) AND ep.lon = round(v.lon_partida::numeric, 3)
     LEFT JOIN tb_enderecos ec ON ec.lat = round(v.lat_chegada::numeric, 3) AND ec.lon = round(v.lon_chegada::numeric, 3);
;

-- ============================================================
-- vw_saneago_resumo_frota_mensal
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_resumo_frota_mensal AS
 WITH base AS (
         SELECT r.device_id,
            r.ano,
            r.mes,
            r.km,
            r.duracao_segundos,
            r.dias_utilizados,
            r.viagens,
            c.placa,
            c.veiculo,
            c.marca,
            c.modelo,
            c.todos_grupos,
            c.grupo_id,
            c.marca_padrao,
            c.modelo_padrao,
            LEAST((date_trunc('month'::text, make_date(r.ano, r.mes, 1)::timestamp with time zone) + '1 mon'::interval - '1 day'::interval)::date, CURRENT_DATE) - date_trunc('month'::text, make_date(r.ano, r.mes, 1)::timestamp with time zone)::date + 1 AS dias_no_periodo
           FROM tb_resumo_mensal r
             JOIN vw_saneago_cadastro c ON c.id = r.device_id
          WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE
        )
 SELECT placa,
    veiculo,
    marca,
    modelo,
    todos_grupos,
    grupo_id,
    ano,
    mes,
    to_char(make_date(ano, mes, 1)::timestamp with time zone, 'YYYY-MM'::text) AS ano_mes,
    dias_no_periodo,
    dias_utilizados,
    round(km::numeric, 1) AS km_rodado,
    round((km / NULLIF(dias_utilizados, 0)::double precision)::numeric, 1) AS media_km_dia,
    round(duracao_segundos::numeric / 3600.0, 1) AS tempo_movimento_h,
    round(LEAST(dias_utilizados, dias_no_periodo)::numeric / NULLIF(dias_no_periodo, 0)::numeric * 100::numeric, 0) AS taxa_utilizacao_pct,
    viagens,
        CASE
            WHEN modelo IS NULL OR modelo = ''::text THEN marca
            ELSE modelo
        END AS modelo2,
    marca_padrao,
    modelo_padrao
   FROM base
  ORDER BY placa, ano, mes;
;

-- ============================================================
-- vw_saneago_indicadores_mensal
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_indicadores_mensal AS
 WITH base AS (
         SELECT r.device_id,
            r.ano,
            r.mes,
            r.km,
            r.duracao_segundos,
            r.dias_utilizados,
            c.todos_grupos,
            c.grupo_id,
            LEAST((date_trunc('month'::text, make_date(r.ano, r.mes, 1)::timestamp with time zone) + '1 mon'::interval - '1 day'::interval)::date, CURRENT_DATE) - date_trunc('month'::text, make_date(r.ano, r.mes, 1)::timestamp with time zone)::date + 1 AS dias_no_periodo
           FROM tb_resumo_mensal r
             JOIN vw_saneago_cadastro c ON c.id = r.device_id
          WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE
        )
 SELECT todos_grupos,
    grupo_id,
    ano,
    mes,
    to_char(make_date(ano, mes, 1)::timestamp with time zone, 'YYYY-MM'::text) AS ano_mes,
    count(*) AS qtd_veiculos,
    round(sum(km)::numeric, 0) AS km_total,
    round((sum(km) / NULLIF(count(*), 0)::double precision)::numeric, 0) AS media_km_veiculo,
    round(sum(duracao_segundos) / 3600.0, 0) AS tempo_movimento_h,
    round(avg(LEAST(dias_utilizados, dias_no_periodo)::numeric / NULLIF(dias_no_periodo, 0)::numeric * 100::numeric), 0) AS taxa_media_utilizacao_pct
   FROM base
  GROUP BY todos_grupos, grupo_id, ano, mes
  ORDER BY todos_grupos, ano, mes;
;

-- ============================================================
-- vw_saneago_motoristas
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_motoristas AS
 WITH viagens_dia AS (
         SELECT v.motorista_id,
            v.data_partida::date AS dia,
            count(*) AS viagens,
            count(DISTINCT v.device_id) AS qtd_veiculos,
            string_agg(DISTINCT c.placa, ', '::text ORDER BY c.placa) AS veiculos,
            round(sum(v.distancia_km)::numeric, 1) AS km,
            round(sum(v.duracao_segundos)::numeric / 3600.0, 1) AS horas_movimento,
            round(sum(v.tempo_ocioso_segundos)::numeric / 3600.0, 1) AS horas_ocioso,
            round(sum(v.duracao_parada_segundos)::numeric / 3600.0, 1) AS horas_parado
           FROM tb_viagens v
             LEFT JOIN tb_cadastro c ON c.id = v.device_id
          WHERE v.motorista_id <> ''::text AND (v.motorista_nome <> ALL (ARRAY['Nenhum'::text, 'Desconhecido'::text, ''::text]))
          GROUP BY v.motorista_id, (v.data_partida::date)
        ), eventos_dia AS (
         SELECT tb_comportamento_motorista.motorista_id,
            tb_comportamento_motorista.dia,
            COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'excesso_velocidade'::text), 0::bigint) AS excessos_velocidade,
            COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'aceleracao_brusca'::text), 0::bigint) AS aceleracoes_bruscas,
            COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'frenagem_brusca'::text), 0::bigint) AS frenagens_bruscas,
            COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'curva_drastica'::text), 0::bigint) AS curvas_drasticas,
            COALESCE(sum(tb_comportamento_motorista.qtd), 0::bigint) AS total_eventos
           FROM tb_comportamento_motorista
          GROUP BY tb_comportamento_motorista.motorista_id, tb_comportamento_motorista.dia
        )
 SELECT m.nome AS motorista_nome,
    m.nome_completo AS motorista_nome_completo,
    m.matricula AS motorista_matricula,
    arrumar_grupos(m.todos_grupos) AS todos_grupos,
    hashtext(arrumar_grupos(m.todos_grupos)) AS grupo_id,
    COALESCE(vd.dia, ed.dia) AS data,
    EXTRACT(year FROM COALESCE(vd.dia, ed.dia))::integer AS ano,
    EXTRACT(month FROM COALESCE(vd.dia, ed.dia))::integer AS mes,
    vd.qtd_veiculos,
    vd.veiculos,
    vd.viagens,
    vd.km,
    vd.horas_movimento,
    vd.horas_ocioso,
    vd.horas_parado,
    COALESCE(ed.excessos_velocidade, 0::bigint) AS excessos_velocidade,
    COALESCE(ed.aceleracoes_bruscas, 0::bigint) AS aceleracoes_bruscas,
    COALESCE(ed.frenagens_bruscas, 0::bigint) AS frenagens_bruscas,
    COALESCE(ed.curvas_drasticas, 0::bigint) AS curvas_drasticas,
    COALESCE(ed.total_eventos, 0::bigint) AS total_eventos,
    COALESCE(ed.excessos_velocidade, 0::bigint) * 3 + COALESCE(ed.aceleracoes_bruscas, 0::bigint) * 2 + COALESCE(ed.frenagens_bruscas, 0::bigint) * 2 + COALESCE(ed.curvas_drasticas, 0::bigint) * 1 AS score_risco
   FROM viagens_dia vd
     FULL JOIN eventos_dia ed ON ed.motorista_id = vd.motorista_id AND ed.dia = vd.dia
     LEFT JOIN tb_motoristas m ON m.id = COALESCE(vd.motorista_id, ed.motorista_id)
  WHERE grupo_visivel(m.todos_grupos);
;

-- ============================================================
-- vw_saneago_motoristas_anual
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_motoristas_anual AS
 WITH viagens_mot AS (
         SELECT v.motorista_id,
            max(v.motorista_nome) AS motorista_nome,
            max(v.motorista_matricula) AS motorista_matricula,
            count(*) AS viagens,
            count(DISTINCT v.device_id) AS qtd_veiculos,
            string_agg(DISTINCT c.placa, ', '::text ORDER BY c.placa) AS veiculos,
            round(sum(v.distancia_km)::numeric, 1) AS km_total,
            round(sum(v.duracao_segundos)::numeric / 3600.0, 1) AS horas_movimento,
            round(sum(v.tempo_ocioso_segundos)::numeric / 3600.0, 1) AS horas_ocioso,
            round(sum(v.duracao_parada_segundos)::numeric / 3600.0, 1) AS horas_parado
           FROM tb_viagens v
             LEFT JOIN tb_cadastro c ON c.id = v.device_id
          WHERE v.motorista_id <> ''::text AND (v.motorista_nome <> ALL (ARRAY['Nenhum'::text, 'Desconhecido'::text, ''::text]))
          GROUP BY v.motorista_id
        ), eventos_mot AS (
         SELECT tb_comportamento_motorista.motorista_id,
            COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'excesso_velocidade'::text), 0::bigint) AS excesso_velocidade,
            COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'aceleracao_brusca'::text), 0::bigint) AS aceleracao_brusca,
            COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'frenagem_brusca'::text), 0::bigint) AS frenagem_brusca,
            COALESCE(sum(tb_comportamento_motorista.qtd) FILTER (WHERE tb_comportamento_motorista.tipo = 'curva_drastica'::text), 0::bigint) AS curva_drastica,
            COALESCE(sum(tb_comportamento_motorista.qtd), 0::bigint) AS total_eventos
           FROM tb_comportamento_motorista
          GROUP BY tb_comportamento_motorista.motorista_id
        )
 SELECT vm.motorista_nome,
    m.nome_completo AS motorista_nome_completo,
    vm.motorista_matricula,
    arrumar_grupos(m.todos_grupos) AS todos_grupos,
    hashtext(arrumar_grupos(m.todos_grupos)) AS grupo_id,
    vm.qtd_veiculos,
    vm.veiculos,
    vm.viagens,
    vm.km_total,
    vm.horas_movimento,
    vm.horas_ocioso,
    vm.horas_parado,
    COALESCE(em.excesso_velocidade, 0::bigint) AS excesso_velocidade,
    COALESCE(em.aceleracao_brusca, 0::bigint) AS aceleracao_brusca,
    COALESCE(em.frenagem_brusca, 0::bigint) AS frenagem_brusca,
    COALESCE(em.curva_drastica, 0::bigint) AS curva_drastica,
    COALESCE(em.total_eventos, 0::bigint) AS total_eventos,
        CASE
            WHEN vm.km_total >= 1::numeric THEN round((GREATEST(0::numeric, 100::numeric - COALESCE(em.excesso_velocidade, 0::bigint)::numeric * 1000.0 / vm.km_total) + GREATEST(0::numeric, 100::numeric - COALESCE(em.aceleracao_brusca, 0::bigint)::numeric * 1000.0 / vm.km_total) + GREATEST(0::numeric, 100::numeric - COALESCE(em.frenagem_brusca, 0::bigint)::numeric * 1000.0 / vm.km_total) + GREATEST(0::numeric, 100::numeric - COALESCE(em.curva_drastica, 0::bigint)::numeric * 1000.0 / vm.km_total)) / 4.0, 1)
            ELSE NULL::numeric
        END AS score_seguranca
   FROM viagens_mot vm
     LEFT JOIN eventos_mot em ON em.motorista_id = vm.motorista_id
     LEFT JOIN tb_motoristas m ON m.id = vm.motorista_id
  WHERE grupo_visivel(m.todos_grupos);
;

-- ============================================================
-- vw_saneago_grupos
-- ============================================================
CREATE OR REPLACE VIEW vw_saneago_grupos AS
 WITH combos AS (
         SELECT tb_cadastro.todos_grupos
           FROM tb_cadastro
          WHERE tb_cadastro.todos_grupos IS NOT NULL AND grupo_visivel(tb_cadastro.todos_grupos)
        UNION
         SELECT tb_motoristas.todos_grupos
           FROM tb_motoristas
          WHERE tb_motoristas.todos_grupos IS NOT NULL AND grupo_visivel(tb_motoristas.todos_grupos)
        ), base AS (
         SELECT combos.todos_grupos AS orig,
            arrumar_grupos(combos.todos_grupos) AS tg,
            split_grupo(combos.todos_grupos, 'OPE'::text) AS ope_bruto,
            split_outros(combos.todos_grupos) AS outros,
            split_grupo(combos.todos_grupos, 'REG'::text) AS reg_bruto,
            split_grupo(combos.todos_grupos, 'ULOT'::text) AS ulot_bruto,
            sup_oficial(split_grupo(combos.todos_grupos, 'REG'::text), split_grupo(combos.todos_grupos, 'SUP'::text)) AS sup_bruto
           FROM combos
        ), agrupado AS (
         SELECT base.tg AS todos_grupos,
            min(base.orig) AS todos_grupos_original,
            min(base.sup_bruto) AS sup_bruto,
            min(base.reg_bruto) AS reg_bruto,
            min(base.ulot_bruto) AS ulot_bruto,
            min(base.ope_bruto) AS ope_bruto,
            min(base.outros) AS outros
           FROM base
          WHERE base.tg IS NOT NULL
          GROUP BY base.tg
        ), codigos AS (
         SELECT a.todos_grupos,
            a.todos_grupos_original,
            a.sup_bruto,
            a.reg_bruto,
            a.ulot_bruto,
            a.ope_bruto,
            a.outros,
            grupo_codigo(a.sup_bruto) AS c_sup,
            grupo_codigo(a.reg_bruto) AS c_reg,
            grupo_codigo(a.ulot_bruto) AS c_ulot
           FROM agrupado a
        ), limpo AS (
         SELECT c.todos_grupos,
            c.todos_grupos_original,
            c.sup_bruto,
            c.reg_bruto,
            c.ulot_bruto,
            c.ope_bruto,
            c.outros,
            c.c_sup,
            c.c_reg,
            c.c_ulot,
                CASE
                    WHEN c.c_reg IS NOT NULL AND c.c_reg = c.c_sup THEN NULL::text
                    ELSE c.reg_bruto
                END AS reg_ok,
                CASE
                    WHEN c.c_ulot IS NOT NULL AND (c.c_ulot = c.c_sup OR c.c_ulot = c.c_reg) THEN NULL::text
                    ELSE c.ulot_bruto
                END AS ulot_ok
           FROM codigos c
        )
 SELECT hashtext(todos_grupos) AS grupo_id,
    todos_grupos_original,
    todos_grupos,
    ope_bruto AS operacao,
    grupo_codigo(ope_bruto) AS ope_codigo,
    grupo_nome(ope_bruto) AS ope_nome,
    grupo_cod_nome(ope_bruto) AS ope_cod_nome,
    grupo_codigo(sup_bruto) AS sup_codigo,
    grupo_nome(sup_bruto) AS sup_nome,
    grupo_cod_nome(sup_bruto) AS sup_cod_nome,
    grupo_codigo(reg_ok) AS reg_codigo,
    grupo_nome(reg_ok) AS reg_nome,
    grupo_cod_nome(reg_ok) AS reg_cod_nome,
    grupo_codigo(ulot_ok) AS ulot_codigo,
    grupo_nome(ulot_ok) AS ulot_nome,
    grupo_cod_nome(ulot_ok) AS ulot_cod_nome,
    outros,
    grupo_nome(outros) AS outros_nome
   FROM limpo
  ORDER BY todos_grupos;
;

