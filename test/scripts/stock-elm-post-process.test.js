// compiler/scripts/post-process-stock-elm.js on small synthetic stock-Elm outputs
// (plans/stage1-direct-kernel-linking.md §5): the link pass (link-stock-elm-kernels.js), then the
// kernel-override pass (apply-overrides.js), with temporary kernel and override directories.
//
// Run: node --test test/scripts/stock-elm-post-process.test.js   (target run-js-kernel-override-tests)
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");

const { postProcess } = require("../../compiler/scripts/post-process-stock-elm.js");
const { LinkError } = require("../../compiler/scripts/link-stock-elm-kernels.js");

function tmp(tag) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `eco-post-process-${tag}-`));
}

// A kernel directory holding `files` ({ "Foo.js": text }).
function kernelDir(files) {
  const dir = tmp("kernels");
  for (const [name, text] of Object.entries(files)) fs.writeFileSync(path.join(dir, name), text);
  return dir;
}

// A generated directory whose kernels.json lists `entries`.
function generated(entries) {
  const dir = tmp("generated");
  fs.writeFileSync(path.join(dir, "kernels.json"), JSON.stringify(entries));
  return dir;
}

// An override directory holding `files`, or an empty one.
function overrides(files = {}) {
  const dir = tmp("overrides");
  for (const [name, text] of Object.entries(files)) fs.writeFileSync(path.join(dir, name), text);
  return dir;
}

// A stock-Elm-like output: kernel code `kernel` (lines), then the stub of $author$project$M$kGo for Foo.go,
// then `elm` (lines).
function output(kernel, elm = []) {
  return [
    "(function(scope){",
    "'use strict';",
    ...kernel,
    "var $author$project$M$kGo = _Debug_todo('M', {start: {line: 1, column: 1}, end: {line: 1, column: 2}})('ECO_STAGE1_KERNEL_STUB Foo.go');",
    "var $author$project$M$main = $author$project$M$kGo;",
    ...elm,
    "}(this));",
    "",
  ].join("\n");
}

const STUB_ENTRY = { global: "$author$project$M$kGo", package: "eco/test", home: "Foo", fn: "go" };

test("an Eco.Kernel import with no kernel file is elm/core's, and is not linked", () => {
  const kernels = kernelDir({
    "Foo.js": "/*\nimport Eco.Kernel.Scheduler exposing (binding)\n*/\n\nvar _Foo_go = __Scheduler_binding;\n",
  });
  const out = postProcess(output(["var _Scheduler_binding = 1;"]), generated([STUB_ENTRY]), [kernels], overrides());
  assert.match(out, /^var _Eco_Foo_go = _Scheduler_binding;$/m);
  assert.match(out, /^var \$author\$project\$M\$kGo = _Eco_Foo_go;$/m);
  assert.doesNotMatch(out, /_Eco_Scheduler_/);
});

test("a kernel importing elm/core's Array gets $elm$core$Array names", () => {
  const kernels = kernelDir({ "Foo.js": "/*\nimport Array exposing (foldl)\n*/\n\nvar _Foo_go = __Array_foldl;\n" });
  const out = postProcess(output([]), generated([STUB_ENTRY]), [kernels], overrides());
  assert.match(out, /^var _Eco_Foo_go = \$elm\$core\$Array\$foldl;$/m);
});

test("a kernel importing an elm/core kernel name the output does not define is refused", () => {
  const kernels = kernelDir({
    "Foo.js": "/*\nimport Elm.Kernel.Utils exposing (Tuple3)\n*/\n\nvar _Foo_go = __Utils_Tuple3;\n",
  });
  assert.throws(() => postProcess(output([]), generated([STUB_ENTRY]), [kernels], overrides()),
    (e) => e instanceof LinkError && /_Utils_Tuple3/.test(e.message));
});

test("the stub token inside a longer string is not a stub; a stub nobody lists is refused", () => {
  const kernels = kernelDir({ "Foo.js": "/*\n*/\n\nvar _Foo_go = 1;\n" });
  const mentioned = output([], ["var $author$project$T$name = 'a test of ECO_STAGE1_KERNEL_STUB text';"]);
  assert.match(postProcess(mentioned, generated([STUB_ENTRY]), [kernels], overrides()), /_Eco_Foo_go = 1/);
  assert.throws(() => postProcess(output([]), generated([]), [kernels], overrides()),
    (e) => e instanceof LinkError && /still holds a kernel stub/.test(e.message));
});

test("an override that requires a kernel only the link pass adds is applied", () => {
  const kernels = kernelDir({ "Foo.js": "/*\n*/\n\nvar _Foo_go = 1;\n" });
  const over = overrides({
    "FooOverride.js":
      "/*\nkind kernel\nrequires Eco.Kernel.Foo\npackage elm/core 1.0.5\n*/\n_Eco_Foo_go = 2;\n",
  });
  const out = postProcess(output([]), generated([STUB_ENTRY]), [kernels], over);
  const lines = out.split("\n");
  const marker = lines.indexOf("// KERNEL OVERRIDES (compiler/kernel-overrides)");
  assert.ok(marker > lines.indexOf("var _Eco_Foo_go = 1;"), "the override must follow the linked kernel:\n" + out);
  assert.strictEqual(lines[marker + 1], "_Eco_Foo_go = 2;");
});

test("a second run is refused", () => {
  const kernels = kernelDir({ "Foo.js": "/*\n*/\n\nvar _Foo_go = 1;\n" });
  const once = postProcess(output([]), generated([STUB_ENTRY]), [kernels], overrides());
  assert.throws(() => postProcess(once, generated([STUB_ENTRY]), [kernels], overrides()),
    (e) => e instanceof LinkError && /already linked/.test(e.message));
});

test("a kernel home in two kernel directories is refused", () => {
  const a = kernelDir({ "Foo.js": "/*\n*/\n\nvar _Foo_go = 1;\n" });
  const b = kernelDir({ "Foo.js": "/*\n*/\n\nvar _Foo_go = 2;\n" });
  assert.throws(() => postProcess(output([]), generated([STUB_ENTRY]), [a, b], overrides()),
    (e) => e instanceof LinkError && /two kernel directories/.test(e.message));
});
