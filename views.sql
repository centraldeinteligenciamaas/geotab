-- Views do projeto Geotab -> Supabase (geradas do banco)
-- Coluna todos_grupos adicionada em status, comportamento, resumo_frota e indicadores.
-- Em vw_indicadores_produtividade o agrupamento passou a ser por todos_grupos.
--
-- Períodos de cada view (todas expõem datas):
--   vw_cadastro                  snapshot atual           (atualizado_em)
--   vw_status                    tempo real / snapshot     (snapshot_em, ultimo_contato)
--   vw_comportamento             últimos 6 meses           (periodo_ini, periodo_fim)
--   vw_relatorio_viagens         ano corrente (por viagem) (data_partida, data_chegada, atualizado_em)
--   vw_resumo_frota              ano corrente              (data_ini, data_fim)
--   vw_indicadores_produtividade ano corrente              (data_ini, data_fim)

-- ============================================================
-- vw_cadastro
-- ============================================================
CREATE OR REPLACE VIEW vw_cadastro AS
 SELECT id,
    serial,
    placa,
    veiculo,
    marca,
    modelo,
    ano,
    tipo_veiculo,
    grupo,
    todos_grupos,
    ativo,
    atualizado_em
   FROM tb_cadastro
  WHERE todos_grupos !~~ '%OPE_SEINFRA%'::text AND todos_grupos !~~ '%OPE_COMURG%'::text AND todos_grupos !~~ '%P-CSB%'::text AND todos_grupos !~~ '%OPE_CS_BRASIL%'::text AND todos_grupos !~~ '%OPE_PEDREIRA%'::text AND todos_grupos !~~ '%OPE_SECRET. DA ECONOMIA - 018/2025%'::text AND todos_grupos !~~ '%OPE_SEPLANH%'::text AND todos_grupos !~~ '%OPE_SMT%'::text AND todos_grupos !~~ '%OPE - ADMINISTRATIVO%'::text AND todos_grupos !~~ '%OPE - ASSISTENCIA SOCIAL%'::text AND todos_grupos !~~ '%OPE - DIRETORIA/GERENCIA%'::text AND todos_grupos !~~ '%OPE - RECOLHIMENTO DE ANIMAIS%'::text AND todos_grupos !~~ '%OPE - SERVIÇOS EM CAMPO%'::text AND todos_grupos !~~ '%OPE_AGETUL%'::text AND todos_grupos !~~ '%OPE_AMMA%'::text AND todos_grupos !~~ '%OPE_SEMAD - 006/2020%'::text AND todos_grupos !~~ '%OPE - DIRETORIA/GERÊNCIA%'::text AND todos_grupos !~~ '%OPE_SECULT%'::text AND (grupo <> ALL (ARRAY['OPE - ADMINISTRATIVO'::text, 'OPE - ASSISTENCIA SOCIAL'::text, 'OPE - DIRETORIA/GERÊNCIA'::text, 'OPE - DIRETORIA/GERENCIA'::text, 'OPE - RECOLHIMENTO DE ANIMAIS'::text, 'OPE - SERVIÇOS EM CAMPO'::text, 'OPE_AGETUL'::text, 'OPE_AMMA'::text, 'OPE_SEMAD'::text, 'OPE_SEMAD - 006/2020'::text, 'REDEMOB CONSÓRCIO - 008/2025'::text]));

