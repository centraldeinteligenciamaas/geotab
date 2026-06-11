import os
import threading
import logging
from datetime import datetime
from zoneinfo import ZoneInfo

from flask import Flask, jsonify, request
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger
from sqlalchemy import text

from geotab_supabase import main as sync_main, criar_engine

app = Flask(__name__)
BRT = ZoneInfo("America/Sao_Paulo")
log = logging.getLogger(__name__)

API_KEY = os.environ.get("SYNC_API_KEY", "")
_lock = threading.Lock()

_estado = {
    "em_execucao": False,
    "modo_atual":  None,
    "ultimo_erro": None,
}

# (modo, hora, minuto) — um job por tabela, 1x ao dia, seg-sex (horário BRT).
# Fonte única de verdade: usada tanto para agendar os jobs quanto para calcular
# a próxima execução exibida em /status.
AGENDA = [
    ("cadastro",      4, 0),   # 04:00 — leve
    ("status",        5, 0),   # 05:00 — leve
    ("comportamento", 6, 0),   # 06:00 — incremental (buckets 6m); 1ª vez = backfill
    ("viagens",      21, 0),   # 21:00 — mais pesado (Trips por device + geocode)
]


def _proximas_execucoes():
    """Próxima execução de cada modo, calculada a partir da AGENDA e da hora
    atual. Determinístico e independente do estado em memória do scheduler."""
    agora = datetime.now(tz=BRT)
    prox = {}
    for modo, hora, minuto in AGENDA:
        trigger = CronTrigger(hour=hora, minute=minuto, day_of_week="mon-fri", timezone=BRT)
        nxt = trigger.get_next_fire_time(None, agora)
        prox[modo] = nxt.astimezone(BRT).strftime("%Y-%m-%d %H:%M:%S") if nxt else None
    return prox


def executar_sync(modo):
    if not _lock.acquire(blocking=False):
        log.warning(f"Sync já em execução — ignorando modo={modo}")
        return
    _estado["em_execucao"] = True
    _estado["modo_atual"]  = modo
    _estado["ultimo_erro"] = None
    try:
        sync_main(modo)
    except Exception as exc:
        _estado["ultimo_erro"] = str(exc)
        log.exception(f"Erro durante sync modo={modo}")
    finally:
        _estado["em_execucao"] = False
        _estado["modo_atual"]  = None
        _lock.release()


@app.route("/")
def index():
    return jsonify({
        "service": "geotab-sync",
        "endpoints": {
            "health": "/health",
            "status": "/status",
            "run":    "/run/<modo>",
        },
        "comandos_manuais": {
            "cadastro":      "/run/cadastro",
            "status":        "/run/status",
            "comportamento": "/run/comportamento",
            "viagens":       "/run/viagens",
        },
        "obs": (
            "Rode UMA tabela por vez. NÃO use /run/all — processar tudo no mesmo "
            "processo estoura a RAM do free tier. Cada tabela tem job diário próprio "
            "em horário separado (cadastro 04h, status 05h, comportamento 06h, viagens 21h BRT)."
        ),
    })


@app.route("/health")
def health():
    return jsonify({
        "status": "ok",
        "hora_brt": datetime.now(tz=BRT).strftime("%Y-%m-%d %H:%M:%S"),
    })


@app.route("/status")
def status():
    ult = {"cadastro": None, "status": None, "comportamento": None, "viagens": None}
    try:
        engine = criar_engine()
        with engine.connect() as conn:
            ult["cadastro"]      = conn.execute(text("SELECT MAX(atualizado_em) FROM tb_cadastro")).scalar()
            ult["status"]        = conn.execute(text("SELECT MAX(snapshot_em)   FROM tb_status")).scalar()
            ult["comportamento"] = conn.execute(text("SELECT MAX(atualizado_em) FROM tb_comportamento")).scalar()
            ult["viagens"]       = conn.execute(text("SELECT MAX(atualizado_em) FROM tb_viagens")).scalar()
        engine.dispose()
    except Exception as exc:
        log.error(f"Erro ao consultar últimas atualizações: {exc}")

    # Próxima execução calculada de forma determinística a partir da AGENDA +
    # hora atual. NÃO usamos job.next_run_time porque ele vive só na memória do
    # scheduler e é perdido a cada spin-down/restart do free tier — o que fazia
    # a "próxima execução" ficar congelada num horário já passado.
    proximos = _proximas_execucoes()

    return jsonify({
        "em_execucao": _estado["em_execucao"],
        "modo_atual":  _estado["modo_atual"],
        "ultimo_erro": _estado["ultimo_erro"],
        "ultima_atualizacao_brt": {k: str(v) if v else None for k, v in ult.items()},
        "proximas_execucoes_brt": proximos,
    })


@app.route("/run/<modo>")
def run_sync(modo):
    if API_KEY:
        if request.args.get("key", "") != API_KEY:
            return jsonify({"error": "unauthorized"}), 401

    if modo not in ("all", "cadastro", "status", "comportamento", "viagens"):
        return jsonify({"error": "modo inválido — use: all, cadastro, status, comportamento, viagens"}), 400

    thread = threading.Thread(target=executar_sync, args=(modo,), daemon=True)
    thread.start()
    return jsonify({"status": "iniciado", "modo": modo})


# ─────────────────────────────────────────────────────────
# AGENDAMENTOS (horários em BRT, seg-sex)
# ─────────────────────────────────────────────────────────
# Cada tabela roda 1x/dia em horário SEPARADO. NUNCA usamos 'all' aqui: rodar
# tudo no mesmo processo estoura a RAM do free tier (512 MB). Os horários têm
# folga entre si para nunca haver dois syncs simultâneos (o _lock já impede
# concorrência, mas o espaçamento evita disputa de memória).
scheduler = BackgroundScheduler(timezone=BRT)

# AGENDA é definida no topo do módulo (fonte única, compartilhada com /status).
for _modo, _hora, _minuto in AGENDA:
    scheduler.add_job(
        lambda m=_modo: executar_sync(m),
        CronTrigger(hour=_hora, minute=_minuto, day_of_week="mon-fri", timezone=BRT),
        id=_modo,
    )

scheduler.start()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)))