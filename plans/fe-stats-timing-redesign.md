# Front-end timing stats redesign

## Goal

Replace the ad-hoc `[crawl]/[check]/[build]/[phase]` per-module stderr tracing and the mono/global-opt/MLIR codegen frames with a structured timing-stats system gated behind a CLI flag.

Specifically:

- Per-module timings (crawl, check, build) accumulated into log-spaced histograms across the whole module set, plus the five slowest modules per stage.
- Per-phase wall-clock timings for the six top-level front-end phases.
- A total front-end wall-clock measured from entry to exit of `Make.run`. No attempt is made to reconcile this against the sum of phases — we report what we measure, even if imperfect.
- One-line "Starting <phase>..." messages on stderr at each phase boundary.
- Everything gated on a single CLI flag (`--stats`, default off) on `eco make`.
- A pretty-printed summary at the end of `make` when the flag is set.

## Non-goals

- Replacing the user-facing build progress output (Bucket A in the inventory): the `Compiling …`, `\rCompiling (N)`, `Success!`, `Dependencies ready!`, install/uninstall/bump/init/repl/format output all remain untouched.
- Per-pass timing inside monomorphization, global optimization, or MLIR codegen (the "  Phase 1…", "  Phase 2…", "  Specialization (worklist)…" lines go away with no replacement).
- Plumbing stats into commands other than `eco make`.
- Persisting stats to a file or producing machine-readable output (JSON, CSV).

## Current state

The reference inventory (Bucket B and C in the most recent transcript) lists exactly:

- **Bucket B — verbose phase tracing (delete)**
  - `Builder/Build.elm` L302 `[phase] crawl done; dispatching N modules to checkModule`
  - `Builder/Build.elm` L581 `[crawl] <name>`
  - `Builder/Build.elm` L802 `[check] <name> <branchTag>`
  - `Builder/Build.elm` L1465 `[build] compile <name>  (…)`
  - `Builder/Reporting.elm` L338 `[deps] verifying dependencies`
  - `Builder/Reporting.elm` L492 `[deps] N/M verified`
  - `Builder/Reporting.elm` L563 `[build] Compiling ...`
  - `Builder/Reporting.elm` L606 `[build] N modules done`
  - `Builder/Reporting.elm` L631 `[build] <finalMessage>`
  - `Compiler/Compile.elm` L165 (commented-out, delete the dead line)

- **Bucket C — mono/global-opt/MLIR codegen frames (delete + remove callback plumbing)**
  - `Builder/Generate.elm` L727, L738, L750, L757, L768, L775 + the `logStderr` helper at L785–787
  - `Compiler/Monomorphize/Monomorphize.elm` L118, L136, L143, L409–415 + `monomorphizeWithLog`'s `log` parameter
  - `Compiler/GlobalOpt/MonoGlobalOptimize.elm` L139, L146, L153, L160, L167 + `globalOptimizeWithLog`'s `log` parameter
  - `Compiler/Generate/MLIR/Backend.elm` L166, L171, L182 + the `stderrLog` helper at L158–159

After the rewrite, only six new stderr lines exist in the front end — the "Starting <phase>..." messages — and only when `--stats` is set.

## Proposed design

### FEStats data shape (new module `Builder/Eco/FEStats.elm`)

```elm
type alias FEStats =
    { startedAt   : Posix
    , phases      : Dict PhaseName PhaseStats
    , perModule   : Dict ModuleStage Histogram
    }

type PhaseName
    = PhaseDeps
    | PhaseLocal
    | PhaseMono
    | PhaseInlineSimplify
    | PhaseGlobalOpt
    | PhaseMlir

type ModuleStage = Crawl | Check | Build

type alias PhaseStats =
    { startedAt : Posix
    , endedAt   : Posix
    , wallMs    : Float
    }

type alias Histogram =
    { buckets : Array Int                       -- 13 slots, log2 ms boundaries starting at 10 ms
    , count   : Int
    , sumMs   : Float
    , minMs   : Float
    , maxMs   : Float
    , topSlow : List ( ModuleName.Raw, Float )  -- descending by ms, length ≤ 5
    }
```

- Bucket boundaries (upper edges, ms): `[10, 20, 40, 80, 160, 320, 640, 1280, 2560, 5120, 10240, 20480, +∞]` — 13 slots. Bucketing is `clamp 0 12 (floor (logBase 2 (ms / 10)))` with sub-10ms samples falling into bucket 0.
- `topSlow` is maintained as a descending list: on each `recordModule`, splice the new `(name, ms)` into the list and truncate to length 5. Trivially cheap at 5 elements.
- A `Maybe (MVar FEStats)` handle is threaded through the front end. `Nothing` means the flag is off and every recorder is a no-op.

