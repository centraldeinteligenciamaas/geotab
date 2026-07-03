// Consulta: vw_motoristas
let
    public_vw_motoristas = Table.TransformColumnTypes(
        Table.PromoteHeaders(
            Csv.Document(
                Web.Contents("https://ldhelbygqrjqchistrgp.supabase.co", [RelativePath = "storage/v1/object/public/geotab-csv/vw_motoristas.csv"]),
                [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
            [PromoteAllScalars = true]),
        {{"motorista_nome", type text}, {"motorista_nome_completo", type text}, {"motorista_matricula", type text}, {"lotacao", type text}, {"regional", type text}, {"superintendencia", type text}, {"todos_grupos", type text}, {"data", type date}, {"ano", Int64.Type}, {"mes", Int64.Type}, {"qtd_veiculos", Int64.Type}, {"veiculos", type text}, {"viagens", Int64.Type}, {"km", type number}, {"horas_movimento", type number}, {"horas_ocioso", type number}, {"horas_parado", type number}, {"excessos_velocidade", Int64.Type}, {"aceleracoes_bruscas", Int64.Type}, {"frenagens_bruscas", Int64.Type}, {"curvas_drasticas", Int64.Type}, {"total_eventos", Int64.Type}, {"score_risco", Int64.Type}}, "en-US"),
    #"Colocar Cada Palavra Em Maiúscula" = Table.TransformColumns(public_vw_motoristas,{{"motorista_nome_completo", Text.Proper, type text}})
in
    #"Colocar Cada Palavra Em Maiúscula"
