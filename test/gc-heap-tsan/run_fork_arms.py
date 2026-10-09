#!/usr/bin/env python3
"""Runs the harness guard arms of the concurrency register (fork_arms.txt;
plans/threaded-gc-register-repros-impl.md Step 27 and §13.6).

Builds, with g++ and Ninja, gc-fork-harness and the TSan binary gc-heap-tsan (<build-dir>/plain)
and gc-fork-trace (<build-dir>/trace, -DECO_TLA_TRACE=ON), runs every row of the chosen tier, and
maps each arm's exit code to a result.

Flavours plain and trace run `<exe> <arm> <trials> <seed>` once; the harness runs the trials.
Flavour tsan runs `gc-heap-tsan <arm split on ':'>` `trials` times (seed unused) with
TSAN_OPTIONS=halt_on_error=0; a trial reproduces when it prints REACHED, exits 66 (a TSan report)
and the report names the row's `match=` function (so an unrelated race cannot pass for the
entry); exit 0 with REACHED is "not reproduced", exit 3 (NOT REACHED) is a missed precondition.

  arm exit                    clean row   xfail row                   reach row   wontfix row          strict (ECO_TEST_XFAIL=strict)
  0 (not reproduced)          PASS        XPASS: fails, flip the row  FAIL        XPASS: fails         an xfail row passes
  1 (reproduced)              FAIL        XFAIL                       PASS        WONTFIX (passes)     an xfail row fails
  4 (precondition missed),
  other, timeout              ERROR       ERROR                       ERROR       ERROR                ERROR

A `wontfix` row documents ACCEPTED behaviour (a register entry closed as Won't-fix, e.g. CR-012
under its benchmark/test opt-in; plans/threaded-gc-register-fixes.md Step 0.1): reproducing is
WONTFIX, which passes in both modes; exit 0 is XPASS ("the accepted behaviour changed"), which fails.

`flaky` rows only report. Exit status: 0 when every gating row is PASS or XFAIL, else 1.

  run_fork_arms.py --tier quick                       # configure, build, run
  run_fork_arms.py --flavor trace --exe <gc-fork-trace> # one flavour, a prebuilt binary (CMake targets)
"""
import argparse
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
TARGETS = {"plain": "gc-fork-harness", "trace": "gc-fork-trace", "tsan": "gc-heap-tsan"}
BUILD_DIR = {"plain": "plain", "trace": "trace", "tsan": "plain"}   # tsan shares the plain tree


def parse_registry(path):
    rows = []
    for n, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        f = line.split()
        match = None
        if len(f) == 7 and f[6].startswith("match="):
            match = f.pop()[len("match="):]
        if len(f) != 6:
            sys.exit(f"{path}:{n}: expected `flavor tier arm trials seed expected [match=fn]`, "
                     f"got {len(f)} fields")
        flavor, tier, arm, trials, seed, expected = f
        if flavor not in TARGETS:
            sys.exit(f"{path}:{n}: flavor must be plain, trace or tsan, not {flavor}")
        if flavor == "tsan" and expected in ("xfail", "wontfix") and not match:
            sys.exit(f"{path}:{n}: a tsan {expected} row needs match=<function in the report>")
        if tier not in ("quick", "stress"):
            sys.exit(f"{path}:{n}: tier must be quick or stress, not {tier}")
        if expected not in ("clean", "xfail", "reach", "wontfix", "flaky", "retired"):
            sys.exit(f"{path}:{n}: expected must be clean, xfail, reach, wontfix or flaky, not {expected}")
        tag = raw.split("#", 1)[1].strip() if "#" in raw else ""
        rows.append(dict(line=n, flavor=flavor, tier=tier, arm=arm, trials=int(trials), seed=int(seed),
                         expected=expected, tag=tag, match=match))
    return rows


def clean_env():
    env = dict(os.environ)
    for k in list(env):
        if k in ("ECO_HEAP_CONFIG", "ECO_NURSERY_REGIONS", "ECO_TENURE_MODE", "FORK_HARNESS_CENSUS",
                 "ECO_P1_CENSUS") or k.startswith("ECO_GC_"):
            del env[k]
    return env


