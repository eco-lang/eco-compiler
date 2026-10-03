# Backend lowering optimization loop: experiment protocol

This loop makes the backend lowering faster, one change at a time. The backend lowering is
`eco-boot-native <compiler>.mlir -o <exe>`: MLIR pipeline, then MLIR→LLVM translation, then
RS4GC, LLVM opt, object emission and link. The generated program must stay correct.

The step list is in `plans/backend-lowering-optimization.md`. That plan orders the steps by
expected win.

**Wall time is the primary measure.** Each step is ONE lowering run. Repeated runs and A/B
interleaving are not needed, because this box has no measurable day-to-day drift for this
workload.

## 1. The workload

| | |
|---|---|
| input | `build/compiler/build-kernel/bin/ecoGCR.mlir`, the compiler's own source as MLIR bytecode, 13,249,839 B, produced 2026-10-01 by `eco-optFHR`. It is FIXED for the whole series: never regenerate it mid-series. |
| tool | `build/runtime/src/codegen/eco-boot-native`, rebuilt with the step's change |
| flags | none: the shipped defaults (`-O 2`, `--parallel-opt=none`, `--split-codegen` auto, `--lazy-split`, `--lowering-stats` on). A step that changes a DEFAULT edits the default in source, so the command line never changes. |
| output | a native compiler ELF, about 92 MB |

## 2. The loop: one iteration per step

The reference is the BEST row so far: the baseline, or the last kept step if one beat it. Each
candidate is judged against that reference. A reverted step never becomes the reference, and the
reference is never re-measured.

1. `benchmarks/lss-loop-snap.sh verify <ref>`: the live tree must match the reference snapshot.
2. Implement the step. Then run `lss-loop-snap.sh snap try-<id> "<short name>"`, and
   `lss-loop-snap.sh diff <ref> try-<id> > snapshots/lss-loop/step-<id>.patch`.
3. Build: `cmake --build build --target eco-boot-native`. Build every target only if the step
   touched runtime archives that the link step pulls in (see memory
   `relower-needs-all-runtime-libs`).
4. Measure with ONE run (§3).
5. Verdict (§4). Write the entry (§5) whatever the verdict.
   - **Win:** run `lss-loop-snap.sh snap keep-<id> "<short name>"`. That snapshot becomes `<ref>`.
   - **Loss or flat-with-added-complexity:** run `lss-loop-snap.sh restore <ref>`, then
     `verify <ref>`. Run `cmake --preset build` if the step added or removed files.

**Correctness checks are batched, not run per step.** Steps are kept on wall time alone. The
gates in §6 run once, at the end of the series or when the user asks, against the final kept
tree. If a gate fails, bisect over the `keep-*` snapshots to find the step that broke it.

**Two cheap sanity checks DO run on every step**, because they cost nothing:
- `rc == 0`, and the output ELF exists and is about the expected size. A crashed run is fast and
  would read as a win.
- The `--lowering-stats` banner printed in full.

## 3. Commands (run from `/work`)

```bash
ulimit -c 0
BK=build/compiler/build-kernel
BOOT=build/runtime/src/codegen/eco-boot-native
IN=$BK/bin/ecoGCR.mlir
L=stats-backend-opt            # logs, kept for the whole series
ID=<step id>                        # e.g. base, B1, B2a

/usr/bin/time -v -o $L/$ID.time $BOOT $IN -o $BK/bin/eco-be-$ID > $L/$ID.stats 2>&1
echo rc=$?; ls -la $BK/bin/eco-be-$ID
grep -E "Elapsed|User time|Maximum resident" $L/$ID.time
cat $L/$ID.stats                    # the full stats banner, quoted verbatim in the entry
rm -f $BK/bin/eco-be-$ID            # once the entry is written (keep the base binary)
```

Nothing else may run on the machine during a measured run. This includes no `perf` attached and
no concurrent build or test. A profiling run is a separate, labelled, untimed leg. For example:

```bash
perf record -F 25 --call-graph dwarf,32768 -o $L/$ID.perf.data -- $BOOT $IN -o /tmp/x
```

The `--time-passes` flag crashes (an LLVM `Timer` assertion) under parallel partition emit, and
the whole-module opt pipeline has no pass instrumentation. Attribute opt time with `perf`
call stacks (`PassModel<…, PassName>` frames) instead.

## 4. The win rule

- **Wall decreased beyond the noise floor ⇒ WIN.** The noise floor is 2 s, or 1 % of wall
  if that is larger.
- **Wall within the noise floor ⇒ FLAT.** A flat step that DELETES code or work ships. A flat
  step that ADDS complexity is reverted.
- **Wall increased beyond the noise floor ⇒ LOSS**, and the step is reverted.
- Read user CPU and max RSS as secondary stats. A step that buys wall with a large RSS rise
  (more than +1 GB) says so in its entry; the box has 15 GB.
- A step that changes the GENERATED CODE, not just how fast it is produced, must also pass the
  recursive-tax check in §6 before the series closes. Examples: opt pipeline, inlining,
  `--parallel-opt`, codegen opt level. Mark it `codegen-changing` in its entry.

**Amendment 1 (2026-10-01, after step D1), from measured noise.**
The original 2 s floor was sized for a 210 s wall. After A1 the wall is about 60 s, and real data
now exists:
- **Wall:** the same tree measured twice gave 59.63 s and 60.17 s (`noise-B3b-rerun.*`), so
  run-to-run noise is about 0.5 s.
- **Serial phase timers are much tighter.** On unchanged code, the MLIR pipeline read 11.88,
  12.08 and 12.24 s across three runs (±0.2 s), and the drain read 16.64–17.09 s.

So, from step B2 on:
- **The noise floor is 1.0 s, or 1 % of wall if that is larger.**
- **Second WIN rule:** a step counts as a WIN when its wall did not increase beyond the floor
  AND the phase it targets improved by more than 3× that phase's observed spread. Quote both
  numbers in the entry.
- Wall stays the primary measure. A wall increase beyond the floor is still a LOSS, whatever
  the phase did.
- C2 (drain −2.4 s) was reverted under the old rule. It is re-tried under this one as
  step C2′.

## 5. Records

Each entry goes under §7 (newest last). Put the table first, then at most ten lines of prose:

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|

Quote the full `--lowering-stats` banner in a collapsed block under the entry. The §8 summary
table repeats each row's numbers only.

## 6. Batched correctness gates (end of series, `ulimit -c 0`, strictly serial)

1. **Bootstrap fixed point.** The lowered final compiler compiles the compiler source to
   `<x>.mlir`, and `cmp <x>.mlir ecoGCR.mlir` must match. Use the same command shape as the
   gc-opt loop's Phase 1.3: cold `eco-stuff`, `touch` the registry,
   `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1`.
2. **E2E:** `cmake --build build --target check`, which covers the C++-only backend changes.
   Use `--target full` if any step touched the Elm compiler.
3. **Unit tests:** `build/test/test`. Rebuild `ecoc` and `test` first: they link
   `libEcoPasses.a` separately from `eco-boot-native`.
4. **Recursive tax**, required if any step is `codegen-changing`. Self-compile the compiler with
   the final lowered binary, using the gc-opt loop's §2 Phase 2 command shape. Compare it with
   the same compiler lowered at the series base. The final binary may be at most 3 % slower.
5. **Determinism**, where a step touched ordering. Lower twice and compare at the IR level
   (`--emit=llvm`), not as ELFs: `-O2` lazy-split object emission is not byte-reproducible.

## 7. Runs

### Pre-loop history (2026-10-01): context only, not part of the series

These four fixes for repeated linear `module.lookupSymbol` scans went in before this loop
existed, so they are part of the base tree. They are listed here so the history is not lost.

| tree | wall | user CPU | max RSS | MLIR pipeline | whole-module opt | note |
|---|---|---|---|---|---|---|
| before the fixes | 10:40.97 (641 s) | 856.5 s | 6,892,912 kB | 450.2 s | 150.9 s | `EcoToLLVMPass` 277.6 s, `EcoListCursorPass` 141.4 s, `EcoListTemplatePass` 24.2 s |
| + `EcoToLLVM` string-literal slots and eval-descriptor lookups, `EcoListCursor` decls once | 3:57.62 (238 s) | 454.5 s | 6,892,560 kB | 49.0 s | 149.4 s | ELF byte-identical to the "before" ELF |
| + `EcoListTemplate` symbol-use index, CAF promote-decl flag | 3:30.77 under `perf` | 426.9 s | 6,875,544 kB | 19.1 s | 151.2 s | measured under `perf`, so not a clean number; the base row below replaces it |

### base: series baseline

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| base | 209.93 | — | 426.16 | 6,990,948 | 18.68 | 151.34 | 142.45 | baseline | — |

Snapshot `be-base`. Measured 2026-10-01 on an idle box (step 0a of the plan). It replaces a
provisional 215.83 s run that was taken while read-only agents were working; that run's whole
5.9 s difference was in the serial opt stage. Full banner: `stats-backend-opt/base.stats`.
Extract any row's cells with `stats-backend-opt/row.sh <id>`.

### 0b/0c: diagnostic legs (untimed)

One run: `ECO_ECO2LLVM_STATS=1 eco-boot-native -O 0 --emit=llvm ecoGCR.mlir` on the `be-base`
tree.

**0b. `EcoToLLVMPass` stages.** Stage 2 is parallel; every other stage is serial.

| stage | ms |
|---|---|
| 1. pre-scan + lowerAllocGroups | 71 |
| 2. Stage 0 signature + module conversion | 784 |
| 2b. pre-materialization | 838 |
| 3. Stage 2 per-function body conversion | 5,704 |
| 4. GC-strategy + shadow-root walks (epilogue) | 521 |
| 5. createGlobalRootInitFunction + unused-decl strip | 3,083 |

Stage 2 took 0.74 s in July, so it is now 7.7× slower. That points at plan step B1: the
assert-wrapped linear `lookupSymbol` calls run once per closure site. Stage 5 is the
`SymbolUserMap` strip (plan step B3b).

**0c. Unoptimized IR after RS4GC, by function family.** 8,357,113 instructions in total;
the `.ll` file is 710 MB.

| family | functions | instructions | share | statepoints |
|---|---|---|---|---|
| specs (`_$_N`) | 32,525 | 5,333,166 | 63.8 % | 140,964 |
| `$cap` variants | 10,233 | 1,672,379 | 20.0 % | 43,066 |
| other | 14,047 | 860,002 | 10.3 % | 25,393 |
| `__closure_wrapper_typed_*` | 16,081 | 258,209 | 3.1 % | 15,233 |
| `__closure_sat_*` | 25,274 | 233,337 | 2.8 % | 24,222 |

The sat thunks and typed wrappers are numerous but small, about 6 % between them. The
largest IR-volume target for plan step C1 is the `$cap` duplicates, at 20 %.

### A1: make `--parallel-opt=cgu` the default (plan A1)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| A1 | 68.75 | -141.18 | 453.34 | 6,894,632 | 18.94 | — | 157.16 | WIN (codegen-changing) | base |

