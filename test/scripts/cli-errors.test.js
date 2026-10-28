// Regression tests for error-reporting bugs observable through the `eco make` front end
// (compiler/bin/index.js, run against the built build/compiler/build-xhr/bin/guida.js).
// "errors" group. Every test here is EXPECTED TO FAIL until the bug it names is fixed; each test's
// comment names the bug and the elm-test unit test (under compiler/tests/) that also covers it.
// Run: node --test test/scripts/cli-errors.test.js
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const ECO = path.resolve(__dirname, "../../compiler/bin/index.js");
const APP_ELM_JSON = path.resolve(__dirname, "../elm/elm.json");

function project(files, elmJson) {
  const dir = (fs.mkdirSync("/tmp/cli-errors", { recursive: true }), fs.mkdtempSync("/tmp/cli-errors/t-"));
  fs.writeFileSync(path.join(dir, "elm.json"), elmJson || fs.readFileSync(APP_ELM_JSON, "utf8"));
  for (const [rel, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), text);
  }
  return dir;
}
function ecoRaw(dir, args) {
  const r = spawnSync(process.execPath, [ECO, ...args], { cwd: dir, encoding: "utf8", timeout: 300000 });
  return { status: r.status, raw: (r.stdout || "") + (r.stderr || "") };
}
function eco(dir, args) {
  const r = ecoRaw(dir, args);
  return { status: r.status, out: r.raw.replace(/\x1b\[[0-9;]*m/g, "") };
}
// Compiles a one-module application whose src/Main.elm is `main`.
function make(main) {
  const dir = project({ "src/Main.elm": main });
  return eco(dir, ["make", "src/Main.elm", "--output=out.js"]);
}
const HEAD = "module Main exposing (main)\n\nimport Html\n\n\n";
const MAIN = 'main =\n    Html.text "a"\n';

// Bugs 1 + 4: Compiler.Reporting.Doc.hcat (Text.PrettyPrint.ANSI.Leijen.hcat) keeps only the last doc, and
// Compiler.Reporting.Error.Pattern.delist leaves finite-list entries reversed. A missing two-element list
// pattern is shown as `[_]` (only the last entry survives hcat). Unit tests:
// Compiler/Reporting/DocHcatTest.elm, Compiler/Reporting/Error/PatternFiniteListTest.elm,
// Text/PrettyPrint/ANSI/LeijenTest.elm ("hcat keeps every document"). EXPECTED TO FAIL until fixed.
test("a missing two-element list pattern is printed with both entries", () => {
  const r = make(HEAD +
    "f : List Int -> Int\nf xs =\n    case xs of\n        [] ->\n            0\n\n        [ _ ] ->\n            1\n\n" +
    "        _ :: _ :: _ :: _ ->\n            3\n\n\n" + MAIN);
  assert.match(r.out, /MISSING PATTERNS/);
  assert.match(r.out, /\[_,_\]/, r.out);
});

// Bug 2: Compiler.Reporting.Render.Code.whatIsNext / detectKeywords filter the whole rest of the line instead
// of taking the leading run, so `then x` is read as the name "henx" and reported as UNEXPECTED NAME with a
// 6-column highlight instead of RESERVED WORD on `then`. Unit test:
// Compiler/Reporting/Render/CodeWhatIsNextTest.elm. EXPECTED TO FAIL until fixed.
test("a stray reserved word is reported as RESERVED WORD", () => {
  const r = make(HEAD + 'main =\n    Html.text "a" then x\n');
  assert.match(r.out, /RESERVED WORD/, r.out);
  assert.match(r.out, /The name `then` is reserved/);
});

// Bug 2 (second path): an indented first line ` module Main exposing (main)` should get the
// TOO MUCH INDENTATION advice; whatIsNext returns Lower 'm' "oduleMainexposingmain" instead of Keyword
// "module", so a generic SYNTAX PROBLEM is shown. Unit test: Compiler/Reporting/Render/CodeWhatIsNextTest.elm.
// EXPECTED TO FAIL until fixed.
test("an indented module line is reported as TOO MUCH INDENTATION", () => {
  const r = make(" " + HEAD + MAIN);
  assert.match(r.out, /TOO MUCH INDENTATION/, r.out);
});

// Bug 3a: Compiler.Reporting.Result.indexedTraverse (used by Canonicalize.Environment.Local for the
// constructors of a custom type) keeps only one error: with two unknown argument types only `Bar` is
// reported, `Foo` is lost. Unit test: Compiler/Reporting/ResultTraverseErrorsTest.elm. EXPECTED TO FAIL.
test("unknown types in two constructors are both reported", () => {
  const r = make(HEAD + "type T\n    = A Foo\n    | B Bar\n\n\n" + MAIN);
  assert.match(r.out, /cannot find a `Bar` type/);
  assert.match(r.out, /cannot find a `Foo` type/, r.out);
});

// Bug 3b: Compiler.Reporting.Result.mapTraverseWithKey (used by Canonicalize.Environment.Dups.detect) keeps
// only the first failing entry: `f (a, a) (b, b)` reports the duplicate `a` but not `b`. Unit test:
// Compiler/Reporting/ResultTraverseErrorsTest.elm. EXPECTED TO FAIL until fixed.
test("two different duplicated arguments are both reported", () => {
  const r = make(HEAD + "f ( a, a ) ( b, b ) =\n    1\n\n\n" + MAIN);
  assert.match(r.out, /multiple `a` arguments/);
  assert.match(r.out, /multiple `b` arguments/, r.out);
});

// Bug 5: Compiler.Reporting.Error.Json.expectationToReport crashes ("region") on any single-row Expecting
// problem: an elm.json with `"elm-version": 19` makes eco crash with a JS stack trace instead of reporting
// the bad field. Unit test: Compiler/Reporting/Error/JsonSingleRowTest.elm. EXPECTED TO FAIL until fixed.
test("a wrongly typed scalar in elm.json gives a report, not a crash", () => {
  const json = fs.readFileSync(APP_ELM_JSON, "utf8").replace('"elm-version": "0.19.1"', '"elm-version": 19');
  const dir = project({ "src/Main.elm": HEAD + MAIN }, json);
  const r = eco(dir, ["make", "src/Main.elm", "--output=out.js"]);
  assert.notStrictEqual(r.status, 0);
  assert.doesNotMatch(r.out, /Eco\.Crash|threw while handling|_Debug_crash/, r.out);
  assert.match(r.out, /elm\.json/);
});

// Bug 6: Compiler.Canonicalize.Environment.Dups.unions folds later-first, so a duplicate constructor's
// "One here:" snippet shows the LATER occurrence (line 9) and "another one here:" the earlier (line 7).
// Unit test: Compiler/Canonicalize/Environment/DupsUnionsOrderTest.elm. EXPECTED TO FAIL until fixed.
test("a duplicate constructor is reported earlier occurrence first", () => {
  const r = make(HEAD + "type T\n    = A\n    | B\n    | A\n\n\n" + MAIN);
  assert.match(r.out, /NAME CLASH/);
  const first = r.out.indexOf("One here:");
  const second = r.out.indexOf("And another one here:");
  assert.ok(first >= 0 && second > first, r.out);
  assert.match(r.out.slice(first, second), /^7\|\s+= A$/m, r.out);
});

// Bug 7: Compiler.Elm.Docs.checkNames keeps only the last name's outcome, so a package module that exposes
// `a` without documenting it and lists `b` on @docs without exposing it passes `eco make --docs` (rc 0,
// docs.json written) because the last name `z` is fine. Unit test: Compiler/Elm/DocsTest.elm.
// EXPECTED TO FAIL until fixed.
test("@docs / exposing disagreements fail eco make --docs", () => {
  const elmJson = JSON.stringify({
    type: "package", name: "author/example", summary: "Example package", license: "BSD-3-Clause",
    version: "1.0.0", "exposed-modules": ["Example"], "elm-version": "0.19.0 <= v < 0.20.0",
    dependencies: { "elm/core": "1.0.0 <= v < 2.0.0" }, "test-dependencies": {},
  }, null, 4);
  const src = "module Example exposing (a, z)\n\n{-| Example.\n\n@docs b, z\n\n-}\n\n\n" +
    "{-| a -}\na : Int\na =\n    1\n\n\n{-| z -}\nz : Int\nz =\n    2\n";
  const dir = project({ "src/Example.elm": src }, elmJson);
  const r = eco(dir, ["make", "--docs=docs.json"]);
  assert.notStrictEqual(r.status, 0, r.out);
  assert.ok(!fs.existsSync(path.join(dir, "docs.json")), "docs.json was written");
});

// Bug 8: Compiler.Type.Constrain.Typed.Expression.constrainLetSpine reports a let body that mismatches the
// annotation at the whole `let` as "an anonymous function" instead of at the body `"s"` as a string.
// Unit test: Compiler/Type/Constrain/Typed/ExpressionTest.elm. EXPECTED TO FAIL until fixed.
test("a let body that mismatches its annotation is reported as a string at the body", () => {
  const r = make(HEAD + 'f : Int\nf =\n    let\n        x =\n            1\n    in\n    "s"\n\n\n' + MAIN);
  assert.match(r.out, /TYPE MISMATCH/);
  assert.doesNotMatch(r.out, /anonymous function/, r.out);
  assert.match(r.out, /The body is a string of type/, r.out);
});

// Bug 9: System.IO.isTerminal is hard-coded True (Builder.Reporting.Exit.Help.toHandle), so error reports
// written to a pipe/file carry ANSI escape codes; the plain path would also leak codes through
// Text.PrettyPrint.ANSI.Leijen.plain. Unit test: Text/PrettyPrint/ANSI/LeijenTest.elm (plain/reset cases).
// EXPECTED TO FAIL until fixed.
test("error reports written to a pipe contain no ANSI escape codes", () => {
  const dir = project({ "src/Main.elm": HEAD + "main =\n    Html.text (1 + \"a\")\n" });
  const r = ecoRaw(dir, ["make", "src/Main.elm", "--output=out.js"]);
  assert.match(r.raw, /TYPE MISMATCH/);
  assert.doesNotMatch(r.raw, /\x1b\[/, JSON.stringify(r.raw.slice(0, 400)));
});

// Bug 10: Compiler.Parse.Primitives.andThen passes "consumed, then failed without consuming" on as an
// empty error, so chompListEnd's oneOf falls back to its `]` alternative at the comma. `[1,2,]` is reported
// as UNFINISHED LIST at the comma ("expecting to see a closing square bracket") instead of "another list
// entry after that last comma" at the `]`. Unit test: Compiler/Parse/PrimitivesAndThenConsumedTest.elm.
// EXPECTED TO FAIL until fixed.
test("a trailing comma in a list is reported after the comma", () => {
  const r = make(HEAD + "main =\n    Html.text (Debug.toString [ 1, 2, ])\n");
  assert.match(r.out, /UNFINISHED LIST/);
  assert.match(r.out, /another list entry after that last comma/, r.out);
});
