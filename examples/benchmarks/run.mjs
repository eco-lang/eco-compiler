// Build and run the compute benchmarks on three backends and compare them:
//
//   elm         the official Elm compiler's JavaScript (elm/ElmBench.elm), run in this process
//   eco-js      eco's JavaScript backend (src/Bench.elm), run under node
//   eco-native  eco's native backend (src/Bench.elm)
//
// Needs `eco`, `elm` (0.19.1) and `node` on the PATH; set ECO or ELM to use other binaries.
//
//   node run.mjs                         build, then run every workload on every backend
//   node run.mjs fib nbody --runs 25     some workloads, more samples
//   node run.mjs mandelbrot=800          another size
//   node run.mjs --skip-elm              without the official compiler (also --skip-js)
//   node run.mjs --no-build              reuse the programs in build/
//
// Every backend must compute the same result for each workload, and at the default sizes the
// result must be the known one; otherwise the script exits with status 1. Times are medians in
// milliseconds after the warm-up runs. eco times itself with Time.now (1 ms resolution); the
// official elm build is timed here with process.hrtime. The table goes to stdout and every
// figure to build/results.json.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const dir = path.dirname(fileURLToPath(import.meta.url));
const build = path.join(dir, "build");
const require = createRequire(import.meta.url);
const ECO = process.env.ECO || "eco";
const ELM = process.env.ELM || "elm";

function fail(message, code = 2) {
  console.error(`run.mjs: ${message}`);
  process.exit(code);
}

// ---- options ---------------------------------------------------------------------------------

const opts = { warmup: 3, runs: 11, skipElm: false, skipJs: false, build: true, selected: [] };
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  const number = (least) => {
    const n = Number(args[++i]);
    if (!Number.isInteger(n) || n < least) fail(`${a} needs a whole number of at least ${least}`);
    return n;
  };
  if (a === "--warmup") opts.warmup = number(0);
  else if (a === "--runs") opts.runs = number(1);
  else if (a === "--skip-elm") opts.skipElm = true;
  else if (a === "--skip-js") opts.skipJs = true;
  else if (a === "--no-build") opts.build = false;
  else if (a === "--help" || a === "-h") {
    console.log(fs.readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n\n")[0].replace(/^\/\/ ?/gm, ""));
    process.exit(0);
  } else if (a.startsWith("-")) fail(`unknown option ${a} (see --help)`);
  else opts.selected.push(a);
}
const benchArgs = ["--json", "--warmup", String(opts.warmup), "--runs", String(opts.runs), ...opts.selected];

// ---- build -----------------------------------------------------------------------------------

function run(command, commandArgs, cwd, what) {
  const r = spawnSync(command, commandArgs, { cwd, stdio: "inherit" });
  if (r.error?.code === "ENOENT") {
    const variable = command === ELM ? "ELM" : "ECO";
    const skip = command === ELM ? ", or pass --skip-elm" : "";
    fail(`cannot run ${command} (${what}): not found; put it on the PATH or set ${variable}${skip}`);
  }
  if (r.error) fail(`cannot run ${command} (${what}): ${r.error.message}`);
  if (r.status !== 0) fail(`${what} failed (exit status ${r.status})`);
}

const nativeBin = path.join(build, process.platform === "win32" ? "bench.exe" : "bench");
const ecoJs = path.join(build, "bench.js");
const ecoJsLauncher = path.join(build, "bench-run.cjs");
const elmJs = path.join(build, "elm-bench.js");

if (opts.build) {
  fs.mkdirSync(build, { recursive: true });
  console.log("building eco native ...");
  run(ECO, ["make", "src/Bench.elm", `--output=${nativeBin}`], dir, "eco make (native)");
  if (!opts.skipJs) {
    console.log("building eco JavaScript ...");
    run(ECO, ["make", "src/Bench.elm", `--output=${ecoJs}`], dir, "eco make (JavaScript)");
  }
  if (!opts.skipElm) {
    console.log("building official elm JavaScript ...");
    run(ELM, ["make", "ElmBench.elm", "--optimize", `--output=${elmJs}`], path.join(dir, "elm"), "elm make");
  }
}
fs.writeFileSync(ecoJsLauncher, "require('./bench.js').Elm.Bench.init();\n");

// ---- eco runs --------------------------------------------------------------------------------

