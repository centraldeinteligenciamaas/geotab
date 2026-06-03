import os
import gc
import sys
import time
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
            excessos_velocidade_30d  INTEGER,
            aceleracoes_bruscas_30d  INTEGER,
            frenagens_bruscas_30d    INTEGER,
            curvas_drasticas_30d     INTEGER,
            ultimo_excesso_vel       TIMESTAMP,
            ultima_acel_brusca       TIMESTAMP,
            ultima_fren_brusca       TIMESTAMP,
            ultima_curva_drastica    TIMESTAMP,
            score_risco              INTEGER,
            odometro                 DOUBLE PRECISION,
            odometro_gps             DOUBLE PRECISION,
            atualizado_em            TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS tb_viagens (
            id                  TEXT PRIMARY KEY,   -- device_id + '|' + start
            device_id           TEXT,
            serial              TEXT,
            placa               TEXT,
            veiculo             TEXT,
            grupo               TEXT,
            regional            TEXT,
            superintendencia    TEXT,
            todos_grupos        TEXT,
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
            ADD COLUMN IF NOT EXISTS motorista_matricula TEXT;
        ALTER TABLE tb_viagens
            ADD COLUMN IF NOT EXISTS regional         TEXT,
            ADD COLUMN IF NOT EXISTS superintendencia TEXT;
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


def _post_geotab(method, params, contexto=""):
    """POST único e blindado para a API Geotab.
    - Pacing proativo de quota + retry reativo em OverLimitException.
    - Trata corpo vazio / não-JSON sem estourar JSONDecodeError.
    - Loga status HTTP e início do corpo quando o parse falha.
    Retorna o dict da resposta JSON-RPC ({"result": ...} ou {"error": ...}),
    ou {"error": {...}} sintético em caso de falha de rede/parse."""
    unidades = len(params.get("calls", [])) if method == "ExecuteMultiCall" else 1

    resp = None
    for tentativa in range(1, QUOTA_RETRY + 2):
        _consumir_quota(unidades)
        try:
            r = requests.post(
                GEOTAB["servidor"],
                json={"method": method, "params": params},
                timeout=180,
            )
        except Exception as exc:
            log.warning(f"  ⚠ Falha de rede em {method} {contexto}: {exc}")
            return {"error": {"message": str(exc)}}

        corpo = (r.text or "").strip()
        if not corpo:
            log.warning(f"  ⚠ {method} {contexto} retornou corpo VAZIO (HTTP {r.status_code}).")
            return {"error": {"message": "corpo vazio", "httpStatus": r.status_code}}
        try:
            resp = r.json()
        except ValueError:
            log.warning(
                f"  ⚠ {method} {contexto}: resposta não-JSON (HTTP {r.status_code}). "
                f"Início do corpo: {corpo[:120]!r}"
            )
            return {"error": {"message": "resposta não-JSON", "httpStatus": r.status_code}}

        if _eh_erro_quota(resp) and tentativa <= QUOTA_RETRY:
            espera = QUOTA_PAUSA * tentativa  # 12, 24, 36...
            log.warning(
                f"  ⏳ Quota excedida em {method} {contexto} — aguardando {espera}s "
                f"(retry {tentativa}/{QUOTA_RETRY})"
            )
            time.sleep(espera)
            continue
        return resp

    return resp


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
        log.error(f"Falha na autenticação Geotab: {resp['error']}")
        sys.exit(1)

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
    """Para devices sem leitura nos 30 dias, busca no ano anterior."""
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


def buscar_odo_gps(credentials, lista_ids, data_inicio, data_fim):
    """Retorna {device_id: km} via GPS (DiagnosticDeviceTotalDistanceId).
    Valores sempre em metros → divide por 1000."""
    log.info(f"  • GPS odômetro via '{DIAG_GPS}'...")
    mapa_raw = _max_diag_em_lotes(credentials, lista_ids, DIAG_GPS, data_inicio, data_fim)
    _com_fallback_ano(credentials, lista_ids, DIAG_GPS, data_inicio, mapa_raw)
    mapa_km = {did: round(v / 1000, 2) if v else 0.0 for did, v in mapa_raw.items()}
    com_dado = sum(1 for v in mapa_km.values() if v > 0)
    log.info(f"    → {com_dado}/{len(lista_ids)} veículos com dado GPS")
    return mapa_km


def buscar_odo_fisico(credentials, lista_ids, data_inicio, data_fim):
    """Retorna {device_id: km} via OBD2 (odômetro físico do veículo).
    Testa DIAG_ODO_FISICO em ordem; unidade inferida automaticamente por _inferir_km."""
    for diag_id in DIAG_ODO_FISICO:
        log.info(f"  • Odômetro físico via '{diag_id}'...")
        mapa_raw = _max_diag_em_lotes(credentials, lista_ids, diag_id, data_inicio, data_fim)
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
def extrair_comportamento(credentials):
    log.info("Extraindo eventos de comportamento (30 dias)...")

    veiculos   = geotab_get(credentials, "Device")
    lista_ids  = [v.get("id") for v in veiculos]
    serial_map = {v.get("id"): v.get("serialNumber", "") for v in veiculos}
    placa_map  = {v.get("id"): v.get("licensePlate", "") for v in veiculos}

    todas_regras = geotab_get(
        credentials, "Rule",
        search={"fromDate": "2000-01-01T00:00:00.000Z"}
    )

    # ── Mapeamento de tipos → lista de IDs de regras ────────────────────────
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

    data_fim    = agora_brt()
    data_inicio = data_fim - timedelta(days=30)

    # ── Odômetro GPS (distância acumulada pelo device desde instalação) ────────
    odo_gps_map = buscar_odo_gps(credentials, lista_ids, data_inicio, data_fim)

    # ── Odômetro físico (OBD2 — odômetro real do veículo, se disponível) ───
    odo_fisico_map = buscar_odo_fisico(credentials, lista_ids, data_inicio, data_fim)

    # ── Contadores de eventos ───────────────────────────────────────────────
    contadores = {
        did: {
            "excesso_velocidade": 0, "ultimo_excesso":    None,
            "aceleracao_brusca":  0, "ultima_aceleracao": None,
            "frenagem_brusca":    0, "ultima_frenagem":   None,
            "curva_drastica":     0, "ultima_curva":      None,
        }
        for did in lista_ids
    }
    CAMPO_ULTIMO = {
        "excesso_velocidade": "ultimo_excesso",
        "aceleracao_brusca":  "ultima_aceleracao",
        "frenagem_brusca":    "ultima_frenagem",
        "curva_drastica":     "ultima_curva",
    }

    def processar_eventos(eventos, tipo, chave_ultimo):
        contados, ignorados = 0, 0
        for ev in eventos:
            did = (
                ev["device"].get("id")
                if isinstance(ev.get("device"), dict)
                else ev.get("device")
            )
            if not did or did not in contadores:
                ignorados += 1
                continue
            contadores[did][tipo] += 1
            contados += 1
            data_ev = ev.get("activeFrom") or ev.get("dateTime")
            if data_ev:
                atual = contadores[did][chave_ultimo]
                if atual is None or data_ev > atual:
                    contadores[did][chave_ultimo] = data_ev
        return contados, ignorados

    # Teto por chamada da Geotab. Quando atingido, a janela é fracionada — assim
    # NENHUM evento é perdido (contagem completa) e cada chamada continua leve.
    LIMIT     = 50000
    MIN_JANELA = timedelta(minutes=5)  # piso do fracionamento recursivo

    def contar_regra(rid, tipo, chave_ultimo, ini, fim):
        """Conta TODOS os eventos da regra em [ini, fim].
        Se a janela satura (>= LIMIT eventos = sinal de truncamento), divide pela
        metade e recursa — garantindo a contagem completa sem nunca segurar mais
        que uma sub-janela em memória. Retorna (total, contados, ignorados)."""
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
            # Saturou: libera esta leitura e fraciona a janela pela metade.
            del eventos
            gc.collect()
            meio = ini + (fim - ini) / 2
            t1, c1, i1 = contar_regra(rid, tipo, chave_ultimo, ini, meio)
            t2, c2, i2 = contar_regra(rid, tipo, chave_ultimo, meio, fim)
            return t1 + t2, c1 + c2, i1 + i2

        if n >= LIMIT:
            log.warning(
                f"  ⚠ Janela mínima {ini:%Y-%m-%d %H:%M}–{fim:%H:%M} ainda saturada "
                f"({n} eventos, regra {rid}) — caso extremo, reduza MIN_JANELA"
            )
        c, i = processar_eventos(eventos, tipo, chave_ultimo)
        del eventos
        return n, c, i

    # Velocidade (todas as regras) — fracionamento adaptativo sobre os 30 dias.
    total_vel, contados_vel, ignorados_vel = 0, 0, 0
    for rid in ids_velocidade:
        t, c, i = contar_regra(rid, "excesso_velocidade", "ultimo_excesso", data_inicio, data_fim)
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
        t, c, i = contar_regra(rid, tipo, CAMPO_ULTIMO[tipo], data_inicio, data_fim)
        gc.collect()
        log.info(f"  • {tipo}: {t} eventos ({c} atribuídos, {i} sem match)")

    rows = []
    for did in lista_ids:
        c  = contadores[did]
        ev = c["excesso_velocidade"]
        ac = c["aceleracao_brusca"]
        fr = c["frenagem_brusca"]
        cu = c["curva_drastica"]
        rows.append({
            "id":                      did,
            "serial":                  serial_map.get(did, ""),
            "placa":                   placa_map.get(did, ""),
            "excessos_velocidade_30d": ev,
            "aceleracoes_bruscas_30d": ac,
            "frenagens_bruscas_30d":   fr,
            "curvas_drasticas_30d":    cu,
            "ultimo_excesso_vel":      ts_brt(c["ultimo_excesso"]),
            "ultima_acel_brusca":      ts_brt(c["ultima_aceleracao"]),
            "ultima_fren_brusca":      ts_brt(c["ultima_frenagem"]),
            "ultima_curva_drastica":   ts_brt(c["ultima_curva"]),
            "score_risco":             ev * 3 + ac * 2 + fr * 2 + cu * 1,
            "odometro":                odo_fisico_map.get(did, 0),
            "odometro_gps":            odo_gps_map.get(did, 0),
            "atualizado_em":           agora_brt(),
        })

    df = pd.DataFrame(rows)
    log.info(f"  → {len(df)} veículos no comportamento")
    return df


# ─────────────────────────────────────────────────────────
# TABELA 4 — VIAGENS  (base do Relatório de Viagem estilo SANEAGO)
# ─────────────────────────────────────────────────────────
# Janela de extração. Padrão = MÊS CORRENTE (do dia 1 às 00:00 até agora).
# VIAGENS_DIAS > 0 sobrescreve com uma janela móvel de N dias (útil p/ smoke test:
# ex. VIAGENS_DIAS=2). VIAGENS_DIAS=0 (padrão) → mês corrente.
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


def _montar_viagem_row(v, did, maps, info_motoristas, odo_anterior, coord_anterior):
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

    row = {
        "id":                  f"{did}|{start}",
        "device_id":           did,
        "serial":              maps["serial"].get(did, ""),
        "placa":               maps["placa"].get(did, ""),
        "veiculo":             maps["nome"].get(did, ""),
        "grupo":               maps["grupo"].get(did, ""),
        "regional":            maps["regional"].get(did, ""),
        "superintendencia":    maps["superintendencia"].get(did, ""),
        "todos_grupos":        maps["grupos_todos"].get(did, ""),
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
    periodo = f"{VIAGENS_DIAS} dias" if VIAGENS_DIAS > 0 else "mês corrente"
    log.info(
        f"Extraindo viagens ({periodo}, geocode={'on' if VIAGENS_GEOCODE else 'off'}, "
        f"lote={VIAGENS_DEVICE_LOTE} devices)..."
    )

    veiculos  = geotab_get(credentials, "Device")
    lista_ids = [v.get("id") for v in veiculos]

    grupos = {g.get("id"): g.get("name", "") for g in geotab_get(credentials, "Group")}
    maps = {
        "serial":           {v.get("id"): v.get("serialNumber", "") for v in veiculos},
        "placa":            {v.get("id"): v.get("licensePlate", "") for v in veiculos},
        "nome":             {v.get("id"): v.get("name", "")          for v in veiculos},
        "grupo":            {},
        "grupos_todos":     {},
        "regional":         {},
        "superintendencia": {},
    }
    for v in veiculos:
        gnomes = [grupos.get(g.get("id"), g.get("id")) for g in v.get("groups", [])]
        did = v.get("id")
        maps["grupo"][did]            = gnomes[-1] if gnomes else ""
        maps["grupos_todos"][did]     = " | ".join(gnomes)
        # Hierarquia SANEAGO codificada por prefixo no nome do grupo:
        # REG_ = regional, SUP_ = superintendência (guarda o nome completo do grupo).
        maps["regional"][did]         = next((g for g in gnomes if g.startswith("REG_")), "")
        maps["superintendencia"][did] = next((g for g in gnomes if g.startswith("SUP_")), "")
    del grupos, veiculos

    data_fim = agora_brt()
    if VIAGENS_DIAS > 0:
        data_inicio = data_fim - timedelta(days=VIAGENS_DIAS)
    else:
        # Mês corrente: do dia 1 às 00:00 até agora.
        data_inicio = data_fim.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
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

        rows, coords_partida, coords_chegada = [], [], []
        for did in chunk_ids:
            seed = seeds.get(did, {})
            odo_anterior = seed.get("odo")
            coord_anterior = seed.get("coord")
            for v in viagens_por_device.get(did, []):
                if not v.get("start"):
                    continue
                row, lat_p, lon_p, lat_c, lon_c, odo_anterior, coord_anterior = _montar_viagem_row(
                    v, did, maps, info_motoristas, odo_anterior, coord_anterior
                )
                rows.append(row)
                coords_partida.append((lat_p, lon_p))
                coords_chegada.append((lat_c, lon_c))
        del viagens_por_device, info_motoristas, seeds

        if rows and VIAGENS_GEOCODE:
            log.info(f"    → geocodificando {len(rows)} viagens do lote...")
            end_partida = reverse_geocode(credentials, coords_partida)
            end_chegada = reverse_geocode(credentials, coords_chegada)
            for k, r in enumerate(rows):
                r["end_partida"] = end_partida[k] if k < len(end_partida) else ""
                r["end_chegada"] = end_chegada[k] if k < len(end_chegada) else ""
            del end_partida, end_chegada
        del coords_partida, coords_chegada

        if rows:
            gravar_tabela(pd.DataFrame(rows), "tb_viagens", engine, chave_upsert="id")
            total_gravadas += len(rows)
        del rows
        gc.collect()

    log.info(f"  → {total_gravadas} viagens gravadas em tb_viagens")
    return total_gravadas


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
            df = extrair_comportamento(credentials)
            gravar_tabela(df, "tb_comportamento", engine, chave_upsert="id")
            del df
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