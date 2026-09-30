#!/usr/bin/env python3
"""Run the weak-memory drivers registered in drivers.txt under GenMC (RC11).

plans/threaded-gc-tla-W-weak-memory.md §3, §11; the shape of test/tla/run_models.py.
For every selected row it
  1. applies the row's header mutants (mutate.sh) to copies of the headers in a
     scratch directory, which goes first on the include path;
  2. compiles the driver to LLVM IR with the clang of GenMC's LLVM (the ordinary
     glibc / libstdc++ headers, -DWDRIVER_GENMC; see wdriver.hpp for why the IR is
     built here and not by GenMC's own compile step, which puts GenMC's C headers
     first on the path);
  3. runs `genmc -rc11 -disable-estimation -disable-ipr -disable-sr [row flags]
     <driver>.ll` and classifies the verdict from the error report's own graph:
       pass              "No errors were detected"
       assert:<expr>     "Safety violation": GenMC 0.19 prints no assertion text, so
                         the expression is read from the source line of the ERROR
                         event (wdriver.hpp makes assert fail at its own line)
       race              "Non-atomic race", with the two racing events
       uninit            "Attempt to read from uninitialized memory", with the event
       error:<kind>      any other GenMC error (mixed-size access, memory error, ...)
       compile-error, mutate-error, timeout, tool-error
  4. compares the verdict with the row's expected outcome (drivers.txt): an assert
     by its expression; a race or uninit by a racing event's variable (`race:bits`
     matches bits, bits[0], bits.x) or, for heap objects, which GenMC leaves
     unnamed, by its source line (`race:@<code>`: the line contains <code>).
     Alternatives are separated by `|`. A report outside the list fails the row,
     as does a pass of a mutant.

Usage: run_drivers.py [--only SUBSTR] [--jobs N] [--timeout SEC] [--log-dir DIR]
                      [--genmc PATH] [--clang PATH] [--list]
Tools: genmc on PATH, or /opt/genmc/bin/genmc, or --genmc / $GENMC; the clang of
GenMC's LLVM major (from `genmc --version`), /usr/lib/llvm-<major>/bin/clang++, or
--clang / $GENMC_CLANG. The opt-in dev layer (docker/eco-dev-genmc.Dockerfile)
provides both (docker/install-genmc.sh).
"""
import argparse
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
HEADERS = ROOT / "runtime" / "src" / "allocator"

# Flags every row gets. -disable-estimation: skip the state-space estimate GenMC
# otherwise runs first (it only prints a guess). -disable-ipr, -disable-sr:
# in-place revisiting (for assume-blocked reads) and symmetry reduction (for
# threads running the same code) each upgrade GenMC's "unordered writes"
# WARNING to an error. A failed SpinMutex::try_lock still writes true with its
# exchange, unordered with the holder's later unlock: benign, the ordinary
# test-and-set lock (W3f). Disabling an optimisation is sound.
GENMC_BASE = ["-rc11", "-disable-estimation", "-disable-ipr", "-disable-sr"]
CFLAGS = ["-std=c++20", "-fno-exceptions", "-g", "-fno-discard-value-names",
          "-Xclang", "-disable-O0-optnone", "-Wall", "-Wextra", "-DWDRIVER_GENMC"]


class Row:
    def __init__(self, lineno, name, source, options, expected):
        self.lineno = lineno
        self.name = name
        self.source = source
        self.defines, self.mutants, self.flags = [], [], []
        if options != "-":
            for tok in options.split(","):
                if tok.startswith("mutate:"):
                    self.mutants.append(tok.split(":", 1)[1])
                elif tok.startswith("genmc:"):
                    self.flags.append(tok.split(":", 1)[1])
                else:
                    self.defines.append("-D" + tok)
        self.expected = expected
        self.alternatives = [a.strip() for a in expected.split("|")]


