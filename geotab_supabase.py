import os
import gc
import sys
import time
import calendar
import logging
import threading
import collections
import unicodedata
import requests
import pandas as pd
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from dotenv import load_dotenv
from sqlalchemy import create_engine, text
from sqlalchemy.engine.url import URL
from sqlalchemy.pool import NullPool

BRT = ZoneInfo("America/Sao_Paulo")


def agora_brt():
    """Retorna o datetime atual em BRT como naive (sem offset).
    Colunas são TIMESTAMP (sem timezone) — o valor é exibido como está."""
    return datetime.now(tz=BRT).replace(tzinfo=None)


def ts_brt(valor):
    """Converte qualquer timestamp UTC (string ou pd.Timestamp) para naive BRT.
    Retorna pd.NaT se inválido — mantém dtype datetime64 no DataFrame."""
    ts = pd.to_datetime(valor, utc=True, errors="coerce")
    if pd.isna(ts):
        return pd.NaT
    return ts.tz_convert(BRT).tz_localize(None)


load_dotenv()

GEOTAB = {
    "servidor": os.environ["GEOTAB_SERVIDOR"],
    "database": os.environ["GEOTAB_DATABASE"],
    "userName": os.environ["GEOTAB_USERNAME"],
    "password": os.environ["GEOTAB_PASSWORD"],
}

SUPABASE = {
    "host":    os.environ["SUPABASE_HOST"],
    "porta":   int(os.environ.get("SUPABASE_PORTA", 5432)),
    "banco":   os.environ["SUPABASE_BANCO"],
    "usuario": os.environ["SUPABASE_USUARIO"],
    "senha":   os.environ["SUPABASE_SENHA"],
}

# GPS: acumulado pelo device Geotab desde a instalação — sempre em metros.
DIAG_GPS = "DiagnosticDeviceTotalDistanceId"

# Odômetro físico via OBD2 — testados em ordem de prioridade.
# Unidade inferida automaticamente: > 1_000_000 → metros (÷1000); caso contrário → km.
DIAG_ODO_FISICO = [
    "DiagnosticOdometerInKilometersId",
    "DiagnosticOdometerAdjustmentId",
    "DiagnosticOdometer",
]

# Devices por lote nas consultas de StatusData (odômetro). Cada device pode ter
# milhares de leituras em 30 dias; lote menor = menos leituras seguradas por vez
# = menor pico de memória (essencial no free tier do Render, 512 MB).
ODO_LOTE = int(os.environ.get("GEOTAB_ODO_LOTE", 25))

# Janela (dias) do odômetro no modo INCREMENTAL do comportamento. O odômetro é
# monotônico: basta a leitura mais recente. Quem não reportou nessa janela curta
# mantém o valor anterior (max-merge). No backfill usamos os 6 meses + fallback.
ODO_INCREMENTAL_DIAS = int(os.environ.get("GEOTAB_ODO_INCREMENTAL_DIAS", 7))


# ─────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)s  %(message)s",
    handlers=[logging.StreamHandler()],
)
log = logging.getLogger(__name__)


# ─────────────────────────────────────────────────────────
# CONEXÃO SUPABASE
# ─────────────────────────────────────────────────────────
def criar_engine():
    cfg = SUPABASE
    url = URL.create(
        drivername="postgresql+psycopg2",
        username=cfg["usuario"],
        password=cfg["senha"],
        host=cfg["host"],
        port=cfg["porta"],
        database=cfg["banco"],
        query={"sslmode": "require"},
    )
    # NullPool: o app NUNCA segura conexão ociosa — cada checkout abre uma conexão
    # nova e a fecha ao devolver. No pooler do Supabase em TRANSACTION mode (porta
    # 6543) isso é barato (o pooler multiplexa muitos clientes sobre poucas conexões
    # de servidor). Evita o "max clients reached in session mode" que estourava o
    # limite de 15 do session mode (porta 5432), onde cada conexão segura um slot.
    # Os syncs rodam sequencialmente (lock no app.py) — não há concorrência real.
    return create_engine(
        url,
        poolclass=NullPool,
        connect_args={"connect_timeout": 30},
    )


def _com_retry(fn, tentativas=4, espera_base=5):
    """Executa fn() com retry exponencial — absorve falhas transientes do pooler."""
    for n in range(1, tentativas + 1):
        try:
            return fn()
        except Exception as exc:
            if n == tentativas:
                raise
            espera = espera_base * (2 ** (n - 1))  # 5s, 10s, 20s
            log.warning(f"  ⚠ Tentativa {n}/{tentativas} falhou: {exc}. Aguardando {espera}s...")
            time.sleep(espera)


def criar_tabelas(engine):
    """Cria as 4 tabelas no Supabase se ainda não existirem.
    Usa TIMESTAMP (sem timezone): os valores são gravados em BRT como estão."""
    ddl = """
        CREATE TABLE IF NOT EXISTS tb_cadastro (
            id              TEXT PRIMARY KEY,
            serial          TEXT,
            placa           TEXT,
            veiculo         TEXT,
            marca           TEXT,
            modelo          TEXT,
            ano             TEXT,
            tipo_veiculo    TEXT,
            grupo           TEXT,
            todos_grupos    TEXT,
            ativo           BOOLEAN,
            atualizado_em   TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS tb_status (
            id               TEXT PRIMARY KEY,
            serial           TEXT,
            placa            TEXT,
            todos_grupos     TEXT,
            comunicando      BOOLEAN,
            ultimo_contato   TIMESTAMP,
            latitude         DOUBLE PRECISION,
            longitude        DOUBLE PRECISION,
            velocidade       DOUBLE PRECISION,
            ignicao_ligada   BOOLEAN,
            motorista_nome   TEXT,
            motorista_email  TEXT,
            motorista_tel    TEXT,
            motorista_matricula TEXT,
            viagem_inicio    TIMESTAMP,
            snapshot_em      TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS tb_comportamento (
            id                       TEXT PRIMARY KEY,
            serial                   TEXT,
            placa                    TEXT,
            todos_grupos             TEXT,
            excessos_velocidade_6m   INTEGER,
            aceleracoes_bruscas_6m   INTEGER,
            frenagens_bruscas_6m     INTEGER,
            curvas_drasticas_6m      INTEGER,
            ultimo_excesso_vel       TIMESTAMP,
            ultima_acel_brusca       TIMESTAMP,
            ultima_fren_brusca       TIMESTAMP,
            ultima_curva_drastica    TIMESTAMP,
            score_risco              INTEGER,
            odometro                 DOUBLE PRECISION,
            odometro_gps             DOUBLE PRECISION,
            atualizado_em            TIMESTAMP
        );

        -- Enxuta de propósito: placa/veiculo/grupo/todos_grupos NÃO ficam aqui —
        -- são derivados de tb_cadastro (por device_id) nas views. Repetir esse texto
        -- por viagem custava ~190 MB e estourava o free tier do Supabase (500 MB).
        CREATE TABLE IF NOT EXISTS tb_viagens (
            id                  TEXT PRIMARY KEY,   -- device_id + '|' + start
            device_id           TEXT,
            data_partida        TIMESTAMP,
            data_chegada        TIMESTAMP,
            duracao_segundos    INTEGER,
            distancia_km        DOUBLE PRECISION,
            hodometro_inicial   DOUBLE PRECISION,
            hodometro_final     DOUBLE PRECISION,
            velocidade_media    DOUBLE PRECISION,
            velocidade_maxima   DOUBLE PRECISION,
            end_partida         TEXT,
            end_chegada         TEXT,
            lat_partida         DOUBLE PRECISION,
            lon_partida         DOUBLE PRECISION,
            lat_chegada         DOUBLE PRECISION,
            lon_chegada         DOUBLE PRECISION,
            motorista_id        TEXT,
            motorista_nome      TEXT,
            motorista_matricula TEXT,
            atualizado_em       TIMESTAMP
        );
        CREATE INDEX IF NOT EXISTS ix_viagens_device  ON tb_viagens (device_id);
        CREATE INDEX IF NOT EXISTS ix_viagens_partida ON tb_viagens (data_partida);

        -- Buckets diários de eventos de comportamento (1 linha por device/dia/tipo).
        -- Fonte incremental de tb_comportamento: contamos só os dias novos e somamos
        -- os últimos 6 meses para reconstruir os contadores *_6m. A janela móvel é
        -- mantida apagando buckets fora dos 6 meses.
        CREATE TABLE IF NOT EXISTS tb_comportamento_eventos (
            device_id   TEXT,
            dia         DATE,
            tipo        TEXT,
            qtd         INTEGER,
            ultimo_ts   TIMESTAMP,
            PRIMARY KEY (device_id, dia, tipo)
        );
        CREATE INDEX IF NOT EXISTS ix_comp_eventos_dia ON tb_comportamento_eventos (dia);

        -- Cache de geocodificação (coord arredondada → endereço). As views de
        -- viagens trazem o endereço por JOIN, evitando guardar texto de endereço
        -- repetido em cada viagem (que reinflaria tb_viagens). Coords arredondadas
        -- a GEOCODE_CASAS decimais para deduplicar paradas próximas.
        CREATE TABLE IF NOT EXISTS tb_enderecos (
            lat       NUMERIC(8,4),
            lon       NUMERIC(9,4),
            endereco  TEXT,
            PRIMARY KEY (lat, lon)
        );

        -- Agregado MENSAL de viagens por veículo (km/tempo/dias/qtd). Permite
        -- indicadores cobrindo o ano inteiro filtráveis por mês no BI, sem guardar
        -- as viagens cruas do ano (que não cabem no free tier). ~1750 devices × 12
        -- meses ≈ 21k linhas/ano. placa/grupo vêm de tb_cadastro via JOIN nas views.
        CREATE TABLE IF NOT EXISTS tb_resumo_mensal (
            device_id         TEXT,
            ano               INTEGER,
            mes               INTEGER,
            km                DOUBLE PRECISION,
            duracao_segundos  BIGINT,
            dias_utilizados   INTEGER,
            viagens           INTEGER,
            atualizado_em     TIMESTAMP,
            PRIMARY KEY (device_id, ano, mes)
        );
    """
    # Migra colunas existentes de TIMESTAMPTZ → TIMESTAMP (converte UTC → BRT)
    migrar = """
        DO $$ BEGIN
            IF EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_name = 'tb_status'
                AND column_name = 'snapshot_em'
                AND data_type = 'timestamp with time zone'
            ) THEN
                ALTER TABLE tb_cadastro
                    ALTER COLUMN atualizado_em TYPE TIMESTAMP
                    USING (atualizado_em AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo';

                ALTER TABLE tb_status
                    ALTER COLUMN ultimo_contato TYPE TIMESTAMP
                    USING (ultimo_contato AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo',
                    ALTER COLUMN viagem_inicio TYPE TIMESTAMP
                    USING (viagem_inicio AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo',
                    ALTER COLUMN snapshot_em TYPE TIMESTAMP
                    USING (snapshot_em AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo';

                ALTER TABLE tb_comportamento
                    ALTER COLUMN ultimo_excesso_vel TYPE TIMESTAMP
                    USING (ultimo_excesso_vel AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo',
                    ALTER COLUMN ultima_acel_brusca TYPE TIMESTAMP
                    USING (ultima_acel_brusca AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo',
                    ALTER COLUMN ultima_fren_brusca TYPE TIMESTAMP
                    USING (ultima_fren_brusca AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo',
                    ALTER COLUMN ultima_curva_drastica TYPE TIMESTAMP
                    USING (ultima_curva_drastica AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo',
                    ALTER COLUMN atualizado_em TYPE TIMESTAMP
                    USING (atualizado_em AT TIME ZONE 'UTC') AT TIME ZONE 'America/Sao_Paulo';
            END IF;
        END $$;
    """
    migrar_colunas = """
        ALTER TABLE tb_comportamento
            ADD COLUMN IF NOT EXISTS odometro     DOUBLE PRECISION DEFAULT 0,
            ADD COLUMN IF NOT EXISTS odometro_gps DOUBLE PRECISION DEFAULT 0;
        ALTER TABLE tb_status
            DROP COLUMN IF EXISTS odometro_inicio;
        ALTER TABLE tb_status
            ADD COLUMN IF NOT EXISTS motorista_matricula TEXT,
            ADD COLUMN IF NOT EXISTS todos_grupos        TEXT;
        ALTER TABLE tb_comportamento
            ADD COLUMN IF NOT EXISTS todos_grupos TEXT;
        -- Enxugamento (2026-06-15): colunas derivadas de tb_cadastro ou não usadas
        -- por nenhuma view saem de tb_viagens p/ caber no free tier. As views passam
        -- a trazer placa/veiculo/grupo/todos_grupos via JOIN com tb_cadastro. Rode
        -- VACUUM FULL tb_viagens depois p/ reaver o espaço em disco.
        ALTER TABLE tb_viagens
            DROP COLUMN IF EXISTS serial,
            DROP COLUMN IF EXISTS placa,
            DROP COLUMN IF EXISTS veiculo,
            DROP COLUMN IF EXISTS grupo,
            DROP COLUMN IF EXISTS todos_grupos,
            DROP COLUMN IF EXISTS regional,
            DROP COLUMN IF EXISTS superintendencia;
        -- Renomeia os contadores _30d → _6m (janela passou de 30 dias p/ 6 meses).
        DO $$ BEGIN
            IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_name='tb_comportamento' AND column_name='excessos_velocidade_30d') THEN
                ALTER TABLE tb_comportamento RENAME COLUMN excessos_velocidade_30d TO excessos_velocidade_6m;
            END IF;
            IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_name='tb_comportamento' AND column_name='aceleracoes_bruscas_30d') THEN
                ALTER TABLE tb_comportamento RENAME COLUMN aceleracoes_bruscas_30d TO aceleracoes_bruscas_6m;
            END IF;
            IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_name='tb_comportamento' AND column_name='frenagens_bruscas_30d') THEN
                ALTER TABLE tb_comportamento RENAME COLUMN frenagens_bruscas_30d TO frenagens_bruscas_6m;
            END IF;
            IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_name='tb_comportamento' AND column_name='curvas_drasticas_30d') THEN
                ALTER TABLE tb_comportamento RENAME COLUMN curvas_drasticas_30d TO curvas_drasticas_6m;
            END IF;
        END $$;
    """
    def _executar():
        with engine.begin() as conn:
            conn.execute(text(ddl))
            conn.execute(text(migrar))
            conn.execute(text(migrar_colunas))

    _com_retry(_executar)
    log.info("  ✓ Tabelas verificadas no Supabase.")