def build(flavor, build_dir, cxx, jobs, log_dir):
    if not shutil.which("cmake") or not shutil.which("ninja") or not shutil.which(cxx):
        sys.exit("run_fork_arms: cmake, ninja and " + cxx + " are required")
    bdir = build_dir / BUILD_DIR[flavor]
    cfg = ["cmake", "-S", str(HERE), "-B", str(bdir), "-G", "Ninja", f"-DCMAKE_CXX_COMPILER={cxx}",
           "-DECO_TLA_TRACE=" + ("ON" if flavor == "trace" else "OFF")]
    bld = ["cmake", "--build", str(bdir), "--target", TARGETS[flavor]]
    if jobs:
        bld += ["-j", str(jobs)]
    out = ""
    for cmd in (cfg, bld):
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        out += " ".join(cmd) + "\n" + p.stdout
        if p.returncode != 0:
            (log_dir / f"build-{flavor}.log").write_text(out)
            sys.exit(f"run_fork_arms: building {TARGETS[flavor]} failed; see {log_dir}/build-{flavor}.log")
    (log_dir / f"build-{flavor}.log").write_text(out)
    return bdir / TARGETS[flavor]


def run_tsan(exe, r, env, log_dir):
    """Runs a tsan row's trials; returns (rc, text) with rc 1 reproduced in every trial, 0 in
    none, 4 a precondition missed, 3 a mix of hits and misses, "error" anything else."""
    tenv = dict(env)
    tenv["TSAN_OPTIONS"] = "halt_on_error=0"
    cmd = [str(exe)] + r["arm"].split(":")
    per, text = [], []
    for t in range(r["trials"]):
        try:
            p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                               env=tenv, timeout=600, errors="replace")
            rc, out = p.returncode, p.stdout
        except subprocess.TimeoutExpired:
            rc, out = "timeout", ""
        warn = out.count("WARNING: ThreadSanitizer")
        reached = "REACHED" in out and "NOT REACHED" not in out
        # plans/large-object-space.md: a route made unreachable BY CONSTRUCTION (the arm
        # checks the structure that rules it out, exits 0 and says "route RETIRED").
        retired = "route RETIRED" in out
        named = r["match"] is None or r["match"] in out
        if rc == 3 or "NOT REACHED" in out:
            v = 4
        elif rc == 66 and reached and warn and named:
            v = 1
        elif rc == 0 and reached and not warn:
            v = 0
        elif rc == 0 and retired and not warn:
            v = 5
        else:
            v = "error"
        per.append(v)
        text.append(f"trial {t}: exit={rc} reached={int(reached)} tsan_warnings={warn} "
                    f"match({r['match']})={int(named)} -> {v}")
        (log_dir / f"{r['arm'].replace(':', '_')}.trial{t}.log").write_text(" ".join(cmd) + "\n" + out)
    if "error" in per:
        agg = "error"
    elif 4 in per:
        agg = 4
    elif all(v == 5 for v in per):
        agg = 5
    elif all(v == 1 for v in per):
        agg = 1
    elif all(v == 0 for v in per):
        agg = 0
    else:
        agg = 3
    hits = sum(1 for v in per if v == 1)
    text.append(f"SUMMARY tsan {r['arm']}: reproduced in {hits}/{len(per)} trials")
    return agg, "\n".join(text)


