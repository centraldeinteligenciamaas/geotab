"""Estima o volume de dados (viagens/dia e eventos/dia) direto da API Geotab.
Não toca no Supabase. Consome ~100 sub-chamadas da quota (limite 4500/min)."""
import random
from datetime import datetime, timedelta

from geotab_supabase import (
    autenticar, geotab_get, multicall, _identificar_regras, agora_brt, FMT,
)

AMOSTRA = 80  # devices na amostra de viagens

cred = autenticar()

veiculos = geotab_get(cred, "Device")
ativos = [v for v in veiculos if not v.get("isArchived", False)]
print(f"Devices: {len(veiculos)} total, {len(ativos)} ativos")

# Ontem (dia útil completo, 00:00–24:00 BRT)
hoje = agora_brt().replace(hour=0, minute=0, second=0, microsecond=0)
ini, fim = hoje - timedelta(days=1), hoje
print(f"Dia amostrado: {ini:%Y-%m-%d} (qui)")

# ── Viagens: amostra de devices ──
random.seed(42)
amostra = random.sample(ativos, min(AMOSTRA, len(ativos)))
res = multicall(cred, [
    {"method": "Get", "params": {"typeName": "Trip", "search": {
        "deviceSearch": {"id": v["id"]},
        "fromDate": ini.strftime(FMT), "toDate": fim.strftime(FMT),
    }}}
    for v in amostra
])
viagens_por_device = []
for r in res:
    trips = r if isinstance(r, list) else (r or {}).get("result", [])
    viagens_por_device.append(len(trips))

n = len(viagens_por_device)
total = sum(viagens_por_device)
com_viagem = sum(1 for x in viagens_por_device if x > 0)
media = total / n if n else 0
print(f"\n== VIAGENS (amostra de {n} devices) ==")
print(f"  devices que rodaram no dia: {com_viagem}/{n} ({100*com_viagem/n:.0f}%)")
print(f"  viagens no dia (amostra):   {total}  (média {media:.1f}/device)")
extrap_dia = media * len(ativos)
print(f"  extrapolação frota/dia:     {extrap_dia:,.0f} viagens")
# ~261 dias úteis + fins de semana com menos uso → fator 280 'dias equivalentes'
extrap_ano = extrap_dia * 280
print(f"  extrapolação ano (~280d):   {extrap_ano:,.0f} viagens")
print(f"  tamanho tb_viagens/ano:     {extrap_ano * 0.7 / 1024 / 1024:,.2f} GB (0,7 KB/linha c/ índices)")

# ── Eventos de comportamento: frota inteira, 1 dia ──
ids_vel, regras_simples = _identificar_regras(cred)
print(f"\n== EVENTOS DE COMPORTAMENTO ({ini:%Y-%m-%d}, frota inteira) ==")
total_ev = 0
for rotulo, rids in [("excesso_velocidade", ids_vel)] + [
    (t, [r]) for t, r in regras_simples.items() if r
]:
    qtd = 0
    for rid in rids:
        evs = geotab_get(cred, "ExceptionEvent", search={
            "ruleSearch": {"id": rid},
            "fromDate": ini.strftime(FMT), "toDate": fim.strftime(FMT),
        }, resultsLimit=50000)
        qtd += len(evs)
    total_ev += qtd
    print(f"  {rotulo:22} {qtd:>7} eventos/dia")
print(f"  {'TOTAL':22} {total_ev:>7} eventos/dia")
# buckets: no máx. 1 linha por device/dia/tipo — eventos colapsam
buckets_dia_max = len(ativos) * 4
print(f"  buckets/dia (máx):     {buckets_dia_max:,} → 6 meses ≈ {buckets_dia_max*183:,} linhas")
print(f"  tamanho tb_comportamento_eventos (máx): {buckets_dia_max*183*0.1/1024/1024:,.2f} GB (0,1 KB/linha)")
print(f"  tb_comportamento: {len(ativos)} linhas (1 por device) — desprezível")
