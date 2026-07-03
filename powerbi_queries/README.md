# Consultas M do Power BI (fonte = CSV público, SEM gateway)

Scripts Power Query prontos para colar no Power BI Desktop (**Transformar dados → Nova
fonte → Consulta em branco → Editor Avançado**), lendo os CSVs que o `exportar_csv.py`
publica no Supabase Storage. Permitem **atualização agendada no Power BI Service sem
On-premises Data Gateway** (fonte Web / Anônimo).

Contexto e passo a passo completo: ver a seção 10-B do `../MANUAL.md`.

## Arquivos (1 consulta cada)

| Arquivo | View | Observações |
|---|---|---|
| `vw_cadastro.m` | vw_cadastro | booleano `ativo` convertido de `t`/`f` |
| `vw_status.m` | vw_status | booleanos `comunicando`/`ignicao_ligada` de `t`/`f` |
| `vw_grupos.m` | vw_grupos | tudo texto |
| `vw_comportamento.m` | vw_comportamento | |
| `vw_motoristas.m` | vw_motoristas | |
| `vw_indicadores_mensal.m` | vw_indicadores_mensal | |
| `vw_resumo_frota_mensal.m` | vw_resumo_frota_mensal | colunas calculadas dependem de tipo numérico |
| `vw_relatorio_viagens.m` | vw_relatorio_viagens | **combina todos os meses** (lê `index.html`, aguenta `_p1`/`_p2` gzip) |

## Regras aplicadas na adaptação

- Fonte trocada de `PostgreSQL.Database(...)` para `Web.Contents(base, [RelativePath=...])`
  — o formato com base estática + `RelativePath` é o que o Service aceita para refresh de
  URL dinâmica (sem ele: erro "fonte de dados dinâmica").
- **Tipagem** replicando o que o conector PostgreSQL entregava, dobrada no passo `public_vw_*`
  para manter TODAS as transformações originais intactas. Cultura `en-US` (CSV usa `.` decimal).
- **Booleanos**: o `\copy ... FORMAT csv` grava `t`/`f` (não `true`/`false`); convertidos com
  `each _ = "t"` em vez de `type logical`.
- **`duracao_hhmm`**: é texto `HH:MM` no banco (igual ao que o conector entregava); a conversão
  `type duration` do usuário foi mantida sem alteração.

## Credencial no Service

Primeiro refresh vai pedir credencial da fonte Web → **Anônimo**, privacidade **Público**.
Não usa mais usuário/senha do Postgres.

## Manutenção

Se uma view ganhar/perder/renomear coluna, ajuste a lista de tipos no passo `public_vw_*`
do arquivo correspondente (nomes e tipos vêm de `information_schema.columns` no banco `geotab`).
