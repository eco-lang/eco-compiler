// Regression tests for error-reporting bugs observable through the `eco make` front end
// (compiler/bin/index.js, run against the built build/compiler/build-xhr/bin/guida.js).
// "errors" group. Each test pins a bug (tests 1-10 fixed 2026-10-28 by plans/review-bug-triage-fixes.md
// Part 5); each test's comment names the bug and the elm-test unit test (under compiler/tests/) that also
// covers it.
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
// Compiler.Nitpick.Error.delist leaves finite-list entries reversed. A missing two-element list
// pattern is shown as `[_]` (only the last entry survives hcat). Unit tests:
// Compiler/Reporting/DocHcatTest.elm, Compiler/Nitpick/ErrorTest.elm,
// Text/PrettyPrint/ANSI/LeijenTest.elm ("hcat keeps every document").
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
// Compiler/Reporting/Render/CodeWhatIsNextTest.elm.
test("a stray reserved word is reported as RESERVED WORD", () => {
  const r = make(HEAD + 'main =\n    Html.text "a" then x\n');
  assert.match(r.out, /RESERVED WORD/, r.out);
  assert.match(r.out, /The name `then` is reserved/);
});

// Bug 2 (second path): an indented first line ` module Main exposing (main)` should get the
// TOO MUCH INDENTATION advice; whatIsNext returns Lower 'm' "oduleMainexposingmain" instead of Keyword
// "module", so a generic SYNTAX PROBLEM is shown. Unit test: Compiler/Reporting/Render/CodeWhatIsNextTest.elm.
test("an indented module line is reported as TOO MUCH INDENTATION", () => {
  const r = make(" " + HEAD + MAIN);
  assert.match(r.out, /TOO MUCH INDENTATION/, r.out);
});

// Bug 3a: Compiler.Reporting.Result.indexedTraverse (used by Canonicalize.Environment.Local for the
// constructors of a custom type) keeps only one error: with two unknown argument types only `Bar` is
// reported, `Foo` is lost. Unit test: Compiler/Reporting/ResultTraverseErrorsTest.elm.
test("unknown types in two constructors are both reported", () => {
  const r = make(HEAD + "type T\n    = A Foo\n    | B Bar\n\n\n" + MAIN);
  assert.match(r.out, /cannot find a `Bar` type/);
  assert.match(r.out, /cannot find a `Foo` type/, r.out);
});

// Bug 3b: Compiler.Reporting.Result.mapTraverseWithKey (used by Canonicalize.Environment.Dups.detect) keeps
// only the first failing entry: `f (a, a) (b, b)` reports the duplicate `a` but not `b`. Unit test:
// Compiler/Reporting/ResultTraverseErrorsTest.elm.
test("two different duplicated arguments are both reported", () => {
  const r = make(HEAD + "f ( a, a ) ( b, b ) =\n    1\n\n\n" + MAIN);
  assert.match(r.out, /multiple `a` arguments/);
  assert.match(r.out, /multiple `b` arguments/, r.out);
});

// Bug 5: Builder.Reporting.Exit.JsonError.expectationToReport crashes ("region") on any single-row Expecting
// problem: an elm.json with `"elm-version": 19` makes eco crash with a JS stack trace instead of reporting
// the bad field. Unit test: Builder/Reporting/Exit/JsonErrorTest.elm.
test("a wrongly typed scalar in elm.json gives a report, not a crash", () => {
  const json = fs.readFileSync(APP_ELM_JSON, "utf8").replace('"elm-version": "0.19.1"', '"elm-version": 19');
  const dir = project({ "src/Main.elm": HEAD + MAIN }, json);
  const r = eco(dir, ["make", "src/Main.elm", "--output=out.js"]);
  assert.notStrictEqual(r.status, 0);
  assert.doesNotMatch(r.out, /Eco\.Crash|threw while handling|_Debug_crash/, r.out);
  assert.match(r.out, /elm\.json/);
});

// Bug 6: Compiler.Canonicalize.Dups.unions folds later-first, so a duplicate constructor's
// "One here:" snippet shows the LATER occurrence (line 9) and "another one here:" the earlier (line 7).
// Unit test: Compiler/Canonicalize/DupsUnionsOrderTest.elm.
test("a duplicate constructor is reported earlier occurrence first", () => {
  const r = make(HEAD + "type T\n    = A\n    | B\n    | A\n\n\n" + MAIN);
  assert.match(r.out, /NAME CLASH/);
  const first = r.out.indexOf("One here:");
  const second = r.out.indexOf("And another one here:");
  assert.ok(first >= 0 && second > first, r.out);
  assert.match(r.out.slice(first, second), /^7\|\s+= A$/m, r.out);
});