def gravar_tabela(df, nome_tabela, engine, chave_upsert="id"):
    if df.empty:
        log.warning(f"DataFrame vazio — {nome_tabela} não atualizada.")
        return

    def _executar():
        with engine.begin() as conn:
            temp = f"tmp_{nome_tabela}"
            # chunksize: insere em blocos para não materializar o INSERT inteiro
            # em memória — essencial no free tier do Render (512 MB).
            df.to_sql(temp, conn, if_exists="replace", index=False, chunksize=1000)

            colunas    = df.columns.tolist()
            cols_str   = ", ".join(colunas)
            update_str = ", ".join([
                f"{c} = EXCLUDED.{c}"
                for c in colunas if c != chave_upsert
            ])

            conn.execute(text(f"""
                INSERT INTO {nome_tabela} ({cols_str})
                SELECT DISTINCT ON ({chave_upsert}) {cols_str}
                FROM {temp}
                ORDER BY {chave_upsert}
                ON CONFLICT ({chave_upsert})
                DO UPDATE SET {update_str};
            """))
            conn.execute(text(f"DROP TABLE IF EXISTS {temp}"))

    _com_retry(_executar)
    log.info(f"  ✓ {nome_tabela}: {len(df)} linhas gravadas.")


# ─────────────────────────────────────────────────────────
# HELPERS GEOTAB
# ─────────────────────────────────────────────────────────
FMT = "%Y-%m-%dT%H:%M:%S.000Z"


def sem_acento(texto: str) -> str:
    """Remove acentos para comparação de nomes de regras."""
    return unicodedata.normalize("NFD", texto).encode("ascii", "ignore").decode()


def _mapa_todos_grupos(credentials, veiculos):
    """{device_id: 'GrupoA | GrupoB | ...'} — nomes de TODOS os grupos do device.
    Mesma semântica da coluna todos_grupos de tb_cadastro/tb_viagens."""
    grupos = {g.get("id"): g.get("name", "") for g in geotab_get(credentials, "Group")}
    mapa = {}
    for v in veiculos:
        gnomes = [grupos.get(g.get("id"), g.get("id")) for g in v.get("groups", [])]
        mapa[v.get("id")] = " | ".join(gnomes)
    return mapa


def parse_nome_veiculo(nome: str) -> dict:
    """
    O Geotab armazena o nome no formato 'PLACA | MARCA | MODELO | NUMERO'.
    Extrai marca e modelo quando disponíveis.
    """
    partes = [p.strip() for p in nome.split("|")]
    return {
        "marca":  partes[1] if len(partes) > 1 else "",
        "modelo": partes[2] if len(partes) > 2 else "",
    }


# ── Controle de quota da Geotab (limite oficial: 5000 sub-chamadas / 1 min) ──
# Estratégia em duas camadas:
#  1) THROTTLE PROATIVO: janela deslizante de 60s; antes de cada chamada esperamos
#     ter orçamento para as N sub-chamadas que ela consome (multicall conta N).
#     Mantém abaixo do teto sem gerar rejeições — crítico p/ frota de 1729 devices.
#  2) RETRY REATIVO: se ainda assim vier OverLimitException (quota compartilhada
#     com outros clientes), espera e repete — rede de segurança.
QUOTA_LIMITE  = int(os.environ.get("GEOTAB_QUOTA_LIMITE", 4500))   # margem sob 5000
QUOTA_RETRY   = int(os.environ.get("GEOTAB_QUOTA_RETRY", 6))       # tentativas reativas
QUOTA_PAUSA   = int(os.environ.get("GEOTAB_QUOTA_PAUSA", 12))      # s por tentativa reativa

_quota_lock = threading.Lock()
_quota_hist = collections.deque()  # timestamps (monotonic) de sub-chamadas recentes


def _consumir_quota(unidades):
    """Bloqueia até haver orçamento para 'unidades' sub-chamadas na janela de 60s,
    então registra o consumo. Pacing proativo para não estourar a quota."""
    unidades = max(int(unidades), 1)
    with _quota_lock:
        while True:
            agora = time.monotonic()
            while _quota_hist and agora - _quota_hist[0] >= 60:
                _quota_hist.popleft()
            if len(_quota_hist) + unidades <= QUOTA_LIMITE:
                _quota_hist.extend([agora] * unidades)
                return
            espera = 60 - (agora - _quota_hist[0]) + 0.1
            log.info(
                f"  ⏳ Throttle quota: aguardando {espera:.1f}s "
                f"({len(_quota_hist)}/{QUOTA_LIMITE} sub-chamadas na janela de 60s)"
            )
            time.sleep(min(espera, 5))


def _eh_erro_quota(resp):
    """True se a resposta JSON-RPC for um OverLimitException (quota excedida)."""
    err = resp.get("error") if isinstance(resp, dict) else None
    if not isinstance(err, dict):
        return False
    if (err.get("data") or {}).get("type") == "OverLimitException":
        return True
    if any(isinstance(e, dict) and e.get("name") == "OverLimitException"
           for e in (err.get("errors") or [])):
        return True
    return "quota" in str(err.get("message", "")).lower()


# Proxy de saída OPCIONAL para alternar o IP de origem das chamadas Geotab.
# A API fica atrás de Cloudflare e barra (403) IPs de datacenter flagados — caso
# do Render. Defina GEOTAB_PROXY (ex.: "http://user:senha@host:porta") para rotear
# por um IP confiável; deixe vazio para conexão DIRETA (uso local, IP limpo).
# Só afeta as chamadas Geotab (requests); a conexão Supabase usa psycopg2 e não
# passa por aqui. Assim o MESMO código roda local (direto) e no Render (via proxy)
# só trocando a variável de ambiente.
GEOTAB_PROXY = os.environ.get("GEOTAB_PROXY", "").strip()


def _host_proxy(url: str) -> str:
    """Host:porta do proxy SEM expor credenciais (descarta user:senha@)."""
    if not url:
        return ""
    return url.split("://", 1)[-1].split("@", 1)[-1]


def descrever_saida_geotab() -> str:
    """Texto curto de como as chamadas Geotab saem — para logs e /status."""
    return f"proxy:{_host_proxy(GEOTAB_PROXY)}" if GEOTAB_PROXY else "direto"


