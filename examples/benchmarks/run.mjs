// Build and run the compute benchmarks on three backends and compare them:
//
//   elm         the official Elm compiler's JavaScript (elm/ElmBench.elm), run under node
//   eco-js      eco's JavaScript backend (src/Bench.elm), run under node
//
// Both JavaScript builds use --optimize. eco's native backend ignores it, so the native build
// does not pass it.
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
// Each workload runs on each backend in a process of its own, so no workload's timings depend on
// the ones before it. Every workload checks its own result (see Bench.elm); if a check fails on
// any backend the script exits with status 1. Times are medians in milliseconds after the warm-up
// runs. eco times itself with Time.now (1 ms resolution); the official elm build is timed with
// process.hrtime. The table goes to stdout and every figure to build/results.json.

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

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

// ---- official elm worker: `node run.mjs --elm-worker NAME SIZE --warmup W --runs R` -----------
//
// Runs one workload of build/elm-bench.js in this process (run.mjs starts one per workload) and
// prints `{ "ok": ..., "medianMs": ..., "fastestMs": ... }`. Timed with process.hrtime: the
// reply on the `fromBench` port ends each run, taken in the port callback itself.

if (process.argv[2] === "--elm-worker") {
  const [name, size, , warmup, , runs] = process.argv.slice(3);
  const elmJs = path.join(build, "elm-bench.js");
  let app;
  try {
    app = require(elmJs).Elm.ElmBench.init();
  } catch (e) {
    fail(`cannot load ${elmJs}: ${e.message} (build it first, without --no-build)`);
  }
  let pending = null;
  app.ports.fromBench.subscribe((value) => {
    const end = process.hrtime.bigint();
    const p = pending;
    pending = null;
    p?.({ value, end });
  });
  const once = () =>
    new Promise((resolve) => {
      pending = resolve;
      app.ports.toBench.send({ name, size: Number(size) });
    });
  const timed = async () => {
    const start = process.hrtime.bigint();
    const { value, end } = await once();
    if (value === null) fail(`elm-bench.js has no workload ${name}`);
    return { ok: value, ms: Number(end - start) / 1e6 };
  };
  for (let i = 0; i < Number(warmup); i++) await timed();
  const samples = [];
  let ok = true;
  for (let i = 0; i < Number(runs); i++) {
    const r = await timed();
    samples.push(r.ms);
    ok = ok && r.ok;
  }
  console.log("{");
  console.log(`  "ok": ${ok}, "medianMs": ${median(samples)}, "fastestMs": ${Math.min(...samples)}`);
  console.log("}");
  process.exit(0);
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
    run(ECO, ["make", "src/Bench.elm", "--optimize", `--output=${ecoJs}`], dir, "eco make (JavaScript)");
  }
  if (!opts.skipElm) {
    console.log("building official elm JavaScript ...");
    run(ELM, ["make", "ElmBench.elm", "--optimize", `--output=${elmJs}`], path.join(dir, "elm"), "elm make");
  }
}
fs.writeFileSync(ecoJsLauncher, "require('./bench.js').Elm.Bench.init();\n");

// ---- one workload on one backend, in a process of its own ----------------------------------
//
// Every (workload, backend) pair runs in a fresh process: a workload's timings cannot depend on
// what ran before it (heap left full, GC debt, JIT state), and the order of the workloads does not
// matter. Inside that process the warm-up runs and the timed runs share the heap and the JIT, which
// is what the warm-up is for.

// Run an eco build of Bench.elm and parse the JSON document it prints. Its stdout may carry other
// text after the document (a development build of eco prints GC statistics at exit), so read the
// document from its opening `{` line to its closing `}` line.
function runJson(command, commandArgs, label) {
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

const timing = ["--warmup", String(opts.warmup), "--runs", String(opts.runs)];

function runEco(command, prefix, w, label) {
  const report = runJson(command, [...prefix, "--json", ...timing, `${w.name}=${w.size}`], `${label} ${w.name}`);
  return report.workloads[0];
}

function runElm(w) {
  return runJson(process.execPath, [fileURLToPath(import.meta.url), "--elm-worker", w.name, String(w.size), ...timing], `elm ${w.name}`);
}

// ---- the workloads ---------------------------------------------------------------------------

const all = runJson(nativeBin, ["--list", "--json"], "eco native --list").workloads;
const chosen = opts.selected.length
  ? opts.selected.map((arg) => {
      const [name, size] = arg.split("=");
      const w = all.find((x) => x.name === name.toLowerCase());
      if (!w) fail(`unknown workload ${name} (see ${path.relative(process.cwd(), nativeBin) || "bench"} --list)`);
      const n = size === undefined ? w.size : Number(size);
      if (!Number.isInteger(n) || n < 1) fail(`${name} needs a whole-number size of at least 1`);
      return { name: w.name, size: n };
    })
  : all.map((w) => ({ name: w.name, size: w.size }));

const problems = [];
const rows = [];
for (const w of chosen) {
  console.log(`running ${w.name} (size ${w.size}) ...`);
  const e = opts.skipElm ? null : runElm(w);
  const js = opts.skipJs ? null : runEco(process.execPath, [ecoJsLauncher], w, "eco JavaScript");
  const n = runEco(nativeBin, [], w, "eco native");
  const failed = [["elm", e], ["eco-js", js], ["eco-native", n]].filter(([, r]) => r && !r.ok).map(([b]) => b);
  if (failed.length) problems.push(`${w.name} (size ${w.size}): check failed on ${failed.join(", ")}`);
  rows.push({
    name: w.name,
    size: w.size,
    ok: failed.length === 0,
    elm: e?.medianMs ?? null,
    ecoJs: js?.medianMs ?? null,
    ecoNative: n.medianMs,
  });
}

// ---- report ----------------------------------------------------------------------------------

const fmt = (x) => (x == null ? "-" : x.toFixed(x < 10 ? 2 : 1)).padStart(11);
const ratio = (r) => (r.elm == null || r.ecoNative === 0 ? "-" : `${(r.elm / r.ecoNative).toFixed(1)}x`).padStart(15);
console.log(`\nwarmup ${opts.warmup}, runs ${opts.runs}, one process per workload and backend; median ms, lower is better\n`);
console.log("workload".padEnd(16) + "size".padStart(9) + "check".padStart(7) + "elm".padStart(11) + "eco-js".padStart(11) + "eco-native".padStart(11) + "native vs elm".padStart(15));
console.log("-".repeat(80));
for (const r of rows) {
  console.log(r.name.padEnd(16) + String(r.size).padStart(9) + (r.ok ? "ok" : "WRONG").padStart(7) + fmt(r.elm) + fmt(r.ecoJs) + fmt(r.ecoNative) + ratio(r));
}
fs.writeFileSync(path.join(build, "results.json"), JSON.stringify({ warmup: opts.warmup, runs: opts.runs, workloads: rows }, null, 2) + "\n");
console.log(`\nwrote ${path.relative(process.cwd(), path.join(build, "results.json")) || "build/results.json"}`);

if (problems.length) {
  console.error("\n" + problems.map((p) => `PROBLEM ${p}`).join("\n"));
  process.exit(1);
}