-- ============================================================
-- vw_status
-- ============================================================
CREATE OR REPLACE VIEW vw_status AS
 SELECT s.id,
    s.serial,
    s.placa,
    s.comunicando,
    s.ultimo_contato,
    s.latitude,
    s.longitude,
    s.velocidade,
    s.ignicao_ligada,
    s.motorista_nome,
    s.motorista_email,
    s.motorista_tel,
    s.viagem_inicio,
    s.snapshot_em,
    s.viagem_fim,
    s.todos_grupos
   FROM tb_status s
     JOIN vw_cadastro c ON c.id = s.id
  WHERE c.todos_grupos !~~ '%OPE_COMURG%'::text AND c.todos_grupos !~~ '%P-CSB%'::text AND c.todos_grupos !~~ '%OPE_CS_BRASIL%'::text AND c.todos_grupos !~~ '%OPE_PEDREIRA%'::text AND c.todos_grupos !~~ '%OPE_SECRET. DA ECONOMIA - 018/2025%'::text AND c.todos_grupos !~~ '%OPE_SEPLANH%'::text AND c.todos_grupos !~~ '%OPE_SMT%'::text AND c.todos_grupos !~~ '%OPE - ADMINISTRATIVO%'::text AND c.todos_grupos !~~ '%OPE - ASSISTENCIA SOCIAL%'::text AND c.todos_grupos !~~ '%OPE - ASSISTÊNCIA SOCIAL%'::text AND c.todos_grupos !~~ '%OPE - DIRETORIA/GERENCIA%'::text AND c.todos_grupos !~~ '%OPE - RECOLHIMENTO DE ANIMAIS%'::text AND c.todos_grupos !~~ '%OPE - SERVIÇOS EM CAMPO%'::text AND c.todos_grupos !~~ '%OPE_AGETUL%'::text AND c.todos_grupos !~~ '%OPE_AMMA%'::text AND c.todos_grupos !~~ '%OPE_SEMAD - 006/2020%'::text AND c.todos_grupos !~~ '%OPE - DIRETORIA/GERÊNCIA%'::text AND c.todos_grupos !~~ '%OPE_SECULT%'::text AND (c.grupo <> ALL (ARRAY['OPE - ADMINISTRATIVO'::text, 'OPE - ASSISTENCIA SOCIAL'::text, 'OPE - ASSISTÊNCIA SOCIAL'::text, 'OPE - DIRETORIA/GERÊNCIA'::text, 'OPE - DIRETORIA/GERENCIA'::text, 'OPE - RECOLHIMENTO DE ANIMAIS'::text, 'OPE - SERVIÇOS EM CAMPO'::text, 'OPE_AGETUL'::text, 'OPE_AMMA'::text, 'OPE_SEMAD'::text, 'OPE_SEMAD - 006/2020'::text, 'REDEMOB CONSÓRCIO - 008/2025'::text]));

-- ============================================================
-- vw_comportamento
-- ============================================================
CREATE OR REPLACE VIEW vw_comportamento AS
 SELECT cmp.id,
    cmp.serial,
    cmp.placa,
    cmp.excessos_velocidade_6m,
    cmp.aceleracoes_bruscas_6m,
    cmp.frenagens_bruscas_6m,
    cmp.curvas_drasticas_6m,
    cmp.ultimo_excesso_vel,
    cmp.ultima_acel_brusca,
    cmp.ultima_fren_brusca,
    cmp.ultima_curva_drastica,
    cmp.score_risco,
    cmp.odometro,
    cmp.atualizado_em,
    -- Janela dos contadores *_6m: 6 meses até o momento da extração.
    (cmp.atualizado_em - '6 mons'::interval) AS periodo_ini,
    cmp.atualizado_em AS periodo_fim,
    cmp.odometro_gps,
    cmp.todos_grupos
   FROM tb_comportamento cmp
     JOIN vw_cadastro c ON c.id = cmp.id
  WHERE c.todos_grupos !~~ '%OPE_COMURG%'::text AND c.todos_grupos !~~ '%P-CSB%'::text AND c.todos_grupos !~~ '%OPE_CS_BRASIL%'::text AND c.todos_grupos !~~ '%OPE_PEDREIRA%'::text AND c.todos_grupos !~~ '%OPE_SECRET. DA ECONOMIA - 018/2025%'::text AND c.todos_grupos !~~ '%OPE_SEPLANH%'::text AND c.todos_grupos !~~ '%OPE_SMT%'::text AND c.todos_grupos !~~ '%OPE - ADMINISTRATIVO%'::text AND c.todos_grupos !~~ '%OPE - ASSISTENCIA SOCIAL%'::text AND c.todos_grupos !~~ '%OPE - ASSISTÊNCIA SOCIAL%'::text AND c.todos_grupos !~~ '%OPE - DIRETORIA/GERENCIA%'::text AND c.todos_grupos !~~ '%OPE - RECOLHIMENTO DE ANIMAIS%'::text AND c.todos_grupos !~~ '%OPE - SERVIÇOS EM CAMPO%'::text AND c.todos_grupos !~~ '%OPE_AGETUL%'::text AND c.todos_grupos !~~ '%OPE_AMMA%'::text AND c.todos_grupos !~~ '%OPE_SEMAD - 006/2020%'::text AND c.todos_grupos !~~ '%OPE - DIRETORIA/GERÊNCIA%'::text AND c.todos_grupos !~~ '%OPE_SECULT%'::text AND (c.grupo <> ALL (ARRAY['OPE - ADMINISTRATIVO'::text, 'OPE - ASSISTENCIA SOCIAL'::text, 'OPE - DIRETORIA/GERÊNCIA'::text, 'OPE - DIRETORIA/GERENCIA'::text, 'OPE - RECOLHIMENTO DE ANIMAIS'::text, 'OPE - SERVIÇOS EM CAMPO'::text, 'OPE_AGETUL'::text, 'OPE_AMMA'::text, 'OPE_SEMAD'::text, 'OPE_SEMAD - 006/2020'::text, 'REDEMOB CONSÓRCIO - 008/2025'::text]));

