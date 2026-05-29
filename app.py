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
            "run":    "/run/<modo>  — modos: all, cadastro, status, comportamento",
        },
    })


@app.route("/health")
def health():
    return jsonify({
        "status": "ok",
        "hora_brt": datetime.now(tz=BRT).strftime("%Y-%m-%d %H:%M:%S"),
    })


@app.route("/status")
def status():
    ult = {"cadastro": None, "status": None, "comportamento": None}
    try:
        engine = criar_engine()
        with engine.connect() as conn:
            ult["cadastro"]      = conn.execute(text("SELECT MAX(atualizado_em) FROM tb_cadastro")).scalar()
            ult["status"]        = conn.execute(text("SELECT MAX(snapshot_em)   FROM tb_status")).scalar()
            ult["comportamento"] = conn.execute(text("SELECT MAX(atualizado_em) FROM tb_comportamento")).scalar()
        engine.dispose()
    except Exception as exc:
        log.error(f"Erro ao consultar últimas atualizações: {exc}")

    proximos = {
        job.id: job.next_run_time.astimezone(BRT).strftime("%Y-%m-%d %H:%M:%S")
        for job in scheduler.get_jobs()
        if job.next_run_time
    }

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

    if modo not in ("all", "cadastro", "status", "comportamento"):
        return jsonify({"error": "modo inválido — use: all, cadastro, status, comportamento"}), 400

    thread = threading.Thread(target=executar_sync, args=(modo,), daemon=True)
    thread.start()
    return jsonify({"status": "iniciado", "modo": modo})


# ─────────────────────────────────────────────────────────
# AGENDAMENTOS (horários em BRT, seg-sex)
# ─────────────────────────────────────────────────────────
scheduler = BackgroundScheduler(timezone=BRT)

# Cadastro: 07:00 BRT
scheduler.add_job(
    lambda: executar_sync("cadastro"),
    CronTrigger(hour=7, minute=0, day_of_week="mon-fri", timezone=BRT),
    id="cadastro",
)

# Status: 06:00, 12:30, 18:30 BRT
for _hora, _minuto in [(6, 0), (12, 30), (18, 30)]:
    scheduler.add_job(
        lambda: executar_sync("status"),
        CronTrigger(hour=_hora, minute=_minuto, day_of_week="mon-fri", timezone=BRT),
        id=f"status_{_hora}h{_minuto:02d}",
    )

# Comportamento: 20:00 BRT
scheduler.add_job(
    lambda: executar_sync("comportamento"),
    CronTrigger(hour=20, minute=0, day_of_week="mon-fri", timezone=BRT),
    id="comportamento",
)

scheduler.start()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)))
