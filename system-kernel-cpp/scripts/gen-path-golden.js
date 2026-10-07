#!/usr/bin/env node
// gen-path-golden.js — golden tables for System.File.Path (plans/eco-system-library.md Phase 4.1).
//
// The oracle is gren-node's implementation: Gren/Kernel/FilePath.js (node:path `normalize` then
// `parse`, in the posix or win32 flavour) plus the pure logic of FileSystem/Path.gren, ported
// below on top of the real node:path. The pure-Elm System.File.Path must reproduce every value.
//
// Deviation from FilePath.js, per Appendix E.2: FilePath.js prepends a `./` directory entry when the
// input starts with `.` + the *native* separator. That quirk is kept for the posix flavour only
// (as if native were posix), so the tables do not depend on the host OS.
//
// The win32 flavour of node:path changed in node 22 (CVE-2024-36139 and reserved device names such
// as `CON:`), so regenerate with node >= 22 and check any diff.
//
// Usage: node scripts/gen-path-golden.js [outFile]   (default: tests/tests/PathGolden.elm)
"use strict";
const fs = require("fs");
const nodePath = require("path");
const posix = require("node:path").posix;
const win32 = require("node:path").win32;

// ---- Port of Gren/Kernel/FilePath.js ---------------------------------------------------------

function parse(pathMod, str) {
    const result = pathMod.parse(pathMod.normalize(str));
    const root = result.root;
    let dirStr = result.dir.startsWith(root) ? result.dir.substring(root.length) : result.dir;
    // FilePath.js: `str.startsWith(`.${path.sep}`)` with the native separator; posix only (E.2).
    if (pathMod === posix && str.startsWith("./")) {
        dirStr = "./" + dirStr;
    }
    const filename = result.name === "." && result.ext.length === 0 ? "" : result.name;
    return {
        root: result.root,
        directory: dirStr === "" ? [] : dirStr.split(pathMod.sep).filter((d) => d.length > 0),
        filename,
        extension: result.ext.length > 0 ? result.ext.substring(1) : "",
    };
}

const fromPosixString = (s) => parse(posix, s);
const fromWin32String = (s) => parse(win32, s);

function isEmpty(p) {
    return p.root === "" && p.directory.length === 0 && p.filename === "" && p.extension === "";
}

function format(pathMod, p) {
    const filename = p.extension.length > 0 ? p.filename + "." + p.extension : p.filename;
    const parts = filename === "" ? p.directory : p.directory.concat(filename);
    return p.root + parts.join(pathMod.sep);
}

function toPosixString(p) {
    if (isEmpty(p)) return ".";
    if (p.root !== "" && p.root !== "/") p = { ...p, root: "/" };
    return format(posix, p);
}

function toWin32String(p) {
    if (isEmpty(p)) return ".";
    return format(win32, p);
}

// ---- Port of FileSystem/Path.gren ------------------------------------------------------------

const empty = { root: "", directory: [], filename: "", extension: "" };

function filenameWithExtension(p) {
    return p.extension === "" ? p.filename : p.filename + "." + p.extension;
}

function parentPath(p) {
    if (p.directory.length === 0) {
        if (filenameWithExtension(p) === "") return null;
        return { ...p, filename: "", extension: "" };
    }
    const last = p.directory[p.directory.length - 1];
    const initial = p.directory.slice(0, -1);
    const parts = last.split(".");
    const [filename, extension] = parts.length === 2 ? parts : [last, ""];
    return { ...p, directory: initial, filename, extension };
}

// gren's `Array.append a b` is `b ++ a`, so the gren source reads
// `left.directory ++ [ filenameWithExtension left ] ++ right.directory`.
function prepend(left, right) {
    return {
        ...left,
        directory: left.directory
            .concat([filenameWithExtension(left)])
            .concat(right.directory)
            .filter((d) => d !== ""),
        filename: right.filename,
        extension: right.extension,
    };
}

