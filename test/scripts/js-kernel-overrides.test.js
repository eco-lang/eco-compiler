// JS kernel overrides (plans/js-kernel-overrides.md): what eco's JavaScript backend emits between the
// kernel code and the Elm code, and the source-map offset that must count it.
//
// The programs are compiled with the Stage 1 compiler (compiler/bin/index.js running guida.js) in a
// private ECO_HOME, as cli-sourcemap-sources.test.js does, because `eco make --sourcemaps` needs an
// `st.src` link in each package.
//
// Run: node --test test/scripts/js-kernel-overrides.test.js   (target run-js-kernel-override-tests)
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const REPO = path.resolve(__dirname, "../..");
const ECO = path.join(REPO, "compiler/bin/index.js");
const ELM_JSON = {
  type: "application",
  "source-directories": ["src"],
  "elm-version": "0.19.1",
  dependencies: {
    direct: { "elm/bytes": "1.0.8", "elm/core": "1.0.5", "elm/html": "1.0.0", "elm/json": "1.1.3" },
    indirect: { "elm/virtual-dom": "1.0.3" },
  },
  "test-dependencies": { direct: {}, indirect: {} },
};

// A private eco home with the dependencies copied from the real one, each with an `st.src` link.
function privateEcoHome() {
  const realHome = process.env.ECO_HOME || path.join(os.homedir(), ".eco");
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "eco-ko-home-"));
  const deps = Object.assign({}, ELM_JSON.dependencies.direct, ELM_JSON.dependencies.indirect);
  for (const ver of fs.readdirSync(realHome)) {
    const pkgs = path.join(realHome, ver, "packages");
    if (!fs.existsSync(pkgs)) continue;
    for (const [name, version] of Object.entries(deps)) {
      const src = path.join(pkgs, name, version);
      if (!fs.existsSync(src)) continue;
      const dst = path.join(home, ver, "packages", name, version);
      fs.mkdirSync(path.dirname(dst), { recursive: true });
      fs.cpSync(src, dst, { recursive: true });
      fs.symlinkSync("src", path.join(dst, "st.src"));
    }
  }
  return home;
}

let ecoHome = null;

// Compiles `main` (the text of src/Main.elm) and returns the generated JavaScript.
function compile(main, extraArgs = []) {
  if (ecoHome === null) ecoHome = privateEcoHome();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "eco-ko-"));
  fs.writeFileSync(path.join(dir, "elm.json"), JSON.stringify(ELM_JSON, null, 4));
  fs.mkdirSync(path.join(dir, "src"));
  fs.writeFileSync(path.join(dir, "src/Main.elm"), main);
  const env = Object.assign({}, process.env, { ECO_HOME: ecoHome });
  const make = spawnSync(process.execPath, [ECO, "make", "src/Main.elm", "--output=o.js", ...extraArgs],
    { cwd: dir, env, encoding: "utf8", timeout: 300000 });
  assert.strictEqual(make.status, 0, make.stdout + make.stderr);
  return fs.readFileSync(path.join(dir, "o.js"), "utf8");
}

// Decodes a source map's `mappings` into [generatedLine (1-based), sourceIndex, sourceLine (1-based)].
function decodeMappings(map) {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const vlq = (s) => {
    const out = [];
    let v = 0;
    let shift = 0;
    for (const c of s) {
      let d = chars.indexOf(c);
      const more = d & 32;
      d &= 31;
      v += d << shift;
      if (more) shift += 5;
      else {
        out.push(v & 1 ? -(v >> 1) : v >> 1);
        v = 0;
        shift = 0;
      }
    }
    return out;
  };
  const result = [];
  let src = 0;
  let line = 0;
  map.mappings.split(";").forEach((segments, gen) => {
    if (!segments) return;
    for (const seg of segments.split(",")) {
      const d = vlq(seg);
      if (d.length >= 4) {
        src += d[1];
        line += d[2];
        result.push([gen + 1, src, line + 1]);
      }
    }
  });
  return result;
}

const SOURCE_MAP_MAIN = `module Main exposing (main)

import Html exposing (text)


markerValue : Int -> Int
markerValue n =
    n * 7919


main =
    text (String.fromInt (markerValue 3))
`;

