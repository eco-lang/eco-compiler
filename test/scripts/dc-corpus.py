#!/usr/bin/env python3
"""Output corpora of the compiler, for checking that a change leaves every output byte-identical
(plans/dead-code-removal.md, section 3).

    dc-corpus.py mlir   <out>     copy build/test/*/eco-stuff/mlir/*.mlir (written by the JIT E2E run)
    dc-corpus.py js     <out>     compile every JS-E2E test plain, --optimize and --debug; docs.json
    dc-corpus.py format <out>     API.Main `format` of every .elm file under the corpus roots
    dc-corpus.py diff   <a> <b>   differing files, then the first lines of the first three diffs

`format` builds API.Main from $DC_SHADOW (default: the build-xhr shadow root). `js` and `format` use the Stage 1 compiler build/compiler/build-xhr/bin/guida.js, so build the
`guida` target first. Compile and format errors are recorded as output too: a change that turns a
success into a failure (or changes a report) is a difference.
"""
import concurrent.futures as cf
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = "/work"
BUILD = f"{REPO}/build"
GUIDA = f"{BUILD}/compiler/build-xhr/bin/guida.js"
BIN = f"{REPO}/compiler/bin"
JOBS = int(os.environ.get("DC_JOBS", "10"))
# The formatter takes minutes on some mid-size modules with long doc comments (Markdown), so the
# corpus is every test source plus the small (doc-commented) compiler and kernel modules, and a
# file that takes longer than FORMAT_TIMEOUT seconds is recorded as TIMEOUT.
FORMAT_ROOTS = [("test/elm/src", None), ("test/elm-core/src", None), ("test/elm-bytes/src", None),
                ("test/eco-system/src", None), ("test/elm-conformance/src", None),
                ("test/elm-parser/src", None), ("test/elm-json/src", None),
                ("test/elm-compile-errors", None),
                ("test/eco-mlir/src", None), ("test/eco-elm/src", None), ("test/eco-elm-bytes/src", None), ("test/eco-elm-core/src", None), ("test/eco-elm-json/src", None), ("test/eco-elm-regex/src", None), ("test/eco-elm-conformance/src", None), ("compiler/src", 6000), ("compiler/src-xhr", 6000),
                ("eco-kernel-cpp/src", 6000), ("system-kernel-cpp/src", 6000)]
FORMAT_TIMEOUT = 30
# The module text travels in argv, and Linux caps one argument at 128 KiB.
MAX_FORMAT_BYTES = 120 * 1024
JS_PROJECTS = [("eco-system", ["eco/system=" + f"{REPO}/system-kernel-cpp"]),
               ("elm-conformance", [])]


def run(args, cwd, env=None, timeout=900):
    r = subprocess.run(args, cwd=cwd, env=env, capture_output=True, timeout=timeout)
    return r.returncode, r.stdout + r.stderr


def cmd_mlir(out):
    n = 0
    for pkg in sorted(os.listdir(f"{BUILD}/test")):
        src = f"{BUILD}/test/{pkg}/eco-stuff/mlir"
        if not os.path.isdir(src):
            continue
        os.makedirs(f"{out}/{pkg}", exist_ok=True)
        for f in sorted(os.listdir(src)):
            if f.endswith(".mlir"):
                shutil.copyfile(f"{src}/{f}", f"{out}/{pkg}/{f}")
                n += 1
    print(f"{n} .mlir files copied to {out}")


def runner_js(tmp, main):
    """A copy of compiler/bin/index.js that starts Elm.<main> (as cli-errors.test.js does)."""
    path = f"{tmp}/run-{main.replace('.', '_')}.js"
    with open(f"{BIN}/index.js") as f:
        text = f.read()
    text = (text.replace('require("./eco-io-handler")', f'require({json.dumps(BIN + "/eco-io-handler")})')
                .replace('require("mock-xmlhttprequest")',
                         f'require({json.dumps(REPO + "/compiler/node_modules/mock-xmlhttprequest")})')
                .replace("Elm.Terminal.Main.init();", f"Elm.{main}.init();"))
    with open(path, "w") as f:
        f.write(text)
    return path


def cmd_js(out):
    work = tempfile.mkdtemp(prefix="dc-js-", dir="/tmp")
    env = dict(os.environ, GUIDA_JS_PATH=GUIDA)
    jobs = []
    for name, local in JS_PROJECTS:
        src = f"{REPO}/test/{name}"
        for mode, flags in (("plain", []), ("optimize", ["--optimize"]), ("debug", ["--debug"])):
            proj = f"{work}/{name}-{mode}"
            shutil.copytree(src, proj, ignore=shutil.ignore_patterns("elm-stuff", "eco-stuff"))
            tests = sorted(f[:-4] for f in os.listdir(f"{proj}/src")
                           if f.endswith(".elm") and _has_main(f"{proj}/src/{f}"))
            os.makedirs(f"{out}/{name}/{mode}", exist_ok=True)
            # The first compile of a project builds its package caches; the rest share them.
            jobs.append((proj, name, mode, flags, local, tests))
    def compile_one(proj, name, mode, flags, local, t):
        args = ["node", f"{BIN}/index.js", "make", f"src/{t}.elm", f"--output=out/{t}.js", *flags]
        for lp in local:
            args += ["--local-package", lp]
        args.append(f"--builddir=bd-{t}")
        code, text = run(args, proj, env)
        dst = f"{out}/{name}/{mode}/{t}"
        if code == 0 and os.path.exists(f"{proj}/out/{t}.js"):
            shutil.copyfile(f"{proj}/out/{t}.js", dst + ".js")
        else:
            with open(dst + ".error", "wb") as f:
                f.write(f"exit {code}\n".encode() + _scrub(text, proj))
    with cf.ThreadPoolExecutor(JOBS) as ex:
        futs = []
        for proj, name, mode, flags, local, tests in jobs:
            if tests:
                compile_one(proj, name, mode, flags, local, tests[0])
            futs += [ex.submit(compile_one, proj, name, mode, flags, local, t) for t in tests[1:]]
        for f in futs:
            f.result()
    # Package docs (Compiler.Docs, Docs.Type, Json.*): eco/system's docs.json, as eco-system-docs makes it.
    pkg = f"{work}/system-kernel-cpp"
    shutil.copytree(f"{REPO}/system-kernel-cpp", pkg, ignore=shutil.ignore_patterns("elm-stuff", "eco-stuff", "build*"))
    code, text = run(["node", f"{BIN}/index.js", "make", "--docs=docs.json"], pkg, env)
    if code == 0:
        shutil.copyfile(f"{pkg}/docs.json", f"{out}/docs.json")
    else:
        with open(f"{out}/docs.error", "wb") as f:
            f.write(f"exit {code}\n".encode() + _scrub(text, pkg))
    shutil.rmtree(work)
    print(f"js corpus written to {out}")