def judge(expected, rc, strict):
    if rc == 5:   # every trial reported its route retired
        return "RETIRED" if expected == "retired" else "ERROR"
    if expected == "retired":
        return "ERROR"
    if rc not in (0, 1):
        return "ERROR"
    if expected == "flaky":
        return "REPORT"
    if expected == "clean":
        return "PASS" if rc == 0 else "FAIL"
    if expected == "reach":
        return "PASS" if rc == 1 else "FAIL"
    if expected == "wontfix":   # accepted behaviour: passes in both modes; a change is XPASS
        return "WONTFIX" if rc == 1 else "XPASS"
    # xfail
    if strict:
        return "PASS" if rc == 0 else "FAIL"
    return "XFAIL" if rc == 1 else "XPASS"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tier", choices=("quick", "stress", "all"), default="quick")
    ap.add_argument("--flavor", choices=("plain", "trace", "tsan"), help="only this flavour's rows")
    ap.add_argument("--exe", help="a prebuilt binary for --flavor (skips the build)")
    ap.add_argument("--build-dir", default=str(ROOT / "build-fork-det"))
    ap.add_argument("--registry", default=str(HERE / "fork_arms.txt"))
    ap.add_argument("--arm", action="append", help="only these arms (repeatable)")
    ap.add_argument("--cxx", default="g++")
    ap.add_argument("--jobs", type=int, default=0)
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    if a.exe and not a.flavor:
        sys.exit("run_fork_arms: --exe needs --flavor")

    rows = [r for r in parse_registry(Path(a.registry))
            if (a.tier == "all" or r["tier"] == a.tier) and (not a.flavor or r["flavor"] == a.flavor)
            and (not a.arm or r["arm"] in a.arm)]
    if a.list:
        for r in rows:
            print(f"{r['flavor']:5} {r['tier']:6} {r['arm']:22} x{r['trials']:<3} {r['expected']:6} {r['tag']}")
        return 0
    if not rows:
        sys.exit("run_fork_arms: no rows selected")
    build_dir = Path(a.build_dir)
    log_dir = build_dir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    exes = {}
    for flavor in sorted({r["flavor"] for r in rows}):
        exes[flavor] = Path(a.exe) if a.exe else build(flavor, build_dir, a.cxx, a.jobs, log_dir)
    strict = os.environ.get("ECO_TEST_XFAIL") == "strict"
    env = clean_env()
    try:
        import resource
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))   # abort-based guards: no core files
    except (ImportError, ValueError, OSError):
        pass

    results = []
    for r in rows:
        cmd = [str(exes[r["flavor"]]), r["arm"], str(r["trials"]), str(r["seed"])]
        deadline = 60 + 300 * r["trials"]
        t0 = time.time()
        if r["flavor"] == "tsan":
            rc, out = run_tsan(exes["tsan"], r, env, log_dir)
            dt = time.time() - t0
            verdict = judge(r["expected"], rc, strict)
            results.append((r, rc, verdict))
            print(f"{verdict:6} {r['arm']:22} expected={r['expected']:6} exit={rc} ({dt:.1f} s)  {r['tag']}")
            for l in out.splitlines():
                if l.startswith("SUMMARY") or verdict in ("ERROR", "FAIL", "XPASS"):
                    print(f"         {l[:300]}")
            sys.stdout.flush()
            continue
        try:
            p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
                               timeout=deadline, errors="replace")
            rc, out = p.returncode, p.stdout
        except subprocess.TimeoutExpired as e:
            raw = e.stdout or ""
            rc, out = "timeout", raw.decode(errors="replace") if isinstance(raw, bytes) else raw
        dt = time.time() - t0
        (log_dir / f"{r['arm']}.log").write_text(" ".join(cmd) + "\n" + out)
        verdict = judge(r["expected"], rc, strict)
        summary = next((l for l in out.splitlines() if l.startswith("SUMMARY")), "(no SUMMARY line)")
        results.append((r, rc, verdict))
        print(f"{verdict:6} {r['arm']:22} expected={r['expected']:6} exit={rc} ({dt:.1f} s)  {r['tag']}")
        print(f"         {summary}")
        if verdict in ("ERROR", "FAIL", "XPASS"):
            for l in out.splitlines():
                if l.startswith("trial "):
                    print(f"         {l[:300]}")
        sys.stdout.flush()

    counts = {}
    for _, _, v in results:
        counts[v] = counts.get(v, 0) + 1
    bad = sum(n for v, n in counts.items() if v in ("FAIL", "XPASS", "ERROR"))
    print("run_fork_arms: " + ", ".join(f"{v} {n}" for v, n in sorted(counts.items())) +
          f" ({len(results)} rows, tier {a.tier}{', strict' if strict else ''}; logs in {log_dir})")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
