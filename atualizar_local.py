"""
Rotina de atualização LOCAL (dispara no logon via Agendador de Tarefas do Windows).

Por que local: o IP de saída do Render está bloqueado pelo WAF da Geotab (403);
a máquina do usuário não está bloqueada. Roda os 4 modos do sync em sequência,
cada um isolado num subprocesso (uma falha não derruba os outros).

Regras:
- Só em DIAS ÚTEIS (seg-sex). Fim de semana: sai sem fazer nada.
- UMA VEZ por dia: se já rodou com sucesso hoje, sai (evita re-rodar a cada logon).
  Se algum modo falhar, o marcador NÃO é gravado → tenta de novo no próximo logon.
- Tudo é logado em atualizacao_local.log (e a saída de cada modo também).
"""
import os
import sys
import subprocess
import datetime
import pathlib

BASE   = pathlib.Path(__file__).resolve().parent
LOG    = BASE / "atualizacao_local.log"
MARKER = BASE / ".ultima_atualizacao"          # guarda a data do último sucesso
# Ordem leve → pesado. São as planilhas que mudam diariamente; cadastro/status são
# snapshots rápidos, comportamento/viagens são incrementais (e atualizam, de quebra,
# o odômetro/dia e o resumo mensal do mês corrente).
MODOS  = ["cadastro", "status", "comportamento", "viagens"]
NO_WINDOW = 0x08000000  # CREATE_NO_WINDOW: não pisca janela de console


def stamp(fh, msg):
    ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    fh.write(f"{ts}  {msg}\n")
    fh.flush()


def main():
    hoje = datetime.date.today()
    with open(LOG, "a", encoding="utf-8") as fh:
        # weekday(): seg=0 ... sex=4, sáb=5, dom=6
        if hoje.weekday() >= 5:
            stamp(fh, f"Fim de semana ({hoje:%a}) — nada a fazer.")
            return

        if MARKER.exists() and MARKER.read_text(encoding="utf-8").strip() == hoje.isoformat():
            stamp(fh, "Já atualizado hoje — pulando.")
            return

        stamp(fh, "================ Atualização local iniciada ================")
        env = dict(os.environ, PYTHONIOENCODING="utf-8")
        falhas = []
        for modo in MODOS:
            stamp(fh, f"---- {modo} ----")
            rc = None
            try:
                rc = subprocess.run(
                    [sys.executable, str(BASE / "geotab_supabase.py"), modo],
                    cwd=str(BASE), env=env,
                    stdout=fh, stderr=subprocess.STDOUT,
                    creationflags=NO_WINDOW,
                ).returncode
            except Exception as exc:
                stamp(fh, f"  exceção ao rodar {modo}: {exc}")
            ok = (rc == 0)
            stamp(fh, f"  {'OK' if ok else 'FALHOU'} {modo} (exit {rc})")
            if not ok:
                falhas.append(modo)

        if falhas:
            stamp(fh, f"================ Concluído COM FALHAS: {falhas} "
                      f"(marcador não gravado; tenta de novo no próximo logon) ===")
        else:
            MARKER.write_text(hoje.isoformat(), encoding="utf-8")
            stamp(fh, "================ Concluído (todos OK) ================")


if __name__ == "__main__":
    main()