def read_registry(path):
    rows, names = [], set()
    for n, line in enumerate(path.read_text().splitlines(), 1):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        f = line.split(None, 3)
        if len(f) != 4:
            sys.exit(f"{path}:{n}: expected: name file options expected")
        row = Row(n, *f)
        if row.name in names:
            sys.exit(f"{path}:{n}: duplicate row name {row.name}")
        names.add(row.name)
        if not (HERE / row.source).is_file():
            sys.exit(f"{path}:{n}: {row.source} does not exist")
        for a in row.alternatives:
            if not (a == "pass" or re.fullmatch(r"(race|uninit|assert):.+", a)):
                sys.exit(f"{path}:{n}: expected must be pass, race:<variable|@code>, "
                         f"uninit:<variable|@code> or assert:<expr> "
                         f"(alternatives separated by |), not {a!r}")
        if "pass" in row.alternatives and len(row.alternatives) > 1:
            sys.exit(f"{path}:{n}: pass cannot be an alternative")
        rows.append(row)
    return rows


def find_tools(args):
    genmc = args.genmc or os.environ.get("GENMC") or shutil.which("genmc")
    if not genmc and Path("/opt/genmc/bin/genmc").is_file():
        genmc = "/opt/genmc/bin/genmc"
    if not genmc or not Path(genmc).is_file():
        sys.exit("genmc-check: genmc not found. Use the eco-dev-genmc image (docker/eco-dev-genmc.Dockerfile, "
                 "which installs it with docker/install-genmc.sh), or pass --genmc / set $GENMC.")
    genmc = str(Path(genmc).resolve())
    ver = subprocess.run([genmc, "--version"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True).stdout
    m = re.search(r"LLVM (\d+)\.", ver)
    if not m:
        sys.exit(f"genmc-check: cannot read GenMC's LLVM version from `genmc --version`:\n{ver}")
    major = m.group(1)
    clang = args.clang or os.environ.get("GENMC_CLANG") or f"/usr/lib/llvm-{major}/bin/clang++"
    if not Path(clang).is_file():
        sys.exit(f"genmc-check: {clang} not found: the drivers must be compiled by the clang of "
                 f"GenMC's LLVM ({major}). Pass --clang or set $GENMC_CLANG.")
    runtime_inc = Path(genmc).parent.parent / "include" / "genmc" / "runtime"
    if not (runtime_inc / "genmc_internal.h").is_file():
        sys.exit(f"genmc-check: {runtime_inc}/genmc_internal.h not found")
    name = next((ln.strip() for ln in ver.splitlines() if "GenMC v" in ln), "GenMC ?")
    return genmc, clang, runtime_inc, f"{name}, LLVM {major}, {clang}"


def run(cmd, cwd, timeout):
    t0 = time.monotonic()
    try:
        p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, timeout=timeout)
        return p.returncode, p.stdout, time.monotonic() - t0, False
    except subprocess.TimeoutExpired as e:
        out = e.stdout if isinstance(e.stdout, str) else (e.stdout or b"").decode(errors="replace")
        return None, out, time.monotonic() - t0, True


# An access in GenMC's error graph: "\t(2, 1): Rna (_ZL7payload[8], 0) [INIT] w1_deque.cpp:52"
EVENT_LINE = re.compile(r"^\s*\((\d+), (\d+)\): (\S+)(.*)$")


def demangle(name):
    """GenMC prints a variable by its symbol (a static is `_ZL4bits`), plus any
    index or field suffix. Demangle the symbol part: `_ZL4bits[3]` -> `bits[3]`."""
    m = re.match(r"(_Z[A-Za-z0-9_]+)(.*)$", name)
    if not m:
        return name
    sym, rest = m.groups()
    cxxfilt = shutil.which("c++filt")
    if cxxfilt:
        p = subprocess.run([cxxfilt, sym], stdout=subprocess.PIPE, text=True)
        if p.returncode == 0 and p.stdout.strip():
            return p.stdout.strip() + rest
    m = re.fullmatch(r"_ZL(\d+)(\w+)", sym)
    return (m.group(2)[:int(m.group(1))] + rest) if m else name