test("source map points an Elm line at the generated line that holds it", () => {
  const js = compile(SOURCE_MAP_MAIN, ["--sourcemaps"]);
  const lines = js.split("\n");
  const generated = lines.findIndex((l) => l.includes("7919")) + 1;
  assert.ok(generated > 0, "the marker expression is not in the output");
  const m = js.match(/sourceMappingURL=data:application\/json;base64,(\S+)/);
  assert.ok(m, "no inline source map");
  const map = JSON.parse(Buffer.from(m[1], "base64").toString("utf8"));
  const main = map.sources.findIndex((s) => /Main/.test(s));
  assert.ok(main >= 0, "no Main source in " + JSON.stringify(map.sources));
  // Main.elm line 8 is `n * 7919`.
  const mapped = decodeMappings(map).filter(([, s, l]) => s === main && l === 8).map(([g]) => g);
  assert.ok(mapped.length > 0, "Main.elm line 8 has no mapping");
  assert.deepStrictEqual([...new Set(mapped)], [generated],
    "Main.elm line 8 maps to generated line(s) " + [...new Set(mapped)].join(",") + ", but it is on line " + generated);
});

const MARKER = require("../../compiler/scripts/kernel-overrides-lib.js").MARKER;

// Runs the compiled program `js` in this process and returns its `Elm` object.
function load(js) {
  const scope = {};
  new Function(js).call(scope);
  return scope.Elm;
}

const count = (text, needle) => text.split(needle).length - 1;

// A worker with Bytes ports both ways: it sends `héllo €` out as Bytes, and decodes the Bytes it
// receives as a String, which it sends back. Out uses _Json_encodeBytes, in uses _Json_decodeBytes
// (BytesForPorts.js), and decoding uses the rebound _Bytes_read_string (BytesReadString.js).
const PORTS_MAIN = `port module Main exposing (main)

import Bytes exposing (Bytes)
import Bytes.Decode as Decode
import Bytes.Encode as Encode


port bytesOut : Bytes -> Cmd msg


port stringOut : String -> Cmd msg


port bytesIn : (Bytes -> msg) -> Sub msg


main : Program () () Bytes
main =
    Platform.worker
        { init = \\_ -> ( (), bytesOut (Encode.encode (Encode.string "h\u{00E9}llo \u{20AC}")) )
        , update =
            \\bytes model ->
                ( model
                , stringOut
                    (Decode.decode (Decode.string (Bytes.width bytes)) bytes |> Maybe.withDefault "<none>")
                )
        , subscriptions = \\_ -> bytesIn identity
        }
`;

test("a program using the Bytes and Json kernels gets both overrides once, and they work", async () => {
  const js = compile(PORTS_MAIN);
  assert.strictEqual(count(js, MARKER), 1, "the override marker must appear once");
  assert.strictEqual(count(js, "\n_Bytes_read_string = F3("), 1, "BytesReadString.js must be emitted once");
  assert.strictEqual(count(js, "\nvar _Json_decodeBytes = "), 1, "BytesForPorts.js must be emitted once");
  // Every kernel definition comes before the marker, every Elm definition after it.
  const at = js.indexOf(MARKER);
  assert.ok(js.indexOf("\nvar _Bytes_read_string = ") < at, "the stock definition precedes the override");
  assert.ok(js.indexOf("\nvar $") > at, "no Elm definition precedes the override section");

  const app = load(js).Main.init();
  const out = await new Promise((resolve) => app.ports.bytesOut.subscribe(resolve));
  assert.ok(out instanceof Uint8Array, "a Bytes port gives a Uint8Array");
  assert.strictEqual(Buffer.from(out).toString("utf8"), "h\u00e9llo \u20ac");
  const back = new Promise((resolve) => app.ports.stringOut.subscribe(resolve));
  app.ports.bytesIn.send(new Uint8Array(Buffer.from("a\u00e9\u20ac\ud834\udd1e", "utf8")));
  assert.strictEqual(await back, "a\u00e9\u20ac\ud834\udd1e", "the rebound _Bytes_read_string decodes 1- to 4-byte UTF-8");
});

const NO_BYTES_MAIN = `module Main exposing (main)


main : Program () () ()
main =
    Platform.worker
        { init = \\_ -> ( (), Cmd.none )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
`;

test("a program without the Bytes kernel gets no _Bytes_read_string override", () => {
  const js = compile(NO_BYTES_MAIN);
  assert.strictEqual(count(js, "_Bytes_read_string"), 0, "no Bytes kernel, so no Bytes override");
  assert.strictEqual(count(js, "\nvar _Json_decodeBytes = "), 1, "the Json kernel is in every program, so BytesForPorts.js is");
  load(js).Main.init();
});

