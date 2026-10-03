# MLIR-level split backend: master plan

**Status:** outline, 2026-10-02. Nothing is built.

**Child plans,** numbered riskiest first. Risk means the most likely to fail to be implemented
because of the hazards identified; the numbering is also the implementation order:
- `plans/mlir-split-backend-00-spikes.md`: every spike, measurement and census from 01–04 and
  the master's go/no-go spike, done first to de-risk. **Results 2026-10-02: all GO** (see its §8).
- `plans/mlir-split-backend-01-cap-hoist-plan.md`
- `plans/mlir-split-backend-02-gc-leaf-propagation.md`
- `plans/mlir-split-backend-03-reachability.md`
- `plans/mlir-split-backend-04-constant-thunks.md`
- `plans/mlir-split-backend-05-ecosplit.md`: the split itself (§4), implemented 2026-10-02.
- `plans/mlir-split-backend-06-partition-boundaries.md`: EcoSplit follow-ups, 2026-10-03.
- `plans/mlir-split-backend-07-pipeline-parallelism.md`: the serial MLIR pipeline made parallel,
  2026-10-03 (byte-identical output; pipeline 8.02 → 2.74 s, wall 25.10 → 20.04 s).

Renumbered on 2026-10-02. The old numbers were: 01 reachability, 02 cap-hoist, 03 gc-leaf,
04 thunks. References inside every plan were updated to the new numbers.

**Background:**
- Research: `design_docs/mlir-level-partitioning-whole-program-steps.md`.
- Measurements: `benchmarks/backend-opt-loop.md`, entries TL (CPU timeline), DV1 and IPO.
- Previous series: `plans/backend-lowering-optimization.md`.

## 1. Goal

Lowering the self-hosted compiler takes 44 s today. About 28 s of that is single-core. From the
TL timeline, roughly 20 s comes from three serial blocks:

| serial block | time |
|---|---|
| MLIR → LLVM translation into ONE `llvm::Module` | 6.7 s |
| Whole-program LLVM steps: internalize/DCE, marker expansion, capacity hoisting, `$cap` prepass, gc-leaf propagation, IPSCCP prologue | ~10 s |
| Bitcode serialize + per-worker re-parse | 3.7 s plus ~0.35 s per worker |

**The target pipeline:**
1. Split the program into partitions in **MLIR**. The MLIRContext is thread-safe; an
   LLVMContext is not.
2. Translate each partition **in parallel** into its own LLVMContext.
3. Run all LLVM work per partition, so the bitcode round trip disappears.
4. Precompute every whole-program fact on the MLIR side or in the Elm front-end, and carry it
   as attributes.

**Ceiling:** about 20 s off the 44 s. **Constraint:** the generated code must stay at least as
good. Checks: recursive tax ≤ 3 %, and the bootstrap fixed point.

## 2. Target pipeline

```
Elm front-end: constant thunks (04)
MLIR pipeline ... EcoTailConversions
  → EcoReachability (03): DCE plus a per-symbol referrer set; roots main, __eco_init_globals
  → EcoCapHoistPlan (01): covered and budget as function attributes
  → EcoGcFreePropagation (02): gc-leaf passthrough, using the shared marker may-GC table
  → EcoSplit (this plan, §4): partition ownership; internal vs hidden linkage; attributes
    copied onto declarations; `$cap` bodies copied in as available_externally
per partition, in parallel:
  translate → marker expansion → plan-given hoisting → expandInlineAllocs → `$cap` prepass
  → local gc-leaf check → RS4GC (+ assert) → -O2 → emit
link
```

## 3. Child plans: risk order, dependencies and implementation order

| # | Plan | Moves | Main hazards (from the feasibility pass and adversarial reviews) | Depends on |
|---|---|---|---|---|
| 01 | Cap-hoist plan (MLIR) | budget/coverage fixpoint | Seven LLVM-behaviour emulations; five unsound holes found in review; global attribute-equality premise; new `$cap` copy mechanism; small standalone payoff | 03's "local / address-taken" facts (see below) |
| 02 | gc-leaf propagation (MLIR) | poison fixpoint | GC-critical; the 01/02 ordering hazard; the three-column marker table | 01 (coverage bit), the marker table |
| 03 | Reachability (MLIR) | internalize + GlobalDCE (additive; the decl strip stays) | Loud failures only; byte identity not proven; the exe path is covered only by AOT E2E and the bootstrap | — |
| 04 | Constant thunks (front-end) | IPSCCP prologue (5.7 s), measured worth 1.8 % — **DONE 2026-10-02: prologue deleted**, self-compile 108.11 s vs 108.25 s with it, LLVM backend phase −6 s | Phase 2 let-name leak (fix known); phase 1 is low risk | — |

