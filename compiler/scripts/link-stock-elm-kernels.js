// link-stock-elm-kernels.js — links eco's JavaScript kernels into JavaScript built by stock `elm make`
// (plans/stage1-direct-kernel-linking.md §5). The link pass of post-process-stock-elm.js, which is the only
// caller; this module has no command line.
//
// A stock-Elm build compiles the stock-Elm copies of eco/system and eco/kernel modules that
// make-stage1-kernels.js generates. Each kernel reference in them is a stub,
// `Debug.todo "ECO_STAGE1_KERNEL_STUB <Home>.<fn>"`, which is the whole body of a top-level definition
// listed in the generated kernels.json. `link`:
//   1. replaces the compiled definition of each listed stub that the output still holds (stock Elm drops
//      unused definitions) with `var <global> = _Eco_<Home>_<fn>;`, as eco's own JS backend emits it;
//   2. emits, just before the first Elm definition, the kernel files Eco/Kernel/<Home>.js of the kernel
//      directories that those stubs need and every Eco kernel they import, dependencies first, rendered the
//      way eco's JS backend renders a kernel in development mode (Compiler.Parse.Kernel,
//      Compiler.GenerateJs.Generate.generateKernel):
//        - `__Home_name` of an `Elm.Kernel.Home` import is `_Home_name`; of an `Eco.Kernel.Home` import,
//          `_Eco_Home_name` when a kernel directory has Home's file, and otherwise `_Home_name`, the elm/core
//          kernel (Generate.resolveKernelGlobal); of an Elm module import, `$elm$core$Module$name`;
//        - in the plain text of a linked kernel, an identifier `_Home_...` of a linked kernel becomes
//          `_Eco_Home_...`;
//        - `__$name` is the Elm record field `name`; a lower-case `__name` is a field number, rendered
//          `$k<n>`, numbered per file in order of first use; `__<digit>name` is an enumeration number,
//          numbered per file and per digit; `__DEBUG` disappears and `__PROD` is `_UNUSED`;
//   3. fails, changing nothing, if a stub is left (a reachable kernel reference with no listed stub), if a
//      linked name or an elm/core kernel name a linked kernel imports is not defined, if a kernel home is
//      in two kernel directories, or if the kernels were already linked.
// Kernels the program does not reach are not linked.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { definitionSpan } = require("./apply-overrides.js");

const REPO = path.resolve(__dirname, "../..");
const MARKER = "// ECO KERNELS (compiler/scripts/post-process-stock-elm.js)";
// The text every stub's `Debug.todo` message starts with (make-stage1-kernels.js). Stock Elm emits the
// message as a single-quoted JavaScript string, so a stub is the token right after a quote; text that only
// mentions the token further into a string does not match.
const STUB_TOKEN = "ECO_STAGE1_KERNEL_STUB";
const STUB_IN_OUTPUT = "'" + STUB_TOKEN + " ";

// The elm/core modules a kernel header may import values from.
const ELM_CORE_MODULES = new Set([
    "Array", "Basics", "Bitwise", "Char", "Debug", "Dict", "List", "Maybe", "Platform", "Platform.Cmd",
    "Platform.Sub", "Process", "Result", "Set", "String", "Task", "Tuple",
]);

class LinkError extends Error {}

// Parses the `/* import ... */` header of the kernel file at `file`: the import lines, and the body after it.
function parseHeader(file, text) {
    const m = text.match(/^\/\*\n([\s\S]*?)\*\/\n/);
    if (!m) throw new LinkError(`${file}: no import header`);
    const imports = [];
    for (const line of m[1].split("\n")) {
        if (line.trim() === "") continue;
        const im = line.match(/^import\s+([A-Z][\w.]*)\s+exposing\s+\(([^)]*)\)\s*$/);
        if (!im) throw new LinkError(`${file}: cannot read header line ${JSON.stringify(line)}`);
        imports.push({ module: im[1], names: im[2].split(",").map((s) => s.trim()).filter(Boolean) });
    }
    return { imports, body: text.slice(m[0].length) };
}

// The kernel files of `kernelDirs`, as a map from home to path. A home in two directories is an error.
function kernelFiles(kernelDirs) {
    const files = new Map();
    for (const dir of kernelDirs) {
        if (!fs.existsSync(dir)) continue;
        for (const f of fs.readdirSync(dir).filter((f) => f.endsWith(".js")).sort()) {
            const home = f.slice(0, -3);
            const file = path.join(dir, f);
            if (files.has(home)) throw new LinkError(`kernel ${home} is in two kernel directories: ${files.get(home)} and ${file}`);
            files.set(home, file);
        }
    }
    return files;
}

// The Eco kernel homes kernel `home` imports that have a file; an `Eco.Kernel.X` import with no file is
// elm/core's kernel X.
function ecoImports(home, files) {
    const { imports } = parseHeader(files.get(home), fs.readFileSync(files.get(home), "utf8"));
    return imports
        .filter((i) => i.module.startsWith("Eco.Kernel.") && files.has(i.module.slice("Eco.Kernel.".length)))
        .map((i) => i.module.slice("Eco.Kernel.".length));
}

