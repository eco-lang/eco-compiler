#!/usr/bin/env python3
"""Run the TLA+ models registered in models.txt.

plans/threaded-gc-tla-verification.md §6.1. For every model directory selected it
  1. parses every module with SANY and fails on its error TEXT (SANY exits 0 even
     when it reports errors); a module that EXTENDS Apalache is type-checked by
     Apalache instead, when an Apalache row of that directory is selected;
  2. re-translates every PlusCal module in a scratch copy and fails if the
     committed translation is stale;
  3. runs every selected row in a scratch copy of the model directory (so no tool
     ever writes into the source tree) and compares the outcome with the one
     models.txt expects: `pass`, `violates:<Invariant or property>`, `deadlock` or
     `witness:<Invariant>` (a configuration that fails on purpose to show a state is
     reachable; judged exactly like `violates:`). A row that hits the time limit fails.
       tool tlc:      TLC with `-config <config>` on `<module>.tla`;
       tool apalache: `apalache-mc check <the arguments in the file <config>>
                      <module>.tla`; `violates:` names the `--inv` it checks.
The shared modules in test/tla/common/ are copied next to a model's modules for
SANY and TLC. Trace validation (traces.txt) has its own runner, run_traces.py,
which reuses the functions here.

Usage: run_models.py [--tier quick|deep|all] [--model M1] [--config SUBSTR] [--tool tlc|apalache]
                     [--jobs N] [--workers N] [--timeout SEC] [--log-dir DIR]
                     [--java-opts "-Xmx4g ..."]   (default: $ECO_TLA_JAVA_OPTS)
Tools: --jar / $TLA2TOOLS_JAR / $TLA_TOOLS_DIR/tla2tools.jar, java on PATH (or
--java), and for Apalache rows apalache-mc on PATH (or --apalache). The dev image
(docker/eco-dev.Dockerfile) provides all three.
"""
import argparse
import concurrent.futures
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
# Shared modules (e.g. the trace-validation modules TraceLog, TraceInOrder,
# TraceAnyOrder): copied next to a model's modules wherever SANY or TLC runs, so
# a model's module can EXTEND them. A model's own module of the same name wins.
COMMON = HERE / "common"

SANY_ERRORS = re.compile(r"\*\*\* Errors|Semantic errors|Parse Error|Fatal errors|Lexical error|"
                         r"Could not parse|Cannot find source file")
EXTENDS_APALACHE = re.compile(r"^EXTENDS\b[^\n]*\bApalache\b", re.M)


class Row:
    def __init__(self, lineno, model, directory, module, config, tier, tool, expected):
        self.lineno = lineno
        self.model = model
        self.directory = directory
        self.module = module
        self.config = config
        self.tier = tier
        self.tool = tool
        self.expected = expected

    @property
    def name(self):
        return f"{self.model}:{self.config}"


def read_registry(path):
    rows = []
    for n, line in enumerate(path.read_text().splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        f = line.split()
        if len(f) != 7:
            sys.exit(f"{path}:{n}: expected 7 fields "
                     f"(model dir module config tier tool expected), got {len(f)}")
        row = Row(n, *f)
        if row.tier not in ("quick", "deep"):
            sys.exit(f"{path}:{n}: tier must be quick or deep, not {row.tier}")
        if row.tool not in ("tlc", "apalache"):
            sys.exit(f"{path}:{n}: tool must be tlc or apalache, not {row.tool}")
        if not (row.expected in ("pass", "deadlock") or row.expected.startswith("violates:")
                or row.expected.startswith("witness:")):
            sys.exit(f"{path}:{n}: expected must be pass, deadlock, violates:<Name> or witness:<Name>")
        if not (HERE / row.directory / row.config).is_file():
            sys.exit(f"{path}:{n}: {row.directory}/{row.config} does not exist")
        rows.append(row)
    return rows


def find_tools(args, need_apalache):
    jar = args.jar or os.environ.get("TLA2TOOLS_JAR")
    if not jar and os.environ.get("TLA_TOOLS_DIR"):
        jar = str(Path(os.environ["TLA_TOOLS_DIR"]) / "tla2tools.jar")
    java = args.java or shutil.which("java")
    if not jar or not Path(jar).is_file() or not java:
        sys.exit("tla-check: tla2tools.jar or java not found. Use the dev image "
                 "(docker/eco-dev.Dockerfile), or set TLA2TOOLS_JAR / TLA_TOOLS_DIR "
                 f"and put java on PATH. (jar={jar!r}, java={java!r})")
    cp = [jar]
    community = Path(jar).with_name("CommunityModules-deps.jar")
    if community.is_file():
        cp.append(str(community))
    apalache = args.apalache or shutil.which("apalache-mc")
    if need_apalache and not apalache:
        sys.exit("tla-check: an Apalache row is selected but apalache-mc was not found. "
                 "Use the dev image, or pass --apalache.")
    return java, os.pathsep.join(cp), apalache


def run(cmd, cwd, timeout):
    t0 = time.monotonic()
    try:
        p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, timeout=timeout)
        return p.returncode, p.stdout, time.monotonic() - t0, False
    except subprocess.TimeoutExpired as e:
        out = e.stdout if isinstance(e.stdout, str) else (e.stdout or b"").decode(errors="replace")
        return None, out, time.monotonic() - t0, True


