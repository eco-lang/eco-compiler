#!/usr/bin/env node
// post-process-stock-elm.js — turns JavaScript built by stock `elm make` into what eco's own JS backend would
// emit for the same program (plans/stage1-direct-kernel-linking.md, D1). Every stock-Elm build of the
// compiler goes through it: Stage 1 (guida.js), the elm-test bundle (through elm-stock-post-processed.js),
// the coverage builds and the API.Main builds of the CLI tests.
//
//   node compiler/scripts/post-process-stock-elm.js <output.js> [<generated dir>]
//
// Two passes, in the order eco's backend emits their text:
//   1. link (link-stock-elm-kernels.js): the Eco kernels the output reaches, from the stubs listed in
//      <generated dir>/kernels.json (written by make-stage1-kernels.js);
//   2. overrides (apply-overrides.js): the kernel overrides of compiler/kernel-overrides whose kernels are
//      present, which includes the Eco kernels pass 1 linked.
// The generated dir defaults to $ECO_STAGE1_GENERATED, else build/compiler/build-xhr/src-stage1. The file is
// rewritten through <output.js>.tmp only when both passes succeed. Exit status: 0; 1 on a link, override or
// override-file error, with the message on stderr; 2 on bad usage.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { link, LinkError } = require("./link-stock-elm-kernels.js");
const { apply, ApplyError } = require("./apply-overrides.js");
const lib = require("./kernel-overrides-lib.js");

const REPO = path.resolve(__dirname, "../..");
const KERNEL_DIRS = [
    path.join(REPO, "system-kernel-cpp/src/Eco/Kernel"),
    path.join(REPO, "eco-kernel-cpp/src/Eco/Kernel"),
];
const DEFAULT_GENERATED = path.join(REPO, "build/compiler/build-xhr/src-stage1");

// The generated dir to use when none is given.
function defaultGeneratedDir() {
    return process.env.ECO_STAGE1_GENERATED || DEFAULT_GENERATED;
}

// Returns `text` post-processed with the stubs of `generatedDir`. Throws LinkError, ApplyError or
// OverrideError; `kernelDirs` and `overridesDir` exist for tests.
function postProcess(text, generatedDir, kernelDirs = KERNEL_DIRS, overridesDir = lib.DIR) {
    const listing = path.join(generatedDir, "kernels.json");
    if (!fs.existsSync(listing)) throw new LinkError(`no ${listing}; build the guida target, which generates it`);
    const entries = JSON.parse(fs.readFileSync(listing, "utf8"));
    return apply(link(text, entries, kernelDirs), lib.load(overridesDir));
}

// Post-processes the file `file` in place. Returns an exit status, printing any error.
function postProcessFile(file, generatedDir = defaultGeneratedDir()) {
    try {
        const result = postProcess(fs.readFileSync(file, "utf8"), generatedDir);
        const tmp = file + ".tmp";
        fs.writeFileSync(tmp, result);
        fs.renameSync(tmp, file);
        return 0;
    } catch (e) {
        if (e instanceof LinkError || e instanceof ApplyError || e instanceof lib.OverrideError) {
            console.error(`post-process-stock-elm: ${path.basename(file)}: ${e.message}`);
            return 1;
        }
        throw e;
    }
}

function main(argv) {
    if (argv.length < 1 || argv.length > 2) {
        console.error("usage: post-process-stock-elm.js <output.js> [<generated dir>]");
        return 2;
    }
    return postProcessFile(argv[0], argv[1] || defaultGeneratedDir());
}

module.exports = { postProcess, postProcessFile, defaultGeneratedDir, KERNEL_DIRS };

if (require.main === module) process.exit(main(process.argv.slice(2)));
