# Split `-enable-unboxed-agg` and redesign EscapeAnalysis around cross-spec

Two related changes, sequenced so the first lands risk-free and unblocks the second:

1. **Part 1** — split the existing `-enable-unboxed-agg` flag into two independent flags so the cross-spec/flatten path and the intra-function escape-analysis path can be toggled separately. Both default ON across all entry points; behavior identical except where `EcoRunner` defaults change (see §1.2 step 6 below).
2. **Part 2** — replace `EcoEscapeAnalysis` + `EcoUnboxedAggSpecialize` with a single cross-spec-aware local rewrite pass (`EcoUnboxedAggLocalRewrite`) that consumes metadata produced by `EcoUnboxedAggCrossSpec` instead of re-deriving "safe use" rules locally.

The new flag is `-enable-agg-cross-spec` (matches the pass name `EcoUnboxedAggCrossSpec`).

---

## Status quo (verified)

Single flag `-enable-unboxed-agg` is parsed in three driver binaries and threaded through `EcoPipelineOptions::enableUnboxedAgg`:

- `runtime/src/codegen/eco-boot.cpp:176` — `cl::opt enableUnboxedAgg`, default `true`. Plumbed at `:317` (`pipeOpts.enableUnboxedAgg = enableUnboxedAgg`).
- `runtime/src/codegen/ecoc.cpp:135` — sibling `cl::opt`. Plumbed at `:186`.
- `runtime/src/codegen/EcoNativeDriver.{h,cpp}` — `enableUnboxedAgg` field in `Options` (`EcoNativeDriver.h:32`); `runPipeline(..., bool enableUnboxedAgg, ...)` signature at `EcoNativeDriver.cpp:82`; threaded at `:96` and `:174`.
- `runtime/src/codegen/EcoRunner.{hpp,cpp}` — field at `EcoRunner.hpp:84` (note: default is `false` here, unlike the other entry points); plumbed at `EcoRunner.cpp:180`.
- `runtime/src/codegen/EcoPipeline.h:38` — `EcoPipelineOptions::enableUnboxedAgg`, default `true`.
- `runtime/src/codegen/EcoPipeline.cpp:72-88` — the single `if (opts.enableUnboxedAgg)` block that adds all four passes in order:

    ```cpp
    if (opts.enableUnboxedAgg) {
        pm.addPass(eco::createEcoUnboxedAggCrossSpecPass());                       // :78
        pm.addNestedPass<func::FuncOp>(eco::createEcoEscapeAnalysisPass());        // :79
        pm.addNestedPass<func::FuncOp>(eco::createEcoUnboxedAggSpecializePass());  // :80
        pm.addPass(eco::createEcoFlattenAggBoundaryPass());                        // :87
    }
    ```