class Event:
    """One event of GenMC's error graph, e.g.
         (2, 9): Wna (_ZL4bits[0], 17) mutate.hpp:35
         (1, 5): Rna (, 11) [(2, 9)] w5_forwarding.cpp:83     (heap: no name)
         (0, 35): ERROR w2_termination.cpp:123"""
    def __init__(self, kind, var, file, line, text):
        self.kind, self.var, self.file, self.line, self.text = kind, var, file, line, text

    def describe(self):
        where = f"{self.file}:{self.line}" if self.file else "?"
        return f"{self.var or '(heap)'} @{where}"


def source_line(name, line, dirs):
    for d in dirs:
        f = d / name
        if f.is_file():
            lines = f.read_text().splitlines()
            if 1 <= line <= len(lines):
                return lines[line - 1]
    return ""


def find_event(report, pos, dirs):
    for ln in report.splitlines():
        m = EVENT_LINE.match(ln)
        if not m or (m.group(1), m.group(2)) != pos:
            continue
        rest = m.group(4)
        v = re.match(r"\s*\(([^,()]*),", rest)
        loc = re.search(r"(\S+):(\d+)\s*$", rest)
        file, line = (loc.group(1), int(loc.group(2))) if loc else ("", 0)
        return Event(m.group(3), demangle(v.group(1).strip()) if v else "",
                     file, line, source_line(file, line, dirs) if file else "")
    return None


def assert_expression(text):
    """The expression of `assert(...)` on a source line (balanced parentheses)."""
    i = text.find("assert(")
    if i < 0:
        return None
    depth, j = 0, i + len("assert")
    for k in range(j, len(text)):
        depth += {"(": 1, ")": -1}.get(text[k], 0)
        if depth == 0:
            return text[j + 1:k].strip()
    return None


def classify(rc, out, timed_out, dirs):
    """GenMC's verdict: (outcome, events). Only the report's own graph is read (a
    log can hold earlier warning graphs, whose event numbers mean other events)."""
    if timed_out:
        return "timeout", []
    if "No errors were detected" in out and rc == 0:
        return "pass", []
    m = re.search(r"^Error: (.+?)!\s*$", out, re.M)
    if not m:
        return "tool-error", []
    report = out[m.start():]
    stop = re.search(r"^(Coherence:|\*\*\* )", report, re.M)
    report = report[:stop.start()] if stop else report
    kind = m.group(1).strip()
    pos = re.search(r"^Event \((\d+), (\d+)\) (?:conflicts with event \((\d+), (\d+)\) )?in graph:",
                    report, re.M)
    events = []
    if pos:
        events = [find_event(report, (pos.group(1), pos.group(2)), dirs)]
        if pos.group(3):
            events.append(find_event(report, (pos.group(3), pos.group(4)), dirs))
        events = [e for e in events if e]
    if kind == "Safety violation":
        err = events[0] if events else None
        if err is None:
            return "assert:?", []
        if err.file == "wdriver.hpp":
            return "assert:<an allocator-header assertion>", events
        expr = assert_expression(err.text)
        return ("assert:" + expr) if expr else f"assert:?@{err.file}:{err.line}", events
    if kind == "Non-atomic race":
        return "race", events
    if kind == "Attempt to read from uninitialized memory":
        return "uninit", events
    return "error:" + kind, events


def matches(alternative, outcome, events):
    if alternative == "pass":
        return outcome == "pass"
    if alternative.startswith("assert:"):
        norm = lambda s: " ".join(s.split())
        return outcome.startswith("assert:") and norm(outcome[7:]) == norm(alternative[7:])
    kind, want = alternative.split(":", 1)
    if outcome != kind:
        return False
    for e in events:
        if want.startswith("@"):
            if want[1:] in e.text:
                return True
        elif e.var == want or e.var.startswith(want + "[") or e.var.startswith(want + "."):
            return True
    return False


