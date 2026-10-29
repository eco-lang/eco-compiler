// Terminal command output bugs reproduced through the real `eco` CLI
// (compiler/bin/index.js, run against the built build/compiler/build-xhr/bin/guida.js).
// Each test FAILS today and pins an open bug:
//   1. Terminal.Diff.aliasToDoc nests D.plus (which prints its SECOND argument first), so an added
//      alias prints as `= Pair a alias type ( a, a )` instead of `type alias Pair a = ( a, a )`.
//   2. Terminal.Diff.binopToDoc, same cause: an added operator prints as
//      `) 7 / left     ( Int -> Int -> Int : ) +++ (` instead of `(+++) : Int -> Int -> Int    (left/7)`.
//   3. Terminal.Install.viewName uses D.fill, which is Pretty.indent and does not pad: in the
//      "Here is my plan" listing every name is indented by nameWidth+3 and the versions do not line up.
//   4. Terminal.Uninstall.viewName, same cause, in the uninstall plan.
//   5. Terminal.Init: `eco init --package` also solves the APPLICATION defaults (eco/system and
//      elm/core), so when eco/system cannot be resolved it fails with NO SOLUTION naming eco/system,
//      although a package outline needs only elm/core.
// Every test uses a throwaway HOME and a throwaway local package server (GUIDA_REGISTRY) with
// made-up `zz/*` packages, so nothing depends on the user's ~/.eco cache.
// Run: node --test test/scripts/cli-terminal-render.test.js
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const ECO = path.resolve(__dirname, "../../compiler/bin/index.js");