const append = (left, right) => prepend(right, left);
const appendPosixString = (s, p) => prepend(p, fromPosixString(s));
const appendWin32String = (s, p) => prepend(p, fromWin32String(s));
const prependPosixString = (s, p) => prepend(fromPosixString(s), p);
const prependWin32String = (s, p) => prepend(fromWin32String(s), p);

// gren: popFirst, then `Array.foldl append first rest`; gren's foldl is (a -> b -> b), so each
// step is `append elem acc`.
function join(paths) {
    if (paths.length === 0) return empty;
    return paths.slice(1).reduce((acc, elem) => append(elem, acc), paths[0]);
}

function ancestors(p) {
    const out = [];
    let q = parentPath(p);
    while (q !== null && out.length < 64) {
        out.push(toPosixString(q));
        q = parentPath(q);
    }
    return out;
}

// ---- Inputs ----------------------------------------------------------------------------------

const handPicked = [
    // empties and dots
    "", ".", "..", "...", "....", "./", "../", ".//", "./.", "././", "./..", "../..", "../../",
    "./a", "./a/b", "./a/", ".\\a", "./../a", "./.hidden", "./a.txt", ".../a", "a/...", "a/..b",
    // normalisation
    "a/../b", "a/./b", "a/b/..", "a/b/../..", "a/b/../../..", "a//b", "a/b/", "a/b//", "/a/../..",
    "/..", "/../a", "/./a", "/a/./b/../c", "a/../../b", "x/y/../../../z",
    // slashes
    "/", "//", "///", "//a//b/", "//a", "///a///b///", "/a", "/a/", "/a/b", "/a/b/c.txt",
    // file names and extensions
    "file", "file.txt", "file.tar.gz", ".bashrc", ".bashrc.bak", "..a", "a.", "a..", "a.b.",
    ".a.b", "a..b", "noext/", "dir.d/file", "dir.d/", "/home/me/file.md", "/home/me/.config/",
    "/home/me/archive.tar.gz", "src/System/File/Path.elm", "Makefile", "README.md",
    "/usr/local/lib/libfoo.so.1.2", "photo.JPEG", "a b/c d.txt", "with space ", " leading",
    // backslashes in posix are ordinary characters
    "a\\b", "a\\b/c", "\\a", "\\\\server\\share\\x",
    // windows drive roots
    "C:", "C:\\", "C:/", "c:\\", "C:foo", "C:foo\\bar.txt", "C:\\foo\\bar.txt", "C:/foo/bar.txt",
    "C:\\foo\\", "C:\\foo\\..", "C:\\..\\..\\x", "C:..\\x", "C:.", "C:.\\", "Z:\\a/b\\c",
    "C:\\Program Files\\App\\app.exe", "d:\\x.y.z", "1:\\x", "CC:\\x",
    // UNC and device paths
    "\\\\server\\share", "\\\\server\\share\\", "\\\\server\\share\\dir\\file.txt",
    "//server/share/dir/file.txt", "\\\\server", "\\\\server\\", "\\\\", "\\\\\\x", "\\\\.\\x",
    "\\\\.\\PHYSICALDRIVE0", "\\\\?\\C:\\x\\y", "\\\\?\\COM1:", "\\\\.\\COM1:\\x", "\\\\server\\\\share",
    // mixed separators
    "a/b\\c", "a\\b/c\\d.e", "\\a/b", "/a\\b", "a\\\\b//c", "a\\.\\b", "a\\..\\b",
    // colons and reserved names (node CVE-2024-36139 handling)
    ":", "a:", "a:b", "ab:c", "foo:bar\\baz", "a/b:c", "x:/y", "CON", "CON:", "con:x", "NUL",
    "CONx", "aux.txt", "LPT1:\\x", "COM\u00b9:",
    // more ordinary paths
    "a/b/c/d/e.f", "/a/b/c/", "~", "~/x", "a~b", "-", "--x", "a/.b/c", ".git/config",
    "node_modules/.bin/", "/etc/passwd", "/tmp/", "x.y/z.w/", "\\", "C:\\a\\.\\b",
    "C:\\a\\b\\..\\..\\..", "\\\\srv\\shr\\..\\x", "\\\\.\\COM1", "\\\\?\\UNC\\srv\\shr\\f",
    "PRN.txt", "nul:", "LPT9:x", "c:/a:b", "1:", "ab:\\c", "a/b:", "a:/", "./C:x",
    // unicode
    "\u00e9t\u00e9/caf\u00e9.txt", "\u65e5\u672c/\u6587\u5b57.md", "\ud83d\ude00/\ud83d\ude00.\ud83d\ude00",
    "/\u0394/\u03a9.\u03b1", "C:\\\u00fcber\\na\u00efve.txt", "\u00e9", "\ud83d\ude00",
];

