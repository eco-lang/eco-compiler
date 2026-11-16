#!/usr/bin/env python3
"""Coverage driver for the coverage-driven test loop (plans/coverage-driven-test-generation.md).

Coverage of compiler/src is measured by instrumenting it with elm-instrument (compiler/elm-coverage)
and running two suites against the instrumented build:

  elm-test  the elm-test-rs suite, through elm-coverage;
  E2E       the JIT E2E suite (build/test/test) and the JS-target E2E suite (run-js-e2e.js), whose
            compiles go through a guida.js built from the same instrumented sources and handed to
            the harnesses through GUIDA_JS_PATH.

Commands:

  setup       install elm-coverage's node modules and build its analyzer (once per checkout)
  baseline    run both suites in full under coverage and store the result in build/coverage/baseline
              (about 15 min elm-test + 10 min E2E; moves the per-test eco-stuff caches aside)
  quick       run a filtered elm-test run (default filter "coverage run", about 25 s) and optionally
              compile some E2E test files with an instrumented compiler; store the counts as a quick file
  workspace   create /tmp/eco-cov-agents/NAME/compiler, a private copy of the tests for one agent
  diff        list the test files a workspace changed
  report      merge the baseline with quick files and print coverage of the loop's scope; with
              --module, list that module's unreached annotations; with --write-tracker, update
              compiler/coverage/tracker.csv
  gap         compare the suites: what elm-test reaches and E2E (baseline plus quick --e2e
              compiles) does not, by folder, module or annotation
  html        elm-coverage's HTML report of each baseline suite, in build/coverage/html/<suite>

A module's baseline counts are used only while its source is unchanged (sha1 recorded at baseline
time); an edited module is measured by quick runs alone until the next baseline.

Code that calls System.Crash.crash / Eco.Crash.crash / Debug.todo directly as a branch or body is
excluded from coverage automatically, and any hit on it is reported, because reaching it means a
bug. Other exclusions (default-off flags, provably unreachable code) are listed in
compiler/coverage/exclusions.csv.
"""

import argparse
import csv
import glob
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

WORK = "/work"
COMPILER = f"{WORK}/compiler"
BUILD = f"{WORK}/build"
BASE = f"{BUILD}/coverage"
BASELINE = f"{BASE}/baseline"
QUICK = f"{BASE}/quick"
TOOLCHAIN = f"{BUILD}/toolchain/bin"
ELM_COVERAGE = f"{COMPILER}/elm-coverage"
LOOP_DIR = f"{COMPILER}/coverage"
TRACKER = f"{LOOP_DIR}/tracker.csv"
EXCLUSIONS = f"{LOOP_DIR}/exclusions.csv"

# The loop's scope: the typed pipeline from type checking to MLIR, plus type error reporting.
SCOPE_PREFIXES = [
    "Compiler.Type.",
    "Compiler.Reporting.Render.Type",
    "Compiler.LocalOpt.Typed.",
    "Compiler.PreMono.",
    "Compiler.Monomorphize.",
    "Compiler.MonoOpt.",
    "Compiler.GenerateMlir.",
    "Mlir.",
]

FOLDER_ORDER = [
    "Compiler.Type", "Compiler.Reporting", "Compiler.LocalOpt", "Compiler.PreMono",
    "Compiler.Monomorphize", "Compiler.MonoOpt", "Compiler.GenerateMlir", "Mlir",
]

BRANCH_TYPES = ("caseBranch", "ifElseBranch")
CRASH_RE = re.compile(r"^\(*\s*(?:(?:System\.)?Crash\.|Eco\.Crash\.)?crash\b|^\(*\s*Debug\.todo\b")


def in_scope(module):
    return any(module.startswith(p) or module == p.rstrip(".") for p in SCOPE_PREFIXES)


def folder_of(module):
    parts = module.split(".")
    if parts[0] == "Compiler" and len(parts) > 2:
        return "Compiler." + parts[1]
    return parts[0]


def module_path(root, module):
    return os.path.join(root, "src", *module.split(".")) + ".elm"


def sha1_file(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha1(f.read()).hexdigest()
    except FileNotFoundError:
        return None


def run(cmd, **kw):
    print("+ " + (cmd if isinstance(cmd, str) else " ".join(cmd)), flush=True)
    return subprocess.run(cmd, **kw)


def tool_env(extra=None):
    env = dict(os.environ)
    env["PATH"] = TOOLCHAIN + os.pathsep + env.get("PATH", "")
    if extra:
        env.update(extra)
    return env


# ---------------------------------------------------------------------------------------------
# Data files
# ---------------------------------------------------------------------------------------------

def merge_data_files(paths):
    """Sums elm-coverage data files ({module: {index: count}}) into one dict."""
    out = {}
    for p in paths:
        with open(p) as f:
            d = json.load(f)
        for mod, counts in d.items():
            m = out.setdefault(mod, {})
            if isinstance(counts, list):
                for i in counts:
                    m[str(i)] = m.get(str(i), 0) + 1
            else:
                for i, c in counts.items():
                    m[i] = m.get(i, 0) + c
    return out


def load_json(path):
    with open(path) as f:
        return json.load(f)


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, separators=(",", ":"))
    os.replace(tmp, path)


# ---------------------------------------------------------------------------------------------
# Running elm-test under coverage
# ---------------------------------------------------------------------------------------------

def run_elm_coverage(root, filt, workers, log_path):
    """Instruments root/src and runs elm-test-rs in root/.coverage/instrumented. Returns the
    merged counts, the info.json annotations and the test summary lines."""
    args = ["node", f"{ELM_COVERAGE}/bin/elm-coverage", "src/", "--tests", "tests/",
            "--elm-test", "elm-test-rs", "--report", "json", "--force", "--",
            "--workers", str(workers), "--fuzz", "1"]
    if filt:
        args += ["--filter", filt]
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    t0 = time.time()
    with open(log_path, "w") as log:
        r = subprocess.run(args, cwd=root, env=tool_env(), stdout=log, stderr=subprocess.STDOUT,
                           preexec_fn=no_core_dumps)
    dt = time.time() - t0
    cov = os.path.join(root, ".coverage")
    data = merge_data_files(glob.glob(os.path.join(cov, "instrumented", "data-*.json")))
    info = load_json(os.path.join(cov, "info.json"))
    summary = test_summary(log_path)
    print(f"elm-test under coverage: {dt:.0f} s, rc {r.returncode}; " + "; ".join(summary["lines"]))
    if not data:
        print("WARNING: no coverage data was written; the tests did not run. See " + log_path)
    return data, info, summary


