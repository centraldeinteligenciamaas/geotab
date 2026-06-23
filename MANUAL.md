# Manual do Projeto — Geotab → Postgres Local → BI/CSV

> Documentação operacional do projeto. Voltada para **pessoas** (você e a equipe):
> o que o projeto faz, como ele funciona e como operá-lo no dia a dia.
> Para o estado técnico resumido entre sessões de desenvolvimento, ver `.claude/context.md`.
>
> **Última atualização:** 2026-06-23

---

## 1. Visão geral

Este projeto sincroniza dados da telemetria da frota (plataforma **Geotab**) para um
**banco PostgreSQL local**, alimentando dois consumidores:

1. **Power BI** — conectado ao banco local via On-premises Data Gateway (relatórios internos).
2. **Download CSV externo** — snapshot diário de cada relatório publicado no **Supabase Storage**,
   com links públicos estáveis para clientes que não têm acesso ao banco.

Fluxo de dados:

```
  API Geotab (JSON-RPC)
        │  (sync diária, dias úteis, no logon)
        ▼
  PostgreSQL LOCAL  (C:\Users\ygor.kouzak\pgdata, porta 5432, banco "geotab")
        │                                   │
        ▼                                   ▼
  Power BI (Gateway)              CSVs → Supabase Storage (links públicos)
```

### Por que rodar local?
O projeto já rodou no **Render** (nuvem), mas o IP de saída do Render é **bloqueado pelo WAF
da Geotab** (erro 403 na autenticação). Além disso, o banco era Supabase free (500 MB) e estourava.
Rodar na máquina do usuário resolve os três problemas (IP limpo, sem custo, sem limite de disco)
— ao custo de depender do notebook estar ligado em dia útil.

---

## 2. Stack e requisitos

- **Linguagem:** Python 3 (ver `requirements.txt`).
- **Libs principais:** `requests` (API Geotab), `pandas`, `SQLAlchemy`/`psycopg2` (Postgres),
  `python-dotenv` (carrega o `.env`).
- **Banco:** PostgreSQL 18.4 **portátil** (sem instalação/admin), binários em
  `C:\Users\ygor.kouzak\pgsql\pgsql\bin`, dados em `C:\Users\ygor.kouzak\pgdata`, porta 5432.
- **Storage externo:** Supabase (projeto `geotab-export`, ref `ldhelbygqrjqchistrgp`), só Storage.
- **SO:** Windows 11 (máquina corporativa — **sem admin**, GPO restritivo: por isso nada vira
  serviço do Windows nem roda sem janela de console).

---

## 3. Estrutura de arquivos

| Arquivo | Função |
|---|---|
| `geotab_supabase.py` | **Núcleo.** Extrai da API Geotab e grava no Postgres. Cria/migra tabelas, faz throttle de quota, geocodifica endereços. |
| `atualizar_local.py` | **Orquestrador.** Roda os 4 modos do sync em sequência (dias úteis, 1×/dia), garante o Postgres no ar e, no fim, dispara o export CSV. |
| `exportar_csv.py` | Exporta cada view para CSV e sobe no Supabase Storage (links externos). |
| `iniciar_postgres.bat` | Sobe o Postgres local. Roda no logon (pasta Inicializar). |
| `backup_geotab.bat` | `pg_dump` diário para `C:\Users\ygor.kouzak\backups` (mantém 14 dias). Roda no logon. |
| `psql_geotab.bat` | Abre o cliente `psql` já conectado ao banco local (duplo-clique; saída com `\q`). |
| `views.sql` | Definição das views (DDL). `views_backup.sql` é o backup. |
| `.env` | Credenciais e configuração (**não versionado**). |
| `.claude/context.md` | Estado técnico resumido para retomada de sessões de dev. |
| `MANUAL.md` | Este manual. |

Gerados em runtime (ignorados pelo git): `atualizacao_local.log`, `.ultima_atualizacao`, `exports/`, `__pycache__/`.

---

## 4. Operação no dia a dia

### Modelo de funcionamento
> **Liga o PC num dia útil → tudo roda sozinho no logon.** Não há servidor ligado 24/7.
> A máquina corporativa não acorda sozinha do desligado (GPO trava wake timers), então
> a sync depende de o computador ser ligado em algum momento do dia útil.

O que acontece automaticamente ao fazer **logon**:
1. `iniciar_postgres.bat` sobe o Postgres.
2. `backup_geotab.bat` faz o dump do dia.
3. A Tarefa Agendada **`GeotabSyncLocal`** dispara `atualizar_local.py`, que:
   - confere se é dia útil e se ainda não rodou hoje (marcador `.ultima_atualizacao`);
   - garante o Postgres no ar (auto-cura — ver §8);
   - roda os 4 modos: **cadastro → status → comportamento → viagens**;
   - se os 4 derem OK, grava o marcador do dia e **publica os CSVs** no Supabase Storage.

