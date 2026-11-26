// kernel-overrides-lib.js — reads compiler/kernel-overrides/*.js (plans/js-kernel-overrides.md §2), for
// gen-kernel-overrides.mjs (eco's JS backend) and apply-overrides.js (Stage 1).
//
// An override file is a `/* ... */` header, one directive per line, then the body:
//   kind kernel                            required, first line (the only kind; plans/stage1-direct-kernel-linking.md
//                                          retired the Stage-1-only `kind value`)
//   requires <Prefix>.Kernel.<Home>        one or more; used only when every one is in the program
//   package <author>/<name> <version>      one or more; the stock package the body was written against
// The body is plain JavaScript, emitted as written (no kernel `__` tags, no record fields). Files are
// printable ASCII, tabs and newlines only.
"use strict";

const fs = require("node:fs");
const path = require("node:path");

const DIR = path.resolve(__dirname, "../kernel-overrides");

// The line that opens the override section, in eco's output (Compiler.GenerateJs.KernelOverride.marker)
// and in Stage 1's. Keep the two equal.
const MARKER = "// KERNEL OVERRIDES (compiler/kernel-overrides)\n";

class OverrideError extends Error {}

// Parses the override file `file` (a base name) with text `text`. Throws OverrideError, naming the file and
// line, on anything that does not follow the grammar.
function parse(file, text) {
  const fail = (line, msg) => {
    throw new OverrideError(`${file}:${line}: ${msg}`);
  };
  if (!text.startsWith("/*\n")) fail(1, "must start with a `/*` line opening the header");
  // ASCII only: the generated Elm module must stay what elm-format would write, and elm-format's
  // handling of other characters in string literals is not worth reproducing.
  const nonAscii = text.search(/[^\x09\x0a\x20-\x7e]/);
  if (nonAscii >= 0) fail(text.slice(0, nonAscii).split("\n").length, "only printable ASCII, tabs and newlines are allowed");
  const close = text.indexOf("\n*/\n");
  if (close < 0) fail(1, "no `*/` line closing the header");
  const lines = text.slice(3, close + 1).split("\n").slice(0, -1);
  const o = { file, kind: null, requires: [], packages: [] };
  lines.forEach((line, i) => {
    const n = i + 2;
    const m = line.match(/^(\S+) (.+)$/);
    if (!m) fail(n, `not a directive: ${JSON.stringify(line)}`);
    const [, key, arg] = m;
    if (i === 0 && key !== "kind") fail(n, "the first directive must be `kind`");
    switch (key) {
      case "kind":
        if (i !== 0) fail(n, "`kind` must be the first directive, once");
        if (arg !== "kernel") fail(n, "`kind` is `kernel`");
        o.kind = arg;
        break;
      case "requires": {
        const r = arg.match(/^(Elm|Eco)\.Kernel\.([A-Z][A-Za-z0-9]*)$/);
        if (!r) fail(n, "`requires` names a kernel module, `Elm.Kernel.<Home>` or `Eco.Kernel.<Home>`");
        o.requires.push([r[1], r[2]]);
        break;
      }
      case "package": {
        const p = arg.match(/^([a-z0-9-]+\/[a-z0-9-]+) (\d+\.\d+\.\d+)$/);
        if (!p) fail(n, "`package` is `<author>/<name> <version>`");
        o.packages.push([p[1], p[2]]);
        break;
      }
      default:
        fail(n, `unknown directive \`${key}\``);
    }
  });
  if (o.kind === null) fail(1, "no `kind`");
  if (o.requires.length === 0) fail(1, "a kernel override needs at least one `requires`");
  if (o.packages.length === 0) fail(1, "a kernel override needs at least one `package`");
  let body = text.slice(close + 4);
  if (!body.endsWith("\n")) body += "\n";
  o.body = body;
  return o;
}

// Every override in `dir`, sorted by file name.
function load(dir = DIR) {
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".js"))
    .sort()
    .map((f) => parse(f, fs.readFileSync(path.join(dir, f), "utf8")));
}

// The text inserted between the kernel code and the Elm code for the chosen kernel overrides, or "".
function section(chosen) {
  return chosen.length === 0 ? "" : "\n" + MARKER + chosen.map((o) => o.body).join("");
}

module.exports = { DIR, MARKER, OverrideError, parse, load, section };
