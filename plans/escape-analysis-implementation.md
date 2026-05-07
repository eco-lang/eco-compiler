# Escape Analysis for Small Aggregates — Implementation Plan

Source design: `design_docs/escape-analysis.md`.

## 1. Goal and scope

Reduce heap allocations for small aggregates whose values demonstrably do
not escape — so the LLVM mid‑end (mem2reg, SROA, InstCombine) can keep them
in registers and RS4GC has fewer live `ptr addrspace(1)` to track across
statepoints.

**In scope (eventually) — all six aggregate shapes are first‑class from the
start:**
- 2/3‑tuples (`Tuple2ConstructOp` / `Tuple3ConstructOp`)
- records (`RecordConstructOp`)
- custom ADTs (`CustomConstructOp`)
- list cons cells (`ListConstructOp`)
- closure environments (`AllocateClosureOp` payload)

**Out of scope (this work):**
- Strings (`Tag_String`/Slice/Rope) and ByteBuffers — stay `!eco.value`.
- ElmArray ops — stay heap (variable‑size, mutation‑shaped intrinsics).
- Generic boxing/unboxing of primitives (already covered by REP_BOUNDARY_*).
- Fully unboxed list *segments* (i.e. an `!eco.cons` whose tail is also
  `!eco.cons`). Phase 0 keeps cons tail as `!eco.value` to match the
  existing heap list representation; deeper unboxing of list spines is a
  later extension.

## 2. Reality check vs the design doc

The design assumes a `ConstructLowering` pass that lowers `eco.construct.*`
to `eco.allocate_* + stores` BEFORE EcoToLLVM. That pass does **not** exist
today: only declared in `runtime/src/codegen/Passes.h:28`, commented out in
`EcoPipeline.cpp:52`, and there is no `.cpp` implementation. Heap construct
ops lower DIRECTLY to runtime allocator calls
(`Tuple2ConstructOpLowering` → `eco_alloc_tuple2`, etc.) in
`runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`.

Implication: design Section F ("ConstructLowering changes") becomes a no‑op.
Gating between heap and value forms happens automatically because
`eco.make.*` get their own LLVM lowering patterns; existing
`eco.construct.*` patterns continue to run only on ops whose result type is
`!eco.value`.

`createControlFlowLoweringPass` is in the same state — declared, never
implemented, never used. This is unrelated to escape analysis but worth
flagging since the design references it.

The Elm‑side `MlirType` is `I1 | I16 | I32 | I64 | F64 | NamedStruct String
| FunctionType` — adding new aggregate types front‑end‑side means either
spelling them as `NamedStruct "!eco.tuple2<...>"` (textual) or extending the
ADT. For Phase 0 the front‑end does not need to emit aggregate types at
all.

## 3. Staged plan

### Phase 0 — IR plumbing only (no behavioral change)

Goal: add types, ops, type conversion, and lowering patterns so a
hand‑written `.mlir` exercising `eco.make.*` round‑trips through to LLVM
and gets SROA'd. No escape pass yet, no Elm codegen change, no test pipeline
change beyond new MLIR fixtures.

**0.1 Aggregate types in `runtime/src/codegen/Ops.td` and `EcoTypes.{h,cpp}`**
- New `Eco_Type` definitions, all six shapes from the start:
  - `Eco_Tuple2Type` — parameterised by element types `(Type, Type)`.
  - `Eco_Tuple3Type` — parameterised by `(Type, Type, Type)`.
  - `Eco_RecordType` — parameterised by `ArrayRef<Type>` (field types).
  - `Eco_CustomType` — parameterised by `ArrayRef<Type>` plus an `i64`
    tag attribute.
  - `Eco_ConsType` — parameterised by `(headType, tailType)`. Tail is
    fixed to `!eco.value` for now (matches the existing heap list spine).
  - `Eco_ClosureEnvType` — parameterised by `ArrayRef<Type>` (capture
    slot types). Carries no function‑symbol or arity information; those
    live on the heap‑realisation site (see 0.3).
- Constraint defs `Eco_Tuple2`, `Eco_Tuple3`, `Eco_Record`, `Eco_Custom`,
  `Eco_Cons`, `Eco_ClosureEnv`, plus a meta‑constraint
  `Eco_AnyAggregate = AnyTypeOf<[...]>` enumerating all six.
- C++ TypeDef storage classes (`Tuple2TypeStorage`, …, `ConsTypeStorage`,
  `ClosureEnvTypeStorage`) — needed because ODS only generates a stub for
  parameterised types.
- Custom printer/parser methods so the textual form looks like
  `!eco.tuple2<i64, !eco.value>`,
  `!eco.cons<i64, !eco.value>`,
  `!eco.closure_env<i64, !eco.value, f64>`.
- Add round‑trip tests under `test/codegen/` (parse then re‑print) for all
  six shapes.

**0.2 `eco.make.*` value‑aggregate ops in `Ops.td`**
All six are `Pure`, **not** `GCRootCarrier`, no `live_roots`, no
`unboxed_bitmap` (Q‑B: bitmap is heap‑layout only and stays off
value‑level types and ops).
- `Eco_Tuple2MakeOp`: `(Eco_AnyValue, Eco_AnyValue) -> Eco_Tuple2`. Builder
  enforces that result element types match operand types.
- `Eco_Tuple3MakeOp`: `(Eco_AnyValue × 3) -> Eco_Tuple3`.
- `Eco_RecordMakeOp`: `(Variadic<Eco_AnyValue>) -> Eco_Record`, with field
  count derivable from operand count.