-- ============================================================
-- vw_relatorio_viagens
-- ============================================================
CREATE OR REPLACE VIEW vw_relatorio_viagens AS
 SELECT placa,
    veiculo,
    grupo AS uo_lotacao,
    todos_grupos,
    data_partida,
    data_chegada,
    duracao_segundos,
    to_char((duracao_segundos || ' seconds'::text)::interval, 'HH24:MI'::text) AS duracao_hhmm,
    distancia_km,
    hodometro_inicial,
    hodometro_final,
    velocidade_media,
    velocidade_maxima,
    end_partida,
    end_chegada,
    motorista_nome,
    motorista_matricula,
    atualizado_em
   FROM tb_viagens v
  ORDER BY placa, data_partida;

-- ============================================================
-- vw_resumo_frota
-- ============================================================
CREATE OR REPLACE VIEW vw_resumo_frota AS
 WITH params AS (
         SELECT date_trunc('year', CURRENT_DATE)::timestamp without time zone AS data_ini,
            CURRENT_DATE::timestamp without time zone AS data_fim
        )
 SELECT v.placa,
    v.grupo AS uo_lotacao,
    p.data_ini,
    p.data_fim,
    EXTRACT(day FROM p.data_fim - p.data_ini)::integer AS dias_no_periodo,
    count(DISTINCT v.data_partida::date) AS dias_utilizados,
    round(sum(v.distancia_km)::numeric, 1) AS km_rodado,
    round((sum(v.distancia_km) / NULLIF(count(DISTINCT v.data_partida::date), 0)::double precision)::numeric, 1) AS media_km_dia,
    round(sum(v.duracao_segundos)::numeric / 3600.0, 1) AS tempo_movimento_h,
    round(count(DISTINCT v.data_partida::date)::numeric / NULLIF(EXTRACT(day FROM p.data_fim - p.data_ini), 0::numeric) * 100::numeric, 0) AS taxa_utilizacao_pct,
    v.todos_grupos
   FROM tb_viagens v
     CROSS JOIN params p
  WHERE v.data_partida >= p.data_ini AND v.data_partida <= p.data_fim
  GROUP BY v.placa, v.grupo, v.todos_grupos, p.data_ini, p.data_fim
  ORDER BY v.placa;

-- ============================================================
-- vw_indicadores_produtividade
-- ============================================================
CREATE OR REPLACE VIEW vw_indicadores_produtividade AS
 WITH params AS (
         SELECT date_trunc('year', CURRENT_DATE)::timestamp without time zone AS data_ini,
            CURRENT_DATE::timestamp without time zone AS data_fim
        ), por_veiculo AS (
         SELECT v.grupo AS uo_lotacao,
            v.todos_grupos,
            v.placa,
            sum(v.distancia_km) AS km_veiculo,
            sum(v.duracao_segundos) AS seg_veiculo,
            count(DISTINCT v.data_partida::date) AS dias_utilizados,
            EXTRACT(day FROM p.data_fim - p.data_ini) AS dias_periodo,
            p.data_ini,
            p.data_fim
           FROM tb_viagens v
             CROSS JOIN params p
          WHERE v.data_partida >= p.data_ini AND v.data_partida <= p.data_fim
          GROUP BY v.grupo, v.todos_grupos, v.placa, p.data_ini, p.data_fim
        )
 SELECT uo_lotacao,
    min(data_ini) AS data_ini,
    max(data_fim) AS data_fim,
    count(*) AS qtd_veiculos,
    round(sum(km_veiculo)::numeric, 0) AS km_total,
    round((sum(km_veiculo) / NULLIF(count(*), 0)::double precision)::numeric, 0) AS media_km_veiculo,
    round(sum(seg_veiculo) / 3600.0, 0) AS tempo_movimento_h,
    round(avg(dias_utilizados::numeric / NULLIF(dias_periodo, 0::numeric) * 100::numeric), 0) AS taxa_media_utilizacao_pct,
    todos_grupos
   FROM por_veiculo
  GROUP BY uo_lotacao, todos_grupos
  ORDER BY todos_grupos;

