-- Renomeia as views do painel para o prefixo vw_saneago_* (2026-08-24).
-- Deps entre views são por OID → o rename não quebra as dependentes.
-- Rollback: renomear de volta (vw_saneago_X -> vw_X).
BEGIN;
ALTER VIEW vw_cadastro            RENAME TO vw_saneago_cadastro;
ALTER VIEW vw_status              RENAME TO vw_saneago_status;
ALTER VIEW vw_comportamento       RENAME TO vw_saneago_comportamento;
ALTER VIEW vw_relatorio_viagens   RENAME TO vw_saneago_relatorio_viagens;
ALTER VIEW vw_resumo_frota_mensal RENAME TO vw_saneago_resumo_frota_mensal;
ALTER VIEW vw_indicadores_mensal  RENAME TO vw_saneago_indicadores_mensal;
ALTER VIEW vw_motoristas          RENAME TO vw_saneago_motoristas;
ALTER VIEW vw_motoristas_anual    RENAME TO vw_saneago_motoristas_anual;
ALTER VIEW vw_grupos              RENAME TO vw_saneago_grupos;
COMMIT;