- `Eco_CustomMakeOp`: `(Variadic<Eco_AnyValue>) -> Eco_Custom` plus `tag`
  and `size` attributes (Q‑B: tag stays on the op, never on the type).
- `Eco_ConsMakeOp`: `(Eco_AnyValue head, Eco_Value tail) -> Eco_Cons`.
  Tail stays `!eco.value` — there is no recursive value‑level cons spine
  in this phase. Naming asymmetry with the existing heap op
  `eco.construct.list` is deliberate (Q‑D); we do not rename either side.
- `Eco_ClosureEnvMakeOp`: `(Variadic<Eco_AnyValue>) -> Eco_ClosureEnv`.
  Captures only — no function symbol or arity. The function/arity is
  attached at heap‑realisation time via the dedicated `eco.make.closure`
  op (see 0.3), **not** via `eco.to_heap`.

**0.3 Heap/value boundary ops**
- `Eco_ToHeapOp` covers the **data‑aggregate** shapes only. The op
  dispatches on the aggregate kind:
  - `!eco.tuple2/3` → `eco_alloc_tuple2/3` with field stores matching the
    existing `Tuple2/3ConstructOpLowering` heap layout.
  - `!eco.record` → `eco_alloc_record` + per‑field stores; carries the
    same `field_count` and `unboxed_bitmap` attributes as
    `RecordConstructOp` (heap‑layout attributes per Q‑B).
  - `!eco.custom` → `eco_alloc_custom` + per‑field stores; carries the
    same `tag`, `size`, `unboxed_bitmap` attributes as
    `CustomConstructOp`.
  - `!eco.cons` → `eco_alloc_cons` + head/tail stores; same
    `head_unboxed` + `head_kind` attributes as `ListConstructOp`.
  - **Excludes** `!eco.closure_env`. The verifier rejects a `to_heap`
    whose input is `!eco.closure_env`.
  - Implements `Eco_GCRootCarrier`, with `live_roots` populated by
    `EcoGCPrepare` exactly like `eco.box` / `eco.allocate_*` (Q6).
- `Eco_MakeClosureOp` is the **dedicated closure‑realisation op**
  (Q‑A‑b). It is the only `make.*` that allocates and is the only
  `make.*` whose result is `!eco.value`:
  - Arguments: `env: Eco_ClosureEnv`, `Variadic<Eco_Value>:$live_roots`.
  - Attributes: `function: FlatSymbolRefAttr`, `arity: I64Attr`
    (mirroring `AllocateClosureOp`). May also need a `num_captured`
    attribute or have it implied by the env type's field count;
    decision can be left to the implementation since both are derivable.
  - Result: `!eco.value`.
  - Traits: `Eco_GCRootCarrier`. **Not** `Pure` (it allocates).
  - Deliberate naming exception: this is the only op in the `make.*`
    family that allocates and produces `!eco.value`; documented in the
    op's `summary`/`description` so future readers don't expect Pure
    semantics. Reviewers may suggest a different name (e.g.
    `eco.box.closure`); the plan keeps `eco.make.closure` per Q‑A.
- Defer `Eco_FromHeapOp` to Phase 3 — Phase 0 only converts in the
  unbox→box direction.

**0.4 Aggregate‑form projection**
- Extend the existing projection ops to accept either `!eco.value` or the
  matching aggregate type, dispatching in lowering (Q‑C). Updates needed:
  - `eco.project.tuple2`, `eco.project.tuple3`,
  - `eco.project.record`, `eco.project.custom`,
  - `eco.project.list_head`, `eco.project.list_tail` (for `!eco.cons`),
  - `eco.project.closure` (for `!eco.closure_env`).
- The verifier accepts both source forms; the LLVM lowering picks
  `extractvalue` for aggregate operands and the existing heap path for
  `!eco.value` operands. **Only the EcoToLLVM projection patterns gain
  the type dispatch (Q‑C).** Higher‑level closure conversion / env
  building patterns in `EcoToLLVMClosures.cpp` are left untouched in
  Phases 0–3; they only ever see `!eco.value` until Phase 4.
- A `Custom` aggregate's tag is structural (op attribute, Q‑B), so the
  `eco.get_tag` lowering, when it sees a `!eco.custom` operand, folds
  to a constant from the producer op's tag attribute rather than
  emitting a load. There is no `!eco.custom` reaching `eco.case` in
  Phases 0–3 (Q4: classified as escaping), so this fold's only initial
  consumer is hand‑written fixtures.

**0.5 `EcoTypeConverter` extensions in `Passes/EcoToLLVMRuntime.cpp`**
- Add `addConversion` callbacks for all six shapes:
  - `Tuple2Type{T0, T1}` → `LLVM::LLVMStructType::getLiteral({Tᵢ'})`.
  - `Tuple3Type` → `LLVMStructType` of three.
  - `RecordType` → `LLVMStructType` of N elements.
  - `CustomType` → `LLVMStructType` (tag is structural, not a struct
    field).
  - `ConsType{Head, Tail}` → `LLVMStructType{Head', Tail'}`. With the
    Phase 0 constraint Tail = `!eco.value`, Tail' = `ptr addrspace(1)`.
  - `ClosureEnvType{T0, …, Tn}` → `LLVMStructType{Tᵢ'}`. The "value
    layout" of the env is whatever the type converter produces; it does
    *not* need to match the heap closure header layout, since boundary
    ops translate explicitly.

