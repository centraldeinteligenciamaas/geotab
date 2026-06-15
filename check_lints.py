"""Sonda final: discrimina IO global vs problema pontual."""
import time
from sqlalchemy import text
from geotab_supabase import criar_engine

engine = criar_engine()

def medir(conn, rotulo, sql):
    t0 = time.monotonic()
    try:
        r = conn.execute(text(sql)).scalar()
        print(f"  {rotulo:35} {r}  ({time.monotonic()-t0:.1f}s)")
    except Exception as exc:
        print(f"  {rotulo:35} FALHOU ({time.monotonic()-t0:.0f}s): {type(exc).__name__}")

with engine.begin() as conn:
    conn.execute(text("SET LOCAL statement_timeout = '150s'"))
    medir(conn, "SELECT 1 (sem disco)", "SELECT 1")
    medir(conn, "count tb_cadastro (~1700 linhas)", "SELECT count(*) FROM tb_cadastro")
    medir(conn, "count tb_viagens (tabela grande)", "SELECT count(*) FROM tb_viagens")
    medir(conn, "tamanho do banco", "SELECT pg_size_pretty(pg_database_size(current_database()))")
    medir(conn, "tamanho tb_viagens", "SELECT pg_size_pretty(pg_total_relation_size('tb_viagens'))")

engine.dispose()
