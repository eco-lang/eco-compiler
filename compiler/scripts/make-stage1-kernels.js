#!/usr/bin/env node
// make-stage1-kernels.js — the stock-Elm copies of the eco/system and eco/kernel modules that the compiler and
// its tests import, for every build of the compiler by stock `elm make` (plans/stage1-direct-kernel-linking.md
// §6).
//
//   node compiler/scripts/make-stage1-kernels.js <outDir> <project elm.json>
//
// Stock `elm make` rejects these packages' sources as they are: they import `Eco.Kernel.*`, and some are
// `effect module`s. This script writes stock-Elm copies of them, rewritten by
// system-kernel-cpp/scripts/stock-elm-rewrite.js (the rewrite eco/system's docs.json is built with), where
// every kernel reference is a stub, `Debug.todo "ECO_STAGE1_KERNEL_STUB <Home>.<fn>"`, that is the whole body
// of a top-level definition:
//   - a reference that already is the whole body of a top-level definition (`hash = Eco.Kernel.FNV.hash`)
//     becomes that definition's body;
//   - any other reference (`Eco.Kernel.MVar.read id |> ...`) becomes the name `ecoKernelStub<Home><Fn>`,
//     defined once at the end of the module as the stub. Stock Elm generalizes an unannotated top-level
//     definition, so one stub serves every use.
// kernels.json lists each such definition by its JavaScript global; post-process-stock-elm.js replaces it
// with the real kernel after `elm make`.
//
// The modules: every module imported by compiler/src or compiler/tests whose file is in exactly one of the
// two packages and in none of the project's source directories (other than <outDir>), and the modules those
// import, by the same rule. A module the project defines itself is never generated.
//
// Writes <outDir>/<Module/Path>.elm, <outDir>/kernels.json and <outDir>/GENERATED (the build's stamp, always
// rewritten). The modules and kernels.json are rewritten only when their text changes, so `elm make` does
// not recompile them needlessly, and generated modules no longer produced are deleted.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { rewrite } = require("../../system-kernel-cpp/scripts/stock-elm-rewrite.js");

const REPO = path.resolve(__dirname, "../..");
const PACKAGES = [
    { name: "eco/system", src: path.join(REPO, "system-kernel-cpp/src") },
    { name: "eco/kernel", src: path.join(REPO, "eco-kernel-cpp/src") },
];
const SCAN_DIRS = [path.join(REPO, "compiler/src"), path.join(REPO, "compiler/tests")];

const STUB_TOKEN = "ECO_STAGE1_KERNEL_STUB";

class GenerateError extends Error {}

function relModuleFile(name) {
    return path.join(...name.split(".")) + ".elm";
}

// The `import`ed module names of Elm source `source`.
function importsOf(source) {
    return [...source.matchAll(/^import\s+([A-Z][\w.]*)/gm)].map((m) => m[1]);
}

// Every .elm file under `dir`.
function elmFiles(dir) {
    const out = [];
    const walk = (d) => {
        if (!fs.existsSync(d)) return;
        for (const e of fs.readdirSync(d, { withFileTypes: true })) {
            if (e.name === "elm-stuff" || e.name.startsWith(".")) continue;
            const p = path.join(d, e.name);
            if (e.isDirectory()) walk(p);
            else if (e.name.endsWith(".elm")) out.push(p);
        }
    };
    walk(dir);
    return out.sort();
}

// `name` with its first letter upper-cased.
function capitalised(name) {
    return name.charAt(0).toUpperCase() + name.slice(1);
}

// The stock-Elm text of module `name` (package `pkg`) with source `source`, and its kernels.json entries.
function generateModule(name, pkg, source) {
    const refs = [];
    const rewritten = rewrite(source, {
        kernelRef: (home, fn) => {
            refs.push({ home, fn });
            return `ECO_KERNEL_REF_${refs.length - 1}_`;
        },
    });
    const globalOf = (defName) => "$author$project$" + name.replace(/\./g, "$") + "$" + defName;
    const stubText = (r) => `Debug.todo "${STUB_TOKEN} ${r.home}.${r.fn}"`;
    const entries = [];

    // Whole-body references keep their definition. The reference must end the body: after it come only
    // blank lines, then a line at column 0 or the end of the module (`new =\n    ref\n        |> f` is not
    // a whole body).
    const wrapped = new Set();
    for (const m of rewritten.matchAll(/^([a-z]\w*)[ \t]*=[ \t]*\n[ \t]+ECO_KERNEL_REF_(\d+)_[ \t]*(?=\n|$(?![\s\S]))/gm)) {
        const rest = rewritten.slice(m.index + m[0].length).replace(/^(\n[ \t]*)*\n/, "\n");
        if (rest.trim() !== "" && !/^\n?\S/.test(rest)) continue;
        const r = refs[Number(m[2])];
        wrapped.add(Number(m[2]));
        entries.push({ global: globalOf(m[1]), package: pkg.name, home: r.home, fn: r.fn });
    }

    // Every other reference names a lifted stub.
    const lifted = new Map();
    let text = rewritten.replace(/ECO_KERNEL_REF_(\d+)_/g, (_, i) => {
        const r = refs[Number(i)];
        if (wrapped.has(Number(i))) return `(${stubText(r)})`;
        const stub = `ecoKernelStub${r.home}${capitalised(r.fn)}`;
        lifted.set(stub, r);
        return stub;
    });
    for (const [stub, r] of [...lifted].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
        if (new RegExp(`^${stub}\\b`, "m").test(source)) {
            throw new GenerateError(`${name}: the lifted stub name ${stub} is already defined in the module`);
        }
        text = text.replace(/\n*$/, "\n") + `\n\n${stub} =\n    ${stubText(r)}\n`;
        entries.push({ global: globalOf(stub), package: pkg.name, home: r.home, fn: r.fn });
    }
    return { text, entries };
}