**0.6 Lowering patterns in a new `Passes/EcoToLLVMValueAgg.cpp`**
- `Tuple2/3MakeOpLowering`, `RecordMakeOpLowering`, `CustomMakeOpLowering`,
  `ConsMakeOpLowering`, `ClosureEnvMakeOpLowering`: chain
  `LLVM::UndefOp` + `LLVM::InsertValueOp` per field. All `Pure`.
- Extend the existing projection lowerings (Q‑C) **only on the heap
  side**:
  - `Tuple2/3ProjectOpLowering`, `RecordProjectOpLowering`,
    `CustomProjectOpLowering`, `ListHeadOpLowering`, `ListTailOpLowering`
    in `EcoToLLVMHeap.cpp` get a type check: `LLVMStructType` operand →
    `LLVM::ExtractValueOp`; `ptr addrspace(1)` operand → unchanged.
  - `ProjectClosureOpLowering` in `EcoToLLVMClosures.cpp` is **left
    untouched** in this phase. Phase 4 will revisit it together with
    closure dispatch lowering.
  - For Phase 0/1/2 we therefore add a small parallel
    `ProjectClosureFromEnvLowering` next to `EcoToLLVMValueAgg.cpp`
    that handles `!eco.closure_env` operands only — keeping the
    closure‑heavy file out of this PR.
- `ToHeapOpLowering`: dispatch on the input data‑aggregate kind and
  reuse the corresponding `EcoRuntime` allocator helper
  (`eco_alloc_tuple2/3`, `eco_alloc_record`, `eco_alloc_custom`,
  `eco_alloc_cons`). Emit field stores identical to the heap‑construct
  op patterns. **Does not handle closure_env** — that is rejected by
  the verifier.
- `MakeClosureOpLowering` (new): allocates a heap closure via
  `eco_alloc_closure` (or whatever helper `AllocateClosureOpLowering`
  uses today), populates capture slots from the env aggregate's struct
  fields by `extractvalue`+store, and stores the `function`/`arity`
  metadata. Layout must match the existing heap closure produced by
  `eco.allocate_closure` + `papCreate` so downstream call dispatch is
  unaffected.

**0.7 Pattern registration**
- Wire new patterns in
  `Passes/EcoToLLVMHeap.cpp::populateEcoHeapOpsToLLVMPatterns` (or a new
  `populateEcoValueAggPatterns` called from the same site). Closure
  patterns also live alongside `Passes/EcoToLLVMClosures.cpp`
  registrations.

**0.8 Hand‑written MLIR fixtures**
- `test/codegen/value_tuple2.mlir` — `make.tuple2` + `project.tuple2` of
  two i64s; verify lowered LLVM has no `eco_alloc_*` call and produces
  `insertvalue` / `extractvalue` chains.
- `test/codegen/value_tuple3.mlir` — same for `make.tuple3`.
- `test/codegen/value_record3.mlir` — 3‑field record, mixed
  unboxed/boxed.
- `test/codegen/value_custom.mlir` — tagged custom with one boxed field;
  also exercises `eco.get_tag` on the value form folding to a constant.
- `test/codegen/value_cons.mlir` — `make.cons` + `project.list_head` /
  `list_tail` over a value‑level cons whose tail is `eco.constant Nil`.
- `test/codegen/value_closure_env.mlir` — `make.closure_env` + several
  `project.closure` reads via the new `ProjectClosureFromEnvLowering`.
  No call/dispatch yet — just struct build/extract.
- `test/codegen/value_make_closure.mlir` — `make.closure_env` →
  `eco.make.closure` round‑trip; FileCheck that the lowered LLVM
  matches the existing heap closure layout (compare against an
  `eco.allocate_closure` baseline).
- `test/codegen/value_to_heap_<kind>.mlir` — one `to_heap` fixture per
  *data* aggregate kind (tuple2, tuple3, record, custom, cons),
  comparing the lowered allocator call sequence against the
  corresponding `eco.construct.*` baseline.
- `test/codegen/invalid_to_heap_closure_env.mlir` — negative test that
  `eco.to_heap` on a `!eco.closure_env` operand fails verification.
- Run `cmake --build build --target check` (C++‑only) to verify these
  parse/lower; full E2E unaffected.

**Phase 0 PR scope:** 6 types + 6 `eco.make.*` value‑aggregate ops +
`eco.to_heap` (data aggregates only) + `eco.make.closure` (closure
realisation) + projection extensions (heap side for tuple/record/custom/
cons; new value‑side `ProjectClosureFromEnv` for closure_env) + LLVM
lowering + ~12 MLIR fixtures (incl. one negative). No Elm changes. No
`EcoPipeline` changes. No invariant changes yet — CGEN_025 still holds
because no `eco.construct.*` / `eco.allocate_closure` op is rewritten to
produce a non‑`!eco.value` result.

### Phase 1 — Local intra‑function escape analysis (tuples only)

Goal: behind `-enable-unboxed-agg` (OFF by default; Q5), rewrite
non‑escaping `eco.construct.tuple2` / `tuple3` results to `eco.make.*` so
existing tests still pass and a few hand‑authored Elm functions visibly
allocate less.

