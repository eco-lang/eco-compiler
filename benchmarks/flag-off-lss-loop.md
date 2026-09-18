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

Work **backwards from flag 34 to flag 1** of the LSS flag list. Once a flag is
turned off it **stays off** for every later iteration, so iteration N runs with
flags N..34 off.

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
lowering). `flag-off-lss-run.sh all` runs every effective iteration, 35 → 1.

## 2. Metrics recorded

Two records per iteration (one Run standard, one Run optimized), five metrics
each.

**Record them in tabular form in a file under `/work/`.** The runner does this
automatically, on every recorded run:

- `benchmarks/flag-off-lss-results.md` — the table to read. One row per compiler
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
| 35 | *(none — all flags ON)* | *no env; the reference pair* | — |
| 34 | `stamp.rootFoldDepth` | `ECO_MONO_LSS_ROOT_FOLD_DEPTH=0` | on |
| 33 | `stamp.useInjectPap` | `ECO_MONO_LSS_INSTANCE_QUAL_USE_INJECT_PAP=0` | on |
| 32 | `flow.litFacts` | `ECO_MONO_LSS_FLOW_LIT_FACTS=0` | on |
| 31 | `flow.accessFlow` | `ECO_MONO_LSS_FLOW_ACCESS_FLOW=0` | on |
| 30 | `flow.letOverlay` | `ECO_MONO_LSS_FLOW_LET_OVERLAY=0` | on |
| 29 | `stamp.useInject` | `ECO_MONO_LSS_INSTANCE_QUAL_USE_INJECT=0` | on |
| 28 | `stamp.papFast` | `ECO_MONO_LSS_PAP_FAST=0` | on |
| 27 | `stamp.flatPeel` | `ECO_MONO_LSS_FLAT_PEEL=0` | on |
| 26 | `instanceQual` (`stamp.enabled`) | `ECO_MONO_LSS_INSTANCE_QUAL=0` | on |
| 25 | `flow.connect` | `ECO_MONO_LSS_FLOW_CONNECT=0` | on |
| 24 | `settle.varLambda` | `ECO_MONO_LSS_VAR_LAMBDA=0` | on |
| 23 | `settle.varCtorRows` | `ECO_MONO_LSS_VAR_CTOR_ROWS=0` | on |
| 22 | `settle.varSucc` | `ECO_MONO_LSS_VAR_SUCC=0` | on |
| 21 | `destrAnno` | `ECO_MONO_LSS_DESTR_ANNO=0` | on |
| 20 | `rsTop` | `ECO_MONO_LSS_RS_TOP=0` | on |
| 19 | `injTotal` | `ECO_MONO_LSS_INJ_TOTAL=0` | on |
| 18 | `refPapSpine` | `ECO_MONO_LSS_REF_PAP_SPINE=0` | on |
| 17 | `rootFold` | `ECO_MONO_LSS_ROOT_FOLD=0` | on |
| 16 | `regIdentity` | `ECO_MONO_LSS_REG_IDENTITY=0` | on |
| 15 | `papMembers` | `ECO_MONO_LSS_PAP_MEMBERS=0` | on |
| 14 | `refIdentity` | `ECO_MONO_LSS_REF_IDENTITY=0` | on |
| 13 | `arrowSolverRoots` | `ECO_MONO_LSS_ARROW_ROOTS=0` | on |
| 12 | `arrowIdentity` | `ECO_MONO_LSS_ARROW_ID=0` | on |
| 11 | `postSettleDevirt` | `ECO_MONO_LSS_DEVIRT_POST=0` | on |
| 10 | `layoutQualMembers` | `ECO_MONO_LSS_LAYOUT_QUAL=0` | on |
| 9 | `sigFlow` | `ECO_MONO_LSS_SIG_FLOW=0` | on |
| 8 | `groundStandalones` | `ECO_MONO_LSS_GROUND=0` | on |
| 7 | `muTie` | `ECO_MONO_LSS_MU_TIE=0` | on |
| 6 | `devirtFnGlobals` | `ECO_MONO_LSS_DEVIRT_FN=0` | on |
| 5 | `keyedGlobals` | `ECO_MONO_LSS_KEYED_GLOBALS=""` | non-empty |
| 4 | `maxSpecsPerGlobal` | *already off* (0 = unlimited) | 0 |
| 3 | `keyed` | `ECO_MONO_LSS=unkeyed` | on |
| 2 | `maxSetSize` | *already off* (0 = unlimited) | 0 |
| 1 | `enabled` | `ECO_MONO_LSS=0` | on |

`enabled` and `keyed` share one env var: from iteration 3 onward the off-set
carries `ECO_MONO_LSS=unkeyed`, and at iteration 1 that is replaced by
`ECO_MONO_LSS=0`.

### Knobs that are deliberately NOT rows

- **Censuses** — `lss.report`, `lss.qCensus`, `lss.arrowCensus`,
  `stamp.census`. Output-only, default-off, and §4 requires every census off
  for a timed run anyway.
- **`stamp.maxInstances`** (`ECO_MONO_LSS_INSTANCE_QUAL_MAX`, default 8). Like
  `maxSetSize` / `maxSpecsPerGlobal` it is a cap where `0` means UNLIMITED, so
  "turning it off" turns *more* qualification on — the opposite of what this
  loop measures. `instanceQual` (row 26) is the switch that disables the
  mechanism.