def _has_main(path):
    with open(path, encoding="utf8") as f:
        return any(line.startswith("main") for line in f)


def _scrub(text, path):
    return text.replace(path.encode(), b"<PROJECT>")


def cmd_format(out):
    tmp = tempfile.mkdtemp(prefix="dc-fmt-", dir="/tmp")
    # DC_SHADOW: another Elm project root holding the compiler sources (an agent workspace).
    shadow = os.environ.get("DC_SHADOW", f"{BUILD}/compiler/build-xhr")
    code, text = run([f"{BUILD}/toolchain/bin/elm", "make", f"--output={tmp}/api.js",
                      "src/API/Main.elm"], shadow)
    if code != 0:
        sys.exit(text.decode())
    run(["node", f"{REPO}/compiler/scripts/replacements.js", f"{tmp}/api.js"], tmp)
    runner = runner_js(tmp, "API.Main")
    env = dict(os.environ, GUIDA_JS_PATH=f"{tmp}/api.js")
    files = []
    # DC_FORMAT_INPUTS: a tree with the repo's layout (a snapshot). A corpus root it holds is read
    # from it instead of the repo, so that edits to the compiler's own sources do not count as
    # formatter differences.
    inputs = os.environ.get("DC_FORMAT_INPUTS")
    for root, cap in FORMAT_ROOTS:
        base = inputs if inputs and os.path.isdir(f"{inputs}/{root}") else REPO
        for d, _, fs in os.walk(f"{base}/{root}"):
            if "elm-stuff" in d or "eco-stuff" in d:
                continue
            files += [p for p in (os.path.join(d, f) for f in fs if f.endswith(".elm"))
                      if cap is None or os.path.getsize(p) <= cap]
    files.sort()
    def fmt(path):
        with open(path, encoding="utf8", errors="replace") as f:
            content = f.read()
        if len(content.encode()) > MAX_FORMAT_BYTES:
            return False
        try:
            code, text = run(["node", runner, json.dumps({"command": "format", "content": content})],
                             tmp, env, timeout=FORMAT_TIMEOUT)
            result = scrub_stack(f"exit {code}\n".encode() + text)
        except subprocess.TimeoutExpired:
            result = b"TIMEOUT\n"
        dst = f"{out}/{os.path.relpath(path, inputs if inputs and path.startswith(inputs) else REPO)}.out"
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as f:
            f.write(result)
        return result == b"TIMEOUT\n"
    with cf.ThreadPoolExecutor(JOBS) as ex:
        timeouts = sum(ex.map(fmt, files))
    shutil.rmtree(tmp)
    print(f"{len(files)} files formatted into {out}, {timeouts} timed out")


def scrub_stack(text):
    """Drops the stack frames of a JS crash: they name the temporary build and its line numbers,
    which change with every edit of the compiler. The crash message itself is kept."""
    return b"\n".join(l for l in text.split(b"\n") if not re.match(rb"\s+at ", l))


def cmd_diff(a, b):
    r = subprocess.run(["diff", "-r", "--brief", a, b], capture_output=True, text=True)
    # A format run that timed out on either side is not compared: the formatter's run time on the
    # slow modules depends on the machine's load, so it flips around FORMAT_TIMEOUT.
    def timed_out(path):
        try:
            with open(path, "rb") as f:
                return f.read(8) == b"TIMEOUT\n"
        except OSError:
            return False
    # The API process can exit before node has flushed a large response, so an output past the
    # 64 KiB pipe buffer may be cut short: one output being a prefix of the other is not compared.
    def truncated(pa, pb):
        def body(path):
            with open(path, "rb") as f:
                text = f.read()
            return text.split(b"Compiled in DEV mode")[0]
        try:
            x, y = body(pa), body(pb)
        except OSError:
            return False
        return max(len(x), len(y)) >= 65536 and (x.startswith(y) or y.startswith(x))
    def ignored(line):
        if not line.startswith("Files "):
            return False
        pa, pb = line.split()[1], line.split()[3]
        return timed_out(pa) or timed_out(pb) or (pa.endswith(".out") and truncated(pa, pb))
    lines = [line for line in r.stdout.splitlines() if not ignored(line)]
    print(f"{len(lines)} differences")
    for line in lines[:40]:
        print(line)
    shown = 0
    for line in lines:
        parts = line.split()
        if line.startswith("Files ") and shown < 3:
            d = subprocess.run(["diff", parts[1], parts[3]], capture_output=True, text=True).stdout
            print("\n".join(d.splitlines()[:40]))
            shown += 1
    sys.exit(1 if lines else 0)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    {"mlir": cmd_mlir, "js": cmd_js, "format": cmd_format, "diff": cmd_diff}[cmd](*args)