**1.1 `EcoEscapeAnalysisPass`** in
  `runtime/src/codegen/Passes/EcoEscapeAnalysis.{h,cpp}`.
  - `OperationPass<func::FuncOp>` (per‑function — module pass not yet
    needed).
  - Build worklist of candidate values: results of `Tuple2ConstructOp`,
    `Tuple3ConstructOp` only in Phase 1. (Records, customs, lists in
    Phase 2; closure envs in Phase 4.)
  - Walk uses; classify as `NonEscaping`, `EscapesToHeap`,
    `EscapesToUnknown` per design §D2.
  - Result is a side map `DenseMap<Value, EscapeKind>` exposed via an
    analysis interface so the next pass can read it without re‑computing.
  - Conservatively treat:
    - operand of any other `construct.*` / `allocate_*` / `box` /
      `store_global` / unknown `eco.call` → escapes;
    - operand of `papCreate` / `papExtend` capture slot → escapes;
    - operand of `project.tuple2/3` with the same value as receiver →
      non‑escaping use;
    - returned by `func.return` → escapes (cross‑function handled in
      Phase 3);
    - flowing into `eco.case` scrutinee → escapes (Q3/Q4 — aggregates do
      not flow through case in this phase).

**1.2 `EcoUnboxedAggSpecializePass`** in
  `runtime/src/codegen/Passes/EcoUnboxedAggSpecialize.{h,cpp}`.
  - Reads the analysis. For each `Tuple2ConstructOp` / `Tuple3ConstructOp`
    whose result is `NonEscaping`:
    - Replace with `Tuple2MakeOp` / `Tuple3MakeOp`. Result type changes
      from `!eco.value` → `!eco.tuple2<...>` / `!eco.tuple3<...>`.
    - Update each direct user (`project.tuple2/3`) to use the new operand
      type — the projection ops already accept either after Phase 0.4.
  - Emits a `LoweringStats` counter so we can measure rewrites/run.

**1.3 RS4GC FCA constraint — Phase 1 restriction.** LLVM's
`RewriteStatepointsForGC` asserts `"support for FCA unimplemented"` if a
first-class aggregate type contains GC pointers (`ptr addrspace(1)`)
and is live across a statepoint. Phase 1 does not yet wire SROA into the
LLVM-IR pipeline before RS4GC, so we conservatively restrict the
escape-analysis classifier: a candidate is rewritten only when **every
element type is a primitive** (`i64`, `f64`, `i16`). Any `!eco.value`
operand disqualifies the construct, even when the result is locally
projected and trivially eliminable. The restriction is implemented in
`EcoEscapeAnalysisPass::allElementsPrimitive` and is lifted in Phase 2's
SROA wiring (see Phase 2 prerequisites). Until then, real-Elm wins are
limited to numeric tuples.

**1.3 Pipeline wiring in `EcoPipeline.cpp::buildEcoToEcoPipeline`**
  - Add the two passes after `createEcoPAPSimplifyPass`, gated behind a
    CLI option `-enable-unboxed-agg` plumbed through `ecoc.cpp`.
  - Default OFF (Q5).

**1.4 Tests**
  - One Elm fixture where a tuple is built then projected and never
    escapes. Use FileCheck on the lowered Eco/LLVM dialect (Q7):
    - Assert no `eco.allocate_*` / `eco.to_heap` / `eco_alloc_tuple2` in
      the region under test.
    - Assert `eco.make.tuple2` is present where expected.
  - Optional `LoweringStats` counter assertion in a unit test.
  - Run full E2E (`cmake --build build --target full`) with the flag both
    OFF (no behavioural change expected) and ON (no regressions).

### Phase 2 — Records, customs, lists/cons

**Prerequisite — wire SROA before RS4GC at the LLVM-IR level.** Phase 1's
all-primitive restriction (§1.3) is unworkable for records, customs,
and cons cells because in real Elm code those almost always have at
least one `!eco.value` field. Before Phase 2 lifts the rewrite to those
shapes, the LLVM-IR pipeline must run SROA (and `mem2reg`) to scalarise
value-aggregate structs **before** `RewriteStatepointsForGC` is invoked,
so a struct of `(i64, ptr addrspace(1))` is broken into independent
scalar values that RS4GC can track per-element. Concretely:
- Audit each LLVM-IR pipeline construction site: `ecoc.cpp`,
  `EcoRunner.cpp`, `eco-boot.cpp`. Currently each builds a `PassManager`
  via `PB.buildPerModuleDefaultPipeline(...)` and then bolts on
  `RewriteStatepointsForGC`; verify SROA actually runs before that
  point at the relevant optimisation level.
- If SROA isn't reliably scheduled before RS4GC, add it explicitly in
  the same place RS4GC is added. Mirror the design's sketch in §H of
  the source design (`design_docs/escape-analysis.md`).
- Drop the `allElementsPrimitive` guard from `EcoEscapeAnalysisPass`
  once a stress run with the relaxed classifier is clean.
- Add a regression fixture exercising `(i64, !eco.value)` and
  `(!eco.value, !eco.value)` tuples as a non-escaping rewrite to lock
  in the lifted restriction.

After the prerequisite lands, extend the analysis and rewrite to:
- `RecordConstructOp` → `RecordMakeOp`.
- `CustomConstructOp` → `CustomMakeOp`. Per Q4, when a custom value
  flows into `eco.case` (the scrutinee path that reads the tag), the
  analysis classifies it as **escaping** — we do not widen `eco.case` to
  accept aggregate scrutinees in this work.
- `ListConstructOp` → `ConsMakeOp`. Cons cells are first‑class via the
  Phase 0 plumbing. The tail stays `!eco.value` (matches the heap list
  spine), so we get value‑level wins on the *tip* of a list (cons cells
  built and immediately projected/matched and discarded). Recursive
  `!eco.cons` spines are out of scope for this work.
