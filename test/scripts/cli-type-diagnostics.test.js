// Type-checker and canonicalizer diagnostics that differ from Elm 0.19.1, observed through the
// `eco make` front end (compiler/bin/index.js, run against the built build/compiler/build-xhr/bin/guida.js).
// Each test compiles a small erroneous program and checks the report against what
// /work/build/toolchain/bin/elm (0.19.1) prints for the same program.
// Run: node --test test/scripts/cli-type-diagnostics.test.js
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const ECO = path.resolve(__dirname, "../../compiler/bin/index.js");
const APP_ELM_JSON = path.resolve(__dirname, "../elm/elm.json");

function make(main) {
  fs.mkdirSync("/tmp/cli-type-diagnostics", { recursive: true });
  const dir = fs.mkdtempSync("/tmp/cli-type-diagnostics/t-");
  fs.writeFileSync(path.join(dir, "elm.json"), fs.readFileSync(APP_ELM_JSON, "utf8"));
  fs.mkdirSync(path.join(dir, "src"));
  fs.writeFileSync(path.join(dir, "src/Main.elm"), main);
  const r = spawnSync(process.execPath, [ECO, "make", "src/Main.elm", "--output=out.js"],
    { cwd: dir, encoding: "utf8", timeout: 300000 });
  return ((r.stdout || "") + (r.stderr || "")).replace(/\x1b\[[0-9;]*m/g, "");
}
const HEAD = "module Main exposing (main)\n\nimport Html\n\n\n";
const MAIN = 'main =\n    Html.text "a"\n';

// Compiler.Reporting.Error.Canonicalize.aliasToUnionDoc folds the alias parameters with the flipped
// `D.plus` (`List.foldr D.plus (D.fromChars "=") args`), so the suggested `type` declaration for a
// directly recursive alias `Tree a b` is printed as `type  Tree = b a` instead of Elm's `type Tree a b =`.
test("a recursive alias suggestion declares its parameters before the =", () => {
  const out = make(HEAD +
    "type alias Tree a b =\n    { value : a, other : b, kids : List (Tree a b) }\n\n\n" + MAIN);
  assert.match(out, /ALIAS PROBLEM/, out);
  assert.match(out, /^ {4}type Tree a b =$/m, out);
});

// System.TypeCheck.IO.foldrM folds from the HEAD of the list (it is a foldlM), while Haskell's foldrM,
// which Compiler.Type.Type.getVarNames was ported from, visits the LAST element first. So for the
// right side `( Maybe a, a )` of the failed `==` below, getVarNames meets `Nothing`'s instantiated
// flex var (named `a`) before the annotation's rigid `a`, and addName renames the RIGID variable to
// `a1` in the store. Both sides, and the hint, then call the annotation's variable `a1`, which the
// annotation does not mention. Elm 0.19.1 keeps `a` for the annotation variable here:
//   The left side of (==) is:  ( a, number )   ...   Hint: Your type annotation uses type variable `a`
test("a rigid annotation variable keeps its name in a type mismatch report", () => {
  const out = make(HEAD +
    "k : a -> Bool\nk x =\n    ( x, 1 ) == ( Nothing, x )\n\n\n" +
    'main =\n    Html.text (if k 2 then "a" else "b")\n');
  assert.match(out, /TYPE MISMATCH/, out);
  assert.match(out, /The left side of \(==\) is:\s+\( a, number \)/, out);
  assert.match(out, /Your type annotation uses type variable `a` which/, out);
});