### Rodar a sync manualmente
```powershell
# orquestrador completo (4 modos + export):
python atualizar_local.py

# um modo isolado:
python geotab_supabase.py cadastro      # snapshot da frota + motoristas
python geotab_supabase.py status        # snapshot tempo real
python geotab_supabase.py comportamento # eventos + odômetro/dia (incremental)
python geotab_supabase.py viagens       # viagens + geocode (incremental)
```
> `viagens` NÃO entra no modo `all` (é o trecho mais pesado). O orquestrador roda os 4 explicitamente.

### Publicar os CSVs manualmente
```powershell
python exportar_csv.py
```
Gera os CSVs em `exports/` e sobe no bucket. Link do índice para o cliente:
`https://ldhelbygqrjqchistrgp.supabase.co/storage/v1/object/public/geotab-csv/index.html`

### Inspecionar o banco
- `psql_geotab.bat` (duplo-clique) ou DBeaver (`localhost:5432` / banco `geotab` / usuário `postgres`).
- Subir o Postgres na mão, se preciso:
  `pg_ctl -D C:\Users\ygor.kouzak\pgdata start`

### Onde olhar quando algo falha
- Log da sync: `atualizacao_local.log` (na raiz do projeto).
- Log do servidor Postgres: `C:\Users\ygor.kouzak\pgdata\server.log`.

---

## 5. Banco de dados — tabelas

> **Piso temporal:** nenhuma tabela guarda dados anteriores a **01/jan do ano corrente**
> (`ANO_CORTE`, default 2026, em `geotab_supabase.py`). Para virar o ano, ajustar `ANO_CORTE`.

| Tabela | Conteúdo | Janela |
|---|---|---|
| `tb_cadastro` | Snapshot atual da frota (full refresh). | atual |
| `tb_status` | Snapshot tempo real; motorista vem das viagens das últimas 24h. | atual |
| `tb_motoristas` | Dimensão de motoristas (entidade User): login/e-mail, nome próprio, matrícula, lotação/regional/superintendência. | atual |
| `tb_comportamento_eventos` | Buckets diários device/dia/tipo de evento (excesso, aceleração, frenagem, curva). | ano corrente |
| `tb_comportamento_motorista` | Mesmos eventos, por motorista (só eventos com motorista identificado, ~40-57%). | ano corrente |
| `tb_viagens` | Uma linha por viagem (enxuta — placa/veículo/grupo vêm de `tb_cadastro` por JOIN). | ano corrente (incremental) |
| `tb_enderecos` | Cache de geocode: coordenada arredondada → endereço. | acumulado |
| `tb_odometro_dia` | Odômetro por device/dia (físico + GPS, último valor do dia). | ano corrente |
| `tb_resumo_mensal` | Agregado km/tempo/dias/viagens por device/mês. | ano corrente |

**Notas de operação:**
- **Viagens é incremental** (`VIAGENS_INCREMENTAL=1`): a janela começa em `max(data_partida) − 3 dias`,
  evitando re-buscar o ano inteiro todo dia. Upsert por id não duplica.
- **Geocode é por lookup e incremental:** só geocodifica coordenadas novas; endereços ficam em
  `tb_enderecos`, não em `tb_viagens`. O `round(lat/lon, 3)` da view tem que casar com `GEOCODE_CASAS=3`.

---

## 6. Banco de dados — views (o que cada relatório serve)

Regra: **uma view por tema.** Todas filtram grupos OPE_*/terceiros e usam `security_invoker = on`.

| View | Granularidade | Uso |
|---|---|---|
| `vw_cadastro` | 1 linha/veículo | Snapshot atual da frota. |
| `vw_status` | 1 linha/veículo | Tempo real (último contato). |
| `vw_grupos` | por grupo | Dimensão de grupos. |
| `vw_comportamento` | device × dia | Eventos do dia + odômetro. ~6 meses. |
| `vw_relatorio_viagens` | 1 linha/viagem | Viagens com endereços, tempos de parada/ocioso. |
| `vw_motoristas` | motorista × dia | Espelha `vw_comportamento` por motorista; BI agrega no período. |
| `vw_motoristas_anual` | 1 linha/motorista | Versão **agregada no ano** (nomes legados `km_total`/`score_seguranca`), para o Power BI antigo. |
| `vw_resumo_frota_mensal` | veículo × mês | Resumo mensal por veículo (inclui marca/modelo). |
| `vw_indicadores_mensal` | grupo × mês | Indicadores mensais por grupo. |

