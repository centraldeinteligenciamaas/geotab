import os
import sys
import time
import logging
import unicodedata
import requests
import pandas as pd
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
from dotenv import load_dotenv
from sqlalchemy import create_engine, text
from sqlalchemy.engine.url import URL

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
    # pool_size=1: syncs rodam sequencialmente (lock no app.py) — não há concorrência.
    # pool_pre_ping detecta conexões mortas após períodos de inatividade no servidor.
    return create_engine(
        url,
        pool_pre_ping=True,
        pool_size=1,
        max_overflow=0,
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
            df.to_sql(temp, conn, if_exists="replace", index=False)

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


def _post_geotab(method, params, contexto=""):
    """POST único e blindado para a API Geotab.
    - Trata corpo vazio / não-JSON sem estourar JSONDecodeError.
    - Loga status HTTP e início do corpo quando o parse falha.
    Retorna o dict da resposta JSON-RPC ({"result": ...} ou {"error": ...}),
    ou {"error": {...}} sintético em caso de falha de rede/parse."""
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
        return r.json()
    except ValueError:
        log.warning(
            f"  ⚠ {method} {contexto}: resposta não-JSON (HTTP {r.status_code}). "
            f"Início do corpo: {corpo[:120]!r}"
        )
        return {"error": {"message": "resposta não-JSON", "httpStatus": r.status_code}}


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


def multicall_em_lotes(credentials, chamadas, lote=150):
    """Divide um multicall grande em lotes para evitar timeout/disconnect no servidor."""
    resultados = []
    for i in range(0, len(chamadas), lote):
        resultados.extend(multicall(credentials, chamadas[i:i + lote]))
    return resultados


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
        for did in lista_ids
    ])

    motoristas_ativos = {}
    driver_ids = set()
    for i, resultado in enumerate(res_viagens):
        did     = lista_ids[i]
        viagens = resultado if isinstance(resultado, list) else resultado.get("result", [])
        viagem  = next((v for v in viagens if not v.get("stop")), None)
        if viagem and viagem.get("driver", {}).get("id"):
            motoristas_ativos[did] = {
                "driver_id":     viagem["driver"]["id"],
                "viagem_inicio": viagem.get("start"),
            }
            driver_ids.add(viagem["driver"]["id"])

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


def _consultar_diag(credentials, lista_ids, diag_id, ini, fim):
    return multicall_em_lotes(credentials, [
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
        for did in lista_ids
    ])


def _max_por_device(resultados, lista_ids):
    """Extrai o valor máximo bruto (sem conversão) por device."""
    mapa = {}
    for i, resultado in enumerate(resultados):
        did      = lista_ids[i]
        leituras = resultado if isinstance(resultado, list) else resultado.get("result", [])
        mapa[did] = max((r.get("data") or 0 for r in leituras), default=0)
    return mapa


def _com_fallback_ano(credentials, lista_ids, diag_id, data_inicio, mapa_raw):
    """Para devices sem leitura nos 30 dias, busca no ano anterior."""
    sem_dado = [did for did, v in mapa_raw.items() if not v]
    if not sem_dado:
        return
    um_ano = data_inicio - timedelta(days=365)
    res2   = _consultar_diag(credentials, sem_dado, diag_id, um_ano, data_inicio)
    for i, resultado in enumerate(res2):
        did      = sem_dado[i]
        leituras = resultado if isinstance(resultado, list) else resultado.get("result", [])
        v = max((r.get("data") or 0 for r in leituras), default=0)
        if v:
            mapa_raw[did] = v
    recuperados = sum(1 for did in sem_dado if mapa_raw[did])
    log.info(f"    → {recuperados}/{len(sem_dado)} recuperados no fallback 1 ano")