const prefixes = ["", "/", "./", "../", "C:", "C:\\", "\\\\srv\\shr\\", "a/b/"];
const tails = ["", "a", "a.txt", ".hidden", "x/y/", "x\\y.z", ".."];
const systematic = [];
for (const p of prefixes) for (const t of tails) systematic.push(p + t);

const inputs = [...new Set([...handPicked, ...systematic])];

const combineStrings = [
    "", ".", "/", "a", "a/b", "/a/b", "file.txt", "dir/file.tar.gz", "../x", "./y", ".hidden",
    "C:\\w", "C:", "\\\\srv\\shr\\z", "a/", "..",
];
const combineRight = ["", "/", "b", "/root/dir", "c/d.e", "C:\\x\\y.z", "../up", "./here"];

const joinLists = [
    [], [""], ["/"], ["a"], ["/a", "b", "c.txt"], ["a", "/b"], ["/", "x"], ["a/b", "c/d", "e.f"],
    ["", "a", ""], [".", "a"], ["..", "..", "x"], ["/a/", "b/", "c/"], ["C:\\x", "y"],
    ["a.b", "c.d", "e.f"], ["/usr", "local", "bin", "eco"], ["./x", "./y"],
];

// ---- Elm output ------------------------------------------------------------------------------

function elmString(s) {
    let out = '"';
    for (const ch of s) {
        const cp = ch.codePointAt(0);
        if (ch === "\\") out += "\\\\";
        else if (ch === '"') out += '\\"';
        else if (ch === "\n") out += "\\n";
        else if (ch === "\r") out += "\\r";
        else if (ch === "\t") out += "\\t";
        else if (cp < 0x20 || cp > 0x7e) out += "\\u{" + cp.toString(16).toUpperCase().padStart(4, "0") + "}";
        else out += ch;
    }
    return out + '"';
}

const elmList = (xs, f) => (xs.length === 0 ? "[]" : "[ " + xs.map(f).join(", ") + " ]");

function elmPath(p) {
    return (
        "{ root = " + elmString(p.root) +
        ", directory = " + elmList(p.directory, elmString) +
        ", filename = " + elmString(p.filename) +
        ", extension = " + elmString(p.extension) + " }"
    );
}

const elmMaybePath = (p) => (p === null ? "Nothing" : "Just (" + elmPath(p) + ")");

function record(fields, indent) {
    const pad = " ".repeat(indent);
    return (
        pad + "{ " +
        fields.map(([k, v]) => k + " = " + v).join("\n" + pad + ", ") +
        "\n" + pad + "}"
    );
}

function elmRecords(name, type, items, toFields) {
    const body = items.map((it) => record(toFields(it), 6)).join("\n    ,\n");
    return `${name} : List ${type}\n${name} =\n    [\n${body}\n    ]\n`;
}

function flavourFields(prefix, p) {
    return [
        [prefix, elmPath(p)],
        [prefix + "ToPosix", elmString(toPosixString(p))],
        [prefix + "ToWin32", elmString(toWin32String(p))],
        [prefix + "Filename", elmString(filenameWithExtension(p))],
        [prefix + "Parent", elmMaybePath(parentPath(p))],
        [prefix + "Ancestors", elmList(ancestors(p), elmString)],
    ];
}