# Sessão HTTP reutilizada com cabeçalhos "de navegador". A API Geotab fica atrás
# de um WAF (Cloudflare): requisições com o User-Agent padrão 'python-requests/x'
# saindo de IPs de datacenter (ex.: Render) podem ser barradas com 403 + página
# HTML (corpo não-JSON). Um UA de navegador + Accept/Content-Type evita esse filtro.
_HTTP = requests.Session()
_HTTP.headers.update({
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept": "application/json",
    "Content-Type": "application/json",
})
if GEOTAB_PROXY:
    _HTTP.proxies.update({"http": GEOTAB_PROXY, "https": GEOTAB_PROXY})
log.info(f"  • Saída das chamadas Geotab: {descrever_saida_geotab()}")

# Status HTTP tratados como falha TRANSITÓRIA (vale retry): bloqueios momentâneos
# de WAF (403), rate-limit do edge (429) e indisponibilidades de servidor (5xx).
RETRYABLE_HTTP = {403, 408, 429, 500, 502, 503, 504}


def _post_geotab(method, params, contexto=""):
    """POST único e blindado para a API Geotab.
    - Pacing proativo de quota + retry reativo em OverLimitException.
    - Retry em falhas TRANSITÓRIAS: erro de rede, corpo vazio/não-JSON e HTTP
      403/429/5xx (bloqueio de WAF / rate-limit / servidor indisponível). Erros
      definitivos (ex.: 401 credencial inválida) NÃO são repetidos.
    - Trata corpo vazio / não-JSON sem estourar JSONDecodeError.
    Retorna o dict da resposta JSON-RPC ({"result": ...} ou {"error": ...}),
    ou {"error": {...}} sintético em caso de falha de rede/parse."""
    unidades = len(params.get("calls", [])) if method == "ExecuteMultiCall" else 1

    ultima = None
    for tentativa in range(1, QUOTA_RETRY + 2):
        _consumir_quota(unidades)
        try:
            r = _HTTP.post(
                GEOTAB["servidor"],
                json={"method": method, "params": params},
                timeout=180,
            )
        except Exception as exc:
            # Erro de rede: sem httpStatus → tratado como transitório.
            ultima = {"error": {"message": str(exc)}}
        else:
            corpo = (r.text or "").strip()
            if not corpo:
                ultima = {"error": {"message": "corpo vazio", "httpStatus": r.status_code}}
            else:
                try:
                    resp = r.json()
                except ValueError:
                    ultima = {"error": {
                        "message": "resposta não-JSON",
                        "httpStatus": r.status_code,
                        "corpo": corpo[:120],
                    }}
                else:
                    # Resposta JSON válida: só a quota pede retry; o resto é definitivo.
                    if _eh_erro_quota(resp) and tentativa <= QUOTA_RETRY:
                        espera = QUOTA_PAUSA * tentativa  # 12, 24, 36...
                        log.warning(
                            f"  ⏳ Quota excedida em {method} {contexto} — aguardando {espera}s "
                            f"(retry {tentativa}/{QUOTA_RETRY})"
                        )
                        time.sleep(espera)
                        continue
                    return resp

        # Falha transitória (rede / corpo vazio / não-JSON). Repete se o status
        # for transitório (ou desconhecido, no caso de erro de rede).
        status = (ultima.get("error") or {}).get("httpStatus")
        transitorio = status is None or status in RETRYABLE_HTTP
        if transitorio and tentativa <= QUOTA_RETRY:
            espera = min(QUOTA_PAUSA * tentativa, 30)
            log.warning(
                f"  ⏳ {method} {contexto}: falha transitória "
                f"({ultima['error'].get('message')}, HTTP {status}) — "
                f"retry {tentativa}/{QUOTA_RETRY} em {espera}s"
            )
            time.sleep(espera)
            continue

        log.warning(f"  ⚠ {method} {contexto} falhou (definitivo): {ultima['error']}")
        return ultima

    return ultima


class GeotabAuthError(RuntimeError):
    """Falha de autenticação na API Geotab (bloqueio de WAF ou credencial inválida).
    Levantada em vez de sys.exit para que o erro suba como exceção normal — assim
    o worker do app.py registra ultimo_erro e o erro aparece em /status, em vez de
    a thread morrer silenciosamente com SystemExit."""


def autenticar():
    """Autentica e respeita o redirecionamento de federation da Geotab.
    Se a resposta trouxer 'path' diferente de 'ThisServer', aponta GEOTAB_SERVIDOR
    para o servidor direto do banco — evita respostas vazias nas chamadas seguintes."""
    resp = _post_geotab(
        "Authenticate",
        {
            "database": GEOTAB["database"],
            "userName": GEOTAB["userName"],
            "password": GEOTAB["password"],
        },
        contexto="(login)",
    )
    if "error" in resp:
        err    = resp["error"] if isinstance(resp["error"], dict) else {"message": resp["error"]}
        status = err.get("httpStatus")
        msg    = str(err.get("message", ""))

        # Diagnóstico direcionado: 403 + corpo não-JSON = bloqueio de WAF (não é
        # senha errada); 401/InvalidUser = credencial de fato inválida.
        if status == 403 or (status is None and "não-JSON" in msg):
            motivo = ("bloqueio de WAF (HTTP 403, corpo não-JSON) — IP de saída barrado "
                      "pelo edge (Cloudflare); NÃO é credencial inválida")
            log.error(
                "Falha na autenticação Geotab: BLOQUEIO DE WAF (HTTP 403, corpo não-JSON). "
                "NÃO é credencial inválida — o edge (Cloudflare) barrou a requisição. "
                "Provável bloqueio do IP de saída (datacenter/Render). "
                "Ações: liberar o IP no MyGeotab/suporte ou usar IP de saída fixo/confiável."
            )
        elif status == 401 or "InvalidUserException" in msg or "incorrect" in msg.lower():
            motivo = ("credencial inválida (HTTP 401) — verifique GEOTAB_DATABASE, "
                      "GEOTAB_USERNAME e GEOTAB_PASSWORD")
            log.error(
                "Falha na autenticação Geotab: CREDENCIAL INVÁLIDA (HTTP 401). "
                "Verifique GEOTAB_DATABASE, GEOTAB_USERNAME e GEOTAB_PASSWORD."
            )
        else:
            motivo = str(err)
            log.error(f"Falha na autenticação Geotab: {err}")
        # ANTES era sys.exit(1): SystemExit escapava do except do worker (app.py),
        # a thread morria sem registrar ultimo_erro e o /status ficava "limpo"
        # enquanto a tabela não atualizava. Levantar exceção normal corrige isso.
        raise GeotabAuthError(f"Autenticação Geotab falhou: {motivo}")

    resultado = resp["result"]
    path = resultado.get("path", "")
    if path and path != "ThisServer":
        novo = f"https://{path}/apiv1"
        if novo != GEOTAB["servidor"]:
            log.info(f"  ↪ Federation: redirecionando servidor para {novo}")
            GEOTAB["servidor"] = novo
    return resultado["credentials"]


def geotab_get(credentials, typeName, search=None, resultsLimit=None):
    params = {"credentials": credentials, "typeName": typeName}
    if search:       params["search"]       = search
    if resultsLimit: params["resultsLimit"] = resultsLimit
    resp = _post_geotab("Get", params, contexto=f"({typeName})")
    if "error" in resp:
        log.warning(f"  ⚠ Get {typeName} falhou: {resp['error']}")
        return []
    return resp.get("result", []) or []


def multicall(credentials, chamadas):
    if not chamadas:
        return []
    resp = _post_geotab(
        "ExecuteMultiCall",
        {"credentials": credentials, "calls": chamadas},
        contexto=f"({len(chamadas)} calls)",
    )
    if "error" in resp:
        log.warning(f"Erro no MultiCall: {resp['error']}")
        return []
    return resp.get("result", []) or []


# ─────────────────────────────────────────────────────────
# TABELA 1 — CADASTRO
# ─────────────────────────────────────────────────────────
def extrair_cadastro(credentials):
    log.info("Extraindo cadastro de veículos...")
    veiculos = geotab_get(credentials, "Device")
    # 0 devices = falha de API (WAF/quota) muito mais provável que frota vazia.
    # Sem esta guarda, o DataFrame sai vazio, gravar_tabela só loga "vazio" e
    # retorna, e o /run/cadastro "conclui" sem atualizar nada nem registrar erro.
    if not veiculos:
        raise RuntimeError(
            "Geotab retornou 0 devices — provável falha de API (WAF/quota), não "
            "frota vazia. Abortando o cadastro para o erro aparecer em /status."
        )
    grupos   = {
        g.get("id"): g.get("name", "")
        for g in geotab_get(credentials, "Group")
    }
    rows = []
    for v in veiculos:
        gids   = [g.get("id") for g in v.get("groups", [])]
        gnomes = [grupos.get(gid, gid) for gid in gids]
        nome   = v.get("name", "")
        parsed = parse_nome_veiculo(nome)
        rows.append({
            "id":            v.get("id", ""),
            "serial":        v.get("serialNumber", ""),
            "placa":         v.get("licensePlate", ""),
            "veiculo":       nome,
            # Geotab não preenche make/model/year — extraímos do nome
            "marca":         v.get("make", "") or parsed["marca"],
            "modelo":        v.get("model", "") or parsed["modelo"],
            "ano":           str(v.get("year", "")),
            "tipo_veiculo":  v.get("vehicleType", ""),
            # gnomes[-1] = grupo mais específico (gnomes[0] seria "Vehicle", raiz)
            "grupo":         gnomes[-1] if gnomes else "",
            "todos_grupos":  " | ".join(gnomes),
            "ativo":         not v.get("isArchived", False),
            "atualizado_em": agora_brt(),
        })
    df = pd.DataFrame(rows)
    log.info(f"  → {len(df)} veículos")
    return df


