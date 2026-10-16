# Compute benchmarks

Pure-computation benchmarks (no IO) for comparing eco with the official Elm compiler. Each
workload in `src/` is a module exposing `bench : Int -> Bool` that uses only `elm/core`, so the
same source builds with both compilers. `bench` does the work at the given size and checks its
own result.

The default sizes make every workload take at least 200 ms on the official compiler's
JavaScript, each run in a process of its own.

## How results are checked

Each workload checks itself as strongly as it can, at whatever size it runs:

- Exactly at every size, by a closed form or an independent recomputation: fib, binary-trees,
  list-map, list-filter, list-fold, dict, sort, float-sum (within its rounding error) and
  merkletrees. spectral-norm must lie within `6 / n^3` of its limit (a bound measured with a C
  program from 1 to 5,500).
- Exactly against a table that covers every feasible size: fannkuch-redux (1-12 items, from the
  standard C algorithm), nsieve (2-14, from a separate sieve) and n-queens (up to 18, OEIS
  A000170). Larger sizes fail the check.
- Exactly at the sizes in a table, and by an invariant elsewhere: mandelbrot (counts from a C
  program; elsewhere a plausible share of the grid), nbody (published outputs; elsewhere the
  published initial energy and energy conservation), lru (elsewhere hits + misses = rounds) and
  fasta (elsewhere the output's length). At sizes outside their tables these four can pass a
  subtly wrong result.

The check runs inside the timed region, and costs little next to the work.

## Run the comparison

Needs `eco`, `elm` (0.19.1) and `node` on the PATH:

    node run.mjs                         # build, then run every workload on every backend
    node run.mjs fib nbody --runs 25     # some workloads, more samples
    node run.mjs --skip-elm              # without the official compiler

The table shows, per workload, the median time in milliseconds on the official compiler's
JavaScript (`elm`), eco's JavaScript (`eco-js`) and eco's native code (`eco-native`), and how many
times faster eco native is than `elm`. If a workload's check fails on any backend, `run.mjs`
exits with status 1. All figures also go to `build/results.json`. Set `ECO` or `ELM` to use
binaries that are not on the PATH.

`run.mjs` runs each workload on each backend in a process of its own, so a workload's timings do
not depend on the workloads before it (a heap left full, GC debt, JIT state) or on their order.
Inside that process, the warm-up runs and then the timed runs share the heap and the JIT, which
is what the warm-up is for. `./bench` on its own runs all its workloads in one process.

eco times itself with `Time.now`, which has 1 ms resolution; the official build is timed by
`run.mjs` with `process.hrtime`.

## eco only

    eco make src/Bench.elm --output=bench
    ./bench                              # all workloads, as a table
    ./bench --list                       # the workloads and what each one stresses
    ./bench --print nbody=1000           # a standard benchmark's usual text output
    ./bench --json fib=30                # results as JSON (`--list --json` lists the workloads)

## Layout

- `src/`: the workloads, and `Bench.elm`, the eco/system program that times them.
- `elm/`: the project for the official compiler; `ElmBench.elm` runs any workload through ports.
- `run.mjs`: builds all three, runs each workload on each in a fresh process, and prints the
  table.

The first nine workloads come from the alm compute benchmarks; nbody, spectral-norm,
fannkuch-redux, nsieve, merkletrees, lru and fasta from the Programming Language Benchmarks suite
(each builds that suite's exact text output, which `--print` shows); n-queens counts the
solutions of the n-queens puzzle.
