// The compiler's IO wrappers over eco/system, on a real file system: the cases where the compiler
// gives eco/system's operations its own meaning (plans/compiler-io-on-eco-system.md §6).
//   1. Utils.dirCanonicalizePath resolves symbolic links in a path that holds `..` (eco/system's
//      Path cancels `..` against the entry before it as text, so `link/../x` must not reach it), and
//      in the part of a missing path that exists, as GHC's canonicalizePath does. Only a missing
//      path falls back to text; any other failure (a loop of links) crashes.
//   2. Utils.dirRemoveDirectoryRecursiveIfExists, the only directory removal, says in its name that a
//      missing path is not a failure; its caller clears a cache directory that may not exist yet (a
//      --local-package seen for the first time). Any other failure crashes.
//   3. Reporting.ask answers no at the end of input: `eco install` with stdin closed changes nothing
//      (it used to read end of input as an empty line, which answers yes).
// Tests 1 and 2 run test/compiler-io/IoProbe.elm, built from compiler/src with the Stage 1 compiler
// (compiler/bin/index.js, run against build/compiler/build-xhr/bin/guida.js) the way Stage 2 is.
// Run: cmake --build build --target run-compiler-io-tests (`full` runs it), or
//      node --test test/scripts/compiler-io.test.js
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const { spawn, spawnSync } = require("child_process");

const ROOT = path.resolve(__dirname, "../..");
const ECO = path.join(ROOT, "compiler/bin/index.js");
const BUILD = process.env.ECO_BUILD_DIR || path.join(ROOT, "build");