def test_summary(log_path):
    with open(log_path, errors="replace") as f:
        text = f.read()
    lines = [l.strip() for l in text.splitlines() if re.match(r"^\s*(Passed|Failed|Duration|TEST RUN)", l)]
    failures = re.findall(r"^\s*✗\s*(.*)$", text, re.M)
    compile_error = "-- " in text and "Failed to read newly created file" in text
    return {"lines": lines, "failures": failures, "compile_error": compile_error}


def no_core_dumps():
    import resource
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


# ---------------------------------------------------------------------------------------------
# Instrumented guida.js and E2E compiles
# ---------------------------------------------------------------------------------------------

def build_instrumented_guida(root, out_dir, data_dir):
    """Builds guida.js from root/.coverage/instrumented, with its coverage counters writing
    data-<pid>-<tid>.json files into data_dir."""
    inst = os.path.join(root, ".coverage", "instrumented")
    shutil.rmtree(out_dir, ignore_errors=True)
    os.makedirs(os.path.join(out_dir, "bin"))
    os.makedirs(data_dir, exist_ok=True)
    shutil.copytree(os.path.join(inst, "src"), os.path.join(out_dir, "src"), symlinks=True)
    shutil.copytree(os.path.join(inst, "src-xhr"), os.path.join(out_dir, "src-xhr"), symlinks=True)
    shutil.copytree(f"{BUILD}/compiler/version", os.path.join(out_dir, "version"), symlinks=True)
    shutil.copy(f"{BUILD}/compiler/build-xhr/elm.json", out_dir)
    guida = os.path.join(out_dir, "bin", "guida.js")
    r = run(["node", f"{ELM_COVERAGE}/bin/fake-elm", "make", f"--output={guida}", "src/Terminal/Main.elm"],
            cwd=out_dir, env=tool_env({"ELM_COVERAGE_DIR": data_dir}))
    if r.returncode != 0 or not os.path.exists(guida):
        sys.exit("building the instrumented guida.js failed")
    run(["node", f"{COMPILER}/scripts/replacements.js", guida], check=True)
    with open(guida) as f:
        if "INJECTED COVERAGE FIXTURE" not in f.read():
            sys.exit("the coverage hook was not injected into guida.js")
    return guida


def eco_home_version():
    vs = sorted(os.listdir(os.path.expanduser("~/.eco")))
    return vs[-1] if vs else "0.2.0"


def compile_e2e_files(guida, files, tag, js=False):
    """Compiles each E2E test file with the instrumented guida.js (no JIT run): coverage only. With
    js, to JavaScript (the JS backend, as run-js-e2e.js does). A `-- COMPILE-ERROR:` test is
    expected to fail to compile."""
    ok = True
    for f in files:
        f = os.path.abspath(f)
        m = re.match(rf"{WORK}/test/([^/]+)/src/", f)
        if not m:
            sys.exit(f"{f}: not an E2E test file (expected /work/test/<suite>/src/...)")
        suite_dir = f"{BUILD}/test/{m.group(1)}"
        if not os.path.exists(os.path.join(suite_dir, "elm.json")):
            sys.exit(f"{suite_dir}/elm.json missing: build the test target once first")
        out = f"{QUICK}/{tag}-{'js' if js else 'mlir'}/{os.path.basename(f)[:-4]}.{'js' if js else 'mlir'}"
        os.makedirs(os.path.dirname(out), exist_ok=True)
        builddir = f"covq-{tag}"
        with open(f) as src:
            text_mlir = " --text-mlir" if not js and re.search(r"^-- TEXT-MLIR:", src.read(), re.M) else ""
        r = subprocess.run(f'ulimit -s unlimited 2>/dev/null; node --stack-size=50000 {COMPILER}/bin/index.js '
                           f'make "{f}" --output="{out}" --builddir={builddir}{text_mlir}',
                           shell=True, cwd=suite_dir, env=dict(os.environ, GUIDA_JS_PATH=guida),
                           capture_output=True, text=True)
        with open(f) as src:
            expect_error = re.search(r"^-- COMPILE-ERROR:", src.read(), re.M) is not None
        compiled = r.returncode == 0 and os.path.exists(out)
        if expect_error:
            status = "FAILED (compiled, but COMPILE-ERROR expected)" if compiled else "ok (rejected)"
        else:
            status = "ok" if compiled else "FAILED"
        ok = ok and status.startswith("ok")
        print(f"  E2E compile{' (js)' if js else ''} {os.path.basename(f)}: {status}")
        if not status.startswith("ok"):
            print((r.stdout + r.stderr)[-3000:])
        shutil.rmtree(os.path.join(suite_dir, "eco-stuff", eco_home_version(), builddir), ignore_errors=True)
    return ok


# ---------------------------------------------------------------------------------------------
# baseline
# ---------------------------------------------------------------------------------------------