Snapshot `try-A1` and `keep-A1`. The patch `step-A1.patch` is 76 lines.
- **Change:** `eco-boot-native` and `EcoNativeOptions` (so `eco make` too) now default to `cgu`. The `cgu` IPO prologue gets PostOrder and ReversePostOrder FunctionAttrs back, so the declarations each partition sees keep their inferred attributes.
- **Effect:** the 151 s serial whole-module `-O2` is gone. In its place: a 12.5 s serial prologue (IPSCCP, GlobalOpt, GlobalDCE and the attrs pair), 152 s Σ of partition opt, 13 s Σ of per-partition RS4GC, and an 18.5 s drain on the critical path. User CPU went up 27 s.
- **Owed:** **codegen-changing**, so the recursive-tax gate (§6.4) applies before the series closes. The ELF is 91.0 MB, against 91.9 MB at base.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-4af031.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             157.16 s   35.7%      24
    partition opt (sum over workers)              152.15 s   34.5%      24
  LLVM backend (RS4GC + opt + object emission)     37.93 s    8.6%       1
  MLIR lowering pipeline                           18.94 s    4.3%       1
    parallel opt+emit drain (post-serialize...     18.50 s    4.2%       1
    lazy extract (sum over workers)                15.51 s    3.5%      24
    partition RS4GC (sum over workers)             13.15 s    3.0%      24
    cheap-IPO prologue (serial)                    12.50 s    2.8%       1
  MLIR -> LLVM IR translation                       6.78 s    1.5%       1
    externalize + serialize once (serial)           3.69 s    0.8%       1
  Link (clang++ driver)                             1.11 s    0.3%       1
    capacity-hoist analysis (serial)             942.57 ms    0.2%       1
  MLIR parse + verify                            750.08 ms    0.2%       1
    $cap inline prepass (serial)                 628.89 ms    0.1%       1
  Internalize + GlobalDCE                        410.86 ms    0.1%       1
    gc-free leaf propagation (serial)            288.78 ms    0.1%       1
  TargetMachine init                              10.84 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           440.45 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass             11.08 s    2.5%       1
  SCFToControlFlowPass                              5.91 s    1.3%   98355
  ArithToLLVMConversionPass                         3.22 s    0.7%   98355
  mlir::detail::OpToOpPassAdaptor                   2.54 s    0.6%       2
  (anonymous namespace)::EcoControlFlowToSC...      1.71 s    0.4%       1
  ConvertControlFlowToLLVMPass                      1.22 s    0.3%       1
  (anonymous namespace)::EcoFoldProjectPass         1.12 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        672.15 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     499.80 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       437.41 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   347.22 ms    0.1%       1
  (anonymous namespace)::BFToLLVMPass            128.03 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   113.45 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       74.30 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    43.26 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    23.42 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        22.92 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    17.15 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                            29.18 s
```
</details>

### A3: our own `-O2` pipeline: no SLP or loop vectorizer, skip CalledValuePropagation (plan A3)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| A3 | 66.75 | -2.00 | 427.37 | 6,879,252 | 18.69 | — | 157.04 | FLAT, kept (deletes work; codegen-changing) | A1 |

Snapshots `try-A3` and `keep-A3`.
- **Change:** a new `runEcoModuleOpt` replaces `mlir::makeOptimizingTransformer` on both the per-partition path and the whole-module path. It has the same `buildPerModuleDefaultPipeline` shape, with unrolling and interleaving on. SLPVectorization and LoopVectorization are off, and a `shouldRun` callback skips CalledValuePropagation.
- **Verdict:** wall moved −2.00 s, exactly the noise floor, so FLAT. It removes work: user CPU −26.0 s (453.3 → 427.4) and partition opt Σ 152.2 → 127.8 s. The ELF is byte-for-byte the same SIZE as A1's (90,968,264 B), consistent with SLP having produced almost nothing. Kept under the deletion clause.
- **Owed:** **codegen-changing**, so the recursive-tax gate applies. The `--emit=llvm` and JIT paths still use `makeOptimizingTransformer`, which leaves the diagnostics unchanged.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-9a402f.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             157.04 s   37.9%      24
    partition opt (sum over workers)              127.79 s   30.8%      24
  LLVM backend (RS4GC + opt + object emission)     36.16 s    8.7%       1
    lazy extract (sum over workers)                19.26 s    4.6%      24
  MLIR lowering pipeline                           18.69 s    4.5%       1
    parallel opt+emit drain (post-serialize...     16.80 s    4.1%       1
    cheap-IPO prologue (serial)                    12.50 s    3.0%       1
    partition RS4GC (sum over workers)             11.58 s    2.8%      24
  MLIR -> LLVM IR translation                       6.71 s    1.6%       1
    externalize + serialize once (serial)           3.62 s    0.9%       1
  Link (clang++ driver)                             1.08 s    0.3%       1
    capacity-hoist analysis (serial)             947.58 ms    0.2%       1
  MLIR parse + verify                            756.41 ms    0.2%       1
    $cap inline prepass (serial)                 627.87 ms    0.2%       1
  Internalize + GlobalDCE                        411.13 ms    0.1%       1
    gc-free leaf propagation (serial)            288.45 ms    0.1%       1
  TargetMachine init                              11.68 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           414.28 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass             10.90 s    2.6%       1
  SCFToControlFlowPass                              5.77 s    1.4%   98355
  ArithToLLVMConversionPass                         3.29 s    0.8%   98355
  mlir::detail::OpToOpPassAdaptor                   2.44 s    0.6%       2
  (anonymous namespace)::EcoControlFlowToSC...      1.74 s    0.4%       1
  ConvertControlFlowToLLVMPass                      1.22 s    0.3%       1
  (anonymous namespace)::EcoFoldProjectPass         1.14 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        668.06 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     494.59 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       432.98 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   341.65 ms    0.1%       1
  (anonymous namespace)::BFToLLVMPass            131.04 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   119.89 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       83.27 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    45.94 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        25.43 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    22.69 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    16.91 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                            28.89 s
```
</details>

### B1: O(1) existence asserts in parallel Stage 2 (plan B1)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| B1 | 62.93 | -3.82 | 370.70 | 6,831,908 | 14.24 | — | 157.83 | WIN | A3 |

Snapshots `try-B1` and `keep-B1`.
- **Change:** `EcoToLLVMClosures.cpp` had three asserts that called `runtime.module.lookupSymbol`, a linear module scan, once per closure site. They now use `runtime.lookupSymbol` (symCache) and `evalLayoutNames.contains`. Asserts are live in the default `-UNDEBUG` build. Generated code is unchanged.
- **Effect:** `EcoToLLVMPass` 11.0 → 6.3 s, MLIR pipeline 18.7 → 14.2 s, and user CPU **−56.7 s**: the scans were spread over 24 Stage 2 threads.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-cce4a0.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             157.83 s   38.6%      24
    partition opt (sum over workers)              127.29 s   31.1%      24
  LLVM backend (RS4GC + opt + object emission)     36.78 s    9.0%       1
    parallel opt+emit drain (post-serialize...     17.09 s    4.2%       1
    lazy extract (sum over workers)                16.12 s    3.9%      24
  MLIR lowering pipeline                           14.24 s    3.5%       1
    cheap-IPO prologue (serial)                    12.75 s    3.1%       1
    partition RS4GC (sum over workers)             12.25 s    3.0%      24
  MLIR -> LLVM IR translation                       6.76 s    1.7%       1
    externalize + serialize once (serial)           3.62 s    0.9%       1
  Link (clang++ driver)                             1.10 s    0.3%       1
    capacity-hoist analysis (serial)             979.42 ms    0.2%       1
  MLIR parse + verify                            773.25 ms    0.2%       1
    $cap inline prepass (serial)                 640.29 ms    0.2%       1
  Internalize + GlobalDCE                        419.03 ms    0.1%       1
    gc-free leaf propagation (serial)            297.29 ms    0.1%       1
  TargetMachine init                              11.50 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           408.95 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              6.33 s    1.5%       1
  SCFToControlFlowPass                              5.85 s    1.4%   98355
  ArithToLLVMConversionPass                         3.22 s    0.8%   98355
  mlir::detail::OpToOpPassAdaptor                   2.50 s    0.6%       2
  (anonymous namespace)::EcoControlFlowToSC...      1.73 s    0.4%       1
  ConvertControlFlowToLLVMPass                      1.26 s    0.3%       1
  (anonymous namespace)::EcoFoldProjectPass         1.11 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        676.33 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     496.95 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       442.28 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   357.71 ms    0.1%       1
  (anonymous namespace)::BFToLLVMPass            129.40 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   127.23 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       83.79 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    42.76 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        24.36 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    22.37 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    16.85 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                            24.42 s
```
</details>

### B3b: parallel use collection for the unused-decl strip (plan B3b)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| B3b | 59.63 | -3.30 | 369.39 | 6,885,472 | 11.88 | — | 157.00 | WIN | B1 |

Snapshots `try-B3b` and `keep-B3b`.
- **Change:** the serial `SymbolUserMap` (`EcoToLLVM.cpp`, stage 5) is replaced by a `parallelFor` over the module's top-level ops in 8×threads chunks. Each chunk collects into a local `DenseSet<StringAttr>` the root references from the op's own attribute dictionary plus `SymbolTable::getSymbolUses(op)`. That is the same use relation, because the module is the only symbol table. It falls back to the serial map if any op hides its uses.
- **Effect:** `EcoToLLVMPass` 6.3 → 4.1 s; MLIR pipeline 14.2 → 11.9 s. Generated code is unchanged (same ELF size).

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-7ea68f.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             157.00 s   38.8%      24
    partition opt (sum over workers)              127.51 s   31.5%      24
  LLVM backend (RS4GC + opt + object emission)     35.81 s    8.8%       1
    lazy extract (sum over workers)                17.28 s    4.3%      24
    parallel opt+emit drain (post-serialize...     16.64 s    4.1%       1
    cheap-IPO prologue (serial)                    12.38 s    3.1%       1
  MLIR lowering pipeline                           11.88 s    2.9%       1
    partition RS4GC (sum over workers)             11.73 s    2.9%      24
  MLIR -> LLVM IR translation                       6.88 s    1.7%       1
    externalize + serialize once (serial)           3.57 s    0.9%       1
  Link (clang++ driver)                             1.09 s    0.3%       1
    capacity-hoist analysis (serial)             929.57 ms    0.2%       1
  MLIR parse + verify                            753.58 ms    0.2%       1
    $cap inline prepass (serial)                 627.21 ms    0.2%       1
  Internalize + GlobalDCE                        408.39 ms    0.1%       1
    gc-free leaf propagation (serial)            290.01 ms    0.1%       1
  TargetMachine init                              11.47 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           404.79 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  SCFToControlFlowPass                              5.95 s    1.5%   98355
  (anonymous namespace)::EcoToLLVMPass              4.11 s    1.0%       1
  ArithToLLVMConversionPass                         3.40 s    0.8%   98355
  mlir::detail::OpToOpPassAdaptor                   2.50 s    0.6%       2
  (anonymous namespace)::EcoControlFlowToSC...      1.72 s    0.4%       1
  ConvertControlFlowToLLVMPass                      1.21 s    0.3%       1
  (anonymous namespace)::EcoFoldProjectPass         1.17 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        669.71 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     484.71 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       422.70 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   337.41 ms    0.1%       1
  (anonymous namespace)::BFToLLVMPass            129.04 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   112.44 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       81.20 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    41.94 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        23.06 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    21.91 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    16.29 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                            22.39 s
```
</details>

### C2: LPT size-balanced partition ownership (plan C2)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| C2 | 58.75 | -0.88 | 376.73 | 7,071,588 | 12.24 | — | 156.94 | FLAT, reverted | B3b |

Snapshot `try-C2b` (`try-C2` did not build), patch `step-C2.patch`.
- **Change:** a serial pass over the defined functions (0.18 s) assigns each one, by instruction count, LPT-greedy, to the least-loaded partition. Workers then look up owners in a read-only `StringMap` instead of using FNV-1a % N.
- **Its own effect is real:** drain 16.70 → 14.34 s, and the slowest worker went from about 27 % over the mean to about 8 % over it. But other phases came in slightly higher (MLIR +0.36, translation +0.11, prologue +0.19). Net wall was −0.88 s, inside the 2 s floor, so FLAT. It adds complexity, so it is reverted under §4.
- **Revisit** once the serial path is shorter. **Noise data point:** the failed-build run accidentally re-measured B3b's tree at 60.17 s, against 59.63 s (`noise-B3b-rerun.*`), so run-to-run noise is about 0.5 s.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-c98295.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             156.94 s   38.4%      24
    partition opt (sum over workers)              132.40 s   32.4%      24
  LLVM backend (RS4GC + opt + object emission)     34.29 s    8.4%       1
    lazy extract (sum over workers)                19.14 s    4.7%      24
    parallel opt+emit drain (post-serialize...     14.34 s    3.5%       1
    cheap-IPO prologue (serial)                    12.77 s    3.1%       1
  MLIR lowering pipeline                           12.24 s    3.0%       1
    partition RS4GC (sum over workers)             11.94 s    2.9%      24
  MLIR -> LLVM IR translation                       7.00 s    1.7%       1
    externalize + serialize once (serial)           3.69 s    0.9%       1
  Link (clang++ driver)                             1.11 s    0.3%       1
    capacity-hoist analysis (serial)             965.73 ms    0.2%       1
  MLIR parse + verify                            788.37 ms    0.2%       1
    $cap inline prepass (serial)                 642.64 ms    0.2%       1
  Internalize + GlobalDCE                        418.67 ms    0.1%       1
    gc-free leaf propagation (serial)            297.47 ms    0.1%       1
    partition balance (serial)                   177.98 ms    0.0%       1
  TargetMachine init                              11.64 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           409.16 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  SCFToControlFlowPass                              5.72 s    1.4%   98355
  (anonymous namespace)::EcoToLLVMPass              4.21 s    1.0%       1
  ArithToLLVMConversionPass                         3.28 s    0.8%   98355
  mlir::detail::OpToOpPassAdaptor                   2.52 s    0.6%       2
  (anonymous namespace)::EcoControlFlowToSC...      1.80 s    0.4%       1
  ConvertControlFlowToLLVMPass                      1.29 s    0.3%       1
  (anonymous namespace)::EcoFoldProjectPass         1.13 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        680.34 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     522.33 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       425.90 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   355.62 ms    0.1%       1
  (anonymous namespace)::BFToLLVMPass            132.43 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   121.64 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       86.62 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    41.41 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    23.10 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        23.02 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    17.16 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                            22.38 s
```
</details>

### D1: per-pass timers in the cgu IPO prologue (plan D1)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| D1 | 60.17 | +0.54 | 370.82 | 6,866,976 | 12.08 | — | 156.66 | FLAT, kept (instrumentation) | B3b |

Snapshots `try-D1` and `keep-D1`.
- **Change:** `runCheapModuleIPO` runs each pass in its own pass manager under a `--lowering-stats` scope. The analysis managers are shared, so it is the same pipeline.
- **Verdict:** +0.54 s, which is noise (about 0.5 s run to run). Kept as plan-mandated instrumentation, not as a speed step.
- **Finding:** the prologue's 12.56 s is IPSCCP 6.17, GlobalOpt 3.59, PostOrderFunctionAttrs 1.95 (restored by A1), GlobalDCE 0.56 and ReversePostOrderFunctionAttrs 0.01. IPSCCP is the only interprocedural constant propagation left under cgu, because partitions see externalized functions.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-ca24c9.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             156.66 s   37.6%      24
    partition opt (sum over workers)              127.68 s   30.6%      24
  LLVM backend (RS4GC + opt + object emission)     36.11 s    8.7%       1
    parallel opt+emit drain (post-serialize...     16.73 s    4.0%       1
    lazy extract (sum over workers)                15.29 s    3.7%      24
    partition RS4GC (sum over workers)             12.78 s    3.1%      24
    cheap-IPO prologue (serial)                    12.56 s    3.0%       1
  MLIR lowering pipeline                           12.08 s    2.9%       1
  MLIR -> LLVM IR translation                       6.85 s    1.6%       1
      prologue: IPSCCP                              6.17 s    1.5%       1
      prologue: GlobalOpt                           3.59 s    0.9%       1
    externalize + serialize once (serial)           3.58 s    0.9%       1
      prologue: PostOrderFunctionAttrs              1.95 s    0.5%       1
  Link (clang++ driver)                             1.12 s    0.3%       1
    capacity-hoist analysis (serial)             934.86 ms    0.2%       1
  MLIR parse + verify                            770.28 ms    0.2%       1
    $cap inline prepass (serial)                 630.04 ms    0.2%       1
      prologue: GlobalDCE                        560.56 ms    0.1%       1
  Internalize + GlobalDCE                        414.61 ms    0.1%       1
    gc-free leaf propagation (serial)            293.16 ms    0.1%       1
  TargetMachine init                              12.02 ms    0.0%       1
      prologue: ReversePostOrderFunctionAttrs     10.30 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           416.79 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  SCFToControlFlowPass                              5.87 s    1.4%   98355
  (anonymous namespace)::EcoToLLVMPass              4.17 s    1.0%       1
  ArithToLLVMConversionPass                         3.34 s    0.8%   98355
  mlir::detail::OpToOpPassAdaptor                   2.55 s    0.6%       2
  (anonymous namespace)::EcoControlFlowToSC...      1.75 s    0.4%       1
  ConvertControlFlowToLLVMPass                      1.23 s    0.3%       1
  (anonymous namespace)::EcoFoldProjectPass         1.17 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        682.92 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     500.16 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       412.99 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   347.45 ms    0.1%       1
  (anonymous namespace)::BFToLLVMPass            127.34 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   119.53 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       83.76 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    41.24 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        24.35 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    22.52 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    16.58 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                            22.46 s
```
</details>

### B2: chunked parallel tail conversions (plan B2)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| B2 | 58.86 | -0.77 | 368.90 | 6,881,700 | 10.85 | — | 156.54 | WIN (amendment-1 rule) | B3b |

Snapshots `try-B2` and `keep-B2`.
- **Change:** `EcoTailConversions` is now a ModuleOp pass doing a chunked `parallelFor` over functions. Each chunk builds one `LLVMTypeConverter` and frozen pattern sets on its stack. Per function it runs SCF→CF (the upstream target and patterns), then Arith+CF→LLVM in one partial conversion under `LLVMConversionTarget`. It replaces the nested SCFToControlFlow + ArithToLLVM sweeps and the serial `ConvertControlFlowToLLVMPass`. The parked fused-conversion design is not used (see the file header).
- **Effect:** MLIR pipeline 12.08 → 10.85 s (−1.23 s, about 6× its ±0.2 s spread). Wall −0.77 s against B3b, which is flat on wall but a WIN under amendment 1. Same ELF size.
- **Noted:** the new pass takes 2.41 s wall for about 10 s of CPU, so parallel scaling is poor. Suspects are context-uniquer contention or chunk imbalance; candidate for a later look.
- **Owed:** the IR-identity / fixed-point gate (§6) must confirm the tail output is unchanged.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-146884.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             156.54 s   37.2%      24
    partition opt (sum over workers)              128.31 s   30.5%      24
  LLVM backend (RS4GC + opt + object emission)     36.22 s    8.6%       1
    lazy extract (sum over workers)                20.48 s    4.9%      24
    parallel opt+emit drain (post-serialize...     16.79 s    4.0%       1
    cheap-IPO prologue (serial)                    12.61 s    3.0%       1
    partition RS4GC (sum over workers)             11.84 s    2.8%      24
  MLIR lowering pipeline                           10.85 s    2.6%       1
  MLIR -> LLVM IR translation                       6.71 s    1.6%       1
      prologue: IPSCCP                              6.15 s    1.5%       1
      prologue: GlobalOpt                           3.66 s    0.9%       1
    externalize + serialize once (serial)           3.54 s    0.8%       1
      prologue: PostOrderFunctionAttrs              1.94 s    0.5%       1
  Link (clang++ driver)                             1.09 s    0.3%       1
    capacity-hoist analysis (serial)             957.54 ms    0.2%       1
  MLIR parse + verify                            781.87 ms    0.2%       1
    $cap inline prepass (serial)                 631.84 ms    0.2%       1
      prologue: GlobalDCE                        565.37 ms    0.1%       1
  Internalize + GlobalDCE                        423.20 ms    0.1%       1
    gc-free leaf propagation (serial)            292.25 ms    0.1%       1
  TargetMachine init                              11.06 ms    0.0%       1
      prologue: ReversePostOrderFunctionAttrs     10.41 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           420.40 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              4.17 s    1.0%       1
  (anonymous namespace)::EcoTailConversions...      2.41 s    0.6%       1
  (anonymous namespace)::EcoControlFlowToSC...      1.75 s    0.4%       1
  (anonymous namespace)::EcoFoldProjectPass         1.13 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        671.28 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     495.18 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       407.21 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   325.71 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                174.12 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            130.84 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   117.53 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       84.99 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    39.48 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    23.56 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        23.01 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    16.83 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                            11.97 s
```
</details>

### C2p: LPT size-balanced partitions, re-tried on B2 (plan C2)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| C2p | 56.78 | -2.08 | 374.70 | 7,044,696 | 10.65 | — | 157.07 | WIN (codegen-changing) | B2 |

Snapshots `try-C2p` and `keep-C2p`. Same patch as C2 (`step-C2.patch`, applied with offsets), recorded as `step-C2p.patch`.
- **Effect:** drain 16.79 → 14.39 s; wall −2.08 s against B2, a WIN under either rule. Partition opt Σ rose 128.3 → 132.7 s, and user CPU rose about 6 s. Grouping now changes which functions share a partition, and so cgu's intra-partition inlining. The ELF is +4,096 B.
- **Owed:** codegen-changing, so the recursive-tax gate applies. Determinism: the LPT order is a pure function of the module (cost descending, then name).

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-bfad43.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             157.07 s   37.5%      24
    partition opt (sum over workers)              132.66 s   31.6%      24
  LLVM backend (RS4GC + opt + object emission)     34.21 s    8.2%       1
    lazy extract (sum over workers)                17.63 s    4.2%      24
    parallel opt+emit drain (post-serialize...     14.39 s    3.4%       1
    cheap-IPO prologue (serial)                    12.69 s    3.0%       1
    partition RS4GC (sum over workers)             12.66 s    3.0%      24
  MLIR lowering pipeline                           10.65 s    2.5%       1
  MLIR -> LLVM IR translation                       6.78 s    1.6%       1
      prologue: IPSCCP                              6.23 s    1.5%       1
      prologue: GlobalOpt                           3.64 s    0.9%       1
    externalize + serialize once (serial)           3.63 s    0.9%       1
      prologue: PostOrderFunctionAttrs              1.94 s    0.5%       1
  Link (clang++ driver)                             1.12 s    0.3%       1
    capacity-hoist analysis (serial)             975.32 ms    0.2%       1
  MLIR parse + verify                            768.66 ms    0.2%       1
    $cap inline prepass (serial)                 642.21 ms    0.2%       1
      prologue: GlobalDCE                        581.77 ms    0.1%       1
  Internalize + GlobalDCE                        425.33 ms    0.1%       1
    gc-free leaf propagation (serial)            302.17 ms    0.1%       1
    partition balance (serial)                   172.43 ms    0.0%       1
  TargetMachine init                              11.67 ms    0.0%       1
      prologue: ReversePostOrderFunctionAttrs     10.39 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           419.17 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              4.12 s    1.0%       1
  (anonymous namespace)::EcoTailConversions...      2.26 s    0.5%       1
  (anonymous namespace)::EcoControlFlowToSC...      1.74 s    0.4%       1
  (anonymous namespace)::EcoFoldProjectPass         1.16 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        670.32 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     491.68 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       418.88 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   333.96 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                177.71 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            129.93 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   118.06 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       83.65 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    40.03 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        23.50 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    23.39 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    17.30 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                            11.81 s
```
</details>

### A1b: drop the function-attrs pair from the cgu prologue

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| A1b | 54.10 | -2.68 | 372.89 | 7,038,684 | 10.65 | — | 157.28 | WIN (codegen-changing) | C2p |

Snapshots `try-A1b` and `keep-A1b`.
- **Change:** this reverses the attrs half of A1. Under cgu, RS4GC runs per partition before opt, so calls to eco functions are already `gc.statepoint`s, and opt cannot use their callees' inferred attributes. Only gc-leaf calls could benefit.
- **Effect:** prologue 12.69 → 10.32 s; wall −2.68 s. The ELF is +57,344 B, so the attributes had a small effect on code.
- **Owed:** **codegen-changing**, so the recursive-tax gate decides whether to keep this. If the final binary fails the 3 % gate, bisect A1b first.
- `runCheapModuleIPO` keeps its `withFunctionAttrs` parameter, so the pair can be switched back on.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-2d9e1b.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             157.28 s   38.2%      24
    partition opt (sum over workers)              133.36 s   32.4%      24
  LLVM backend (RS4GC + opt + object emission)     31.55 s    7.7%       1
    lazy extract (sum over workers)                17.07 s    4.1%      24
    parallel opt+emit drain (post-serialize...     14.25 s    3.5%       1
    partition RS4GC (sum over workers)             12.47 s    3.0%      24
  MLIR lowering pipeline                           10.65 s    2.6%       1
    cheap-IPO prologue (serial)                    10.32 s    2.5%       1
  MLIR -> LLVM IR translation                       6.76 s    1.6%       1
      prologue: IPSCCP                              6.12 s    1.5%       1
      prologue: GlobalOpt                           3.63 s    0.9%       1
    externalize + serialize once (serial)           3.53 s    0.9%       1
  Link (clang++ driver)                             1.12 s    0.3%       1
    capacity-hoist analysis (serial)             945.75 ms    0.2%       1
  MLIR parse + verify                            781.17 ms    0.2%       1
    $cap inline prepass (serial)                 632.50 ms    0.2%       1
      prologue: GlobalDCE                        566.72 ms    0.1%       1
  Internalize + GlobalDCE                        422.93 ms    0.1%       1
    gc-free leaf propagation (serial)            294.30 ms    0.1%       1
    partition balance (serial)                   171.01 ms    0.0%       1
  TargetMachine init                              11.81 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           411.93 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              4.11 s    1.0%       1
  (anonymous namespace)::EcoTailConversions...      2.29 s    0.6%       1
  (anonymous namespace)::EcoControlFlowToSC...      1.75 s    0.4%       1
  (anonymous namespace)::EcoFoldProjectPass         1.12 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        670.58 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     493.62 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       410.26 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   323.20 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                172.65 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            129.81 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   116.05 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       84.82 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    39.81 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        24.02 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    23.19 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    17.03 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                            11.77 s
```
</details>

### C3: skip the per-worker UpgradeDebugInfo verifyModule (plan C3)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| C3 | 54.67 | +0.57 | 373.31 | 7,095,612 | 10.75 | — | 158.10 | WIN (amendment-1 rule; deletes work) | A1b |

Snapshots `try-C3` and `keep-C3`.
- **Change:** `emitObjectFilesSplitLazy` sets LLVM's `-disable-auto-upgrade-debug-info` once, via `cl::getRegisteredOptions`. Workers no longer run a full `verifyModule` on their partition while lazy-loading our own fresh bitcode.
- **Effect:** lazy extract Σ 17.07 → 12.90 s (−4.17 CPU-s, about 20× its spread). Wall +0.57 s, inside the 1 s floor: the critical-path share is about 0.17 s per worker, below drain noise. Generated code is unchanged (same ELF size as A1b).

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-b7c6c3.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             158.10 s   38.3%      24
    partition opt (sum over workers)              135.45 s   32.8%      24
  LLVM backend (RS4GC + opt + object emission)     31.97 s    7.7%       1
    parallel opt+emit drain (post-serialize...     14.33 s    3.5%       1
    partition RS4GC (sum over workers)             13.92 s    3.4%      24
    lazy extract (sum over workers)                12.90 s    3.1%      24
  MLIR lowering pipeline                           10.75 s    2.6%       1
    cheap-IPO prologue (serial)                    10.51 s    2.5%       1
  MLIR -> LLVM IR translation                       6.71 s    1.6%       1
      prologue: IPSCCP                              6.31 s    1.5%       1
      prologue: GlobalOpt                           3.61 s    0.9%       1
    externalize + serialize once (serial)           3.59 s    0.9%       1
  Link (clang++ driver)                             1.16 s    0.3%       1
    capacity-hoist analysis (serial)             985.51 ms    0.2%       1
  MLIR parse + verify                            781.57 ms    0.2%       1
    $cap inline prepass (serial)                 649.11 ms    0.2%       1
      prologue: GlobalDCE                        589.37 ms    0.1%       1
  Internalize + GlobalDCE                        430.16 ms    0.1%       1
    gc-free leaf propagation (serial)            303.97 ms    0.1%       1
    partition balance (serial)                   177.67 ms    0.0%       1
  TargetMachine init                              12.36 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           413.24 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              4.13 s    1.0%       1
  (anonymous namespace)::EcoTailConversions...      2.31 s    0.6%       1
  (anonymous namespace)::EcoControlFlowToSC...      1.76 s    0.4%       1
  (anonymous namespace)::EcoFoldProjectPass         1.18 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        674.38 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     496.23 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       410.33 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   335.02 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                181.71 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            131.47 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   116.23 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       84.16 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    42.18 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    23.72 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        22.46 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    17.43 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                            11.93 s
```
</details>

### B5: EcoControlFlowToSCF per top-level op in parallel chunks (plan B5)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| B5 | 52.23 | -1.87 | 371.80 | 7,100,280 | 8.90 | — | 156.82 | WIN | A1b (best wall); tree C3 |

Snapshots `try-B5` and `keep-B5`.
- **Change:** the module-wide `applyPatternsGreedily` becomes the same greedy driver applied to each isolated top-level op, in `parallelFor` chunks. Each chunk has its own patterns and `StringCaseMemo` listener.
- **The `Elm_Kernel_Utils_equal` declaration** is hoisted. It is pre-declared at module start iff a string case exists, which is where the pattern put it, using the first string case's location. In the parallel phase the pattern's `ensureEqualDeclared` therefore only ever hits. If no rewrite uses it, `EcoToLLVM`'s strip erases it.
- **Fallback:** if a non-isolated top-level op holds case or joinpoint ops, the pass runs the original whole-module form.
- **Effect:** the pass 1.75 → 0.26 s; MLIR pipeline 10.75 → 8.90 s; wall −1.87 s against the best row (A1b, 54.10). The ELF is the same size as C3's.
- **Owed:** the IR-identity gate. The July note said a per-function NESTED version was neutral, but this chunked form is not.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-7c804c.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             156.82 s   38.5%      24
    partition opt (sum over workers)              135.28 s   33.2%      24
  LLVM backend (RS4GC + opt + object emission)     31.45 s    7.7%       1
    parallel opt+emit drain (post-serialize...     14.41 s    3.5%       1
    partition RS4GC (sum over workers)             14.28 s    3.5%      24
    lazy extract (sum over workers)                11.81 s    2.9%      24
    cheap-IPO prologue (serial)                    10.11 s    2.5%       1
  MLIR lowering pipeline                            8.90 s    2.2%       1
  MLIR -> LLVM IR translation                       6.82 s    1.7%       1
      prologue: IPSCCP                              6.04 s    1.5%       1
    externalize + serialize once (serial)           3.53 s    0.9%       1
      prologue: GlobalOpt                           3.52 s    0.9%       1
  Link (clang++ driver)                             1.12 s    0.3%       1
    capacity-hoist analysis (serial)             923.92 ms    0.2%       1
  MLIR parse + verify                            763.19 ms    0.2%       1
    $cap inline prepass (serial)                 633.39 ms    0.2%       1
      prologue: GlobalDCE                        555.90 ms    0.1%       1
  Internalize + GlobalDCE                        403.06 ms    0.1%       1
    gc-free leaf propagation (serial)            286.04 ms    0.1%       1
    partition balance (serial)                   167.42 ms    0.0%       1
  TargetMachine init                              11.65 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           407.83 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              3.80 s    0.9%       1
  (anonymous namespace)::EcoTailConversions...      2.32 s    0.6%       1
  (anonymous namespace)::EcoFoldProjectPass         1.19 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        667.96 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     514.08 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       404.12 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   341.61 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   255.19 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                185.61 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            120.99 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   111.40 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       81.06 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    35.98 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        22.92 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    21.86 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    15.85 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                            10.08 s
```
</details>

### M1: glibc malloc tuning in eco-boot-native (new step from profiling)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| M1 | 51.36 | -0.87 | 371.23 | 7,966,932 | 8.21 | — | 156.62 | WIN, marginal (amendment-1 rule) | B5 |

Snapshots `try-M1` and `keep-M1`.
- **Finding (untimed `perf` leg on C3):** 41 % of the MLIR thread pool's samples were kernel spinlocks (`__pv_queued_spin_lock_slowpath` 28 %, `osq_lock` 13 %). That is `mmap_lock` contention from glibc arenas growing by `mprotect` and from large blocks churning through mmap/munmap.
- **Diagnostic:** `GLIBC_TUNABLES` with top_pad 256 MB gave 50.94 s, but RSS +0.93 GB.
- **Change:** `main()` of `eco-boot-native` only: `mallopt(M_TOP_PAD, 64 MB)`, `M_MMAP_THRESHOLD` 32 MB, `M_TRIM_THRESHOLD` 1 GB.
- **Effect:** MLIR pipeline 8.90 → 8.21 s (−0.69 s, about 3.5× its spread); `EcoTailConversions` 2.32 → 1.95 s; wall −0.87 s, inside the floor. Max RSS **+0.87 GB** (7.10 → 7.97 GB).
- **Verdict:** a marginal WIN under amendment 1. A better allocator (mimalloc or jemalloc) is not installed in this container; it is a follow-up for the A2 image rebuild.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-05762e.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             156.62 s   38.8%      24
    partition opt (sum over workers)              136.95 s   33.9%      24
  LLVM backend (RS4GC + opt + object emission)     31.60 s    7.8%       1
    parallel opt+emit drain (post-serialize...     14.02 s    3.5%       1
    partition RS4GC (sum over workers)             12.32 s    3.1%      24
    cheap-IPO prologue (serial)                    10.52 s    2.6%       1
    lazy extract (sum over workers)                 8.42 s    2.1%      24
  MLIR lowering pipeline                            8.21 s    2.0%       1
  MLIR -> LLVM IR translation                       6.60 s    1.6%       1
      prologue: IPSCCP                              6.40 s    1.6%       1
    externalize + serialize once (serial)           3.69 s    0.9%       1
      prologue: GlobalOpt                           3.56 s    0.9%       1
  Link (clang++ driver)                             1.13 s    0.3%       1
    capacity-hoist analysis (serial)             916.78 ms    0.2%       1
  MLIR parse + verify                            737.13 ms    0.2%       1
    $cap inline prepass (serial)                 617.62 ms    0.2%       1
      prologue: GlobalDCE                        555.62 ms    0.1%       1
  Internalize + GlobalDCE                        397.68 ms    0.1%       1
    gc-free leaf propagation (serial)            297.08 ms    0.1%       1
    partition balance (serial)                   166.35 ms    0.0%       1
  TargetMachine init                               9.77 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           403.73 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              3.59 s    0.9%       1
  (anonymous namespace)::EcoTailConversions...      1.95 s    0.5%       1
  (anonymous namespace)::EcoFoldProjectPass         1.09 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        654.62 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     491.35 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       384.71 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   326.35 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   248.60 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                170.68 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            117.26 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   101.84 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       79.47 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    35.63 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        22.07 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    21.17 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    15.95 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             9.30 s
```
</details>

### X1: skip LLVM module teardown at exit (new step from profiling)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| X1 | 49.28 | -2.08 | 366.37 | 7,945,076 | 8.20 | — | 154.84 | WIN | M1 |

Snapshots `try-X1` and `keep-X1`.
- **Finding:** on M1, 48.7 s of top-level phases left 2.7 s of wall unaccounted for. The tail of the earlier `perf` trace showed about 1.5 s of main-thread `llvm::Module` destruction after the link (`BasicBlock::dropAllReferences`, value-name `StringMap` removal, `free`).
- **Change:** `ecoBootFinalExit` now ends the process on POSIX too. It flushes the streams and calls `_exit(rc)`, as Windows already did with `TerminateProcess`. It is skipped when `-time-passes` or `-stats` reports are still owed by LLVM's static destructors. All outputs are written and temp objects removed before it runs.
- **Effect:** wall −2.08 s; user CPU −4.9 s. Generated code is unchanged.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-8dded4.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             154.84 s   38.8%      24
    partition opt (sum over workers)              135.43 s   34.0%      24
  LLVM backend (RS4GC + opt + object emission)     31.05 s    7.8%       1
    parallel opt+emit drain (post-serialize...     13.98 s    3.5%       1
    partition RS4GC (sum over workers)             12.22 s    3.1%      24
    cheap-IPO prologue (serial)                    10.17 s    2.6%       1
    lazy extract (sum over workers)                 8.42 s    2.1%      24
  MLIR lowering pipeline                            8.20 s    2.1%       1
  MLIR -> LLVM IR translation                       6.48 s    1.6%       1
      prologue: IPSCCP                              6.23 s    1.6%       1
    externalize + serialize once (serial)           3.61 s    0.9%       1
      prologue: GlobalOpt                           3.40 s    0.9%       1
  Link (clang++ driver)                             1.12 s    0.3%       1
    capacity-hoist analysis (serial)             904.12 ms    0.2%       1
  MLIR parse + verify                            719.30 ms    0.2%       1
    $cap inline prepass (serial)                 601.73 ms    0.2%       1
      prologue: GlobalDCE                        541.94 ms    0.1%       1
  Internalize + GlobalDCE                        382.31 ms    0.1%       1
    gc-free leaf propagation (serial)            280.53 ms    0.1%       1
    partition balance (serial)                   159.81 ms    0.0%       1
  TargetMachine init                               9.44 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           398.76 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              3.59 s    0.9%       1
  (anonymous namespace)::EcoTailConversions...      1.91 s    0.5%       1
  (anonymous namespace)::EcoFoldProjectPass         1.13 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        666.19 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     485.90 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       395.82 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   329.01 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   242.11 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                179.41 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            119.52 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   104.04 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       82.81 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    35.33 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        24.32 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    21.59 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    15.67 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             9.33 s
```
</details>

### A1c: drop GlobalOpt from the cgu prologue

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| A1c | 46.50 | -2.78 | 363.04 | 7,945,596 | 8.25 | — | 155.35 | WIN (codegen-changing) | X1 |

Snapshots `try-A1c` and `keep-A1c`.
- **Change:** removes the 3.6 s serial whole-module GlobalOpt. Each partition's `-O2` still runs GlobalOpt over the functions it owns.
- **Effect:** prologue 10.17 → 6.84 s; wall −2.78 s. The ELF is +16,384 B, so whole-module GlobalOpt did little to the code.
- **Owed:** **codegen-changing**, so the recursive-tax gate applies. Together with A1b, these are the first steps to bisect if the final binary fails the 3 % gate.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-26e54d.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             155.35 s   39.9%      24
    partition opt (sum over workers)              135.04 s   34.7%      24
  LLVM backend (RS4GC + opt + object emission)     27.95 s    7.2%       1
    parallel opt+emit drain (post-serialize...     13.98 s    3.6%       1
    partition RS4GC (sum over workers)             12.27 s    3.1%      24
    lazy extract (sum over workers)                 8.40 s    2.2%      24
  MLIR lowering pipeline                            8.25 s    2.1%       1
    cheap-IPO prologue (serial)                     6.84 s    1.8%       1
  MLIR -> LLVM IR translation                       6.74 s    1.7%       1
      prologue: IPSCCP                              6.34 s    1.6%       1
    externalize + serialize once (serial)           3.79 s    1.0%       1
  Link (clang++ driver)                             1.12 s    0.3%       1
    capacity-hoist analysis (serial)             924.84 ms    0.2%       1
  MLIR parse + verify                            722.76 ms    0.2%       1
    $cap inline prepass (serial)                 611.20 ms    0.2%       1
      prologue: GlobalDCE                        499.74 ms    0.1%       1
  Internalize + GlobalDCE                        389.52 ms    0.1%       1
    gc-free leaf propagation (serial)            291.74 ms    0.1%       1
    partition balance (serial)                   165.01 ms    0.0%       1
  TargetMachine init                               9.31 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           389.67 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              3.57 s    0.9%       1
  (anonymous namespace)::EcoTailConversions...      1.99 s    0.5%       1
  (anonymous namespace)::EcoFoldProjectPass         1.29 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        662.21 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     487.85 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       367.88 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   326.61 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   236.66 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                206.89 ms    0.1%       1
  (anonymous namespace)::BFToLLVMPass            116.95 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   102.43 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       83.56 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    35.79 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        21.82 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    21.64 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    16.00 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             9.54 s
```
</details>

### A1d: IPSCCP without function specialization in the cgu prologue

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| A1d | 45.42 | -1.08 | 364.55 | 7,894,864 | 8.02 | — | 154.38 | WIN | A1c |

Snapshots `try-A1d` and `keep-A1d`.
- **Change:** `IPSCCPPass(IPSCCPOptions(/*AllowFuncSpec=*/false))`. Constant propagation is kept; the search for function-specialization clones is dropped.
- **Effect:** IPSCCP 6.34 → 5.77 s (its earlier readings were 6.17–6.40); wall −1.08 s.
- **Code:** the ELF is the same size to the byte as A1c's, so specialization produced no clones on this module. This removes analysis cost only. Nominally codegen-changing, but probably not in practice.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-cd6b26.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             154.38 s   39.6%      24
    partition opt (sum over workers)              138.18 s   35.5%      24
  LLVM backend (RS4GC + opt + object emission)     27.28 s    7.0%       1
    parallel opt+emit drain (post-serialize...     14.00 s    3.6%       1
    partition RS4GC (sum over workers)             12.36 s    3.2%      24
    lazy extract (sum over workers)                 8.49 s    2.2%      24
  MLIR lowering pipeline                            8.02 s    2.1%       1
  MLIR -> LLVM IR translation                       6.57 s    1.7%       1
    cheap-IPO prologue (serial)                     6.28 s    1.6%       1
      prologue: IPSCCP                              5.77 s    1.5%       1
    externalize + serialize once (serial)           3.72 s    1.0%       1
  Link (clang++ driver)                             1.10 s    0.3%       1
    capacity-hoist analysis (serial)             879.94 ms    0.2%       1
  MLIR parse + verify                            732.05 ms    0.2%       1
    $cap inline prepass (serial)                 605.65 ms    0.2%       1
      prologue: GlobalDCE                        514.97 ms    0.1%       1
  Internalize + GlobalDCE                        384.20 ms    0.1%       1
    gc-free leaf propagation (serial)            280.67 ms    0.1%       1
    partition balance (serial)                   170.39 ms    0.0%       1
  TargetMachine init                               9.58 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           389.74 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              3.44 s    0.9%       1
  (anonymous namespace)::EcoTailConversions...      1.94 s    0.5%       1
  (anonymous namespace)::EcoFoldProjectPass         1.04 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        658.70 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     483.31 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       368.38 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   313.59 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   240.38 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                167.40 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            116.49 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   107.33 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       82.25 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    36.80 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        23.18 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    21.96 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    16.08 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             9.06 s
```
</details>

### S1: bitcode without the irsymtab for the lazy split

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| S1 | 45.89 | +0.47 | 362.58 | 7,819,740 | 8.29 | — | 156.76 | FLAT, reverted | A1d |

Snapshot `try-S1`, patch `step-S1.patch`.
- **Change:** write the bitcode with `BitcodeWriter::writeModule` + `writeStrtab` instead of `WriteBitcodeToFile`, skipping the LTO irsymtab.
- **Effect:** serialize 3.72 → 3.55 s, inside that phase's observed 3.53–3.79 s range. Wall +0.47 s. FLAT; reverted.
- **Finding:** the irsymtab is not where serialization time goes. It is the module writer itself, about 3.5 s for the whole module.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-528029.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             156.76 s   40.4%      24
    partition opt (sum over workers)              133.94 s   34.5%      24
  LLVM backend (RS4GC + opt + object emission)     27.31 s    7.0%       1
    parallel opt+emit drain (post-serialize...     14.08 s    3.6%       1
    partition RS4GC (sum over workers)             12.29 s    3.2%      24
    lazy extract (sum over workers)                 8.45 s    2.2%      24
  MLIR lowering pipeline                            8.29 s    2.1%       1
  MLIR -> LLVM IR translation                       6.68 s    1.7%       1
    cheap-IPO prologue (serial)                     6.31 s    1.6%       1
      prologue: IPSCCP                              5.80 s    1.5%       1
    externalize + serialize once (serial)           3.55 s    0.9%       1
  Link (clang++ driver)                             1.16 s    0.3%       1
    capacity-hoist analysis (serial)             933.62 ms    0.2%       1
  MLIR parse + verify                            725.60 ms    0.2%       1
    $cap inline prepass (serial)                 616.24 ms    0.2%       1
      prologue: GlobalDCE                        504.12 ms    0.1%       1
  Internalize + GlobalDCE                        394.47 ms    0.1%       1
    gc-free leaf propagation (serial)            294.86 ms    0.1%       1
    partition balance (serial)                   173.07 ms    0.0%       1
  TargetMachine init                               9.03 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           388.26 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              3.67 s    0.9%       1
  (anonymous namespace)::EcoTailConversions...      1.92 s    0.5%       1
  (anonymous namespace)::EcoFoldProjectPass         1.02 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        667.68 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     494.32 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       389.30 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   329.71 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   240.98 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                163.04 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            122.22 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   106.68 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       82.92 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    34.99 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    22.21 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        22.15 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    15.92 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             9.30 s
```
</details>

### B8a: getOps instead of recursive walks in the EcoToLLVM epilogue and global-root init (plan B3a/B8)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| B8a | 45.39 | -0.03 | 360.90 | 7,870,416 | 7.89 | — | 154.42 | FLAT, kept (deletes work) | A1d |

Snapshots `try-B8a` and `keep-B8a`.
- **Change:** the two whole-module recursive walks that only look for top-level ops now iterate the module body: the epilogue's `module.walk(LLVMFuncOp)` and `createGlobalRootInitFunction`'s `module.walk(GlobalOp)`. The visiting order is the same.
- **Effect:** `EcoToLLVMPass` 3.44 → 3.25 s; wall −0.03 s. FLAT, kept as a pure deletion of work.
- **Diagnostic leg before this step** (`ECO_ECO2LLVM_STATS`, A1d tree):

| stage | time |
|---|---|
| pre-scan | 66 ms |
| Stage 0 | 734 ms |
| 2b pre-materialization | 757 ms |
| Stage 2 | 651 ms (was 5,704 ms before B1) |
| 4 epilogue | 499 ms |
| 5 global-root init + strip | 915 ms (was 3,083 ms before B3b) |

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-f4a311.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             154.42 s   39.9%      24
    partition opt (sum over workers)              135.00 s   34.9%      24
  LLVM backend (RS4GC + opt + object emission)     27.27 s    7.1%       1
    parallel opt+emit drain (post-serialize...     13.91 s    3.6%       1
    partition RS4GC (sum over workers)             12.40 s    3.2%      24
    lazy extract (sum over workers)                 8.42 s    2.2%      24
  MLIR lowering pipeline                            7.89 s    2.0%       1
  MLIR -> LLVM IR translation                       6.64 s    1.7%       1
    cheap-IPO prologue (serial)                     6.33 s    1.6%       1
      prologue: IPSCCP                              5.83 s    1.5%       1
    externalize + serialize once (serial)           3.66 s    0.9%       1
  Link (clang++ driver)                             1.13 s    0.3%       1
    capacity-hoist analysis (serial)             926.90 ms    0.2%       1
  MLIR parse + verify                            721.44 ms    0.2%       1
    $cap inline prepass (serial)                 620.35 ms    0.2%       1
      prologue: GlobalDCE                        500.64 ms    0.1%       1
  Internalize + GlobalDCE                        392.59 ms    0.1%       1
    gc-free leaf propagation (serial)            295.14 ms    0.1%       1
    partition balance (serial)                   164.62 ms    0.0%       1
  TargetMachine init                              10.18 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           386.54 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              3.25 s    0.8%       1
  (anonymous namespace)::EcoTailConversions...      1.96 s    0.5%       1
  (anonymous namespace)::EcoFoldProjectPass         1.07 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        667.34 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     488.14 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       377.53 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   330.09 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   243.03 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                168.26 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            120.06 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   104.26 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       79.50 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    34.90 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        22.86 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    22.19 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    16.54 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             8.96 s
```
</details>

### T1: reset MLIR locations to UnknownLoc before translation

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| T1 | 45.99 | +0.57 | 363.58 | 7,914,876 | 7.89 | — | 153.86 | FLAT/worse, reverted | A1d |

Snapshot `try-T1`, patch `step-T1.patch`.
- **Change:** a parallel walk set every op and block-argument location to `UnknownLoc` before `translateModuleToLLVMIR`, hoping to shrink its serial `legalizeDIExpressionsRecursively` pre-walk.
- **Effect:** translation 6.64 → 6.95 s; wall +0.60 s. Reverted.
- **Finding:** the pre-walk's cost is building an attribute dictionary for every op, not the locations. It cannot be removed without patching MLIR. Recorded as an upstream item.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-35cac4.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             153.86 s   39.6%      24
    partition opt (sum over workers)              137.08 s   35.2%      24
  LLVM backend (RS4GC + opt + object emission)     27.56 s    7.1%       1
    parallel opt+emit drain (post-serialize...     14.20 s    3.7%       1
    partition RS4GC (sum over workers)             12.33 s    3.2%      24
    lazy extract (sum over workers)                 8.43 s    2.2%      24
  MLIR lowering pipeline                            7.89 s    2.0%       1
  MLIR -> LLVM IR translation                       6.95 s    1.8%       1
    cheap-IPO prologue (serial)                     6.34 s    1.6%       1
      prologue: IPSCCP                              5.84 s    1.5%       1
    externalize + serialize once (serial)           3.62 s    0.9%       1
  Link (clang++ driver)                             1.11 s    0.3%       1
    capacity-hoist analysis (serial)             943.78 ms    0.2%       1
  MLIR parse + verify                            718.61 ms    0.2%       1
    $cap inline prepass (serial)                 620.50 ms    0.2%       1
      prologue: GlobalDCE                        507.18 ms    0.1%       1
  Internalize + GlobalDCE                        396.37 ms    0.1%       1
    gc-free leaf propagation (serial)            295.75 ms    0.1%       1
    partition balance (serial)                   168.53 ms    0.0%       1
  TargetMachine init                               9.85 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           388.87 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              3.23 s    0.8%       1
  (anonymous namespace)::EcoTailConversions...      1.97 s    0.5%       1
  (anonymous namespace)::EcoFoldProjectPass         1.08 s    0.3%   56944
  (anonymous namespace)::EcoGCPreparePass        668.05 ms    0.2%       1
  (anonymous namespace)::EcoListTemplatePass     488.95 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       388.09 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   328.99 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   238.76 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                171.88 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            121.42 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   105.14 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       82.33 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    36.85 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        23.31 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    21.41 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    15.87 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             8.97 s
```
</details>

### B6: parallel EcoGCPrepare (plan B6, partial)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| B6 | 44.10 | -1.29 | 361.25 | 7,869,536 | 7.39 | — | 153.42 | WIN | B8a |

Snapshots `try-B6` and `keep-B6`.
- **Change:** `EcoGCPrepare`'s per-function work (liveness, root sets, allocation-group attributes on the function's own ops, no module writes) now runs in `parallelForEach` over the top-level functions. It stays serial when `ECO_GCPREPARE_CENSUS` is set, because `gCensus` is unsynchronised.
- **Effect:** the pass 0.67 → 0.15 s; MLIR pipeline 7.89 → 7.39 s; wall −1.29 s. Same ELF size.
- **Not done (the rest of B6):** fusing it with `EcoFoldProject`, and the linear liveness sweep. With this pass now at 0.15 s, neither is worth it.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-482ea2.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             153.42 s   39.8%      24
    partition opt (sum over workers)              136.39 s   35.4%      24
  LLVM backend (RS4GC + opt + object emission)     26.77 s    7.0%       1
    parallel opt+emit drain (post-serialize...     13.92 s    3.6%       1
    partition RS4GC (sum over workers)             12.45 s    3.2%      24
    lazy extract (sum over workers)                 8.45 s    2.2%      24
  MLIR lowering pipeline                            7.39 s    1.9%       1
  MLIR -> LLVM IR translation                       6.43 s    1.7%       1
    cheap-IPO prologue (serial)                     6.07 s    1.6%       1
      prologue: IPSCCP                              5.60 s    1.5%       1
    externalize + serialize once (serial)           3.56 s    0.9%       1
  Link (clang++ driver)                             1.11 s    0.3%       1
    capacity-hoist analysis (serial)             868.68 ms    0.2%       1
  MLIR parse + verify                            723.34 ms    0.2%       1
    $cap inline prepass (serial)                 593.18 ms    0.2%       1
      prologue: GlobalDCE                        474.28 ms    0.1%       1
  Internalize + GlobalDCE                        364.15 ms    0.1%       1
    gc-free leaf propagation (serial)            277.13 ms    0.1%       1
    partition balance (serial)                   159.80 ms    0.0%       1
  TargetMachine init                               9.02 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           385.01 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              3.26 s    0.8%       1
  (anonymous namespace)::EcoTailConversions...      1.94 s    0.5%       1
  (anonymous namespace)::EcoFoldProjectPass         1.12 s    0.3%   56944
  (anonymous namespace)::EcoListTemplatePass     491.97 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       385.14 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   319.64 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   239.96 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                181.44 ms    0.0%       1
  (anonymous namespace)::EcoGCPreparePass        149.65 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            124.53 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   106.49 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       84.72 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    35.43 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        21.92 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    21.35 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    16.11 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             8.51 s
```
</details>

### LC: parallel per-function EcoListCursor rewrites

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| LC | 44.14 | +0.04 | 360.70 | 7,896,996 | 7.19 | — | 154.60 | FLAT, reverted | B6 |

Snapshot `try-LC`, patch `step-LC.patch`.
- **Change:** loops grouped by function and rewritten in `parallelForEach`, with the helper decls created up front and the counters made atomic.
- **Effect:** the pass 0.40 → 0.36 s; wall +0.04 s. FLAT and adds complexity, so reverted.
- **Finding:** the pass's cost is the serial whole-module `walk(scf::WhileOp)` that collects loops, not the rewrites. Folding the loop collection into an existing parallel sweep (`EcoToLLVM` Stage 2 or the tail conversions) would be the real fix, which is B2's fuller form.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-2fab49.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             154.60 s   40.2%      24
    partition opt (sum over workers)              134.59 s   35.0%      24
  LLVM backend (RS4GC + opt + object emission)     26.91 s    7.0%       1
    parallel opt+emit drain (post-serialize...     13.93 s    3.6%       1
    partition RS4GC (sum over workers)             12.39 s    3.2%      24
    lazy extract (sum over workers)                 8.42 s    2.2%      24
  MLIR lowering pipeline                            7.19 s    1.9%       1
  MLIR -> LLVM IR translation                       6.51 s    1.7%       1
    cheap-IPO prologue (serial)                     6.15 s    1.6%       1
      prologue: IPSCCP                              5.66 s    1.5%       1
    externalize + serialize once (serial)           3.57 s    0.9%       1
  Link (clang++ driver)                             1.10 s    0.3%       1
    capacity-hoist analysis (serial)             887.37 ms    0.2%       1
  MLIR parse + verify                            715.43 ms    0.2%       1
    $cap inline prepass (serial)                 605.12 ms    0.2%       1
      prologue: GlobalDCE                        484.89 ms    0.1%       1
  Internalize + GlobalDCE                        371.80 ms    0.1%       1
    gc-free leaf propagation (serial)            281.10 ms    0.1%       1
    partition balance (serial)                   163.28 ms    0.0%       1
  TargetMachine init                               9.07 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           384.54 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              3.17 s    0.8%       1
  (anonymous namespace)::EcoTailConversions...      1.89 s    0.5%       1
  (anonymous namespace)::EcoFoldProjectPass         1.09 s    0.3%   56944
  (anonymous namespace)::EcoListTemplatePass     478.97 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       364.34 ms    0.1%       1
  ReconcileUnrealizedCastsPass                   324.51 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   242.32 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                173.24 ms    0.0%       1
  (anonymous namespace)::EcoGCPreparePass        149.64 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            122.09 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   100.61 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       77.28 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    35.76 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        22.22 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    21.54 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    16.01 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             8.27 s
```
</details>

### RC: reconcile casts per function inside the tail pass

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| RC | 44.56 | +0.46 | 361.51 | 7,876,068 | 6.95 | — | 155.88 | FLAT, kept (deletes a serial pass) | B6 |

Snapshots `try-RC` and `keep-RC`.
- **Change:** `EcoTailConversions` calls `reconcileUnrealizedCasts` on each function's casts inside its parallel chunk; cast chains are SSA-local, so they never cross functions. Casts under non-function top-level ops are reconciled serially afterwards. `ReconcileUnrealizedCastsPass` is removed from the pipeline.
- **Effect:** MLIR pipeline 7.39 → 6.95 s (−0.44 s, about 2× its spread); wall +0.46 s, noise (translation +0.38 s on unchanged code). FLAT, kept as the deletion of a 0.33 s serial sweep.
- **Not measured:** the call-graph `perf` leg meant to explain the tail pass's poor scaling (1.9 s wall) was stopped at its 30-minute limit; DWARF unwinding over a whole run is too slow to report. Left open.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-958bb9.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             155.88 s   40.4%      24
    partition opt (sum over workers)              134.28 s   34.8%      24
  LLVM backend (RS4GC + opt + object emission)     27.20 s    7.0%       1
    parallel opt+emit drain (post-serialize...     14.05 s    3.6%       1
    partition RS4GC (sum over workers)             12.33 s    3.2%      24
    lazy extract (sum over workers)                 8.45 s    2.2%      24
  MLIR lowering pipeline                            6.95 s    1.8%       1
  MLIR -> LLVM IR translation                       6.81 s    1.8%       1
    cheap-IPO prologue (serial)                     6.20 s    1.6%       1
      prologue: IPSCCP                              5.71 s    1.5%       1
    externalize + serialize once (serial)           3.69 s    1.0%       1
  Link (clang++ driver)                             1.12 s    0.3%       1
    capacity-hoist analysis (serial)             891.62 ms    0.2%       1
  MLIR parse + verify                            710.60 ms    0.2%       1
    $cap inline prepass (serial)                 602.70 ms    0.2%       1
      prologue: GlobalDCE                        483.54 ms    0.1%       1
  Internalize + GlobalDCE                        369.87 ms    0.1%       1
    gc-free leaf propagation (serial)            280.67 ms    0.1%       1
    partition balance (serial)                   161.15 ms    0.0%       1
  TargetMachine init                               9.69 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           386.18 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              3.20 s    0.8%       1
  (anonymous namespace)::EcoTailConversions...      1.93 s    0.5%       1
  (anonymous namespace)::EcoFoldProjectPass         1.07 s    0.3%   56944
  (anonymous namespace)::EcoListTemplatePass     480.93 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       385.87 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   224.58 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                166.77 ms    0.0%       1
  (anonymous namespace)::EcoGCPreparePass        158.26 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            124.86 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   100.73 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       80.72 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    33.53 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        24.39 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    21.14 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    15.83 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             8.02 s
```
</details>

### CH: parallel capacity-hoist Phase A

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| CH | 44.59 | +0.49 | 367.93 | 9,052,228 | 7.02 | — | 157.68 | FLAT, reverted (RSS +1.18 GB) | B6 |

Snapshot `try-CH`, patch `step-CH.patch`.
- **Change:** `llvm::parallelFor` over capacity hoisting's read-only per-function scan (Phase A).
- **Effect:** the phase 0.92 → 0.52 s. But max RSS **+1.18 GB** (to 9.05 GB) and wall +0.49 s (noise).
- **Why RSS rose:** LLVM's default executor starts its own 24 threads, and with M1's `M_TOP_PAD` of 64 MB each of them grows a fresh glibc arena.
- **Verdict:** 0.4 s of a serial phase is not worth 1.2 GB on a 15 GB box. Reverted. Revisit only together with a pooled allocator (A2 image).

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-8dd075.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             157.68 s   40.2%      24
    partition opt (sum over workers)              138.32 s   35.3%      24
  LLVM backend (RS4GC + opt + object emission)     27.14 s    6.9%       1
    parallel opt+emit drain (post-serialize...     14.15 s    3.6%       1
    partition RS4GC (sum over workers)             12.43 s    3.2%      24
    lazy extract (sum over workers)                 8.41 s    2.1%      24
  MLIR lowering pipeline                            7.02 s    1.8%       1
  MLIR -> LLVM IR translation                       6.78 s    1.7%       1
    cheap-IPO prologue (serial)                     6.31 s    1.6%       1
      prologue: IPSCCP                              5.82 s    1.5%       1
    externalize + serialize once (serial)           3.73 s    1.0%       1
  Link (clang++ driver)                             1.13 s    0.3%       1
  MLIR parse + verify                            716.54 ms    0.2%       1
    $cap inline prepass (serial)                 612.31 ms    0.2%       1
    capacity-hoist analysis (serial)             524.42 ms    0.1%       1
      prologue: GlobalDCE                        493.83 ms    0.1%       1
  Internalize + GlobalDCE                        384.02 ms    0.1%       1
    gc-free leaf propagation (serial)            289.55 ms    0.1%       1
    partition balance (serial)                   165.67 ms    0.0%       1
  TargetMachine init                              10.15 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           392.12 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              3.20 s    0.8%       1
  (anonymous namespace)::EcoTailConversions...      1.97 s    0.5%       1
  (anonymous namespace)::EcoFoldProjectPass         1.01 s    0.3%   56944
  (anonymous namespace)::EcoListTemplatePass     495.97 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       390.13 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   243.04 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                160.38 ms    0.0%       1
  (anonymous namespace)::EcoGCPreparePass        152.24 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            131.48 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...   101.67 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       77.25 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    35.56 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        21.43 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    21.21 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    15.82 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             8.03 s
```
</details>

### B7: the remaining per-site linear symbol lookups (plan B7)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| B7 | 44.46 | +0.36 | 362.65 | 7,889,980 | 6.88 | — | 155.17 | FLAT, kept (removes quadratic scans) | B6 |

Snapshots `try-B7` and `keep-B7`.
- **`ensureUtilsCmp3Decl`:** scans the module body from the END. It runs once per rewritten compare site, and the decl it creates is appended at the end, so later calls are O(1).
- **`EcoListTemplate`'s `kFinishFwdFn`:** the lookup is now once per run, not once per unwind rewrite.
- **Effect:** `EcoCompareCaseRewrite` 0.11 → 0.03 s; `EcoListTemplate` 0.51 → 0.40 s; wall flat.
- **Not changed:** `ListMapOp::verify`'s `lookupNearestSymbolFrom` (parse-time). It needs a TableGen trait change (`SymbolUserOpInterface`), and parse + verify is 0.74 s in total. `ensureEqualDeclared` is already O(1) since B5, because the decl is pre-declared at the module start.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-9be1c9.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             155.17 s   40.1%      24
    partition opt (sum over workers)              135.85 s   35.1%      24
  LLVM backend (RS4GC + opt + object emission)     27.44 s    7.1%       1
    parallel opt+emit drain (post-serialize...     14.03 s    3.6%       1
    partition RS4GC (sum over workers)             12.30 s    3.2%      24
    lazy extract (sum over workers)                 8.45 s    2.2%      24
  MLIR lowering pipeline                            6.88 s    1.8%       1
  MLIR -> LLVM IR translation                       6.55 s    1.7%       1
    cheap-IPO prologue (serial)                     6.32 s    1.6%       1
      prologue: IPSCCP                              5.83 s    1.5%       1
    externalize + serialize once (serial)           3.72 s    1.0%       1
  Link (clang++ driver)                             1.12 s    0.3%       1
    capacity-hoist analysis (serial)             924.39 ms    0.2%       1
  MLIR parse + verify                            735.88 ms    0.2%       1
    $cap inline prepass (serial)                 614.70 ms    0.2%       1
      prologue: GlobalDCE                        489.39 ms    0.1%       1
  Internalize + GlobalDCE                        382.81 ms    0.1%       1
    gc-free leaf propagation (serial)            297.27 ms    0.1%       1
    partition balance (serial)                   165.08 ms    0.0%       1
  TargetMachine init                               9.63 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           387.29 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              3.17 s    0.8%       1
  (anonymous namespace)::EcoTailConversions...      2.02 s    0.5%       1
  (anonymous namespace)::EcoFoldProjectPass         1.03 s    0.3%   56944
  (anonymous namespace)::EcoListTemplatePass     402.82 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       392.13 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   244.14 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                166.01 ms    0.0%       1
  (anonymous namespace)::EcoGCPreparePass        157.30 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            122.40 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       80.63 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    34.57 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...    30.11 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        24.08 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    23.16 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    15.67 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             7.91 s
```
</details>

### B4: finer Stage 2 chunks (plan B4, minimal form)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| B4 | 44.09 | -0.01 | 363.33 | 7,861,344 | 6.65 | — | 155.35 | FLAT, kept (one-line) | B6 |

Snapshots `try-B4` and `keep-B4`.
- **Change:** Stage 2 uses 8 chunks per thread instead of one equal-count chunk per thread. `failableParallelForEach` hands them out dynamically.
- **Effect:** `EcoToLLVMPass` 3.17 → 2.99 s; MLIR pipeline 6.88 → 6.65 s; wall 44.09 s, flat against the 44.10 s best.
- **Not done (the rest of B4):** the single parallel pre-materialization collect and the `materialize()` memo. The stage is about 0.76 s serial, worth about 0.5 s at most.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-f17bc7.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             155.35 s   40.1%      24
    partition opt (sum over workers)              136.23 s   35.2%      24
  LLVM backend (RS4GC + opt + object emission)     27.21 s    7.0%       1
    parallel opt+emit drain (post-serialize...     14.00 s    3.6%       1
    partition RS4GC (sum over workers)             12.30 s    3.2%      24
    lazy extract (sum over workers)                 8.42 s    2.2%      24
  MLIR lowering pipeline                            6.65 s    1.7%       1
  MLIR -> LLVM IR translation                       6.62 s    1.7%       1
    cheap-IPO prologue (serial)                     6.28 s    1.6%       1
      prologue: IPSCCP                              5.78 s    1.5%       1
    externalize + serialize once (serial)           3.58 s    0.9%       1
  Link (clang++ driver)                             1.13 s    0.3%       1
    capacity-hoist analysis (serial)             921.09 ms    0.2%       1
  MLIR parse + verify                            725.12 ms    0.2%       1
    $cap inline prepass (serial)                 613.17 ms    0.2%       1
      prologue: GlobalDCE                        492.00 ms    0.1%       1
  Internalize + GlobalDCE                        381.54 ms    0.1%       1
    gc-free leaf propagation (serial)            291.28 ms    0.1%       1
    partition balance (serial)                   165.32 ms    0.0%       1
  TargetMachine init                               8.58 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           387.16 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              2.99 s    0.8%       1
  (anonymous namespace)::EcoTailConversions...      1.93 s    0.5%       1
  (anonymous namespace)::EcoFoldProjectPass         1.30 s    0.3%   56944
  (anonymous namespace)::EcoListTemplatePass     405.95 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       388.55 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   235.71 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                207.45 ms    0.1%       1
  (anonymous namespace)::EcoGCPreparePass        151.79 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            128.51 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       82.64 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    34.49 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...    25.66 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        23.75 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    20.93 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    15.44 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             7.95 s
```
</details>

### Batched gates (§6), run 2026-10-01 on the final tree `keep-B4`

**Final compiler.** `bin/eco-be-final` is `ecoGCR.mlir` lowered by the `keep-B4` tree's
`eco-boot-native`.

**Self-compiles.** The base compiler (`bin/eco-be-base`, lowered at `be-base`) and the final
compiler each compiled the compiler source twice, interleaved, using the gc-opt loop's §2
command shape (`stats-backend-opt/selfcompile.sh`):

| run | wall | max RSS (kB) | output |
|---|---|---|---|
| base r1 | 108.20 s | 12,592,116 | identical to `ecoGCR.mlir` |
| final r1 | 108.81 s | 12,598,376 | identical to `ecoGCR.mlir` |
| base r2 | 108.37 s | 12,597,832 | identical to `ecoGCR.mlir` |
| final r2 | 108.98 s | 12,600,616 | identical to `ecoGCR.mlir` |

- **§6.1 Bootstrap fixed point: PASS.** Every run reproduced `ecoGCR.mlir` byte for byte, with
  no `[gc-stats] SIG` and rc 0.
- **§6.4 Recursive tax: PASS.** The final compiler is **+0.56 %** slower on the self-compile
  (mean 108.90 s against 108.29 s), against a 3 % gate. That covers every codegen-changing step
  together: A1 (cgu), A3 (no SLP/LoopVec/CVP), C2′ (LPT partitions), A1b (no attrs pair),
  A1c (no prologue GlobalOpt) and A1d (no IPSCCP funcspec).
- **§6.2 E2E and §6.3 unit tests: PASS.** First \`cmake --build build\` (a full rebuild, so
  \`ecoc\` and \`test\` relink \`libEcoPasses.a\`), then \`cmake --build build --target check\`, run
  once. \`check\` runs \`build/test/test\`, the full unit + JIT E2E binary: **2006/2006 passed**,
  with XFAILs skipped. Log: \`/tmp/test_output.txt\`. This exercises every MLIR-pipeline change
  (B1–B7, RC) through the JIT path.
- **§6.5 Determinism: PASS.** Two \`-O 0 --emit=llvm\` lowerings of \`ecoGCR.mlir\` gave
  byte-identical IR (710,639,046 B, md5 \`7857fb694040…\`). That is also exactly the byte size of
  the step-0c dump from the \`be-base\` tree. It suggests, but does not prove, that the MLIR-side
  steps left the IR unchanged; the base dump was deleted before a byte comparison could be made.
- **NOT RUN: AOT E2E (\`run-aot-e2e\`).**
  - Its dependencies would rebuild the JS bootstrap stages (\`eco-boot\`, \`eco-boot-2.js\`), which
    are long and have hit out-of-memory on this box before.
  - AOT test programs are far below the 4,000-function split threshold, so they never take the
    \`cgu\`/LPT path. They would only exercise A3's pipeline on the whole-module path.
  - The large-module path is covered by the four fixed-point self-compiles above.
  - Owed if a shipping gate requires it.

### dev: `--parallel-opt=dev` comparison on the final tree (2026-10-02; not a step)

This is one lowering of `ecoGCR.mlir` with `--parallel-opt=dev` on the `keep-B4` tree, then one
self-compile with the produced compiler (`sc-dev-r1`).

| | cgu (B4, default) | dev |
|---|---|---|
| lowering wall | 44.09 s | 43.09 s |
| user CPU | 363.3 s | 303.2 s |
| max RSS | 7,861,344 kB | 9,199,772 kB |
| partition opt Σ | 136.2 s | 66.5 s |
| partition emit Σ | 155.4 s | 161.8 s |
| drain | 14.0 s | 11.3 s |
| ELF | 91,046,088 B | 91,119,816 B |
| self-compile | 108.81 / 108.98 s | 108.46 s |
| fixed point | identical | identical |

- **It works:** the fixed point holds.
- **Lowering is 1 s faster** and uses 60 s less CPU. Emit now dominates each worker, so the
  critical path drops only 2.7 s.
- **RSS is +1.3 GB, not investigated.** One possible cause is extra malloc arenas, as in step CH.
- **Generated code is not measurably slower** (one run). After RS4GC, nearly every call is a
  `gc.statepoint` the inliner cannot touch, so the no-inline pipeline loses little.
- **Not proposed as the default:** 1 s is not worth +1.3 GB on a 15 GB box. Confirm the tax with
  more runs before reconsidering.

### dev variants: lowering speed against code quality (2026-10-02; not steps)

These are lowerings on the `keep-B4` tree, each followed by one self-compile with the produced
compiler. Every variant reproduced `ecoGCR.mlir`.

| variant | lowering wall | user CPU | partition opt Σ | partition emit Σ | drain | ELF | self-compile |
|---|---|---|---|---|---|---|---|
| cgu (default) | 44.09 s | 363 s | 136.2 s | 155.4 s | 14.0 s | 91.0 MB | 108.9 s |
| dev | 43.09 s | 303 s | 66.5 s | 161.8 s | 11.3 s | 91.1 MB | 108.5 s |
| dev `--dev-opt-o1` | 41.13 s | 275 s | 35.0 s | 166.2 s | 10.1 s | 92.8 MB | 110.8 s (+2.3 %) |
| dev `--dev-opt-o1 --dev-emit-cg=0` | 36.19 s | 156 s | 34.5 s | 45.7 s | 5.0 s | 122.1 MB | **154.9 s (+43 %)** |
| `-O 0` (no opt, serial RS4GC) | 37.96 s | 127 s | — | 58.1 s | 3.7 s | 134.3 MB | not run |

- **Codegen level None** (FastISel plus the fast register allocator) is what cuts emit by 3.6×,
  and it is also what costs 43 % at runtime.
- **The IR-pipeline knobs** (`dev`, O1) save CPU but little wall: emit dominates each worker.
- **Untested dev lever:** skip the serial IPSCCP prologue (about 6.3 s) under `dev`.

### DV1: the dev tier skips the serial IPO prologue (2026-10-02; dev-only, cgu unchanged)

Snapshot `try-DV2`, which also contains the `ECO_OPT_PASS_TIMES` diagnostic below.

| variant | lowering | self-compile | fixed point |
|---|---|---|---|
| dev, with prologue | 43.09 s | 108.46 s | identical |
| **dev, no prologue** | **35.74 s** | 110.64 s (+2.2 % against base) | identical |
| dev `--dev-opt-o1`, no prologue | 34.43 s | 113.48 s (+4.8 %) | identical |

Whole-module IPSCCP is worth about 2 % at runtime. The dev tier now trades it for 7.4 s of
lowering.

**`ECO_OPT_PASS_TIMES=1`** is a new diagnostic. It prints each new-PM pass's exclusive time,
summed over workers (files `pt-cgu.stats` and `pt-dev.stats`). Partition opt totals: cgu 137.7 s
against dev 66.7 s. The 71 s of cgu-only work is:

| cgu-only work | Σ seconds |
|---|---|
| IPSCCP per partition | 16.2 |
| GlobalOpt per partition | 11.7 |
| a second InstCombine round | +12.2 (587k calls against 294k) |
| InferFunctionAttrs + CallGraph + PostOrderFunctionAttrs + GlobalDCE + CGSCC adaptor | about 10 |
| more SimplifyCFG and EarlyCSE | about 6 |

Module-level IPO inside a partition sees only externalized functions, so it can do almost
nothing; the useful IPSCCP is the whole-module prologue. This matches the equal self-compile
times of cgu and dev.

### TL: CPU timeline of a default (cgu) lowering (2026-10-02; diagnostic)

Snapshot `try-TL` adds `ECO_LOWERING_TIMELINE=1`, which prints a timestamped `[timeline]` line
at every stats scope and every module-level MLIR pass. `stats-backend-opt/cpu-timeline.py`
samples per-thread CPU from `/proc` every 100 ms and joins it to those markers. Raw files:
`tl-cgu.samples` and `tl-cgu.stderr`. Wall 44.07 s.

| time (s) | phase | CPU | shape |
|---|---|---|---|
| 0.00–0.72 | MLIR parse | ~130 % | serial |
| 0.72–7.35 | MLIR pipeline | 518 % avg | serial with 0.2–0.4 s bursts at 2,000–2,300 % |
| 2.05–3.62 | EcoToLLVM Stage 0 + pre-materialization | 100 % | serial |
| 3.72–4.02 | EcoToLLVM Stage 2 | ~1,900 % | parallel |
| 4.83–4.93 | decl strip | ~1,300 % | parallel |
| 5.53–5.83 | tail conversions | ~2,100 % | parallel |
| **5.94–7.34** | **tail conversions, one straggler chunk** | **100 %, 1 thread** | serial |
| 7.35–14.03 | MLIR → LLVM IR translation | 100 % | serial |
| **14.03–15.20** | **unlabelled: MLIR context/module teardown (M6 scope end)** | 100 % | serial |
| 15.20–15.57 | internalize + GlobalDCE | 100 % | serial |
| **15.57–16.43** | **unlabelled: LLVM marker expansions** (get-tag, list, string-len, value-eq, inline-deref) | 100 % | serial |
| 16.43–17.33 | capacity-hoist | 100 % | serial |
| **17.33–17.79** | **unlabelled: expandInlineAllocs / root ranges / sat** | 100 % | serial |
| 17.79–18.68 | `$cap` prepass + gc-free leaf propagation | 100 % | serial |
| 18.68–24.88 | IPO prologue (IPSCCP 5.7 s) | 100 % | serial |
| 24.89–28.55 | externalize + serialize | 100 % | serial |
| 28.72–42.66 | partition drain | **2,310 % avg** | 24 threads busy until about 41.7 s, then about 1 s of ramp-down |
| 42.67–43.83 | link (`ld`, a child process, not counted) | — | serial |

**Totals:** about 28 s of the 44 s wall is single-core. About 15.5 s runs near 24 cores. No phase
shows a contention signature (many threads, each partly busy). The "~500 %" readings are serial
work mixed with short parallel bursts, below `top`'s sampling resolution.

### IPO: what the IPSCCP prologue buys (2026-10-02; measurement, not a step)

Snapshot `try-IPO` adds `ECO_IPO_PROLOGUE=0`, a diagnostic that skips the prologue under cgu.

**What IPSCCP changes.** Measured on the real prologue input: `--dump-pre-rs4gc-ir`, then
`opt -passes='ipsccp<no-func-spec>' -stats`. The input has 73,514 defined functions, all internal
except `eco_main` and `__eco_init_globals`; 8.36M instructions. Scripts:
`ipsccp-attr-calls.py` and `ipsccp-attr-diff.py`. Stats: `ipsccp-opt.stats`.

| change | count |
|---|---|
| arguments constant-propagated | 2,662 (2,669 args unused afterwards, in 2,497 functions) |
| basic blocks made unreachable | 1,615, in only 117 functions, mostly the `Mlir_Bytecode_*` encoders |
| instructions removed | 15,123 (17,390 lines, about 0.2 % of the IR) |
| instructions simplified | 2,898 |
| arity-0 thunk call results folded | 28 call sites, 14 thunks |
| functions changed | 16,611 after normalizing attribute numbering and comments. In a sample of 40, about 80 % only gained `nuw`/`nsw`/`nneg` flags from range inference |

**Runtime value.** Self-compile with three interleaved runs per arm, all fixed point:

| arm | runs | median |
|---|---|---|
| prologue on | 108.06 / 108.71 / 108.40 s | 108.40 s |
| prologue off | 110.17 / 110.33 / 110.71 s | **110.33 s** |

That is **+1.93 s (+1.8 %)** without the prologue; the two ranges do not overlap.

**Where it comes from.** `perf` per-symbol samples for one self-compile of each arm; total CPU
is equal at about 200 s:
- **About 1.0 s:** `Array_shiftStep` + `Array_branchFactor` + `log@plt` + libm `log`. These thunks
  are `ceiling (logBase 2 32)`, recomputed with a `log` call on every `Array.get`.
- **About 0.8 s:** `mixHash` + `hashBase`. `hashBase()` returns the literal 2^26. With IPSCCP the
  constant reaches `mixHash`, so its two `srem`s become power-of-two remainders. Without it they
  are two 64-bit divisions by an unknown divisor, on every interning hash.

**Conclusion.** All of the measurable value is the return values of two hot arity-0 thunks. The
2,669 propagated arguments, the dead blocks and the wrap flags do not show at runtime on this
workload. The front-end constant-thunk plan
(`design_docs/mlir-level-partitioning-whole-program-steps.md` §5, A1) recovers it:
- phase 1, literal bodies, gets `hashBase`;
- phase 2, the exact evaluator, gets `shiftStep`/`branchFactor`.

A2 (constant arguments) has no measured payoff here.

### SPL: MLIR-split plans 01–04 landed (2026-10-02)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| SPL | 38.61 | -5.48 | 370.50 | 7,582,164 | 8.15 | — | 157.01 | WIN (codegen-changing: prologue deleted) | B4 |

Tree: plans `mlir-split-backend-01` … `-04` implemented (cap-hoist plan, gc-free plan and
reachability in MLIR; the cgu IPSCCP prologue deleted after the front end took over constant
thunks).
- **Input substitution:** `ecoGCR.mlir` no longer exists (`build/` was recreated). The run used
  `stats-backend-opt/p04/base.mlir`, the pre-04 compiler's self-compile output, which has the
  series input's exact size (13,249,839 B). It was not hash-verified against the lost file.
- **Effect:**
  - the serial prologue (IPSCCP 5.6 s + GlobalDCE 0.5 s) is gone;
  - internalize + GlobalDCE (0.38 s) is replaced by `Reachability finish` (0.11 s);
  - gc-free propagation drops from 0.29 s to 8 ms;
  - the MLIR pipeline gains `EcoReachability` / `EcoCapHoistPlan` / `EcoGcFreePropagation`
    (≈1.3 s, mostly parallel; 6.65 → 8.15 s).
- **Output:** the ELF is byte-identical to the plan-04 `ecoBaseOFF` arm (same input, prologue
  off, lowered before plan 03). So plans 01–03 are output-neutral and the only codegen change is
  the prologue removal. Its runtime tax was measured in plan 04: with folded thunks, 108.11 s
  vs 108.25 s.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-892e25.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             157.01 s   42.2%      24
    partition opt (sum over workers)              136.64 s   36.8%      24
  LLVM backend (RS4GC + opt + object emission)     20.88 s    5.6%       1
    parallel opt+emit drain (post-serialize...     14.16 s    3.8%       1
    partition RS4GC (sum over workers)             12.77 s    3.4%      24
    lazy extract (sum over workers)                 8.44 s    2.3%      24
  MLIR lowering pipeline                            8.15 s    2.2%       1
  MLIR -> LLVM IR translation                       6.30 s    1.7%       1
    externalize + serialize once (serial)           3.64 s    1.0%       1
  Link (clang++ driver)                             1.12 s    0.3%       1
    capacity-hoist analysis (serial)             921.18 ms    0.2%       1
  MLIR parse + verify                            725.34 ms    0.2%       1
    $cap inline prepass (serial)                 591.52 ms    0.2%       1
    partition balance (serial)                   158.98 ms    0.0%       1
  Reachability finish (serial)                   110.75 ms    0.0%       1
    gc-free leaf propagation (serial)              8.33 ms    0.0%       1
  TargetMachine init                               5.67 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                           371.65 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              3.06 s    0.8%       1
  (anonymous namespace)::EcoTailConversions...      2.11 s    0.6%       1
  (anonymous namespace)::EcoFoldProjectPass         1.15 s    0.3%   56944
  (anonymous namespace)::EcoCapHoistPlanPass     570.22 ms    0.2%       1
  (anonymous namespace)::EcoReachabilityPass     526.66 ms    0.1%       1
  (anonymous namespace)::EcoListTemplatePass     394.58 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       393.11 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   241.27 ms    0.1%       1
  (anonymous namespace)::EcoGcFreePropagati...   207.82 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                178.22 ms    0.0%       1
  (anonymous namespace)::EcoGCPreparePass        153.50 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            122.90 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       80.40 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    32.78 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...    26.87 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        23.29 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    20.51 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    15.24 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             9.30 s
```

</details>

### ES: EcoSplit — partition in MLIR, translate and lower in parallel (plan 05, 2026-10-02)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| ES | 25.53 | -13.08 | 365.09 | 7,694,944 | 8.16 | — | 156.24 | WIN (codegen-changing: partition assignment) | SPL |

Tree: `plans/mlir-split-backend-05-ecosplit.md` implemented. Input as for SPL
(`stats-backend-opt/p04/base.mlir`).
- **What left the critical path:**
  - the serial whole-module translation (6.30 s); translation now runs per partition in the
    workers, 22.4 s CPU in total;
  - the serial pre-RS4GC block (~3.0 s);
  - externalize + bitcode serialize (3.64 s);
  - the per-worker lazy re-parse/extract (8.44 s CPU);
  - the MLIR teardown, now on a helper thread.
- **Added:** the EcoSplit build, 0.73 s (parallel clone; about 1,011 `$cap` import copies per
  partition).
- **Correctness** (plan 05 gates):
  - every function's pre-RS4GC IR equals the translate-whole path's, modulo phi incoming
    order (73,602 / 73,602);
  - deterministic;
  - bootstrap fixed point, with all 5 lowering stages through EcoSplit;
  - AOT E2E 900/902 both normally and with every program force-split.
- **Runtime tax:** self-compile 108.54 s vs 110.50 s for the lazy-split compiler (N = 3).
- **Codegen-changing:** ownership comes from MLIR op counts, so per-partition `-O2` sees
  different neighbours.

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-64ef56.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             156.24 s   42.9%      24
    partition opt (sum over workers)              127.26 s   34.9%      24
    partition translate (sum over workers)         22.44 s    6.2%      24
  LLVM backend (EcoSplit: translate + lower...     15.32 s    4.2%       1
    parallel lower drain (post-split wait)         14.54 s    4.0%       1
    partition RS4GC (sum over workers)             11.32 s    3.1%      24
  MLIR lowering pipeline                            8.16 s    2.2%       1
    capacity-hoist analysis (serial)                3.18 s    0.9%      24
    $cap inline prepass (sum over workers)          2.36 s    0.6%      24
  Link (clang++ driver)                             1.10 s    0.3%       1
    gc-free leaf propagation (serial)               1.06 s    0.3%      24
  MLIR parse + verify                            743.73 ms    0.2%       1
    EcoSplit build (parallel clone)              734.77 ms    0.2%       1
  ------------------------------------------------------------------------
  total                                           364.45 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              3.06 s    0.8%       1
  (anonymous namespace)::EcoTailConversions...      2.06 s    0.6%       1
  (anonymous namespace)::EcoFoldProjectPass         1.13 s    0.3%   56944
  (anonymous namespace)::EcoCapHoistPlanPass     569.65 ms    0.2%       1
  (anonymous namespace)::EcoReachabilityPass     525.35 ms    0.1%       1
  (anonymous namespace)::EcoListTemplatePass     414.23 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       403.19 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   242.54 ms    0.1%       1
  (anonymous namespace)::EcoGcFreePropagati...   210.65 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                175.59 ms    0.0%       1
  (anonymous namespace)::EcoGCPreparePass        160.17 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            121.97 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       79.03 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    36.95 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...    29.94 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        23.25 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    23.22 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    15.65 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             9.28 s
```

</details>

### B4X: late export of dead-able `$cap` bodies (plan 06 B4, 2026-10-03)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| B4X | 25.59 | +0.06 | 361.69 | 7,691,812 | 8.32 | — | 154.09 | FLAT, kept (deletes work: 2,262 dead $cap bodies; −0.76 % binary) | ES |

Tree: `plans/mlir-split-backend-06-partition-boundaries.md` B4. An owned `$cap` that nothing
takes the address of is exported only after its owner's prepass, and only if it survived. The 2,262
bodies the whole-module path deleted are no longer emitted: function bodies equal the
translate-whole path's, with no extras. Plan 06's C2 (LPT on a fitted instruction-count cost)
was measured FLAT against this tree (medians 25.23 vs 25.19 s, no smaller finish spread) and
reverted. A and D were not built (FLAT in S6).

<details><summary>--lowering-stats banner</summary>

```
/usr/bin/ld: /tmp/eco-part-538eba.o: warning: relocation against `Compiler_Monomorphize_MonoTraverse_mapExprTypes_$_36256' in read-only section `.llvm_stackmaps'
/usr/bin/ld: warning: creating DT_TEXTREL in a PIE

=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             154.09 s   42.7%      24
    partition opt (sum over workers)              125.99 s   34.9%      24
    partition translate (sum over workers)         22.67 s    6.3%      24
  LLVM backend (EcoSplit: translate + lower...     15.24 s    4.2%       1
    parallel lower drain (post-split wait)         14.46 s    4.0%       1
    partition RS4GC (sum over workers)             11.24 s    3.1%      24
  MLIR lowering pipeline                            8.32 s    2.3%       1
    capacity-hoist analysis (serial)                3.17 s    0.9%      24
    $cap inline prepass (sum over workers)          2.35 s    0.7%      24
  Link (clang++ driver)                             1.12 s    0.3%       1
    gc-free leaf propagation (serial)               1.01 s    0.3%      24
    EcoSplit build (parallel clone)              741.60 ms    0.2%       1
  MLIR parse + verify                            701.22 ms    0.2%       1
  ------------------------------------------------------------------------
  total                                           361.10 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              3.17 s    0.9%       1
  (anonymous namespace)::EcoTailConversions...      2.06 s    0.6%       1
  (anonymous namespace)::EcoFoldProjectPass         1.12 s    0.3%   56944
  (anonymous namespace)::EcoCapHoistPlanPass     602.61 ms    0.2%       1
  (anonymous namespace)::EcoReachabilityPass     537.71 ms    0.1%       1
  (anonymous namespace)::EcoListCursorPass       412.30 ms    0.1%       1
  (anonymous namespace)::EcoListTemplatePass     408.44 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   234.09 ms    0.1%       1
  (anonymous namespace)::EcoGcFreePropagati...   217.81 ms    0.1%       1
  mlir::detail::OpToOpPassAdaptor                179.21 ms    0.0%       1
  (anonymous namespace)::EcoGCPreparePass        162.55 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass            123.61 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       82.10 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    36.24 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...    30.32 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        22.89 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    22.77 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    16.27 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             9.44 s
```

</details>

### P07: MLIR pipeline parallelism (plan 07, 2026-10-03)

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| P07 | 20.04 | -5.06 | 345.74 | 6,681,892 | 2.74 | — | 153.06 | WIN (byte-identical output) | B4X tree, re-measured 25.10 s as P07base |

Tree: `plans/mlir-split-backend-07-pipeline-parallelism.md`. It has eleven steps, each measured
alone; the per-step table is in the plan.

What changed:
- FoldProject is now a module pass.
- One chunked parallel helper replaces every per-element `parallelForEach`, whose
  diagnostic-handler mutex was taken twice per element.
- Symbol references are found without `getAttrDictionary` (the uniquer write lock).
- SCF→CF is lowered by a listener-free rewriter, siblings last-first. The 1.4 s straggler was
  O(#ifs × block length) recorded moves.
- Loop and demand collection in ListCursor, ListTemplate, EcoToLLVM pre-materialization and
  BFToLLVM now runs in parallel.
- The EcoToLLVM epilogue runs in parallel.
- EcoToLLVM stage 0 is sharded into scratch modules.

Results:
- **Every step's executable is byte-identical** to the reference (md5 `60fb7e14…`). So is the
  post-pipeline MLIR, dumped with the new `ECO_DUMP_LOWERED_MLIR`.
- Not codegen-changing, so no runtime-tax gate is needed.
- Max RSS −1.0 GB, from the conversion driver's per-move rewrite records that are no longer kept.
- Partition translate's CPU sum rose 22.6 → 32.0 s: upstream `legalizeDIExpressionsRecursively`
  now creates the attribute dictionaries that `symgraph::build` used to pre-create. The drain rose
  by +0.5 s.

<details><summary>--lowering-stats banner</summary>

```
=== eco-boot-native lowering stats ===

Phases (wall clock):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
    partition emit (sum over workers)             153.06 s   42.1%      24
    partition opt (sum over workers)              125.07 s   34.4%      24
    partition translate (sum over workers)         31.99 s    8.8%      24
  LLVM backend (EcoSplit: translate + lower...     15.28 s    4.2%       1
    parallel lower drain (post-split wait)         14.91 s    4.1%       1
    partition RS4GC (sum over workers)             11.64 s    3.2%      24
    capacity-hoist analysis (serial)                3.22 s    0.9%      24
    $cap inline prepass (sum over workers)          2.79 s    0.8%      24
  MLIR lowering pipeline                            2.74 s    0.8%       1
  Link (clang++ driver)                             1.11 s    0.3%       1
    gc-free leaf propagation (serial)            994.79 ms    0.3%      24
  MLIR parse + verify                            731.67 ms    0.2%       1
    EcoSplit build (parallel clone)              333.55 ms    0.1%       1
  ------------------------------------------------------------------------
  total                                           363.87 s

MLIR passes (wall clock, may overlap with phases):
  name                                        time         %      calls   
  ------------------------------------------------------------------------
  (anonymous namespace)::EcoToLLVMPass              1.27 s    0.3%       1
  (anonymous namespace)::EcoTailConversions...   285.92 ms    0.1%       1
  (anonymous namespace)::EcoControlFlowToSC...   241.53 ms    0.1%       1
  (anonymous namespace)::EcoCapHoistPlanPass     193.86 ms    0.1%       1
  (anonymous namespace)::EcoReachabilityPass     135.84 ms    0.0%       1
  (anonymous namespace)::EcoListCursorPass       116.01 ms    0.0%       1
  (anonymous namespace)::EcoGCPreparePass        112.55 ms    0.0%       1
  (anonymous namespace)::EcoPAPSimplifyPass       84.69 ms    0.0%       1
  (anonymous namespace)::EcoListTemplatePass      83.87 ms    0.0%       1
  (anonymous namespace)::EcoGcFreePropagati...    67.85 ms    0.0%       1
  (anonymous namespace)::EcoMarkGCLeafCalls...    32.16 ms    0.0%       1
  (anonymous namespace)::EcoCompareCaseRewr...    28.13 ms    0.0%       1
  (anonymous namespace)::RCEliminationPass        22.98 ms    0.0%       1
  (anonymous namespace)::UndefinedFunctionPass    22.28 ms    0.0%       1
  (anonymous namespace)::BFToLLVMPass             18.44 ms    0.0%       1
  (anonymous namespace)::JoinpointNormaliza...    16.41 ms    0.0%       1
  (anonymous namespace)::EcoFoldProjectPass        5.69 ms    0.0%       1
  ------------------------------------------------------------------------
  total                                             2.73 s
```

</details>

## 8. Summary

| step | wall (s) | Δ vs ref (s) | user CPU (s) | max RSS (kB) | MLIR pipeline (s) | whole-module opt (s) | partition emit Σ (s) | verdict | ref |
|---|---|---|---|---|---|---|---|---|---|
| base | 209.93 | — | 426.16 | 6,990,948 | 18.68 | 151.34 | 142.45 | baseline | — |
| A1 | 68.75 | -141.18 | 453.34 | 6,894,632 | 18.94 | — | 157.16 | WIN (codegen-changing) | base |
| A3 | 66.75 | -2.00 | 427.37 | 6,879,252 | 18.69 | — | 157.04 | FLAT, kept (deletes work; codegen-changing) | A1 |
| B1 | 62.93 | -3.82 | 370.70 | 6,831,908 | 14.24 | — | 157.83 | WIN | A3 |
| B3b | 59.63 | -3.30 | 369.39 | 6,885,472 | 11.88 | — | 157.00 | WIN | B1 |
| C2 | 58.75 | -0.88 | 376.73 | 7,071,588 | 12.24 | — | 156.94 | FLAT, reverted | B3b |
| D1 | 60.17 | +0.54 | 370.82 | 6,866,976 | 12.08 | — | 156.66 | FLAT, kept (instrumentation) | B3b |
| B2 | 58.86 | -0.77 | 368.90 | 6,881,700 | 10.85 | — | 156.54 | WIN (amendment-1 rule) | B3b |
| C2p | 56.78 | -2.08 | 374.70 | 7,044,696 | 10.65 | — | 157.07 | WIN (codegen-changing) | B2 |
| A1b | 54.10 | -2.68 | 372.89 | 7,038,684 | 10.65 | — | 157.28 | WIN (codegen-changing) | C2p |
| C3 | 54.67 | +0.57 | 373.31 | 7,095,612 | 10.75 | — | 158.10 | WIN (amendment-1 rule; deletes work) | A1b |
| B5 | 52.23 | -1.87 | 371.80 | 7,100,280 | 8.90 | — | 156.82 | WIN | A1b (best wall); tree C3 |
| M1 | 51.36 | -0.87 | 371.23 | 7,966,932 | 8.21 | — | 156.62 | WIN, marginal (amendment-1 rule) | B5 |
| X1 | 49.28 | -2.08 | 366.37 | 7,945,076 | 8.20 | — | 154.84 | WIN | M1 |
| A1c | 46.50 | -2.78 | 363.04 | 7,945,596 | 8.25 | — | 155.35 | WIN (codegen-changing) | X1 |
| A1d | 45.42 | -1.08 | 364.55 | 7,894,864 | 8.02 | — | 154.38 | WIN | A1c |
| S1 | 45.89 | +0.47 | 362.58 | 7,819,740 | 8.29 | — | 156.76 | FLAT, reverted | A1d |
| B8a | 45.39 | -0.03 | 360.90 | 7,870,416 | 7.89 | — | 154.42 | FLAT, kept (deletes work) | A1d |
| T1 | 45.99 | +0.57 | 363.58 | 7,914,876 | 7.89 | — | 153.86 | FLAT/worse, reverted | A1d |
| B6 | 44.10 | -1.29 | 361.25 | 7,869,536 | 7.39 | — | 153.42 | WIN | B8a |
| LC | 44.14 | +0.04 | 360.70 | 7,896,996 | 7.19 | — | 154.60 | FLAT, reverted | B6 |
| RC | 44.56 | +0.46 | 361.51 | 7,876,068 | 6.95 | — | 155.88 | FLAT, kept (deletes a serial pass) | B6 |
| CH | 44.59 | +0.49 | 367.93 | 9,052,228 | 7.02 | — | 157.68 | FLAT, reverted (RSS +1.18 GB) | B6 |
| B7 | 44.46 | +0.36 | 362.65 | 7,889,980 | 6.88 | — | 155.17 | FLAT, kept (removes quadratic scans) | B6 |
| B4 | 44.09 | -0.01 | 363.33 | 7,861,344 | 6.65 | — | 155.35 | FLAT, kept (one-line) | B6 |
| SPL | 38.61 | -5.48 | 370.50 | 7,582,164 | 8.15 | — | 157.01 | WIN (codegen-changing: prologue deleted) | B4 |
| ES | 25.53 | -13.08 | 365.09 | 7,694,944 | 8.16 | — | 156.24 | WIN (codegen-changing: partition assignment) | SPL |
| B4X | 25.59 | +0.06 | 361.69 | 7,691,812 | 8.32 | — | 154.09 | FLAT, kept (deletes work: 2,262 dead $cap bodies; −0.76 % binary) | ES |
| P07 | 20.04 | -5.06 | 345.74 | 6,681,892 | 2.74 | — | 153.06 | WIN (byte-identical; plan 07, 11 steps) | B4X (re-measured 25.10) |
