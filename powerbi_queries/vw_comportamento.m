// Consulta: vw_comportamento
let
    public_vw_comportamento = Table.TransformColumnTypes(
        Table.PromoteHeaders(
            Csv.Document(
                Web.Contents("https://ldhelbygqrjqchistrgp.supabase.co", [RelativePath = "storage/v1/object/public/geotab-csv/vw_comportamento.csv"]),
                [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
            [PromoteAllScalars = true]),
        {{"id", type text}, {"serial", type text}, {"placa", type text}, {"todos_grupos", type text}, {"data", type date}, {"ano", Int64.Type}, {"mes", Int64.Type}, {"excessos_velocidade", Int64.Type}, {"aceleracoes_bruscas", Int64.Type}, {"frenagens_bruscas", Int64.Type}, {"curvas_drasticas", Int64.Type}, {"total_eventos", Int64.Type}, {"score_risco", Int64.Type}, {"odometro", type number}, {"odometro_gps", type number}}, "en-US"),
    #"Linhas Filtradas1" = Table.SelectRows(public_vw_comportamento, each not Text.Contains([todos_grupos], "OPE_COMURG") and not Text.Contains([todos_grupos], "OPE_SEINFRA") and not Text.Contains([todos_grupos], "OPE_PEDREIRA") and not Text.Contains([todos_grupos], "OPE_CS_BRASIL") and not Text.Contains([todos_grupos], "OPE_AGETUL") and not Text.Contains([todos_grupos], "OPE - SERVIÇOS EM CAMPO") and not Text.Contains([todos_grupos], "OPE - ADMINISTRATIVO") and not Text.Contains([todos_grupos], "OPE_SMT") and not Text.Contains([todos_grupos], "OPE - ASSISTÊNCIA SOCIAL") and not Text.Contains([todos_grupos], "OPE - RECOLHIMENTO DE ANIMAIS") and not Text.Contains([todos_grupos], "OPE_SEPLANH") and not Text.Contains([todos_grupos], "OPE - DIRETORIA/GERÊNCIA") and not Text.Contains([todos_grupos], "OPE_SECRET. DA ECONOMIA") and not Text.Contains([todos_grupos], "OPE_AMMA") and not Text.Contains([todos_grupos], "OPE_SEMAD") and not Text.Contains([todos_grupos], "OPE_SECULT") and not Text.Contains([todos_grupos], "REDEMOB")),
    #"Colocar Cada Palavra Em Maiúscula" = Table.TransformColumns(#"Linhas Filtradas1",{{"todos_grupos", Text.Proper, type text}})
in
    #"Colocar Cada Palavra Em Maiúscula"