def buscar_odo_gps(credentials, lista_ids, data_inicio, data_fim):
    """Retorna {device_id: km} via GPS (DiagnosticDeviceTotalDistanceId).
    Valores sempre em metros → divide por 1000."""
    log.info(f"  • GPS odômetro via '{DIAG_GPS}'...")
    resultados = _consultar_diag(credentials, lista_ids, DIAG_GPS, data_inicio, data_fim)
    mapa_raw   = _max_por_device(resultados, lista_ids)
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
        resultados = _consultar_diag(credentials, lista_ids, diag_id, data_inicio, data_fim)
        mapa_raw   = _max_por_device(resultados, lista_ids)
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
    janelas     = [
        (data_inicio + timedelta(days=i), data_inicio + timedelta(days=i + 1))
        for i in range(0, 30)
    ]

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

    LIMIT = 50000

    def buscar_eventos(credentials, rid, ini, fim):
        eventos = geotab_get(
            credentials, "ExceptionEvent",
            search={
                "ruleSearch": {"id": rid},
                "fromDate": ini.strftime(FMT),
                "toDate":   fim.strftime(FMT),
            },
            resultsLimit=LIMIT,
        )
        if len(eventos) >= LIMIT:
            log.warning(
                f"  ⚠ Limite {LIMIT} atingido na janela {ini.date()}–{fim.date()} "
                f"(regra {rid}) — contagem pode estar incompleta"
            )
        return eventos

    # Velocidade (todas as regras, todas as janelas)
    total_vel, contados_vel, ignorados_vel = 0, 0, 0
    for rid in ids_velocidade:
        for ini, fim in janelas:
            eventos = buscar_eventos(credentials, rid, ini, fim)
            total_vel += len(eventos)
            c, i = processar_eventos(eventos, "excesso_velocidade", "ultimo_excesso")
            contados_vel += c
            ignorados_vel += i
    log.info(f"  • excesso_velocidade: {total_vel} eventos ({contados_vel} atribuídos, {ignorados_vel} sem match)")

    # Demais tipos
    for tipo, rid in regras_simples.items():
        if not rid:
            log.warning(f"  • Regra '{tipo}' não encontrada — pulando")
            continue
        total, contados_total, ignorados_total = 0, 0, 0
        for ini, fim in janelas:
            eventos = buscar_eventos(credentials, rid, ini, fim)
            total += len(eventos)
            c, i = processar_eventos(eventos, tipo, CAMPO_ULTIMO[tipo])
            contados_total += c
            ignorados_total += i
        log.info(f"  • {tipo}: {total} eventos ({contados_total} atribuídos, {ignorados_total} sem match)")

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
# Janela de extração. Na PRIMEIRA carga use algo pequeno (ex.: VIAGENS_DIAS=7)
# para validar rápido; depois aumente.
VIAGENS_DIAS = int(os.environ.get("VIAGENS_DIAS", 30))

# Reverse geocode (GetAddresses) dobra o volume de chamadas e é o trecho mais
# lento. Desligue na primeira carga com VIAGENS_GEOCODE=0 e ligue depois.
VIAGENS_GEOCODE = os.environ.get("VIAGENS_GEOCODE", "1") not in ("0", "false", "False", "")


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


