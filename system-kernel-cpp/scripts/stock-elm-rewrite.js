// stock-elm-rewrite.js — rewrite eco/system's Elm sources into modules the original Elm 0.19.1 accepts.
//
// Stock Elm rejects two things these sources use: `import Eco.Kernel.*` and `effect module` outside @elm
// (plans/eco-system-library.md D12). Two scripts turn the sources into stock-Elm modules with this one
// rewrite, so that what they produce cannot drift apart:
//   - make-docs-package.js (docs.json, D13): every kernel reference becomes `(Debug.todo "kernel")`;
//   - compiler/scripts/make-stage1-kernels.js (every stock-Elm build of the compiler,
//     plans/stage1-direct-kernel-linking.md §6): every kernel reference becomes a stub that
//     post-process-stock-elm.js later replaces with the real kernel.
//
// The rewrite:
//   - `effect module X where { ... } exposing` becomes `module X exposing`;
//   - `import Eco.Kernel.*` lines are dropped, and the caller's extra imports (if any) are added after the
//     module's last import;
//   - every `Eco.Kernel.<Home>.<fn>` reference in code becomes `kernelRef(home, fn)`;
//   - in former effect modules, code uses of the built-in `command` / `subscription` functions become
//     `(\_ -> Debug.todo "effect")`.
// Comments and string literals are left alone: doc comments mention `command` and `Eco.Kernel.*` in prose.
"use strict";

// Splits Elm source into code and non-code (comments, string and char literals) segments.
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

// Rewrites one code segment: kernel references, and in a former effect module the uses of `command` and
// `subscription`.
function rewriteCode(code, effect, kernelRef) {
    let s = code.replace(/\bEco\.Kernel\.([A-Z]\w*)\.([a-z]\w*)/g, (_, home, fn) => kernelRef(home, fn));
    if (effect) {
        // A use, not a definition (`command =` / `command :`), record field (`.command`,
        // `{ command =`) or the effect-module header (already rewritten).
        s = s.replace(/(^|[^.\w])(command|subscription)\b(?!\s*[=:])/gm,
            (m, pre) => `${pre}(\\_ -> Debug.todo "effect")`);
    }
    return s;
}

// The kernel homes (`Stream`, `FileSystem`, ...) the source refers to in code, in order of first use.
function kernelHomes(source) {
    const homes = [];
    for (const seg of segments(source)) {
        if (!seg.code) continue;
        for (const m of seg.text.matchAll(/\bEco\.Kernel\.([A-Z]\w*)\.[a-z]\w*/g)) {
            if (!homes.includes(m[1])) homes.push(m[1]);
        }
    }
    return homes;
}

// Returns the stock-Elm version of `source`.
//   options.kernelRef(home, fn) -> string   what a kernel reference becomes
//   options.extraImports(homes) -> string[] import lines to add, given the kernel homes the module uses
//                                           (default: none)
function rewrite(source, options) {
    const kernelRef = options.kernelRef;
    const homes = kernelHomes(source);
    let effect = false;
    let s = source.replace(
        /^effect\s+module\s+([A-Z][\w.]*)\s+where\s*\{[^}]*\}\s*exposing/m,
        (_, name) => { effect = true; return `module ${name} exposing`; });
    s = s.replace(/^import\s+Eco\.Kernel\.[\w.]*.*\n/gm, "");
    const extra = options.extraImports ? options.extraImports(homes) : [];
    if (extra.length > 0) {
        const imports = [...s.matchAll(/^import\s.*$/gm)];
        const at = imports.length > 0
            ? imports[imports.length - 1].index + imports[imports.length - 1][0].length + 1
            : s.search(/^[a-z]/m);
        s = s.slice(0, at) + extra.map((l) => l + "\n").join("") + s.slice(at);
    }
    return segments(s).map((seg) => (seg.code ? rewriteCode(seg.text, effect, kernelRef) : seg.text)).join("");
}

module.exports = { rewrite, kernelHomes, segments };