// ====== apply-overrides.js on small synthetic stock-Elm outputs ======

const lib = require("../../compiler/scripts/kernel-overrides-lib.js");
const { apply, ApplyError } = require("../../compiler/scripts/apply-overrides.js");

const KERNEL = lib.parse("K.js", "/*\nkind kernel\nrequires Elm.Kernel.Foo\npackage elm/core 1.0.5\n*/\n_Foo_f = 2;\n");
const NEEDS_BAR = lib.parse("N.js", "/*\nkind kernel\nrequires Elm.Kernel.Bar\npackage elm/core 1.0.5\n*/\n_Bar_g = 3;\n");
const value = (name, group = "g") =>
  lib.parse(name + ".js", `/*\nkind value\nvalue $author$project$M$${name}\ngroup ${group}\n*/\nvar $author$project$M$${name} = 'new ${name}';\n`);

const STOCK = [
  "(function(scope){",
  "'use strict';",
  "var _Foo_f = 1;",
  "function _Foo_h(x) { return x; }",
  "var $author$project$M$a = function (x) {",
  "\treturn x;",
  "};",
  "var $author$project$M$b = 'old b';",
  "var $author$project$M$main = 0;",
  "}(this));",
].join("\n");

test("apply-overrides inserts kernel overrides at the boundary and replaces a value group", () => {
  const out = apply(STOCK, [KERNEL, NEEDS_BAR, value("a"), value("b")]).split("\n");
  const marker = out.indexOf(lib.MARKER.trimEnd());
  assert.ok(marker > out.indexOf("function _Foo_h(x) { return x; }"), "after the kernel code");
  assert.strictEqual(out[marker + 1], "_Foo_f = 2;");
  assert.ok(out[marker + 2].startsWith("var $"), "right before the first Elm definition");
  assert.ok(!out.includes("_Bar_g = 3;"), "an override whose kernel is absent is left out");
  assert.ok(out.includes("var $author$project$M$a = 'new a';") && !out.includes("\treturn x;"), "a is replaced whole");
  assert.ok(out.includes("var $author$project$M$b = 'new b';") && !out.includes("var $author$project$M$b = 'old b';"));
});

test("apply-overrides leaves a value group whose definitions are all absent", () => {
  const out = apply(STOCK, [value("x", "other"), value("y", "other")]);
  assert.ok(!out.includes("'new x'") && !out.includes(lib.MARKER), "nothing to apply");
});

const rejects = (name, text, overrides, pattern) =>
  test("apply-overrides refuses " + name, () => {
    assert.throws(() => apply(text, overrides), (e) => e instanceof ApplyError && pattern.test(e.message));
  });

rejects("a second run", apply(STOCK, [KERNEL]), [KERNEL], /already applied/);
rejects("an output without a boundary", STOCK.replace(/var \$/g, "var x"), [KERNEL], /no kernel\/Elm boundary/);
rejects("an assignment to a name no kernel defines",
  STOCK, [lib.parse("U.js", "/*\nkind kernel\nrequires Elm.Kernel.Foo\npackage elm/core 1.0.5\n*/\n_Foo_missing = 1;\n")],
  /assigns _Foo_missing/);
rejects("a value group with a member missing", STOCK, [value("a"), value("zzz")], /only some definitions.*zzz/);
rejects("a value defined twice", STOCK + "\nvar $author$project$M$b = 'again';\nvar $end = 1;", [value("b")], /defined 2 times/);
rejects("a definition that runs into another statement",
  STOCK.replace("var $author$project$M$b = 'old b';", "var $author$project$M$b = 'old b';\nconsole.log(1);"),
  [value("b")], /runs into another statement/);

test("an override file that breaks the header grammar is refused", () => {
  assert.throws(() => lib.parse("Bad.js", "/*\nkind kernel\nrequire Elm.Kernel.Foo\n*/\nx;\n"),
    (e) => e instanceof lib.OverrideError && /Bad\.js:3: unknown directive `require`/.test(e.message));
  assert.throws(() => lib.parse("NoVar.js", "/*\nkind value\nvalue $a$b\ngroup g\n*/\n$a$b = 1;\n"),
    (e) => e instanceof lib.OverrideError && /must define `var \$a\$b = \.\.\.`/.test(e.message));
});

module.exports = { compile, decodeMappings };