### Recorder API

```elm
type alias Handle = Maybe (MVar FEStats)

beginPhase   : Handle -> PhaseName -> Task x ()
endPhase     : Handle -> PhaseName -> Task x ()
withPhase    : Handle -> PhaseName -> Task x a -> Task x a
recordModule : Handle -> ModuleStage -> ModuleName.Raw -> Posix -> Posix -> Task Never ()
startTotal   : Handle -> Task x Posix
endTotal     : Handle -> Posix -> Task x ()
prettyPrint  : Handle -> Task Never ()
```

`withPhase` is the convenience wrapper: take a starting timestamp, log `Starting <phase>...` to stderr, run the task, take an ending timestamp, fold into the MVar.

### Timing source

Use `Time.now : Task x Posix`. Resolution of 1 ms is sufficient: the smallest histogram bucket is 10 ms, and anything under 10 ms collapses into bucket 0.

### CLI flag

Add a boolean flag to `eco make` in `Terminal/Main.elm` (or wherever `make` is wired):

- Long form: `--stats`
- No short form.
- Default: `False`.
- Applied to `eco make` only — not to `install`, `test`, `bump`, `init`, `repl`, `format`.

The flag is parsed into the existing `Make.Flags` (or equivalent) record and forwarded into the build driver.

### Phase instrumentation

| # | Phase                          | Wrapped call                                                  |
|---|--------------------------------|---------------------------------------------------------------|
| 1 | Dependency checking            | The verify/solve task in `Builder/Deps/Solver.elm` (or whoever orchestrates deps) |
| 2 | Parse / check / build (local)  | `Build.fromExposed` (or top-level `Build.build`)              |
| 3 | Monomorphization               | `runMonoOptPipeline` (Generate.elm L725)                      |
| 4 | Inline + simplify              | `runInlineSimplifyPhase` (Generate.elm L748)                  |
| 5 | Global optimization            | `runGlobalOptPhase` (Generate.elm L766)                       |
| 6 | MLIR code generation           | `streamMlirToWriter` invocation (Generate.elm L808-ish)        |

Total: captured at the entry to `Make.run` and at the very end after artifacts are flushed.

### Per-module histograms

Inside phase 2, three sample points:

- Crawl: bracket the work currently dispatched at `Build.elm` ~L581 with start/end timestamps; record on completion.
- Check: bracket the work currently dispatched at `Build.elm` ~L802.
- Build (local optimized IR): bracket the work currently dispatched at `Build.elm` ~L1465.

Each sample folds into the MVar via a single `recordModule Handle stage start end` call.

### Pretty-print format (stderr)

```
Front-end timing
=================
  dependency check       120 ms
  parse / check / build  450 ms  (123 modules)
      crawl   n=123  sum=246  min=1   max=45    [ ▂▆█▄▁ . . . . . . . . ]
              slowest: Foo.Bar 45ms, Baz.Qux 38ms, Boop 22ms, Wibble 18ms, Wobble 15ms
      check   n=123  sum=580  min=2   max=120   [ . ▃▆█▄▂ . . . . . . . ]
              slowest: ...
      build   n=123  sum=110  min=0   max=22    [ ▆█▃▁ . . . . . . . . ]
              slowest: ...
  monomorphization       300 ms
  inline + simplify       70 ms
  global optimization    100 ms
  MLIR codegen           220 ms
  ---------------------------
  Total (wall clock)     1260 ms
```

- Bar chars: `▁▂▃▄▅▆▇█` scaled to the max bucket.
- `slowest:` line shows the five slowest modules for that stage, descending by ms.
- All values in ms, integer-rounded.
- Phase rows and Total are printed as-measured. Total is wall-clock from entry to exit of `Make.run`; no reconciliation against the phase sum is attempted.

## Code changes

### New files

- `compiler/src/Builder/Eco/FEStats.elm` — data type, recorder API, pretty-printer.

### Modified files