def cmd_baseline(a):
    root = COMPILER
    if a.import_dirs:
        et_dir, e2_dir, info_path = a.import_dirs
        et = merge_data_files(glob.glob(f"{et_dir}/data-*.json"))
        e2 = merge_data_files(glob.glob(f"{e2_dir}/data-*.json"))
        info = load_json(info_path)
        write_baseline(root, info, et, e2, {"imported": a.import_dirs})
        return
    t0 = time.time()
    pre_hashes = {}
    for dirpath, _, files in os.walk(os.path.join(root, "src")):
        for fn in files:
            if fn.endswith(".elm"):
                path = os.path.join(dirpath, fn)
                pre_hashes[os.path.relpath(path, os.path.join(root, "src"))[:-4].replace(os.sep, ".")] = sha1_file(path)
    et, info, summ = run_elm_coverage(root, None, a.workers, f"{BASELINE}/elm-test.log")
    post = {m: sha1_file(module_path(root, m)) for m in info}
    moved = [m for m in info if post[m] != pre_hashes.get(m)]
    if moved:
        sys.exit(f"compiler sources changed during the baseline run ({', '.join(moved[:5])}); run it again")
    if summ["failures"] or not et:
        print("elm-test failures under coverage:\n  " + "\n  ".join(summ["failures"][:30]))
    if a.elm_test_only:
        # Keep the stored E2E counts; they stay valid for every module whose source is unchanged,
        # which write_baseline cannot check, so refuse when a module's source changed.
        old_hashes = load_json(f"{BASELINE}/hashes.json")
        changed = [m for m in info if old_hashes.get(m) != sha1_file(module_path(root, m))]
        if changed:
            sys.exit(f"--elm-test-only: {len(changed)} modules changed since the E2E baseline "
                     f"({', '.join(changed[:5])}); run a full baseline")
        meta = load_json(f"{BASELINE}/meta.json")
        meta.update({"elm_test": summ["lines"], "elm_test_failures": summ["failures"],
                     "elm_test_only_rerun": time.strftime("%Y-%m-%d %H:%M:%S")})
        write_baseline(root, info, et, load_json(f"{BASELINE}/e2e.json"), meta)
        return
    guida = build_instrumented_guida(root, f"{BASE}/guida-baseline", f"{BASE}/baseline-e2e-data")
    for p in glob.glob(f"{BASE}/baseline-e2e-data/data-*.json"):
        os.remove(p)
    # Every E2E test program must be recompiled: move the per-test caches aside.
    aside = f"{BASE}/eco-stuff-aside"
    shutil.rmtree(aside, ignore_errors=True)
    os.makedirs(aside)
    for d in glob.glob(f"{BUILD}/test/*/eco-stuff"):
        shutil.move(d, os.path.join(aside, d.split("/")[-2]))
    log = "/tmp/test_output.txt"
    r = run(f"ulimit -c 0; {BUILD}/test/test 2>&1 | tee {log} | tail -8", shell=True,
            env=dict(os.environ, GUIDA_JS_PATH=guida))
    with open(log, errors="replace") as f:
        tail = f.read()[-2000:]
    m = re.search(r"Tests run:\s*(\d+).*?Tests passed:\s*(\d+).*?Tests failed:\s*(\d+)", tail, re.S)
    js_summary = run_js_e2e_under_coverage(guida)
    e2 = merge_data_files(glob.glob(f"{BASE}/baseline-e2e-data/data-*.json"))
    meta = {"elm_test": summ["lines"], "elm_test_failures": summ["failures"],
            "e2e": m.groups() if m else "unknown", "e2e_js": js_summary,
            "minutes": round((time.time() - t0) / 60, 1)}
    write_baseline(root, info, et, e2, meta)
    shutil.rmtree(aside, ignore_errors=True)


def run_js_e2e_under_coverage(guida):
    """The JS-target E2E suite (test/scripts/run-js-e2e.js, the only E2E path through the JS
    backend) compiled by the instrumented guida.js, in a build directory of its own so that every
    test is recompiled and the normal JS E2E outputs are left alone. Returns its summary line."""
    work = f"{BASE}/js-e2e-build"
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work)
    log = f"{BASELINE}/js-e2e.log"
    run(f"node {WORK}/test/scripts/run-js-e2e.js --build-dir {work} --repo-root {WORK} > {log} 2>&1",
        shell=True, env=dict(os.environ, GUIDA_JS_PATH=guida))
    with open(log, errors="replace") as f:
        lines = [l.strip() for l in f if l.startswith("Tests run:")]
    print("JS E2E under coverage: " + (lines[-1] if lines else f"no summary, see {log}"))
    return lines[-1] if lines else "unknown"


def write_baseline(root, info, et, e2, meta):
    hashes = {mod: sha1_file(module_path(root, mod)) for mod in info}
    save_json(f"{BASELINE}/info.json", info)
    save_json(f"{BASELINE}/elm-test.json", et)
    save_json(f"{BASELINE}/e2e.json", e2)
    save_json(f"{BASELINE}/hashes.json", hashes)
    meta["time"] = time.strftime("%Y-%m-%d %H:%M:%S")
    save_json(f"{BASELINE}/meta.json", meta)
    print(f"baseline written to {BASELINE}: {len(et)} modules hit by elm-test, {len(e2)} by E2E")


# ---------------------------------------------------------------------------------------------
# quick
# ---------------------------------------------------------------------------------------------

def cmd_quick(a):
    root = os.path.abspath(a.root)
    if a.tag:
        tag = a.tag
    elif root.startswith(WORKSPACES + "/"):
        tag = root[len(WORKSPACES) + 1:].split("/")[0]
    else:
        tag = "main"
    if not a.tag and a.filter != "coverage run":
        # A filtered run measures part of the suite: keep it out of the agent's main quick file.
        tag += "-filtered"
    # Hash the sources before instrumenting them: a module edited while the tests run must not
    # be recorded with its new hash against counts of the old instrumented copy.
    hashes = {}
    for dirpath, _, files in os.walk(os.path.join(root, "src"), followlinks=True):
        for fn in files:
            if fn.endswith(".elm"):
                path = os.path.join(dirpath, fn)
                mod = os.path.relpath(path, os.path.join(root, "src"))[:-4].replace(os.sep, ".")
                hashes[mod] = sha1_file(path)
    data, info, summ = run_elm_coverage(root, a.filter, a.workers, f"{QUICK}/{tag}.log")
    e2_data = {}
    if a.e2e or a.e2e_js:
        ddir = f"{QUICK}/{tag}-e2edata"
        shutil.rmtree(ddir, ignore_errors=True)
        guida = build_instrumented_guida(root, f"{QUICK}/{tag}-guida", ddir)
        if a.e2e:
            compile_e2e_files(guida, a.e2e, tag)
        if a.e2e_js:
            compile_e2e_files(guida, a.e2e_js, tag, js=True)
        e2_data = merge_data_files(glob.glob(f"{ddir}/data-*.json"))
    hashes = {mod: hashes.get(mod) for mod in info}
    out = f"{QUICK}/{tag}.json"
    save_json(out, {"root": root, "filter": a.filter, "info": info, "hashes": hashes,
                    "elm_test": data, "e2e": e2_data, "summary": summ, "time": time.strftime("%H:%M:%S")})
    print(f"quick counts written to {out}")
    if summ["failures"]:
        print("FAILING TESTS:\n  " + "\n  ".join(summ["failures"]))
    if summ["compile_error"]:
        print("THE TESTS DID NOT COMPILE: see " + f"{QUICK}/{tag}.log")
    if a.report:
        report(root, [out], a.module, a.folder, False, a.all)


# ---------------------------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------------------------

