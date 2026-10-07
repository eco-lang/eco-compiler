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
// The exposed API and its doc comments are untouched, so the generated docs equal the real ones.
//
// Usage: node scripts/make-docs-package.js [outDir]   (default: .docs-package, next to elm.json)
"use strict";
const fs = require("fs");
const path = require("path");

const pkg = path.resolve(__dirname, "..");
const out = path.resolve(pkg, process.argv[2] || ".docs-package");

// Split Elm source into code and non-code (comments, string and char literals) segments, so the
// rewrites below only touch code: doc comments mention `command` and `Eco.Kernel.*` in prose.
function segments(source) {
    const out = [];
    let code = "";
    let i = 0;
    const n = source.length;
    const flush = () => { if (code) { out.push({ code: true, text: code }); code = ""; } };
    while (i < n) {
        const start = i;
        if (source.startsWith("{-", i)) {
            let depth = 0;
            while (i < n) {
                if (source.startsWith("{-", i)) { depth++; i += 2; }
                else if (source.startsWith("-}", i)) { depth--; i += 2; if (depth === 0) break; }
                else i++;
            }
        } else if (source.startsWith("--", i)) {
            while (i < n && source[i] !== "\n") i++;
        } else if (source.startsWith('"""', i)) {
            i += 3;
            while (i < n && !source.startsWith('"""', i)) i += source[i] === "\\" ? 2 : 1;
            i += 3;
        } else if (source[i] === '"') {
            i++;
            while (i < n && source[i] !== '"' && source[i] !== "\n") i += source[i] === "\\" ? 2 : 1;
            i++;
        } else if (source[i] === "'") {
            i++;
            while (i < n && source[i] !== "'" && source[i] !== "\n") i += source[i] === "\\" ? 2 : 1;
            i++;
        } else {
            code += source[i++];
            continue;
        }
        flush();
        out.push({ code: false, text: source.slice(start, Math.min(i, n)) });
    }
    flush();
    return out;
}

function rewriteCode(code, effect) {
    let s = code.replace(/\bEco\.Kernel\.[A-Z]\w*\.[a-z]\w*/g, '(Debug.todo "kernel")');
    if (effect) {
        // A use, not a definition (`command =` / `command :`), record field (`.command`,
        // `{ command =`) or the effect-module header (already rewritten).
        s = s.replace(/(^|[^.\w])(command|subscription)\b(?!\s*[=:])/gm,
            (m, pre) => `${pre}(\\_ -> Debug.todo "effect")`);
    }
    return s;
}

function rewrite(source) {
    let effect = false;
    let s = source.replace(
        /^effect\s+module\s+([A-Z][\w.]*)\s+where\s*\{[^}]*\}\s*exposing/m,
        (_, name) => { effect = true; return `module ${name} exposing`; });
    s = s.replace(/^import\s+Eco\.Kernel\.[\w.]*.*\n/gm, "");
    return segments(s).map(seg => seg.code ? rewriteCode(seg.text, effect) : seg.text).join("");
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