// Run an eco build of Bench.elm with --json and return its report. Its stdout may carry other text
// after the JSON document (a development build of eco prints GC statistics at exit), so read the
// document from its opening `{` line to its closing `}` line.
function runEco(command, commandArgs, label) {
  console.log(`running ${label} ...`);
  const r = spawnSync(command, commandArgs, { cwd: dir, encoding: "utf8", maxBuffer: 1 << 26 });
  if (r.error) fail(`cannot run ${label}: ${r.error.message} (build it first, without --no-build)`);
  const lines = r.stdout.split("\n");
  const start = lines.indexOf("{");
  const end = lines.indexOf("}", start);
  if (start < 0 || end < 0) {
    process.stderr.write(r.stderr);
    fail(`${label} printed no results (exit status ${r.status})`);
  }
  if (r.status !== 0 && r.status !== 1) {
    process.stderr.write(r.stderr);
    fail(`${label} failed (exit status ${r.status})`);
  }
  return JSON.parse(lines.slice(start, end + 1).join("\n"));
}

const native = runEco(nativeBin, benchArgs, "eco native");
const ecoJsReport = opts.skipJs ? null : runEco(process.execPath, [ecoJsLauncher, ...benchArgs], "eco JavaScript");

// ---- official elm, in this process -----------------------------------------------------------

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

async function runElm(workloads) {
  console.log("running official elm ...");
  let app;
  try {
    app = require(elmJs).Elm.ElmBench.init();
  } catch (e) {
    fail(`cannot load ${elmJs}: ${e.message} (build it first, without --no-build)`);
  }
  // One request at a time: the reply ends the timing (taken in the port callback itself).
  let pending = null;
  app.ports.fromBench.subscribe((value) => {
    const end = process.hrtime.bigint();
    const p = pending;
    pending = null;
    p?.({ value, end });
  });
  const once = (name, size) =>
    new Promise((resolve) => {
      pending = resolve;
      app.ports.toBench.send({ name, size });
    });
  const timed = async (name, size) => {
    const start = process.hrtime.bigint();
    const { value, end } = await once(name, size);
    return { value, ms: Number(end - start) / 1e6 };
  };
  const report = {};
  for (const w of workloads) {
    for (let i = 0; i < opts.warmup; i++) await timed(w.name, w.size);
    const samples = [];
    let result = null;
    for (let i = 0; i < opts.runs; i++) {
      const { value, ms } = await timed(w.name, w.size);
      samples.push(ms);
      result = value;
    }
    report[w.name] = { result, medianMs: median(samples), fastestMs: Math.min(...samples) };
  }
  return report;
}

const elm = opts.skipElm ? null : await runElm(native.workloads);

// ---- compare and report ----------------------------------------------------------------------

const problems = [];
const rows = native.workloads.map((n) => {
  const js = ecoJsReport?.workloads.find((w) => w.name === n.name && w.size === n.size);
  const e = elm?.[n.name];
  // Results as numbers: official elm's Int is a JavaScript double, so compare in that type.
  const results = [["eco-native", n.result], ["eco-js", js?.result], ["elm", e?.result]].filter(([, v]) => v != null);
  if (results.some(([, v]) => Number(v) !== Number(n.result))) {
    problems.push(`${n.name}: backends disagree (${results.map(([b, v]) => `${b} ${v}`).join(", ")})`);
  }
  if (n.check === "WRONG") problems.push(`${n.name}: result ${n.result}, expected ${n.expected}`);
  return {
    name: n.name,
    size: n.size,
    result: n.result,
    elm: e?.medianMs ?? null,
    ecoJs: js?.medianMs ?? null,
    ecoNative: n.medianMs,
  };
});

const fmt = (x) => (x == null ? "-" : x.toFixed(x < 10 ? 2 : 1)).padStart(11);
const ratio = (r) => (r.elm == null || r.ecoNative === 0 ? "-" : `${(r.elm / r.ecoNative).toFixed(1)}x`).padStart(15);
console.log(`\nwarmup ${opts.warmup}, runs ${opts.runs}; median ms, lower is better\n`);
console.log("workload".padEnd(16) + "size".padStart(9) + "elm".padStart(11) + "eco-js".padStart(11) + "eco-native".padStart(11) + "native vs elm".padStart(15));
console.log("-".repeat(73));
for (const r of rows) {
  console.log(r.name.padEnd(16) + String(r.size).padStart(9) + fmt(r.elm) + fmt(r.ecoJs) + fmt(r.ecoNative) + ratio(r));
}
fs.writeFileSync(path.join(build, "results.json"), JSON.stringify({ warmup: opts.warmup, runs: opts.runs, workloads: rows }, null, 2) + "\n");
console.log(`\nwrote ${path.relative(process.cwd(), path.join(build, "results.json")) || "build/results.json"}`);

if (problems.length) {
  console.error("\n" + problems.map((p) => `PROBLEM ${p}`).join("\n"));
  process.exit(1);
}
