// Consulta: vw_cadastro
let
    public_vw_cadastro = Table.TransformColumnTypes(
        Table.TransformColumns(
            Table.PromoteHeaders(
                Csv.Document(
                    Web.Contents("https://ldhelbygqrjqchistrgp.supabase.co", [RelativePath = "storage/v1/object/public/geotab-csv/vw_cadastro.csv"]),
                    [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
                [PromoteAllScalars = true]),
            {{"ativo", each if _ = "t" then true else if _ = "f" then false else null, type logical}}),
        {{"id", type text}, {"serial", type text}, {"placa", type text}, {"veiculo", type text}, {"marca", type text}, {"modelo", type text}, {"ano", type text}, {"tipo_veiculo", type text}, {"grupo", type text}, {"todos_grupos", type text}, {"atualizado_em", type datetime}, {"operacao", type text}, {"sup", type text}, {"reg", type text}, {"ulot", type text}, {"outros", type text}}, "en-US"),
    #"Linhas Filtradas1" = Table.SelectRows(public_vw_cadastro, each not Text.Contains([todos_grupos], "OPE_COMURG") and not Text.Contains([todos_grupos], "OPE_SEINFRA") and not Text.Contains([todos_grupos], "OPE_PEDREIRA") and not Text.Contains([todos_grupos], "OPE_AGETUL") and not Text.Contains([todos_grupos], "OPE_CS_BRASIL") and not Text.Contains([todos_grupos], "OPE - SERVIÇOS EM CAMPO") and not Text.Contains([todos_grupos], "OPE_AMMA") and not Text.Contains([todos_grupos], "OPE_SECRET. DA ECONOMIA") and not Text.Contains([todos_grupos], "OPE - DIRETORIA/GERÊNCIA") and not Text.Contains([todos_grupos], "OPE_SEPLANH") and not Text.Contains([todos_grupos], "OPE - RECOLHIMENTO DE ANIMAIS") and not Text.Contains([todos_grupos], "OPE - ASSISTÊNCIA SOCIAL") and not Text.Contains([todos_grupos], "OPE - ADMINISTRATIVO") and not Text.Contains([todos_grupos], "OPE_SMT") and not Text.Contains([todos_grupos], "OPE_SEMAD") and not Text.Contains([todos_grupos], "REDEMOB") and not Text.Contains([todos_grupos], "OPE_SECULT") and not Text.Contains([todos_grupos], "Redemob")),
    #"Colocar Cada Palavra Em Maiúscula" = Table.TransformColumns(#"Linhas Filtradas1",{{"ulot", Text.Proper, type text}, {"sup", Text.Proper, type text}, {"reg", Text.Proper, type text}}),
    #"Texto Inserido Antes do Delimitador" = Table.AddColumn(#"Colocar Cada Palavra Em Maiúscula", "Sup_", each Text.BeforeDelimiter([sup], " "), type text),
    #"Texto Inserido Antes do Delimitador1" = Table.AddColumn(#"Texto Inserido Antes do Delimitador", "Reg_", each Text.BeforeDelimiter([reg], " "), type text),
    #"Texto Inserido Antes do Delimitador2" = Table.AddColumn(#"Texto Inserido Antes do Delimitador1", "Ulot_", each Text.BeforeDelimiter([ulot], " "), type text),
    #"Texto Extraído Após o Delimitador" = Table.TransformColumns(#"Texto Inserido Antes do Delimitador2", {{"sup", each Text.AfterDelimiter(_, "-"), type text}, {"reg", each Text.AfterDelimiter(_, "-"), type text}, {"ulot", each Text.AfterDelimiter(_, "-"), type text}}),
    #"Texto Aparado" = Table.TransformColumns(#"Texto Extraído Após o Delimitador",{{"sup", Text.Trim, type text}, {"reg", Text.Trim, type text}, {"ulot", Text.Trim, type text}}),
    #"Colocar Cada Palavra Em Maiúscula1" = Table.TransformColumns(#"Texto Aparado",{{"todos_grupos", Text.Proper, type text}})
in
    #"Colocar Cada Palavra Em Maiúscula1"
