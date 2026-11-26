// compiler/scripts/make-stage1-kernels.js on small temporary packages (plans/stage1-direct-kernel-linking.md
// §6): which modules it copies, and how each kernel reference becomes a listed stub.
//
// Run: node --test test/scripts/stage1-kernels-generator.test.js   (target run-js-kernel-override-tests)
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");

const { generate, GenerateError } = require("../../compiler/scripts/make-stage1-kernels.js");

function tmp(tag) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `eco-stage1-gen-${tag}-`));
}

// A directory holding `files` ({ "A/B.elm": text }).
function tree(tag, files) {
  const dir = tmp(tag);
  for (const [rel, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), text);
  }
  return dir;
}

// Runs the generator with one scanned source importing `imports`, packages `pkgs` ({ name: files }) and
// project source directories `projectDirs`; returns { out, entries }.
function run(imports, pkgs, projectDirs = []) {
  const scan = tree("scan", { "Main.elm": "module Main exposing (main)\n\n" + imports.map((i) => `import ${i}\n`).join("") });
  const packages = Object.entries(pkgs).map(([name, files]) => ({ name, src: tree("pkg", files) }));
  const out = tmp("out");
  const entries = generate({ packages, projectSourceDirs: projectDirs, scanDirs: [scan], outDir: out });
  return { out, entries };
}

const WRAPPED = "module Lib exposing (go)\n\nimport Eco.Kernel.Foo\n\n\ngo : Int -> Int\ngo =\n    Eco.Kernel.Foo.go\n";
const INLINE =
  "module Eco.Lib exposing (a, b)\n\nimport Eco.Kernel.Foo\n\n\na : Int -> Int\na x =\n    Eco.Kernel.Foo.go x\n\n\n" +
  "b : Int -> Int\nb x =\n    Eco.Kernel.Foo.go (x + 1)\n";

test("a kernel reference that is a whole definition body is listed under that definition, any name", () => {
  const { out, entries } = run(["Lib"], { "eco/system": { "Lib.elm": WRAPPED } });
  assert.deepStrictEqual(entries, [{ global: "$author$project$Lib$go", package: "eco/system", home: "Foo", fn: "go" }]);
  const text = fs.readFileSync(path.join(out, "Lib.elm"), "utf8");
  assert.match(text, /^go =\n {4}\(Debug\.todo "ECO_STAGE1_KERNEL_STUB Foo\.go"\)$/m);
  assert.doesNotMatch(text, /import Eco\.Kernel/);
});

test("an inline kernel reference becomes one lifted stub, defined once and listed", () => {
  const { out, entries } = run(["Eco.Lib"], { "eco/kernel": { "Eco/Lib.elm": INLINE } });
  assert.deepStrictEqual(entries, [
    { global: "$author$project$Eco$Lib$ecoKernelStubFooGo", package: "eco/kernel", home: "Foo", fn: "go" },
  ]);
  const text = fs.readFileSync(path.join(out, "Eco/Lib.elm"), "utf8");
  assert.match(text, /^ {4}ecoKernelStubFooGo x$/m);
  assert.match(text, /^ {4}ecoKernelStubFooGo \(x \+ 1\)$/m);
  assert.strictEqual(text.match(/^ecoKernelStubFooGo =$/gm).length, 1);
  assert.match(text, /^ecoKernelStubFooGo =\n {4}Debug\.todo "ECO_STAGE1_KERNEL_STUB Foo\.go"\n$/m);
});

test("a reference whose definition body goes on after it is lifted, not taken for the whole body", () => {
  const piped = "module Lib exposing (go, last)\n\nimport Eco.Kernel.Foo\n\n\ngo : Int\ngo =\n    Eco.Kernel.Foo.go\n        |> negate\n\n\n" +
    "last : Int\nlast =\n    Eco.Kernel.Foo.last\n";
  const { out, entries } = run(["Lib"], { "eco/system": { "Lib.elm": piped } });
  assert.deepStrictEqual(entries, [
    { global: "$author$project$Lib$ecoKernelStubFooGo", package: "eco/system", home: "Foo", fn: "go" },
    { global: "$author$project$Lib$last", package: "eco/system", home: "Foo", fn: "last" },
  ]);
  assert.match(fs.readFileSync(path.join(out, "Lib.elm"), "utf8"), /^go =\n {4}ecoKernelStubFooGo\n {8}\|> negate$/m);
});

test("a module a project source directory defines is not generated", () => {
  const project = tree("project", { "Eco/Lib.elm": "module Eco.Lib exposing (a)\n\n\na =\n    1\n" });
  const { out, entries } = run(["Eco.Lib"], { "eco/kernel": { "Eco/Lib.elm": INLINE } }, [project]);
  assert.deepStrictEqual(entries, []);
  assert.ok(!fs.existsSync(path.join(out, "Eco/Lib.elm")));
});

test("a module in two packages is refused", () => {
  assert.throws(() => run(["Lib"], { "eco/system": { "Lib.elm": WRAPPED }, "eco/kernel": { "Lib.elm": WRAPPED } }),
    (e) => e instanceof GenerateError && /two packages/.test(e.message));
});

test("a lifted stub name the module already defines is refused", () => {
  const clash = INLINE + "\n\necoKernelStubFooGo : Int\necoKernelStubFooGo =\n    0\n";
  assert.throws(() => run(["Eco.Lib"], { "eco/kernel": { "Eco/Lib.elm": clash } }),
    (e) => e instanceof GenerateError && /already defined/.test(e.message));
});
