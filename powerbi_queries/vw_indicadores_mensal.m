// Consulta: vw_indicadores_mensal
let
    public_vw_indicadores_mensal = Table.TransformColumnTypes(
        Table.PromoteHeaders(
            Csv.Document(
                Web.Contents("https://ldhelbygqrjqchistrgp.supabase.co", [RelativePath = "storage/v1/object/public/geotab-csv/vw_indicadores_mensal.csv"]),
                [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
            [PromoteAllScalars = true]),
        {{"uo_lotacao", type text}, {"todos_grupos", type text}, {"ano", Int64.Type}, {"mes", Int64.Type}, {"ano_mes", type text}, {"qtd_veiculos", Int64.Type}, {"km_total", type number}, {"media_km_veiculo", type number}, {"tempo_movimento_h", type number}, {"taxa_media_utilizacao_pct", type number}}, "en-US"),
    #"Linhas Filtradas1" = Table.SelectRows(public_vw_indicadores_mensal, each not Text.Contains([todos_grupos], "OPE_COMURG") and not Text.Contains([todos_grupos], "OPE_SEINFRA") and not Text.Contains([todos_grupos], "OPE_PEDREIRA") and not Text.Contains([todos_grupos], "OPE_CS_BRASIL") and not Text.Contains([todos_grupos], "OPE_AGETUL") and not Text.Contains([todos_grupos], "OPE - SERVIÇOS EM CAMPO") and not Text.Contains([todos_grupos], "OPE - ADMINISTRATIVO") and not Text.Contains([todos_grupos], "OPE_SMT") and not Text.Contains([todos_grupos], "OPE - ASSISTÊNCIA SOCIAL") and not Text.Contains([todos_grupos], "OPE - RECOLHIMENTO DE ANIMAIS") and not Text.Contains([todos_grupos], "OPE_SEPLANH") and not Text.Contains([todos_grupos], "OPE - DIRETORIA/GERÊNCIA") and not Text.Contains([todos_grupos], "OPE_SECRET. DA ECONOMIA") and not Text.Contains([todos_grupos], "OPE_AMMA") and not Text.Contains([todos_grupos], "OPE_SEMAD") and not Text.Contains([todos_grupos], "OPE_SECULT") and not Text.Contains([todos_grupos], "REDEMOB")),
    #"Colocar Cada Palavra Em Maiúscula" = Table.TransformColumns(#"Linhas Filtradas1",{{"todos_grupos", Text.Proper, type text}, {"uo_lotacao", Text.Proper, type text}})
in
    #"Colocar Cada Palavra Em Maiúscula"
