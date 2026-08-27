-- BACKUP das views/funções ANTES do refactor Power BI (2026-08-24)
-- ============ vw_cadastro ============
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
    atualizado_em,
    split_grupo(todos_grupos, 'OPE'::text) AS operacao,
    split_grupo(todos_grupos, 'SUP'::text) AS sup,
    split_grupo(todos_grupos, 'REG'::text) AS reg,
    split_grupo(todos_grupos, 'ULOT'::text) AS ulot,
    split_outros(todos_grupos) AS outros
   FROM tb_cadastro c;
;
-- ============ vw_status ============
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
;
-- ============ vw_comportamento ============
CREATE OR REPLACE VIEW vw_comportamento AS
 SELECT e.device_id AS id,
    c.serial,
    c.placa,
    c.todos_grupos,
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
     JOIN vw_cadastro c ON c.id = e.device_id
     LEFT JOIN tb_odometro_dia o ON o.device_id = e.device_id AND o.dia = e.dia
  GROUP BY e.device_id, c.serial, c.placa, c.todos_grupos, e.dia, o.odometro, o.odometro_gps;
;
-- ============ vw_relatorio_viagens ============
CREATE OR REPLACE VIEW vw_relatorio_viagens AS
 SELECT c.placa,
    c.veiculo,
    c.grupo AS uo_lotacao,
    c.todos_grupos,
    v.data_partida,
    v.data_chegada,
    v.duracao_segundos,
    to_char((v.duracao_segundos || ' seconds'::text)::interval, 'HH24:MI'::text) AS duracao_hhmm,
    v.tempo_ocioso_segundos,
    (((v.tempo_ocioso_segundos / 3600)::text) || ':'::text) || lpad((v.tempo_ocioso_segundos % 3600 / 60)::text, 2, '0'::text) AS tempo_ocioso_hhmm,
    v.duracao_parada_segundos,
    (((v.duracao_parada_segundos / 3600)::text) || ':'::text) || lpad((v.duracao_parada_segundos % 3600 / 60)::text, 2, '0'::text) AS duracao_parada_hhmm,
    v.distancia_km,
    v.hodometro_inicial,
    v.hodometro_final,
    v.velocidade_media,
    v.velocidade_maxima,
    ep.endereco AS end_partida,
    ec.endereco AS end_chegada,
    v.motorista_nome,
    v.motorista_matricula
   FROM tb_viagens v
     LEFT JOIN tb_cadastro c ON c.id = v.device_id
     LEFT JOIN tb_enderecos ep ON ep.lat = round(v.lat_partida::numeric, 3) AND ep.lon = round(v.lon_partida::numeric, 3)
     LEFT JOIN tb_enderecos ec ON ec.lat = round(v.lat_chegada::numeric, 3) AND ec.lon = round(v.lon_chegada::numeric, 3)
  ORDER BY c.placa, v.data_partida;
;
-- ============ vw_resumo_frota_mensal ============
CREATE OR REPLACE VIEW vw_resumo_frota_mensal AS
 WITH base AS (
         SELECT r.device_id,
            r.ano,
            r.mes,
            r.km,
            r.duracao_segundos,
            r.dias_utilizados,
            r.viagens,
            c.placa,
            c.marca,
            c.modelo,
            c.grupo AS uo_lotacao,
            c.todos_grupos,
            LEAST((date_trunc('month'::text, make_date(r.ano, r.mes, 1)::timestamp with time zone) + '1 mon'::interval - '1 day'::interval)::date, CURRENT_DATE) - date_trunc('month'::text, make_date(r.ano, r.mes, 1)::timestamp with time zone)::date + 1 AS dias_no_periodo
           FROM tb_resumo_mensal r
             JOIN vw_cadastro c ON c.id = r.device_id
          WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE
        )
 SELECT placa,
    marca,
    modelo,
    uo_lotacao,
    todos_grupos,
    ano,
    mes,
    to_char(make_date(ano, mes, 1)::timestamp with time zone, 'YYYY-MM'::text) AS ano_mes,
    dias_no_periodo,
    dias_utilizados,
    round(km::numeric, 1) AS km_rodado,
    round((km / NULLIF(dias_utilizados, 0)::double precision)::numeric, 1) AS media_km_dia,
    round(duracao_segundos::numeric / 3600.0, 1) AS tempo_movimento_h,
    round(LEAST(dias_utilizados, dias_no_periodo)::numeric / NULLIF(dias_no_periodo, 0)::numeric * 100::numeric, 0) AS taxa_utilizacao_pct,
    viagens
   FROM base
  ORDER BY placa, ano, mes;
;
-- ============ vw_indicadores_mensal ============
CREATE OR REPLACE VIEW vw_indicadores_mensal AS
 WITH base AS (
         SELECT r.device_id,
            r.ano,
            r.mes,
            r.km,
            r.duracao_segundos,
            r.dias_utilizados,
            c.grupo AS uo_lotacao,
            c.todos_grupos,
            LEAST((date_trunc('month'::text, make_date(r.ano, r.mes, 1)::timestamp with time zone) + '1 mon'::interval - '1 day'::interval)::date, CURRENT_DATE) - date_trunc('month'::text, make_date(r.ano, r.mes, 1)::timestamp with time zone)::date + 1 AS dias_no_periodo
           FROM tb_resumo_mensal r
             JOIN vw_cadastro c ON c.id = r.device_id
          WHERE make_date(r.ano, r.mes, 1) <= CURRENT_DATE
        )
 SELECT uo_lotacao,
    todos_grupos,
    ano,
    mes,
    to_char(make_date(ano, mes, 1)::timestamp with time zone, 'YYYY-MM'::text) AS ano_mes,
    count(*) AS qtd_veiculos,
    round(sum(km)::numeric, 0) AS km_total,
    round((sum(km) / NULLIF(count(*), 0)::double precision)::numeric, 0) AS media_km_veiculo,
    round(sum(duracao_segundos) / 3600.0, 0) AS tempo_movimento_h,
    round(avg(LEAST(dias_utilizados, dias_no_periodo)::numeric / NULLIF(dias_no_periodo, 0)::numeric * 100::numeric), 0) AS taxa_media_utilizacao_pct
   FROM base
  GROUP BY uo_lotacao, todos_grupos, ano, mes
  ORDER BY todos_grupos, ano, mes;
;
-- ============ vw_motoristas ============
CREATE OR REPLACE VIEW vw_motoristas AS
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
    m.lotacao,
    m.regional,
    m.superintendencia,
    m.todos_grupos,
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
  ORDER BY m.matricula, (COALESCE(vd.dia, ed.dia));
;
-- ============ vw_motoristas_anual ============
CREATE OR REPLACE VIEW vw_motoristas_anual AS
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
  ORDER BY (
        CASE
            WHEN vm.km_total >= 1::numeric THEN round((GREATEST(0::numeric, 100::numeric - COALESCE(em.excesso_velocidade, 0::bigint)::numeric * 1000.0 / vm.km_total) + GREATEST(0::numeric, 100::numeric - COALESCE(em.aceleracao_brusca, 0::bigint)::numeric * 1000.0 / vm.km_total) + GREATEST(0::numeric, 100::numeric - COALESCE(em.frenagem_brusca, 0::bigint)::numeric * 1000.0 / vm.km_total) + GREATEST(0::numeric, 100::numeric - COALESCE(em.curva_drastica, 0::bigint)::numeric * 1000.0 / vm.km_total)) / 4.0, 1)
            ELSE NULL::numeric
        END);
;
-- ============ vw_grupos ============
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
  ORDER BY todos_grupos;
;