DEF_RE = re.compile(r"^([a-z_]\w*)\b[^:]*=\s*(?:--.*)?$|^([a-z_]\w*)\b[^:]*=\s*\S")


def decl_ranges(src):
    """{name: (first line, last line)} of each top-level definition: from its `name ... =` line
    to the line before the next one."""
    starts = []
    for i, l in enumerate(src):
        m = DEF_RE.match(l)
        if m and not l.startswith(("type ", "port ", "import ", "module ")):
            starts.append((i + 1, m.group(1) or m.group(2)))
    out = {}
    for k, (line, name) in enumerate(starts):
        end = starts[k + 1][0] - 1 if k + 1 < len(starts) else len(src)
        out.setdefault(name, (line, end))
    return out


def decl_at(src, line):
    best = None
    for name, (lo, hi) in decl_ranges(src).items():
        if lo <= line <= hi:
            best = name
    return best


def load_exclusions(root=COMPILER):
    """exclusions.csv rows: module, line, kind, reason, anchor. `line` is a line number, a range
    `lo-hi` (every annotation starting in it), or `*` (the whole module). `anchor` is the stripped
    text of line `lo`: when the code has moved, the row is moved to the line with that text (and
    `hi` by the same amount), so edits elsewhere in a module do not orphan it. An anchor that
    matches several lines takes the match nearest to the shift of the nearest unambiguous row."""
    whole, ranges = {}, {}
    if not os.path.exists(EXCLUSIONS):
        return whole, ranges
    sources = {}
    pending = {}
    with open(EXCLUSIONS) as f:
        for row in csv.DictReader(f):
            mod, line = row["module"].strip(), row["line"].strip()
            if line == "*":
                whole[mod] = row
                continue
            lo, _, hi = line.partition("-")
            pending.setdefault(mod, []).append((int(lo), int(hi or lo), row))
    for mod, rows in pending.items():
        src = module_source(root, mod) or []
        where = {}
        for i, l in enumerate(src):
            where.setdefault(l.strip(), []).append(i + 1)
        decls = decl_ranges(src)

        def in_decl(row, cands):
            # A row with a `decl` only moves within that top-level definition.
            d = (row.get("decl") or "").strip()
            if not d or d not in decls:
                return cands
            lo, hi = decls[d]
            return [c for c in cands if lo <= c <= hi]
        # Pass 1: rows whose anchor is in place, or matches exactly one line, give the shift of
        # their part of the module. Pass 2: a row whose anchor matches several lines (e.g.
        # `Nothing`) takes the match nearest to where the nearest pass-1 row's shift puts it.
        shifts = []
        placed = {}
        for k, (lo, hi, row) in enumerate(rows):
            anchor = (row.get("anchor") or "").strip()
            if not anchor:
                placed[k] = (lo, hi)
                continue
            if 0 < lo <= len(src) and src[lo - 1].strip() == anchor:
                placed[k] = (lo, hi)
                shifts.append((lo, 0))
            elif len(in_decl(row, where.get(anchor, []))) == 1:
                new_lo = in_decl(row, where[anchor])[0]
                placed[k] = (new_lo, hi + new_lo - lo)
                shifts.append((lo, new_lo - lo))
        for k, (lo, hi, row) in enumerate(rows):
            if k in placed:
                continue
            cands = in_decl(row, where.get((row.get("anchor") or "").strip(), []))
            if not cands:
                placed[k] = (lo, hi)
                continue
            delta = min(shifts, key=lambda s: abs(s[0] - lo))[1] if shifts else 0
            new_lo = min(cands, key=lambda c: abs(c - (lo + delta)))
            placed[k] = (new_lo, hi + new_lo - lo)
        for k, (lo, hi, row) in enumerate(rows):
            nlo, nhi = placed[k]
            if (nlo, nhi) != (lo, hi):
                row["relocated"] = f"{nlo}-{nhi}" if nhi != nlo else str(nlo)
            ranges.setdefault(mod, []).append((nlo, nhi, row))
    return whole, ranges


def cmd_exclusions(a):
    """Adds missing anchors (from the current sources) and, with --rewrite, writes relocated line
    numbers back to exclusions.csv."""
    whole, ranges = load_exclusions()
    with open(EXCLUSIONS) as f:
        rows = list(csv.DictReader(f))
    moved = added = skipped = 0
    sources = {}
    baseline_hashes = load_json(f"{BASELINE}/hashes.json") if os.path.exists(f"{BASELINE}/hashes.json") else {}
    for row in rows:
        mod, line = row["module"].strip(), row["line"].strip()
        if line == "*":
            row.setdefault("anchor", "")
            continue
        match = next((r for lo, hi, r in ranges.get(mod, []) if r is row or
                      (r["line"] == row["line"] and r["reason"] == row["reason"])), None)
        if match is not None and match.get("relocated"):
            row["line"] = match["relocated"]
            moved += 1
        if not (row.get("anchor") or "").strip():
            # Fill an anchor only where the recorded line is known to be current: the module is
            # unchanged since the baseline the row was written against (or --anchor-changed).
            if not a.anchor_changed and baseline_hashes.get(mod) != sha1_file(module_path(COMPILER, mod)):
                skipped += 1
                continue
            if mod not in sources:
                sources[mod] = module_source(COMPILER, mod) or []
            lo = int(row["line"].split("-")[0])
            if 0 < lo <= len(sources[mod]):
                row["anchor"] = sources[mod][lo - 1].strip()
                added += 1
    for row in rows:
        mod, line = row["module"].strip(), row["line"].strip()
        if line == "*" or (row.get("decl") or "").strip():
            continue
        if not a.anchor_changed and baseline_hashes.get(mod) != sha1_file(module_path(COMPILER, mod)):
            continue
        if mod not in sources:
            sources[mod] = module_source(COMPILER, mod) or []
        row["decl"] = decl_at(sources[mod], int(line.split("-")[0])) or ""
    print(f"{moved} rows relocated, {added} anchors added"
          + (f", {skipped} rows of changed modules left unanchored (check their lines, then --anchor-changed)" if skipped else ""))
    if a.rewrite:
        with open(EXCLUSIONS, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["module", "line", "kind", "reason", "anchor", "decl"],
                               extrasaction="ignore", lineterminator="\n")
            w.writeheader()
            for row in rows:
                w.writerow(row)
        print(f"rewrote {EXCLUSIONS}")