Pass sizes (so we know what we're touching/replacing):

- `Passes/EcoUnboxedAggCrossSpec.cpp` — 2769 lines. Defines `kLogicalParamTypesAttr`, `kLogicalResultTypesAttr`, `kUnboxedWorkerAttr`. Key helpers already named in design: `buildWorkerType` (:1287), `cloneAsWorker` (:1790), `retypeJoinTree` (:1474).
- `Passes/EcoEscapeAnalysis.cpp` — 215 lines. Writes a string attr `eco.escape` ∈ {`non_escaping`, `escapes`} on each `eco.construct.*` op. Conservative rule: only matching projection at operand 0 is non-escaping.
- `Passes/EcoUnboxedAggSpecialize.cpp` — 173 lines. Reads `eco.escape` and rewrites construct → make.
- `Passes/EcoFlattenAggBoundary.cpp` — 595 lines. Independent; flattens aggregate-typed function boundaries.

Existing lit tests live in `/work/test/codegen/`: `cross_spec_*.mlir` (~20 files) and `specialize_*.mlir` (~7 files for escape/specialize behavior).

---

## Part 1 — Split the flag

### 1.1 Goal

| Flag | Today controls | After change controls |
|---|---|---|
| `-enable-unboxed-agg` | all four passes | only `EcoEscapeAnalysis` + `EcoUnboxedAggSpecialize` (later: `EcoUnboxedAggLocalRewrite`) |
| `-enable-agg-cross-spec` *(new)* | — | `EcoUnboxedAggCrossSpec` + `EcoFlattenAggBoundary` |

Both default `true` in every entry point (including `EcoRunner`, which previously defaulted `enableUnboxedAgg = false` — see §1.2 step 6).

### 1.2 Steps

1. **`EcoPipeline.h:33-39`** — add `bool enableAggCrossSpec = true;` to `EcoPipelineOptions`. Update the doc comment on `enableUnboxedAgg` to narrow its scope to the intra-function path.

2. **`EcoPipeline.cpp:72-88`** — replace the single gate with two independent gates, preserving current relative order (cross-spec → escape-analysis → specialize → flatten):

    ```cpp
    if (opts.enableAggCrossSpec) {
        pm.addPass(eco::createEcoUnboxedAggCrossSpecPass());
    }
    if (opts.enableUnboxedAgg) {
        pm.addNestedPass<func::FuncOp>(eco::createEcoEscapeAnalysisPass());
        pm.addNestedPass<func::FuncOp>(eco::createEcoUnboxedAggSpecializePass());
    }
    if (opts.enableAggCrossSpec) {
        pm.addPass(eco::createEcoFlattenAggBoundaryPass());
    }
    ```

    Rationale for ordering: cross-spec rewrites worker bodies before escape-analysis runs (so the local pass sees the final shape); flatten still runs last because it relies on cross-spec having created aggregate-typed boundaries.

3. **`eco-boot.cpp`** — add a sibling `cl::opt<bool> enableAggCrossSpec("enable-agg-cross-spec", …, cl::init(true))` next to the existing one at `:176`. Plumb into `pipeOpts.enableAggCrossSpec` next to `:317`.

4. **`ecoc.cpp`** — same: sibling `cl::opt` near `:135`; plumb near `:186`.

5. **`EcoNativeDriver.{h,cpp}`** — add `bool enableAggCrossSpec = true;` to `Options` near `EcoNativeDriver.h:32`. **Refactor `runPipeline(...)` at `EcoNativeDriver.cpp:82` to take a `const Options &` in the same PR** (rather than adding another positional `bool`). Update the single caller at `:174` accordingly.

6. **`EcoRunner.{hpp,cpp}`** — mirror in `Options` at `EcoRunner.hpp:84`. **Change the default of `enableUnboxedAgg` from `false` to `true`, and set `enableAggCrossSpec = true`**, so `EcoRunner` matches every other entry point and the "unboxed world is on by default" story. Plumb at `EcoRunner.cpp:180`. This is the one behavioral change in Part 1 — call it out in the PR description. Any test/benchmark that wants the old behavior must now opt out via an explicit flag.

7. **`CMakeLists.txt:286`** — update the comment that mentions the old flag.

### 1.3 Tests

Add two lit-test pairs that exercise the gates independently:

- `test/codegen/agg_cross_spec_off_keeps_local_rewrite.mlir`
    ```
    // RUN: %ecoc %s -emit=mlir-llvm -enable-agg-cross-spec=false -enable-unboxed-agg=true | FileCheck %s
    ```
    Expect: no `@f$unboxed` worker, no aggregate-typed func signatures, but `eco.construct.tuple2` results still rewritten to `eco.make.tuple2` where escape-analysis allows.

- `test/codegen/unboxed_agg_off_keeps_cross_spec.mlir`
    ```
    // RUN: %ecoc %s -emit=mlir-llvm -enable-agg-cross-spec=true -enable-unboxed-agg=false | FileCheck %s
    ```
    Expect: `@f$unboxed` worker present and boundaries flattened; intra-function `eco.construct.*` ops remain (no `eco.escape` attr, no `eco.make.*` from the local pass).

Also: spot-check one or two existing `cross_spec_*.mlir` tests to ensure they still pass with default flags (no IR diff).

### 1.4 Docs

- Update the doc comment on `EcoPipelineOptions` (`EcoPipeline.h:33-39`).
- Update the help string for the old flag in `eco-boot.cpp:178-182` and `ecoc.cpp:137-141` so it no longer claims to control cross-spec or flatten.

---

## Part 2 — Redesign EscapeAnalysis around cross-spec

Land Part 1 first. Then proceed in five stages, each ship-on-green:

### Stage A — Shared analysis support module

New files: `runtime/src/codegen/Passes/EcoUnboxedAggAnalysisSupport.{h,cpp}`.

Defines:

- `enum class UnboxedUseKind { Projection, EligibleCall, Join, Safepoint, BoundaryToHeap, Unknown }`.
- `struct CrossSpecInfo` with the queries listed in the design (isUnboxedWorker, isPromotedParam, isPromotedResult, isPromotedCallOperand, isPromotedCallResult, isInUnboxedWorld, getUnboxedSlotId).
- `UnboxedUseKind classifyUse(Operation *user, Value v, const CrossSpecInfo &info)`.
- `CrossSpecInfo CrossSpecInfo::fromAttributes(ModuleOp m)` — **lazy reconstruction** from per-function and per-op attributes (the simpler of the two options in the design). The struct caches the walk result internally; callers reuse a single instance across a pass run. If this becomes a hot path we can later promote to a proper `mlir::AnalysisManager` analysis, but not now.

No behavioral change yet; just the library compiled in. Cover with a tiny unit test against a hand-written module with the expected attributes.

### Stage B — Cross-spec emits the metadata

Modify `EcoUnboxedAggCrossSpec.cpp`:

- In `buildWorkerType` (`:1287`) / `cloneAsWorker` (`:1790`), attach to each worker `func::FuncOp`:
    - `eco.unboxed_param_slots = [bool…]` (length == param count)
    - `eco.unboxed_result_slots = [bool…]` (length == result count)
- Keep the existing `eco.unboxed_worker` marker (`EcoUnboxedAggCrossSpec.cpp:177`) — it gates `isUnboxedWorker`.
- For SSA values that enter the "unboxed world" — entry block args of promoted params, results of `eco.make.*` created during `cloneAsWorker`, joined values rewritten by `retypeJoinTree` (`:1474`), and results of `eco.from_heap` at the worker boundary — set an attribute on the defining op. Use **per-result array attributes** so multi-result ops (e.g. `eco.case`, `scf.while`) can encode different slot ids per result:

    ```mlir
    %0:3 = scf.while ... : ... -> (!eco.tuple2<...>, i64, !eco.record<...>)
        attributes { eco.unboxed_world_slots = [0, -1, 1] }
    ```

    Convention: `-1` means "not in any unboxed world"; non-negative entries are slot ids. Single-result ops use a one-element array for consistency. `CrossSpecInfo::isInUnboxedWorld(Value v)` looks up the array by result index on the defining op.

- Verify by dumping a transformed worker for one of the existing `cross_spec_*.mlir` tests — the new attributes should be present.

Reconstruction is lazy (see Stage A); no module-level summary attribute.

### Stage C — New `EcoUnboxedAggLocalRewrite` pass

New file: `runtime/src/codegen/Passes/EcoUnboxedAggLocalRewrite.cpp`. Per-function pass (`OperationPass<func::FuncOp>`).

Algorithm:

1. Build `CrossSpecInfo` once from the parent `ModuleOp` (or accept it via an MLIR analysis cache once we wire that up).
2. Walk all `eco.construct.{tuple2,tuple3,record,custom,list}` in the function.
3. For each construct result `v`, run the BFS in the design doc:
    - Pop SSA values, classify each user via `classifyUse`.
    - **Projection** — push user's results.
    - **EligibleCall** — push only those results that `info.isInUnboxedWorld(...)` confirms.
    - **Join** — same as EligibleCall.
    - **Safepoint** — transparent; nothing to push (safepoints don't forward values today; revisit if/when they do).
    - **BoundaryToHeap** — return `false`.
    - **Unknown** — return `false`.
    - Also fail if `v` (or any forwarded value) flows into a non-promoted param/result of the enclosing function.
4. If `canRewriteToMake(v)` and the shape matches, rewrite construct → make.
5. Erase the original construct.

**Shape-matching strategy (two-step within Stage C):**

- **C.1 — simple rule first.** Initial implementation: only rewrite when the construct's result type is already an aggregate SSA type. Ship and prove parity for the cases this covers.
- **C.2 — DSL-driven shape match.** Before Stage E can delete the old passes, we must cover the cases that `EcoEscapeAnalysis` + `EcoUnboxedAggSpecialize` rewrite today but the simple rule misses. Concretely:
    1. Enumerate the construct shapes covered by today's pipeline by reading `/work/test/codegen/specialize_*.mlir` and the `non_escaping` paths in `EcoEscapeAnalysis.cpp`.
    2. For `eco.construct.*` returning `!eco.value`, consult `eco.logical_param_types` / `eco.logical_result_types` on the enclosing function (constants `kLogicalParamTypesAttr`/`kLogicalResultTypesAttr` already exported by `EcoUnboxedAggCrossSpec.cpp:175-176`).
    3. Reuse the DSL parser already in cross-spec (`buildWorkerType`'s parser, around `:640`) — extract into the shared support module if it isn't already standalone.
    4. Only rewrite when field count + element kinds match.
- If C.2 turns out to be a bigger lift than expected, **keep `EcoEscapeAnalysis` + `EcoUnboxedAggSpecialize` alive behind the hidden flag from Stage D** until C.2 lands. Stage E's deletion is gated on C.2.

Register via `createEcoUnboxedAggLocalRewritePass()` in `Passes.h` and `Passes.cpp` (or wherever the existing factories live).

### Stage D — Side-by-side run (hidden flag)

Add an internal `cl::opt<bool> useNewLocalRewrite("use-new-local-unboxed-agg-rewrite", cl::Hidden, cl::init(false))` to `eco-boot.cpp` and `ecoc.cpp`. Plumb a matching field through `EcoPipelineOptions`.

In `EcoPipeline.cpp`, replace the inner gate from Part 1:

```cpp
if (opts.enableUnboxedAgg) {
    if (opts.useNewLocalRewrite) {
        pm.addNestedPass<func::FuncOp>(eco::createEcoUnboxedAggLocalRewritePass());
    } else {
        pm.addNestedPass<func::FuncOp>(eco::createEcoEscapeAnalysisPass());
        pm.addNestedPass<func::FuncOp>(eco::createEcoUnboxedAggSpecializePass());
    }
}
```

Run the existing lit suite under `-use-new-local-unboxed-agg-rewrite=true`; iterate until output is equivalent (or strictly better — fewer `eco.escape` annotations and at least as many `eco.make.*` rewrites).

Run E2E (`cmake --build build --target full`) and the stress suite under both modes.

### Stage E — Cutover and deletion

**Hard gates** before this stage can land:

- Stage C.2 (DSL-driven shape match) is in and tested.
- `grep -rn 'eco\.escape\|kEscapeAttr\|"eco.escape"' runtime/ test/ design_docs/` returns only references in the files being deleted (and possibly tests that need to be updated). Expectation: only `EcoUnboxedAggSpecialize` reads the attribute today; confirm.

Then:

1. Flip the default of `useNewLocalRewrite` to `true`. Land. Bake one cycle.
2. Remove the `useNewLocalRewrite` branch entirely; `-enable-unboxed-agg` now gates only the new pass.
3. Delete `Passes/EcoEscapeAnalysis.cpp` and `Passes/EcoUnboxedAggSpecialize.cpp`, their factory declarations in `Passes.h:58,66`, their CMake entries, and the `eco.escape` attribute from the dialect.
4. Update the `specialize_*.mlir` lit tests to reference the new pass or fold their CHECK lines into existing `cross_spec_*` tests.

### Behavior under `-enable-unboxed-agg=true -enable-agg-cross-spec=false`

The new local pass **gracefully no-ops** in this combination. It looks for `eco.unboxed_param_slots` / `eco.unboxed_result_slots` on the enclosing function and `eco.unboxed_world_slots` on producer ops; cross-spec is the only thing that emits these, so when cross-spec didn't run, `CrossSpecInfo` is empty, every `classifyUse` falls through to `Unknown`, and the BFS rejects every construct. Document this in the help string for `-enable-unboxed-agg` and in the `EcoUnboxedAggLocalRewrite` header comment. Don't forbid the combination at the flag level.

---

## Migration table (consolidated)

| Step | Files touched | Risk | Verification |
|------|---------------|------|--------------|
| 1.1 — add field | `EcoPipeline.h` | trivial | builds |
| 1.2 — split gate | `EcoPipeline.cpp` | low | existing lit tests unchanged with defaults |
| 1.3 — CLI plumbing | `eco-boot.cpp`, `ecoc.cpp`, `EcoNativeDriver.{h,cpp}`, `EcoRunner.{hpp,cpp}` | low | spot-check each binary's `--help` |
| 1.4 — new lit tests | `test/codegen/*.mlir` | low | `cmake --build build --target check` |
| 1.5 — docs | comments only | none | n/a |
| A — analysis support | new `EcoUnboxedAggAnalysisSupport.{h,cpp}` | low | compiles + small unit test |
| B — cross-spec emits attrs | `Passes/EcoUnboxedAggCrossSpec.cpp` | medium | existing `cross_spec_*.mlir` IR diff is additive |
| C.1 — simple-rule local pass | new `Passes/EcoUnboxedAggLocalRewrite.cpp`, `Passes.h`, registration | medium | lit tests for the pass in isolation |
| C.2 — DSL-driven shape match | `Passes/EcoUnboxedAggLocalRewrite.cpp`, support module | medium | `specialize_*.mlir` parity vs old passes |
| D — side-by-side | `EcoPipeline.{h,cpp}`, drivers | medium | full E2E + stress under both modes |
| E — cutover + delete *(gated on C.2 + grep)* | remove old passes + tests | low (after bake) | E2E green |

---

## Resolved decisions

1. **`EcoRunner` defaults.** Fix the inconsistency in the Part 1 PR: `EcoRunner.hpp:84` will default `enableUnboxedAgg = true` and `enableAggCrossSpec = true`, matching every other entry point. Any test/benchmark that relied on the silent `false` default must pass an explicit flag. This is the one behavioral change in Part 1; call it out in the PR description.
2. **CrossSpecInfo storage.** Lazy reconstruction from attributes (no MLIR analysis registration, no module-level summary attr). Revisit only if profiling shows `fromAttributes` is hot.
3. **Multi-result tagging.** Per-result array attribute `eco.unboxed_world_slots = [...]`, `-1` for "not in unboxed world", non-negative for slot id. Single-result ops use a one-element array. Explicit per-result info matters because joins (`eco.case`, `scf.while`) can merge multiple slots.
4. **Shape-matching scope.** Stage C is internally split: C.1 ships the simple rule; C.2 ships the DSL-driven match. **Stage E (deletion of old passes) is gated on C.2 landing.** If C.2 slips, keep the old passes alive behind the Stage D hidden flag until it's in.
5. **`eco.escape` consumers.** Hard gate: grep before deleting in Stage E. Expectation is that only `EcoUnboxedAggSpecialize` (and its tests) read it; confirm at gate time.
6. **`runPipeline` signature.** Refactor to `const Options &` in the same PR as Part 1 to avoid another positional `bool` and a second refactor later.
7. **Flag name.** `-enable-agg-cross-spec` (matches `EcoUnboxedAggCrossSpec`). Already adopted throughout this plan.
8. **`enableUnboxedAgg=true, enableAggCrossSpec=false`.** Allowed. The new local pass gracefully no-ops (empty `CrossSpecInfo` → every classify falls to `Unknown` → BFS rejects every construct). Documented in the help string and the pass header. No flag-level forbidding.