> Para display de nome de motorista no BI, usar `motorista_nome_completo` (nome próprio);
> `motorista_nome` é o login/e-mail. Matrícula = `employeeNo` (~98% de cobertura).

> **Sempre conferir a definição real com `pg_get_viewdef` antes de assumir o que o `views.sql` diz** —
> o arquivo já ficou dessincronizado do banco no passado.

---

## 7. Configuração (`.env`)

O `.env` (não versionado) guarda credenciais e parâmetros. Principais chaves:

| Chave | Para quê |
|---|---|
| `GEOTAB_SERVIDOR` / `GEOTAB_DATABASE` / `GEOTAB_USERNAME` / `GEOTAB_PASSWORD` | Acesso à API Geotab. |
| `SUPABASE_HOST` / `_PORTA` / `_BANCO` / `_USUARIO` / `_SENHA` | Conexão Postgres **local** (nomes herdados da era Supabase; hoje apontam p/ localhost). |
| `SUPABASE_SSLMODE` | `disable` no local (era `require` na nuvem). |
| `VIAGENS_DIAS` | `0` = ano inteiro (local); `>0` = janela móvel em dias (e ativa a poda). |
| `SUPABASE_STORAGE_URL` / `SUPABASE_SERVICE_KEY` / `SUPABASE_BUCKET` | Upload dos CSVs no Storage externo. |

> **Importante:** o orquestrador `atualizar_local.py` carrega o `.env` via `load_dotenv`. Sem isso,
> o export CSV era pulado todo dia (bug corrigido em 2026-06-23).

---

## 8. Robustez do Postgres (auto-cura)

O Postgres local **morre se fecharem a janela/terminal que o hospeda** (exceção `0xC000013A`,
`STATUS_CONTROL_C_EXIT`). Isso já derrubou a sync no meio.

- **Não pode virar serviço** (precisa de admin/GPO) nem rodar sem console (WSH e janela-oculta
  bloqueados na máquina). Por isso a defesa é no código, não no launcher.
- **Auto-cura:** `atualizar_local.py` checa o socket e dá `pg_ctl start` **antes** da sync e
  **de novo** se uma fase falhar (repetindo a fase 1×). Caminhos configuráveis por env
  (`PG_CTL`/`PGDATA`/`PG_HOST`/`PG_PORT`).
- **Regra de ouro para o usuário:** nunca suba o banco por um terminal que vai fechar. Deixe o
  `iniciar_postgres.bat` do logon cuidar disso. Se fechar e o banco morrer, a próxima sync religa.

---

## 9. Download CSV externo (Supabase Storage)

- **Objetivo:** clientes externos baixam cada relatório por link público estável, **sem depender
  do notebook ligado** (snapshot diário, não ao vivo).
- **Como:** após a sync, `exportar_csv.py` usa `psql \copy` (não carrega na RAM) para gerar 1 arquivo
  de **nome fixo** por view e sobe no Storage com `x-upsert` (o link nunca muda). Gera um `index.html`
  com todos os links — **esse é o link que se manda ao cliente.**
- **Viagens é grande** (~1,6 GB no ano): dividida por mês + gzip, e particionada por tamanho
  (`_YYYY-MM.csv.gz` ou `_p1`/`_p2`) para respeitar o **limite do free tier: 50 MB por arquivo**.
- **Refresh:** o bucket é limpo antes de cada publicação (evita arquivos órfãos).
- **Encoding:** `PGCLIENTENCODING=UTF8` é obrigatório no `\copy` (senão o psql aborta no 1º acento).
- **Caveat free tier:** o projeto Supabase pausa após ~7 dias sem atividade — o upload diário o mantém acordado.

Link do índice: `https://ldhelbygqrjqchistrgp.supabase.co/storage/v1/object/public/geotab-csv/index.html`

---

## 10. Atualização agendada no Power BI (banco local via Gateway)

O Power BI Service lê o banco **local** através do **On-premises Data Gateway** instalado nesta
máquina. Para a atualização rodar sozinha, é preciso configurar uma vez a fonte de dados no
gateway e o agendamento no dataset.

### Pré-requisitos
- **Gateway padrão** (standard, não "personal") instalado e online, rodando como **serviço do
  Windows** e logado com a **mesma conta da organização** dona do dataset.
- Driver **Npgsql** (PostgreSQL) instalado na máquina do gateway.
- **Postgres local no ar** no momento do refresh (ver gotcha abaixo).

