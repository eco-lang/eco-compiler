# Compute benchmarks

Pure-computation benchmarks (no IO) for comparing eco with the official Elm compiler. Each
workload in `src/` is a module exposing `bench : Int -> Int` that uses only `elm/core`, so the same
source builds with both compilers.

## Run the comparison

Needs `eco`, `elm` (0.19.1) and `node` on the PATH:

    node run.mjs                         # build, then run every workload on every backend
    node run.mjs fib nbody --runs 25     # some workloads, more samples
    node run.mjs --skip-elm              # without the official compiler

The table shows, per workload, the median time in milliseconds on the official compiler's
JavaScript (`elm`), eco's JavaScript (`eco-js`) and eco's native code (`eco-native`), and how many
times faster eco native is than `elm`. Every backend must compute the same result, and at the
default sizes the known one; otherwise `run.mjs` exits with status 1. All figures also go to
`build/results.json`. Set `ECO` or `ELM` to use binaries that are not on the PATH.

eco times itself with `Time.now`, which has 1 ms resolution; the official build is timed by
`run.mjs` with `process.hrtime`.

## eco only

    eco make src/Bench.elm --output=bench
    ./bench                              # all workloads, as a table
    ./bench --list                       # the workloads and what each one stresses
    ./bench --print nbody=1000           # a standard benchmark's usual text output

## Layout

- `src/`: the workloads, and `Bench.elm`, the eco/system program that times them.
- `elm/`: the project for the official compiler; `ElmBench.elm` runs any workload through ports.
- `run.mjs`: builds all three, runs them, checks the results and prints the table.

The first nine workloads come from the alm compute benchmarks; nbody, spectral-norm,
fannkuch-redux, nsieve, merkletrees, lru and fasta from the Programming Language Benchmarks suite
(each builds that suite's exact text output and returns its checksum); n-queens counts the
solutions of the n-queens puzzle.
