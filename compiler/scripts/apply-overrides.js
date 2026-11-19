#!/usr/bin/env node
// apply-overrides.js — applies compiler/kernel-overrides/*.js to JavaScript built by stock `elm make`
// (Stage 1 guida.js, the API build), which knows nothing about overrides (plans/js-kernel-overrides.md §4).
// eco's own JS backend emits kernel overrides itself (Compiler.GenerateJs.KernelOverride); its outputs
// need no post-processing. This script knows no stock source text: it applies the override files, checks
// everything it touches, and fails without writing on any mismatch.
//
//   node compiler/scripts/apply-overrides.js <output.js> [<overrides dir>]
//
// 1. The output must not already hold the override marker as a line (a second run fails).
// 2. Value overrides, by group: a group whose definitions are all absent is skipped (eco-built compilers
//    have no MVar hooks); a group whose definitions are each present exactly once has each definition
//    span replaced by its override's body; anything else fails.
// 3. The kernel/Elm boundary is the first line that starts with `var $`. Kernel code defines no
//    `$`-named top-level var, so everything above it is kernel code and everything from it on is Elm.
// 4. A kernel module `<Prefix>.Kernel.<Home>` is present iff a line above the boundary starts with
//    `var _<Home>_` or `function _<Home>_` (`_Eco_<Home>_` for an Eco kernel).
// 5. Each kernel override whose kernel modules are all present is kept; every name its body assigns
//    at column 0 must be defined above the boundary.
// 6. The marker and the kept bodies are inserted just before the boundary, as eco's backend emits them.
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const lib = require("./kernel-overrides-lib.js");

class ApplyError extends Error {}

const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// The [start, end) character range of the definition of `global` in `lines` (an array of lines, each
// without its "\n") as line indices: from its `var <global> = ` line up to, not including, the next line
// that starts with `var `. Every other line in it that starts at column 0 may hold only closing brackets
// and `;`. Returns null when there is no definition; throws when there are several or the span is odd.
function definitionSpan(lines, global, file) {
  const head = new RegExp("^var " + escape(global) + " = ");
  const at = [];
  lines.forEach((l, i) => {
    if (head.test(l)) at.push(i);
  });
  if (at.length === 0) return null;
  if (at.length > 1) throw new ApplyError(`${file}: ${global} is defined ${at.length} times`);
  let end = at[0] + 1;
  while (end < lines.length && !lines[end].startsWith("var ")) {
    const l = lines[end];
    if (l.length > 0 && !/^\s/.test(l) && !/^[\]})]+;?$/.test(l)) {
      throw new ApplyError(`${file}: the definition of ${global} runs into another statement: ${JSON.stringify(l)}`);
    }
    end++;
  }
  if (end === lines.length) throw new ApplyError(`${file}: the definition of ${global} is not followed by a var`);
  return [at[0], end];
}

// Returns the text of `output` with `overrides` applied, or throws ApplyError.
function apply(output, overrides) {
  let lines = output.split("\n");
  // A whole line: the compiler's own output also holds the marker inside a string constant.
  if (lines.includes(lib.MARKER.trimEnd())) {
    throw new ApplyError("the overrides are already applied (the marker line is there)");
  }

  // 2. Value overrides, all-or-none per group, replaced from the last span to the first.
  const groups = new Map();
  for (const o of overrides.filter((o) => o.kind === "value")) {
    if (!groups.has(o.group)) groups.set(o.group, []);
    groups.get(o.group).push(o);
  }
  const replacements = [];
  for (const [group, members] of groups) {
    const spans = members.map((o) => [o, definitionSpan(lines, o.value, o.file)]);
    const found = spans.filter(([, s]) => s !== null);
    if (found.length === 0) continue;
    if (found.length !== members.length) {
      const missing = spans.filter(([, s]) => s === null).map(([o]) => o.value);
      throw new ApplyError(`group ${group}: only some definitions are present; missing ${missing.join(", ")}`);
    }
    for (const [o, span] of found) replacements.push([span, o.body.replace(/\n$/, "").split("\n")]);
  }
  replacements.sort((a, b) => b[0][0] - a[0][0]);
  for (const [[start, end], body] of replacements) lines.splice(start, end - start, ...body);

  // 3. The boundary.
  const boundary = lines.findIndex((l) => l.startsWith("var $"));
  if (boundary < 0) throw new ApplyError("no Elm definition (`var $...`) found, so no kernel/Elm boundary");
  const kernelLines = lines.slice(0, boundary);

  // 4. Kernel presence.
  const present = ([prefix, home]) => {
    const name = prefix === "Eco" ? `_Eco_${home}_` : `_${home}_`;
    return kernelLines.some((l) => l.startsWith("var " + name) || l.startsWith("function " + name));
  };
  const defined = (name) =>
    kernelLines.some((l) => l.startsWith(`var ${name} =`) || l.startsWith(`function ${name}(`));

  // 5. Kernel overrides.
  const kept = overrides.filter((o) => o.kind === "kernel" && o.requires.every(present));
  for (const o of kept) {
    for (const m of o.body.matchAll(/^(_[A-Za-z0-9_]+) = /gm)) {
      if (!defined(m[1])) throw new ApplyError(`${o.file}: assigns ${m[1]}, which no kernel above the boundary defines`);
    }
  }

  // 6. Insert.
  const section = lib.section(kept);
  if (section !== "") lines.splice(boundary, 0, ...section.replace(/\n$/, "").split("\n"));
  return lines.join("\n");
}

function main(argv) {
  const [file, dir] = argv;
  if (!file || argv.length > 2) {
    console.error("usage: apply-overrides.js <output.js> [<overrides dir>]");
    return 2;
  }
  try {
    const result = apply(fs.readFileSync(file, "utf8"), lib.load(dir || lib.DIR));
    const tmp = file + ".tmp";
    fs.writeFileSync(tmp, result);
    fs.renameSync(tmp, file);
    return 0;
  } catch (e) {
    if (e instanceof ApplyError || e instanceof lib.OverrideError) {
      console.error(`apply-overrides: ${path.basename(file)}: ${e.message}`);
      return 1;
    }
    throw e;
  }
}

module.exports = { apply, ApplyError };

if (require.main === module) process.exit(main(process.argv.slice(2)));