- A useful corollary: `eco.get_tag` on a `!eco.custom` operand can fold
  to a constant from the op's structural `tag` attribute; this is added
  as a small canonicalisation but only matters once Phase 4 (or a later
  widening) lets a `!eco.custom` reach `eco.case`. For Phase 2 it has no
  user yet.

Update the invariant docs (see §4) when this phase lands so the new
shapes are recognised.

### Phase 3 — Worker/wrapper specialization (tuples / records / customs / lists)

Cross‑function unboxing per design §E, **excluding closure envs**.

#### Overview

Lift the SROA opportunity from intra‑function (Phase 2) to
cross‑function: when `@f` takes/returns a small aggregate and **none**
of its uses on either side of the call boundary escapes, split `@f`
into:

- `@f$unboxed` — worker with aggregate‑typed params/results.
- `@f` — wrapper retaining the original `!eco.value` ABI, calling the
  worker via `eco.from_heap` / `eco.to_heap`.

Internal direct calls are rewritten to the worker; external‑ABI callers
(closures, kernels, PAP captures) continue calling `@f`.

#### Pipeline placement

New module‑level pass `EcoUnboxedAggCrossSpec` running **before** the
existing per‑func `EcoEscapeAnalysis` + `EcoUnboxedAggSpecialize`:

```
... ParseAndElaborate ...
EcoPAPSimplify
EcoUnboxedAggCrossSpec        ← NEW (module pass, gated)
EcoEscapeAnalysis             (per‑func, existing)
EcoUnboxedAggSpecialize       (per‑func, existing)
... rest of pipeline ...
```

Order rationale: cross‑spec creates new worker funcs whose bodies are
then cleaned up by the per‑func specialize pass to rewrite their
internal `eco.construct.* → eco.make.*` for any aggregates that don't
escape locally either.

#### Step 1 — Add `eco.from_heap`

New op in `Ops.td`, mirror of `eco.to_heap`:

```
eco.from_heap %hp : !eco.value -> !eco.tuple2<i64, i64>
```

`Pure` (`NoMemoryEffect`); lowering reads each field via the same
heap‑projection helpers used by `eco.project.*`, packs into an LLVM
struct value. Verifier rejects `!eco.closure_env` (mirrors the
`eco.to_heap` rejection rule, CGEN_062).

#### Step 2 — Logical‑type metadata (Q1, resolved)

Add new `func.func` attributes — **the authoritative source** for
"logical Elm type of this `!eco.value` param/result":

- `eco.logical_param_types` (array, one entry per parameter)
- `eco.logical_result_types` (array, one per result)

Have the Elm→MLIR generator (Compiler.Generate.MLIR.Functions) populate
these from MonoType.

In the cross‑spec pass these attributes are read directly; do not
reverse‑engineer from `_operand_types` at call sites. A debug‑only
consistency check (`#ifdef ECO_LOWERING_VALIDATION`) verifies that
`_operand_types` at call sites match the callee's
`eco.logical_param_types`.

#### Step 3 — Two‑phase eligibility analysis (Q2, resolved)

Module‑level fixpoint analysis over functions:

- **Phase 3a (leaf pass)** — Scan all functions and identify **leaf
  candidates**: aggregate params/results never flow into `eco.call`
  arguments, or only flow into calls that don't take aggregates
  (primitives, runtime intrinsics with kernel ABI). Run an
  intra‑function escape check on those and mark **eligible** if all
  relevant values are NonEscaping.

- **Phase 3b (propagate upwards)** — Repeatedly scan remaining
  functions: if a function only passes aggregate params/results into
  callees that are **already marked eligible**, and its own
  intra‑function uses are NonEscaping, mark it eligible too. Iterate
  to a fixpoint (no new eligibles).

At call sites within an eligible caller:
- Callee marked eligible → may unbox this boundary.
- Callee not yet eligible → treat the aggregate as escaping for
  cross‑spec purposes (stay boxed at this call site).

This admits chained pipelines `f → g → h` once all satisfy the
constraints while remaining conservative for everything else.

#### Step 4 — Worker creation

For each eligible `@f`:

1. Clone with name `@f$unboxed` (uniquified via the symbol table per
   Q6 — start with `@f$unboxed`, fall back to `@f$unboxed_0`,
   `@f$unboxed_1`, ...) and attribute `eco.unboxed_worker = true`. Use
   `mlir::OpBuilder` + `cloneRegion`.
2. Rewrite signature: each eligible aggregate param becomes its
   aggregate type (`!eco.tuple2<...>` etc.); each eligible aggregate
   result likewise. **One‑level unboxing only** (Q5) — fields that are
   themselves aggregates stay as `!eco.value` in v1.
3. Walk the worker body and rewrite:
   - Param uses: `eco.project.* %p[i]` over the old `!eco.value`
     becomes plain `eco.project.tuple2 %agg[i] : !eco.tuple2<...> -> ...`
     (existing `EcoToLLVMHeap` extension for aggregates handles this).
   - Construct ops whose result was the function's return:
     `eco.construct.tuple2 ...` → `eco.make.tuple2 ...`.
   - `return %v : !eco.value` → `return %agg : !eco.tuple2<...>`.