const parseCases = elmRecords("parseCases", "ParseCase", inputs, (s) => {
    const p = fromPosixString(s);
    const w = fromWin32String(s);
    return [
        ["input", elmString(s)],
        ...flavourFields("posix", p),
        ["posixRoundTrip", elmPath(fromPosixString(toPosixString(p)))],
        ...flavourFields("win32", w),
        ["win32RoundTrip", elmPath(fromWin32String(toWin32String(w)))],
    ];
});

const pairs = [];
for (const a of combineStrings) for (const b of combineRight) pairs.push([a, b]);

const combineCases = elmRecords("combineCases", "CombineCase", pairs, ([a, b]) => {
    const pa = fromPosixString(a), pb = fromPosixString(b);
    const wb = fromWin32String(b);
    const appended = append(pa, pb);
    const prepended = prepend(pa, pb);
    return [
        ["left", elmString(a)],
        ["right", elmString(b)],
        ["append", elmPath(appended)],
        ["appendToPosix", elmString(toPosixString(appended))],
        ["prepend", elmPath(prepended)],
        ["prependToPosix", elmString(toPosixString(prepended))],
        ["appendPosixString", elmPath(appendPosixString(a, pb))],
        ["prependPosixString", elmPath(prependPosixString(a, pb))],
        ["appendWin32String", elmPath(appendWin32String(a, wb))],
        ["prependWin32String", elmPath(prependWin32String(a, wb))],
    ];
});

const joinCases = elmRecords("joinCases", "JoinCase", joinLists, (xs) => {
    const jp = join(xs.map(fromPosixString));
    const jw = join(xs.map(fromWin32String));
    return [
        ["inputs", elmList(xs, elmString)],
        ["posix", elmPath(jp)],
        ["posixToPosix", elmString(toPosixString(jp))],
        ["win32", elmPath(jw)],
        ["win32ToWin32", elmString(toWin32String(jw))],
    ];
});

const pathType = "{ root : String, directory : List String, filename : String, extension : String }";

const header = `module PathGolden exposing (CombineCase, JoinCase, ParseCase, combineCases, joinCases, parseCases)

{-| GENERATED FILE — do not edit.

Golden tables for System.File.Path, produced by running gren-node's FilePath.js / Path.gren
semantics on node ${process.version} (node:path posix and win32 normalize + parse).

Regenerate from system-kernel-cpp/ with:

    node scripts/gen-path-golden.js

-}


type alias P =
    ${pathType}


type alias ParseCase =
    { input : String
    , posix : P
    , posixToPosix : String
    , posixToWin32 : String
    , posixFilename : String
    , posixParent : Maybe P
    , posixAncestors : List String
    , posixRoundTrip : P
    , win32 : P
    , win32ToPosix : String
    , win32ToWin32 : String
    , win32Filename : String
    , win32Parent : Maybe P
    , win32Ancestors : List String
    , win32RoundTrip : P
    }


type alias CombineCase =
    { left : String
    , right : String
    , append : P
    , appendToPosix : String
    , prepend : P
    , prependToPosix : String
    , appendPosixString : P
    , prependPosixString : P
    , appendWin32String : P
    , prependWin32String : P
    }


type alias JoinCase =
    { inputs : List String
    , posix : P
    , posixToPosix : String
    , win32 : P
    , win32ToWin32 : String
    }

`;

const outFile = nodePath.resolve(__dirname, "..", process.argv[2] || "tests/tests/PathGolden.elm");
fs.mkdirSync(nodePath.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, [header, parseCases, combineCases, joinCases].join("\n\n"));
console.log(
    `gen-path-golden: ${inputs.length} parse cases, ${pairs.length} combine cases, ` +
    `${joinLists.length} join cases -> ${nodePath.relative(process.cwd(), outFile)}`
);
