#!/usr/bin/env python3
"""X1 blast-radius analysis. Usage: analyze_x1.py <baseline.tsv> <baseline2.tsv> <edits.json>
edits.json: {"e1": {"census": path, "modules": ["Terminal.Main"], "desc": "..."}, ...}"""
import sys, json, statistics, collections
from census_lib import Census, raw_ident, range_units, range_unit_costs, module_units, owner_units, unit_cost_dict, ucost, K
from imports_lib import Imports, classify_instance

base = Census(sys.argv[1])
base2 = Census(sys.argv[2]) if sys.argv[2] != "-" else None
edits = json.load(open(sys.argv[3]))
out = {}


def total_cost(c):
    return sum(ucost(s) for s in c.specs.values())


def pct(a, b):
    return 100.0 * a / b if b else 0.0


def summarize_census(c):
    inst, req = c.requesters()
    reasons = collections.Counter(c.instance_reason(s) for s in c.specs.values())
    coll_groups = collections.Counter()
    for s in c.specs.values():
        if s.coll > 1:
            coll_groups[s.key.rsplit("#", 1)[0]] += 1
    proj = [s for s in c.specs.values() if c.is_project(s)]
    return {
        "specs": len(c.specs),
        "total_cost": total_cost(c),
        "project_specs": len(proj),
        "project_cost": sum(ucost(s) for s in proj),
        "instances": len(inst),
        "instance_cost": sum(ucost(c.specs[i]) for i in inst),
        "instance_reasons": dict(reasons),
        "collision_groups": len(coll_groups),
        "specs_in_collision_groups": sum(coll_groups.values()),
        "poly_annotations": len(c.poly),
        "globals_without_annotation": sum(1 for s in c.specs.values() if c.poly_decl(s) is None and s.pkg != "eco/accessor"),
        "modules_def": len({c.home(s) for s in c.specs.values()}),
        "project_pkg": c.project_pkg,
        "lambdas": sum(s.lambdas for s in c.specs.values()),
    }


out["baseline"] = summarize_census(base)

# ---- determinism control ----
if base2:
    ctl = {}
    ctl["same_keyset"] = set(base.by_key) == set(base2.by_key)
    common = set(base.by_key) & set(base2.by_key)
    ctl["fp_diff"] = sum(1 for k in common if base.by_key[k].fp != base2.by_key[k].fp)
    ctl["fpn_diff"] = sum(1 for k in common if base.by_key[k].fpn != base2.by_key[k].fpn)
    ctl["fpraw_diff"] = sum(1 for k in common if base.by_key[k].fpraw != base2.by_key[k].fpraw)
    ctl["sym_diff"] = sum(1 for k in common if base.by_key[k].sym != base2.by_key[k].sym)
    ctl["only_in_1"] = len(set(base.by_key) - set(base2.by_key))
    ctl["only_in_2"] = len(set(base2.by_key) - set(base.by_key))
    out["control"] = ctl


def unit_diff(bu, eu):
    """bu, eu: dict name -> {key: fp}. Returns set of dirty unit names."""
    dirty = set()
    for n in set(bu) | set(eu):
        if bu.get(n) != eu.get(n):
            dirty.add(n)
    return dirty


def range_rule(b, e, raw):
    bu = range_units(b, raw=raw)
    eu = range_units(e, raw=raw)
    costs, tot = range_unit_costs(e)
    d = [i for i in range(K) if bu[i] != eu[i]]
    return {"units": K, "dirty": len(d), "dirty_cost_pct": pct(sum(costs[i] for i in d), tot),
            "max_dirty_unit_cost_pct": max([pct(costs[i], tot) for i in d], default=0.0)}


def keyed_rule(b, e, unitfn, edited_units, fpfield="fp"):
    bu = unitfn(b)
    eu = unitfn(e)
    if fpfield != "fp":
        bu = {n: {k: getattr(b.by_key[k], fpfield) for k in m} for n, m in bu.items()}
        eu = {n: {k: getattr(e.by_key[k], fpfield) for k in m} for n, m in eu.items()}
    d = unit_diff(bu, eu)
    uc = unit_cost_dict(e, eu)
    ucb = unit_cost_dict(b, bu)
    tot = total_cost(e)
    own = {n for n in d if n in edited_units}
    callee = d - own
    # cost of the copies of a unit: under ownership a unit's cost counts its copies
    tot_units_cost = sum(uc.values())
    return {"units": len(eu), "dirty": len(d),
            "dirty_cost_pct": pct(sum(uc.get(n, ucb.get(n, 0)) for n in d), tot_units_cost),
            "max_dirty_unit_cost_pct": max([pct(uc.get(n, 0), tot_units_cost) for n in d], default=0.0),
            "dirty_own_source": len(own), "dirty_callee_only": len(callee),
            "dirty_units": sorted(d)[:40]}


