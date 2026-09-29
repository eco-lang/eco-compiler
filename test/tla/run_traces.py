#!/usr/bin/env python3
"""Trace validation: run the rows of traces.txt (the `tla-trace` target).

plans/threaded-gc-tla-verification.md §6.1 (tla-trace), §6.3; test/tla/README.md,
"Trace validation". For the selected rows it
  1. checks the rows' model directories as tla-check does (SANY on every module,
     with test/tla/common/ beside them; PlusCal freshness);
  2. configures and builds each harness the rows use, in its TRACE build
     (`cmake -S <dir> -B <build-dir>/<harness> -G Ninja -DCMAKE_CXX_COMPILER=g++
     -DECO_TLA_TRACE=ON`, then its target): the runtime's ECO_TLA_TRACE hooks
     compiled in, no TSan;
  3. per row: runs the harness with the row's arguments (it writes the raw
     per-thread log to $ECO_TLA_TRACE_OUT), optionally doctors the raw log (a
     negative control, `mutate=`), merges it (trace/merge_trace.py, keeping the
     events listed in <dir>/<module>.keep if that file exists), and runs TLC on
     the row's trace spec in a scratch copy of the model directory, with the
     merged log as trace.ndjson;
  4. judges the outcome. A trace spec lists one invariant, TLUnmatched or
     TPUnmatched ("some event is still unmatched"): TLC reporting it violated
     means a behaviour matched the whole log, the trace is ACCEPTED; TLC finishing
     with no error means no behaviour matches it, the trace is REJECTED. Anything
     else (a parse error, a timeout, a harness failure) is an error. The row's
     expected outcome is `accept` or `reject`; on a rejection the runner prints
     the furthest event any behaviour matched (the spec's TRACE-PROGRESS lines)
     and the events after it.

Registry lines (traces.txt; `#` starts a comment):
  harness <name> <source dir, repo-relative> <cmake target>
  trace <model> <dir> <module> <config> <harness> <args> <expected> [mutate=<m>]
    args      the harness arguments, comma-separated (no spaces)
    expected  accept | reject
    mutate    a negative control, applied to the raw log before the merge:
                drop:<ev>:<k>          delete the k-th <ev> event (1-based, time order)
                set:<ev>:<k>:<f>=<v>   set field f of the k-th <ev> event (v is JSON)
                swap:<ev>:<k>          swap the k-th <ev> event with the next event
                                       of its thread

Usage: run_traces.py [--model M1] [--row SUBSTR] [--jobs N] [--workers N]
                     [--java-opts "-Xmx3g"] [--build-dir DIR] [--log-dir DIR]
                     [--timeout SEC] [--cxx g++] [--build-jobs N] [--list]
Tools: java and tla2tools.jar + CommunityModules-deps.jar (as run_models.py), cmake,
ninja and g++ (the dev image, docker/eco-dev.Dockerfile, has them all). A missing
tool fails the run with a message; nothing is skipped.
"""
import argparse
import concurrent.futures
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.dont_write_bytecode = True          # no __pycache__ in the source tree
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "trace"))
import run_models                      # noqa: E402  (find_tools, check_modules, run, tlc_outcome)
import merge_trace                     # noqa: E402

ACCEPT_INVARIANTS = ("TLUnmatched", "TPUnmatched")


class Harness:
    def __init__(self, lineno, name, source, target):
        self.lineno, self.name, self.source, self.target = lineno, name, source, target


class TraceRow:
    def __init__(self, lineno, model, directory, module, config, harness, args, expected, mutate):
        self.lineno = lineno
        self.model = model
        self.directory = directory
        self.module = module
        self.config = config
        self.harness = harness
        self.args = [a for a in args.split(",") if a]
        self.expected = expected
        self.mutate = mutate

    @property
    def name(self):
        n = f"{self.model}:{self.module}:{','.join(self.args)}"
        return n + (f":{self.mutate}" if self.mutate else "")


