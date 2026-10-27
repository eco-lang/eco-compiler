---
status: done
updated: 2026-10-27
---

# Plan: one-command elm vs eco benchmark runs in examples/benchmarks

## Goal

A user of the distribution can compare the official Elm compiler with eco on the bundled compute
benchmarks with one command, given `eco`, `elm` (0.19.1) and `node` on the PATH:

    cp -R /usr/local/share/eco/examples ~/ && cd ~/examples/benchmarks
    node run.mjs

The script builds every backend, checks that all of them compute the same results, and prints one
table: official elm (JS), eco (JS) and eco (native), with eco native's speed-up over elm.

## Current state

- `examples/benchmarks/src/` holds 17 workloads, each a module exposing `bench : Int -> Int` that
  imports only `elm/core` (plus `Output.elm`, a core-only helper), and `Bench.elm`, an eco/system
  program that times them in-process with `Time.now` (1 ms resolution) and prints a table.
- Official `elm` cannot compile `Bench.elm` (it imports eco/system), and nothing runs the
  workloads under official elm or eco's JS backend.
- The bundle installs `examples/**/elm.json` and `*.elm` only.

## Design

```
examples/benchmarks/
  elm.json, src/      eco project (unchanged layout): the workloads + Bench.elm
  elm/elm.json        official-elm project: elm/core + elm/json, source dirs [".", "../src"]
  elm/ElmBench.elm    Platform.worker: {name, size} in on a port, bench result out on a port
  run.mjs             build, run, check, report (Node, no npm packages)
  README.md
```

1. **`Bench.elm --json`**: print one JSON document (the settings and, per workload, name, size,
   result, check, median and fastest ms) instead of the table. Exit codes unchanged.
2. **`elm/ElmBench.elm`**: the workloads compiled by official elm. Elm only compiles modules that
   are imported, so `Bench.elm` in `../src` is ignored. Its workload table (name -> `bench`) must
   list the same names as `Bench.elm`.
3. **`run.mjs`**:
   - Build into `build/`: `eco make src/Bench.elm --output=build/bench` (native),
     `eco make src/Bench.elm --output=build/bench.js` (eco JS), and from `elm/`,
     `elm make ElmBench.elm --optimize --output=../build/elm-bench.js`.
   - Run eco native and eco JS with `--json` and the same options; run official elm in-process:
     send each workload on the port and time with `process.hrtime` until the result returns,
     after the same warm-up count.
   - Check: every backend must agree per workload; the eco runs also check default-size
     checksums. Any disagreement or wrong result exits 1.
   - Report a table (workload, size, elm, eco-js, eco-native, eco-native vs elm) and write
     `build/results.json`.
   - Options: `--warmup N`, `--runs N`, workload names (`NAME` or `NAME=SIZE`), passed through;
     `--skip-elm` and `--skip-js` for machines without `elm` or to save time; `--no-build`.
   - A missing `eco`/`elm` gives a clear message, not a stack trace.
4. **Shipping**: add `*.mjs` and `README.md` to the three bundle install rules for
   `share/eco/examples`. `eco-system-examples` keeps compiling `Bench.elm` only.

## Known limits

- eco is timed in-process at 1 ms resolution, official elm with `hrtime`. The default sizes keep
  every workload well above 1 ms natively; a high-resolution monotonic clock in eco/system would
  remove the asymmetry (follow-up, not part of this plan).
- Official elm's `Int` is a JS double; every result is exact except float-sum (above 2^53), which
  still compares equal as a number.
- In the dev tree, the runtime prints GC statistics to stdout at exit; `run.mjs` reads only the
  JSON document, so it is unaffected.

## Verification

- `node run.mjs` end to end in the dev container, with official elm 0.19.1 installed temporarily
  under the scratch directory (not on the system), and with `--skip-elm`.
- A deliberately wrong expectation is reported and exits 1 (not committed).
- `eco-system-examples` still builds.

## Status

- 2026-10-15: plan written.
- 2026-10-15: built. `node run.mjs` passes end to end in the dev container (eco via a stand-in
  wrapper around the Stage-1 driver and eco-boot-native, official elm 0.19.1 from npm in the
  scratch directory): all 17 workloads agree on all three backends. A wrong official-elm result
  (patched into build/elm-bench.js, then restored) is reported and exits 1; a missing `elm` names
  `ELM`/`--skip-elm` and exits 2. `eco-system-examples` builds.