### Iterations that change nothing — SKIPPED

**Only the two numeric caps.** `maxSpecsPerGlobal` (4) and `maxSetSize` (2) are
already at their off value in `defaultLss` (`0` *is* "no limit"), so turning a
cap off is a no-op; turning one *on* would be the change. The runner refuses
them with an explanation; `flag-off-lss-run.sh <N> --force` measures one anyway.

**Every other row is a real iteration.** Until 2026-09-17 seven rows were
default-off booleans that the loop had to skip; they were deleted from the
compiler outright, with their gated code
(`plans/remove-default-off-lss-flags.md`), so the list no longer carries a knob
that cannot move. The retired seven were `spineArity`, `qSolve`,
`sigRootIdentity`, `argPoints`, `stageAnchor.rowFill`, `stageAnchor.demandFill`
and `flow.rowDefer` — each measured neutral or negative, or never implemented;
that plan's §2 carries the evidence per flag.

**Iteration 35 is the all-flags-ON reference pair** (off-set `<none>`): the
compiler as shipped. Every other iteration is read against it, and its
`optimized` row is the fully-LSS-optimized compiler self-compiling.

That leaves 33 iterations:

    35 34 33 32 31 30 29 28 27 26 25 24 23 22 21 20 19 18 17 16 15 14 13 12
    11 10 9 8 7 6 5 3 1

**There is no longer a free no-op repeat.** A skipped boolean used to double as
the harness self-check and as the experiment's only run-to-run noise estimate.
Both now cost a real run: `flag-off-lss-run.sh 4 --force` (or `2`) re-runs the
*previous* level's configuration and is the way to get a same-config repeat.

### Renumbering — the recorded TSV is stale

Row indices are positions in an append-only list, and the list has been
renumbered twice in one day: seven flags were appended (the reference pair
moved 35 → 42), then seven older rows were deleted (35 again). Rows already in
`benchmarks/flag-off-lss-loop.tsv` were recorded under the FIRST numbering,
where 35 meant `<none>`; under this one 35 means `<none>` again but every row
between 5 and 34 has shifted. Those rows are not comparable to a new run in any
case — the default build has gained seven flags and lost seven since — so
**archive the TSV before the next run**, as the 2026-09-04 data was archived:

```bash
mv benchmarks/flag-off-lss-loop.tsv benchmarks/flag-off-lss-loop-ref35-v1.tsv
```

## 4. Hygiene — non-negotiable

- **`rm -rf eco-stuff` before every measured run.** The project cache is
  `<root>/eco-stuff/<version>`. Run standard and Run optimized in one iteration
  share a config hash, so a warm cache would let the second run skip work and
  fabricate a win.
- **Strictly serial.** The box has 15 GB RAM and 15 GB swap; peak RSS is
  ~11 GB. Two concurrent self-compiles will swap and destroy every timing.
  Concurrent runs also corrupt the `~/.eco` typed-artifact cache.
- **All censuses off.** Leave `ECO_MONO_LSS_REPORT`, `ECO_MONO_LSS_QCENSUS`,
  `ECO_MONO_LSS_CENSUS`, `ECO_MONO_LSS_ARROW_CENSUS`, `ECO_DISPATCH_STATS`,
  `ECO_CALL_CENSUS` unset.
  Census volume moves wall and GC counts; it is not what is being measured.
- **Do not touch `ECO_HEAP_CONFIG`.** A non-default heap changes major-GC
  counts by an order of magnitude, and majors are one of the recorded metrics.
- Nothing else heavy on the machine while a run is in flight.
- Compare only same-source arms. Same-day baselines drift; every number here
  must come from ONE source tree. **The 2026-09-04 run's data is archived in
  `benchmarks/flag-off-lss-loop-2026-09-04.tsv` and is NOT comparable
  row-by-row to the current TSV** — that tree predates LSS_038/039/040, and
  the corpus (the compiler's own source) has grown since.

## 5. Provenance

- Flag list and defaults: `compiler/src/Compiler/Eco/Config.elm:234`
  (`LssConfig`) and `defaultLss` (`Config.elm:900`); env overrides in
  `compiler/src/Builder/Eco/Config.elm` (`applyEnvOverrides`).
- `LssConfig` sat AT the runtime's 32-slot record GC-scan cap, which is why
  every flag added since 2026-09 lives in a SUB-RECORD: `LssFlowConfig`
  (`flow.*`), `LssSettleConfig` (`settle.*`), `LssStampConfig` (`stamp.*` —
  `instanceQual` is `stamp.enabled`). A new flag will be in one of those, not
  at top level. The 2026-09-17 removal took it to 27 fields, so there is slack
  again — but the sub-record convention stands.
  (`LssStageAnchorConfig` was the fourth sub-record; it went with its two
  flags.)
- Addition order derived from the record field order (`LssConfig` first, then
  each sub-record in field order), cross-checked against the ship dates in the
  field doc comments.
- Self-compile command copied from bootstrap Stage 7a,
  `compiler/CMakeLists.txt:494`.
