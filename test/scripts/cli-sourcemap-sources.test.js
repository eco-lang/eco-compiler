// Source map `sources` drop the package of each module (eco make --sourcemaps).
//
// Compiler.Generate.JavaScript.SourceMap.mappingsToJson writes each source as the
// bare module name of its ModuleName.Canonical. An application module named
// `Elm.JsArray` and elm/core's internal `Elm.JsArray` are two different modules,
// but the source map lists both as "Elm.JsArray", so a consumer that keys
// sources by name (every browser devtools does) merges them and shows one
// file's text for the other's mappings. The two sources must have distinct names.
//
// `eco make --sourcemaps` currently also crashes for every project, because
// Builder.Elm.Outline.getAllModulePaths looks for each package's modules under
// `<pkg>/st.src` instead of `<pkg>/src` (recomment-bugs-triage.tsv, TOOL row).
// So that this test reaches the source map, it runs with a private ECO_HOME
// holding copies of the needed packages plus an `st.src -> src` link in each;
// the link is harmless once that bug is fixed.
//
// Run: node --test test/scripts/cli-sourcemap-sources.test.js
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const ECO = path.resolve(__dirname, "../../compiler/bin/index.js");
const APP_ELM_JSON = path.resolve(__dirname, "../elm/elm.json");

const MAIN = `module Main exposing (main)

import Array
import Elm.JsArray
import Html exposing (text)


main =
    text (String.fromInt (Elm.JsArray.mine (Array.length (Array.fromList [ 1, 2 ]))))
`;

const LOCAL_JSARRAY = `module Elm.JsArray exposing (mine)


mine : Int -> Int
mine n =
    n + 1
`;

// A private eco home with the application's dependencies copied from the real
// one, each with an `st.src` link to its `src`.
function privateEcoHome(elmJson) {
  const realHome = process.env.ECO_HOME || path.join(os.homedir(), ".eco");
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "eco-sm-home-"));
  const deps = Object.assign({}, elmJson.dependencies.direct, elmJson.dependencies.indirect);
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

test("source map gives a local module and a same-named package module distinct sources", () => {
  const elmJson = JSON.parse(fs.readFileSync(APP_ELM_JSON, "utf8"));
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "eco-cli-sm-"));
  fs.writeFileSync(path.join(dir, "elm.json"), JSON.stringify(elmJson, null, 4));
  fs.mkdirSync(path.join(dir, "src/Elm"), { recursive: true });
  fs.writeFileSync(path.join(dir, "src/Main.elm"), MAIN);
  fs.writeFileSync(path.join(dir, "src/Elm/JsArray.elm"), LOCAL_JSARRAY);
  const env = Object.assign({}, process.env, { ECO_HOME: privateEcoHome(elmJson) });
  const make = spawnSync(process.execPath, [ECO, "make", "src/Main.elm", "--sourcemaps", "--output=o.js"],
    { cwd: dir, env, encoding: "utf8", timeout: 300000 });
  assert.strictEqual(make.status, 0, make.stdout + make.stderr);
  const js = fs.readFileSync(path.join(dir, "o.js"), "utf8");
  const m = js.match(/sourceMappingURL=data:application\/json;base64,(\S+)/);
  assert.ok(m, "no inline source map");
  const sm = JSON.parse(Buffer.from(m[1], "base64").toString("utf8"));
  const named = sm.sources.filter((s) => /(^|[\/:])Elm\.JsArray$|Elm\/JsArray\.elm$/.test(s));
  assert.strictEqual(named.length, 2, "expected two Elm.JsArray sources, got " + JSON.stringify(sm.sources));
  assert.notStrictEqual(named[0], named[1], "two different modules share one source name: " + JSON.stringify(sm.sources));
});
