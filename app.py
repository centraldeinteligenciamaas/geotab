import os
import threading
import logging
from datetime import datetime
from zoneinfo import ZoneInfo

from flask import Flask, jsonify, request
from apscheduler.schedulers.background import BackgroundScheduler
from apscheduler.triggers.cron import CronTrigger

from geotab_supabase import main as sync_main

app = Flask(__name__)
BRT = ZoneInfo("America/Sao_Paulo")
log = logging.getLogger(__name__)

API_KEY = os.environ.get("SYNC_API_KEY", "")
_lock = threading.Lock()


def executar_sync(modo):
    if not _lock.acquire(blocking=False):
        log.warning(f"Sync já em execução — ignorando modo={modo}")
        return
    try:
        sync_main(modo)
    except Exception:
        log.exception(f"Erro durante sync modo={modo}")
    finally:
        _lock.release()


@app.route("/")
def index():
    return jsonify({
        "service": "geotab-sync",
        "endpoints": {
            "health": "/health",
            "run":    "/run/<modo>  — modos: all, cadastro, status, comportamento",
        },
    })


@app.route("/health")
def health():
    return jsonify({
        "status": "ok",
        "hora_brt": datetime.now(tz=BRT).strftime("%Y-%m-%d %H:%M:%S"),
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
