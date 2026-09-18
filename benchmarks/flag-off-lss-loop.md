# LSS flag-off census — experiment protocol

**SOLO MODE since 2026-09-18.** Each run turns off **exactly one** flag; every
other flag stays at its default. The previous design was CUMULATIVE — flag N
off implied flags N+1.. also off — which priced the stack from the top down but
could never attribute an effect to one flag: a delta at level N was the joint
effect of everything above it, and any flag whose neighbours masked it read as
zero. Solo mode answers a different, simpler question, one flag at a time:

> **Does this flag do anything at all, and if so what does it buy and what does
> it cost?**

Everything here is native. **Never measure on the JS build** — 13:58/10.1 GB
native vs 31:13/11.8 GB under node, and the JS path needs
`--max-old-space-size=16384` to finish at all.

## 0. One-time setup — the instrument

The instrument is the **SHIPPING compiler**: the tree's own fixed-point MLIR,
lowered with dispatch site counters. Built once, reused by every row.

```bash
cd /work/build/compiler/build-kernel
BOOT=/work/build/runtime/src/codegen/eco-boot-native

# the tree's fixed-point artifact — bootstrap Stage 7a's output, or any
# verified all-flags-ON emit (they are byte-identical by construction)
ECO_LSS_DISPATCH_SITE_COUNTERS=1 \
    $BOOT bin/post-change.mlir -o bin/eco-opt-solo-census
```

The site-counter lowering is what makes `[dispatch-stats]` appear at all; a
plainly-lowered binary run with `ECO_DISPATCH_STATS=1` prints nothing and the
column reads `ERR`. `ECO_MONO_LSS_REPORT` needs no special lowering.

**Why the optimized compiler and not a subst build.** An earlier revision of
this protocol used a SUBST-engine instrument, on the reasoning that a compiler
with no LSS applied to it is a stable measuring stick whose own speed cannot
vary with the flags. That is true, and it is the wrong instrument anyway: it
carries no LSS stamps, so its `fast` column is pinned at 0 and every wall and
dispatch number it produces describes a compiler nobody ships. Those are
`call-stats`' REFERENCE numbers, not its BENCHMARK numbers. The cost of a flag
has to be priced on the compiler we actually ship, which is LSS-built — and
that compiler is also ~13 % faster, so the census is cheaper too.

**The instrument IS the baseline's own product.** All-flags-ON emits exactly
the MLIR the instrument was lowered from (the bootstrap fixed-point property),
so the baseline row doubles as a fixed-point check: if its `out.mlir` does not
come back byte-identical to `bin/post-change.mlir`, the instrument and the tree
have diverged and the series is invalid. The runner warns when that happens.

## 1. The loop

Work down the flag list, 32 → 1. **Iteration N turns off flag N and nothing
else.** There is no cumulative off-set and no ordering effect: iterations are
independent and may be run or re-run in any order.

For each flag N, ONE measured run — the FIXED instrument compiles the workload
with flag N off:

```bash
cd /work/build/compiler/build-kernel
rm -rf eco-stuff                                  # MANDATORY, see hygiene
env ECO_MONO_ENGINE=solver ECO_DISPATCH_STATS=1 ECO_MONO_LSS_REPORT=1 \
    <THE ONE OFF SWITCH> \
  /usr/bin/time -v -o fN.time \
  ./bin/eco-opt-solo-census make --optimize \
      --kernel-package eco/compiler \
      --local-package eco/kernel=/work/eco-kernel-cpp \
      --output=bin/fN-out.mlir \
      /work/compiler/src/Terminal/Main.elm \
  > fN.stdout 2> fN.stderr
```

Same binary every row ⇒ every difference is the flag. Each run yields the
`coverage:` and `lss globalopt:` lines (what the flag DID to the analysis), the
emitted artifact (whether the effect reached the code), and wall/GC/dispatch
**as the shipping compiler experiences them** (what the flag COSTS).

`flag-off-lss-solo.sh <N>` does one iteration. `flag-off-lss-solo.sh base` does
the all-flags-ON baseline. `flag-off-lss-solo.sh all` runs the baseline then
every flag, 32 → 1, and reminds you to re-run `base` as the drift check.

The cumulative runner `flag-off-lss-run.sh` is kept unchanged beside it: it is
the script that produced the archived cumulative data.

### What this census does NOT measure

**What a flag BUYS at run time.** That needs a second compiler per flag — lower
the row's `fN-out.mlir` and run the workload through THAT binary, which is
`call-stats`' benchmark arm at that flag level. It is deliberately out of scope
here: it costs a ~5 min lowering plus a ~9 min run per row, roughly tripling the
census. This census answers "does the flag do anything, and what does computing
it cost"; a flag that looks expensive and inert here is then a candidate for
that follow-up measurement, not a conclusion about run-time benefit.

