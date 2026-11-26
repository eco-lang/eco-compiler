#!/usr/bin/env node
// Runs the Stage 1 compiler: guida.js, built by stock elm and post-processed by
// scripts/post-process-stock-elm.js, which links eco's JavaScript kernels into it
// (plans/stage1-direct-kernel-linking.md). CMake passes its path in GUIDA_JS_PATH; the default is the
// `build` preset's, for ad-hoc invocations from a shell.
const path = require("path");
const guidaPath = process.env.GUIDA_JS_PATH ||
    path.join(__dirname, "../../build/compiler/build-xhr/bin/guida.js");
const { Elm } = require(guidaPath);

Elm.Terminal.Main.init();
