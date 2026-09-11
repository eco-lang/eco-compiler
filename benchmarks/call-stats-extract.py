#!/usr/bin/env python3
"""Pull all four call-stat groups out of one run's artefacts, TSV on stdout."""
import re, sys, os

BK = "/work/build/compiler/build-kernel"

def read(p):
    try:
        return open(p, "rb").read().replace(b"\0", b"").decode("utf8", "replace")
    except FileNotFoundError:
        return ""

def grab(pat, s, *groups, cast=int):
    m = re.search(pat, s)
    if not m:
        return [None] * len(groups) if len(groups) > 1 else None
    vals = [cast(m.group(g)) for g in groups]
    return vals if len(groups) > 1 else vals[0]

def run(tag):
    err = read(f"{BK}/{tag}.stderr")
    out = read(f"{BK}/{tag}.stdout")
    tim = read(f"{BK}/{tag}.time")
    d = {"tag": tag}

    # --- group 1: lss-coverage ---
    for k in ("positions", "k1", "kN", "var", "top", "part"):
        d["cov_" + k] = grab(rf"^coverage: .*\b{k}=(\d+)", err, 1) if re.search(r"^coverage:", err, re.M) else None
    m = re.search(r"^coverage: (.*)$", err, re.M)
    if m:
        for k in ("positions", "k1", "kN", "var", "top", "part"):
            mm = re.search(rf"\b{k}=(\d+)", m.group(1))
            d["cov_" + k] = int(mm.group(1)) if mm else None

    # --- group 2: lss-stamping ---
    m = re.search(r"^lss globalopt: (.*)$", err, re.M)
    g = m.group(1) if m else ""
    for k in ("dispatchUpgraded", "stampedPapPrefix", "stampedPapGlobal", "stampedStaged",
              "declinedBlocked", "declinedNoInstance", "declinedShape",
              "declinedAbiMismatch", "declinedBodyMismatch", "multiInstanceGroups"):
        mm = re.search(rf"\b{k}=(\d+)", g)
        d["st_" + k] = int(mm.group(1)) if mm else None
    mm = re.search(r"devirtPost\([^)]*\)=(\d+)/(\d+)/(\d+)/(\d+)", g)
    if mm:
        d["st_dpFn"], d["st_dpCtor"], d["st_dpNoSpec"], d["st_dpAmbiguous"] = map(int, mm.groups())

    # --- group 3: dispatch-stats ---
    mm = re.search(r"\[dispatch-stats\] sat=(\d+) gen=(\d+) typed=(\d+) fast=(\d+) distinct=(\d+)", err)
    if mm:
        d["ds_sat"], d["ds_gen"], d["ds_typed"], d["ds_fast"], d["ds_distinct"] = map(int, mm.groups())

    # --- group 4: call-census ---
    mm = re.search(r"\[call-census\] elm=(\d+) kernel=(\d+) cap=(\d+) helper=(\d+) runtime=(\d+) extern=(\d+) indirect=(\d+) sites=(\d+)", err)
    if mm:
        (d["cc_elm"], d["cc_kernel"], d["cc_cap"], d["cc_helper"],
         d["cc_runtime"], d["cc_extern"], d["cc_indirect"], d["cc_sites"]) = map(int, mm.groups())
    for name, key in (("eco_apply_closure_eval", "cc_applyEval"),
                      ("eco_closure_call_saturated", "cc_sat"),
                      ("eco_closure_call_saturated_eval", "cc_satEval")):
        mm = re.search(rf"row kind=helper name={name} count=(\d+)", err)
        d[key] = int(mm.group(1)) if mm else None

    # --- context ---
    mm = re.search(r"Elapsed \(wall clock\) time.*?:\s*(?:(\d+):)?(\d+):([\d.]+)", tim)
    if mm:
        h = int(mm.group(1) or 0); d["wall"] = round(h*3600 + int(mm.group(2))*60 + float(mm.group(3)), 1)
    d["rss"] = grab(r"Maximum resident set size \(kbytes\): (\d+)", tim, 1)
    d["minor"] = grab(r"Minor GC cycles:\s+(\d+)", out, 1)
    d["major"] = grab(r"Major GC cycles:\s+(\d+)", out, 1)
    d["promotedMB"] = grab(r"totals: promoted \d+ \((\d+) MiB\)", out, 1)
    p = f"{BK}/bin/{tag}-out.mlir"
    d["outmlir"] = os.path.getsize(p) if os.path.exists(p) else None
    d["ok"] = "Success!" in out
    return d

if __name__ == "__main__":
    rows = [run(t) for t in sys.argv[1:]]
    keys = list(rows[0].keys())
    print("\t".join(keys))
    for r in rows:
        print("\t".join("" if r.get(k) is None else str(r.get(k)) for k in keys))