## 2. Metrics recorded

One record per iteration, in four groups. All census lines land on **stderr**;
the GC banner is on **stdout**; wall/RSS come from `/usr/bin/time -v`.

- `benchmarks/flag-off-lss-solo-results.md` — the tables to read, regenerated
  from scratch after every run so they never drift from the data.
- `benchmarks/flag-off-lss-solo.tsv` — the same records as TSV, appended one
  line per run. This is the source of truth the tables are rendered from.

Never hand-edit either; add rows only by running an iteration, so every number
has an `fN.time` / `fN.stdout` / `fN.stderr` triple behind it.

| Group | Fields | Source line |
|---|---|---|
| **context** | wall, max RSS, minor GC, major GC, promoted MiB | `fN.time`, `fN.stdout` |
| **artifact** | `out.mlir` bytes, `vs base` | `stat` + `cmp` vs `bin/solo-base-out.mlir` |
| **lss-coverage** | positions, k1, kN, var, ⊤, part, coverage % | `coverage:` (stderr) |
| **lss-stamping** | dispatchUpgraded, stampedPapGlobal/Staged/PapPrefix, declined noInstance/blocked/shape/abiMismatch/bodyMismatch, devirtPost fn/ctor/noSpec/ambiguous, multiInstanceGroups | `lss globalopt:` (stderr) |
| **dispatch-stats** | sat, gen, typed, fast, distinct | `[dispatch-stats]` (stderr) |


Field names match `benchmarks/call-stats.md` groups 1–3 deliberately, so a solo
row can be read beside a call-stats row without a translation table. Group 4
(call-census) is NOT collected — it needs an `ECO_CALL_CENSUS=1` lowering and
answers a question this census does not ask.

### Reading the metrics — what each is actually measuring

This is the part to get right, because two of the groups describe the **analysis
result** and two describe the **instrument's own execution**, and confusing them
produces confident nonsense.

- **lss-coverage and lss-stamping are the flag's EFFECT.** They are a function of
  (source, flags) alone — what the LSS analysis concluded about the workload and
  what AbiCloning did with it. This is where "what does this flag actually do"
  gets its answer: if `var` rises and `k1` falls when a flag goes off, that flag
  was resolving those positions; if every cell is unchanged, it was not.
- **`vs base` is the verdict on whether the effect reached the artifact.** A flag
  can move coverage cells and still emit byte-identical MLIR — precision that
  no consumer used. `same` with moved coverage is a precise and useful finding:
  the flag computes something real that changes nothing downstream.
- **dispatch-stats is a COST metric measured on the SHIPPING compiler.** These
  count the dispatches the instrument performed while compiling, so they move
  with how much work the analysis did — on the binary we actually ship, with its
  real `fast` share. Its virtue is that it is **deterministic**: unlike wall time
  it has no run-to-run noise, which makes it the sharpest cost signal in the
  table. It is NOT what the flag buys — that is the out-of-scope measurement
  described in §1.
- **Minor GC and promoted MiB are the allocation cost**, and they track analysis
  volume honestly.
- **Wall is usable but not to the second** — ~±2 % run-to-run. Treat a smaller
  delta as noise. Prefer dispatch counts when the question is cost.
- **MAX RSS IS BIMODAL AND IS NOT A PER-FLAG METRIC.** Peak RSS lands in one of
  two modes (old-gen 8.9 vs 11.1 GB, a 2.15 GB gap) at *identical* allocation,
  major counts and nursery settings. A single run's RSS says which mode the GC
  happened to land in, not what the flag cost. A 2026-09-03 claim that
  `injTotal` costs +2.1 GB was retracted for exactly this reason. Record it —
  it is free — but draw no per-flag conclusion from it without N≥3 per arm.

### Baseline discipline

The baseline (all flags ON) is the row every other row is read against, so it
carries the drift risk for the whole series. Run it **first and again last**.
If the two baselines disagree by more than the noise band, the series drifted
(machine state, thermal, an unnoticed concurrent job) and per-flag deltas below
that disagreement cannot be trusted.

## 3. The flag list and its off-switch

**Every row is default-ON**, so every row is a real iteration: turning it off
is always a change. Order = order added to the codebase; iteration N turns off
row N **and only row N**.