def extrair_viagens(credentials):
    """Uma linha por viagem (Trip) dos últimos VIAGENS_DIAS dias — base do
    Relatório de Viagem: partida/chegada, distância, hodômetro, velocidade,
    endereços e motorista (nome + matrícula).

    Roda APENAS no modo 'viagens' (não faz parte do 'all') — é o trecho mais
    pesado do pipeline. Geocode controlado por VIAGENS_GEOCODE."""
    log.info(f"Extraindo viagens dos últimos {VIAGENS_DIAS} dias (geocode={'on' if VIAGENS_GEOCODE else 'off'})...")

    veiculos   = geotab_get(credentials, "Device")
    lista_ids  = [v.get("id") for v in veiculos]
    serial_map = {v.get("id"): v.get("serialNumber", "") for v in veiculos}
    placa_map  = {v.get("id"): v.get("licensePlate", "") for v in veiculos}
    nome_map   = {v.get("id"): v.get("name", "")          for v in veiculos}
    log.info(f"  • {len(lista_ids)} dispositivos — buscando Trips em lotes...")

    grupos = {g.get("id"): g.get("name", "") for g in geotab_get(credentials, "Group")}
    grupo_map, grupos_todos_map = {}, {}
    for v in veiculos:
        gnomes = [grupos.get(g.get("id"), g.get("id")) for g in v.get("groups", [])]
        grupo_map[v.get("id")]        = gnomes[-1] if gnomes else ""
        grupos_todos_map[v.get("id")] = " | ".join(gnomes)

    data_fim    = agora_brt()
    data_inicio = data_fim - timedelta(days=VIAGENS_DIAS)

    resultados = multicall_em_lotes(credentials, [
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
        for did in lista_ids
    ])

    driver_ids = set()
    viagens_por_device = {}
    for i, resultado in enumerate(resultados):
        did = lista_ids[i]
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

    total_viagens = sum(len(v) for v in viagens_por_device.values())
    log.info(f"  • {total_viagens} viagens brutas / {len(driver_ids)} motoristas distintos")

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
                    "nome":      u.get("name", "Desconhecido"),
                    "matricula": u.get("employeeNo", ""),
                }

    rows, coords_partida, coords_chegada = [], [], []
    for did in lista_ids:
        odo_anterior = None
        for v in viagens_por_device.get(did, []):
            start = v.get("start")
            if not start:
                continue
            stop = v.get("stop")

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

            drv = v.get("driver")
            drv_id = drv.get("id") if isinstance(drv, dict) else (drv if isinstance(drv, str) else "")
            mot = info_motoristas.get(drv_id, {})

            lat_p, lon_p = v.get("latitude"), v.get("longitude")
            lat_c, lon_c = _coord(v.get("stopPoint"))
            coords_partida.append((lat_p, lon_p))
            coords_chegada.append((lat_c, lon_c))

            rows.append({
                "id":                  f"{did}|{start}",
                "device_id":           did,
                "serial":              serial_map.get(did, ""),
                "placa":               placa_map.get(did, ""),
                "veiculo":             nome_map.get(did, ""),
                "grupo":               grupo_map.get(did, ""),
                "todos_grupos":        grupos_todos_map.get(did, ""),
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
            })

    if VIAGENS_GEOCODE:
        log.info(f"  • Geocodificando {len(rows)} viagens (partida + chegada)...")
        end_partida = reverse_geocode(credentials, coords_partida)
        end_chegada = reverse_geocode(credentials, coords_chegada)
        for i, r in enumerate(rows):
            r["end_partida"] = end_partida[i] if i < len(end_partida) else ""
            r["end_chegada"] = end_chegada[i] if i < len(end_chegada) else ""
    else:
        log.info("  • Geocode DESLIGADO (VIAGENS_GEOCODE=0) — endereços em branco")

    df = pd.DataFrame(rows)
    log.info(f"  → {len(df)} viagens extraídas")
    return df


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

        if modo in ("all", "status"):
            df = extrair_status(credentials)
            gravar_tabela(df, "tb_status", engine, chave_upsert="id")

        if modo in ("all", "comportamento"):
            df = extrair_comportamento(credentials)
            gravar_tabela(df, "tb_comportamento", engine, chave_upsert="id")

        # IMPORTANTE: viagens NÃO entra no 'all' — só roda no modo explícito.
        # É o trecho mais pesado (Trips por device + geocode) e travava o 'all'.
        if modo == "viagens":
            df = extrair_viagens(credentials)
            gravar_tabela(df, "tb_viagens", engine, chave_upsert="id")

    finally:
        engine.dispose()

    log.info("\n✅ Sincronização concluída.")


if __name__ == "__main__":
    main()