def copy_common(dest):
    """Put the shared modules (test/tla/common/*.tla) into dest, never over a model's own."""
    if COMMON.is_dir():
        for tla in sorted(COMMON.glob("*.tla")):
            if not (dest / tla.name).exists():
                shutil.copy(tla, dest / tla.name)


def check_modules(directory, java, cp, apalache, scratch):
    """SANY (or Apalache's type checker) + PlusCal freshness for one model directory."""
    problems = []
    src = HERE / directory
    modules = sorted(src.glob("*.tla"))
    for tla in modules:
        text = tla.read_text()
        if re.search(r"--(fair\s+)?algorithm", text):
            work = Path(tempfile.mkdtemp(prefix="pcal-", dir=scratch))
            shutil.copy(tla, work / tla.name)
            rc, out, _, _ = run([java, "-cp", cp, "pcal.trans", "-nocfg", tla.name], work, 300)
            if rc != 0 or "Translation completed" not in out:
                problems.append(f"{directory}/{tla.name}: PlusCal translation failed:\n{out}")
            elif (work / tla.name).read_text() != text:
                problems.append(f"{directory}/{tla.name}: the committed translation is stale. "
                                f"Re-run `pcal -nocfg {tla.name}` and commit the result.")
    work = Path(tempfile.mkdtemp(prefix="sany-", dir=scratch))
    for tla in modules:
        shutil.copy(tla, work / tla.name)
    copy_common(work)
    for tla in modules:
        if EXTENDS_APALACHE.search(tla.read_text()):
            if apalache:
                rc, out, _, _ = run([apalache, f"--out-dir={work / '_apalache-out'}",
                                     "typecheck", tla.name], work, 600)
                if rc != 0 or "Type checker [OK]" not in out:
                    problems.append(f"{directory}/{tla.name}: Apalache's type checker failed:\n{out}")
            continue
        rc, out, _, _ = run([java, "-cp", cp, "tla2sany.SANY", tla.name], work, 300)
        if rc != 0 or SANY_ERRORS.search(out):
            problems.append(f"{directory}/{tla.name}: SANY reported errors:\n{out}")
    return problems


def tlc_outcome(rc, out, timed_out):
    if timed_out:
        return "timeout"
    m = re.search(r"Error: Invariant (\S+) is violated", out)
    if m:
        return f"violates:{m.group(1)}"
    if "Error: Deadlock reached" in out:
        return "deadlock"
    m = re.search(r"Error: Temporal property (\S+) was violated", out)
    if m:
        return f"violates:{m.group(1)}"
    if "Error: Temporal properties were violated" in out:
        return "violates:<temporal>"
    if rc == 0 and "Model checking completed. No error has been found." in out:
        return "pass"
    first = next((l for l in out.splitlines() if l.startswith("Error:")), f"exit status {rc}")
    return f"error ({first.strip()})"


def apalache_outcome(rc, out, timed_out, inv):
    if timed_out:
        return "timeout"
    if rc == 0 and "The outcome is: NoError" in out:
        return "pass"
    if "The outcome is: Error" in out and inv:
        return f"violates:{inv}"
    first = next((l for l in out.splitlines() if "EXITCODE" in l or "rror" in l), f"exit status {rc}")
    return f"error ({first.strip()})"


def expected_outcome(row):
    """A witness row is judged like a mutant: it must violate exactly the named invariant."""
    if row.expected.startswith("witness:"):
        return "violates:" + row.expected.split(":", 1)[1]
    return row.expected