**Why riskiest first.** If 01 or 02 cannot be made sound, the MLIR-level split loses its
purpose. Finding that out early is cheaper than finishing 03 and 04 for a split that never
happens. 03 and 04 are worthwhile on their own regardless.

**Resolving 01's dependency on 03.**
- 01 needs "local after internalization" and an address-taken rule matching
  `Function::hasAddressTaken`.
- 01 starts in **validate mode** against today's LLVM path, where internalize + GlobalDCE still
  run. It computes eligibility itself, emulating "local" as every non-root definition that 03's
  rules would internalize, and compares that with the LLVM Phases A–C.
- Only the small `EcoSymbolGraph` slice of 03 (the edge collection plus the `addrTaken` rule,
  03 §5.2) needs to be built first, as part of 01's first step. The rest of 03 (MLIR-side
  erase and internalize) can follow later.

**Implementation order:**
0. **00, spikes and censuses** (`-00-spikes.md`). They include the M1 spike and every child
   plan's measurements. All were completed 2026-10-02, with GO for every plan.
1. **M1 spike** (§6, done in 00 as SP1: GO, 0.67 s parallel against 6.7 s serial): parallel
   translation of today's partitions. This validates the premise of
   the whole effort before anything else is built.
2. **01:** the `EcoSymbolGraph` slice of 03, then `EcoCapHoistPlan` in validate mode, the plan
   stamp on the module, and the per-partition verification.
3. **02:** the three-column marker table and the per-partition / F11 checks, which ship as
   safety work on today's pipeline; then `EcoGcFreePropagation` in validate mode (⊆ gate).
4. **03:** MLIR reachability (erase and internalize), additive to the decl strip.
5. **04:** phase 1, then phase 2; drop the cgu prologue if the tax holds. 04 can run in
   parallel with any of the above, since it touches only the front-end.
6. **The split** (§4).

Each step runs as a backend-opt loop step against the then-best tree:
- one lowering run, judged on wall time (loop §4, amendment 1);
- the batched gates at the end.

## 4. The split itself (master-plan scope, after 01–04)

**4.1 Partitioning in MLIR.**
- Use LPT by op count, reusing step C2's balancing.
- Ownership is decided on MLIR symbols and stays deterministic: cost descending, then name.
- Consider merging single-caller callees into their caller's partition. Measure first.

**4.2 Build the partition modules.** Do this in parallel, cloning into fresh MLIR modules:
- the definitions the partition owns;
- external declarations for everything else, carrying the copied attributes: `gc-leaf`,
  `eco-cap-*`, passthrough;
- `$cap` bodies as `available_externally` (01);
- globals: the owner keeps the definition, everyone else gets a declaration.

