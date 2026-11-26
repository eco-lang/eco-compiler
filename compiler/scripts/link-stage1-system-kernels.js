#!/usr/bin/env node
// link-stage1-system-kernels.js — links eco/system's JavaScript kernels into the Stage 1 compiler
// (plans/compiler-io-on-eco-system.md §5).
//
//   node compiler/scripts/link-stage1-system-kernels.js <output.js> <stage1 system dir>
//
// Stage 1 (guida.js) is built by stock `elm make` from the eco/system modules make-stage1-system.js
// generates, whose kernel wrappers (`kRead = Eco.Kernel.Stream.read`) are `Debug.todo` stubs listed in
// <stage1 system dir>/kernels.json. This script, run after apply-overrides.js:
//   1. replaces the compiled definition of each listed wrapper the output still holds (stock Elm drops
//      unused definitions) with `var <wrapper> = _Eco_<Home>_<fn>;`, as eco's own JS backend emits it;
//   2. emits, just before the first Elm definition, the kernel files
//      system-kernel-cpp/src/Eco/Kernel/<Home>.js those wrappers need and every Eco kernel they import,
//      dependencies first, rendered the way eco's JS backend renders a kernel in development mode
//      (Compiler.Parse.Kernel, Compiler.GenerateJs.Generate.generateKernel):
//        - `__Home_name` of an `Elm.Kernel.Home` import is `_Home_name`; of an `Eco.Kernel.Home` import,
//          `_Eco_Home_name`; of an Elm module import, `$elm$core$Module$name`;
//        - in the plain text of an Eco kernel, an identifier `_Home_...` of a linked Eco kernel becomes
//          `_Eco_Home_...`;
//        - `__$name` is the Elm record field `name`; a lower-case `__name` is a field number, rendered
//          `$k<n>`, numbered per file in order of first use; `__<digit>name` is an enumeration number,
//          numbered per file and per digit; `__DEBUG` disappears and `__PROD` is `_UNUSED`;
//   3. fails, writing nothing, if a stub is left (a reachable kernel reference with no wrapper), if a
//      linked name is not defined, or if the kernels were already linked.
// So Stage 1 runs the kernels Stages 2-5 run. Kernels the program does not reach are not linked.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { definitionSpan } = require("./apply-overrides.js");

const KERNEL_DIR = path.resolve(__dirname, "../../system-kernel-cpp/src/Eco/Kernel");
const MARKER = "// ECO/SYSTEM KERNELS (compiler/scripts/link-stage1-system-kernels.js)";
const STUB = "eco/system kernel";

// The package of each Elm module a kernel header may import.
const ELM_MODULE_PACKAGE = { Maybe: "elm$core", List: "elm$core", Result: "elm$core", Basics: "elm$core", Dict: "elm$core" };

class LinkError extends Error {}

// Parses the `/* import ... */` header of kernel file `home`: the import lines, and the body after it.
function parseHeader(home, text) {
    const m = text.match(/^\/\*\n([\s\S]*?)\*\/\n/);
    if (!m) throw new LinkError(`${home}.js: no import header`);
    const imports = [];
    for (const line of m[1].split("\n")) {
        if (line.trim() === "") continue;
        const im = line.match(/^import\s+([A-Z][\w.]*)\s+exposing\s+\(([^)]*)\)\s*$/);
        if (!im) throw new LinkError(`${home}.js: cannot read header line ${JSON.stringify(line)}`);
        imports.push({ module: im[1], names: im[2].split(",").map((s) => s.trim()).filter(Boolean) });
    }
    return { imports, body: text.slice(m[0].length) };
}

// The Eco kernel homes kernel `home` imports.
function ecoImports(home) {
    const { imports } = parseHeader(home, fs.readFileSync(path.join(KERNEL_DIR, home + ".js"), "utf8"));
    return imports.filter((i) => i.module.startsWith("Eco.Kernel.")).map((i) => i.module.slice("Eco.Kernel.".length));
}

// `homes` closed under Eco kernel imports, each after the homes it imports.
function linkOrder(homes) {
    const order = [];
    const state = new Map();
    const visit = (home, trail) => {
        if (state.get(home) === "done") return;
        if (state.get(home) === "visiting") throw new LinkError(`kernel import cycle: ${[...trail, home].join(" -> ")}`);
        if (!fs.existsSync(path.join(KERNEL_DIR, home + ".js"))) throw new LinkError(`no kernel file ${home}.js`);
        state.set(home, "visiting");
        for (const dep of ecoImports(home)) visit(dep, [...trail, home]);
        state.set(home, "done");
        order.push(home);
    };
    for (const h of homes) visit(h, []);
    return order;
}