function tmpdir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "eco-cli-terminal-"));
}
function registry(routes) {
  return new Promise((resolve) => {
    const s = http.createServer((q, r) => {
      if (q.url in routes) r.end(routes[q.url]);
      else { r.statusCode = 404; r.end("not found"); }
    });
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
}
// Runs eco in `cwd` against a local registry serving `routes`, feeding `input` on stdin.
async function eco(cwd, args, routes, input) {
  const s = await registry(routes);
  try {
    return await new Promise((resolve) => {
      const p = spawn(process.execPath, [ECO, ...args], {
        cwd, env: { ...process.env, HOME: tmpdir(), GUIDA_REGISTRY: `http://127.0.0.1:${s.address().port}` },
      });
      let out = "";
      p.stdout.on("data", (d) => (out += d));
      p.stderr.on("data", (d) => (out += d));
      p.stdin.end(input || "");
      const t = setTimeout(() => p.kill("SIGKILL"), 300000);
      p.on("close", (status) => {
        clearTimeout(t);
        resolve({ status, out: out.replace(/\x1b\[[0-9;]*m/g, "") });
      });
    });
  } finally {
    s.close();
  }
}

// ---- eco diff ----

const docs = (aliases, binops) =>
  JSON.stringify([{ name: "M", comment: "", unions: [], values: [], aliases, binops }]);
const diffRoutes = {
  "/all-packages": JSON.stringify({ "zz/pkg": ["1.0.0", "2.0.0"] }),
  "/packages/zz/pkg/1.0.0/docs.json": docs([], []),
  "/packages/zz/pkg/2.0.0/docs.json": docs(
    [{ name: "Pair", comment: "", args: ["a"], type: "( a, a )" }],
    [{ name: "+++", comment: "", type: "Basics.Int -> Basics.Int -> Basics.Int", associativity: "left", precedence: 7 }]
  ),
};

test("eco diff prints an added type alias as `type alias Name vars = type`", async () => {
  const r = await eco(tmpdir(), ["diff", "zz/pkg", "1.0.0", "2.0.0"], diffRoutes);
  assert.match(r.out, /Added:/, r.out);
  assert.match(r.out, /type alias Pair a =/, r.out);
});

test("eco diff prints an added operator as `(op) : type    (assoc/prec)`", async () => {
  const r = await eco(tmpdir(), ["diff", "zz/pkg", "1.0.0", "2.0.0"], diffRoutes);
  assert.match(r.out, /Added:/, r.out);
  assert.match(r.out, /\(\+\+\+\) : Int -> Int -> Int\s+\(left\/7\)/, r.out);
});

// ---- install / uninstall plans ----

const pkgElmJson = (name, deps) => JSON.stringify({
  type: "package", name, summary: "x", license: "BSD-3-Clause", version: "1.0.0",
  "exposed-modules": ["M"], "elm-version": "0.19.0 <= v < 0.20.0",
  dependencies: deps, "test-dependencies": {},
});
const coreElmJson = pkgElmJson("elm/core", {}).replace('"1.0.0"', '"1.0.5"');
const planRoutes = {
  "/all-packages": JSON.stringify({ "elm/core": ["1.0.5"], "elm/json": ["1.1.3"], "zz/a": ["1.0.0"], "zz/b": ["1.0.0"], "zz/longer-name": ["1.0.0"] }),
  "/packages/elm/core/1.0.5/elm.json": coreElmJson,
  "/packages/elm/json/1.1.3/elm.json": pkgElmJson("elm/json", { "elm/core": "1.0.0 <= v < 2.0.0" }).replace('"1.0.0",', '"1.1.3",'),
  "/packages/zz/a/1.0.0/elm.json": pkgElmJson("zz/a", {}),
  "/packages/zz/b/1.0.0/elm.json": pkgElmJson("zz/b", {}),
  "/packages/zz/longer-name/1.0.0/elm.json": pkgElmJson("zz/longer-name", { "zz/b": "1.0.0 <= v < 2.0.0" }),
};
function app(direct, indirect) {
  const dir = tmpdir();
  fs.mkdirSync(path.join(dir, "src"));
  fs.writeFileSync(path.join(dir, "elm.json"), JSON.stringify({
    type: "application", "source-directories": ["src"], "elm-version": "0.19.1",
    dependencies: { direct, indirect }, "test-dependencies": { direct: {}, indirect: {} },
  }, null, 4));
  return dir;
}
// The plan lines naming a zz/ package: each must start at column 4, and the versions must line
// up in one column (upstream Elm pads every name to the longest name + 3).
function assertPlanAligned(out) {
  const lines = out.split("\n").filter((l) => /zz\//.test(l) && /\d+\.\d+\.\d+/.test(l));
  assert.ok(lines.length >= 2, out);
  for (const l of lines) assert.match(l, /^ {4}zz\//, `name not at column 4:\n${out}`);
  const cols = lines.map((l) => l.search(/\d+\.\d+\.\d+/));
  assert.ok(cols.every((c) => c === cols[0]), `versions not aligned:\n${out}`);
}

test("eco install plan lists names padded to one column, not indented", async () => {
  const dir = app({ "elm/core": "1.0.5", "elm/json": "1.1.3", "zz/a": "1.0.0" }, {});
  const r = await eco(dir, ["install", "zz/longer-name"], planRoutes, "n\n");
  assert.match(r.out, /Here is my plan/, r.out);
  assertPlanAligned(r.out);
});

test("eco uninstall plan lists names padded to one column, not indented", async () => {
  const dir = app({ "elm/core": "1.0.5", "elm/json": "1.1.3", "zz/a": "1.0.0", "zz/longer-name": "1.0.0" }, { "zz/b": "1.0.0" });
  const r = await eco(dir, ["uninstall", "zz/longer-name"], planRoutes, "n\n");
  assert.match(r.out, /Here is my plan/, r.out);
  assertPlanAligned(r.out);
});

// ---- init --package ----

test("eco init --package needs only elm/core, not eco/system", async () => {
  const dir = tmpdir();
  const r = await eco(dir, ["init", "--package", "--yes"], {
    "/all-packages": JSON.stringify({ "elm/core": ["1.0.5"] }),
    "/packages/elm/core/1.0.5/elm.json": coreElmJson,
  });
  assert.doesNotMatch(r.out, /NO SOLUTION/, r.out);
  assert.ok(fs.existsSync(path.join(dir, "elm.json")), r.out);
  assert.match(fs.readFileSync(path.join(dir, "elm.json"), "utf8"), /"type": "package"/);
});