// Bug 7: Compiler.Docs.checkNames keeps only the last name's outcome, so a package module that exposes
// `a` without documenting it and lists `b` on @docs without exposing it passes `eco make --docs` (rc 0,
// docs.json written) because the last name `z` is fine. Unit test: Compiler/DocsTest.elm.
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
// Unit test: Compiler/Type/Constrain/Typed/ExpressionTest.elm.
test("a let body that mismatches its annotation is reported as a string at the body", () => {
  const r = make(HEAD + 'f : Int\nf =\n    let\n        x =\n            1\n    in\n    "s"\n\n\n' + MAIN);
  assert.match(r.out, /TYPE MISMATCH/);
  assert.doesNotMatch(r.out, /anonymous function/, r.out);
  assert.match(r.out, /The body is a string of type/, r.out);
});

// Bug 9: System.IO.isTerminal is hard-coded True (Builder.Reporting.Exit.Help.toHandle), so error reports
// written to a pipe/file carry ANSI escape codes; the plain path would also leak codes through
// Text.PrettyPrint.ANSI.Leijen.plain. Unit test: Text/PrettyPrint/ANSI/LeijenTest.elm (plain/reset cases).
test("error reports written to a pipe contain no ANSI escape codes", () => {
  const dir = project({ "src/Main.elm": HEAD + "main =\n    Html.text (1 + \"a\")\n" });
  const r = ecoRaw(dir, ["make", "src/Main.elm", "--output=out.js"]);
  assert.match(r.raw, /TYPE MISMATCH/);
  assert.doesNotMatch(r.raw, /\x1b\[/, JSON.stringify(r.raw.slice(0, 400)));
});

// Bug 10 (fixed 2026-10-28, plan review-bug-triage-fixes.md 5.1): Compiler.Lexer.Primitives.andThen passed
// "consumed, then failed without consuming" on as an empty error, so chompListEnd's oneOf falls back to its `]` alternative at the comma. `[1,2,]` is reported
// as UNFINISHED LIST at the comma ("expecting to see a closing square bracket") instead of "another list
// entry after that last comma" at the `]`. Unit test: Compiler/Lexer/PrimitivesAndThenConsumedTest.elm.
test("a trailing comma in a list is reported after the comma", () => {
  const r = make(HEAD + "main =\n    Html.text (Debug.toString [ 1, 2, ])\n");
  assert.match(r.out, /UNFINISHED LIST/);
  assert.match(r.out, /another list entry after that last comma/, r.out);
});

// Kernel headers (plans/dead-code-report.md, b2-parse and C-R1). Compiler.Parse.Kernel crashed on five
// header forms the import parser accepts (`as` on a kernel import, a dotted module without `as`,
// `exposing (..)`, `Type(..)`, an operator), Builder.Build.checkKernelExistsInDirs accepted a kernel file
// whose header or body did not parse at all, and Canonicalize.Environment.Foreign crashed on an Elm
// module's `import Elm.Kernel.X as Y`. Each is now a KERNEL syntax error at the line, and a valid kernel
// file still builds. Unit tests: Compiler/Parse/KernelTest.elm, Compiler/Parse/ModuleTest.elm.
const KERNEL_PKG_ELM_JSON = JSON.stringify({
  type: "package", name: "elm/foo", summary: "x", license: "BSD-3-Clause", version: "1.0.0",
  "exposed-modules": ["Foo"], "elm-version": "0.19.0 <= v < 0.20.0",
  dependencies: { "elm/core": "1.0.0 <= v < 2.0.0" }, "test-dependencies": {},
}, null, 4);
const FOO = "module Foo exposing (x)\n\nimport Elm.Kernel.Foo\n\n\nx : Int\nx =\n    Elm.Kernel.Foo.x\n";
// Builds the kernel package elm/foo whose src/Elm/Kernel/Foo.js is `js` and whose src/Foo.elm is `foo`.
function makeKernelPackage(js, foo) {
  const dir = project({ "src/Foo.elm": foo || FOO, "src/Elm/Kernel/Foo.js": js }, KERNEL_PKG_ELM_JSON);
  return eco(dir, ["make"]);
}
const kernelJs = (header, body) => "/*\n\n" + header + "\n\n*/\n\n" + (body || "var _Foo_x = 1;\n");
function assertKernelError(r, title, message) {
  assert.notStrictEqual(r.status, 0, r.out);
  assert.doesNotMatch(r.out, /Eco\.Crash|threw while handling/, r.out);
  assert.match(r.out, title, r.out);
  assert.match(r.out, message, r.out);
}

test("a valid kernel file builds", () => {
  const r = makeKernelPackage(kernelJs("import Elm.Kernel.Utils exposing (Tuple0)", "var _Foo_x = __Utils_Tuple0;\n"));
  assert.strictEqual(r.status, 0, r.out);
});

test("a kernel header import of a kernel module with `as` is a syntax error", () => {
  assertKernelError(makeKernelPackage(kernelJs("import Elm.Kernel.Utils as U exposing (Tuple0)")),
    /KERNEL IMPORT/, /Elm\.Kernel\.Utils/);
});

test("a kernel header import of a dotted module without `as` is a syntax error", () => {
  assertKernelError(makeKernelPackage(kernelJs("import Json.Decode exposing (field)")),
    /KERNEL IMPORT/, /Json\.Decode/);
});

test("a kernel header `exposing (..)` is a syntax error", () => {
  assertKernelError(makeKernelPackage(kernelJs("import Maybe exposing (..)")), /KERNEL IMPORT/, /exposing \(\.\.\)/);
});

test("a kernel header `Maybe(..)` is a syntax error", () => {
  assertKernelError(makeKernelPackage(kernelJs("import Maybe exposing (Maybe(..))")), /KERNEL IMPORT/, /Maybe\(\.\.\)/);
});

test("a kernel header operator is a syntax error", () => {
  assertKernelError(makeKernelPackage(kernelJs("import Basics exposing ((+))")), /KERNEL IMPORT/, /\(\+\)/);
});

test("a kernel file whose header does not parse is a syntax error, not accepted", () => {
  assertKernelError(makeKernelPackage("/*\n\nimport\n\n*/\n\nvar _Foo_x = 1;\n"), /KERNEL HEADER/, /Elm\.Kernel\.Foo|Foo\.js/);
});

test("a kernel file using a tag it does not import is a syntax error, not accepted", () => {
  assertKernelError(makeKernelPackage(kernelJs("", "var _Foo_x = __Nope_x;\n")), /UNKNOWN KERNEL TAG/, /__Nope_x/);
});

test("an Elm import of a kernel module with `as` is a syntax error, not a crash", () => {
  assertKernelError(makeKernelPackage(kernelJs(""), FOO.replace("import Elm.Kernel.Foo\n", "import Elm.Kernel.Foo as F\n")),
    /KERNEL IMPORT/, /Elm\.Kernel\.Foo/);
});

// The same kernel header problem in a package built as a dependency (Builder.Deps.Details): the package is
// reported broken, like any compile error in a dependency, and --Xpackage-errors shows the KERNEL IMPORT
// report. ECO_HOME is a copy of ~/.eco, so that the local package's artifacts stay out of the real cache.
test("a kernel header problem in a dependency is reported, not a crash", () => {
  const foo = project({ "src/Foo.elm": FOO,
    "src/Elm/Kernel/Foo.js": kernelJs("import Elm.Kernel.Utils as U exposing (Tuple0)") }, KERNEL_PKG_ELM_JSON);
  const app = JSON.parse(fs.readFileSync(APP_ELM_JSON, "utf8"));
  app.dependencies.direct["elm/foo"] = "1.0.0";
  const dir = project({ "src/Main.elm": "module Main exposing (main)\n\nimport Foo\nimport Html\n\n\nmain =\n" +
    "    Html.text (String.fromInt Foo.x)\n" }, JSON.stringify(app, null, 4));
  const ecoHome = path.join(dir, "eco-home");
  const realHome = process.env.ECO_HOME || path.join(os.homedir(), ".eco");
  if (fs.existsSync(realHome)) fs.cpSync(realHome, ecoHome, { recursive: true });
  const r = spawnSync(process.execPath, [ECO, "make", "src/Main.elm", "--output=out.js",
    "--local-package", `elm/foo=${foo}`, "--Xpackage-errors"],
    { cwd: dir, encoding: "utf8", timeout: 600000, env: { ...process.env, ECO_HOME: ecoHome } });
  const out = ((r.stdout || "") + (r.stderr || "")).replace(/\x1b\[[0-9;]*m/g, "");
  assertKernelError({ status: r.status, out }, /PROBLEM BUILDING DEPENDENCIES/, /KERNEL IMPORT[\s\S]*Elm\.Kernel\.Utils/);
});


// Bugs found by plans/dead-code-report.md, each pinned by a test before its fix.

// Fixed: Compiler.Type.Type.variableToErrorType (Type.elm:1017). `y + 1` fails to unify the rigid `a` with
// `number` and turns `a`'s class into Error; the later `r + 1` mismatch renders `r`'s record type, whose
// extension is now ET.Error, which hit `crash "Used toErrorType on a type that is not well-formed"` instead
// of two type errors. Unit test: SourceIR/TypeCheckFailsCases.elm "record whose extension an earlier error
// marked".
test("a record extension marked by an earlier type error is reported, not a crash", () => {
    const r = make(HEAD + "f : { a | x : Int } -> a -> Int\nf r y =\n    (y + 1) + (r + 1)\n\n\n" + MAIN);
    assert.doesNotMatch(r.out, /not well-formed|Eco\.Crash/, r.out);
    assert.match(r.out, /TYPE MISMATCH[\s\S]*TYPE MISMATCH/, r.out);
  });

// Fixed: Compiler.GenerateJs.Expression.generateField (Expression.elm:479-484). LocalOpt/Erased/Expression.elm
// built Opt.Shader without registering its attribute and uniform names, so under --optimize a shader input
// that no record mentions was missing from Mode.shortenFieldNames and generation crashed with "field not
// found in ShortFieldNames". Needs elm-explorations/webgl 1.1.3 and linear-algebra 1.0.3 in the package cache.
test("an --optimize build of a shader whose attribute no record uses succeeds", () => {
    const elmJson = JSON.stringify({
      type: "application", "source-directories": ["src"], "elm-version": "0.19.1",
      dependencies: {
        direct: { "elm/core": "1.0.5", "elm/html": "1.0.0", "elm-explorations/linear-algebra": "1.0.3",
          "elm-explorations/webgl": "1.1.3" },
        indirect: { "elm/json": "1.1.3", "elm/virtual-dom": "1.0.3" },
      },
      "test-dependencies": { direct: {}, indirect: {} },
    }, null, 4);
    const main = "module Main exposing (main)\n\nimport Html exposing (Html)\nimport Math.Vector3 exposing (Vec3)\n" +
      "import WebGL exposing (Shader)\n\n\nvs : Shader { zzAttr : Vec3 } {} {}\nvs =\n    [glsl|\n" +
      "attribute vec3 zzAttr;\nvoid main () { gl_Position = vec4(zzAttr, 1.0); }\n|]\n\n\n" +
      "fs : Shader {} {} {}\nfs =\n    [glsl|\nvoid main () { gl_FragColor = vec4(1.0, 1.0, 1.0, 1.0); }\n|]\n\n\n" +
      "main : Html msg\nmain =\n    WebGL.toHtml [] [ WebGL.entity vs fs (WebGL.points []) {} ]\n";
    const dir = project({ "src/Main.elm": main }, elmJson);
    const r = eco(dir, ["make", "src/Main.elm", "--optimize", "--output=out.js"]);
    assert.strictEqual(r.status, 0, r.out);
    assert.doesNotMatch(r.out, /ShortFieldNames|Eco\.Crash/, r.out);
    assert.match(fs.readFileSync(path.join(dir, "out.js"), "utf8"), /zzAttr: '/);
  });

// Fixed: API.Make (Make.elm:105-106). The API's `diagnostics` with a `path`, and its `make`, ran a full make
// and `crash "No main!"` when the module had no `main`, so the API process died instead of answering with
// JSON. Now `make` answers with the NO MAIN error and `diagnostics` with `{}`: the module compiled, and only
// a page to run needs `main`. API.Main is built here as compiler/scripts/build.sh api builds it, but into a
// temporary directory, and run through a copy of compiler/bin/index.js that starts Elm.API.Main.
function apiRunner() {
  const out = fs.mkdtempSync("/tmp/cli-errors/api-");
  const shadow = path.resolve(__dirname, "../../build/compiler/build-xhr");
  const elm = path.resolve(__dirname, "../../build/toolchain/bin/elm");
  const build = spawnSync(elm, ["make", `--output=${out}/api.js`, path.resolve(__dirname, "../../compiler/src/API/Main.elm")],
    { cwd: shadow, encoding: "utf8", timeout: 600000 });
  assert.strictEqual(build.status, 0, (build.stdout || "") + (build.stderr || ""));
  spawnSync(process.execPath, [path.resolve(__dirname, "../../compiler/scripts/replacements.js"), `${out}/api.js`]);
  const bin = path.resolve(__dirname, "../../compiler/bin");
  fs.writeFileSync(`${out}/run.js`, fs.readFileSync(path.join(bin, "index.js"), "utf8")
    .replace('require("./eco-io-handler")', `require(${JSON.stringify(path.join(bin, "eco-io-handler"))})`)
    .replace('require("mock-xmlhttprequest")',
      `require(${JSON.stringify(path.resolve(__dirname, "../../compiler/node_modules/mock-xmlhttprequest"))})`)
    .replace("Elm.Terminal.Main.init();", "Elm.API.Main.init();"));
  return { js: `${out}/api.js`, run: `${out}/run.js` };
}

// Runs one API request in a project whose src/Foo.elm has no `main`, returning the exit status and output.
function apiRequest(api, request) {
  const dir = project({ "src/Foo.elm": "module Foo exposing (x)\n\n\nx : Int\nx =\n    1\n" });
  const r = spawnSync(process.execPath, [api.run, JSON.stringify(request)],
    { cwd: dir, encoding: "utf8", timeout: 300000, env: { ...process.env, GUIDA_JS_PATH: api.js } });
  return { status: r.status, stdout: r.stdout || "", out: (r.stdout || "") + (r.stderr || "") };
}

test("API diagnostics and make of a module without main answer with JSON, not a crash", () => {
  const api = apiRunner();
  const diag = apiRequest(api, { command: "diagnostics", path: "src/Foo.elm" });
  assert.doesNotMatch(diag.out, /No main!|Eco\.Crash/, diag.out);
  assert.strictEqual(diag.status, 0, diag.out);
  assert.match(diag.stdout, /^\{\}\s*$/m, diag.out);
  const make = apiRequest(api, { command: "make", path: "src/Foo.elm", debug: false, optimize: false, sourcemaps: false });
  assert.doesNotMatch(make.out, /No main!|Eco\.Crash/, make.out);
  assert.strictEqual(make.status, 0, make.out);
  assert.match(make.stdout, /"error"[\s\S]*NO MAIN/, make.out);
});

// Fixed: Compiler.Type.Type.toAnnotation names the members of an unannotated recursive group in turn; its
// getVarNames walk skips the variables an earlier member's walk marked (getVarNamesMark), and those names were
// not reserved in the later member's naming scope. So a variable of the later member's own got a name already
// used by a shared one: with `f x = g x []` and `g x y = f x`, `g : a -> List c -> b` was exported as
// `a -> List a -> b`, and another module's valid `Main.g n [ "s" ]` (n : Int) was rejected with TYPE MISMATCH.
// The shared names (markedVarNames) are now reserved. Stock Elm 0.19.1 crashes on the import (Map.!).
// Unit test: Compiler/Type/TypeTest.elm.
test("a later member of a recursive group keeps its own type variables in the interface", () => {
    const dir = project({
      "src/Main.elm": "module Main exposing (f, g)\n\n\nf x =\n    g x []\n\n\ng x y =\n    f x\n",
      "src/User.elm": "module User exposing (main)\n\nimport Html\nimport Main\n\n\nuse : Int -> String\n" +
        "use n =\n    Main.g n [ \"s\" ]\n\n\nmain =\n    Html.text \"ok\"\n",
    });
    const r = eco(dir, ["make", "src/User.elm", "--output=out.js"]);
    assert.doesNotMatch(r.out, /TYPE MISMATCH|Eco\.Crash/, r.out);
    assert.strictEqual(r.status, 0, r.out);
  });
