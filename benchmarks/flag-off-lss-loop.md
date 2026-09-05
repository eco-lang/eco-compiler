# LSS flag-off loop — experiment protocol

Measures, for each cumulative LSS flag-off level, how much the LSS optimizations
buy in the compiler's **own** runtime: a reference compiler built with no LSS
optimizations applied to it (subst engine) is compared against a compiler built
by the LSS pipeline at that flag level, both doing the same native self-compile.

Everything here is native. **Never measure on the JS build** — 13:58/10.1 GB
native vs 31:13/11.8 GB under node, and the JS path needs
`--max-old-space-size=16384` to finish at all.

## 0. One-time setup — the "standard" compiler

Built once, reused by every iteration's Run standard.

```bash
cd /work/build/compiler/build-kernel
SEED=./bin/eco-native-probe                      # any working native compiler
BOOT=/work/build/runtime/src/codegen/eco-boot-native

rm -rf eco-stuff
ECO_MONO_ENGINE=subst $SEED make --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/std-subst.mlir \
    /work/compiler/src/Terminal/Main.elm

$BOOT bin/std-subst.mlir -o bin/eco-std
```

`bin/eco-std` is the standard compiler. The seed binary only *emits* the .mlir;
output is a function of source + config, not of the compiling binary (that is
the bootstrap fixed-point property), so a slightly stale seed is fine.

## 1. The loop

Work **backwards from flag 31 to flag 1** of the LSS flag list. Once a flag is
turned off it **stays off** for every later iteration, so iteration N runs with
flags N..31 off.

For each flag N:

1. Add flag N to the cumulative off-set.
2. **Run standard** — `bin/eco-std` self-compiles under solver + LSS with the
   off-set applied. Record metrics. Lower the result:
   `eco-boot-native bin/iN-std.mlir -o bin/eco-iN`.
3. **Run optimized** — `bin/eco-iN` self-compiles under solver + LSS with the
   **same** off-set applied. Record metrics.

Both runs of an iteration use an identical LSS configuration. The only thing
that differs is which binary is doing the compiling — that is the whole point:
Run standard prices the LSS analysis, Run optimized prices what the analysis
bought.

### Per-run command

```bash
cd /work/build/compiler/build-kernel
rm -rf eco-stuff                                  # MANDATORY, see hygiene
env ECO_MONO_ENGINE=solver <OFF_SET_ENV> \
  /usr/bin/time -v -o <tag>.time \
  <COMPILER> make --optimize \
      --kernel-package eco/compiler \
      --local-package eco/kernel=/work/eco-kernel-cpp \
      --output=bin/<tag>.mlir \
      /work/compiler/src/Terminal/Main.elm \
  > <tag>.stdout 2> <tag>.stderr
```

`flag-off-lss-run.sh <N>` does one full iteration (both runs plus the
lowering). `flag-off-lss-run.sh all` runs every effective iteration, 31 → 1.

## 2. Metrics recorded

Two records per iteration (one Run standard, one Run optimized), five metrics
each.

**Record them in tabular form in a file under `/work/`.** The runner does this
automatically, on every recorded run:

- `/work/flag-off-lss-results.md` — the table to read. One row per compiler
  run (standard then optimized within each iteration), plus the reference
  build's row and the cumulative off-set per iteration. Regenerated from
  scratch after every run, so it never drifts from the data.
- `/work/benchmarks/flag-off-lss-loop.tsv` — the same records as TSV, appended
  one line per run. This is the source of truth the table is rendered from.

Never hand-edit either file; add rows only by running an iteration, so a
number in the table always has a `<tag>.time` / `<tag>.stdout` pair behind it.

The five metrics:

| Metric | Source | Line |
|---|---|---|
| Wall time | `<tag>.time` | `Elapsed (wall clock) time` |
| Max RSS | `<tag>.time` | `Maximum resident set size (kbytes)` |
| Minor GCs | `<tag>.stdout` | `Minor GC cycles:` |
| Major GCs | `<tag>.stdout` | `Major GC cycles:` |
| Promoted MB | `<tag>.stdout` | `totals: promoted N (X MiB)` |

The GC banner goes to **stdout** at normal exit (`ENABLE_GC_STATS`, ON for the
`build` / RelWithDebInfo preset — confirmed `ECO_GC_STATS:BOOL=ON` in
`build/CMakeCache.txt`). A Release-preset runtime prints nothing.

## 3. The flag list and its off-switch

Order = order added to the codebase. Iteration N turns off row N.