def run_row(row, java, cp, apalache, workers, timeout, scratch, log_dir, java_opts):
    work = Path(tempfile.mkdtemp(prefix=f"{row.model}-", dir=scratch))
    shutil.copytree(HERE / row.directory, work / "m")
    copy_common(work / "m")
    if row.tool == "tlc":
        cmd = [java, "-XX:+UseParallelGC", *java_opts, "-cp", cp, "tlc2.TLC", "-workers", str(workers),
               "-noGenerateSpecTE", "-metadir", str(work / "states"),
               "-config", row.config, f"{row.module}.tla"]
        rc, out, secs, timed_out = run(cmd, work / "m", timeout)
        got = tlc_outcome(rc, out, timed_out)
        states = re.findall(r"([\d,]+) distinct states found", out)
        size = f"{states[-1] if states else '?'} states"
    else:
        extra = shlex.split((HERE / row.directory / row.config).read_text(), comments=True)
        inv = next((a.split("=", 1)[1] for a in extra if a.startswith("--inv=")), None)
        cmd = [apalache, f"--out-dir={work / '_apalache-out'}", "check", *extra, f"{row.module}.tla"]
        rc, out, secs, timed_out = run(cmd, work / "m", timeout)
        got = apalache_outcome(rc, out, timed_out, inv)
        length = next((a.split("=", 1)[1] for a in extra if a.startswith("--length=")), "?")
        size = f"length {length}"
    log = log_dir / (row.name.replace("/", "_").replace(":", "__") + ".log")
    log.write_text(" ".join(cmd) + "\n\n" + out)
    shutil.rmtree(work, ignore_errors=True)
    return row, got, secs, size, log, out


def main():
    # One line per result, even when the output is a file or a pipe (a long run's progress).
    sys.stdout.reconfigure(line_buffering=True)
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tier", default="quick", choices=["quick", "deep", "all"])
    ap.add_argument("--model", action="append", help="only these models (repeatable)")
    ap.add_argument("--config", help="only rows whose config file name contains this")
    ap.add_argument("--tool", choices=["tlc", "apalache"], help="only rows run by this tool")
    ap.add_argument("--jobs", type=int, default=0, help="rows run at once (default: cores/4)")
    ap.add_argument("--workers", type=int, default=0, help="TLC workers per row (default: cores/jobs)")
    ap.add_argument("--timeout", type=int, default=0, help="seconds per row (default: 900 quick, 43200 deep)")
    ap.add_argument("--jar")
    ap.add_argument("--java")
    ap.add_argument("--apalache")
    ap.add_argument("--log-dir", help="where tool logs are kept (default: a temporary directory)")
    ap.add_argument("--java-opts", default=os.environ.get("ECO_TLA_JAVA_OPTS", ""),
                    help="extra JVM options for TLC, e.g. -Xmx4g (default: $ECO_TLA_JAVA_OPTS)")
    ap.add_argument("--list", action="store_true", help="list the selected rows and exit")
    args = ap.parse_args()

    rows = read_registry(HERE / "models.txt")
    rows = [r for r in rows if args.tier == "all" or r.tier == args.tier]
    if args.model:
        rows = [r for r in rows if r.model in args.model]
    if args.config:
        rows = [r for r in rows if args.config in r.config]
    if args.tool:
        rows = [r for r in rows if r.tool == args.tool]
    if args.list:
        for r in rows:
            print(f"{r.name:55s} {r.tier:6s} {r.tool:9s} expected {r.expected}")
        return 0
    if not rows:
        sys.exit("tla-check: no row selected")

    java, cp, apalache = find_tools(args, any(r.tool == "apalache" for r in rows))
    cores = os.cpu_count() or 2
    jobs = args.jobs or max(1, cores // 4)
    workers = args.workers or max(1, cores // jobs)
    timeout = args.timeout or (900 if args.tier == "quick" else 43200)
    scratch = Path(tempfile.mkdtemp(prefix="tla-check-"))
    log_dir = Path(args.log_dir) if args.log_dir else scratch / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)

    failures = []
    for d in sorted({r.directory for r in rows}):
        uses_apalache = any(r.directory == d and r.tool == "apalache" for r in rows)
        for p in check_modules(d, java, cp, apalache if uses_apalache else None, scratch):
            failures.append(p)
            print(f"FAIL  {p}")
    if failures:
        print(f"\ntla-check: {len(failures)} module problem(s); no model checked.")
        return 1
    print(f"tla-check: modules parse and translations are fresh; running {len(rows)} row(s), "
          f"{jobs} at a time with {workers} TLC worker(s) each")

    t_all = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        java_opts = shlex.split(args.java_opts)
        futs = [pool.submit(run_row, r, java, cp, apalache, workers, timeout, scratch, log_dir,
                            java_opts)
                for r in rows]
        for f in concurrent.futures.as_completed(futs):
            row, got, secs, size, log, out = f.result()
            ok = got == expected_outcome(row)
            print(f"{'ok  ' if ok else 'FAIL'}  {row.name:55s} {got:32s} {secs:7.1f}s  {size}")
            if not ok:
                failures.append(row.name)
                print(f"      expected {row.expected}; log: {log}")
                print("      " + "\n      ".join(out.splitlines()[-30:]))
    print(f"\ntla-check: {len(rows) - len(failures)}/{len(rows)} as expected "
          f"in {time.monotonic() - t_all:.0f}s; logs in {log_dir}")
    for p in scratch.iterdir():
        if p != log_dir:
            shutil.rmtree(p, ignore_errors=True)
    if args.log_dir:
        shutil.rmtree(scratch, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