// `homes` closed under Eco kernel imports, each after the homes it imports.
function linkOrder(homes, files) {
    const order = [];
    const state = new Map();
    const visit = (home, trail) => {
        if (state.get(home) === "done") return;
        if (state.get(home) === "visiting") throw new LinkError(`kernel import cycle: ${[...trail, home].join(" -> ")}`);
        if (!files.has(home)) throw new LinkError(`no kernel file ${home}.js in the kernel directories`);
        state.set(home, "visiting");
        for (const dep of ecoImports(home, files)) visit(dep, [...trail, home]);
        state.set(home, "done");
        order.push(home);
    };
    for (const h of homes) visit(h, []);
    return order;
}

// Renders the kernel file of `home` as eco's JS backend renders a kernel in development mode; `linked` is
// the set of Eco kernel homes linked into the program. Returns the text and the names of elm/core kernel
// values it uses through its imports.
function renderKernel(home, linked, files) {
    const file = files.get(home);
    const { imports, body } = parseHeader(file, fs.readFileSync(file, "utf8"));
    const vars = new Map();
    const elmKernelNames = [];
    for (const im of imports) {
        const k = im.module.match(/^(Elm|Eco)\.Kernel\.([A-Z]\w*)$/);
        for (const name of im.names) {
            if (k) {
                const eco = k[1] === "Eco" && linked.has(k[2]);
                const target = eco ? `_Eco_${k[2]}_${name}` : `_${k[2]}_${name}`;
                if (!eco) elmKernelNames.push(target);
                vars.set(`${k[2]}_${name}`, target);
            } else {
                if (!ELM_CORE_MODULES.has(im.module)) {
                    throw new LinkError(`${home}.js: imports Elm module ${im.module}, which is not an elm/core module`);
                }
                vars.set(`${im.module.replace(/\./g, "_")}_${name}`, `$elm$core$${im.module.replace(/\./g, "$")}$${name}`);
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
    return { text: out, elmKernelNames };
}

// Whether `name` is defined at column 0 of `text`.
function definedIn(text, name) {
    const n = name.replace(/\$/g, "\\$");
    return new RegExp(`^(var ${n} =|function ${n}\\()`, "m").test(text);
}

// Returns `output` with the Eco kernels linked, or throws LinkError. `entries` are the kernels.json
// entries ({ global, home, fn, package? }); `kernelDirs` the directories holding Eco/Kernel/<Home>.js files.
function link(output, entries, kernelDirs) {
    const lines = output.split("\n");
    if (lines.includes(MARKER)) throw new LinkError("the Eco kernels are already linked (the marker line is there)");
    const files = kernelFiles(kernelDirs);

    // 1. Stubs, replaced from the last span to the first.
    const replacements = [];
    const homes = new Set();
    for (const e of entries) {
        let span;
        try {
            span = definitionSpan(lines, e.global, "output");
        } catch (err) {
            throw new LinkError(err.message);
        }
        if (span === null) continue;
        replacements.push([span, `var ${e.global} = _Eco_${e.home}_${e.fn};`, e]);
        homes.add(e.home);
    }
    replacements.sort((a, b) => b[0][0] - a[0][0]);
    for (const [[start, end], text] of replacements) lines.splice(start, end - start, text);
    const left = lines.findIndex((l) => l.includes(STUB_IN_OUTPUT));
    if (left >= 0) {
        throw new LinkError(`line ${left + 1} still holds a kernel stub, a kernel reference that is not a listed stub: ` +
            JSON.stringify(lines[left].trim().slice(0, 160)));
    }

    // 2. Kernels.
    const boundary = lines.findIndex((l) => l.startsWith("var $"));
    if (boundary < 0) throw new LinkError("no Elm definition (`var $...`) found, so no kernel/Elm boundary");
    const stockKernelText = lines.slice(0, boundary).join("\n");
    const order = linkOrder([...homes].sort(), files);
    const linked = new Set(order);
    const block = [MARKER];
    for (const home of order) {
        const { text, elmKernelNames } = renderKernel(home, linked, files);
        for (const name of elmKernelNames) {
            if (!definedIn(stockKernelText, name)) {
                throw new LinkError(`${home}.js imports ${name}, which the output's kernel code does not define`);
            }
        }
        block.push(`// --- ${path.relative(REPO, files.get(home))}`);
        block.push(...text.replace(/\n+$/, "").split("\n"));
    }
    const kernelText = block.join("\n");
    for (const [, text, e] of replacements) {
        const name = text.match(/= (_Eco_\w+);$/)[1];
        if (!definedIn(kernelText, name)) {
            const pkg = e.package ? ` (${e.package})` : "";
            throw new LinkError(`${name}${pkg} is not defined by the linked kernels (${order.join(", ")})`);
        }
    }
    lines.splice(boundary, 0, ...block, "");
    return lines.join("\n");
}

module.exports = { link, renderKernel, LinkError, MARKER, STUB_TOKEN };
