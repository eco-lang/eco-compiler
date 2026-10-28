// Regression tests for builder-group bugs reproduced through the real `eco` CLI
// (compiler/bin/index.js, run against the built build/compiler/build-xhr/bin/guida.js).
// Every test here is EXPECTED TO FAIL until the bug it names is fixed. Each is also pinned by
// a unit elm-test under compiler/tests/ (named in the test's comment).
// `eco diff` tests use a throwaway local package server (GUIDA_REGISTRY) and a throwaway HOME.
// Run: node --test test/scripts/cli-builder.test.js
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const ECO = path.resolve(__dirname, "../../compiler/bin/index.js");
const APP_ELM_JSON = path.resolve(__dirname, "../elm/elm.json");
const MAIN = 'module Main exposing (main)\n\nimport Html\n\n\nmain =\n    Html.text "hi"\n';

function tmpdir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "eco-cli-builder-"));
}
function project(files, elmJson) {
  const dir = tmpdir();
  fs.writeFileSync(path.join(dir, "elm.json"), elmJson || fs.readFileSync(APP_ELM_JSON, "utf8"));
  for (const [rel, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), text);
  }
  return dir;
}
// Async spawn so an in-process HTTP server can answer while eco runs.
function eco(dir, args, { env, nodeArgs } = {}) {
  return new Promise((resolve) => {
    const p = spawn(process.execPath, [...(nodeArgs || []), ECO, ...args], {
      cwd: dir, env: { ...process.env, ...(env || {}) },
    });
    let out = "";
    p.stdout.on("data", (d) => (out += d));
    p.stderr.on("data", (d) => (out += d));
    const t = setTimeout(() => p.kill("SIGKILL"), 300000);
    p.on("close", (status) => {
      clearTimeout(t);
      resolve({ status, out: out.replace(/\x1b\[[0-9;]*m/g, "") });
    });
  });
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
async function ecoDiff(routes, pkg) {
  const s = await registry(routes);
  try {
    return await eco(tmpdir(), ["diff", pkg, "1.0.0", "2.0.0"], {
      env: { HOME: tmpdir(), GUIDA_REGISTRY: `http://127.0.0.1:${s.address().port}` },
    });
  } finally {
    s.close();
  }
}
const docsWithFoo = (args) => JSON.stringify([{ name: "M", comment: "", aliases: [], values: [], binops: [],
  unions: [{ name: "Foo", comment: "", args, cases: [] }] }]);
const PKG_ELM_JSON = (name, version) => JSON.stringify({
  type: "package", name, summary: "x", license: "BSD-3-Clause", version,
  "exposed-modules": ["M"], "elm-version": "0.19.0 <= v < 0.20.0",
  dependencies: { "elm/core": "1.0.0 <= v < 2.0.0" }, "test-dependencies": {},
}, null, 4);
const PKG_M = "module M exposing (x)\n\n{-| D\n\n@docs x\n-}\n\n{-| x -}\nx : Int\nx =\n    1\n";

// Bug 1: Builder.Deps.Diff rates an opaque type gaining a type parameter as PATCH; every
// annotation `Foo a` in user code breaks, so it is MAJOR. Unit: Builder/Deps/DiffTest.elm.
test("eco diff: opaque type gaining a parameter is MAJOR", async () => {
  const r = await ecoDiff({
    "/all-packages": JSON.stringify({ "zz/pkg": ["1.0.0", "2.0.0"] }),
    "/packages/zz/pkg/1.0.0/docs.json": docsWithFoo(["a"]),
    "/packages/zz/pkg/2.0.0/docs.json": docsWithFoo(["a", "b"]),
  }, "zz/pkg");
  assert.doesNotMatch(r.out, /No API changes detected/, r.out);
  assert.match(r.out, /MAJOR/, r.out);
});

// Bug 2: Builder.Generate/Exit.toGenerateReport says "This is likely a compiler bug" for the
// STAGE ARITY LIMIT, a program condition (one captured polymorphic local function specialised
// at 2197 types). Unit: Builder/GenerateTest.elm. --stack-size: the default node stack
// overflows in the compiler on this input (a separate problem).
test("STAGE ARITY LIMIT is not reported as a likely compiler bug", async () => {
  const b = ["1", '"a"', "1.5", "'c'", "()", "[ 1 ]", '[ "s" ]', "Just 1", "Nothing", "{ a = 1 }",
    "( 1, 1 )", "[ 1.5 ]", '{ b = "" }'];
  const calls = [];
  for (const x of b) for (const y of b) for (const z of b) calls.push(`Tuple.first (poly ( ${x}, ${y}, ${z} ))`);
  const wide = "module Wide exposing (main)\n\nimport Html\n\n\nmain =\n    Html.text (String.fromInt (g 1))\n\n\n" +
    "g v0 =\n    let\n        poly x =\n            ( v0, x )\n\n        f u =\n            List.sum\n" +
    "                [ u\n                , " + calls.join("\n                , ") + "\n                ]\n" +
    "    in\n    List.foldl (\\x acc -> f (x + acc)) 0 [ 1, 2, 3 ]\n";
  const dir = project({ "src/Wide.elm": wide });
  const r = await eco(dir, ["make", "src/Wide.elm", "--output=w.mlir"], { nodeArgs: ["--stack-size=7000"] });
  assert.match(r.out, /STAGE ARITY LIMIT/, r.out);
  assert.doesNotMatch(r.out, /compiler bug/, r.out);
});

// Bug 3: Builder.Reporting.Exit DP_Data puts the response body where its byte count belongs
// ("The response body contains QQQQQ bytes"). Unit: Builder/Reporting/ExitDocsDataTest.elm.
test("eco diff: undecodable docs.json report gives the body length", async () => {
  const r = await ecoDiff({
    "/all-packages": JSON.stringify({ "zz/bad": ["1.0.0", "2.0.0"] }),
    "/packages/zz/bad/1.0.0/docs.json": "QQQQQ",
    "/packages/zz/bad/2.0.0/docs.json": "QQQQQ",
  }, "zz/bad");
  assert.match(r.out, /PROBLEM LOADING DOCS/, r.out);
  assert.match(r.out, /contains\s+5\s+bytes/, r.out);
});

// Bug 4: Terminal.Make.parseOutput accepts a bare extension: --output=.js is taken as a native
// executable target and fails with NATIVE LOWERING ERROR (exit 0). Unit: Terminal/MakeTest.elm.
for (const ext of [".js", ".html", ".mlir"]) {
  test(`--output=${ext} is rejected, not treated as a native target`, async () => {
    const dir = project({ "src/Main.elm": MAIN });
    const r = await eco(dir, ["make", "src/Main.elm", `--output=${ext}`]);
    assert.doesNotMatch(r.out, /NATIVE LOWERING/, r.out);
    assert.notStrictEqual(r.status, 0, r.out);
  });
}

// Bug 5: Compiler.Json.Decode reports every parse error at the start (1:1): a missing colon
// in elm.json gets "EXPECTING A VALUE" with the caret under `{`. Unit: Compiler/Json/DecodeTest.elm.
test("malformed elm.json error points at the missing colon", async () => {
  const dir = project({ "src/Main.elm": MAIN }, '{"type" "application"}');
  const r = await eco(dir, ["make", "src/Main.elm", "--output=o.js"]);
  assert.notStrictEqual(r.status, 0, r.out);
  assert.doesNotMatch(r.out, /EXPECTING A VALUE/, r.out);
  assert.doesNotMatch(r.out, /1\| \{"type" "application"\}\n {3}\^/, r.out); // caret at column 1
});

// Bug 6: Compiler.Json.Encode writes control characters raw, so `make --docs` with a doc
// comment containing U+0001 / form feed writes invalid docs.json. Unit: Compiler/Json/EncodeTest.elm.
test("make --docs writes valid JSON for doc comments with control characters", async () => {
  const m = "module M exposing (x)\n\n{-| Doc with \x01 ctrl.\n\n@docs x\n-}\n\n{-| x\x0c ff -}\nx : Int\nx =\n    1\n";
  const dir = project({ "src/M.elm": m }, PKG_ELM_JSON("author/proj", "1.0.0"));
  const r = await eco(dir, ["make", "--docs=docs.json"]);
  assert.strictEqual(r.status, 0, r.out);
  assert.doesNotThrow(() => JSON.parse(fs.readFileSync(path.join(dir, "docs.json"), "utf8")));
});

// Bug 7a: Compiler.Elm.Package accepts an author ending in a dash ("author-/proj").
// Unit: Compiler/Elm/PackageTest.elm. ("author/proj-" is rejected: INVALID PACKAGE NAME.)
test("elm.json package name with author ending in a dash is rejected", async () => {
  const dir = project({ "src/M.elm": PKG_M }, PKG_ELM_JSON("author-/proj", "1.0.0"));
  const r = await eco(dir, ["make", "--docs=docs.json"]);
  assert.notStrictEqual(r.status, 0, r.out);
  assert.match(r.out, /INVALID PACKAGE NAME/, r.out);
});

// Bug 7b: Compiler.Elm.Version accepts an unbounded component ("1.0.99999999999999999999").
// Unit: Compiler/Elm/VersionTest.elm.
test("elm.json version with an over-long component is rejected", async () => {
  const dir = project({ "src/M.elm": PKG_M }, PKG_ELM_JSON("author/proj", "1.0.99999999999999999999"));
  const r = await eco(dir, ["make", "--docs=docs.json"]);
  assert.notStrictEqual(r.status, 0, r.out);
});