| N | Flag | The one off switch for this run | Default |
|---|------|---------------------------------|---------|
| base | *(none — all flags ON)* | *no env; the reference row* | — |
| 32 | `stamp.rootFoldDepth` | `ECO_MONO_LSS_ROOT_FOLD_DEPTH=0` | on |
| 31 | `stamp.useInjectPap` | `ECO_MONO_LSS_INSTANCE_QUAL_USE_INJECT_PAP=0` | on |
| 30 | `flow.litFacts` | `ECO_MONO_LSS_FLOW_LIT_FACTS=0` | on |
| 29 | `flow.accessFlow` | `ECO_MONO_LSS_FLOW_ACCESS_FLOW=0` | on |
| 28 | `flow.letOverlay` | `ECO_MONO_LSS_FLOW_LET_OVERLAY=0` | on |
| 27 | `stamp.useInject` | `ECO_MONO_LSS_INSTANCE_QUAL_USE_INJECT=0` | on |
| 26 | `stamp.papFast` | `ECO_MONO_LSS_PAP_FAST=0` | on |
| 25 | `stamp.flatPeel` | `ECO_MONO_LSS_FLAT_PEEL=0` | on |
| 24 | instanceQual (`stamp.enabled`) | `ECO_MONO_LSS_INSTANCE_QUAL=0` | on |
| 23 | `flow.connect` | `ECO_MONO_LSS_FLOW_CONNECT=0` | on |
| 22 | `settle.varLambda` | `ECO_MONO_LSS_VAR_LAMBDA=0` | on |
| 21 | `settle.varCtorRows` | `ECO_MONO_LSS_VAR_CTOR_ROWS=0` | on |
| 20 | `settle.varSucc` | `ECO_MONO_LSS_VAR_SUCC=0` | on |
| 19 | `destrAnno` | `ECO_MONO_LSS_DESTR_ANNO=0` | on |
| 18 | `rsTop` | `ECO_MONO_LSS_RS_TOP=0` | on |
| 17 | `injTotal` | `ECO_MONO_LSS_INJ_TOTAL=0` | on |
| 16 | `refPapSpine` | `ECO_MONO_LSS_REF_PAP_SPINE=0` | on |
| 15 | `rootFold` | `ECO_MONO_LSS_ROOT_FOLD=0` | on |
| 14 | `regIdentity` | `ECO_MONO_LSS_REG_IDENTITY=0` | on |
| 13 | `papMembers` | `ECO_MONO_LSS_PAP_MEMBERS=0` | on |
| 12 | `refIdentity` | `ECO_MONO_LSS_REF_IDENTITY=0` | on |
| 11 | `arrowSolverRoots` | `ECO_MONO_LSS_ARROW_ROOTS=0` | on |
| 10 | `arrowIdentity` | `ECO_MONO_LSS_ARROW_ID=0` | on |
| 9 | `postSettleDevirt` | `ECO_MONO_LSS_DEVIRT_POST=0` | on |
| 8 | `layoutQualMembers` | `ECO_MONO_LSS_LAYOUT_QUAL=0` | on |
| 7 | `sigFlow` | `ECO_MONO_LSS_SIG_FLOW=0` | on |
| 6 | `groundStandalones` | `ECO_MONO_LSS_GROUND=0` | on |
| 5 | `muTie` | `ECO_MONO_LSS_MU_TIE=0` | on |
| 4 | `devirtFnGlobals` | `ECO_MONO_LSS_DEVIRT_FN=0` | on |
| 3 | `keyedGlobals` | `ECO_MONO_LSS_KEYED_GLOBALS=""` | non-empty |
| 2 | `keyed` | `ECO_MONO_LSS=unkeyed` | on |
| 1 | `enabled` | `ECO_MONO_LSS=0` | on |

`enabled` and `keyed` share one env var, which in solo mode is simply set to the
value that row needs — `ECO_MONO_LSS=unkeyed` for row 2, `ECO_MONO_LSS=0` for
row 1. There is no interaction between them any more, because no off-set
accumulates.

### Knobs that are deliberately NOT rows

- **Censuses** — `lss.report`, `lss.qCensus`, `lss.arrowCensus`,
  `stamp.census`. Output-only, default-off, and §4 requires every census off for
  a timed run anyway.
- **The two numeric caps** — `maxSetSize` and `maxSpecsPerGlobal`. Both default
  to `0`, which *is* "no limit", so there is nothing to turn off; turning one
  *on* would be the change, and that is a different experiment (a budget sweep,
  not a flag census). They were rows 2 and 4 of the cumulative list and were
  always skipped there; in solo mode a row that cannot move has no reason to
  exist, so they are gone.
- **`stamp.maxInstances`** (`ECO_MONO_LSS_INSTANCE_QUAL_MAX`, default 8). A cap
  where `0` means UNLIMITED, so "off" turns *more* qualification on — the
  opposite of what this census measures. `instanceQual` (row 24) is the switch
  that disables the mechanism.

### History of this list