def owner_units_variant(c, mode):
    """(iv-B): instances with an import-order dominator live once in the
    dominator module's unit, others copied per requester (A).
    (iv-A+C): package-only instances live in an append-only pool unit per
    generic home module ('pool:<module>'), others copied per requester."""
    if not hasattr(c, "_imp"):
        c._imp = Imports(c)
        c._cls = {}
    inst, req = c.requesters()
    u = collections.defaultdict(dict)
    for s in c.specs.values():
        if s.sid in inst:
            if s.sid not in c._cls:
                c._cls[s.sid] = classify_instance(c, c._imp, s)
            dom, pkg_only = c._cls[s.sid]
            if mode == "B" and dom:
                u[dom][s.key] = s.fp
            elif mode == "AC" and pkg_only:
                u["pool:" + (c.home(s) if s.pkg != "eco/accessor" else "accessor")][s.key] = s.fp
            else:
                for m in req[s.sid]:
                    u[m][s.key] = s.fp
        else:
            u[c.home(s)][s.key] = s.fp
    return u


def pool_rule(b, e, edited_units):
    """A+C with append-only pool semantics: an existing pool unit is dirty only
    if one of its baseline entries changed fingerprint; new pool entries go to
    NEW small units (counted once per pool module that gained entries);
    removed pool entries are tombstones (no dirt)."""
    bu = owner_units_variant(b, "AC")
    eu = owner_units_variant(e, "AC")
    dirty, new_pool = set(), set()
    for n in set(bu) | set(eu):
        if n.startswith("pool:"):
            bm, em = bu.get(n, {}), eu.get(n, {})
            if any(k in em and em[k] != v for k, v in bm.items()):
                dirty.add(n)
            if set(em) - set(bm):
                new_pool.add(n)
        elif bu.get(n) != eu.get(n):
            dirty.add(n)
    uc = unit_cost_dict(e, eu)
    ucb = unit_cost_dict(b, bu)
    tot = sum(uc.values())
    own = {n for n in dirty if n in edited_units}
    newcost = sum(ucost(e.by_key[k]) for n in new_pool for k in set(eu[n]) - set(bu.get(n, {})))
    return {"units": len(eu), "dirty": len(dirty) + len(new_pool),
            "dirty_existing": len(dirty), "new_pool_units": len(new_pool),
            "dirty_cost_pct": pct(sum(uc.get(n, ucb.get(n, 0)) for n in dirty) + newcost, tot),
            "max_dirty_unit_cost_pct": max([pct(uc.get(n, 0), tot) for n in dirty], default=0.0),
            "dirty_own_source": len(own), "dirty_callee_only": len(dirty) - len(own),
            "dirty_units": sorted(dirty)[:40], "new_pool": sorted(new_pool)}


rows = {}
for name, info in edits.items():
    e = Census(info["census"])
    edited_units = {e.project_pkg + ":" + m for m in info["modules"]}
    bk, ek = set(base.by_key), set(e.by_key)
    added, removed = ek - bk, bk - ek
    common = bk & ek
    changed = {k for k in common if base.by_key[k].fp != e.by_key[k].fp}
    changed_names_only = {k for k in common if base.by_key[k].fp == e.by_key[k].fp and base.by_key[k].fpn != e.by_key[k].fpn}
    dirty = added | removed | changed
    dcost = sum(ucost(e.by_key[k]) for k in added | changed) + sum(ucost(base.by_key[k]) for k in removed)
    direct = {k for k in dirty if (e.by_key.get(k) or base.by_key.get(k)) and
              (e.home(e.by_key[k]) if k in e.by_key else base.home(base.by_key[k])) in edited_units}
    # raw identity (today): symbol+raw fingerprint
    braw = {raw_ident(s) for s in base.specs.values()}
    eraw = {raw_ident(s) for s in e.specs.values()}
    raw_dirty = len(eraw - braw) + len({x[0] for x in braw} - {x[0] for x in eraw})
    braw2 = {(s.sym, s.fpraw) for s in base.specs.values()}
    eraw2 = {(s.sym, s.fpraw) for s in e.specs.values()}
    rawstrict_dirty = len(eraw2 - braw2) + len({x[0] for x in braw2} - {x[0] for x in eraw2})
    renumbered = sum(1 for k in common if base.by_key[k].sym != e.by_key[k].sym)
    # cause of indirect fp changes (spec kept its key, home module not edited)
    cause = collections.Counter()
    for k in changed:
        bs, es = base.by_key[k], e.by_key[k]
        if base.home(bs) in edited_units:
            cause["direct"] += 1
            continue
        brefs = {base.sid2key.get(x) for x in bs.refs}
        erefs = {e.sid2key.get(x) for x in es.refs}
        if brefs != erefs:
            cause["indirect-refs-changed"] += 1
        else:
            cause["indirect-same-refs(inlined body/facts/types)"] += 1
    dmods = {(e.home(e.by_key[k]) if k in e.by_key else base.home(base.by_key[k])) for k in dirty}
    r = {
        "desc": info.get("desc", ""),
        "specs_base": len(base.specs), "specs_edit": len(e.specs),
        "added": len(added), "removed": len(removed), "changed": len(changed),
        "changed_names_only": len(changed_names_only),
        "dirty_specs": len(dirty), "dirty_cost_pct": pct(dcost, total_cost(e)),
        "dirty_edit_side": len(added | changed),
        "dirty_direct": len(direct), "dirty_indirect": len(dirty - direct),
        "dirty_def_modules": len(dmods),
        "changed_cause": dict(cause),
        "raw_dirty_specs": raw_dirty, "rawstrict_dirty_specs(member/kind ids too)": rawstrict_dirty, "renumbered_specs": renumbered,
        "rule_i_raw_ranges": range_rule(base, e, raw=True),
        "rule_ii_stable_ranges": range_rule(base, e, raw=False),
        "rule_iii_def_module": keyed_rule(base, e, module_units, edited_units),
        "rule_iii_def_module_names": keyed_rule(base, e, module_units, edited_units, "fpn"),
        "rule_iv_owner_A": keyed_rule(base, e, owner_units, edited_units),
        "rule_iv_owner_B": keyed_rule(base, e, lambda c: owner_units_variant(c, "B"), edited_units),
        "rule_iv_owner_AC_pool": pool_rule(base, e, edited_units),
        "sample_added": sorted(added)[:15], "sample_removed": sorted(removed)[:15],
        "sample_changed": sorted(changed)[:25],
        "dirty_modules_list": sorted(dmods)[:40],
    }
    rows[name] = r

