#!/usr/bin/env node
// make-docs-package.js — build a stock-elm-compatible copy of eco/system for its docs.
//
// Third-party tooling runs the original Elm 0.19.1 (plans/eco-system-library.md D12), which rejects
// kernel imports and `effect module` outside @elm. `elm make --docs` compiles every reachable
// module, so the docs are built from a generated copy (D13) in which:
//   - `effect module X where { ... } exposing` becomes `module X exposing`;
//   - `import Eco.Kernel.*` lines are dropped;
//   - every `Eco.Kernel.<Home>.<fn>` reference in code becomes `(Debug.todo "kernel")`;
//   - in former effect modules, code uses of the built-in `command` / `subscription` functions become
//     `(\_ -> Debug.todo "effect")`.
// The exposed API and its doc comments are untouched, so the generated docs equal the real ones. The rewrite
// itself is stock-elm-rewrite.js, shared with the Stage 1 compiler's copy (compiler/scripts/make-xhr-system.js).
//
// Usage: node scripts/make-docs-package.js [outDir]   (default: .docs-package, next to elm.json)
"use strict";
const fs = require("fs");
const path = require("path");

const pkg = path.resolve(__dirname, "..");
const out = path.resolve(pkg, process.argv[2] || ".docs-package");

const { rewrite: stockRewrite } = require("./stock-elm-rewrite.js");

// Every kernel reference becomes a Debug.todo: docs only need the types.
function rewrite(source) {
    return stockRewrite(source, { kernelRef: () => '(Debug.todo "kernel")' });
}

function copyTree(from, to) {
    fs.mkdirSync(to, { recursive: true });
    for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
        const src = path.join(from, entry.name);
        const dst = path.join(to, entry.name);
        if (entry.isDirectory()) {
            // C++ kernels and JS kernels are not part of the Elm docs build.
            if (entry.name === "eco-system" || (entry.name === "Kernel" && path.basename(from) === "Eco")) continue;
            copyTree(src, dst);
        } else if (entry.name.endsWith(".elm")) {
            fs.writeFileSync(dst, rewrite(fs.readFileSync(src, "utf8")));
        }
    }
}

fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out, { recursive: true });
for (const f of ["elm.json", "README.md", "LICENSE"]) {
    if (fs.existsSync(path.join(pkg, f))) fs.copyFileSync(path.join(pkg, f), path.join(out, f));
}
copyTree(path.join(pkg, "src"), path.join(out, "src"));
console.log(`make-docs-package: wrote ${path.relative(process.cwd(), out) || "."}`);
