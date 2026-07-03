// Consulta: vw_resumo_frota_mensal
let
    public_vw_resumo_frota_mensal = Table.TransformColumnTypes(
        Table.PromoteHeaders(
            Csv.Document(
                Web.Contents("https://ldhelbygqrjqchistrgp.supabase.co", [RelativePath = "storage/v1/object/public/geotab-csv/vw_resumo_frota_mensal.csv"]),
                [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
            [PromoteAllScalars = true]),
        {{"placa", type text}, {"marca", type text}, {"modelo", type text}, {"uo_lotacao", type text}, {"todos_grupos", type text}, {"ano", Int64.Type}, {"mes", Int64.Type}, {"ano_mes", type text}, {"dias_no_periodo", Int64.Type}, {"dias_utilizados", Int64.Type}, {"km_rodado", type number}, {"media_km_dia", type number}, {"tempo_movimento_h", type number}, {"taxa_utilizacao_pct", type number}, {"viagens", Int64.Type}}, "en-US"),
    #"Linhas Filtradas1" = Table.SelectRows(public_vw_resumo_frota_mensal, each not Text.Contains([todos_grupos], "OPE_COMURG") and not Text.Contains([todos_grupos], "OPE_SEINFRA") and not Text.Contains([todos_grupos], "OPE_PEDREIRA") and not Text.Contains([todos_grupos], "OPE_CS_BRASIL") and not Text.Contains([todos_grupos], "OPE_AGETUL") and not Text.Contains([todos_grupos], "OPE - SERVIÇOS EM CAMPO") and not Text.Contains([todos_grupos], "OPE - ADMINISTRATIVO") and not Text.Contains([todos_grupos], "OPE_SMT") and not Text.Contains([todos_grupos], "OPE - ASSISTÊNCIA SOCIAL") and not Text.Contains([todos_grupos], "OPE - RECOLHIMENTO DE ANIMAIS") and not Text.Contains([todos_grupos], "OPE_SEPLANH") and not Text.Contains([todos_grupos], "OPE - DIRETORIA/GERÊNCIA") and not Text.Contains([todos_grupos], "OPE_SECRET. DA ECONOMIA") and not Text.Contains([todos_grupos], "OPE_AMMA") and not Text.Contains([todos_grupos], "OPE_SEMAD") and not Text.Contains([todos_grupos], "OPE_SECULT") and not Text.Contains([todos_grupos], "REDEMOB")),
    #"Colocar Cada Palavra Em Maiúscula" = Table.TransformColumns(#"Linhas Filtradas1",{{"todos_grupos", Text.Proper, type text}, {"uo_lotacao", Text.Proper, type text}}),
    #"Coluna Condicional Adicionada" = Table.AddColumn(#"Colocar Cada Palavra Em Maiúscula", "modelo2", each if [modelo] = "" then [marca] else [modelo]),
    #"Multiplicação Inserida" = Table.AddColumn(#"Coluna Condicional Adicionada", "dia x hora liq", each [dias_no_periodo] * 8, type number),
    #"Divisão Inserida" = Table.AddColumn(#"Multiplicação Inserida", "tx utilizaçao hr liq", each [tempo_movimento_h] / [dia x hora liq], type number)
in
    #"Divisão Inserida"