def body_text(src_lines, ann):
    """The source text of an annotation's expression, from its start position, first 300 chars."""
    fl, fc = ann["from"]["line"], ann["from"]["column"]
    tl = ann["to"]["line"]
    text = src_lines[fl - 1][fc - 1:] + " " + " ".join(l.strip() for l in src_lines[fl:min(tl, fl + 6)])
    if ann["type"] == "declaration":
        # A declaration's range starts at its name; its body follows the first `=`.
        i = text.find("=")
        text = text[i + 1:] if i >= 0 else text
    return text.strip()[:300]


def crash_annotations(src_lines, anns, helpers, imports, mod):
    """Indices of annotations whose expression is a direct crash or a call of a crash helper."""
    return {i for i, a in enumerate(anns) if is_crash(body_text(src_lines, a), helpers, imports, mod)}


IMPORT_RE = re.compile(r"^import\s+([\w.]+)(?:\s+as\s+(\w+))?(?:\s+exposing\s*\((.*?)\))?\s*$", re.S)


def parse_imports(src_lines):
    """{qualifier: module} and {exposed name: module} of one module's imports. An import spans
    its `import` line and the indented lines after it."""
    quals, exposed = {}, {}
    i = 0
    while i < len(src_lines):
        line = src_lines[i]
        if line.startswith("import "):
            text = line
            while i + 1 < len(src_lines) and src_lines[i + 1][:1] in (" ", "\t") and src_lines[i + 1].strip():
                i += 1
                text += " " + src_lines[i].strip()
            m = IMPORT_RE.match(text.strip())
            if m:
                mod, alias, exp = m.groups()
                quals[mod] = mod
                if alias:
                    quals[alias] = mod
                for name in (exp or "").split(","):
                    name = name.strip()
                    if re.match(r"^[a-z]\w*$", name):
                        exposed[name] = mod
                    elif name == "..":
                        exposed.setdefault("..", []).append(mod)
        i += 1
    return quals, exposed


def module_source(root, mod):
    try:
        with open(module_path(root, mod)) as f:
            return f.read().split("\n")
    except FileNotFoundError:
        return None


def crash_helpers(root, info):
    """{(module, name)} of declarations whose body is a crash or a call of another crash helper
    (e.g. Engine's `crashFailure f = Crash.crash (renderFailure f)`), to a fixed point, plus each
    module's parsed imports."""
    decls, imports = [], {}
    for mod, anns in info.items():
        src = module_source(root, mod)
        if src is None:
            continue
        imports[mod] = parse_imports(src)
        for a in anns:
            if a["type"] == "declaration" and a.get("name"):
                decls.append((mod, a["name"], body_text(src, a)))
    helpers = set()
    changed = True
    while changed:
        changed = False
        for mod, name, text in decls:
            if (mod, name) not in helpers and is_crash(text, helpers, imports, mod):
                helpers.add((mod, name))
                changed = True
    return helpers, imports


# Deliberate rejections of an unsupported feature: they abort through a crash helper but mark
# no bug, so they are measured as ordinary code (e.g. the solver's shader rejection).
NOT_CRASH_RE = re.compile(r"^[(\s]*(?:[A-Z]\w*\.)*crashFailure\s*\(\s*Unsupported\b")


def is_crash(text, helpers, imports, mod):
    if NOT_CRASH_RE.match(text):
        return False
    if CRASH_RE.match(text):
        return True
    m = re.match(r"^[(\s]*((?:[A-Z]\w*\.)*)([a-z]\w*)\b", text)
    if not m:
        return False
    qual, name = m.group(1).rstrip("."), m.group(2)
    quals, exposed = imports.get(mod, ({}, {}))
    if qual:
        target = quals.get(qual)
        return target is not None and (target, name) in helpers
    if (mod, name) in helpers:
        return True
    if name in exposed and isinstance(exposed[name], str):
        return (exposed[name], name) in helpers
    return any((m2, name) in helpers for m2 in exposed.get("..", []))


def collect(root, quick_paths, quick_elm_test=True):
    """Merged counts per (module, index): {module: [et_count, e2_count] per annotation}. With
    quick_elm_test=False a quick file adds only its E2E counts."""
    info = load_json(f"{BASELINE}/info.json")
    hashes = load_json(f"{BASELINE}/hashes.json")
    base_et = load_json(f"{BASELINE}/elm-test.json")
    base_e2 = load_json(f"{BASELINE}/e2e.json")
    quicks = [load_json(p) for p in quick_paths]
    # A module's annotations come from a run of its current source: the baseline while the
    # module is unchanged, otherwise a quick file whose recorded hash matches the source now.
    cur_hash = {}
    cur_info = {}
    for mod in set(info) | {m for q in quicks for m in q["info"]}:
        h = sha1_file(module_path(root, mod))
        cur_hash[mod] = h
        if hashes.get(mod) == h and mod in info:
            cur_info[mod] = info[mod]
            continue
        for q in quicks:
            if q["hashes"].get(mod) == h and mod in q["info"]:
                cur_info[mod] = q["info"][mod]
                break
        else:
            cur_info[mod] = info.get(mod) or next(q["info"][mod] for q in quicks if mod in q["info"])
    out = {}
    stale = []
    for mod, anns in cur_info.items():
        h = cur_hash[mod]
        et = [0] * len(anns)
        e2 = [0] * len(anns)
        if hashes.get(mod) == h and len(info.get(mod, [])) == len(anns):
            for i, c in base_et.get(mod, {}).items():
                et[int(i)] += c
            for i, c in base_e2.get(mod, {}).items():
                e2[int(i)] += c
        elif in_scope(mod):
            stale.append(mod)
        for q in quicks:
            if q["hashes"].get(mod) != h or len(q["info"].get(mod, [])) != len(anns):
                continue
            for i, c in (q["elm_test"] if quick_elm_test else {}).get(mod, {}).items():
                et[int(i)] += c
            for i, c in q["e2e"].get(mod, {}).items():
                e2[int(i)] += c
        out[mod] = (anns, et, e2)
    return out, stale