# ─────────────────────────────────────────────────────────
# TABELA 2 — STATUS
# ─────────────────────────────────────────────────────────
def extrair_status(credentials):
    log.info("Extraindo status em tempo real...")

    veiculos   = geotab_get(credentials, "Device")
    lista_ids  = [v.get("id") for v in veiculos]
    serial_map = {v.get("id"): v.get("serialNumber", "") for v in veiculos}
    placa_map  = {v.get("id"): v.get("licensePlate", "") for v in veiculos}
    grupos_map = _mapa_todos_grupos(credentials, veiculos)

    status_map = {}
    for s in geotab_get(credentials, "DeviceStatusInfo"):
        did = s.get("device", {}).get("id")
        if did:
            status_map[did] = s

    agora = agora_brt()
    ontem = agora - timedelta(hours=24)

    # Trips em LOTES de 150 devices: não seguramos os resultados de toda a frota
    # de uma vez (era o que fazia o status picar ~300 MB). Cada lote é processado
    # e descartado.
    motoristas_ativos = {}
    driver_ids = set()
    LOTE = 150
    for ini in range(0, len(lista_ids), LOTE):
        chunk = lista_ids[ini:ini + LOTE]
        res_viagens = multicall(credentials, [
            {
                "method": "Get",
                "params": {
                    "typeName": "Trip",
                    "search": {
                        "deviceSearch": {"id": did},
                        "fromDate": ontem.strftime(FMT),
                        "toDate":   agora.strftime(FMT),
                    },
                },
            }
            for did in chunk
        ])
        for j, resultado in enumerate(res_viagens):
            did     = chunk[j]
            viagens = resultado if isinstance(resultado, list) else (resultado or {}).get("result", [])
            viagem  = next((v for v in viagens if not v.get("stop")), None)
            if viagem and viagem.get("driver", {}).get("id"):
                motoristas_ativos[did] = {
                    "driver_id":     viagem["driver"]["id"],
                    "viagem_inicio": viagem.get("start"),
                }
                driver_ids.add(viagem["driver"]["id"])
        del res_viagens
        gc.collect()

    info_motoristas = {}
    if driver_ids:
        for res in multicall(credentials, [
            {"method": "Get", "params": {"typeName": "User", "search": {"id": did}}}
            for did in driver_ids
        ]):
            usuarios = res if isinstance(res, list) else res.get("result", [])
            if usuarios:
                u = usuarios[0]
                info_motoristas[u.get("id")] = {
                    "nome":     u.get("name", "Desconhecido"),
                    "email":    u.get("email", ""),
                    "telefone": u.get("phone", ""),
                    "matricula": u.get("employeeNo", ""),
                }

    rows = []
    for did in lista_ids:
        s      = status_map.get(did, {})
        viagem = motoristas_ativos.get(did)
        mot    = info_motoristas.get(viagem["driver_id"], {}) if viagem else {}
        rows.append({
            "id":              did,
            "serial":          serial_map.get(did, ""),
            "placa":           placa_map.get(did, ""),
            "todos_grupos":    grupos_map.get(did, ""),
            "comunicando":     s.get("isDeviceCommunicating", False),
            "ultimo_contato":  ts_brt(s.get("dateTime")),
            "latitude":        s.get("latitude")  or 0,
            "longitude":       s.get("longitude") or 0,
            "velocidade":      s.get("speed", 0),
            "ignicao_ligada":  s.get("isDriving", False),
            "motorista_nome":  mot.get("nome", "Nenhum"),
            "motorista_email": mot.get("email", ""),
            "motorista_tel":   mot.get("telefone", ""),
            "motorista_matricula": mot.get("matricula", ""),
            "viagem_inicio":   ts_brt(viagem.get("viagem_inicio") if viagem else None),
            "snapshot_em":     agora_brt(),
        })

    df = pd.DataFrame(rows)
    log.info(f"  → {len(df)} veículos no status")
    return df


# ─────────────────────────────────────────────────────────
# ODÔMETRO — GPS e físico (OBD2)
# ─────────────────────────────────────────────────────────
def _inferir_km(valor_raw: float) -> float:
    """Detecta a unidade do valor bruto e retorna km.
    Regra: valores > 1_000_000 estão em metros (÷ 1000); abaixo disso já são km.
    Cobertura: 1.000 km em metros = 1.000.000 → limiar justo para frotas comerciais."""
    if not valor_raw:
        return 0.0
    return round(valor_raw / 1000, 2) if valor_raw > 1_000_000 else round(float(valor_raw), 2)


def _max_diag_em_lotes(credentials, lista_ids, diag_id, ini, fim, lote=ODO_LOTE):
    """Consulta StatusData em lotes e reduz a {device: max_raw} on-the-fly.
    Nunca acumula todas as leituras em memória — cada lote é processado e
    descartado, mantendo o pico baixo (essencial no free tier do Render)."""
    mapa = {}
    for i in range(0, len(lista_ids), lote):
        sub = lista_ids[i:i + lote]
        resultados = multicall(credentials, [
            {
                "method": "Get",
                "params": {
                    "typeName": "StatusData",
                    "search": {
                        "deviceSearch":     {"id": did},
                        "diagnosticSearch": {"id": diag_id},
                        "fromDate": ini.strftime(FMT),
                        "toDate":   fim.strftime(FMT),
                    },
                },
            }
            for did in sub
        ])
        for j, resultado in enumerate(resultados):
            did      = sub[j]
            leituras = resultado if isinstance(resultado, list) else (resultado or {}).get("result", [])
            mapa[did] = max((r.get("data") or 0 for r in leituras), default=0)
        del resultados
        gc.collect()
    return mapa


def _com_fallback_ano(credentials, lista_ids, diag_id, data_inicio, mapa_raw):
    """Para devices sem leitura na janela, busca no ano anterior."""
    sem_dado = [did for did, v in mapa_raw.items() if not v]
    if not sem_dado:
        return
    um_ano   = data_inicio - timedelta(days=365)
    fallback = _max_diag_em_lotes(credentials, sem_dado, diag_id, um_ano, data_inicio)
    for did, v in fallback.items():
        if v:
            mapa_raw[did] = v
    recuperados = sum(1 for did in sem_dado if mapa_raw[did])
    log.info(f"    → {recuperados}/{len(sem_dado)} recuperados no fallback 1 ano")


def buscar_odo_gps(credentials, lista_ids, data_inicio, data_fim, usar_fallback=True):
    """Retorna {device_id: km} via GPS (DiagnosticDeviceTotalDistanceId).
    Valores sempre em metros → divide por 1000.
    usar_fallback=False pula a busca de 1 ano (modo incremental: janela curta,
    devices sem leitura mantêm o valor anterior via max-merge no chamador)."""
    log.info(f"  • GPS odômetro via '{DIAG_GPS}'...")
    mapa_raw = _max_diag_em_lotes(credentials, lista_ids, DIAG_GPS, data_inicio, data_fim)
    if usar_fallback:
        _com_fallback_ano(credentials, lista_ids, DIAG_GPS, data_inicio, mapa_raw)
    mapa_km = {did: round(v / 1000, 2) if v else 0.0 for did, v in mapa_raw.items()}
    com_dado = sum(1 for v in mapa_km.values() if v > 0)
    log.info(f"    → {com_dado}/{len(lista_ids)} veículos com dado GPS")
    return mapa_km


def buscar_odo_fisico(credentials, lista_ids, data_inicio, data_fim, usar_fallback=True):
    """Retorna {device_id: km} via OBD2 (odômetro físico do veículo).
    Testa DIAG_ODO_FISICO em ordem; unidade inferida automaticamente por _inferir_km.
    usar_fallback=False pula a busca de 1 ano (modo incremental)."""
    for diag_id in DIAG_ODO_FISICO:
        log.info(f"  • Odômetro físico via '{diag_id}'...")
        mapa_raw = _max_diag_em_lotes(credentials, lista_ids, diag_id, data_inicio, data_fim)
        if usar_fallback:
            _com_fallback_ano(credentials, lista_ids, diag_id, data_inicio, mapa_raw)

        mapa_km     = {did: _inferir_km(v) for did, v in mapa_raw.items()}
        encontrados = sum(1 for v in mapa_km.values() if v > 0)
        log.info(f"    → {encontrados}/{len(lista_ids)} veículos com dado físico")

        if encontrados > 0:
            # Loga amostra para validar unidade inferida
            amostras = [(did, mapa_raw[did], mapa_km[did])
                        for did, v in mapa_km.items() if v > 0][:3]
            for did, raw, km in amostras:
                unidade = "metros" if raw > 1_000_000 else "km"
                log.info(f"    └ device {did}: raw={raw:.0f} ({unidade}) → {km} km")
            log.info(f"  ✓ Diagnóstico físico selecionado: '{diag_id}'")
            return mapa_km

    log.warning(f"  ⚠ Nenhum diagnóstico OBD2 disponível: {DIAG_ODO_FISICO}")
    log.warning("  ⚠ Verifique o log SONDA — odometro ficará 0 para todos os veículos.")
    return {did: 0.0 for did in lista_ids}


# ─────────────────────────────────────────────────────────
# TABELA 3 — COMPORTAMENTO
# ─────────────────────────────────────────────────────────
def _meses_atras(dt, n):
    """Subtrai n meses de calendário de dt, com guarda p/ dia inexistente
    (ex.: 31 de mês → mês com 30/28 dias). Mantém hora/min/seg."""
    mes = dt.month - n
    ano = dt.year
    while mes <= 0:
        mes += 12
        ano -= 1
    ultimo_dia = calendar.monthrange(ano, mes)[1]
    return dt.replace(year=ano, month=mes, day=min(dt.day, ultimo_dia))


# Os 4 tipos de evento, na ordem usada em todo o módulo (chave dos buckets).
TIPOS_EVENTO = ["excesso_velocidade", "aceleracao_brusca", "frenagem_brusca", "curva_drastica"]