**4.3 Linkage.**
- Internal for a symbol referenced only from its owner partition (03's referrer sets).
- External + hidden for cross-partition symbols.
- `main`, renamed to `eco_main`, and `__eco_init_globals` are exported.

**4.4 Translation.** Run `translateModuleToLLVMIR` per partition, each on its own thread and
LLVMContext. Check:
- the thread-safety of translation interfaces registered on a shared MLIRContext;
- the `legalizeDIExpressions` walk per partition.

**4.5 Workers.** The existing per-partition pipeline runs, minus extraction. Then:
- delete `externalizeAllLocals`, the serialize step and `emitObjectFilesSplitLazy`'s parse;
- keep the old path behind a flag for one series, as a differential checker.

**4.6 Determinism and gates:**
- bootstrap fixed point;
- `-O0 --emit=llvm`-style IR identity per partition across two runs;
- recursive tax ≤ 3 % against the then-current default;
- `check` (unit + JIT E2E); the JIT path is unaffected because the split is exe-only;
- AOT E2E, if the JS stages can be built.

**4.7 Single-module paths stay supported:** JIT, `--emit=obj`/`.so`, small modules below the
split threshold, and `--parallel-opt=none`. In those paths the MLIR passes from 01–03 still run,
and their attributes are honoured by a one-partition pipeline.

## 4a. Cross-plan findings from the feasibility pass (2026-10-02)

Each child plan was deepened and then adversarially reviewed. Each child's own
"Adversarial review" section is the authority; it records the corrections below and supersedes
this outline where they differ.

- **03 keeps the unused-decl strip.**
  - `EcoListCursor` gates on a pre-declared marker that only the strip removes, and the JIT,
    `.o` and fixture paths need it.
  - 03 must **internalize** as well as erase. MLIR leaves nearly every generated function
    `External`, and IPSCCP, CGEN_074 and AlwaysInliner read LLVM linkage.
  - The referrer sets become a shared, recomputable C++ symbol graph, not IR attributes.
  - The gate must be `emitAction == EmitExe`. Moving `isExecutable` naively would hit
    `--emit=llvm`.
  - GlobalDCE's removal of unused constants affects `hasAddressTaken`. Keep that cleanup.
- **01/02 ordering is a GC-safety hazard.** Once 02 stamps gc-leaf in MLIR, a covered function
  is also gc-leaf. Today's Phase A tests leafness *before* "defined callee", so any LLVM-side
  Phase A would treat a covered callee as transparent and under-count budgets, which corrupts
  the heap. The rules:
  - every classifier checks `eco-cap-*` first;
  - compute-mode LLVM hoisting refuses already-stamped modules;
  - any gc-leaf declaration without `eco-cap-*` must be a known runtime or kernel name
    (02 F11).
- **Per-partition checks are sound only with split-time attribute equality.** The local
  budget check (01) and the post-RS4GC assert (02) prove the global property only if every
  cross-partition declaration carries exactly its owner's `eco-cap-*` / gc-leaf attributes.
  - A dropped `covered` bit is not fail-safe.
  - The split therefore needs a mandatory presence-and-equality check (01 S6, 02 F5), and
    §2.6(a) must also cover declarations.
- **The plan and mode stamp goes on the module,** not on a marker declaration (01 A3), and it
  records exe vs obj/so/JIT.
- **The marker may-GC table needs three columns:** as seen by hoisting, by gc-free
  propagation, and in the final IR. It runs both ways: list-cursor markers are declared
  non-leaf but expand leaf-only. Value-eq leafness depends on whether `Elm_Kernel_Utils_equal`
  survives in each partition.
- **02's validate gate is ⊆, not ==.** `$cap` inlining can make LLVM stamp more than MLIR. MLIR
  stamping something LLVM does not is fatal.
- **04 is a codegen-time map in `generateVarGlobal`.**
  - Phase 1 is literal thunks, which also folds `shiftStep` because `branchFactor` becomes 32
    and LLVM folds the `log`.
  - Phase 2 substitutes closed scalar bodies under a fresh lexical scope, not an Elm
    evaluator.
  - The self-compile writes bytecode MLIR (exact floats). Dropping the prologue needs a
    GlobalDCE fallback measurement and a first E2E/AOT run with the prologue off.

## 5. Risks and mitigations

| Risk | Mitigation |
|---|---|
| GC safety: a function wrongly stamped gc-leaf leaves statepoints out and corrupts the heap (02) | Shared may-GC table; per-partition local check plus the post-RS4GC assert, both hard build errors |
| A missed symbol reference after DCE or the split (03, §4) | Fails loudly at link; validate mode cross-checks against today's LLVM DCE |
| Code-quality loss from partition-local optimization | 04 replaces IPSCCP; internal linkage within a partition; recursive-tax gate |
| Thread safety of parallel translation | Spike first (§6, M1); otherwise keep translation serial but per partition |
| RSS: N LLVMContexts alive at once | Measure; the current peak is 7.9 GB on a 15 GB box; cap concurrency if needed |

## 6. Milestones (in implementation order)

| M | Content | Exit criterion |
|---|---|---|
| M1 | Spike: translate the existing 24 LPT partitions from MLIR, in parallel, in a throwaway path | translation timing, RSS, no thread-safety failures; go/no-go for the whole plan |
| M2 | 01 in validate mode, plus the `EcoSymbolGraph` slice of 03 | zero coverage or budget differences against the LLVM Phases A–C; byte-identical ELF |
| M3 | 02 marker table + per-partition/F11 checks shipped; propagation in validate mode | MLIR stamped set ⊆ LLVM stamped set; all gates |
| M4 | 03 shipped (MLIR erase + internalize; strip kept) | same ELF symbol set; loop step FLAT or WIN |
| M5 | 04 phases 1–2 shipped; cgu prologue dropped if the tax holds | self-compile ≤ today's with the prologue off (N = 3) — **MET 2026-10-02** (P2-OFF 108.11 s ≤ base-ON 108.25 s; prologue deleted) |
| M6 | The split (§4) default-on for exe output | all gates; lowering wall ≤ about 30 s — **MET 2026-10-02** (plan 05 EcoSplit: 25.53 s; lazy bitcode split retired) |

## 7. Out of scope

- LLVM image rebuild without assertions (A2 of the previous plan; manual, the user's step).
- Reducing IR volume (`$cap` duplication is 20 % of the IR).
- Patching MLIR upstream (`legalizeDIExpressions`).