4. **Recursive calls** (Q4, in scope): self‑recursive
   `eco.call @f` inside `@f$unboxed`'s body must be rewritten to call
   `@f$unboxed` directly (otherwise we'd box on every recursion).
   Mutual recursion: any call to a name already marked eligible in the
   fixpoint is rewritten to its `$unboxed` variant.

#### Step 5 — Wrapper construction (Q3, resolved — no shortcut)

Replace `@f`'s original body with a thin wrapper that always uses true
aggregate types between wrapper and worker. **Reject** the design
§E2.4 stage‑1 shortcut of keeping worker params as `!eco.value` —
workers must be "pure aggregate" internally so LLVM sees aggregates at
the function boundary and SROA can do its job.

```
func.func @f(%a: !eco.value, %b: !eco.value) -> !eco.value {
  %a_agg = eco.from_heap %a : !eco.value -> !eco.tuple2<i64, i64>
  %r_agg = func.call @f$unboxed(%a_agg, %b) : ...
  %r     = eco.to_heap %r_agg : !eco.tuple2<i64, i64> -> !eco.value
  return %r : !eco.value
}
```

#### Step 6 — Call‑site rewriting

For each `func.call @f(...)` / `eco.call @f(...)` in the module:

- Caller is itself eligible (specialized) **and** the operand is an
  aggregate value already in scope **and** the callee `@f` is
  eligible → rewrite to `func.call @f$unboxed`, threading the
  aggregate value through.
- Otherwise → leave calling the wrapper (`@f`).

PAP / indirect‑call conservatism: `eco.papCreate %f` and
`eco.papExtend %f` capture the function symbol. These must continue
to reference the wrapper (`@f`). A quick scan tags the wrapper with
`eco.has_pap_users = true`; this does **not** disable specialization
(the wrapper remains callable), it only disables rewriting indirect
call sites and any direct‑call sites whose callee may flow through a
closure.

#### Step 7 — Tests

Codegen fixtures (`test/codegen/cross_spec_*.mlir`):
- `cross_spec_tuple_pair_pass.mlir` — function returning a tuple,
  caller projects, expect worker with `!eco.tuple2` return + wrapper
  using `eco.to_heap`.
- `cross_spec_record_param_pass.mlir` — function taking a record,
  caller passes a fresh aggregate, expect worker with `!eco.record`
  param + wrapper using `eco.from_heap`.
- `cross_spec_recursive.mlir` — self‑recursive function over a tuple
  accumulator; expect recursion rewritten to `@f$unboxed`.
- `cross_spec_chained.mlir` — `f → g → h` pipeline where all three are
  eligible after fixpoint; assert all three end up specialized.
- `cross_spec_pap_negative.mlir` — same shape but the function is
  also captured via `papCreate`; expect worker created but external
  call sites (and any sites with a flow through closure) kept on the
  wrapper.
- `cross_spec_no_change_off.mlir` — flag off → no worker, no wrapper.
- `cross_spec_jit_contract.mlir` — JIT path proves behavioural
  equivalence end‑to‑end.

Elm‑source fixture: a small program where a top‑level helper takes /
returns a tuple and is called from `main`, exercising the pipeline
end‑to‑end.

Keep gated behind `-enable-unboxed-agg` until Phase 4 validation
lands.

#### Step 8 — Invariants

- **CGEN_063** (new): `eco.from_heap` is `Pure`, accepts
  `!eco.value`, produces an aggregate type, never `!eco.closure_env`.
- **CGEN_064** (new): `@f$unboxed` worker functions
  (`eco.unboxed_worker = true`) are direct‑callable only by symbols
  that have themselves been adapted; PAP capture of `@f` always
  references the wrapper.
- **CGEN_065** (new): `eco.logical_param_types` and
  `eco.logical_result_types` are present on every `func.func` emitted
  by the Elm→MLIR generator and must be array attributes whose length
  matches the function type's param / result count.
- Update `REP_AGG_001` to permit aggregate types as `func.func`
  parameter / result types **only** on functions tagged
  `eco.unboxed_worker = true` (currently they're SSA‑only
  intra‑function).

#### Implementation staging (Q7, resolved — accepted ~600–900 LOC, all gated)

Split into small reviewable steps, each landing as its own commit:

1. Add `eco.from_heap` op + lowering + basic invariants (CGEN_063) +
   roundtrip / negative fixtures.
2. Add `eco.logical_param_types` / `eco.logical_result_types`
   attributes (CGEN_065) — Elm→MLIR generator emits, debug check
   verifies.
3. Implement `EcoUnboxedAggCrossSpec` worker creation + wrapper
   construction (no call‑site rewrite yet); fixtures: leaf functions
   only, no recursion.
4. Add the two‑phase fixpoint eligibility analysis + call‑site
   rewriting (including recursion); fixtures: chained pipeline,
   recursive accumulator.
5. Add PAP / indirect‑call conservatism + Elm‑source integration test
   + final invariant updates (CGEN_064, REP_AGG_001 amendment).

All five steps gated behind `-enable-unboxed-agg`.

Closure ABI / `_capture_abi` / `_fast_evaluator` paths are **not**
touched — closure envs are Phase 4.

### Phase 4 — Closure environment escape analysis (separate later phase)

Per Q9, this is a separate later effort after the tuple/record/custom/
list rollout has stabilised. The Phase 0 plumbing
(`!eco.closure_env`, `eco.make.closure_env`, `eco.make.closure`,
`ProjectClosureFromEnv` lowering) **is already in place**, so this phase
is purely about extending escape analysis + worker/wrapper to cover
closures:
- Extend `EcoEscapeAnalysisPass` candidates to include
  `AllocateClosureOp` / `PapCreateOp` / `PapCreateGroupOp` results where
  the closure object's lifetime is locally bounded.
- Coordinate with typed closure calling (`_closure_kind`,
  `_fast_evaluator`, `_dispatch_mode`, `_capture_abi`) — likely the
  hardest aspect, since unboxed envs interact with both the generic
  `$clo` and fast `$cap` clones.
- Add wrapper synthesis that converts heap closures to `!eco.closure_env`
  via projection chains for the worker, then back to `!eco.value` via
  `eco.make.closure` for the wrapper return path.
- Possibly extend `eco.make.closure`'s env operand to also accept
  `!eco.value` (for cases where wrappers need to re‑pack a heap closure
  with new arity/function metadata) — only if Phase 4 actually requires
  it.
- Defer scope/details until Phase 3 lands and we have data on which
  closure shapes dominate.

## 4. Invariants & test logic

When Phase 1 lands and `eco.make.*` ops exist, update:

- `design_docs/invariants.csv`:
  - Re‑word **CGEN_025** (line 265) from "All eco.construct.* ops produce
    !eco.value" to "All **heap‑backed** construct ops (`eco.construct.*`)
    produce `!eco.value`. Value‑only aggregate construction must use
    `eco.make.*` ops with non‑`!eco.value` aggregate result types and
    must not participate in GC root sets, **except `eco.make.closure`**
    which is documented as the dedicated closure‑realisation op (Q‑A‑b)
    and is itself a heap allocation returning `!eco.value`."
  - Add **CGEN_061 (new — was CGEN_028 in earlier plan; CGEN_028
    already taken by `eco.case` yield invariant)**: every
    `eco.make.*` op except `eco.make.closure` is `Pure`, never carries
    `live_roots`, and never appears as an operand of any
    `Eco_GCRootCarrier` interface method. `eco.make.closure` is
    `GCRootCarrier`, returns `!eco.value`, and is the only op allowed
    to bridge the value‑aggregate and heap worlds by allocating.
  - Add **CGEN_062 (new — was CGEN_029 in earlier plan; CGEN_029
    already taken by `eco.case` tag‑array length invariant)**:
    `eco.to_heap` accepts only *data‑aggregate* operands
    (`!eco.tuple2/3`, `!eco.record`, `!eco.custom`, `!eco.cons`);
    a `!eco.closure_env` operand fails verification. Closure
    realisation is exclusively the job of `eco.make.closure`.
  - Add **REP_AGG_001 (new)**: aggregate types
    (`!eco.tuple2/3`, `!eco.record`, `!eco.custom`, `!eco.cons`,
    `!eco.closure_env`) are an SSA‑only representation independent of
    heap layout; they may be lowered to LLVM struct values held in
    registers, never to `ptr addrspace(1)`. Heap‑layout artifacts
    (`unboxed_bitmap`, `field_count`, `tag`, `head_kind`) live on heap
    construct / `eco.to_heap` / `eco.make.closure` ops, never on the
    value types or on the value‑only `eco.make.*` ops (Q‑B).
  - Keep CGEN_026 / CGEN_027 / REP_BOUNDARY_002 unchanged: they
    constrain `eco.construct.*` and operate on operand SSA types,
    which is orthogonal.

- `design_docs/invariant-test-logic.md`: update
  `ConstructResultTypeTest` (referenced in design §I2) to allow either
  `eco.construct.*` → `!eco.value` or `eco.make.*` → aggregate, with
  the documented exception that `eco.make.closure` returns `!eco.value`.

- New invariant tests:
  - `MakeOpResultIsAggregate` — every value‑level `eco.make.*` op
    (excluding `eco.make.closure`) has a result whose type is one of
    the Eco aggregate types.
  - `MakeOpNotInGCRootSet` — no `Eco_GCRootCarrier` op carries a
    value‑level `eco.make.*` result as a `live_root` (excluding
    `eco.make.closure`, whose result is `!eco.value` and is therefore
    a legitimate root).
  - `ToHeapRejectsClosureEnv` — verifier rejects `eco.to_heap` on a
    `!eco.closure_env` operand.

## 5. Out‑of‑scope explicitly

- `eco.from_heap`: introduced in Phase 3 (worker wrappers); Phase 0/1/2
  do not need it.
- Widening `Eco_AnyValue` to include aggregates (Q3): avoided across
  Phases 0–3. Aggregates flow only through `make → project/extract →
  make` and `make → to_heap`. Crossing `eco.case`, `eco.joinpoint`,
  `eco.return`, `eco.yield` requires that widening — not in this
  initiative.
- `eco.case` accepting aggregate scrutinees (Q4): aggregates that would
  flow into case are classified as escaping; case stays operating over
  `!eco.value`.
- Closure environment escape analysis / specialisation (Q9): Phase 4 of
  this plan, separate later effort. Phase 0 ships the closure_env
  plumbing (type, make op, to_heap, lowering, projection extension) so
  Phase 4 can build on it without dialect/lowering changes.
- Recursive `!eco.cons` spines (`make.cons` whose tail is itself
  `!eco.cons`): tail stays `!eco.value`, matching the heap list spine.
- Strings, ByteBuffers, ElmArrays.
- Removing the dead `createConstructLoweringPass` /
  `createControlFlowLoweringPass` declarations (Q10): orthogonal
  cleanup, separate small PR.
- Front‑end `MlirType` extension (Q8): Elm continues emitting
  `!eco.value` and `eco.construct.*` through Phases 0–3; aggregate types
  are synthesised by C++ passes only.

## 6. Effort estimate

- Phase 0: ~3–4 days (6 parameterised types + 6 make ops + to_heap with
  per‑kind attributes + projection extensions across heap+closure
  files + ~10 FileCheck fixtures).
- Phase 1: ~2–3 days (analysis + specialize pass + flag + tests).
- Phase 2: ~4–6 days (records / customs / lists, case‑on‑custom
  classification, invariant updates).
- Phase 3: ~1–2 weeks (worker/wrapper for tuples/records/customs/lists,
  signature rewrites, call sites, `from_heap`, measurement).
- Phase 4 (closure envs, separate later effort): not estimated here.

## 7. Resolved decisions

All design and implementation questions have been resolved. The plan
above incorporates each decision; this section is a single index for
reviewers / future maintainers.

1. **No new `ConstructLowering` pass.** `eco.construct.*` keeps lowering
   directly to runtime allocator calls in `EcoToLLVMHeap.cpp`. New
   `eco.make.*` ops get their own LLVM lowering. The dead
   `createConstructLoweringPass` declaration is left for a separate
   cleanup PR (#10).

2. **Aggregate types are parameterised by element types.** All six
   shapes carry their element/field types so `EcoTypeConverter` can
   convert them without op context. Heap‑layout artifacts
   (`unboxed_bitmap`, `field_count`, `tag`, `head_kind`) stay on the
   ops, never on the types (Q‑B).

3. **`Eco_AnyValue` is NOT widened.** Aggregates stay out of it. They
   exist only as local SSA values and as worker function params/results;
   they do not flow through `eco.case` / `joinpoint` / `return` /
   `yield`.

4. **Custom into `eco.case` = escaping.** No widening of `eco.case` to
   accept aggregate scrutinees in this work. Any `CustomMakeOp`/
   `CustomConstructOp` value that would reach a case is classified as
   escaping and stays boxed.

5. **`-enable-unboxed-agg` default OFF.** Wired through `ecoc.cpp`,
   used only by targeted fixtures and benchmarks until Phase 2
   stabilises.

6. **`Eco_ToHeapOp` is a `GCRootCarrier`** for the four data‑aggregate
   shapes (tuple2/3, record, custom, cons). Participates in
   `EcoGCPrepare` root discovery; `live_roots` is populated from SSA
   liveness, just like `eco.box` and `eco.allocate_*`. Lowering reuses
   the existing `eco_alloc_*` runtime helpers and is *not* routed
   through any old ConstructLowering path.

7. **"No allocation" assertions = FileCheck (primary), stats
   (optional).** Phase 0/1/2 fixtures use FileCheck on the lowered
   Eco/LLVM dialect:
   - `// CHECK-NOT: eco.allocate_`
   - `// CHECK-NOT: eco.to_heap`
   - `// CHECK-NOT: call @eco_alloc_`
   - `// CHECK: eco.make.tuple2` (or shape under test)
   `LoweringStats` counter assertions are a nice‑to‑have; raw `.ll`
   greps are acceptable but not the primary mechanism.

8. **Front‑end MlirType stays.** Elm keeps emitting `!eco.value` and
   `eco.construct.*` for Phases 0–3. Aggregate types are synthesised
   by C++ passes only.

9. **Closure‑env unboxing is Phase 4 (separate later effort).** Phase 0
   ships the closure_env plumbing
   (`!eco.closure_env`, `eco.make.closure_env`, `eco.make.closure`,
   `ProjectClosureFromEnv` lowering) so Phase 4 only needs to add
   escape analysis + worker/wrapper, with no dialect or lowering
   changes.

10. **Cleanup of dead `createConstructLoweringPass` /
    `createControlFlowLoweringPass`** is a **separate small PR**, not
    part of this initiative.

11. **(Q‑A) Closure realisation is a dedicated `eco.make.closure` op.**
    `eco.to_heap` stays uniform over data aggregates only and rejects
    `!eco.closure_env`. `eco.make.closure` is the single op that
    combines `!eco.closure_env` + `function` symbol + `arity` →
    `!eco.value`, allocates a heap closure, and is the one
    `make.*`‑family exception that is `GCRootCarrier` and not `Pure`.

12. **(Q‑B) Tag stays on the op; `unboxed_bitmap` is heap‑layout only.**
    `!eco.custom` is not parameterised by tag; the tag attribute lives
    on `Eco_CustomMakeOp` / `Eco_CustomConstructOp` / `Eco_ToHeapOp` /
    `Eco_MakeClosureOp` (where applicable). `unboxed_bitmap` /
    `field_count` / `head_kind` appear only on heap‑describing ops, never
    on value types or the value‑only `eco.make.*` ops.

13. **(Q‑C) Projection type dispatch lives on the heap side.**
    `Tuple2/3ProjectOpLowering`, `RecordProjectOpLowering`,
    `CustomProjectOpLowering`, `ListHeadOpLowering`,
    `ListTailOpLowering` in `EcoToLLVMHeap.cpp` gain an aggregate‑type
    branch that emits `extractvalue`. `ProjectClosureOpLowering` in
    `EcoToLLVMClosures.cpp` is left untouched until Phase 4; a small
    parallel `ProjectClosureFromEnvLowering` next to
    `EcoToLLVMValueAgg.cpp` handles `!eco.closure_env` operands.

14. **(Q‑D) Naming.** Keep `eco.make.cons` and the existing
    `eco.construct.list`. The asymmetry is documented in the new ops'
    summaries: heap‑level list constructor vs value‑level cons cell
    constructor. No renames.
