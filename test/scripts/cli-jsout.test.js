// Regression tests for JS-output bugs observable through `eco make` (compiler/bin/index.js).
// Every test here is EXPECTED TO FAIL until the bug it names is fixed.
// Run: node --test test/scripts/cli-jsout.test.js
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const ECO = path.resolve(__dirname, "../../compiler/bin/index.js");
const APP_ELM_JSON = path.resolve(__dirname, "../elm/elm.json");

const MAIN = `port module Main exposing (main)

import Platform


port out : String -> Cmd msg


s : String
s =
    "\\u{FFFF}"


main : Program () () ()
main =
    Platform.worker
        { init = \\_ -> ( (), out (String.fromInt (String.length s) ++ " " ++ String.join "," (List.map (Char.toCode >> String.fromInt) (String.toList s))) )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }
`;

// Bug: Compiler.Elm.String writes code point U+FFFF as a (bogus) surrogate pair '퟿\uDFFF' because
// its test is `code < 0xFFFF` instead of `<=`. A user's "\u{FFFF}" literal then has String.length 2 and
// String.toList gives one char 55295. Unit test: compiler/tests/Compiler/Elm/StringTest.elm.
// EXPECTED TO FAIL until fixed.
test("string literal \\u{FFFF} compiles to a one-code-unit JS string", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "eco-cli-jsout-"));
  fs.writeFileSync(path.join(dir, "elm.json"), fs.readFileSync(APP_ELM_JSON, "utf8"));
  fs.mkdirSync(path.join(dir, "src"));
  fs.writeFileSync(path.join(dir, "src/Main.elm"), MAIN);
  const make = spawnSync(process.execPath, [ECO, "make", "src/Main.elm", "--output=o.js"], { cwd: dir, encoding: "utf8", timeout: 300000 });
  assert.strictEqual(make.status, 0, make.stdout + make.stderr);
  fs.writeFileSync(path.join(dir, "run.js"),
    "const {Elm}=require('./o.js'); Elm.Main.init().ports.out.subscribe(x=>console.log(x));\n");
  const run = spawnSync(process.execPath, ["run.js"], { cwd: dir, encoding: "utf8", timeout: 60000 });
  assert.strictEqual(run.stdout.trim(), "1 65535");
});