def run_row(row, genmc, clang, runtime_inc, timeout, scratch, log_dir):
    work = Path(tempfile.mkdtemp(prefix=f"{row.name}-", dir=scratch))
    log = log_dir / f"{row.name}.log"
    hdr = work / "hdr"
    hdr.mkdir()
    text = []
    for m in row.mutants:
        rc, out, _, _ = run(["sh", str(HERE / "mutate.sh"), m, str(HEADERS), str(hdr)], work, 60)
        text.append(f"$ mutate.sh {m}\n{out}")
        if rc != 0:
            log.write_text("\n".join(text))
            shutil.rmtree(work, ignore_errors=True)
            return row, "mutate-error", [], 0.0, "", log
    ll = work / (Path(row.source).stem + ".ll")
    cc = [clang, *CFLAGS, *row.defines, f"-I{hdr}", f"-I{HEADERS}", "-idirafter", str(runtime_inc),
          "-S", "-emit-llvm", "-o", str(ll), str(HERE / row.source)]
    rc, out, _, _ = run(cc, work, 300)
    text.append("$ " + " ".join(cc) + "\n" + out)
    if rc != 0:
        log.write_text("\n".join(text))
        shutil.rmtree(work, ignore_errors=True)
        return row, "compile-error", [], 0.0, "", log
    cmd = [genmc, *GENMC_BASE, *row.flags, str(ll)]
    rc, out, secs, timed_out = run(cmd, work, timeout)
    text.append("$ " + " ".join(cmd) + "\n" + out)
    log.write_text("\n".join(text))
    got, events = classify(rc, out, timed_out, [hdr, HERE, HEADERS])
    execs = re.search(r"Number of complete executions explored: (\d+)", out)
    blocked = re.search(r"Number of blocked executions seen: (\d+)", out)
    size = (f"{execs.group(1)} executions" if execs else "") + \
           (f", {blocked.group(1)} blocked" if blocked else "")
    shutil.rmtree(work, ignore_errors=True)
    return row, got, events, secs, size, log


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", action="append", help="only rows whose name contains this (repeatable)")
    ap.add_argument("--jobs", type=int, default=0, help="rows run at once (default: cores/4)")
    ap.add_argument("--timeout", type=int, default=300, help="seconds per row (default 300)")
    ap.add_argument("--genmc")
    ap.add_argument("--clang")
    ap.add_argument("--log-dir", help="where the logs are kept (default: a temporary directory)")
    ap.add_argument("--list", action="store_true", help="list the selected rows and exit")
    args = ap.parse_args()

    rows = read_registry(HERE / "drivers.txt")
    if args.only:
        rows = [r for r in rows if any(o in r.name for o in args.only)]
    if args.list:
        for r in rows:
            opts = " ".join(r.defines + [f"mutate:{m}" for m in r.mutants] + r.flags)
            print(f"{r.name:34s} {r.source:22s} {opts:55s} expected {r.expected}")
        return 0
    if not rows:
        sys.exit("genmc-check: no row selected")

    genmc, clang, runtime_inc, version = find_tools(args)
    jobs = args.jobs or max(1, (os.cpu_count() or 2) // 4)
    scratch = Path(tempfile.mkdtemp(prefix="genmc-check-"))
    log_dir = Path(args.log_dir) if args.log_dir else scratch / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    print(f"genmc-check: {version}; {len(rows)} row(s), {jobs} at a time")

    failures = []
    t_all = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futs = [pool.submit(run_row, r, genmc, clang, runtime_inc, args.timeout, scratch, log_dir)
                for r in rows]
        for f in concurrent.futures.as_completed(futs):
            row, got, events, secs, size, log = f.result()
            ok = any(matches(a, got, events) for a in row.alternatives)
            shown = got if got in ("pass", "timeout", "tool-error") or got.startswith("assert:") \
                else got + ": " + " / ".join(e.describe() for e in events)
            print(f"{'ok  ' if ok else 'FAIL'}  {row.name:34s} {shown:40s} {secs:7.1f}s  {size}")
            if not ok:
                failures.append(row.name)
                print(f"      expected {row.expected}; log: {log}")
    print(f"\ngenmc-check: {len(rows) - len(failures)}/{len(rows)} as expected "
          f"in {time.monotonic() - t_all:.0f}s; logs in {log_dir}")
    for p in scratch.iterdir():
        if p != log_dir:
            shutil.rmtree(p, ignore_errors=True)
    if args.log_dir:
        shutil.rmtree(scratch, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
