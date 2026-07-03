// Consulta: vw_status
let
    public_vw_status = Table.TransformColumnTypes(
        Table.TransformColumns(
            Table.PromoteHeaders(
                Csv.Document(
                    Web.Contents("https://ldhelbygqrjqchistrgp.supabase.co", [RelativePath = "storage/v1/object/public/geotab-csv/vw_status.csv"]),
                    [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
                [PromoteAllScalars = true]),
            {{"comunicando", each if _ = "t" then true else if _ = "f" then false else null, type logical}, {"ignicao_ligada", each if _ = "t" then true else if _ = "f" then false else null, type logical}}),
        {{"id", type text}, {"serial", type text}, {"placa", type text}, {"ultimo_contato", type datetime}, {"latitude", type number}, {"longitude", type number}, {"velocidade", type number}, {"motorista_nome", type text}, {"motorista_email", type text}, {"motorista_tel", type text}, {"viagem_inicio", type datetime}, {"snapshot_em", type datetime}, {"viagem_fim", type datetime}, {"todos_grupos", type text}}, "en-US"),
    #"Linhas Filtradas1" = Table.SelectRows(public_vw_status, each not Text.Contains([todos_grupos], "OPE_COMURG") and not Text.Contains([todos_grupos], "OPE_SEINFRA") and not Text.Contains([todos_grupos], "OPE_PEDREIRA") and not Text.Contains([todos_grupos], "OPE_CS_BRASIL") and not Text.Contains([todos_grupos], "OPE_AGETUL") and not Text.Contains([todos_grupos], "OPE - SERVIÇOS EM CAMPO") and not Text.Contains([todos_grupos], "OPE - ADMINISTRATIVO") and not Text.Contains([todos_grupos], "OPE_SMT") and not Text.Contains([todos_grupos], "OPE - ASSISTÊNCIA SOCIAL") and not Text.Contains([todos_grupos], "OPE - RECOLHIMENTO DE ANIMAIS") and not Text.Contains([todos_grupos], "OPE_SEPLANH") and not Text.Contains([todos_grupos], "OPE - DIRETORIA/GERÊNCIA") and not Text.Contains([todos_grupos], "OPE_SECRET. DA ECONOMIA") and not Text.Contains([todos_grupos], "OPE_AMMA") and not Text.Contains([todos_grupos], "OPE_SEMAD") and not Text.Contains([todos_grupos], "OPE_SECULT") and not Text.Contains([todos_grupos], "REDEMOB")),
    #"Colocar Cada Palavra Em Maiúscula" = Table.TransformColumns(#"Linhas Filtradas1",{{"todos_grupos", Text.Proper, type text}})
in
    #"Colocar Cada Palavra Em Maiúscula"
