# Parallel LLVM Opt — Tiered Partitioned Backend

Implementation plan for `design_docs/backend-parallel-optimization.md`.

## Implementation status (2026-07-06)

Measured results in `backendstats-runs.txt`; design doc §7 updated.

| Phase | Status | Notes |
|---|---|---|
| 0 — measurement | ✅ partial | `scripts/backend-bench.sh` (compile-time harness). 0.1 `--time-passes` doesn't reach makeOptimizingTransformer's PM → folded into the dev-vs-O2 measurement, which *confirms* the inliner+fused-simplification was the bulk (backend −37 s). 0.3 per-partition timing skipped: cgu≈dev (31.4 vs 28.7 s) shows no bad straggler under the hash split. |
| 1 — shared split policy | ✅ done | `choosePartitionCount` + temp-file lifecycle hoisted into `runEcoBackend`; `EcoBackendJob.splitCodegen/splitEligible` + `EcoBackendResult`; eco-boot / EcoNativeDriver / ecoc migrated; `EcoNativeOptions.splitCodegen=0` (auto) brings parallel emission to `eco make` with no Elm change. Builds green; JIT E2E no regression; scale smoke (both paths → working 61.8 MB exe). |
| 2 — custom partitioner | ⏸ substituted | **Reused the proven `llvm::SplitModule`** for the dev/cgu tiers instead of a from-scratch `EcoModulePartition` — the ~15-45-line insertion the design doc predicted, on already-validated infra (bitcode round-trip, per-thread ctx/TM, multi-blob stackmap). The size-cost balancer (`partitionBySize`) and call-graph clustering (`partitionByCallGraph`) remain as measured refinements (only needed if a straggler shows — none observed). |
| 3 — dev tier | ✅ done | `--parallel-opt=none\|dev\|cgu` (eco-boot) + `EcoNativeOptions.parallelOpt`. Cheap whole-module IPO prologue (IPSCCP/GlobalOpt/function-attrs/GlobalDCE) → per-partition no-inline function pipeline. **Backend 65.8→28.7 s (2.3×), total 86.5→49.0 s, CPU 180→281%.** GC-safe (RS4GC stays before all opt; never combined with `--rs4gc-after-opt`). |
| 4 — release tier (cgu) | ✅ done, **gate passed** | cgu = per-partition **full -O2** (keeps intra-partition inlining). Backend 65.8→31.4 s (2.1×), exe size within 0.1% of baseline. **Recursive-tax gate MEASURED (clean self-host, §below): cgu = −0.5% (within noise, ~0), dev = +1.7% — cgu passes ≤3% with huge margin.** ⇒ the `available_externally` glue replication + `alwaysinline` trampolines are **NOT needed** (cross-partition inlining loss is negligible for the compiler's own runtime); cgu is release-viable as-is. |
| 5 — ThinLTO | ⏸ not needed yet | Only if the cgu recursive-tax gate fails. |

Test hook added: `ECO_AOT_EXTRA_FLAGS` in `test/aot_e2e_main.cpp` lets the AOT
E2E suite exercise the backend under `--parallel-opt=dev/cgu`.

**Validation (all green):**
- Builds: all targets clean.
- JIT E2E (`check`): 1528/1547 (19 failures all pre-existing elm-http network;
  0 codegen/GC; no regression).
- **Self-host equivalence (strongest):** the 85,686-fn compiler built under
  default/dev/cgu runs with BYTE-IDENTICAL functional output (banner + full GC
  allocation profile + all histograms; only timing differs). Identical
  allocation behaviour ⇒ same execution, so no miscompile.
- **AOT elm-core** (serial, fresh cache/mode): default 98/98, dev 99/99,
  cgu 99/99 — 0 backend failures each.
- Perf: `backendstats-runs.txt`.

**Recursive-tax measurement (2026-07-06, clean self-host env).** Method: `rm -rf
build ~/.eco`, `cmake --preset build`, rebuild `eco-boot-native` +
`eco-compiler.mlir`; build three compilers `eco-boot-native
[--parallel-opt=none|dev|cgu] eco-compiler.mlir -o eco-{mode}`; run each through
the Stage-7a self-compile (`make --optimize … --output=*.mlir`, frontend only =
the mode-sensitive Elm-native code), fresh `--builddir` per run (cold 234-module
compile), `/usr/bin/time -v` **user time** (single-threaded, 99% CPU). All runs
rc=0, 234 modules.

| mode | user time (s), samples | mean | tax vs none |
|---|---|---|---|
| none | 273.3 / 274.0 / 270.9 | 272.7 | — |
| dev  | 278.4 / 276.6          | 277.5 | **+1.7 %** |
| cgu  | 271.8 / 270.9          | 271.4 | **−0.5 % (within ~1% noise ≈ 0)** |

**cgu passes the ≤3 % gate with a huge margin (~0 %)** — its per-partition full
-O2 keeps the inlining that matters (most callee/caller pairs are intra-partition;
the hash-split's cross-partition loss is negligible for the compiler's runtime).
Even fully-no-inline **dev costs only +1.7 %**, confirming the design thesis: the
Elm frontend already inlines (threshold 10) and the closure/PAP/alloc glue bottoms
out in external runtime calls, so LLVM inlining contributes little to *this*
program's runtime. Consequence: the deferred Phase-4 replication + ThinLTO work is
**not needed** — cgu is release-viable as-is, and dev is safe even for the
self-host build (though still scoped to dev iteration by default).

Caveat: the `~/.eco`/`eco-stuff` frontend caches corrupt easily under
concurrent/back-to-back runs (documented, orthogonal to the backend); AOT E2E
must be run serially with a fresh `eco-stuff` per mode. A `~/.eco` full purge
loses network-seeded package sources — delete only the corrupt `eco-stuff`.

---

## Goal

Parallelize the last serial stage of the AOT backend — the whole-module `-O2`
optimization pipeline (~51 s of the ~86 s self-host build, running at 107 % CPU
on 24 cores) — without silently taxing the quality of the produced binary
(which is the compiler itself). Two production tiers on shared partitioning
infrastructure, landed in phases, each behind a green test run:

- **Dev tier (no cross-partition IPO):** cheap whole-module IPO prologue →
  **size-balanced** N ≈ cores partitions → per-partition no-inline function
  pipeline → per-partition emit. Fastest compile; output quality irrelevant for
  iteration builds. Needs eco's own **instruction-count balancer** — stock
  `SplitModule` assigns by `MD5(name) % N` and balances clusters by GV *count*,
  so one thread can inherit all the heavy functions.
- **Release tier (keep-IPO codegen units, rustc's model):** **call-graph/SCC-aware
  clusters** (minimizing cut call-edges is a graph min-cut objective; every cut
  edge is a permanently lost inline) sized to N ≈ cores, **plus physically
  replicated `alwaysinline`/small-callee glue** (`available_externally` copies,
  rustc's `LocalCopy`) → per-partition **full `-O2`** → per-partition emit.
  Keeps most inlining while parallelizing the whole opt stage.

Prerequisite Tier 0: hoist the existing emission-split *policy* out of
`eco-boot.cpp` into the shared `EcoBackend` layer so every driver
(`EcoNativeDriver` = `eco make` + self-host stages 6–9, `eco-boot`, `ecoc`)
gets partitioned codegen — today only `eco-boot` has it.

## Current state (verified — see design doc §2/§3/§6 for evidence)

- Pipeline (exe output): `internalizeAndDCEForExecutable` (everything except
  `eco_main`/`__eco_init_globals` internal, then GlobalDCE; `eco-boot.cpp:732`)
  → whole-module RS4GC + `frame-pointer=all` (`EcoBackend.cpp:290`) →
  **whole-module `makeOptimizingTransformer` -O2, serial**
  (`EcoBackend.cpp:300-304`) → `emitObjectFilesSplit` = `SplitModule` N ways,
  bitcode round-trip, per-thread `LLVMContext`+`TargetMachine`, **emission
  only** (`EcoBackend.cpp:93-179`) → `linkExecutable` (vector overload,
  shared, `EcoNativeDriver.cpp:677`).
- Because the split runs *after* opt, the shipped state loses **zero** IPO
  (verified byte-identical N=1 vs N=8). The produced binary gets 100 %
  whole-module IPO today; any split-before-opt change is a quality trade that
  must be measured (design doc §3/§4).
- Measured (self-host, 24 cores): total 86.5 s; LLVM backend 66.75 s =
  RS4GC ~4.8 s + **opt ~51.3 s serial** + emit ~10.6 s parallel.
- `llvm::SplitModule` under `PreserveLocals=false`: externalizes all locals
  first, so its only call-graph clustering branch (gated on `hasLocalLinkage`)
  never fires; assignment is pure `MD5(name)%N`; out-of-partition GVs are
  cloned as **bodyless declarations** (`CloneModule.cpp:142-148`) — hence
  cross-partition calls are un-inlinable, and hence the two tiers above
  (design doc §6.1).
- The `-O2` bottleneck is the CGSCC `InlinerPass`, which **fuses**
  `buildFunctionSimplificationPipeline` inside itself
  (`PassBuilderPipelines.cpp:989-991`, `:1279`). Cheap, high-value module IPO
  to keep: IPSCCP, GlobalOpt, GlobalDCE, function-attrs (design doc §6.3).
- GC safety of per-partition opt **after** whole-module RS4GC: verified safe
  (statepoints are per-function and already stamped; REP_LLVM_001(a) exposure
  unchanged; `StackMap::parse` is multi-blob keyed by absolute return address;
  GC-root globals stay single-definition under externalization). Design doc §5.
- Split policy today: `--split-codegen` `cl::opt` and the ~40-line
  partition-count + temp-file block exist **only** in `eco-boot.cpp:170,744-800`.
  `EcoNativeDriver.cpp:247-257` never sets `job.numPartitions` → `eco make`
  and self-host stages 6–9 emit single-threaded. The mechanism
  (`emitObjectFilesSplit`) and the linker are already shared; only the policy
  is stranded (design doc §8.1).
- The frontend inliner (`MonoInlineSimplify`, threshold 10, pre-closure-lowering)
  does NOT make LLVM inlining redundant; the big LLVM win is folding
  first-order direct calls across the ~85 k monomorphized functions. Closure/
  PAP/alloc glue bottoms out in *external* runtime calls that module-opt can't
  inline regardless (design doc §4).

## Invariants and constraints

- **REP_LLVM_001(a)** (no `i64` from `ptrtoint ptr<1>` live across a
  `gc.statepoint`): preserved — RS4GC stays *before* all optimization, whole
  module, in every tier. Do **not** combine any of this with the experimental
  `--rs4gc-after-opt`; that flag stays on its own validation track.
- **HEAP_020** (stackmap vs RootSet root split): untouched; more partitions
  only means more `.llvm_stackmaps` blobs, which the parser already handles.
- Externalization rules: any custom splitter must reproduce `SplitModule`'s
  `PreserveLocals=false` semantics — promote cross-partition locals to a
  **single** `ExternalLinkage + HiddenVisibility` definition (never duplicate:
  GC-root globals and `__eco_type_graph` must keep exactly one definition).
- Quality gate: the produced binary is the compiler. **No tier becomes a
  release default until the recursive-tax benchmark (Phase 0) shows its
  regression is within budget** (proposed: ≤ 3 % on the self-host lowering
  workload for the release tier).

## Performance flag reference — dev mode vs production mode

Every flag that affects compile time or produced-code quality, verified against
source (2026-07-06). Grouped by intent so we remember what to apply in each
"mode"; a single user-facing mode switch that bundles these is future work
(see the note at the end of this section).

### Backend flags (`eco-boot-native` `cl::opt`s; `EcoNativeOptions` where plumbed)

| Flag | Default | Dev (fast compile) | Production (fast code) | Notes |
|---|---|---|---|---|
| `-O <n>` (0–3, **space-separated**: `-O 2`, not `-O2`) | 2 | `-O 0` until Phase 3 lands; then `-O 2 --parallel-opt=dev` | `-O 2` | `-O 1` ≈ `-O 2` compile time (measured non-win — don't bother); `-O 0` is the real dev lever today (~37 s vs ~86 s full build). `-O 3` unmeasured, assume not worth it. |
| `--split-codegen=N` | 0 = auto (min(cores,16), ≥4000 fns) | auto | auto | Quality-neutral in the shipped post-opt position (byte-identical N=1 vs N=8). `eco-boot` only today; Phase 1 brings it to `eco make`. `1` = off (debugging). |
| `--parallel-opt=none\|dev\|cgu` (**introduced by this plan**, Phases 3–4) | `none` | `dev` | `none` until the Phase 4 gate passes, then `cgu` | `dev` = size-balanced split + no-inline per-partition pipeline (fast compile, slower code). `cgu` = call-graph units + replicated glue + per-partition full `-O2` (parallel compile, ≤3 % code regression gate). |
| `--gc-sections` | off | off | optional on | Binary size only (−2.7 %); no compile-time effect. Off until broadly validated. |
| `--rs4gc-after-opt` | off | **off** | **off** | EXPERIMENTAL, GC-risk (REP_LLVM_001(a)); ~−11 s if it ever validates, but not part of either mode until the GC-stress campaign signs it off. |
| `--emit=exe\|obj\|llvm\|mlir`, `--lowering-stats`, `--dump-*-rs4gc-ir` | — | — | — | Diagnostics; negligible/neutral. Input as MLIR *bytecode* (default) not text — text parse is slower (`eco make --textMlir` is debug-only). |

### Frontend knobs (`eco-config.json` → `Compiler/Eco/Config.elm`)

These trade frontend compile time and downstream IR volume against produced-code
quality. Today there is one setting for both modes; they are candidates for the
future mode split but are **not** changed by this plan.

| Knob | Default | Effect |
|---|---|---|
| `inline.threshold` | 10 | Higher → more Mono-IR inlining → better code, more IR for every downstream phase (slower compile). Lower/0 → faster compile, worse code. |
| `inline.maxPerFunction` / `inline.fixpointIterations` | 1000 / 4 | Caps on the same pass; lowering them bounds worst-case frontend time. |
| `bytesFusion.enabled` | true | Off is faster to compile but a large runtime regression in bytes-heavy code (decoders). Keep on in both modes. |
| `logicalTypes.customMaxFields` | 8 | Unboxed-aggregate eligibility — code-quality knob, negligible compile-time effect. |

### `eco make` CLI

- `--optimize` / `--debug` select the *frontend* mode (Prod/Dev/Debug at the
  AST level — e.g. field-name shortening, debug instrumentation). They do
  **not** control the native backend opt level.
- **Gap (must close in this work):** the unified `eco` binary drives the
  backend through the C ABI `eco_native_lower_and_link{,_bytes}`
  (`EcoNativeDriver.cpp:1170-1185`), which constructs a **default**
  `EcoNativeOptions` — native `-O`, `--split-codegen`, `--parallel-opt`,
  `--gc-sections` are all unreachable from `eco make` today (always `-O2`,
  no split). Phase 1 extends the C ABI so these plumb through; without that,
  neither mode is selectable in the production path.

### Compiler-build-time (not user flags, listed to avoid confusion)

- `ECO_LOWERING_VALIDATION` (CMake): builds the *compiler itself* with extra
  verifier passes — slows every compile it runs; for compiler development and
  GC-validation campaigns only, never in shipped binaries.

### Mode summary (what to apply until a single mode switch exists)

| | **Dev mode** | **Production mode** |
|---|---|---|
| Native opt | `-O 0` (today) → `-O 2 --parallel-opt=dev` (after Phase 3) | `-O 2` |
| Parallel opt | `--parallel-opt=dev` | `none` → `--parallel-opt=cgu` after Phase 4 gate |
| Emission split | `--split-codegen=0` (auto) | `--split-codegen=0` (auto) |
| Link | — | `--gc-sections` (optional, size) |
| Frontend | default | `--optimize` |
| Never (either mode) | `--rs4gc-after-opt` | `--rs4gc-after-opt` |

**Future simplification (out of scope here):** collapse this into a single
`eco make --mode=dev|release` (or profile in `eco.json`) that selects the whole
bundle — frontend mode, native `-O`, `--parallel-opt`, link options — so users
never touch individual flags. This plan keeps the flags explicit so each can be
measured and validated independently first.

## Phases

### Phase 0 — Measurement gates (no behaviour change)

Everything later is accepted/rejected on numbers, so build the ruler first.

1. **Pass-level opt breakdown.** Confirm the "fused inliner dominates the 51 s"
   inference (design doc flags it as *inferred*). `eco-boot-native` links LLVM's
   `cl::opt` surface, so try `--time-passes` first
   (`... --time-passes --emit=llvm -O 2 -o /dev/null <input> 2> passes.txt`).
   If the flag doesn't reach the NewPM instance inside
   `makeOptimizingTransformer`, add a temporary `TimePassesHandler`-enabled
   custom pipeline in a debug branch of `runEcoBackend`. Record: inliner+fused
   simplification vs post-inline tail fractions.
2. **Recursive-tax benchmark harness.** `scripts/` (or `test/perf/`) script:
   - build the self-host compiler binary under mode X,
   - run that binary 3× lowering `build/compiler/build-kernel/bin/eco-compiler.mlir`
     (fixed workload), report median wall + CPU%,
   - also record the *build* time and binary size of step 1.
   Output appended to `backendstats.txt` in the existing format. Baseline run =
   current whole-module `-O2`. This is the acceptance gate for Phases 3–5.
3. **Per-partition timing.** Add a `LoweringStats` scope per partition worker
   (opt time + emit time, labelled `partition[i]`) so straggler skew is visible.
   Gate behind `--lowering-stats` as today.

**Validation:** no functional change; `TEST_FILTER=codegen cmake --build build
--target full` green.

### Phase 1 — Tier 0: shared split policy in `EcoBackend` (quality-neutral)

Design doc §8.1, verbatim intent: don't duplicate `eco-boot`'s block, hoist it.

**API changes (`EcoBackend.h`):**

```cpp
struct EcoBackendJob {
    ...
    /// Partitioned-codegen request: 0 = auto (min(cores,16), gated >= 4000
    /// defined fns, ~1 part / 2000 fns), 1 = off, N = explicit. Replaces the
    /// caller-computed numPartitions.
    unsigned splitCodegen = 0;
    /// True only for plain executable output (not -c / .so / .node). The
    /// caller already computes this for internalizeAndDCEForExecutable.
    bool splitEligible = false;
};

struct EcoBackendResult {
    /// Object files actually produced (1..N). Caller links these (vector
    /// overload of linkExecutable) and removes them. For single-object
    /// output this is { job.objectFilePath }.
    std::vector<std::string> objectFiles;
};

llvm::Error runEcoBackend(llvm::Module &m, const EcoBackendJob &job,
                          EcoBackendResult &result);
```

**Implementation:**
1. `choosePartitionCount(const Module&, unsigned request, bool eligible)` in
   `EcoBackend.cpp` — moves the policy from `eco-boot.cpp:744-765` (count
   defined fns; gate `kMinFnsToSplit = 4000`; auto = `min(cores,16)`;
   `bySize = max(2, fns/2000)`; explicit N honoured as-is).
2. `runEcoBackend` mints the temp part `.o`s (`createTemporaryFile`) and fills
   `result.objectFiles`; on error it removes them itself.
3. `eco-boot.cpp`: delete the inline block; keep its `--split-codegen` flag and
   pass it through `job.splitCodegen`; link `result.objectFiles`.
4. `EcoNativeDriver.cpp`: set `job.splitCodegen` (new `EcoNativeOptions::
   splitCodegen`, default 0 = auto) + `job.splitEligible`; link
   `result.objectFiles` via the existing vector overload (`:677`).
5. `ecoc.cpp` object path: `splitEligible = false` (unchanged behaviour).
6. **Close the C-ABI options gap** (see the flag reference above): the unified
   `eco` binary calls `eco_native_lower_and_link{,_bytes}`
   (`EcoNativeDriver.cpp:1170-1185`), which builds a default-constructed
   `EcoNativeOptions` — so `-O` level and split/parallel options never reach
   the production path. Extend the C ABI with an options parameter (versioned
   struct or key–value pairs; pick whichever matches the existing
   kernel-call conventions) carrying at minimum `optLevel`, `splitCodegen`,
   and (Phase 3+) `parallelOpt`; thread it from the Elm `make` flags. With
   auto as the default, absent options keep today's behaviour.

**Validation:**
- Byte-identical output N=1 vs N=8 on the 15 GC-heavy modules (existing check,
  re-run) — still guaranteed, split remains post-opt.
- `cmake --build build --target full` green; embed/N-API (.so/.node) output
  unaffected (`splitEligible=false` path).
- Measure `eco make` and a stage 6–9 self-host build before/after: expect the
  ~85 s → ~10.6 s emission win to appear in the production path.
- Record in `backendstats.txt`.

### Phase 2 — Partitioning infrastructure (`EcoModulePartition`)

New files `runtime/src/codegen/EcoModulePartition.{h,cpp}` (linked like
`EcoBackend.cpp` into ecoc / EcoRunner / eco-boot-native / the driver lib).
No pipeline behaviour change yet — infrastructure + unit-testable planning.

```cpp
namespace eco {
struct PartitionPlan {
    // Partition id per defined function; non-function GVs may stay hash-
    // assigned (data emission cost is negligible).
    llvm::DenseMap<const llvm::GlobalValue *, unsigned> assignment;
    // Per-partition available_externally replica sets (Phase 4; empty in dev).
    std::vector<llvm::DenseSet<const llvm::GlobalValue *>> replicas;
    unsigned numParts;
};

/// Dev tier: LPT bin-packing. Cost = per-function instruction count. Sort
/// defined functions largest-first, assign each to the least-loaded of N bins.
PartitionPlan partitionBySize(const llvm::Module &m, unsigned n);

/// Release tier: rustc-style codegen units. See below.
PartitionPlan partitionByCallGraph(const llvm::Module &m, unsigned n,
                                   const ReplicationBudget &budget);

/// Split m per plan and hand each sub-module to cb, mirroring SplitModule's
/// PreserveLocals=false semantics: externalize all locals (ExternalLinkage +
/// HiddenVisibility, single definition), CloneModule with the predicate
/// "assignment[GV] == i || replicas[i].contains(GV)", then flip replica
/// clones to available_externally. Serial, parent thread (bitcode
/// serialization per partition exactly as emitObjectFilesSplit does today).
void forEachPartition(llvm::Module &m, const PartitionPlan &plan,
                      llvm::function_ref<void(std::unique_ptr<llvm::Module>)> cb);
}
```

**`partitionByCallGraph` algorithm (rustc's place-then-merge):**
1. **Seed clusters by Elm module prefix.** Symbol names embed the defining
   module (`Compiler_Generate_MLIR_Functions_...`, `Terminal_Main_lambda_12120`)
   — the analogue of rustc's `characteristic_def_id`. Derive the cluster key
   from the mangling scheme (verify the exact scheme against the MLIR
   generator; lambdas/wrappers inherit their parent's prefix, which the name
   already carries). Unparseable names → fallback hash cluster.
2. **SCC safety.** Elm module imports are acyclic, so cross-module call cycles
   should not exist — but verify: build the call graph over defined functions,
   compute SCCs (`llvm::scc_iterator`), and if any SCC spans clusters
   (kernel wrappers, generated glue), merge those clusters. Assert + stat.
3. **Merge down to N.** While clusters > N: rustc's rule — sort by instruction
   count, merge the smallest cluster into the surviving cluster with the
   greatest **cross-edge weight** to it (static call-site count; upgrade to
   inlined-overlap once replica sets exist), tie-break into the least-loaded.
   This is the greedy min-cut/size-balance compromise.
4. **Replica sets (release tier).** Per partition: BFS from its members over
   call edges to out-of-partition callees, admitting a callee if
   `alwaysinline` OR `instCount <= threshold` (default 100, ThinLTO's
   `-import-instr-limit`), decaying the threshold ×0.7 per hop (ThinLTO's
   transitive rule). Record as `replicas[i]`. `EliminateAvailableExternally`
   in the partition's own -O2 run drops the copies post-inlining, so no
   duplicate object code (verify with `nm` in tests).

**Validation (pure unit level, no pipeline switch yet):**
- gtest-style unit checks (or a `--dump-partition-plan` debug flag on
  eco-boot-native): bin sizes within ~10 % of each other for
  `partitionBySize`; no cross-cluster SCC after step 2; replicas respect
  budget; every defined function assigned exactly once.
- `forEachPartition` output linked back together must produce a working
  binary in *emission-only* mode: run it as a drop-in replacement for
  `SplitModule` in `emitObjectFilesSplit` behind a temporary flag and re-run
  the byte-identical N=1 vs N=8 check (post-opt split ⇒ still byte-identical;
  this validates externalization + cloning correctness cheaply, independent of
  any opt-stage change).

### Phase 3 — Tier 1: dev tier (`--parallel-opt=dev`)

**Flag:** `--parallel-opt=none|dev|cgu` on eco-boot-native +
`EcoNativeOptions::parallelOpt` (default `none` — today's behaviour).

**Pipeline (exe output, `dev`):**
1. internalize + GlobalDCE (unchanged) → RS4GC + FP whole-module (unchanged).
2. **Serial cheap-IPO prologue** (new, small `ModulePassManager`):
   `IPSCCPPass` → `GlobalOptPass` →
   `PostOrderFunctionAttrsPass` (CGSCC adaptor) +
   `ReversePostOrderFunctionAttrsPass` → `GlobalDCEPass`.
   Captures the cross-module facts (constants, purity, dead code) that are
   disproportionately valuable on monomorphized output, at O(module) cost
   (design doc §6.3). Measure it; expected a few seconds.
3. `partitionBySize(min(cores, 16))` → `forEachPartition` → per-partition
   worker thread (extends the existing `emitObjectFilesSplit` lambda):
   `parseBitcodeFile` → **no-inline function pipeline** —
   `AlwaysInlinerPass` (honour `alwaysinline` attrs) then
   `createModuleToFunctionPassAdaptor(PB.buildFunctionSimplificationPipeline(
   OptimizationLevel::O2, ThinOrFullLTOPhase::None))` — → `emitObjectFile`
   on the same thread (opt+emit fused; one split, no re-split).
4. Skip the whole-module `makeOptimizingTransformer` when `parallelOpt != none`.

Note `makeOptimizingTransformer` has no IPO toggle (verified) — step 3's
pipeline is the ~30 lines of new `PassBuilder` code.

**Validation:**
- Full E2E (`--target full`) + JIT suite green under `--parallel-opt=dev`.
- Behavioural N-independence: linked binaries at N=1 vs N=8 run the AOT E2E
  suite identically (byte-comparison is not expected — object ordering
  differs — per-function code is N-independent but don't over-claim; compare
  behaviour + spot-check a few functions' disassembly).
- Straggler check (Phase 0.3 stats): max/median partition opt time ≤ ~1.5×;
  this is the direct test of the size balancer vs the stock hash.
- Benchmark: backend wall-clock target ~25–30 s (from 86.5 s); recursive-tax
  run recorded for reference (expected noticeably slower binary — acceptable,
  this tier is for iteration builds, never the shipped compiler).
- **Rollout:** opt-in flag first; wire into an `eco make` dev profile (or
  `-O1` semantics) only after a soak period.

### Phase 4 — Tier 2′: release tier (`--parallel-opt=cgu`)

**Pipeline (exe output, `cgu`):** identical to Phase 3 except:
- step 3 uses `partitionByCallGraph(min(cores, 16), budget)` **with replica
  sets**, and
- the per-partition pipeline is **full `-O2`** (`makeOptimizingTransformer`
  per partition — no new pipeline code): intra-partition CGSCC inlining runs
  over real bodies including the `available_externally` replicas; the
  cheap-IPO prologue (step 2) still runs whole-module first.

**Glue marking (small, separate commit):** add `alwaysinline` at lowering to
the internal wrapper trampolines (`getOrCreateWrapper`,
`EcoToLLVMClosures.cpp:381`) and any other hot generated glue identified by
profile — these are the rustc-`#[inline(always)]`-equivalents that must be in
every partition's replica set. (The external runtime kernel calls are
unaffected — un-inlinable at module level regardless.)

**Validation / acceptance gate:**
- Full E2E + JIT suites green; GC-stress run (heavy-GC AOT tests) green — the
  inliner now runs per-partition over statepoint-bearing IR, same as it runs
  whole-module today, but re-verify.
- `nm` check: no duplicate strong definitions from replicas (all
  `available_externally` copies eliminated or internal).
- **Recursive-tax benchmark: produced-compiler slowdown ≤ 3 % vs whole-module
  baseline.** If it fails: raise the replication threshold, raise N-locality
  (fewer partitions), re-measure. Only if it still fails → Phase 5.
- Compile-time target: backend ~40–45 s (opt 51 s → ~8–12 s at N=16, design
  doc §7); confirm scaling/memory (RSS stayed ≤ ~8 GB at N=16 expected;
  measure — the machine has 15 GB).
- **Rollout:** opt-in until the gate passes on two consecutive self-host
  rebuild cycles (compiler built by a `cgu`-built compiler re-passes the
  gate), then default for executable release output.

### Phase 5 — Decision point: ThinLTO (only if Phase 4 misses the quality gate)

Not scheduled by default. If the `cgu` tier's regression exceeds budget even
after tuning, replace hand-rolled replication with LLVM's real machinery:
per-partition `ModuleSummaryIndex` (`buildModuleSummaryIndex`) → combined
index → `ComputeCrossModuleImport` → `FunctionImporter::importFunctions` per
partition before its `-O2`. Prefer driving the existing `LTO` /
`ThinLTOCodeGenerator` API over hand-rolling (design doc §6.2 option 1).
Everything from Phases 1–4 (shared policy, partition plan plumbing, per-
partition opt+emit workers, benchmarks) is reused as-is.

## Explicitly out of scope

- One-function-per-module granularity (per-module overhead + total IPO loss;
  rustc rejects it with a hard 1800-byte CGU floor — design doc §6.4).
- `--rs4gc-after-opt` (separate GC-critical validation track; do not couple).
- MLIR-side pass parallelism (B1 — measured neutral previously; don't retry).
- Changing the JIT path (`JITInvokePacked` — no object emission, untouched).

## Risk register (from design doc §9)

| Risk | Mitigation |
|---|---|
| Produced-binary regression (recursive tax) | Phase 0 harness; ≤ 3 % gate before any release default |
| Inliner-dominance inference wrong → dev tier disappoints | Phase 0.1 `--time-passes` measurement before building Phases 3–4 |
| Straggler partitions (hash/size skew) | own LPT balancer + per-partition stats; 1.5× skew gate |
| Replicas not eliminated → bloat/dup symbols | `nm` check in Phase 4 validation |
| `makeOptimizingTransformer` not `buildPerModuleDefaultPipeline`-shaped | Phase 0.1 confirms; custom `PassBuilder` pipeline is the fallback either way |
| Memory at N=16 (15 GB machine) | per-partition bitcode holds only its defs; monitor RSS in benchmarks; reduce N if needed |
| Cross-cluster SCCs from generated glue | Phase 2 SCC-merge fallback + assert/stat |