| N | Flag | Off switch | Default |
|---|------|-----------|---------|
| 31 | `stageAnchor.demandFill` | `ECO_MONO_LSS_STAGE_ANCHOR_DEMAND_FILL=0` | **off** |
| 30 | `stageAnchor.rowFill` | `ECO_MONO_LSS_STAGE_ANCHOR_ROW_FILL=0` | **off** |
| 29 | `flowConnect` | `ECO_MONO_LSS_FLOW_CONNECT=0` | on |
| 28 | `settle.varLambda` | `ECO_MONO_LSS_VAR_LAMBDA=0` | on |
| 27 | `settle.varCtorRows` | `ECO_MONO_LSS_VAR_CTOR_ROWS=0` | on |
| 26 | `settle.varSucc` | `ECO_MONO_LSS_VAR_SUCC=0` | on |
| 25 | `destrAnno` | `ECO_MONO_LSS_DESTR_ANNO=0` | on |
| 24 | `rsTop` | `ECO_MONO_LSS_RS_TOP=0` | on |
| 23 | `argPoints` | `ECO_MONO_LSS_ARG_POINTS=0` | **off** |
| 22 | `injTotal` | `ECO_MONO_LSS_INJ_TOTAL=0` | on |
| 21 | `refPapSpine` | `ECO_MONO_LSS_REF_PAP_SPINE=0` | on |
| 20 | `rootFold` | `ECO_MONO_LSS_ROOT_FOLD=0` | on |
| 19 | `regIdentity` | `ECO_MONO_LSS_REG_IDENTITY=0` | on |
| 18 | `sigRootIdentity` | `ECO_MONO_LSS_SIG_ROOT_ID=0` | on |
| 17 | `papMembers` | `ECO_MONO_LSS_PAP_MEMBERS=0` | on |
| 16 | `refIdentity` | `ECO_MONO_LSS_REF_IDENTITY=0` | on |
| 15 | `qSolve` | `ECO_MONO_LSS_QSOLVE=0` | **off** |
| 14 | `arrowSolverRoots` | `ECO_MONO_LSS_ARROW_ROOTS=0` | **off** |
| 13 | `arrowIdentity` | `ECO_MONO_LSS_ARROW_ID=0` | on |
| 12 | `postSettleDevirt` | `ECO_MONO_LSS_DEVIRT_POST=0` | on |
| 11 | `layoutQualMembers` | `ECO_MONO_LSS_LAYOUT_QUAL=0` | on |
| 10 | `sigFlow` | `ECO_MONO_LSS_SIG_FLOW=0` | on |
| 9 | `groundStandalones` | `ECO_MONO_LSS_GROUND=0` | on |
| 8 | `muTie` | `ECO_MONO_LSS_MU_TIE=0` | on |
| 7 | `spineArity` | `ECO_MONO_LSS_SPINE_ARITY=0` | **off** |
| 6 | `devirtFnGlobals` | `ECO_MONO_LSS_DEVIRT_FN=0` | on |
| 5 | `keyedGlobals` | `ECO_MONO_LSS_KEYED_GLOBALS=""` | non-empty |
| 4 | `maxSpecsPerGlobal` | *already off* (0 = unlimited) | 0 |
| 3 | `keyed` | `ECO_MONO_LSS=unkeyed` | on |
| 2 | `maxSetSize` | *already off* (0 = unlimited) | 0 |
| 1 | `enabled` | `ECO_MONO_LSS=0` | on |

`enabled` and `keyed` share one env var: from iteration 3 onward the off-set
carries `ECO_MONO_LSS=unkeyed`, and at iteration 1 that is replaced by
`ECO_MONO_LSS=0`.

### Iterations that change nothing — SKIPPED

Eight of the 31 flags are already at their off value in `defaultLss`
(`compiler/src/Compiler/Eco/Config.elm`), so those iterations would re-run the
previous configuration:

- **31, 30, 23, 15, 14, 7** — booleans that ship default-off.
- **4, 2** — `maxSpecsPerGlobal` / `maxSetSize`, where `0` *is* "no limit";
  turning a cap off is a no-op, turning one *on* would be the change.

**Decision: skip them.** The runner refuses them with an explanation;
`flag-off-lss-run.sh <N> --force` measures one anyway.

**Exception: 31 is kept.** It is a no-op like the rest, but its pair is the
all-defaults baseline that every later iteration is read against — without it
the first recorded level is "defaults minus flowConnect" and there is no
reference point. It is also the setup check that proves the harness works.

That leaves 24 iterations:

    31 29 28 27 26 25 24 22 21 20 19 18 17 16 13 12 11 10 9 8 6 5 3 1

The cost of skipping: identical repeat configurations were the experiment's
only noise estimate, so there is no measured run-to-run variance to compare
differences against. If a later iteration shows a small delta and it matters
whether it is real, re-run that same level with `--force` on a skipped index
to get a same-config repeat.

## 4. Hygiene — non-negotiable

- **`rm -rf eco-stuff` before every measured run.** The project cache is
  `<root>/eco-stuff/<version>`. Run standard and Run optimized in one iteration
  share a config hash, so a warm cache would let the second run skip work and
  fabricate a win.
- **Strictly serial.** The box has 15 GB RAM and 15 GB swap; peak RSS is
  ~11 GB. Two concurrent self-compiles will swap and destroy every timing.
  Concurrent runs also corrupt the `~/.eco` typed-artifact cache.
- **All censuses off.** Leave `ECO_MONO_LSS_REPORT`, `ECO_MONO_LSS_QCENSUS`,
  `ECO_MONO_LSS_ARROW_CENSUS`, `ECO_DISPATCH_STATS`, `ECO_CALL_CENSUS` unset.
  Census volume moves wall and GC counts; it is not what is being measured.
- **Do not touch `ECO_HEAP_CONFIG`.** A non-default heap changes major-GC
  counts by an order of magnitude, and majors are one of the recorded metrics.
- Nothing else heavy on the machine while a run is in flight.
- Compare only same-source arms. Same-day baselines drift; every number here
  must come from this one source tree at HEAD (`218d1c77`).

## 5. Provenance

- Flag list and defaults: `compiler/src/Compiler/Eco/Config.elm:233`
  (`LssConfig`) and `defaultLss`; env overrides in
  `compiler/src/Builder/Eco/Config.elm`.
- Addition order derived from `gitlog.txt`, cross-checked against the
  `LssConfig` field order.
- Self-compile command copied from bootstrap Stage 7a,
  `compiler/CMakeLists.txt:494`.