def module_stats(root, mod, anns, et, e2, excl_whole, excl_lines, helpers):
    path = module_path(root, mod)
    with open(path) as f:
        src = f.read().split("\n")
    helpers, imports = helpers
    crash_idx = crash_annotations(src, anns, helpers, imports, mod)
    excl_here = excl_lines.get(mod, [])
    rows = []
    for i, a in enumerate(anns):
        hit = et[i] + e2[i]
        line = a["from"]["line"]
        excluded = None
        if mod in excl_whole:
            excluded = excl_whole[mod]["kind"]
        elif i in crash_idx:
            excluded = "crash"
        else:
            # A listed line or range excludes every annotation starting in it.
            for lo, hi, row in excl_here:
                if lo <= line <= hi:
                    excluded = row["kind"]
                    break
        if excluded == "flag" and e2[i] and mod not in excl_whole:
            # E2E runs at the default flags: what it reaches is default code (typically the
            # `if not cfg.flag then ...` guard at the top of a gated range), so it is measured.
            excluded = None
        rows.append({"i": i, "type": a["type"], "line": line, "col": a["from"]["column"],
                     "name": a.get("name"), "et": et[i], "e2": e2[i], "hit": hit, "excluded": excluded,
                     "text": body_text(src, a)})
    starts = [r["line"] for r in rows]
    stale_excl = [f"{lo}-{hi}" if hi != lo else str(lo) for lo, hi, _ in excl_here
                  if not any(lo <= l <= hi for l in starts)]
    return rows, stale_excl


def summarize(rows):
    def cnt(pred):
        sel = [r for r in rows if pred(r)]
        return sum(1 for r in sel if r["hit"]), len(sel)
    return {
        "branches": cnt(lambda r: r["type"] in BRANCH_TYPES and not r["excluded"]),
        "decls": cnt(lambda r: r["type"] == "declaration" and not r["excluded"]),
        "all": cnt(lambda r: not r["excluded"]),
        "excluded": sum(1 for r in rows if r["excluded"]),
        "crash_hits": [r for r in rows if r["excluded"] == "crash" and r["hit"]],
    }


def pct(c, t):
    return f"{100 * c / t:5.1f}%" if t else "    – "


def report(root, quick_paths, module, folder, write_tracker, show_all):
    data, stale = collect(root, quick_paths)
    excl_whole, excl_lines = load_exclusions(root)
    mods = sorted(m for m in data if in_scope(m))
    helpers = crash_helpers(root, {m: data[m][0] for m in data})
    stats = {}
    all_crash = []
    for m in mods:
        rows, stale_excl = module_stats(root, m, *data[m], excl_whole, excl_lines, helpers)
        s = summarize(rows)
        s["rows"], s["stale_excl"] = rows, stale_excl
        stats[m] = s
        all_crash += [(m, r) for r in s["crash_hits"]]

    if module:
        show_module(module, stats.get(module) or sys.exit(f"{module}: not in scope or unknown"), show_all)
    else:
        print_summary(stats, folder)

    if stale:
        print(f"\nNOTE: {len(stale)} in-scope modules changed since the baseline; their baseline counts "
              f"are not used: {', '.join(stale[:8])}{' ...' if len(stale) > 8 else ''}")
    stale_all = [(m, s["stale_excl"]) for m, s in stats.items() if s["stale_excl"]]
    if stale_all:
        print("\nSTALE EXCLUSIONS (exclusions.csv lines that match no annotation): " +
              "; ".join(f"{m}:{','.join(map(str, ls))}" for m, ls in stale_all))
    # elm-test also runs non-default configurations on purpose, so a `flag` row is wrong only when
    # E2E (default flags) reaches it; an `unreachable` row is wrong when anything does.
    # A whole-module (`*`) row is exempt: a flag-gated module's empty-stats values and flag
    # guards do run by default, and the module is still gated.
    reached = [(m, r) for m, st in stats.items() if m not in excl_whole for r in st["rows"]
               if r["excluded"] == "unreachable" and r["hit"]]
    if reached:
        print("\nEXCLUDED AS UNREACHABLE BUT REACHED (fix or remove these exclusions.csv rows):")
        for m, r in reached[:40]:
            print(f"  {m}:{r['line']}  [{r['excluded']}]  {r['text'][:90]}")
        if len(reached) > 40:
            print(f"  ... {len(reached) - 40} more")
    if all_crash:
        print("\n*** CRASH CODE REACHED (a bug: unreachable code ran) ***")
        for m, r in all_crash:
            who = "+".join(x for x, c in (("elm-test", r["et"]), ("E2E", r["e2"])) if c)
            print(f"  {m}:{r['line']}  ({who}, {r['hit']} hits)  {r['text'][:100]}")
    if write_tracker:
        update_tracker(stats)


def print_summary(stats, folder):
    groups = {}
    for m, s in stats.items():
        groups.setdefault(folder_of(m), []).append(m)
    order = sorted(groups, key=lambda g: FOLDER_ORDER.index(g) if g in FOLDER_ORDER else 99)
    tot = [0, 0, 0, 0]
    print(f"{'module':58} {'branches':>16} {'decls':>14} {'excl':>5}")
    for g in order:
        if folder and g != folder:
            continue
        gs = [0, 0, 0, 0]
        lines = []
        for m in sorted(groups[g], key=lambda m: -(stats[m]["branches"][1] - stats[m]["branches"][0])):
            s = stats[m]
            b, d = s["branches"], s["decls"]
            gs[0] += b[0]; gs[1] += b[1]; gs[2] += d[0]; gs[3] += d[1]
            lines.append(f"  {m:56} {b[0]:5}/{b[1]:<5}{pct(*b)} {d[0]:4}/{d[1]:<4}{pct(*d)} {s['excluded']:5}")
        print(f"{g:58} {gs[0]:5}/{gs[1]:<5}{pct(gs[0], gs[1])} {gs[2]:4}/{gs[3]:<4}{pct(gs[2], gs[3])}")
        if folder:
            print("\n".join(lines))
        for k in range(4):
            tot[k] += gs[k]
    print(f"{'TOTAL':58} {tot[0]:5}/{tot[1]:<5}{pct(tot[0], tot[1])} {tot[2]:4}/{tot[3]:<4}{pct(tot[2], tot[3])}")


