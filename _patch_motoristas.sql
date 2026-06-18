-- tb_comportamento_motorista (caso o sync ainda não tenha rodado p/ criá-la)
CREATE TABLE IF NOT EXISTS tb_comportamento_motorista (
    motorista_id  TEXT,
    device_id     TEXT,
    dia           DATE,
    tipo          TEXT,
    qtd           INTEGER,
    ultimo_ts     TIMESTAMP,
    PRIMARY KEY (motorista_id, device_id, dia, tipo)
);
CREATE INDEX IF NOT EXISTS ix_comp_mot_dia ON tb_comportamento_motorista (dia);
CREATE INDEX IF NOT EXISTS ix_comp_mot_mot ON tb_comportamento_motorista (motorista_id);

-- ============================================================
-- vw_motoristas  (por MOTORISTA, ano 2026)
-- ============================================================
-- Quais veículos cada motorista conduziu no ano + km/horas (inclui ocioso/parado)
-- de tb_viagens, e os eventos de comportamento atribuídos ao motorista
-- (tb_comportamento_motorista) com o SCORE DE SEGURANÇA.
--
-- SCORE (0-100, maior = mais seguro): método "Event Count" do Driver Safety
-- Scorecard da Geotab, por categoria → score_cat = 100 - (eventos_cat * 1000)/km,
-- com piso 0; a nota final é a MÉDIA das 4 categorias. Quanto MENOR a nota, maior
-- o risco. Difere do portal se este usar o método Hybrid (pondera severidade/
-- distância em violação, que não armazenamos). Cobertura limitada aos eventos/
-- viagens com motorista identificado (login/chaveiro).
CREATE OR REPLACE VIEW vw_motoristas
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
        vm.motorista_matricula,
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
  ORDER BY score_seguranca ASC NULLS LAST;
