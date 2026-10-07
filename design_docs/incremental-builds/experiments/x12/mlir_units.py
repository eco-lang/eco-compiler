"""Module-aligned (definition-module) units judged on actual text-MLIR bytes:
raw = today's symbol names (unit content = its ops' raw text),
norm = stable-key normalised text. Usage: mlir_units.py base.mlir base.tsv edit.mlir edit.tsv"""
import sys, collections
src = open('/tmp/inc-exp/results/x12/mlir_compare.py').read().split('bm, bc, em, ec')[0]
exec(src)
from census_lib import Census, ucost
bm, bc, em, ec = sys.argv[1:5]
out = {}
for tag, (m, cp) in {"base": (bm, bc), "edit": (em, ec)}.items():
    c = Census(cp)
    n, r, st, _ = group(m, c)
    sym2home = {s.sym: c.home(s) for s in c.specs.values()}
    key2home = {s.key: c.home(s) for s in c.specs.values()}
    ru = collections.defaultdict(set); nu = collections.defaultdict(set)
    for k, hsh in r.items():
        ru[sym2home.get(k, "<other>")].add((k, hsh))
    for k, hsh in n.items():
        nu[key2home.get(k, "<other>")].add((k, hsh))
    out[tag] = (ru, nu, c)
for i, name in [(0, "raw-names module units"), (1, "stable-normalised module units")]:
    b, e = out["base"][i], out["edit"][i]
    d = [u for u in set(b) | set(e) if b.get(u) != e.get(u)]
    c = out["edit"][2]
    cost = collections.Counter()
    for s in c.specs.values(): cost[c.home(s)] += ucost(s)
    tot = sum(cost.values())
    print(name, "dirty units:", len(d), "of", len(e), f"cost {100*sum(cost[u] for u in d)/tot:.2f}%", sorted(d)[:8])
