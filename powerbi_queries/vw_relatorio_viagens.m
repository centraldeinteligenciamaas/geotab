// Consulta: vw_relatorio_viagens
let
    IndexTexto = Text.FromBinary(Web.Contents("https://ldhelbygqrjqchistrgp.supabase.co", [RelativePath = "storage/v1/object/public/geotab-csv/index.html"]), 65001),
    PartesHref = List.Skip(Text.Split(IndexTexto, "href="""), 1),
    UrlsTodas = List.Transform(PartesHref, each Text.BeforeDelimiter(_, """")),
    ApenasViagens = List.Select(UrlsTodas, each Text.Contains(_, "vw_relatorio_viagens_") and Text.EndsWith(_, ".csv.gz")),
    Nomes = List.Distinct(List.Transform(ApenasViagens, each Text.AfterDelimiter(_, "/", {0, RelativePosition.FromEnd}))),
    LerGz = (arquivo as text) as table =>
        Table.PromoteHeaders(
            Csv.Document(
                Binary.Decompress(
                    Web.Contents("https://ldhelbygqrjqchistrgp.supabase.co", [RelativePath = "storage/v1/object/public/geotab-csv/" & arquivo]),
                    Compression.GZip),
                [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
            [PromoteAllScalars = true]),
    Combinado = Table.Combine(List.Transform(Nomes, each LerGz(_))),
    public_vw_relatorio_viagens = Table.TransformColumnTypes(Combinado,
        {{"placa", type text}, {"veiculo", type text}, {"uo_lotacao", type text}, {"todos_grupos", type text}, {"data_partida", type datetime}, {"data_chegada", type datetime}, {"duracao_segundos", Int64.Type}, {"duracao_hhmm", type text}, {"tempo_ocioso_segundos", Int64.Type}, {"tempo_ocioso_hhmm", type text}, {"duracao_parada_segundos", Int64.Type}, {"duracao_parada_hhmm", type text}, {"distancia_km", type number}, {"hodometro_inicial", type number}, {"hodometro_final", type number}, {"velocidade_media", type number}, {"velocidade_maxima", type number}, {"end_partida", type text}, {"end_chegada", type text}, {"motorista_nome", type text}, {"motorista_matricula", type text}}, "en-US"),
    #"Tipo Alterado" = Table.TransformColumnTypes(public_vw_relatorio_viagens,{{"duracao_hhmm", type duration}}),
    #"Minutos Extraídos" = Table.TransformColumns(#"Tipo Alterado",{{"duracao_hhmm", Duration.Minutes, Int64.Type}}),
    #"Linhas Filtradas" = Table.SelectRows(#"Minutos Extraídos", each not Text.Contains([todos_grupos], "OPE_COMURG") and not Text.Contains([todos_grupos], "OPE_SEINFRA") and not Text.Contains([todos_grupos], "OPE_PEDREIRA") and not Text.Contains([todos_grupos], "OPE_AGETUL") and not Text.Contains([todos_grupos], "OPE_CS_BRASIL") and not Text.Contains([todos_grupos], "OPE - SERVIÇOS EM CAMPO") and not Text.Contains([todos_grupos], "OPE_AMMA") and not Text.Contains([todos_grupos], "OPE_SECRET. DA ECONOMIA") and not Text.Contains([todos_grupos], "OPE - DIRETORIA/GERÊNCIA") and not Text.Contains([todos_grupos], "OPE_SEPLANH") and not Text.Contains([todos_grupos], "OPE - RECOLHIMENTO DE ANIMAIS") and not Text.Contains([todos_grupos], "OPE - ASSISTÊNCIA SOCIAL") and not Text.Contains([todos_grupos], "OPE - ADMINISTRATIVO") and not Text.Contains([todos_grupos], "OPE_SMT") and not Text.Contains([todos_grupos], "OPE_SEMAD") and not Text.Contains([todos_grupos], "REDEMOB") and not Text.Contains([todos_grupos], "OPE_SECULT")),
    #"Índice Adicionado" = Table.AddIndexColumn(#"Linhas Filtradas", "Índice", 0, 1, Int64.Type),
    #"Coluna Condicional Adicionada" = Table.AddColumn(#"Índice Adicionado", "velocidade_media_2", each if [velocidade_media] > 150 then 0 else [velocidade_media]),
    #"Coluna Condicional Adicionada1" = Table.AddColumn(#"Coluna Condicional Adicionada", "velo_max_2", each if [velocidade_maxima] > 200 then 0 else [velocidade_maxima]),
    #"Tipo Alterado1" = Table.TransformColumnTypes(#"Coluna Condicional Adicionada1",{{"velocidade_media_2", type number}, {"velo_max_2", type number}}),
    #"Colocar Cada Palavra Em Maiúscula" = Table.TransformColumns(#"Tipo Alterado1",{{"todos_grupos", Text.Proper, type text}}),
    #"Valor Substituído" = Table.ReplaceValue(#"Colocar Cada Palavra Em Maiúscula","FITA","FIAT",Replacer.ReplaceText,{"veiculo"}),
    #"Valor Substituído1" = Table.ReplaceValue(#"Valor Substituído","/"," ",Replacer.ReplaceText,{"veiculo"}),
    #"Texto em Maiúscula" = Table.TransformColumns(#"Valor Substituído1",{{"veiculo", Text.Upper, type text}})
in
    #"Texto em Maiúscula"