function writeIfChanged(file, text) {
    if (fs.existsSync(file) && fs.readFileSync(file, "utf8") === text) return;
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, text);
}

// Writes the stock-Elm copies into `outDir`, as the header describes. `packages` are { name, src };
// `projectSourceDirs` the project's source directories (absolute); `scanDirs` the directories whose imports
// are the roots. Returns the kernels.json entries.
function generate({ packages = PACKAGES, projectSourceDirs, scanDirs = SCAN_DIRS, outDir }) {
    const out = path.resolve(outDir);
    const projectDirs = projectSourceDirs.map((d) => path.resolve(d)).filter((d) => d !== out);

    // The package that module `name` is generated from, or null.
    const packageOf = (name) => {
        if (name.startsWith("Eco.Kernel.")) return null;
        const rel = relModuleFile(name);
        const found = packages.filter((p) => fs.existsSync(path.join(p.src, rel)));
        if (found.length === 0) return null;
        if (found.length > 1) {
            throw new GenerateError(`module ${name} is in two packages: ${found.map((p) => p.name).join(", ")}`);
        }
        if (projectDirs.some((d) => fs.existsSync(path.join(d, rel)))) return null;
        return found[0];
    };

    const queue = [];
    for (const dir of scanDirs) {
        for (const file of elmFiles(dir)) queue.push(...importsOf(fs.readFileSync(file, "utf8")));
    }
    const seen = new Set();
    const written = new Set();
    const entries = [];
    while (queue.length > 0) {
        const name = queue.shift();
        if (seen.has(name)) continue;
        seen.add(name);
        const pkg = packageOf(name);
        if (pkg === null) continue;
        const source = fs.readFileSync(path.join(pkg.src, relModuleFile(name)), "utf8");
        queue.push(...importsOf(source));
        const generated = generateModule(name, pkg, source);
        entries.push(...generated.entries);
        writeIfChanged(path.join(out, relModuleFile(name)), generated.text);
        written.add(relModuleFile(name));
    }

    // Delete generated modules that are no longer produced.
    const walk = (dir, rel) => {
        if (!fs.existsSync(dir)) return;
        for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
            const r = path.join(rel, e.name);
            if (e.isDirectory()) walk(path.join(dir, e.name), r);
            else if (e.name.endsWith(".elm") && !written.has(r)) fs.unlinkSync(path.join(dir, e.name));
        }
    };
    walk(out, "");
    entries.sort((a, b) => (a.global < b.global ? -1 : a.global > b.global ? 1 : 0));
    writeIfChanged(path.join(out, "kernels.json"), JSON.stringify(entries, null, 2) + "\n");
    // Always rewritten: it is the build's stamp for this step.
    fs.writeFileSync(path.join(out, "GENERATED"),
        "Generated by compiler/scripts/make-stage1-kernels.js from system-kernel-cpp/src and eco-kernel-cpp/src;\n" +
        "do not edit. The build regenerates this directory when those sources or the compiler's imports change.\n");
    return entries;
}

function main(argv) {
    if (argv.length !== 2) {
        console.error("usage: make-stage1-kernels.js <outDir> <project elm.json>");
        return 2;
    }
    const [outDir, elmJson] = argv;
    const project = JSON.parse(fs.readFileSync(elmJson, "utf8"));
    const projectSourceDirs = project["source-directories"].map((d) => path.resolve(path.dirname(elmJson), d));
    try {
        generate({ projectSourceDirs, outDir });
        return 0;
    } catch (e) {
        if (e instanceof GenerateError) {
            console.error(`make-stage1-kernels: ${e.message}`);
            return 1;
        }
        throw e;
    }
}

module.exports = { generate, GenerateError, STUB_TOKEN };

if (require.main === module) process.exit(main(process.argv.slice(2)));
