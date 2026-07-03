// Consulta: vw_grupos
let
    public_vw_grupos = Table.TransformColumnTypes(
        Table.PromoteHeaders(
            Csv.Document(
                Web.Contents("https://ldhelbygqrjqchistrgp.supabase.co", [RelativePath = "storage/v1/object/public/geotab-csv/vw_grupos.csv"]),
                [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
            [PromoteAllScalars = true]),
        {{"todos_grupos", type text}, {"todos_grupos_arrumado", type text}, {"operacao", type text}, {"sup", type text}, {"reg", type text}, {"ulot", type text}, {"outros", type text}}, "en-US"),
    #"Texto Inserido Após o Delimitador" = Table.AddColumn(public_vw_grupos, "SUP", each Text.AfterDelimiter([sup], "-"), type text),
    #"Texto Inserido Após o Delimitador1" = Table.AddColumn(#"Texto Inserido Após o Delimitador", "REG", each Text.AfterDelimiter([reg], "-"), type text),
    #"Texto Inserido Após o Delimitador2" = Table.AddColumn(#"Texto Inserido Após o Delimitador1", "ULOT", each Text.AfterDelimiter([ulot], "-"), type text),
    #"Texto Aparado" = Table.TransformColumns(#"Texto Inserido Após o Delimitador2",{{"SUP", Text.Trim, type text}, {"REG", Text.Trim, type text}, {"ULOT", Text.Trim, type text}}),
    #"Texto Extraído Antes do Delimitador" = Table.TransformColumns(#"Texto Aparado", {{"sup", each Text.BeforeDelimiter(_, "-"), type text}}),
    #"Texto Extraído Antes do Delimitador1" = Table.TransformColumns(#"Texto Extraído Antes do Delimitador", {{"reg", each Text.BeforeDelimiter(_, "-"), type text}}),
    #"Texto Extraído Antes do Delimitador2" = Table.TransformColumns(#"Texto Extraído Antes do Delimitador1", {{"ulot", each Text.BeforeDelimiter(_, "-"), type text}}),
    #"Texto Aparado1" = Table.TransformColumns(#"Texto Extraído Antes do Delimitador2",{{"ulot", Text.Trim, type text}, {"reg", Text.Trim, type text}, {"sup", Text.Trim, type text}}),
    #"Linhas Filtradas" = Table.SelectRows(#"Texto Aparado1", each not Text.Contains([todos_grupos], "OPE_CS_BRASIL") and not Text.Contains([todos_grupos], "OPE - SERVIÇOS EM CAMPO") and not Text.Contains([todos_grupos], "OPE_AMMA") and not Text.Contains([todos_grupos], "OPE_SECRET. DA ECONOMIA") and not Text.Contains([todos_grupos], "OPE - DIRETORIA/GERÊNCIA") and not Text.Contains([todos_grupos], "OPE_SEPLANH") and not Text.Contains([todos_grupos], "OPE - RECOLHIMENTO DE ANIMAIS") and not Text.Contains([todos_grupos], "OPE - ASSISTÊNCIA SOCIAL") and not Text.Contains([todos_grupos], "OPE - ADMINISTRATIVO") and not Text.Contains([todos_grupos], "OPE_SMT") and not Text.Contains([todos_grupos], "OPE_SEMAD") and not Text.Contains([todos_grupos], "REDEMOB") and not Text.Contains([todos_grupos], "OPE_SECULT") and not Text.Contains([todos_grupos], "OPE_COMURG") and not Text.Contains([todos_grupos], "OPE_SEINFRA") and not Text.Contains([todos_grupos], "OPE_PEDREIRA") and not Text.Contains([todos_grupos], "OPE_AGETUL")),
    #"Colunas Renomeadas" = Table.RenameColumns(#"Linhas Filtradas",{{"SUP", "SUP_"}, {"REG", "REG_"}, {"ULOT", "ULOT_"}}),
    #"Colocar Cada Palavra Em Maiúscula" = Table.TransformColumns(#"Colunas Renomeadas",{{"SUP_", Text.Proper, type text}, {"REG_", Text.Proper, type text}, {"ULOT_", Text.Proper, type text}, {"todos_grupos_arrumado", Text.Proper, type text}})
in
    #"Colocar Cada Palavra Em Maiúscula"