out["edits"] = rows


def agg(path):
    vals = []
    for r in rows.values():
        v = r
        for p in path:
            v = v[p]
        vals.append(v)
    return {"median": statistics.median(vals), "mean": statistics.mean(vals), "min": min(vals), "max": max(vals)}


summary = {}
for rule in ["rule_i_raw_ranges", "rule_ii_stable_ranges", "rule_iii_def_module", "rule_iii_def_module_names", "rule_iv_owner_A", "rule_iv_owner_B", "rule_iv_owner_AC_pool"]:
    summary[rule] = {"dirty": agg([rule, "dirty"]), "dirty_cost_pct": agg([rule, "dirty_cost_pct"]),
                     "max_dirty_unit_cost_pct": agg([rule, "max_dirty_unit_cost_pct"])}
summary["specs"] = {"dirty_specs": agg(["dirty_specs"]), "dirty_edit_side": agg(["dirty_edit_side"]), "dirty_cost_pct": agg(["dirty_cost_pct"]),
                    "raw_dirty_specs": agg(["raw_dirty_specs"]), "dirty_def_modules": agg(["dirty_def_modules"])}
out["summary"] = summary
json.dump(out, open(sys.argv[4] if len(sys.argv) > 4 else "/dev/stdout", "w"), indent=1)

# ---- human table ----
print("edit  | specs dirty (+/-/~) | dirty cost% | direct/indirect | raw-dirty | renum | modules || (i) raw-range | (ii) stable-range | (iii) def-module own/callee | (iii-names) | (iv) owner-A own/callee")
for n, r in rows.items():
    i, ii, iii, iiin, iv = (r[x] for x in ["rule_i_raw_ranges", "rule_ii_stable_ranges", "rule_iii_def_module", "rule_iii_def_module_names", "rule_iv_owner_A"])
    print(f"{n:5} | {r['dirty_specs']:5} ({r['added']}/{r['removed']}/{r['changed']}) | {r['dirty_cost_pct']:6.2f} | {r['dirty_direct']}/{r['dirty_indirect']} | {r['raw_dirty_specs']:5} | {r['renumbered_specs']:5} | {r['dirty_def_modules']:3} || "
          f"{i['dirty']}/{i['units']} ({i['dirty_cost_pct']:.1f}%) | {ii['dirty']}/{ii['units']} ({ii['dirty_cost_pct']:.1f}%) | "
          f"{iii['dirty']}/{iii['units']} ({iii['dirty_cost_pct']:.2f}%, max {iii['max_dirty_unit_cost_pct']:.2f}%) {iii['dirty_own_source']}/{iii['dirty_callee_only']} | "
          f"{iiin['dirty']} | {iv['dirty']}/{iv['units']} ({iv['dirty_cost_pct']:.2f}%, max {iv['max_dirty_unit_cost_pct']:.2f}%) {iv['dirty_own_source']}/{iv['dirty_callee_only']}"
          f" | B {r['rule_iv_owner_B']['dirty']}/{r['rule_iv_owner_B']['units']} | A+C {r['rule_iv_owner_AC_pool']['dirty']}/{r['rule_iv_owner_AC_pool']['units']} (new pool {r['rule_iv_owner_AC_pool']['new_pool_units']})")