function tmpdir(tag) {
  return fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), `eco-compiler-io-${tag}-`)));
}
function clean(out) {
  return out.replace(/\x1b\[[0-9;]*m/g, "");
}

// ---- the probe ----

let probeJs = null;
// Builds IoProbe.elm once, into a throwaway project whose elm.json is the Stage 2 one with the probe's
// directory added to its source directories.
function probe() {
  if (probeJs) return probeJs;
  const dir = tmpdir("probe");
  const elmJson = JSON.parse(fs.readFileSync(path.join(ROOT, "compiler/cmake/bootstrap/build-kernel/elm.json"), "utf8"));
  elmJson["source-directories"] = [
    path.join(ROOT, "test/compiler-io"),
    path.join(ROOT, "compiler/src"),
    path.join(BUILD, "compiler/version"),
  ];
  fs.writeFileSync(path.join(dir, "elm.json"), JSON.stringify(elmJson, null, 4));
  const r = spawnSync(process.execPath, [
    ECO, "make", path.join(ROOT, "test/compiler-io/IoProbe.elm"), "--output=probe.js",
    "--local-package", "eco/kernel=" + path.join(ROOT, "eco-kernel-cpp"),
    "--local-package", "eco/system=" + path.join(ROOT, "system-kernel-cpp"),
  ], { cwd: dir, encoding: "utf8", timeout: 600000, maxBuffer: 1 << 26 });
  assert.strictEqual(r.status, 0, "building IoProbe failed:\n" + clean((r.stdout || "") + (r.stderr || "")));
  fs.writeFileSync(path.join(dir, "run.js"), 'const { Elm } = require("./probe.js");\nElm.IoProbe.init();\n');
  probeJs = path.join(dir, "run.js");
  return probeJs;
}
function runProbe(cwd, args) {
  const r = spawnSync(process.execPath, [probe(), ...args], { cwd, encoding: "utf8", timeout: 120000 });
  return { status: r.status, out: clean(r.stdout || ""), err: clean(r.stderr || "") };
}

// tmp/a/link -> tmp/b/c, with tmp/b/x and tmp/b/c existing.
function linkTree() {
  const t = tmpdir("canon");
  fs.mkdirSync(path.join(t, "a"));
  fs.mkdirSync(path.join(t, "b/c"), { recursive: true });
  fs.mkdirSync(path.join(t, "b/x"));
  fs.symlinkSync(path.join(t, "b/c"), path.join(t, "a/link"));
  return t;
}

// ---- 1. canonicalize ----

test("canonicalize resolves a link before the `..` that follows it", () => {
  const t = linkTree();
  // Not path.join, which would cancel the `..` itself.
  const r = runProbe(t, ["canonicalize", t + "/a/link/../x"]);
  assert.strictEqual(r.status, 0, r.out + r.err);
  assert.strictEqual(r.out.trim(), path.join(t, "b/x"));
});

test("canonicalize of a relative path resolves it against the current directory, links first", () => {
  const t = linkTree();
  const r = runProbe(path.join(t, "a"), ["canonicalize", "link/../x"]);
  assert.strictEqual(r.status, 0, r.out + r.err);
  assert.strictEqual(r.out.trim(), path.join(t, "b/x"));
});

test("canonicalize of a missing path resolves the part that exists and appends the rest", () => {
  const t = linkTree();
  const r = runProbe(t, ["canonicalize", path.join(t, "a/link/missing/y")]);
  assert.strictEqual(r.status, 0, r.out + r.err);
  assert.strictEqual(r.out.trim(), path.join(t, "b/c/missing/y"));
});

test("canonicalize of a missing relative path makes it absolute against the current directory", () => {
  const t = linkTree();
  const r = runProbe(path.join(t, "a"), ["canonicalize", "missing/./z"]);
  assert.strictEqual(r.status, 0, r.out + r.err);
  assert.strictEqual(r.out.trim(), path.join(t, "a/missing/z"));
});

test("canonicalize of an existing path gives its real path", () => {
  const t = linkTree();
  const r = runProbe(t, ["canonicalize", path.join(t, "a/link")]);
  assert.strictEqual(r.status, 0, r.out + r.err);
  assert.strictEqual(r.out.trim(), path.join(t, "b/c"));
});

test("canonicalize through a loop of links crashes instead of falling back to text", () => {
  const t = tmpdir("loop");
  fs.symlinkSync(path.join(t, "loop"), path.join(t, "loop"));
  const r = runProbe(t, ["canonicalize", path.join(t, "loop/x")]);
  assert.notStrictEqual(r.status, 0, "no crash; printed " + JSON.stringify(r.out));
  assert.match(r.out + r.err, /IO error/);
});

// ---- 2. removing a directory ----

test("removing a directory removes it and everything in it", () => {
  const t = tmpdir("rm");
  fs.mkdirSync(path.join(t, "d/e"), { recursive: true });
  fs.writeFileSync(path.join(t, "d/e/f"), "x");
  const r = runProbe(t, ["remove-dir", path.join(t, "d")]);
  assert.strictEqual(r.status, 0, r.out + r.err);
  assert.ok(!fs.existsSync(path.join(t, "d")));
});

test("removing a missing directory succeeds", () => {
  const t = tmpdir("rm");
  const r = runProbe(t, ["remove-dir", path.join(t, "missing")]);
  assert.strictEqual(r.status, 0, r.out + r.err);
  assert.strictEqual(r.out.trim(), "removed");
});

test("removing a directory that cannot be removed crashes", () => {
  const t = tmpdir("rm");
  fs.mkdirSync(path.join(t, "locked/d"), { recursive: true });
  fs.chmodSync(path.join(t, "locked"), 0o555);
  try {
    const r = runProbe(t, ["remove-dir", path.join(t, "locked/d")]);
    assert.notStrictEqual(r.status, 0, "no failure; printed " + JSON.stringify(r.out));
    assert.match(r.out + r.err, /IO error/);
  } finally {
    fs.chmodSync(path.join(t, "locked"), 0o755);
  }
});

test("a --local-package seen for the first time is copied into the package cache", () => {
  const name = "ecotest/compiler-io-" + process.pid;
  const ecoHome = process.env.ECO_HOME || path.join(os.homedir(), ".eco");
  const version = fs.readFileSync(path.join(ROOT, "version.txt"), "utf8").trim();
  const cacheDir = path.join(ecoHome, version, "packages", name);
  fs.rmSync(cacheDir, { recursive: true, force: true });
  try {
    const lib = tmpdir("lib");
    fs.mkdirSync(path.join(lib, "src"));
    fs.writeFileSync(path.join(lib, "src/Lib.elm"), 'module Lib exposing (s)\n\n\ns =\n    "lib"\n');
    fs.writeFileSync(path.join(lib, "elm.json"), JSON.stringify({
      type: "package", name, summary: "x", license: "BSD-3-Clause", version: "1.0.0",
      "exposed-modules": ["Lib"], "elm-version": "0.19.0 <= v < 0.20.0",
      dependencies: { "elm/core": "1.0.0 <= v < 2.0.0" }, "test-dependencies": {},
    }, null, 4));
    const app = tmpdir("app");
    const elmJson = JSON.parse(fs.readFileSync(path.join(ROOT, "test/elm/elm.json"), "utf8"));
    elmJson.dependencies.direct[name] = "1.0.0";
    fs.writeFileSync(path.join(app, "elm.json"), JSON.stringify(elmJson, null, 4));
    fs.mkdirSync(path.join(app, "src"));
    fs.writeFileSync(path.join(app, "src/Main.elm"),
      "module Main exposing (main)\n\nimport Html\nimport Lib\n\n\nmain =\n    Html.text Lib.s\n");
    const r = spawnSync(process.execPath,
      [ECO, "make", "src/Main.elm", "--output=out.js", `--local-package=${name}=${lib}`],
      { cwd: app, encoding: "utf8", timeout: 300000 });
    assert.strictEqual(r.status, 0, clean((r.stdout || "") + (r.stderr || "")));
    assert.ok(fs.existsSync(path.join(cacheDir, "1.0.0/src/Lib.elm")), "no cache copy at " + cacheDir);
  } finally {
    fs.rmSync(cacheDir, { recursive: true, force: true });
  }
});

// ---- 3. answering at the end of input ----

const pkgElmJson = (name, deps) => JSON.stringify({
  type: "package", name, summary: "x", license: "BSD-3-Clause", version: "1.0.0",
  "exposed-modules": ["M"], "elm-version": "0.19.0 <= v < 0.20.0",
  dependencies: deps, "test-dependencies": {},
});
const installRoutes = {
  "/all-packages": JSON.stringify({ "elm/core": ["1.0.5"], "elm/json": ["1.1.3"], "zz/a": ["1.0.0"] }),
  "/packages/elm/core/1.0.5/elm.json": pkgElmJson("elm/core", {}).replace('"1.0.0"', '"1.0.5"'),
  "/packages/elm/json/1.1.3/elm.json": pkgElmJson("elm/json", { "elm/core": "1.0.0 <= v < 2.0.0" }).replace('"1.0.0",', '"1.1.3",'),
  "/packages/zz/a/1.0.0/elm.json": pkgElmJson("zz/a", {}),
};
// Runs eco in `cwd` with a throwaway HOME, against a local package server serving `routes`, with
// `input` on stdin, which then ends.
async function ecoWithInput(cwd, args, routes, input) {
  const s = await new Promise((resolve) => {
    const srv = http.createServer((q, res) => {
      if (q.url in routes) res.end(routes[q.url]);
      else { res.statusCode = 404; res.end("not found"); }
    });
    srv.listen(0, "127.0.0.1", () => resolve(srv));
  });
  try {
    return await new Promise((resolve) => {
      const p = spawn(process.execPath, [ECO, ...args], {
        cwd, env: { ...process.env, HOME: tmpdir("home"), GUIDA_REGISTRY: `http://127.0.0.1:${s.address().port}` },
      });
      let out = "";
      p.stdout.on("data", (d) => (out += d));
      p.stderr.on("data", (d) => (out += d));
      p.stdin.end(input);
      const t = setTimeout(() => p.kill("SIGKILL"), 300000);
      p.on("close", (status) => {
        clearTimeout(t);
        resolve({ status, out: clean(out) });
      });
    });
  } finally {
    s.close();
  }
}

test("eco install with stdin at its end answers no and changes nothing", async () => {
  const dir = tmpdir("install");
  fs.mkdirSync(path.join(dir, "src"));
  const before = JSON.stringify({
    type: "application", "source-directories": ["src"], "elm-version": "0.19.1",
    dependencies: { direct: { "elm/core": "1.0.5", "elm/json": "1.1.3" }, indirect: {} },
    "test-dependencies": { direct: {}, indirect: {} },
  }, null, 4);
  fs.writeFileSync(path.join(dir, "elm.json"), before);
  const r = await ecoWithInput(dir, ["install", "zz/a"], installRoutes, "");
  assert.match(r.out, /Here is my plan/, r.out);
  assert.match(r.out, /Okay, I did not change anything!/, r.out);
  assert.strictEqual(fs.readFileSync(path.join(dir, "elm.json"), "utf8"), before);
});