Until 2026-09-17 the list also carried seven default-OFF booleans that the loop
had to skip. They were deleted from the compiler outright together with the code
they gated (`plans/remove-default-off-lss-flags.md`): `spineArity`, `qSolve`,
`sigRootIdentity`, `argPoints`, `stageAnchor.rowFill`, `stageAnchor.demandFill`
and `flow.rowDefer`. With the two numeric caps also dropped as non-rows, what
remains is 32 flags that are all ON by default — which is precisely the
population this census is for.

### Series boundaries — when previous rows stop being comparable

A solo row is comparable only to rows taken with the SAME instrument binary and
the SAME census setting. Two boundaries exist so far:

1. **2026-09-18, census-off → census-on.** The first solo baseline
   (wall 8:37.65, no census columns) was taken on a plainly-lowered instrument
   with no censuses. Archived as
   `benchmarks/flag-off-lss-solo-censusoff-base.tsv`.
2. **2026-09-18, SUBST instrument → OPTIMIZED instrument.** The second baseline
   (wall 10:20.85, `fast=0`, `sat` 2.91e9) was taken on a subst-built
   instrument. Those are `call-stats`' REFERENCE numbers: a compiler with no LSS
   applied to it, which is not what we ship and not what a flag's cost should be
   priced against. Replaced by the shipping compiler as the instrument; archived
   as `benchmarks/flag-off-lss-solo-substarm-base.tsv`. A row from that series
   is comparable to a `call-stats` reference row, never to a benchmark row.
3. **The cumulative → solo boundary**, below.

### The recorded data from the cumulative experiment is NOT comparable

Row indices have been renumbered three times, the design has changed from
cumulative to solo, and the default build has both gained and lost flags. The
old series is archived as `benchmarks/flag-off-lss-loop-cumulative-ref35.tsv`
(with `flag-off-lss-loop-2026-09-04.tsv` before it) and its table as
`benchmarks/flag-off-lss-results-cumulative-ref35.md`; solo data goes to new files
(`flag-off-lss-solo.tsv`, `flag-off-lss-solo-results.md`) so neither can be
mistaken for the other. Do not read a solo row against a cumulative row.

## 4. Hygiene — non-negotiable

- **The two censuses are MANDATORY, not forbidden.** Every run sets
  `ECO_DISPATCH_STATS=1 ECO_MONO_LSS_REPORT=1`. This reverses the rule the
  cumulative protocol carried, and it costs ~19 % wall (this workload: 8:37
  census-off vs ~10:40 census-on). That tax is paid uniformly by every row
  including the baseline, so it cancels in per-flag comparisons — and it buys
  the columns that actually answer "what does this flag do". **Wall numbers from
  a census-on series are NOT comparable to a census-off one.**
- **The OTHER censuses stay off.** Leave `ECO_MONO_LSS_QCENSUS`,
  `ECO_MONO_LSS_CENSUS`, `ECO_MONO_LSS_ARROW_CENSUS`, `ECO_CALL_CENSUS` unset.
  `qCensus` in particular re-solves ~106k constraints per compile.
- **`rm -rf eco-stuff` before every measured run.** The project cache is
  `<root>/eco-stuff/<version>`. A config hash is per-flag-set, so consecutive
  iterations mostly key different entries — but the baseline and any repeat of
  it key the SAME entry, and a warm cache there would fabricate a win on the one
  row everything else is measured against.
- **Strictly serial.** The box has 15 GB RAM and 15 GB swap; peak RSS is
  ~11 GB. Two concurrent self-compiles will swap and destroy every timing.
  Concurrent runs also corrupt the `~/.eco` typed-artifact cache.
- **Do not touch `ECO_HEAP_CONFIG`.** A non-default heap changes major-GC
  counts by an order of magnitude, and majors are one of the recorded metrics.
- Nothing else heavy on the machine while a run is in flight.
- **One source tree per series.** Every row must come from the same compiler
  source, compiled by the same `bin/eco-std-solo`. If the tree changes mid-census,
  the series restarts — a solo row is only meaningful against a baseline taken on
  its own tree.
- **The measuring instrument must not change.** `bin/eco-std-solo` is built once
  in §0 and reused for every row. Rebuilding it part-way through makes earlier
  and later rows incomparable, which is the one way this design can silently
  produce nonsense.

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
- Noise bands quoted in §2: wall spread from the 2026-08-28 repeat series
  (std 13:56–14:31, opt 13:14–13:49); the bimodal-RSS finding and the retracted
  `injTotal` +2.1 GB claim are recorded in the same series' notes. Those were
  taken on an older tree, so treat the BANDS as indicative and re-derive them
  from this census's own two baseline rows.