- `compiler/src/Terminal/Main.elm` (or whatever wires `make` flags) — add `--stats` flag.
- `compiler/src/Terminal/Make.elm` (or wherever `make` is implemented) — initialize stats handle, wrap top-level Task, call `prettyPrint` at end.
- `compiler/src/Builder/Build.elm` — delete L302, L581, L802, L1465 stderr lines; thread stats handle through `Env`; bracket per-module work with timing samples; wrap whole `fromExposed` body with `withPhase PhaseLocal`.
- `compiler/src/Builder/Reporting.elm` — delete L338, L492, L563, L606, L631 stderr lines. (Leave `putStrFlush`/`stderrLine` helpers if still used by retained code, otherwise delete unused helpers.)
- `compiler/src/Builder/Generate.elm` — delete `logStderr` helper (L785–787) and the six call sites; thread the stats handle into the pipeline; wrap each of `runMonoOptPipeline`/`runInlineSimplifyPhase`/`runGlobalOptPhase`/MLIR streaming with `withPhase`.
- `compiler/src/Compiler/Monomorphize/Monomorphize.elm` — delete L118, L136, L143, L409–415; collapse `monomorphizeWithLog` back into `monomorphize` (drop the callback parameter and the export).
- `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` — delete L139, L146, L153, L160, L167; collapse `globalOptimizeWithLog` back into `globalOptimize`.
- `compiler/src/Compiler/Generate/MLIR/Backend.elm` — delete `stderrLog` helper (L158–159) and the three call sites.
- `compiler/src/Compiler/Compile.elm` — delete the dead commented line at L165.
- Any module that orchestrates deps (likely `Builder/Deps/Solver.elm`) — wrap the verify/solve task with `withPhase PhaseDeps`.

### No invariant impact

This change is logging-only. No representation, codegen, or runtime invariants from `design_docs/invariants.csv` are touched.

## Step-by-step implementation order

1. Create `Builder/Eco/FEStats.elm` with the types, MVar-backed recorder, no-op short-circuits, and pretty-printer. Unit tests for histogram bucketing, top-5 maintenance, and pretty-print formatting.
2. Add `--stats` flag to `eco make`. At this point the flag is parsed but unused.
3. Wire a `Maybe (MVar FEStats)` through `Make.run` (or equivalent): initialize on flag, plumb into the build driver, call `prettyPrint` at end (a no-op when handle is `Nothing`).
4. Add the total-time bracket at the very entry/exit of `Make.run`.
5. Wrap each of the six phases with `withPhase`. After each wrap, manually run `eco make --stats` against a small example and verify the "Starting …" line appears and a row appears in the summary.
6. Instrument the three per-module stages inside phase 2 (crawl/check/build). Verify histograms render and the `slowest:` lines list real module names.
7. Delete Bucket B (5 lines in Reporting.elm, 4 lines in Build.elm, 1 commented-out line in Compile.elm).
8. Delete Bucket C (6 lines + helper in Generate.elm, 4+1 lines + callback in Monomorphize.elm, 5 lines + callback in MonoGlobalOptimize.elm, 3 lines + helper in Backend.elm). Update callers that pass `logStderr` to drop the argument.
9. Sweep for dead helpers (`logStderr`, `stderrLog`, `stderrLine`, `putStrFlush`) — delete any that have no remaining callers; keep any still used by Bucket A.
10. Run `cmake --build build --target full` to confirm a clean build.
11. Compare `eco make` and `eco make --stats` runs: confirm the former is silent of all `[tag]`/`Phase …` noise, and the latter prints six "Starting" lines plus a final summary.

## Test strategy

- Unit-test `Builder/Eco/FEStats.elm`: bucket assignment for representative ms values; min/max/sum/count accounting; top-5 list maintenance (correct ordering, capping at 5, ties); pretty-print formatting (golden text).
- Integration-test: run `eco make` on the `compiler/examples/` tree both with and without `--stats`. Without the flag, stderr should contain only Bucket A output (no `[crawl]`, `[check]`, `[build]`, `[phase]`, `[deps]`, no `Phase N:`, no `Generate node functions`). With the flag, stderr should contain exactly six `Starting …` lines and a summary block.
- Concurrency smoke test: run on a multi-module project under `-j` parallelism and confirm the histograms' `count` equals the number of modules in the project, with no double-counts or drops.

## Resolved decisions

- CLI flag is `--stats`, `eco make` only.
- Six phases total: deps, parse/check/build, monomorphization, inline + simplify, global optimization, MLIR codegen. Inline+simplify is its own row.
- Histogram: 13 log2-spaced buckets starting at 10 ms (`[10, 20, 40, 80, 160, 320, 640, 1280, 2560, 5120, 10240, 20480, +∞]`).
- Each per-module histogram also tracks the five slowest modules for its stage.
- Timer source: `Time.now`.
- Total = wall-clock from entry to exit of `Make.run`. No reconciliation against phase sum — both numbers are printed as measured.
- Trim dead helpers (`logStderr`, `stderrLog`, `stderrLine`, `putStrFlush`) where no callers remain.
- Collapse `monomorphizeWithLog` / `globalOptimizeWithLog` back to `monomorphize` / `globalOptimize` (drop the callback parameter entirely).
