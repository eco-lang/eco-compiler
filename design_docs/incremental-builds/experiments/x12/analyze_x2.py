#!/usr/bin/env python3
"""X2 duplication census. Usage: analyze_x2.py <baseline.tsv> <out.json>"""
import sys, os, re, json, collections, glob
from census_lib import Census, ucost

c = Census(sys.argv[1])
from imports_lib import Imports, classify_instance
imp = Imports(c)

# ---------- per-instance data ----------
inst, req = c.requesters()


rows = []
for sid in inst:
    s = c.specs[sid]
    gh = c.home(s) if s.pkg != "eco/accessor" else None
    dom, pkg_only = classify_instance(c, imp, s)
    rows.append({"sid": sid, "key": s.key, "cost": ucost(s), "nreq": len(req[sid]), "req": sorted(req[sid]),
                 "dom": dom, "pkg_only": pkg_only, "generic_project": bool(gh and c.is_project_mod(gh)),
                 "reason": c.instance_reason(s)})

base_total = sum(ucost(s) for s in c.specs.values())
non_inst_cost = sum(ucost(s) for s in c.specs.values() if s.sid not in inst)
inst_cost = sum(r["cost"] for r in rows)


def variant(copies_fn):
    cost = non_inst_cost + sum(r["cost"] * copies_fn(r) for r in rows)
    nspec = (len(c.specs) - len(rows)) + sum(copies_fn(r) for r in rows)
    return {"cost": cost, "pct_of_baseline": 100.0 * cost / base_total, "symbols": nspec}


A = variant(lambda r: r["nreq"])
B = variant(lambda r: 1 if r["dom"] else r["nreq"])
AC = variant(lambda r: 1 if r["pkg_only"] else r["nreq"])
BC = variant(lambda r: 1 if (r["pkg_only"] or r["dom"]) else r["nreq"])

hist = collections.Counter(min(r["nreq"], 50) for r in rows)
by_reason = collections.defaultdict(lambda: [0, 0, 0])
for r in rows:
    br = by_reason[r["reason"]]
    br[0] += 1
    br[1] += r["cost"]
    br[2] += r["cost"] * r["nreq"]

res = {
    "baseline_total_cost": base_total, "specs": len(c.specs), "instances": len(rows),
    "instance_cost": inst_cost, "instance_cost_pct": 100.0 * inst_cost / base_total,
    "pkg_only_instances": sum(1 for r in rows if r["pkg_only"]),
    "pkg_only_instance_cost": sum(r["cost"] for r in rows if r["pkg_only"]),
    "instances_with_dominator": sum(1 for r in rows if r["dom"]),
    "instances_nreq1": sum(1 for r in rows if r["nreq"] == 1),
    "A": A, "B": B, "A+C": AC, "B+C": BC,
    "nreq_hist": dict(sorted(hist.items())),
    "by_reason": {k: {"n": v[0], "cost": v[1], "cost_A": v[2]} for k, v in by_reason.items()},
    "missing_import_files": sorted(imp.missing_files)[:30], "n_missing_import_files": len(imp.missing_files),
    "distinct_requesting_modules": len({m for r in rows for m in r["req"]}),
}
top = sorted(rows, key=lambda r: -(r["cost"] * (r["nreq"] - 1)))[:20]
res["top20_duplication"] = [{"key": r["key"][:160], "cost": r["cost"], "nreq": r["nreq"],
                             "extra_cost": r["cost"] * (r["nreq"] - 1), "pkg_only": r["pkg_only"],
                             "dominator": r["dom"]} for r in top]
topn = sorted(rows, key=lambda r: -r["nreq"])[:20]
res["top20_by_requesters"] = [{"key": r["key"][:160], "cost": r["cost"], "nreq": r["nreq"], "pkg_only": r["pkg_only"]} for r in topn]
json.dump(res, open(sys.argv[2], "w"), indent=1)
for k in ["baseline_total_cost", "specs", "instances", "instance_cost", "instance_cost_pct", "pkg_only_instances",
          "pkg_only_instance_cost", "instances_with_dominator", "instances_nreq1", "distinct_requesting_modules",
          "n_missing_import_files"]:
    print(k, res[k])
for v in ["A", "B", "A+C", "B+C"]:
    print(v, res[v])
print("by_reason", res["by_reason"])
print("nreq_hist", res["nreq_hist"])
for t in res["top20_duplication"]:
    print(t)