def read_registry(path):
    harnesses, rows = {}, []
    for n, line in enumerate(path.read_text().splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        f = line.split()
        if f[0] == "harness":
            if len(f) != 4:
                sys.exit(f"{path}:{n}: expected `harness <name> <source dir> <cmake target>`")
            if not (ROOT / f[2] / "CMakeLists.txt").is_file():
                sys.exit(f"{path}:{n}: {f[2]}/CMakeLists.txt does not exist")
            harnesses[f[1]] = Harness(n, f[1], f[2], f[3])
        elif f[0] == "trace":
            if len(f) not in (8, 9):
                sys.exit(f"{path}:{n}: expected `trace <model> <dir> <module> <config> <harness> "
                         f"<args> <expected> [mutate=...]`, got {len(f)} fields")
            mutate = None
            if len(f) == 9:
                if not f[8].startswith("mutate="):
                    sys.exit(f"{path}:{n}: the optional 9th field is mutate=<m>")
                mutate = f[8].split("=", 1)[1]
            row = TraceRow(n, *f[1:8], mutate)
            if row.expected not in ("accept", "reject"):
                sys.exit(f"{path}:{n}: expected must be accept or reject, not {row.expected}")
            if row.harness not in harnesses:
                sys.exit(f"{path}:{n}: harness {row.harness} is not declared above")
            for p in (f"{row.module}.tla", row.config):
                if not (HERE / row.directory / p).is_file():
                    sys.exit(f"{path}:{n}: {row.directory}/{p} does not exist")
            rows.append(row)
        else:
            sys.exit(f"{path}:{n}: a line starts with `harness` or `trace`")
    return harnesses, rows


def find_build_tools(cxx):
    missing = [t for t in ("cmake", "ninja") if not shutil.which(t)]
    if not shutil.which(cxx):
        missing.append(cxx)
    if missing:
        sys.exit("tla-trace: " + ", ".join(missing) + " not found; the trace harnesses are built "
                 "with cmake, ninja and g++. Use the dev image (docker/eco-dev.Dockerfile).")


def build_harness(h, build_dir, cxx, jobs, log_dir):
    bdir = build_dir / h.name
    nice = ["nice", "-n", "10"] if shutil.which("nice") else []
    cfg = [*nice, "cmake", "-S", str(ROOT / h.source), "-B", str(bdir), "-G", "Ninja",
           f"-DCMAKE_CXX_COMPILER={cxx}", "-DECO_TLA_TRACE=ON"]
    bld = [*nice, "cmake", "--build", str(bdir), "--target", h.target, "-j", str(jobs)]
    out = ""
    for cmd in (cfg, bld):
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        out += " ".join(cmd) + "\n" + p.stdout
        if p.returncode != 0:
            (log_dir / f"build-{h.name}.log").write_text(out)
            return None, out
    (log_dir / f"build-{h.name}.log").write_text(out)
    exe = bdir / h.target
    return (exe if exe.is_file() else None), out


def mutate_raw(raw_path, spec):
    """Apply one negative-control mutation to a raw log (see the module doc)."""
    lines = raw_path.read_text().splitlines()
    hdr, evs = lines[0], [json.loads(l) for l in lines[1:] if l.strip()]
    parts = spec.split(":")
    kind, ev, k = parts[0], parts[1], int(parts[2])
    hits = sorted((e for e in evs if e["ev"] == ev), key=lambda e: (e.get("ts", 0), e["t"], e["s"]))
    if len(hits) < k:
        raise ValueError(f"mutate={spec}: the log has only {len(hits)} {ev} event(s)")
    target = hits[k - 1]
    thread = sorted((e for e in evs if e["t"] == target["t"]), key=lambda e: e["s"])
    if kind == "drop":
        evs.remove(target)
        for s, e in enumerate(sorted((e for e in evs if e["t"] == target["t"]), key=lambda e: e["s"]), 1):
            e["s"] = s
    elif kind == "set":
        field, value = parts[3].split("=", 1)
        target[field] = json.loads(value)
    elif kind == "swap":
        i = thread.index(target)
        if i + 1 >= len(thread):
            raise ValueError(f"mutate={spec}: no event after it on its thread")
        nxt = thread[i + 1]
        keep = ("t", "s", "ts")
        a = {x: y for x, y in target.items() if x not in keep}
        b = {x: y for x, y in nxt.items() if x not in keep}
        for x in a:
            del target[x]
        for x in b:
            del nxt[x]
        target.update(b)
        nxt.update(a)
    else:
        raise ValueError(f"mutate={spec}: unknown kind {kind}")
    raw_path.write_text(hdr + "\n" + "".join(json.dumps(e) + "\n" for e in evs))


def progress(out):
    """The furthest match any behaviour reached: (count, index, thread, event) or None."""
    best = None
    for m in re.finditer(r'<<"TRACE-PROGRESS", (\d+), (\d+), "([^"]*)", "([^"]*)">>', out):
        n = int(m.group(1))
        if best is None or n > best[0]:
            best = (n, int(m.group(2)), m.group(3), m.group(4))
    return best


def describe_rejection(merged, out):
    best = progress(out)
    lines = merged.read_text().splitlines()[1:]
    events = [json.loads(l) for l in lines]
    if best is None:
        head = "no event was matched (the first step already fails)"
        start = 0
    else:
        head = (f"the furthest behaviour matched {best[0]} of {len(events)} events; "
                f"the last matched was #{best[1]} ({best[2]} {best[3]})")
        start = best[1]
    show = []
    for e in events[start:start + 4]:
        f = {k: v for k, v in e.items() if k not in ("vc", "pk", "i", "t", "n", "ev")}
        show.append(f"#{e['i']} {e['t']} {e['ev']} {json.dumps(f, sort_keys=True)}")
    return head + ("\n      next: " + "\n            ".join(show) if show else "")


def run_harness(exe, args, timeout, scratch, raw):
    """Run one harness invocation; it writes its raw log to raw. Returns (ok, output)."""
    work = Path(tempfile.mkdtemp(prefix="harness-", dir=scratch))
    env = dict(os.environ, ECO_TLA_TRACE_OUT=str(raw))
    if raw.exists():
        raw.unlink()
    try:
        p = subprocess.run([str(exe), *args], cwd=work, env=env, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, timeout=timeout)
        out, rc = p.stdout, p.returncode
    except subprocess.TimeoutExpired as e:
        out = e.stdout if isinstance(e.stdout, str) else (e.stdout or b"").decode(errors="replace")
        rc = None
    shutil.rmtree(work, ignore_errors=True)          # core files, if any, go with it
    head = f"$ ECO_TLA_TRACE_OUT={raw} {exe} {' '.join(args)}\n"
    if rc != 0 or not raw.is_file():
        why = "timed out" if rc is None else f"exit {rc}"
        return False, head + out + f"\n(harness {why})\n"
    return True, head + out


def run_row(row, raw_src, java, cp, workers, java_opts, timeout, scratch, log_dir):
    t0 = time.monotonic()
    safe = row.name.replace("/", "_").replace(":", "__").replace(",", "_")
    raw = log_dir / f"{safe}.raw.ndjson"
    merged = log_dir / f"{safe}.ndjson"
    log = log_dir / f"{safe}.log"
    text = f"raw log: {raw_src}\n"
    try:
        shutil.copy(raw_src, raw)
        if row.mutate:
            mutate_raw(raw, row.mutate)
            text += f"mutated: {row.mutate}\n"
        keep = None
        keep_file = HERE / row.directory / f"{row.module}.keep"
        if keep_file.is_file():
            keep = {w for line in keep_file.read_text().splitlines()
                    for w in line.split("#", 1)[0].split()}
        h, lines, stats = merge_trace.run(str(raw), str(merged), keep)
    except (merge_trace.MergeError, ValueError) as e:
        log.write_text(text + f"merge: {e}\n")
        return row, "error (merge)", time.monotonic() - t0, "", log, str(e)
    text += (f"merge: {stats['events_in']} events, {h['count']} kept, threads {h['threads']}, "
             f"{stats['backtracks']} backtrack(s)\n")
    work = Path(tempfile.mkdtemp(prefix=f"{row.model}-trace-", dir=scratch))
    m = work / "m"
    shutil.copytree(HERE / row.directory, m)
    run_models.copy_common(m)
    shutil.copy(merged, m / "trace.ndjson")
    cmd = [java, "-XX:+UseParallelGC", *java_opts, "-cp", cp, "tlc2.TLC", "-workers", str(workers),
           "-noGenerateSpecTE", "-metadir", str(work / "states"), "-config", row.config,
           f"{row.module}.tla"]
    rc, out, secs, timed_out = run_models.run(cmd, m, timeout)
    log.write_text(text + " ".join(cmd) + "\n\n" + out)
    got = run_models.tlc_outcome(rc, out, timed_out)
    if got.startswith("violates:") and got.split(":", 1)[1] in ACCEPT_INVARIANTS:
        verdict = "accept"
    elif got == "pass":
        verdict = "reject"
    else:
        verdict = got
    states = re.findall(r"([\d,]+) distinct states found", out)
    size = f"{h['count']} events, {states[-1] if states else '?'} states"
    detail = describe_rejection(merged, out) if verdict == "reject" else ""
    shutil.rmtree(work, ignore_errors=True)
    return row, verdict, time.monotonic() - t0, size, log, detail


def main():
    # One line per result, even when the output is a file or a pipe (a long run's progress).
    sys.stdout.reconfigure(line_buffering=True)
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", action="append", help="only these models (repeatable)")
    ap.add_argument("--row", help="only rows whose name contains this")
    ap.add_argument("--jobs", type=int, default=2, help="rows at once (default 2)")
    ap.add_argument("--workers", type=int, default=2, help="TLC workers per row (default 2)")
    ap.add_argument("--timeout", type=int, default=600, help="seconds per harness run and per TLC run")
    ap.add_argument("--build-dir", default=str(ROOT / "build" / "tla-trace"),
                    help="where the trace harnesses are built (default build/tla-trace)")
    ap.add_argument("--build-jobs", type=int, default=4, help="compile jobs per harness build")
    ap.add_argument("--cxx", default="g++", help="the harnesses' C++ compiler (default g++)")
    ap.add_argument("--log-dir", help="where logs and traces are kept (default: a temporary directory)")
    ap.add_argument("--jar")
    ap.add_argument("--java")
    ap.add_argument("--java-opts", default=os.environ.get("ECO_TLA_JAVA_OPTS", ""),
                    help="extra JVM options for TLC, e.g. -Xmx3g (default: $ECO_TLA_JAVA_OPTS)")
    ap.add_argument("--list", action="store_true", help="list the selected rows and exit")
    args = ap.parse_args()

    harnesses, rows = read_registry(HERE / "traces.txt")
    if args.model:
        rows = [r for r in rows if r.model in args.model]
    if args.row:
        rows = [r for r in rows if args.row in r.name]
    if args.list:
        for r in rows:
            print(f"{r.name:70s} {r.harness:16s} expected {r.expected}")
        return 0
    if not rows:
        sys.exit("tla-trace: no row selected")

    args.apalache = None
    java, cp, _ = run_models.find_tools(args, False)
    if "CommunityModules-deps.jar" not in cp:
        sys.exit("tla-trace: CommunityModules-deps.jar (Json, IOUtils) is not next to "
                 "tla2tools.jar; the trace specs need it. Use the dev image.")
    find_build_tools(args.cxx)
    scratch = Path(tempfile.mkdtemp(prefix="tla-trace-"))
    log_dir = Path(args.log_dir) if args.log_dir else scratch / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    build_dir = Path(args.build_dir)
    build_dir.mkdir(parents=True, exist_ok=True)

    failures = []
    for d in sorted({r.directory for r in rows}):
        for p in run_models.check_modules(d, java, cp, None, scratch):
            failures.append(p)
            print(f"FAIL  {p}")
    if failures:
        print(f"\ntla-trace: {len(failures)} module problem(s); nothing run.")
        return 1

    exes = {}
    for name in sorted({r.harness for r in rows}):
        t0 = time.monotonic()
        exe, out = build_harness(harnesses[name], build_dir, args.cxx, args.build_jobs, log_dir)
        if exe is None:
            print(f"FAIL  building harness {name}; log: {log_dir / f'build-{name}.log'}")
            print("      " + "\n      ".join(out.splitlines()[-30:]))
            return 1
        exes[name] = exe
        print(f"tla-trace: built {name} ({exe}) in {time.monotonic() - t0:.0f}s")

    # Each distinct harness invocation runs once; its rows (the positive one and
    # the negative controls doctored from the same log) share its raw log.
    t_all = time.monotonic()
    raws = {}
    for key in sorted({(r.harness, tuple(r.args)) for r in rows}):
        raw = log_dir / (key[0] + "-" + "-".join(key[1]) + ".raw.ndjson")
        t0 = time.monotonic()
        ok, out = run_harness(exes[key[0]], list(key[1]), args.timeout, scratch, raw)
        (log_dir / (raw.name[:-len(".raw.ndjson")] + ".harness.log")).write_text(out)
        if not ok:
            print(f"FAIL  {key[0]} {' '.join(key[1])}: the harness failed")
            print("      " + "\n      ".join(out.splitlines()[-30:]))
            failures.append(f"{key[0]} {' '.join(key[1])}")
            continue
        raws[key] = raw
        print(f"tla-trace: ran {key[0]} {' '.join(key[1])} in {time.monotonic() - t0:.1f}s")
    rows_run = [r for r in rows if (r.harness, tuple(r.args)) in raws]
    print(f"tla-trace: checking {len(rows_run)} trace(s), {args.jobs} at a time with "
          f"{args.workers} TLC worker(s) each")
    java_opts = shlex.split(args.java_opts)
    n_ok = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futs = [pool.submit(run_row, r, raws[(r.harness, tuple(r.args))], java, cp, args.workers,
                            java_opts, args.timeout, scratch, log_dir) for r in rows_run]
        for f in concurrent.futures.as_completed(futs):
            row, verdict, secs, size, log, detail = f.result()
            ok = verdict == row.expected
            n_ok += 1 if ok else 0
            print(f"{'ok  ' if ok else 'FAIL'}  {row.name:70s} {verdict:10s} {secs:6.1f}s  {size}")
            if detail and (not ok or verdict == "reject"):
                print("      " + detail)
            if not ok:
                failures.append(row.name)
                print(f"      expected {row.expected}; log: {log}")
    print(f"\ntla-trace: {n_ok}/{len(rows)} as expected "
          f"in {time.monotonic() - t_all:.0f}s; logs and traces in {log_dir}")
    for p in scratch.iterdir():
        if p != log_dir:
            shutil.rmtree(p, ignore_errors=True)
    if args.log_dir:
        shutil.rmtree(scratch, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
