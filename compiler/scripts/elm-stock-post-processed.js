#!/usr/bin/env node
// elm-stock-post-processed.js — stands in for `elm` wherever a tool runs stock `elm make` on the compiler
// for us (plans/stage1-direct-kernel-linking.md, D2): elm-test-rs through `--compiler` (the elm-tests
// target), and elm-coverage's fake-elm through `elm` on PATH (scripts/coverage/cov.py). It runs the real
// elm with every argument, and after a successful `make --output=<file>` post-processes <file> with
// post-process-stock-elm.js, so the bundle gets the Eco kernels and kernel overrides that Stage 1 gets.
//
// Launchers: elm-stock-post-processed (sh) and elm-stock-post-processed.cmd (Windows).
//
//   ECO_STOCK_ELM         the real elm; default <repo>/build/toolchain/bin/elm (elm.exe on Windows). Never
//                         looked up on PATH, where this wrapper itself may be the `elm`.
//   ECO_STAGE1_GENERATED  the generated stub directory; default build/compiler/build-xhr/src-stage1.
//
// Exit status: elm's when elm fails; 1 when post-processing fails; 2 when the real elm is missing; else 0.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { postProcessFile, defaultGeneratedDir } = require("./post-process-stock-elm.js");

const REPO = path.resolve(__dirname, "../..");

function realElm() {
    if (process.env.ECO_STOCK_ELM) return process.env.ECO_STOCK_ELM;
    return path.join(REPO, "build/toolchain/bin", process.platform === "win32" ? "elm.exe" : "elm");
}

// The file a `make` writes, or null when there is none to post-process.
function makeOutput(args) {
    if (args[0] !== "make") return null;
    const opt = args.find((a) => a.startsWith("--output="));
    if (!opt) return null;
    const file = opt.slice("--output=".length);
    if (file === "/dev/null" || file.toUpperCase() === "NUL") return null;
    return file;
}

function main(args) {
    const elm = realElm();
    if (!fs.existsSync(elm)) {
        console.error(`elm-stock-post-processed: no elm at ${elm}; set ECO_STOCK_ELM to the stock elm binary`);
        return 2;
    }
    const r = spawnSync(elm, args, { stdio: "inherit" });
    if (r.error) {
        console.error(`elm-stock-post-processed: cannot run ${elm}: ${r.error.message}`);
        return 1;
    }
    if (r.status !== 0) return r.status === null ? 1 : r.status;
    const out = makeOutput(args);
    if (out === null || !fs.existsSync(out)) return 0;
    return postProcessFile(out, defaultGeneratedDir());
}

process.exit(main(process.argv.slice(2)));
