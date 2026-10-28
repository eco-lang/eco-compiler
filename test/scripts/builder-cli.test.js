// Regression tests for Builder/Terminal bugs observable through the `eco make` front end
// (compiler/bin/index.js, run against the built build/compiler/build-xhr/bin/guida.js).
// S2 verification, builder batch. Every test here is EXPECTED TO FAIL until the bug it names is fixed:
//   1. Builder.Build.handleCachedDepsStatus: deleting a module that an unchanged module imports
//      crashes with "Error from `Main` should have been reported already." (DepsNotFound -> RBlocked,
//      RNotFound not counted by addErrors).
//   2. Builder.Build.checkRoots: Utils.dictFromListWith always returns Dict.empty, so the same file given
//      twice is not reported (BP_MainPathDuplicate, "CONFUSING FILES").
//   3. Builder.Build.checkUniqueRoots: same cause; two outside files both named `Main` are not reported
//      (BP_RootNameDuplicate, "MODULE NAME CLASH").
//   4. Builder.Elm.Outline.detectDuplicates: same cause; source-directories ["src", "./src"] is not reported
//      as REDUNDANT SOURCE DIRECTORIES.
//   5. Builder.Build.crawlSinglePath: a local module clashing with a package module prints an ABSOLUTE path
//      in the AMBIGUOUS IMPORT report (local/local clashes are made relative).
//   6. Builder.Deps.Solver.parseAndValidateCachedConstraints: a malformed elm.json of a --local-package is
//      DELETED from the user's own source directory (it is treated as a corrupt cache entry).
//   7. Terminal.Terminal.Chomp: a known flag given twice (`--debug --debug`) is reported as an unknown flag.
//   8. Terminal.Make: `--docs` is silently ignored when files are named.
// Run: node --test test/scripts/builder-cli.test.js
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const ECO = path.resolve(__dirname, "../../compiler/bin/index.js");
const APP_ELM_JSON = path.resolve(__dirname, "../elm/elm.json");

const MAIN = 'module Main exposing (main)\n\nimport B\nimport Html\n\n\nmain =\n    Html.text B.b\n';
const B = 'module B exposing (b)\n\n\nb =\n    "hi"\n';

function project(files, elmJson) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "eco-builder-cli-"));
  fs.writeFileSync(path.join(dir, "elm.json"), elmJson || fs.readFileSync(APP_ELM_JSON, "utf8"));
  for (const [rel, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), text);
  }
  return dir;
}
function eco(dir, args) {
  const r = spawnSync(process.execPath, [ECO, ...args], { cwd: dir, encoding: "utf8", timeout: 300000 });
  return { status: r.status, out: ((r.stdout || "") + (r.stderr || "")).replace(/\x1b\[[0-9;]*m/g, "") };
}
function appJsonWith(mutate) {
  const d = JSON.parse(fs.readFileSync(APP_ELM_JSON, "utf8"));
  mutate(d);
  return JSON.stringify(d, null, 4);
}

test("deleting an imported module reports an import error instead of crashing", () => {
  const dir = project({ "src/Main.elm": MAIN, "src/B.elm": B });
  assert.strictEqual(eco(dir, ["make", "src/Main.elm", "--output=out.js"]).status, 0);
  fs.unlinkSync(path.join(dir, "src/B.elm"));
  const r = eco(dir, ["make", "src/Main.elm", "--output=out.js"]);
  assert.doesNotMatch(r.out, /should have been reported already/);
  assert.match(r.out, /MODULE NOT FOUND/);
});

test("the same main file given twice is reported", () => {
  const dir = project({ "src/Main.elm": MAIN, "src/B.elm": B });
  const r = eco(dir, ["make", "src/Main.elm", "./src/Main.elm", "--output=out.js"]);
  assert.notStrictEqual(r.status, 0, r.out);
  assert.match(r.out, /CONFUSING FILES/);
});

test("two outside roots with the same module name are reported", () => {
  const main = 'module Main exposing (main)\n\nimport Html\n\n\nmain =\n    Html.text "a"\n';
  const dir = project({ "src/B.elm": B, "o1/Main.elm": main, "o2/Main.elm": main });
  const r = eco(dir, ["make", "o1/Main.elm", "o2/Main.elm", "--output=out.js"]);
  assert.notStrictEqual(r.status, 0, r.out);
  assert.match(r.out, /MODULE NAME CLASH/);
});

test("a source directory listed twice is reported as redundant", () => {
  const dir = project({ "src/Main.elm": MAIN, "src/B.elm": B },
    appJsonWith((d) => { d["source-directories"] = ["src", "./src"]; }));
  const r = eco(dir, ["make", "src/Main.elm", "--output=out.js"]);
  assert.match(r.out, /REDUNDANT SOURCE DIRECTORIES/);
});

test("AMBIGUOUS IMPORT between a local file and a package names the file relatively", () => {
  const dir = project({ "src/Main.elm": MAIN, "src/B.elm": B, "src/Html.elm": "module Html exposing (x)\n\nx = 1\n" });
  const r = eco(dir, ["make", "src/Main.elm", "--output=out.js"]);
  assert.match(r.out, /AMBIGUOUS IMPORT/);
  assert.ok(!r.out.includes(dir), "report contains the absolute project path:\n" + r.out);
});

test("a malformed elm.json of a --local-package is not deleted", () => {
  const lib = fs.mkdtempSync(path.join(os.tmpdir(), "eco-builder-cli-lib-"));
  fs.mkdirSync(path.join(lib, "src"));
  fs.writeFileSync(path.join(lib, "elm.json"), "{ this is not json");
  const dir = project({ "src/Main.elm": MAIN, "src/B.elm": B },
    appJsonWith((d) => { d.dependencies.direct["me/lib"] = "1.0.0"; }));
  eco(dir, ["make", "src/Main.elm", "--output=out.js", "--local-package=me/lib=" + lib]);
  assert.ok(fs.existsSync(path.join(lib, "elm.json")), "the user's own elm.json was deleted");
});

test("a known flag given twice is not reported as unknown", () => {
  const dir = project({ "src/Main.elm": MAIN, "src/B.elm": B });
  const r = eco(dir, ["make", "--debug", "--debug", "src/Main.elm", "--output=out.js"]);
  assert.doesNotMatch(r.out, /do not recognize this flag/);
});

test("--docs with named files writes docs or is rejected", () => {
  const dir = project({ "src/Main.elm": MAIN, "src/B.elm": B });
  const r = eco(dir, ["make", "src/Main.elm", "--output=out.js", "--docs=d.json"]);
  assert.ok(r.status !== 0 || fs.existsSync(path.join(dir, "d.json")), "--docs silently ignored:\n" + r.out);
});