// Renders kernel file `home` as eco's JS backend renders a kernel in development mode; `linked` is the
// set of Eco kernel homes in the program.
function renderKernel(home, linked) {
    const { imports, body } = parseHeader(home, fs.readFileSync(path.join(KERNEL_DIR, home + ".js"), "utf8"));
    const vars = new Map();
    for (const im of imports) {
        const k = im.module.match(/^(Elm|Eco)\.Kernel\.([A-Z]\w*)$/);
        for (const name of im.names) {
            if (k) {
                const target = k[1] === "Eco" && linked.has(k[2]) ? `_Eco_${k[2]}_${name}` : `_${k[2]}_${name}`;
                vars.set(`${k[2]}_${name}`, target);
            } else {
                const pkg = ELM_MODULE_PACKAGE[im.module];
                if (!pkg) throw new LinkError(`${home}.js: imports Elm module ${im.module}, whose package is not known`);
                vars.set(`${im.module}_${name}`, `$${pkg}$${im.module.replace(/\./g, "$")}$${name}`);
            }
        }
    }
    const fields = new Map();
    const enums = new Map();
    const qualify = (js) =>
        js.replace(/(^|[^A-Za-z0-9_$])_([A-Z][A-Za-z0-9]*)_/g, (m, pre, h) => (linked.has(h) ? `${pre}_Eco_${h}_` : m));
    let out = "";
    let last = 0;
    const re = /__([$A-Za-z0-9_][A-Za-z0-9_]*)/g;
    let m;
    while ((m = re.exec(body)) !== null) {
        out += qualify(body.slice(last, m.index));
        const tag = m[1];
        let rendered;
        if (tag.startsWith("$")) {
            rendered = tag.slice(1);
        } else if (/^[0-9]/.test(tag)) {
            const digit = tag[0];
            if (!enums.has(digit)) enums.set(digit, new Map());
            const table = enums.get(digit);
            if (!table.has(tag)) table.set(tag, table.size);
            rendered = String(table.get(tag));
        } else if (/^[a-z]/.test(tag)) {
            if (!fields.has(tag)) fields.set(tag, fields.size);
            rendered = "$k" + fields.get(tag);
        } else if (tag === "DEBUG") {
            rendered = "";
        } else if (tag === "PROD") {
            rendered = "_UNUSED";
        } else if (vars.has(tag)) {
            rendered = vars.get(tag);
        } else {
            throw new LinkError(`${home}.js: unknown kernel tag __${tag}`);
        }
        out += rendered;
        last = m.index + m[0].length;
    }
    out += qualify(body.slice(last));
    return out;
}

// Returns `output` with the eco/system kernels linked, or throws LinkError.
function link(output, wrappers) {
    let lines = output.split("\n");
    if (lines.includes(MARKER)) throw new LinkError("the eco/system kernels are already linked (the marker line is there)");

    // 1. Wrappers, replaced from the last span to the first.
    const replacements = [];
    const homes = new Set();
    for (const w of wrappers) {
        const span = definitionSpan(lines, w.global, "guida.js");
        if (span === null) continue;
        replacements.push([span, `var ${w.global} = _Eco_${w.home}_${w.fn};`]);
        homes.add(w.home);
    }
    replacements.sort((a, b) => b[0][0] - a[0][0]);
    for (const [[start, end], text] of replacements) lines.splice(start, end - start, text);
    const left = lines.findIndex((l) => l.includes(STUB));
    if (left >= 0) {
        throw new LinkError(`line ${left + 1} still holds a kernel stub, a kernel reference that is not a listed wrapper: ` +
            JSON.stringify(lines[left].trim().slice(0, 160)));
    }

    // 2. Kernels.
    const order = linkOrder([...homes].sort());
    const linked = new Set(order);
    const block = [MARKER];
    for (const home of order) {
        block.push(`// --- system-kernel-cpp/src/Eco/Kernel/${home}.js`);
        block.push(...renderKernel(home, linked).replace(/\n+$/, "").split("\n"));
    }
    const kernelText = block.join("\n");
    for (const [, text] of replacements) {
        const name = text.match(/= (_Eco_\w+);$/)[1];
        if (!new RegExp(`^(var ${name} =|function ${name}\\()`, "m").test(kernelText)) {
            throw new LinkError(`${name} is not defined by the linked kernels (${order.join(", ")})`);
        }
    }
    const boundary = lines.findIndex((l) => l.startsWith("var $"));
    if (boundary < 0) throw new LinkError("no Elm definition (`var $...`) found, so no kernel/Elm boundary");
    lines.splice(boundary, 0, ...block, "");
    return lines.join("\n");
}

function main(argv) {
    const [file, systemDir] = argv;
    if (!file || !systemDir || argv.length > 2) {
        console.error("usage: link-stage1-system-kernels.js <output.js> <stage1 system dir>");
        return 2;
    }
    try {
        const wrappers = JSON.parse(fs.readFileSync(path.join(systemDir, "kernels.json"), "utf8"));
        const result = link(fs.readFileSync(file, "utf8"), wrappers);
        const tmp = file + ".tmp";
        fs.writeFileSync(tmp, result);
        fs.renameSync(tmp, file);
        return 0;
    } catch (e) {
        if (e instanceof LinkError) {
            console.error(`link-stage1-system-kernels: ${path.basename(file)}: ${e.message}`);
            return 1;
        }
        throw e;
    }
}

module.exports = { link, renderKernel, LinkError };

if (require.main === module) process.exit(main(process.argv.slice(2)));