def _dia_ts_brt(iso_utc):
    """A partir de um ISO UTC da Geotab ('2024-06-01T12:34:56.000Z') devolve
    ('YYYY-MM-DD' em BRT, datetime naive BRT). Brasil sem horário de verão desde
    2019 → offset fixo UTC-3. Retorna (None, None) se a string for inválida."""
    if not iso_utc or len(iso_utc) < 19:
        return None, None
    try:
        dt_utc = datetime.strptime(iso_utc[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        return None, None
    dt_brt = dt_utc - timedelta(hours=3)
    return dt_brt.strftime("%Y-%m-%d"), dt_brt


def _identificar_regras(credentials):
    """Devolve (ids_velocidade, regras_simples) resolvendo nomes/ids das regras
    Geotab para cada tipo de evento de comportamento."""
    todas_regras = geotab_get(
        credentials, "Rule",
        search={"fromDate": "2000-01-01T00:00:00.000Z"}
    )

    TERMOS_VELOCIDADE     = {"excesso velocidade"}
    IDS_VELOCIDADE_PADRAO = {"RuleSpeedingId", "RulePostedSpeedingId"}
    TIPOS_SIMPLES = {
        "aceleracao_brusca": (
            {"RuleHarshAccelerationId", "RuleJackrabbitStartsId"},
            ["aceleracao brusca", "jackrabbit", "harsh acceleration", "hard acceleration"],
        ),
        "frenagem_brusca": (
            {"RuleHarshBrakingId"},
            ["frenagem brusca", "harsh braking"],
        ),
        "curva_drastica": (
            {"RuleHarshCorneringId"},
            ["curva drastica", "harsh cornering"],
        ),
    }

    ids_velocidade = [
        r.get("id") for r in todas_regras
        if r.get("id") in IDS_VELOCIDADE_PADRAO
        or any(t in sem_acento(r.get("name", "").lower()) for t in TERMOS_VELOCIDADE)
    ]
    log.info(f"  • Regras de velocidade encontradas ({len(ids_velocidade)}): {ids_velocidade}")

    regras_simples = {}
    for tipo, (ids_padrao, termos) in TIPOS_SIMPLES.items():
        regras_simples[tipo] = next(
            (r.get("id") for r in todas_regras
             if r.get("id") in ids_padrao
             or any(t in sem_acento(r.get("name", "").lower()) for t in termos)),
            None,
        )
        log.info(f"  • Regra '{tipo}' → {regras_simples[tipo]}")

    return ids_velocidade, regras_simples


def _ler_ultimo_dia_buckets(engine):
    """Maior 'dia' já presente em tb_comportamento_eventos (date) ou None se vazia."""
    def _exec():
        with engine.connect() as conn:
            return conn.execute(
                text("SELECT MAX(dia) FROM tb_comportamento_eventos")
            ).scalar()
    return _com_retry(_exec)


def _upsert_buckets(engine, buckets):
    """Grava/atualiza os buckets {(did, dia, tipo): {qtd, ultimo_ts}}.
    Re-sincronizações de um dia já existente SOBRESCREVEM a contagem (o dia é
    recontado por inteiro), então o ON CONFLICT usa o valor novo."""
    if not buckets:
        log.info("  • Nenhum bucket novo de evento.")
        return
    df = pd.DataFrame([
        {"device_id": did, "dia": dia, "tipo": tipo,
         "qtd": v["qtd"], "ultimo_ts": v["ultimo_ts"]}
        for (did, dia, tipo), v in buckets.items()
    ])

    def _exec():
        with engine.begin() as conn:
            df.to_sql("tmp_comp_eventos", conn, if_exists="replace", index=False, chunksize=5000)
            conn.execute(text("""
                INSERT INTO tb_comportamento_eventos (device_id, dia, tipo, qtd, ultimo_ts)
                SELECT device_id, dia::date, tipo, qtd, ultimo_ts FROM tmp_comp_eventos
                ON CONFLICT (device_id, dia, tipo)
                DO UPDATE SET qtd = EXCLUDED.qtd, ultimo_ts = EXCLUDED.ultimo_ts
            """))
            conn.execute(text("DROP TABLE IF EXISTS tmp_comp_eventos"))

    _com_retry(_exec)
    log.info(f"  ✓ {len(df)} buckets (device/dia/tipo) gravados.")


def _limpar_buckets_antigos(engine, limite_dia):
    """Apaga buckets anteriores a limite_dia ('YYYY-MM-DD') — mantém a janela móvel
    de 6 meses e impede a tabela de crescer indefinidamente."""
    def _exec():
        with engine.begin() as conn:
            r = conn.execute(
                text("DELETE FROM tb_comportamento_eventos WHERE dia < CAST(:lim AS date)"),
                {"lim": limite_dia},
            )
            return r.rowcount
    apagados = _com_retry(_exec)
    log.info(f"  ✓ {apagados} buckets fora da janela (dia < {limite_dia}) removidos.")


def _ler_odo_anterior(engine):
    """{device_id: (odometro_fisico, odometro_gps)} já gravados em tb_comportamento.
    Usado no incremental para manter o valor de quem não reportou na janela curta."""
    def _exec():
        with engine.connect() as conn:
            return conn.execute(
                text("SELECT id, odometro, odometro_gps FROM tb_comportamento")
            ).all()
    rows = _com_retry(_exec)
    return {r[0]: (r[1] or 0, r[2] or 0) for r in rows}


def _reconstruir_comportamento(engine, base_rows, janela_ini, agora):
    """Reconstrói tb_comportamento somando os buckets dos últimos 6 meses
    (dia >= janela_ini) por device/tipo e juntando serial/placa/grupos/odômetro
    vindos de base_rows. Faz upsert por id."""
    base_df = pd.DataFrame(base_rows)

    def _exec():
        with engine.begin() as conn:
            base_df.to_sql("tmp_comp_base", conn, if_exists="replace", index=False, chunksize=2000)
            conn.execute(text("""
                INSERT INTO tb_comportamento (
                    id, serial, placa, todos_grupos,
                    excessos_velocidade_6m, aceleracoes_bruscas_6m,
                    frenagens_bruscas_6m, curvas_drasticas_6m,
                    ultimo_excesso_vel, ultima_acel_brusca,
                    ultima_fren_brusca, ultima_curva_drastica,
                    score_risco, odometro, odometro_gps, atualizado_em
                )
                SELECT
                    b.device_id, b.serial, b.placa, b.todos_grupos,
                    COALESCE(ev.qtd,0), COALESCE(ac.qtd,0),
                    COALESCE(fr.qtd,0), COALESCE(cu.qtd,0),
                    ev.ultimo, ac.ultimo, fr.ultimo, cu.ultimo,
                    COALESCE(ev.qtd,0)*3 + COALESCE(ac.qtd,0)*2
                        + COALESCE(fr.qtd,0)*2 + COALESCE(cu.qtd,0)*1,
                    b.odometro, b.odometro_gps, :agora
                FROM tmp_comp_base b
                LEFT JOIN (SELECT device_id, SUM(qtd) qtd, MAX(ultimo_ts) ultimo
                           FROM tb_comportamento_eventos
                           WHERE dia >= CAST(:ini AS date) AND tipo='excesso_velocidade'
                           GROUP BY device_id) ev ON ev.device_id = b.device_id
                LEFT JOIN (SELECT device_id, SUM(qtd) qtd, MAX(ultimo_ts) ultimo
                           FROM tb_comportamento_eventos
                           WHERE dia >= CAST(:ini AS date) AND tipo='aceleracao_brusca'
                           GROUP BY device_id) ac ON ac.device_id = b.device_id
                LEFT JOIN (SELECT device_id, SUM(qtd) qtd, MAX(ultimo_ts) ultimo
                           FROM tb_comportamento_eventos
                           WHERE dia >= CAST(:ini AS date) AND tipo='frenagem_brusca'
                           GROUP BY device_id) fr ON fr.device_id = b.device_id
                LEFT JOIN (SELECT device_id, SUM(qtd) qtd, MAX(ultimo_ts) ultimo
                           FROM tb_comportamento_eventos
                           WHERE dia >= CAST(:ini AS date) AND tipo='curva_drastica'
                           GROUP BY device_id) cu ON cu.device_id = b.device_id
                ON CONFLICT (id) DO UPDATE SET
                    serial=EXCLUDED.serial, placa=EXCLUDED.placa,
                    todos_grupos=EXCLUDED.todos_grupos,
                    excessos_velocidade_6m=EXCLUDED.excessos_velocidade_6m,
                    aceleracoes_bruscas_6m=EXCLUDED.aceleracoes_bruscas_6m,
                    frenagens_bruscas_6m=EXCLUDED.frenagens_bruscas_6m,
                    curvas_drasticas_6m=EXCLUDED.curvas_drasticas_6m,
                    ultimo_excesso_vel=EXCLUDED.ultimo_excesso_vel,
                    ultima_acel_brusca=EXCLUDED.ultima_acel_brusca,
                    ultima_fren_brusca=EXCLUDED.ultima_fren_brusca,
                    ultima_curva_drastica=EXCLUDED.ultima_curva_drastica,
                    score_risco=EXCLUDED.score_risco,
                    odometro=EXCLUDED.odometro, odometro_gps=EXCLUDED.odometro_gps,
                    atualizado_em=EXCLUDED.atualizado_em
            """), {"ini": janela_ini, "agora": agora})
            conn.execute(text("DROP TABLE IF EXISTS tmp_comp_base"))

    _com_retry(_exec)
    log.info(f"  ✓ tb_comportamento reconstruída de {len(base_df)} devices.")


def sincronizar_comportamento(credentials, engine):
    """Sincroniza o comportamento (janela móvel de 6 meses) de forma incremental.

    1ª execução (tb_comportamento_eventos vazia) = BACKFILL: conta os 6 meses
    inteiros. Execuções seguintes = INCREMENTAL: recontam só do último dia já
    gravado (que pode ter ficado parcial) até agora. Os eventos viram buckets
    diários (device/dia/tipo); tb_comportamento é então reconstruída somando os
    buckets dos últimos 6 meses. Buckets fora da janela são apagados."""
    log.info("Sincronizando comportamento (6 meses, incremental por buckets diários)...")

    veiculos   = geotab_get(credentials, "Device")
    lista_ids  = [v.get("id") for v in veiculos]
    ids_set    = set(lista_ids)
    serial_map = {v.get("id"): v.get("serialNumber", "") for v in veiculos}
    placa_map  = {v.get("id"): v.get("licensePlate", "") for v in veiculos}
    grupos_map = _mapa_todos_grupos(credentials, veiculos)

    ids_velocidade, regras_simples = _identificar_regras(credentials)

    data_fim       = agora_brt()
    janela_ini     = _meses_atras(data_fim, 6)
    janela_ini_str = janela_ini.strftime("%Y-%m-%d")

    ultimo_dia = _ler_ultimo_dia_buckets(engine)
    if ultimo_dia is None:
        backfill = True
        desde    = janela_ini
        log.info(f"  • BACKFILL (carga única): {janela_ini:%Y-%m-%d} → {data_fim:%Y-%m-%d}")
    else:
        backfill = False
        # Reconta desde 00:00 do último dia gravado (pode ter ficado parcial),
        # nunca antes do início da janela de 6 meses.
        desde = datetime.combine(ultimo_dia, datetime.min.time())
        if desde < janela_ini:
            desde = janela_ini
        log.info(f"  • INCREMENTAL: {desde:%Y-%m-%d} → {data_fim:%Y-%m-%d} (último dia gravado: {ultimo_dia})")

    # Dia-piso da contagem. A busca na Geotab usa horário BRT rotulado como UTC
    # (convenção do módulo), o que alcança ~3h a mais para trás e "vaza" eventos
    # para o dia anterior. Descartamos buckets antes do piso para não sobrescrever
    # com contagem parcial um dia anterior já completo (no backfill o que sobrar
    # antes da janela é removido por _limpar_buckets_antigos).
    floor_dia = desde.strftime("%Y-%m-%d")

    # ── Conta eventos em buckets diários {(did, 'YYYY-MM-DD', tipo): {qtd, ultimo_ts}} ──
    buckets = {}

    def processar(eventos, tipo):
        contados, ignorados = 0, 0
        for ev in eventos:
            did = (
                ev["device"].get("id")
                if isinstance(ev.get("device"), dict)
                else ev.get("device")
            )
            if not did or did not in ids_set:
                ignorados += 1
                continue
            dia, ts = _dia_ts_brt(ev.get("activeFrom") or ev.get("dateTime"))
            if dia is None:
                ignorados += 1
                continue
            if dia < floor_dia:
                continue  # vazamento de fuso p/ dia anterior já consolidado
            k = (did, dia, tipo)
            b = buckets.get(k)
            if b is None:
                buckets[k] = {"qtd": 1, "ultimo_ts": ts}
            else:
                b["qtd"] += 1
                if ts > b["ultimo_ts"]:
                    b["ultimo_ts"] = ts
            contados += 1
        return contados, ignorados

    # Teto por chamada da Geotab. Quando atingido, a janela é fracionada — assim
    # NENHUM evento é perdido (contagem completa) e cada chamada continua leve.
    LIMIT      = 50000
    MIN_JANELA = timedelta(minutes=5)  # piso do fracionamento recursivo

    def contar_regra(rid, tipo, ini, fim):
        """Conta TODOS os eventos da regra em [ini, fim] para buckets diários.
        Se a janela satura (>= LIMIT), divide pela metade e recursa. Retorna
        (total, contados, ignorados)."""
        eventos = geotab_get(
            credentials, "ExceptionEvent",
            search={
                "ruleSearch": {"id": rid},
                "fromDate": ini.strftime(FMT),
                "toDate":   fim.strftime(FMT),
            },
            resultsLimit=LIMIT,
        )
        n = len(eventos)

        if n >= LIMIT and (fim - ini) > MIN_JANELA:
            del eventos
            gc.collect()
            meio = ini + (fim - ini) / 2
            t1, c1, i1 = contar_regra(rid, tipo, ini, meio)
            t2, c2, i2 = contar_regra(rid, tipo, meio, fim)
            return t1 + t2, c1 + c2, i1 + i2

        if n >= LIMIT:
            log.warning(
                f"  ⚠ Janela mínima {ini:%Y-%m-%d %H:%M}–{fim:%H:%M} ainda saturada "
                f"({n} eventos, regra {rid}) — caso extremo, reduza MIN_JANELA"
            )
        c, i = processar(eventos, tipo)
        del eventos
        return n, c, i

    # Velocidade (todas as regras) — fracionamento adaptativo sobre a janela.
    total_vel, contados_vel, ignorados_vel = 0, 0, 0
    for rid in ids_velocidade:
        t, c, i = contar_regra(rid, "excesso_velocidade", desde, data_fim)
        total_vel += t
        contados_vel += c
        ignorados_vel += i
        gc.collect()
    log.info(f"  • excesso_velocidade: {total_vel} eventos ({contados_vel} atribuídos, {ignorados_vel} sem match)")

    # Demais tipos
    for tipo, rid in regras_simples.items():
        if not rid:
            log.warning(f"  • Regra '{tipo}' não encontrada — pulando")
            continue
        t, c, i = contar_regra(rid, tipo, desde, data_fim)
        gc.collect()
        log.info(f"  • {tipo}: {t} eventos ({c} atribuídos, {i} sem match)")

    # ── Persiste buckets e mantém a janela móvel ──
    _upsert_buckets(engine, buckets)
    del buckets
    gc.collect()
    _limpar_buckets_antigos(engine, janela_ini_str)

    # ── Odômetro: backfill usa 6 meses + fallback; incremental usa janela curta ──
    if backfill:
        odo_gps_map    = buscar_odo_gps(credentials, lista_ids, janela_ini, data_fim)
        odo_fisico_map = buscar_odo_fisico(credentials, lista_ids, janela_ini, data_fim)
    else:
        recente = data_fim - timedelta(days=ODO_INCREMENTAL_DIAS)
        odo_gps_map    = buscar_odo_gps(credentials, lista_ids, recente, data_fim, usar_fallback=False)
        odo_fisico_map = buscar_odo_fisico(credentials, lista_ids, recente, data_fim, usar_fallback=False)
        # Odômetro é monotônico → mantém o maior entre a leitura nova e a anterior
        # (quem não reportou na janela curta preserva o valor já gravado).
        prev = _ler_odo_anterior(engine)
        odo_gps_map    = {did: max(odo_gps_map.get(did, 0),    prev.get(did, (0, 0))[1]) for did in lista_ids}
        odo_fisico_map = {did: max(odo_fisico_map.get(did, 0), prev.get(did, (0, 0))[0]) for did in lista_ids}

    # ── Reconstrói tb_comportamento a partir dos buckets dos últimos 6 meses ──
    base_rows = [
        {
            "device_id":    did,
            "serial":       serial_map.get(did, ""),
            "placa":        placa_map.get(did, ""),
            "todos_grupos": grupos_map.get(did, ""),
            "odometro":     odo_fisico_map.get(did, 0),
            "odometro_gps": odo_gps_map.get(did, 0),
        }
        for did in lista_ids
    ]
    _reconstruir_comportamento(engine, base_rows, janela_ini_str, data_fim)
    log.info(f"  → comportamento sincronizado ({'backfill' if backfill else 'incremental'}).")


# ─────────────────────────────────────────────────────────
# TABELA 4 — VIAGENS  (base do Relatório de Viagem estilo SANEAGO)
# ─────────────────────────────────────────────────────────
# Janela de extração. Padrão = ANO CORRENTE (de 1º/jan às 00:00 até agora).
# VIAGENS_DIAS > 0 sobrescreve com uma janela móvel de N dias (útil p/ smoke test:
# ex. VIAGENS_DIAS=2). VIAGENS_DIAS=0 (padrão) → ano corrente.
VIAGENS_DIAS = int(os.environ.get("VIAGENS_DIAS", 0))

# Reverse geocode (GetAddresses) dobra o volume de chamadas e é o trecho mais
# lento. Desligue na primeira carga com VIAGENS_GEOCODE=0 e ligue depois.
VIAGENS_GEOCODE = os.environ.get("VIAGENS_GEOCODE", "1") not in ("0", "false", "False", "")

# Dispositivos processados por lote no modo viagens. Cada lote é buscado,
# geocodificado, gravado (upsert) e descartado antes do próximo — mantém o pico
# de memória limitado a um lote (essencial no free tier do Render, 512 MB).
VIAGENS_DEVICE_LOTE = int(os.environ.get("VIAGENS_DEVICE_LOTE", 25))

# Lookback (dias) para semear o ponto/hodômetro de PARTIDA da 1ª viagem de cada
# device na janela. O Trip não traz coord de início — ela é o stopPoint da viagem
# anterior; para a 1ª viagem da janela, buscamos a última viagem nos N dias que a
# antecedem. 0 desliga o seed (a 1ª viagem fica sem endereço de partida).
VIAGENS_SEED_DIAS = int(os.environ.get("VIAGENS_SEED_DIAS", 30))


def _coord(ponto):
    """Extrai (lat, lon) de um StopPoint/Coordinate da Geotab (x=lon, y=lat)."""
    if not isinstance(ponto, dict):
        return None, None
    return ponto.get("y"), ponto.get("x")


def _duracao_para_segundos(valor):
    """Converte drivingDuration ('PT1H30M', 'HH:MM:SS', ticks .NET ou número) → segundos."""
    if valor in (None, ""):
        return 0
    try:
        td = pd.to_timedelta(valor)
        if not pd.isna(td):
            return int(td.total_seconds())
    except Exception:
        pass
    try:
        n = float(valor)
        return int(n / 1e7) if n > 1e7 else int(n)
    except Exception:
        return 0


def _buscar_pontos_anteriores(credentials, chunk_ids, data_inicio, lookback_dias):
    """Para cada device, busca a ÚLTIMA viagem nos 'lookback_dias' que antecedem
    data_inicio e devolve {did: {"coord": (lat, lon), "odo": km}}.

    Serve para semear o ponto/hodômetro de partida da 1ª viagem da janela — que,
    no modelo da Geotab, é a chegada (stopPoint) da viagem imediatamente anterior.
    Devices sem viagem no período ficam fora do mapa (partida indefinida, como antes)."""
    if lookback_dias <= 0:
        return {}
    desde = data_inicio - timedelta(days=lookback_dias)
    resultados = multicall(credentials, [
        {
            "method": "Get",
            "params": {
                "typeName": "Trip",
                "search": {
                    "deviceSearch": {"id": did},
                    "fromDate": desde.strftime(FMT),
                    "toDate":   data_inicio.strftime(FMT),
                },
            },
        }
        for did in chunk_ids
    ])
    seeds = {}
    for j, resultado in enumerate(resultados):
        did = chunk_ids[j]
        raw = resultado if isinstance(resultado, list) else (resultado or {}).get("result", [])
        viagens = [v for v in raw if isinstance(v, dict) and v.get("start")]
        if not viagens:
            continue
        anterior = max(viagens, key=lambda v: v.get("start") or "")
        lat, lon = _coord(anterior.get("stopPoint"))
        if not (lat and lon):
            continue
        odo_m = anterior.get("odometer") or 0
        seeds[did] = {
            "coord": (lat, lon),
            "odo":   round(odo_m / 1000, 2) if odo_m else None,
        }
    del resultados
    return seeds


def reverse_geocode(credentials, coordenadas):
    """Converte uma lista de (lat, lon) em endereços via GetAddresses.
    Usa _post_geotab — corpo vazio/não-JSON nunca derruba o sync; apenas
    deixa o endereço em branco. Coordenadas (0,0)/None são puladas."""
    enderecos = [""] * len(coordenadas)
    pedidos, indices = [], []
    for i, (lat, lon) in enumerate(coordenadas):
        if lat in (None, 0) or lon in (None, 0):
            continue
        pedidos.append({"x": lon, "y": lat})
        indices.append(i)
    if not pedidos:
        return enderecos

    LOTE = 100
    total_lotes = (len(pedidos) + LOTE - 1) // LOTE
    for n, ini in enumerate(range(0, len(pedidos), LOTE), start=1):
        sub_pedidos = pedidos[ini:ini + LOTE]
        sub_indices = indices[ini:ini + LOTE]
        log.info(f"    → geocode lote {n}/{total_lotes} ({len(sub_pedidos)} coords)")
        resp = _post_geotab(
            "GetAddresses",
            {
                "credentials": credentials,
                "coordinates": sub_pedidos,
                "movingAddresses": True,
            },
            contexto=f"(geocode lote {ini})",
        )
        if "error" in resp:
            continue  # mantém endereços em branco neste lote, segue adiante
        for j, addr in enumerate(resp.get("result", []) or []):
            if j < len(sub_indices):
                enderecos[sub_indices[j]] = (addr or {}).get("formattedAddress", "")
    return enderecos


# Casas decimais p/ deduplicar coordenadas no cache de endereços. 3 ≈ 110 m
# (paradas próximas viram um ponto), o que torna o geocode viável: ~83k coords
# distintas em vez de ~1,4M trip-a-trip. Aumente p/ 4 (~11 m) se precisar de mais
# precisão (mais chamadas/tempo). O JOIN nas views usa a MESMA arredondamento.
GEOCODE_CASAS = int(os.environ.get("GEOCODE_CASAS", 3))


def geocodificar_enderecos(credentials, engine, casas=None, bloco=5000):
    """Backfill INCREMENTAL do cache tb_enderecos (coord arredondada → endereço).

    Geocodifica só as coordenadas distintas (partida+chegada de tb_viagens,
    arredondadas a `casas` decimais) que ainda NÃO estão em tb_enderecos. As views
    de viagens trazem o endereço por JOIN nessa tabela, então o texto não infla
    tb_viagens. Idempotente/resumível: cada execução cobre apenas o que falta;
    persiste em blocos para não perder progresso se cair no meio."""
    casas = GEOCODE_CASAS if casas is None else casas

    def _pendentes():
        with engine.connect() as conn:
            return conn.execute(text(f"""
                WITH coords AS (
                    SELECT round(lat_partida::numeric, {casas}) la,
                           round(lon_partida::numeric, {casas}) lo
                      FROM tb_viagens WHERE lat_partida <> 0 AND lon_partida <> 0
                    UNION
                    SELECT round(lat_chegada::numeric, {casas}),
                           round(lon_chegada::numeric, {casas})
                      FROM tb_viagens WHERE lat_chegada <> 0 AND lon_chegada <> 0
                )
                SELECT c.la, c.lo
                  FROM coords c
                  LEFT JOIN tb_enderecos e ON e.lat = c.la AND e.lon = c.lo
                 WHERE e.lat IS NULL
            """)).all()

    pendentes = _com_retry(_pendentes)
    if not pendentes:
        log.info("  • Geocode: tb_enderecos já em dia (nada pendente).")
        return
    log.info(f"  • Geocode: {len(pendentes):,} coordenadas distintas pendentes "
             f"(arredondadas a {casas} casas decimais).")

    total = 0
    for i in range(0, len(pendentes), bloco):
        sub    = pendentes[i:i + bloco]
        # API quer floats; o cache guarda os Decimals arredondados (casam no JOIN).
        coords = [(float(la), float(lo)) for la, lo in sub]
        addrs  = reverse_geocode(credentials, coords)
        df = pd.DataFrame([
            {"lat": la, "lon": lo, "endereco": a}
            for (la, lo), a in zip(sub, addrs)
        ])

        def _grava():
            with engine.begin() as conn:
                df.to_sql("tmp_enderecos", conn, if_exists="replace", index=False, chunksize=2000)
                # lat/lon chegam como TEXT na tmp (Decimal vira object/text no to_sql);
                # cast explícito p/ numeric — Postgres não faz text→numeric implícito.
                conn.execute(text("""
                    INSERT INTO tb_enderecos (lat, lon, endereco)
                    SELECT lat::numeric, lon::numeric, endereco FROM tmp_enderecos
                    ON CONFLICT (lat, lon) DO UPDATE SET endereco = EXCLUDED.endereco
                """))
                conn.execute(text("DROP TABLE IF EXISTS tmp_enderecos"))

        _com_retry(_grava)
        total += len(df)
        log.info(f"    → {total:,}/{len(pendentes):,} endereços no cache")
        gc.collect()

    log.info(f"  ✓ Geocode concluído: +{total:,} endereços em tb_enderecos.")


def _montar_viagem_row(v, did, info_motoristas, odo_anterior, coord_anterior):
    """Monta a row de UMA viagem e devolve
    (row, lat_p, lon_p, lat_c, lon_c, novo_odo_anterior, novo_coord_anterior).
    Mantém a continuidade do hodômetro via odo_anterior e do ponto de partida via
    coord_anterior — ambos encadeados por device.

    O objeto Trip da Geotab NÃO traz coordenada de início; só o stopPoint (chegada).
    O ponto de partida de uma viagem é, portanto, o stopPoint da viagem anterior do
    mesmo device (as viagens chegam ordenadas por start)."""
    start = v.get("start")
    stop  = v.get("stop")

    odo_final_m = v.get("odometer") or 0
    odo_final   = round(odo_final_m / 1000, 2) if odo_final_m else None
    dist        = round(float(v.get("distance") or 0), 2)

    if odo_anterior is not None:
        odo_inicial = odo_anterior
    elif odo_final is not None:
        odo_inicial = round(odo_final - dist, 2)
    else:
        odo_inicial = None
    if odo_final is not None:
        odo_anterior = odo_final

    drv    = v.get("driver")
    drv_id = drv.get("id") if isinstance(drv, dict) else (drv if isinstance(drv, str) else "")
    mot    = info_motoristas.get(drv_id, {})

    # Chegada = stopPoint desta viagem. Partida = chegada da viagem anterior
    # (Trip não traz coord de início). Na 1ª viagem do device, partida fica indefinida.
    lat_c, lon_c = _coord(v.get("stopPoint"))
    lat_p, lon_p = coord_anterior if coord_anterior else (None, None)

    # placa/veiculo/grupo/todos_grupos NÃO são gravados aqui — são derivados de
    # tb_cadastro (por device_id) nas views, evitando repetir ~190 MB de texto por
    # todas as viagens (o free tier do Supabase não comporta). Ver views *_viagens.
    row = {
        "id":                  f"{did}|{start}",
        "device_id":           did,
        "data_partida":        ts_brt(start),
        "data_chegada":        ts_brt(stop),
        "duracao_segundos":    _duracao_para_segundos(v.get("drivingDuration")),
        "distancia_km":        dist,
        "hodometro_inicial":   odo_inicial,
        "hodometro_final":     odo_final,
        "velocidade_media":    round(float(v.get("averageSpeed") or 0), 1),
        "velocidade_maxima":   round(float(v.get("maximumSpeed") or 0), 1),
        "end_partida":         "",
        "end_chegada":         "",
        "lat_partida":         lat_p or 0,
        "lon_partida":         lon_p or 0,
        "lat_chegada":         lat_c or 0,
        "lon_chegada":         lon_c or 0,
        "motorista_id":        drv_id,
        "motorista_nome":      mot.get("nome", "Nenhum"),
        "motorista_matricula": mot.get("matricula", ""),
        "atualizado_em":       agora_brt(),
    }
    novo_coord_anterior = (lat_c, lon_c) if (lat_c and lon_c) else coord_anterior
    return row, lat_p, lon_p, lat_c, lon_c, odo_anterior, novo_coord_anterior


def sincronizar_viagens(credentials, engine):
    """Extrai e grava viagens (Trips) dos últimos VIAGENS_DIAS dias em LOTES de
    dispositivos. Cada lote é buscado, geocodificado, gravado (upsert por id) e
    descartado antes do próximo — o pico de memória fica limitado a um lote, não
    à frota inteira (essencial no free tier do Render, 512 MB).

    Roda APENAS no modo 'viagens' (não faz parte do 'all'). Geocode controlado
    por VIAGENS_GEOCODE. Retorna o total de viagens gravadas.

    A continuidade do hodômetro é preservada porque cada device é processado por
    inteiro dentro de um único lote (odo_anterior encadeia as viagens do device)."""
    periodo = f"{VIAGENS_DIAS} dias" if VIAGENS_DIAS > 0 else "ano corrente"
    log.info(
        f"Extraindo viagens ({periodo}, geocode={'on' if VIAGENS_GEOCODE else 'off'}, "
        f"lote={VIAGENS_DEVICE_LOTE} devices)..."
    )

    # Só precisamos dos IDs dos devices: placa/veículo/grupo/todos_grupos vêm de
    # tb_cadastro via JOIN nas views, não são mais gravados por viagem. (Antes este
    # bloco buscava Group e montava maps de texto p/ cada device — desnecessário.)
    veiculos  = geotab_get(credentials, "Device")
    lista_ids = [v.get("id") for v in veiculos]
    del veiculos

    data_fim = agora_brt()
    if VIAGENS_DIAS > 0:
        data_inicio = data_fim - timedelta(days=VIAGENS_DIAS)
    else:
        # Ano corrente: de 1º de janeiro às 00:00 até agora.
        data_inicio = data_fim.replace(month=1, day=1, hour=0, minute=0, second=0, microsecond=0)
    log.info(f"  • Janela: {data_inicio:%Y-%m-%d %H:%M} → {data_fim:%Y-%m-%d %H:%M}")

    total_lotes    = (len(lista_ids) + VIAGENS_DEVICE_LOTE - 1) // VIAGENS_DEVICE_LOTE
    total_gravadas = 0

    for n, ini in enumerate(range(0, len(lista_ids), VIAGENS_DEVICE_LOTE), start=1):
        chunk_ids = lista_ids[ini:ini + VIAGENS_DEVICE_LOTE]
        log.info(f"  • Lote {n}/{total_lotes} — {len(chunk_ids)} dispositivos")

        resultados = multicall(credentials, [
            {
                "method": "Get",
                "params": {
                    "typeName": "Trip",
                    "search": {
                        "deviceSearch": {"id": did},
                        "fromDate": data_inicio.strftime(FMT),
                        "toDate":   data_fim.strftime(FMT),
                    },
                },
            }
            for did in chunk_ids
        ])

        driver_ids = set()
        viagens_por_device = {}
        for j, resultado in enumerate(resultados):
            did = chunk_ids[j]
            raw = resultado if isinstance(resultado, list) else (resultado or {}).get("result", [])
            viagens = [v for v in raw if isinstance(v, dict)]
            viagens.sort(key=lambda v: v.get("start") or "")
            viagens_por_device[did] = viagens
            for v in viagens:
                drv = v.get("driver")
                if isinstance(drv, dict) and drv.get("id"):
                    driver_ids.add(drv["id"])
                elif isinstance(drv, str) and drv not in ("NoDriver", "UnknownDriverId"):
                    driver_ids.add(drv)
        del resultados

        info_motoristas = {}
        if driver_ids:
            for res in multicall(credentials, [
                {"method": "Get", "params": {"typeName": "User", "search": {"id": did}}}
                for did in driver_ids
            ]):
                usuarios = res if isinstance(res, list) else (res or {}).get("result", [])
                if usuarios:
                    u = usuarios[0]
                    info_motoristas[u.get("id")] = {
                        "nome":      u.get("name", "Desconhecido"),
                        "matricula": u.get("employeeNo", ""),
                    }

        # Semeia partida/hodômetro da 1ª viagem de cada device com a viagem
        # imediatamente anterior à janela (stopPoint = ponto de partida).
        seeds = _buscar_pontos_anteriores(
            credentials, chunk_ids, data_inicio, VIAGENS_SEED_DIAS
        )

        # Coords (lat/lon) já vão dentro de cada row → tb_viagens. O endereço NÃO
        # é geocodificado por viagem aqui (era o gargalo, dias de execução); é
        # resolvido depois, deduplicado, em tb_enderecos (ver geocodificar_enderecos).
        rows = []
        for did in chunk_ids:
            seed = seeds.get(did, {})
            odo_anterior = seed.get("odo")
            coord_anterior = seed.get("coord")
            for v in viagens_por_device.get(did, []):
                if not v.get("start"):
                    continue
                row, lat_p, lon_p, lat_c, lon_c, odo_anterior, coord_anterior = _montar_viagem_row(
                    v, did, info_motoristas, odo_anterior, coord_anterior
                )
                rows.append(row)
        del viagens_por_device, info_motoristas, seeds

        if rows:
            gravar_tabela(pd.DataFrame(rows), "tb_viagens", engine, chave_upsert="id")
            total_gravadas += len(rows)
        del rows
        gc.collect()

    # Janela móvel: o upsert por id NUNCA apaga, então sem esta poda a tabela
    # cresceria a cada execução (a janela desliza, adiciona um dia novo e mantém
    # os antigos) e reencheria o free tier do Supabase. Só poda quando há janela
    # (VIAGENS_DIAS > 0); no modo ano-corrente (=0) mantém tudo da janela.
    if VIAGENS_DIAS > 0:
        def _podar():
            with engine.begin() as conn:
                r = conn.execute(
                    text("DELETE FROM tb_viagens WHERE data_partida < :ini"),
                    {"ini": data_inicio},
                )
                return r.rowcount
        apagadas = _com_retry(_podar)
        log.info(f"  ✓ {apagadas} viagens fora da janela (< {data_inicio:%Y-%m-%d}) removidas.")

    # Geocode incremental e deduplicado: preenche tb_enderecos com as coordenadas
    # ainda não conhecidas. O relatório traz o endereço por JOIN, sem inflar
    # tb_viagens. Controlado por VIAGENS_GEOCODE (off = pula).
    if VIAGENS_GEOCODE:
        geocodificar_enderecos(credentials, engine)

    # Atualiza o MÊS CORRENTE do agregado mensal a partir de tb_viagens (sem nova
    # chamada Geotab). Meses passados ficam congelados (preenchidos uma vez por
    # backfill_resumo_mensal). É o que mantém vw_indicadores_mensal vivo no dia a dia.
    atualizar_resumo_mes_corrente(engine)

    log.info(f"  → {total_gravadas} viagens gravadas em tb_viagens")
    return total_gravadas


def _upsert_resumo_mensal(engine, agg):
    """Grava/atualiza tb_resumo_mensal a partir de agg
    {(device_id, ano, mes): {'km', 'dur', 'dias'(set), 'viagens'}}."""
    if not agg:
        log.info("  • Resumo mensal: nada a agregar.")
        return
    df = pd.DataFrame([
        {"device_id": did, "ano": ano, "mes": mes,
         "km": round(b["km"], 2), "duracao_segundos": int(b["dur"]),
         "dias_utilizados": len(b["dias"]), "viagens": b["viagens"],
         "atualizado_em": agora_brt()}
        for (did, ano, mes), b in agg.items()
    ])

    def _exec():
        with engine.begin() as conn:
            df.to_sql("tmp_resumo_mensal", conn, if_exists="replace", index=False, chunksize=5000)
            conn.execute(text("""
                INSERT INTO tb_resumo_mensal
                    (device_id, ano, mes, km, duracao_segundos, dias_utilizados, viagens, atualizado_em)
                SELECT device_id, ano, mes, km, duracao_segundos, dias_utilizados, viagens, atualizado_em
                FROM tmp_resumo_mensal
                ON CONFLICT (device_id, ano, mes) DO UPDATE SET
                    km=EXCLUDED.km, duracao_segundos=EXCLUDED.duracao_segundos,
                    dias_utilizados=EXCLUDED.dias_utilizados, viagens=EXCLUDED.viagens,
                    atualizado_em=EXCLUDED.atualizado_em
            """))
            conn.execute(text("DROP TABLE IF EXISTS tmp_resumo_mensal"))

    _com_retry(_exec)
    log.info(f"  ✓ resumo mensal: {len(df)} linhas (device×mês) gravadas.")


def backfill_resumo_mensal(credentials, engine, data_inicio, data_fim):
    """Agrega as Trips de [data_inicio, data_fim] por (device, ano, mês) e faz
    upsert em tb_resumo_mensal — SEM guardar viagens cruas. Usado p/ o backfill do
    ano (uma vez). Pesado na Geotab (busca Trips de todos os devices na janela),
    então rode isolado de outros jobs p/ não dividir a quota."""
    log.info(f"Backfill resumo mensal: {data_inicio:%Y-%m-%d} → {data_fim:%Y-%m-%d}")
    veiculos  = geotab_get(credentials, "Device")
    lista_ids = [v.get("id") for v in veiculos]
    del veiculos

    agg = {}
    LOTE = VIAGENS_DEVICE_LOTE
    total_lotes = (len(lista_ids) + LOTE - 1) // LOTE
    for n, ini in enumerate(range(0, len(lista_ids), LOTE), start=1):
        chunk = lista_ids[ini:ini + LOTE]
        resultados = multicall(credentials, [
            {"method": "Get", "params": {"typeName": "Trip", "search": {
                "deviceSearch": {"id": did},
                "fromDate": data_inicio.strftime(FMT),
                "toDate":   data_fim.strftime(FMT)}}}
            for did in chunk
        ])
        for j, resultado in enumerate(resultados):
            did = chunk[j]
            raw = resultado if isinstance(resultado, list) else (resultado or {}).get("result", [])
            for v in raw:
                if not isinstance(v, dict) or not v.get("start"):
                    continue
                ts = ts_brt(v.get("start"))
                if pd.isna(ts):
                    continue
                k = (did, ts.year, ts.month)
                b = agg.get(k)
                if b is None:
                    b = agg[k] = {"km": 0.0, "dur": 0, "dias": set(), "viagens": 0}
                b["km"]      += float(v.get("distance") or 0)
                b["dur"]     += _duracao_para_segundos(v.get("drivingDuration"))
                b["dias"].add(ts.date())
                b["viagens"] += 1
        del resultados
        if n % 10 == 0 or n == total_lotes:
            log.info(f"  • backfill mensal: lote {n}/{total_lotes} ({len(agg)} device×mês até agora)")
        gc.collect()

    _upsert_resumo_mensal(engine, agg)
    log.info(f"  → backfill resumo mensal concluído ({len(agg)} device×mês).")


def atualizar_resumo_mes_corrente(engine):
    """Recalcula SÓ o mês corrente de tb_resumo_mensal a partir de tb_viagens (já
    no banco — sem nova chamada Geotab). Mantém o mês vigente fresco a cada sync;
    meses anteriores ficam congelados (vieram do backfill)."""
    def _exec():
        with engine.begin() as conn:
            conn.execute(text("""
                INSERT INTO tb_resumo_mensal
                    (device_id, ano, mes, km, duracao_segundos, dias_utilizados, viagens, atualizado_em)
                SELECT device_id,
                       EXTRACT(year  FROM data_partida)::int,
                       EXTRACT(month FROM data_partida)::int,
                       round(sum(distancia_km)::numeric, 2)::float8,
                       sum(duracao_segundos)::bigint,
                       count(DISTINCT data_partida::date),
                       count(*),
                       :agora
                  FROM tb_viagens
                 WHERE data_partida >= date_trunc('month', CURRENT_DATE)
                 GROUP BY device_id,
                       EXTRACT(year FROM data_partida),
                       EXTRACT(month FROM data_partida)
                ON CONFLICT (device_id, ano, mes) DO UPDATE SET
                    km=EXCLUDED.km, duracao_segundos=EXCLUDED.duracao_segundos,
                    dias_utilizados=EXCLUDED.dias_utilizados, viagens=EXCLUDED.viagens,
                    atualizado_em=EXCLUDED.atualizado_em
            """), {"agora": agora_brt()})
    _com_retry(_exec)
    log.info("  ✓ resumo mensal: mês corrente atualizado de tb_viagens.")


# ─────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────
def main(modo=None):
    if modo is None:
        modo = sys.argv[1] if len(sys.argv) > 1 else "all"

    log.info(f"{'='*55}")
    log.info(f"  Geotab → Supabase  |  modo: {modo}")
    log.info(f"{'='*55}")

    engine = criar_engine()
    criar_tabelas(engine)

    credentials = autenticar()
    log.info("  ✓ Autenticado no Geotab\n")

    try:
        if modo in ("all", "cadastro"):
            df = extrair_cadastro(credentials)
            gravar_tabela(df, "tb_cadastro", engine, chave_upsert="id")
            del df
            gc.collect()

        if modo in ("all", "status"):
            df = extrair_status(credentials)
            gravar_tabela(df, "tb_status", engine, chave_upsert="id")
            del df
            gc.collect()

        if modo in ("all", "comportamento"):
            sincronizar_comportamento(credentials, engine)
            gc.collect()

        # IMPORTANTE: viagens NÃO entra no 'all' — só roda no modo explícito.
        # É o trecho mais pesado (Trips por device + geocode) e travava o 'all'.
        # sincronizar_viagens já grava em lotes e libera memória a cada lote.
        if modo == "viagens":
            sincronizar_viagens(credentials, engine)

    finally:
        engine.dispose()

    log.info("\n✅ Sincronização concluída.")


if __name__ == "__main__":
    main()