def show_module(module, s, show_all):
    b, d = s["branches"], s["decls"]
    print(f"{module}: branches {b[0]}/{b[1]} {pct(*b)}, declarations {d[0]}/{d[1]} {pct(*d)}, "
          f"excluded annotations {s['excluded']}")
    rows = s["rows"]
    decls = [r for r in rows if r["type"] == "declaration"]

    def owner(r):
        best = None
        for dcl in decls:
            if dcl["line"] <= r["line"]:
                best = dcl
        return best["name"] if best else "?"

    shown = [r for r in rows if show_all or (not r["hit"] and not r["excluded"])]
    cur = None
    for r in sorted(shown, key=lambda r: (r["line"], r["col"])):
        o = owner(r)
        if o != cur:
            print(f"\n  {o}")
            cur = o
        mark = "HIT " if r["hit"] else "MISS"
        if r["excluded"]:
            mark = f"x-{r['excluded']}"
        print(f"    {r['line']:5}:{r['col']:<3} {mark:7} {r['type']:15} {r['text'][:110]}")


def update_tracker(stats):
    rows = {}
    if os.path.exists(TRACKER):
        with open(TRACKER) as f:
            for r in csv.DictReader(f):
                rows[r["module"]] = r
    for m, s in stats.items():
        r = rows.setdefault(m, {"module": m, "folder": folder_of(m), "status": "open",
                                "baseline_branches": f"{s['branches'][0]}/{s['branches'][1]}", "notes": ""})
        r["folder"] = folder_of(m)
        r["branches"] = f"{s['branches'][0]}/{s['branches'][1]}"
        r["branch_pct"] = pct(*s["branches"]).strip()
        r["decls"] = f"{s['decls'][0]}/{s['decls'][1]}"
        r["excluded"] = str(s["excluded"])
        if r.get("status") in ("", None):
            r["status"] = "open"
    fields = ["module", "folder", "status", "branch_pct", "branches", "decls", "excluded",
              "baseline_branches", "notes"]
    order = sorted(rows.values(), key=lambda r: (FOLDER_ORDER.index(r["folder"]) if r["folder"] in FOLDER_ORDER
                                                 else 99, r["module"]))
    with open(TRACKER, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore", lineterminator="\n")
        w.writeheader()
        for r in order:
            w.writerow(r)
    print(f"tracker updated: {TRACKER}")


def cmd_report(a):
    quick = list(a.quick or [])
    if a.all_quick:
        quick += sorted(glob.glob(f"{QUICK}/*.json"))
    report(os.path.abspath(a.root), quick, a.module, a.folder, a.write_tracker, a.all)


# ---------------------------------------------------------------------------------------------
# gap: what elm-test reaches and E2E does not
# ---------------------------------------------------------------------------------------------

def gap_stats(root, quick_paths, scope_only):
    """Per module: rows of module_stats with the E2E side (baseline + quick E2E counts) compared
    with the elm-test side (baseline only). Excluded rows (crash, flag, unreachable) do not count:
    elm-test reaches flag code on purpose, which E2E at the default flags cannot."""
    data, stale = collect(root, quick_paths, quick_elm_test=False)
    excl_whole, excl_lines = load_exclusions(root)
    helpers = crash_helpers(root, {m: data[m][0] for m in data})
    out = {}
    for m in sorted(data):
        if scope_only and not in_scope(m):
            continue
        if not os.path.exists(module_path(root, m)):
            continue
        rows, _ = module_stats(root, m, *data[m], excl_whole, excl_lines, helpers)
        rows = [r for r in rows if not r["excluded"]]
        st = {}
        for kind, pred in (("branches", lambda r: r["type"] in BRANCH_TYPES),
                           ("decls", lambda r: r["type"] == "declaration"),
                           ("all", lambda r: True)):
            sel = [r for r in rows if pred(r)]
            st[kind] = (len(sel), sum(1 for r in sel if r["et"]), sum(1 for r in sel if r["e2"]),
                        sum(1 for r in sel if r["et"] and not r["e2"]))
        out[m] = {"st": st, "rows": rows}
    return out, stale


def cmd_gap(a):
    quick = list(a.quick or [])
    if a.all_quick:
        quick += sorted(glob.glob(f"{QUICK}/*.json"))
    stats, stale = gap_stats(os.path.abspath(a.root), quick, a.scope)
    kind = a.kind
    if a.module:
        s = stats.get(a.module) or sys.exit(f"{a.module}: unknown module")
        n, et, e2, g = s["st"][kind]
        print(f"{a.module}: {kind} {n}, elm-test {et}, E2E {e2}, reached by elm-test only {g}")
        decls = [r for r in s["rows"] if r["type"] == "declaration"]
        cur = None
        for r in sorted(s["rows"], key=lambda r: (r["line"], r["col"])):
            if not (r["et"] and not r["e2"]):
                continue
            if kind == "branches" and r["type"] not in BRANCH_TYPES:
                continue
            if kind == "decls" and r["type"] != "declaration":
                continue
            o = max((d for d in decls if d["line"] <= r["line"]), key=lambda d: d["line"], default=None)
            o = o["name"] if o else "?"
            if o != cur:
                print(f"\n  {o}")
                cur = o
            print(f"    {r['line']:5}:{r['col']:<3} et={r['et']:<7} {r['type']:15} {r['text'][:100]}")
        return
    groups = {}
    for m, s in stats.items():
        if a.folder and folder_of(m) != a.folder:
            continue
        groups.setdefault(m if a.folder else folder_of(m), []).append(s["st"][kind])
    rows = []
    tot = [0, 0, 0, 0]
    for g, sts in groups.items():
        t = [sum(x[k] for x in sts) for k in range(4)]
        rows.append((g, t))
        tot = [tot[k] + t[k] for k in range(4)]
    rows.sort(key=lambda r: -r[1][3])
    print(f"{kind} ({'in-scope modules' if a.scope else 'all modules'}; exclusions and crash code left out)")
    print(f"{'module' if a.folder else 'folder':52} {'total':>6} {'elm-test':>15} {'E2E':>15} {'elm-test only':>14}")
    for g, (n, et, e2, gp) in rows + [("TOTAL", tot)]:
        if g != "TOTAL" and not gp and not a.all:
            continue
        print(f"{g:52} {n:6} {et:6} {pct(et, n)} {e2:6} {pct(e2, n)} {gp:8} {pct(gp, n)}")
    if stale:
        print(f"\nNOTE: {len(stale)} in-scope modules changed since the baseline; only quick counts measure them: "
              f"{', '.join(stale[:8])}{' ...' if len(stale) > 8 else ''}")


def cmd_html(a):
    """elm-coverage's HTML report for each suite of the baseline, in build/coverage/html/<suite>."""
    for suite, counts in (("elm-test", "elm-test.json"), ("e2e", "e2e.json")):
        out = f"{BASE}/html/{suite}"
        shutil.rmtree(out, ignore_errors=True)
        run(["node", f"{COMPILER}/scripts/coverage/html-report.js", f"{BASELINE}/info.json",
             f"{BASELINE}/{counts}", f"{COMPILER}/src", out], check=True)


# ---------------------------------------------------------------------------------------------
# workspace: a private compiler directory for one agent of the loop
# ---------------------------------------------------------------------------------------------

WORKSPACES = "/tmp/eco-cov-agents"


def workspace_root(name):
    return f"{WORKSPACES}/{name}/compiler"


def cmd_workspace(a):
    """Creates (or, with --reset, recreates) /tmp/eco-cov-agents/NAME/compiler: src, src-xhr and
    src-version are symlinks to /work/compiler (agents of the loop do not edit the compiler), tests/
    and elm.json are copies the agent edits. Its quick runs are tagged NAME."""
    root = workspace_root(a.name)
    if os.path.exists(root):
        if not a.reset:
            print(f"{root} exists (use --reset to recreate it)")
            return
        shutil.rmtree(os.path.dirname(root))
    os.makedirs(root)
    for d in ("src", "src-xhr", "src-version"):
        os.symlink(f"{COMPILER}/{d}", f"{root}/{d}")
    shutil.copy(f"{COMPILER}/elm.json", root)
    shutil.copytree(f"{COMPILER}/tests", f"{root}/tests", symlinks=True,
                    ignore=shutil.ignore_patterns("elm-stuff"))
    print(root)


def cmd_diff(a):
    """Lists the test files of workspace NAME that differ from /work/compiler/tests."""
    root = workspace_root(a.name)
    r = subprocess.run(["diff", "-rq", "-x", "elm-stuff", f"{COMPILER}/tests", f"{root}/tests"],
                       capture_output=True, text=True)
    print(r.stdout.strip() or "no differences")


# ---------------------------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------------------------

def cmd_setup(a):
    if not os.path.isdir(f"{ELM_COVERAGE}/node_modules"):
        run(["npm", "install", "--no-audit", "--no-fund"], cwd=ELM_COVERAGE, check=True)
    if not os.path.exists(f"{ELM_COVERAGE}/unpacked_bin/elm-instrument"):
        run(["npx", "binwrap-install"], cwd=ELM_COVERAGE, check=True)
    if not os.path.exists(f"{ELM_COVERAGE}/lib/analyzer.js"):
        run(["elm", "make", "--optimize", "src/Analyzer.elm", "--output", "lib/analyzer.js"],
            cwd=ELM_COVERAGE, env=tool_env(), check=True)
    print("elm-coverage is ready")


def main():
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("setup")
    s.set_defaults(fn=cmd_setup)
    s = sub.add_parser("baseline")
    s.add_argument("--workers", type=int, default=8)
    s.add_argument("--elm-test-only", action="store_true",
                   help="rerun only the elm-test half and keep the stored E2E counts")
    s.add_argument("--import-dirs", nargs=3, metavar=("ELMTEST_DATA_DIR", "E2E_DATA_DIR", "INFO_JSON"),
                   help="store existing data files as the baseline instead of running the suites")
    s.set_defaults(fn=cmd_baseline)
    s = sub.add_parser("quick")
    s.add_argument("--root", default=COMPILER, help="compiler directory (src/, tests/, elm.json); default /work/compiler")
    s.add_argument("--filter", default="coverage run", help='elm-test-rs filter (default "coverage run")')
    s.add_argument("--workers", type=int, default=8)
    s.add_argument("--tag", help="name of the quick file (default: the root's directory name)")
    s.add_argument("--e2e", nargs="*", help="E2E test files (/work/test/<suite>/src/X.elm) to compile under coverage")
    s.add_argument("--e2e-js", nargs="*", help="E2E test files to compile to JavaScript under coverage (the JS backend)")
    s.add_argument("--report", action="store_true", help="print the merged report afterwards")
    s.add_argument("--module")
    s.add_argument("--folder")
    s.add_argument("--all", action="store_true")
    s.set_defaults(fn=cmd_quick)
    s = sub.add_parser("workspace", help="create an agent's private compiler directory")
    s.add_argument("name")
    s.add_argument("--reset", action="store_true")
    s.set_defaults(fn=cmd_workspace)
    s = sub.add_parser("diff", help="list an agent workspace's changed test files")
    s.add_argument("name")
    s.set_defaults(fn=cmd_diff)
    s = sub.add_parser("exclusions", help="anchor exclusions.csv rows to their source text")
    s.add_argument("--rewrite", action="store_true", help="write relocated lines and new anchors back")
    s.add_argument("--anchor-changed", action="store_true",
                   help="also fill anchors in modules changed since the baseline (only once their lines are verified)")
    s.set_defaults(fn=cmd_exclusions)
    s = sub.add_parser("report")
    s.add_argument("--root", default=COMPILER)
    s.add_argument("--quick", nargs="*", help="quick files to merge in")
    s.add_argument("--all-quick", action="store_true", help="merge every quick file in build/coverage/quick")
    s.add_argument("--module", help="list this module's unreached annotations")
    s.add_argument("--folder", help="list the modules of this folder (e.g. Compiler.MonoOpt)")
    s.add_argument("--all", action="store_true", help="with --module, list every annotation, hit or not")
    s.add_argument("--write-tracker", action="store_true")
    s.set_defaults(fn=cmd_report)
    s = sub.add_parser("gap", help="what elm-test reaches that E2E does not (baseline + quick E2E counts)")
    s.add_argument("--root", default=COMPILER)
    s.add_argument("--quick", nargs="*", help="quick files whose E2E counts to merge in")
    s.add_argument("--all-quick", action="store_true", help="merge the E2E counts of every quick file")
    s.add_argument("--scope", action="store_true", help="only the loop's in-scope modules (default: all of src/)")
    s.add_argument("--kind", choices=["branches", "decls", "all"], default="branches")
    s.add_argument("--folder", help="list the modules of this folder (e.g. Compiler.MonoOpt)")
    s.add_argument("--module", help="list this module's annotations reached by elm-test only")
    s.add_argument("--all", action="store_true", help="also list folders/modules with no gap")
    s.set_defaults(fn=cmd_gap)
    s = sub.add_parser("html", help="elm-coverage HTML reports of the baseline, one per suite")
    s.set_defaults(fn=cmd_html)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