### Passo a passo (uma vez)
1. Power BI Service → ⚙ → **Gerenciar conexões e gateways** → **Nova conexão / fonte de dados**:
   - **Cluster:** selecionar o gateway desta máquina (dropdown).
   - **Nome da conexão:** `geotab-localhost` (rótulo livre).
   - **Tipo:** PostgreSQL · **Servidor:** `localhost:5432` · **Banco:** `geotab`.
   - **Autenticação:** Basic — usuário `postgres`, senha do banco (ver `psql_geotab.bat` / `.env`).
   - **Nível de privacidade:** Organizational.
   > O **Servidor** aqui tem que ser idêntico ao que está no Power Query do `.pbix` (`localhost`
   > vs `127.0.0.1` importa) — senão dá "não foi possível encontrar a fonte no gateway".
2. Dataset → **⋯ → Configurações → Conexão de gateway:** ativar e mapear para a fonte criada.
3. Mesma tela → **Atualização agendada:** ligar, fuso **UTC-3 (Brasília)**, horário **10:00**,
   e ativar notificação de falha por e-mail.

### Por que 10:00
A sync diária roda no logon e termina cedo (~08:20). 10:00 dá folga para banco + gateway
estarem no ar. Limite do Pro: até 8 horários/dia.

### Gotcha — o refresh falha se o banco estiver fora do ar
A atualização agendada dispara num horário fixo e exige, naquele instante: **PC ligado e
acordado**, **Postgres no ar** e **serviço do gateway rodando**.
- Erro típico: `No connection could be made because the target machine actively refused it`
  (status 400) = **o Postgres não estava no ar** na hora (porta 5432 sem listener).
- A **auto-cura só roda durante a sync diária** — ela NÃO fica vigiando o banco o resto do dia.
  Se o banco cair (janela fechada — gotcha `0xC000013A`, §8) e o Power BI tentar atualizar, falha
  e nada religa o banco para o Power BI.
- **Defesa:** não fechar a janela do Postgres; deixar o `iniciar_postgres.bat` do logon subir o
  banco; manter o PC ligado/acordado às 10:00. Religar na mão se preciso:
  `pg_ctl -D C:\Users\ygor.kouzak\pgdata start` e reexecutar o refresh.
- Nos dias em que o PC fica desligado às 10:00, o refresh falha (limitação do banco ser local
  nesta máquina) — não há solução sem mudar a fonte para um host sempre no ar.

---

## 11. Problemas conhecidos (troubleshooting)

| Sintoma | Causa / Solução |
|---|---|
| Sync não rodou / dados parados | PC não foi ligado em dia útil, ou Postgres caiu. Conferir `atualizacao_local.log` e `server.log`. Religar: `pg_ctl -D C:\...\pgdata start`. |
| `connection refused localhost:5432` | Postgres caiu (janela fechada — `0xC000013A`). A auto-cura religa na próxima fase/sync; ou religar na mão. |
| Power BI: `target machine actively refused it` (400) | Postgres fora do ar na hora do refresh. Religar (`pg_ctl ... start`) e reexecutar. A auto-cura só roda na sync, não p/ o Power BI (ver §10). |
| Export CSV pulado | Faltava `SUPABASE_SERVICE_KEY` no ambiente do orquestrador (corrigido com `load_dotenv` em 2026-06-23). Conferir a chave no `.env`. |
| `403` não-JSON na auth Geotab | Bloqueio de WAF por IP (era o caso do Render). Local tem IP limpo. |
| HTTP 400 ao subir CSV | Arquivo > 50 MB (free tier). O particionamento já cuida; conferir `ALVO_CSV`/`LIMITE_ARQUIVO`. |
| Taxa de utilização > 100% no BI | Mês futuro em `tb_resumo_mensal`. Corrigido em código + views; dar **refresh** no Power BI p/ limpar cache. |
| Quota Geotab estourada | Throttle proativo em 4500 sub-chamadas/min (limite real 5000). |

---

## 12. Decisões importantes (resumo)

- **Local em vez de nuvem:** resolve IP bloqueado (WAF Geotab), limite de disco e custo.
- **Timestamps sem timezone, em horário de Brasília** (Brasil sem horário de verão desde 2019).
- **Uma tabela/view por tema** — rodar tudo junto estoura a RAM e mistura janelas temporais.
- **User-Agent de navegador** nas chamadas Geotab (evita bloqueio Cloudflare).
- **Piso temporal no ano corrente** — banco não guarda histórico anterior a 01/jan.
- **`tb_viagens` enxuta** — texto repetido (placa/grupo) vem por JOIN de `tb_cadastro`.

Para o histórico detalhado por sessão e decisões com data, ver `.claude/context.md`.

---

## 13. Manutenção deste manual

Sempre que houver uma alteração relevante no projeto (novo arquivo, mudança de fluxo,
nova tabela/view, mudança de operação, novo gotcha), **atualize a seção correspondente
deste manual e a data de "Última atualização" no topo** — edição incremental, não
regeneração. Esta regra também está registrada em `claude.md`.
