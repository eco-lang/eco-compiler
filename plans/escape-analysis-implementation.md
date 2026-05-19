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

### Phase 3.1 — Completing Cross‑Function Unboxed Aggregates

Resolved against the Q1–Q7 questions raised when the design was first
imported (2026‑05‑07). This section reflects the *final* in‑scope
plan; deferred work moved to **Phase 3.2** below.

#### 0. Goals and non‑goals

**Goals.** Finish the cross‑function (worker/wrapper) small‑aggregate
work started in Phase 3:

1. Cross‑procedural fixpoint eligibility for **DAGs of functions**
   (chained `f → g → h`). SCCs of size > 1 are deferred to 3.2.
2. Result‑side unboxing for **all‑primitive aggregate results only**
   (Q2). Aggregate results containing `!eco.value` elements stay
   boxed for now.
3. Remove the all‑primitive‑elements restriction on aggregate
   **parameters** by introducing a pre‑lowering Eco‑level rewrite pass
   that flattens aggregate boundary types into multiple scalar
   params (Q1). Eco→LLVM continues to see only scalar / pointer
   types at the boundary.
4. Extend logical‑type attributes to every Elm→MLIR function emitter
   that may produce a cross‑spec candidate (Q5).
5. Single‑ctor customs as `LCustom` / `AggKind::Custom` (Q3).
   Multi‑ctor customs stay opaque (`LUnknown` / `"value"`).
6. Cons cells encoded in logical‑type attributes for round‑trip
   consistency, but treated as `AggKind::None` in cross‑spec (Q4) —
   no actual cons specialisation in 3.1.
7. Elm‑source positive + negative fixtures.
8. Eco‑level (`mlir-llvm`) tests for worker / wrapper IR shape; the
   post‑RS4GC `.ll` validation harness is deferred to 3.2.

**Non‑goals.** No Elm semantics / ABI change. No edits to earlier
phases. No closure‑env unboxing (Phase 4). No SCC handling (Phase
3.2). No new GC behaviour. All new behaviour gated behind
`-enable-unboxed-agg`.

#### 1. Cross‑procedural fixpoint eligibility (DAG only)

Extend `EcoUnboxedAggCrossSpec` from "local, parameter‑only" to a
two‑phase analysis. Build per‑func info `FunctionAggInfo` with:
param/result aggregate slots (`AggKind` + logical descriptor),
intra‑function `paramNonEscaping[i]` / `resultNonEscaping[j]` flags,
and a direct‑callee adjacency list (walk `func.call` / `eco.call` with
`FlatSymbolRefAttr`).

**Phase A (leaf pass).** A function is a leaf candidate if no
aggregate slot ever flows into a callee. Mark each leaf as eligible
iff its slot escape flags are all true.

**Phase B (propagate upwards).** Iterate: a function becomes eligible
when every aggregate flow at its call sites targets an already‑
eligible callee, and its local escape checks pass. Continue to
fixpoint.

**SCC conservatism for v1 (Q7).** Compute SCCs as a side effect of
the call‑graph build. Any function in an SCC of size > 1 (i.e. that
participates in mutual recursion or a cycle) is marked **non‑eligible**
and skipped. Single‑function SCCs with self‑edges (direct recursion)
remain eligible — that's the case Phase 3 already handles.

Eligible funcs are tagged `eco.unboxed_cross_eligible = true` and
become workers + wrappers.

#### 2. Result‑side unboxing — primitive‑element aggregates only (Q2)

**Result eligibility filter.** A result slot is cross‑spec‑eligible
iff its logical type is an aggregate **and every element type is
primitive** (i64 / f64 / i16 / i1). Aggregate results containing
`!eco.value` elements stay boxed in the worker signature; only
parameter aggregates may carry boxed elements (Stage 3 flattening
handles those).

**Signature.** Worker creation rewrites each eligible aggregate
result slot into the corresponding `!eco.tuple2<...>` /
`!eco.tuple3<...>` / `!eco.record<...>` / `!eco.custom<...>`.

**Worker body — return rewriting (Q6).** Cross‑spec performs an
internal, targeted construct→make rewrite limited to operations that
feed an eligible result return. For each `func.return` in the cloned
body, walk each operand at an aggregate result position back to its
producer:
- If producer is an `eco.construct.tuple2/3/record/custom`, rewrite
  to the matching `eco.make.*` (same operands, aggregate result type)
  and update the return operand.
- If producer is a param (already aggregate after parameter
  rewriting) or `eco.from_heap`, retype the return operand directly.

The rest of the worker body (constructs that don't feed a return) is
untouched here; per‑func specialise (Phase 2) handles that as part of
its normal intra‑function pass running after cross‑spec.

**Wrapper body.** Mechanically: `eco.from_heap` each aggregate param,
`func.call @f$unboxed`, `eco.to_heap` each aggregate result, return
the boxed values.

**Caller call‑site rewriting.** A caller that is itself eligible AND
uses the result in aggregate‑friendly ways (projection / local
pattern‑match, non‑escaping per its own intra‑function analysis) is
rewritten to call `@f$unboxed` and keep the aggregate result.
Otherwise it stays on the wrapper. Conservative for v1.

#### 3. Pre‑lowering flattening pass (Q1)

**New pass:** `EcoFlattenAggBoundary`, runs *after* `EcoUnboxedAggCrossSpec`
and before any other lowering. Operates on `func.func` ops with
aggregate‑typed parameters or results in their signature; the type
converter never sees aggregate types at function boundary.

**Per‑function rewrite.**
- Each aggregate parameter is replaced by `N` scalar parameters in the
  function's `function_type` and entry block.
- At entry, an `eco.make.*` op repacks the scalars into the original
  aggregate SSA value, replacing the original block argument.
- Each aggregate return value is decomposed via `eco.project.*` ops at
  every `func.return` and the return takes the flattened operand list.
- The function's `function_type` is updated to the flattened shape.

**Per‑call‑site rewrite.**
- Every `func.call @worker(%agg, ...)` is rewritten so each aggregate
  operand is decomposed via `eco.project.*` immediately before the
  call; the call's operand list is the flattened sequence.
- Every `func.call @worker` whose result was an aggregate is followed
  by an `eco.make.*` to repack the now‑flattened return values into
  the original aggregate SSA shape.

After this pass, every aggregate type appears only inside function
bodies (where SROA can scalarise it). Eco→LLVM type conversion stays
1:1 (no special boundary handling needed).

**Tests.** New `flatten_*.mlir` fixtures: round‑trip a worker through
the pass and check the flattened signature + insertvalue/extractvalue
chains in the body.

#### 4. Logical‑type attribute coverage (Q5)

Centralise logical‑type computation in
`Compiler.Generate.MLIR.LogicalTypes` and apply at every `func.func`
emission site:
- `generateClosureFuncSingle` (Phase 3 already done)
- `generateTailFunc` (Phase 3 already done)
- `generateClosureFuncWithClones` — both `$cap` and `$clo`. The `$cap`
  form encodes captures + params: each capture entry is its precise
  logical descriptor (or `LUnknown` if unavailable), then the original
  Elm params. `$clo` is treated as opaque (`LUnknown` everywhere).
- `generateExtern`, kernel decls — emit `LUnknown` (or omit) since
  there is no Elm‑source MonoType.
- `generateCtor`, `generateEnum`, `generateManagerLeaf`,
  `generateGenericCloneFunc` — emit logical descriptors for the
  parameters and result the front‑end can compute; opaque otherwise.

CGEN_065 is updated to make absent / `LUnknown` ⇒ non‑eligible
explicit.

#### 5. Customs and cons in logical types (Q3, Q4)

Extend `LogicalTypes.elm`:
- `LCustom Tag (List LogicalTypeDesc)` — emitted **only when** the
  Custom is a single‑constructor type with field count ≤ N (e.g. 3).
  Multi‑ctor customs are encoded as `LUnknown` so cross‑spec never
  attempts them.
- `LCons headType tailType` — included in the encoder so the
  attribute roundtrips for documentation / future use.

Extend C++ `AggKind`:
- `AggKind::Custom` is a real cross‑spec target.
- `AggKind::Cons` is parsed but **mapped to `AggKind::None`** in
  cross‑spec (Q4 — skip cons specialisation in 3.1).

Validation: any logical descriptor whose shape exceeds the
configured size limit, or whose elements include unsupported types,
demotes to `AggKind::None`.

#### 6. Tests

Codegen fixtures (gated behind `-enable-unboxed-agg`):
- `cross_spec_chained_pipeline.mlir` — three‑function `f → g → h`
  pipeline becoming eligible via the fixpoint.
- `cross_spec_returns_tuple.mlir` — function returning a primitive
  tuple, worker returns aggregate, wrapper boxes via `eco.to_heap`.
- `cross_spec_returns_record.mlir` — same for an all‑primitive record.
- `cross_spec_custom_pass.mlir` — single‑ctor custom unboxing.
- `cross_spec_pointer_param.mlir` — parameter aggregate carrying
  `!eco.value` elements: post‑flattening, the worker has individual
  `ptr addrspace(1)` LLVM args.
- `cross_spec_no_change_off.mlir` — flag off → no workers, no
  `from_heap`/`to_heap` inserted.
- `flatten_tuple2_pointer.mlir`, `flatten_tuple2_returns.mlir` —
  round‑trip the flattening pass; assert IR shape.

Elm‑source fixtures:
- One positive: cross‑function param + result unboxing in real Elm.
- One negative (`CrossSpecTupleEscapesTest.elm`): tuple captured /
  stored such that conservatism kicks in. `// CHECK-NOT:
  @*$unboxed`, `// CHECK: func.call @<name>(`.

#### 7. Invariants

- **CGEN_063**: unchanged.
- **CGEN_064** (extend): worker `@f$unboxed` is callable only from
  the matching wrapper `@f` or from other eligible callers; PAPs /
  closures always reference the wrapper. (SCC clause deferred to
  3.2.)
- **CGEN_065** (extend): absent or `LUnknown` ⇒ non‑eligible.
- **CGEN_066** (new): the `EcoFlattenAggBoundary` pass is the sole
  introducer of multi‑arg / multi‑result `func.func` signatures
  derived from aggregate boundary types; after this pass no
  aggregate type appears at any function boundary.
- **REP_AGG_001** (extend): aggregate types may appear at function
  *boundary* in Eco IR after cross‑spec but before
  `EcoFlattenAggBoundary`; after that pass they appear only inside
  function bodies. RS4GC therefore never sees a struct‑typed gc
  pointer at a call boundary.
- All Phase 3.1 behaviour gated behind `-enable-unboxed-agg`.

#### 8. Implementation staging (Q7)

Five reviewable commits, each with E2E + stress run:

1. **Logical‑type attribute coverage** — extend
   `LogicalTypes.elm` (LCustom, LCons, LUnknown), wire into all
   remaining function emitters; CGEN_065 updated. No behavioural
   change yet.
2. **Custom support in cross‑spec** — parse `LCustom`, accept
   `AggKind::Custom`, fixtures for single‑ctor customs.
3. **Pre‑lowering flattening pass** — `EcoFlattenAggBoundary` lands;
   drop the all‑primitive‑params constraint in cross‑spec; new
   flatten / pointer‑param fixtures.
4. **Result‑side unboxing (primitives only)** — extend cross‑spec
   with the per‑result eligibility filter, internal worker‑local
   construct→make for return‑feeding ops, wrapper boxing.
5. **Two‑phase fixpoint eligibility (DAG only)** — leaf pass +
   propagate‑upwards; SCCs > 1 marked non‑eligible. Chained pipeline
   fixture lands. Negative + positive Elm fixtures, final invariant
   updates (CGEN_064/065/066, REP_AGG_001).

Estimated total: ~1200–1700 LOC across compiler + runtime + tests.

### Phase 3.2 — Cross‑Function Unboxed Aggregates: completing the pipeline

Sequel to Phase 3.1 that closes the two most visible gaps left open
when 3.1 landed: mutual recursion (currently disqualified at SCC > 1)
and empirical validation that the post‑SROA LLVM IR actually shows
no aggregate boundary structs. Neither item depends on the other;
both extend Phase 3.1 without requiring profiling data the
codebase doesn't yet produce.

Three further potential extensions to the data‑aggregate path
(`!eco.value`‑element results, cons‑cell specialisation, and
miscellaneous guard relaxations) used to live under 3.2 but have
been pushed to §8 below because each is gated on benchmark or
profiling data that 3.1 / 3.2 don't yet provide.

#### 1. SCC‑aware mutual recursion (Q7 deferral)

Lift the "SCC > 1 ⇒ non‑eligible" rule from Phase 3.1.

- After call‑graph build, compute SCCs (use `mlir::CallGraph` or a
  local Tarjan).
- For each SCC `S` of size > 1: gather all aggregate slots across
  members; require every local escape check to pass AND every
  aggregate flow at calls *between* members to target another
  member's matching slot. Any blocked member ⇒ entire SCC ineligible.
- If eligible: clone every `g ∈ S` to `@g$unboxed`; rewrite all
  intra‑SCC calls to `@h$unboxed`; wrappers `g` only call `g$unboxed`.

Fixture: `cross_spec_mutual_recursive.mlir` — 2‑member SCC over a
tuple accumulator. Elm‑source: `CrossSpecMutualRecursiveTest.elm`.

Update CGEN_064 to add the SCC clause.

##### Implementation notes

The Phase 3.1 work already computes SCCs via Tarjan (`computeSCCs` in
`EcoUnboxedAggCrossSpec.cpp`) and disqualifies anything in an SCC of
size > 1. The §3.2 #1 work *removes* that disqualification and adds a
second analysis pass that lets SCC members promote atomically. The
existing single‑function machinery is mostly reusable — the changes
below are additive, not a rewrite.

**A. Algorithm structure — single fixpoint, "same‑SCC" admission rule.**

The existing fixpoint loop (lines ~840–910 of `EcoUnboxedAggCrossSpec.cpp`)
runs first over DAG candidates as today. Then a second pass iterates
each SCC of size > 1 as a unit:

1. Initialize a per‑member *tentative* `paramShapes` / `resultShapes`
   from each member's original logical types.
2. Inner fixpoint: each iteration, re‑derive every member's tentative
   shapes using the use checks below. Iterate until shapes stabilise
   (no further demotion across any member).
3. After convergence, commit each member as eligible iff its tentative
   shapes still show at least one promoted aggregate. Members with
   nothing left to promote simply don't get workers (existing logic).

This is *not* "atomic all‑or‑none": SCC members commit independently
once the inner fixpoint settles. The atomicity comes implicitly from
the propagation rule below — a demotion in one member forces matching
demotions in every member calling that slot, so members either all
keep their shapes mutually consistent or all collapse to Boxed
together.

**B. Slot‑matching semantics.**

Reuse the existing `aggregateShapesMatch` helper. A call site
`A → B(args)` at operand position k feeding from an aggregate slot
`A.tentative[i]` is accepted iff
`aggregateShapesMatch(A.tentative[i], B.tentative[k])`. Custom tags
must match (already enforced by `aggregateShapesMatch`).

Result‑side: an eligible‑call producer feeding `A`'s return at
position j from `B`'s result position j is accepted iff
`aggregateShapesMatch(A.tentative_result[j], B.tentative_result[j])`.

Positional correspondence everywhere — `func.call`'s k‑th operand
maps to `B`'s k‑th param; `eco.call`'s positional semantics are
identical.

**C. Use‑check extensions — accept same‑SCC callees with shape match.**

`allUsesAreProjectionsOrCallsToEligible` (3.1) accepts: projection,
self‑call, call‑to‑eligible, return‑as‑passthrough. The SCC pass
adds one more accepted class: **call to a same‑SCC member at a
position whose tentative shape matches our slot's tentative shape**.
A small wrapper:

```cpp
static bool allUsesAreProjectionsOrCallsToEligibleOrSameSCC(
    BlockArgument arg,
    const LogicalShape &paramShape,
    StringRef selfName,
    const llvm::DenseSet<StringRef> &eligibleCallees,
    ArrayRef<LogicalShape> ownResultShapes,
    const llvm::DenseSet<StringRef> &sccMembers,
    const llvm::DenseMap<StringRef, Candidate> &candidates,
    const SmallVectorImpl<LogicalShape> *tentativeParamsByMember);
```

For a `func.call @G(...)` use at operand position k:
* if `G == selfName` → accept;
* if `G ∈ eligibleCallees` → accept;
* if `G ∈ sccMembers` and `tentativeParamsByMember[G][k]` matches
  `paramShape` (using `aggregateShapesMatch`) → accept;
* otherwise → reject (demote `paramShape`).

The result‑side check
(`resultPositionHasAggregateProducer`) extends symmetrically: an
`eco.call` / `func.call` to a same‑SCC member at result position j
is accepted iff the member's tentative `resultShapes[j]` matches the
caller's tentative `resultShapes[i]`.

**D. Propagation through demotion (atomic collapse).**

If member A demotes `tentative[i]` to Boxed in one iteration, any
same‑SCC member B with `func.call @A(..., op_at_pos_i, ...)` loses
the "same‑SCC callee at matching slot" justification for B's slot
that flows into `op_at_pos_i`. The next inner‑fixpoint iteration
notices the mismatch (B's tentative[from] no longer matches A's now‑
Boxed `tentative[i]`) and demotes B's slot too. The loop iterates
until all surviving slots are mutually consistent.

This is identical in spirit to the 3.1 fixpoint's "demote until
stable" pattern, just scoped to SCC members and using tentative
(not yet committed) callee shapes.

**E. CGEN_064 SCC‑clause wording.**

Append to the existing CGEN_064 paragraph:

> Phase 3.2 amendment: SCCs of size > 1 are no longer disqualified.
> A second analysis pass after the DAG fixpoint runs an inner
> per‑SCC fixpoint over each multi‑member SCC, admitting same‑SCC
> calls as if the callee were eligible iff the callee's tentative
> slot shape matches the caller's at that position (verified via
> `aggregateShapesMatch`). Demotion in any member propagates
> through to every other member referencing that slot, so surviving
> shapes are mutually consistent by construction. Members commit
> independently once tentative shapes stabilise; the existing
> `CalleeRedirect` machinery rewrites intra‑SCC calls to the
> appropriate `$unboxed` worker (or leaves them on the wrapper
> for members with no promoted slots).

**F. Fixture sketches.**

`test/codegen/cross_spec_mutual_recursive.mlir` — 2‑member SCC over
a tuple2 accumulator:

```mlir
// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s

module {
  func.func @ping(%t: !eco.value, %n: i64) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i", "i64"],
          eco.logical_result_types = ["i64"]
      } {
    %zero = arith.constant 0 : i64
    %is_zero = arith.cmpi eq, %n, %zero : i64
    %a = eco.project.tuple2 %t[0] : !eco.value -> i64
    %one = arith.constant 1 : i64
    %nm1 = arith.subi %n, %one : i64
    %r = "eco.call"(%t, %nm1) {callee = @pong}
        : (!eco.value, i64) -> i64
    %out = arith.select %is_zero, %a, %r : i64
    return %out : i64
  }
  func.func @pong(%t: !eco.value, %n: i64) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i", "i64"],
          eco.logical_result_types = ["i64"]
      } {
    %zero = arith.constant 0 : i64
    %is_zero = arith.cmpi eq, %n, %zero : i64
    %b = eco.project.tuple2 %t[1] : !eco.value -> i64
    %one = arith.constant 1 : i64
    %nm1 = arith.subi %n, %one : i64
    %r = "eco.call"(%t, %nm1) {callee = @ping}
        : (!eco.value, i64) -> i64
    %out = arith.select %is_zero, %b, %r : i64
    return %out : i64
  }
}

// Both workers exist (atomic SCC promotion):
// CHECK-DAG: llvm.func @ping$unboxed
// CHECK-DAG: llvm.func @pong$unboxed
// Intra‑SCC calls go to the worker variants:
// CHECK-DAG: llvm.call @pong$unboxed
// CHECK-DAG: llvm.call @ping$unboxed
```

This fixture is structurally identical to the 3.1 negative
sentinel `cross_spec_mutual_recursive_skipped.mlir`; once 3.2 #1
lands, that sentinel becomes redundant and can be deleted (or
re‑purposed as a different negative case).

`test/elm/src/CrossSpecMutualRecursiveTest.elm` — parity‑style
mutual recursion in real Elm:

```elm
module CrossSpecMutualRecursiveTest exposing (main)

-- CHECK: result: 6

import Html exposing (text)

evenPair : ( Int, Int ) -> Int -> Int
evenPair pair n =
    if n <= 0 then
        case pair of
            ( a, _ ) -> a
    else
        oddPair pair (n - 1)

oddPair : ( Int, Int ) -> Int -> Int
oddPair pair n =
    if n <= 0 then
        case pair of
            ( _, b ) -> b
    else
        evenPair pair (n - 1)

main =
    let
        result = evenPair ( 1, 6 ) 5
        _ = Debug.log "result" result
    in
    text "done"
```

Compute: `evenPair (1,6) 5 → oddPair … 4 → evenPair … 3 → oddPair
… 2 → evenPair … 1 → oddPair … 0 → b = 6`.

**Effort and ordering.** The change is one new helper
(`runSCCFixpoint`), one extension to each use check, and one new
fixture pair. Estimated ~150 LOC C++ + ~50 LOC fixtures. Land as
a single commit:

1. Extend the use checks with the same‑SCC tentative‑shape branch.
2. Add the SCC pass after the DAG fixpoint in `runOnOperation`.
3. Drop the `sccDisqualified` block (or invert it — only
   single‑function SCCs need no special handling now).
4. Add fixtures; delete or rewrite the `…_skipped` sentinel.
5. Amend CGEN_064 with the wording in (E).

#### 2. LLVM‑level performance / shape validation harness

Plumb a final‑LLVM‑IR emission mode (or extend the existing one) so
selected `cross_spec_*` fixtures can FileCheck the post‑RS4GC `.ll`:
- `CHECK: define {{.*}} @sum_pair_unboxed(i64 {{.*}}, i64 {{.*}})`
- `CHECK-NOT: insertvalue` / `extractvalue` / `alloca { ... }` for
  the worker's parameter shape after SROA + RS4GC.
- For pointer‑containing tuples post‑flattening: `ptr addrspace(1)`
  in the param list, no struct.

Add the harness as a new emit option in `ecoc` (e.g. `-emit=llvm-ir`)
or extend `mlir-llvm`. Fixture infrastructure (`%FileCheck`) reused.

Optional: an allocation‑counter microbenchmark showing the delta
between flag‑off and flag‑on for an eligible pipeline. Defer further
if test infra doesn't expose allocation counters.

##### Implementation notes

The plumbing is **already in place** — no new emit mode is needed.
Codebase facts (verified before this section was written):

- `-emit=llvm` exists today in `ecoc.cpp` (the `DumpLLVMIR` enumerator
  and its CLI mapping); `dumpLLVMIR` in `ecoc.cpp:200` translates
  MLIR → LLVM IR, then runs `eco::addEcoGCPipeline`, then dumps.
- `eco::addEcoGCPipeline` in `Passes/EcoPtrIntVerify.cpp:412` runs
  **mem2reg → SROAPass → FoldExtractValuePass → RewriteStatepointsForGC**
  in that order. SROA is correctly scheduled BEFORE RS4GC (the Phase
  2 prerequisite is satisfied).
- The codegen test runner already dispatches `// RUN: %ecoc %s
  -emit=llvm …` — see `parseEmitMode` in `CodegenIsolatedTest.hpp:89`
  and `CodegenTest.hpp:56`.

Net effect: the post‑`-emit=llvm` IR is already post‑SROA and
post‑RS4GC. The "harness" is just a set of fixtures using that
existing emit mode plus FileCheck.

**Target fixtures (suggested).** Each is a `.mlir` input identical
to an existing `cross_spec_*` fixture, paired with a `.ll`‑oriented
CHECK template that asserts the post‑SROA scalarisation actually
happened:

* `cross_spec_tuple2_pass_llvm.mlir` — `// RUN: %ecoc %s -emit=llvm
  -enable-unboxed-agg …`. Source is the existing
  `cross_spec_tuple2_pass.mlir`'s function. CHECK lines:
    - `CHECK: define {{.*}} @add_pair$unboxed(i64 {{.*}}, i64 {{.*}})`
    - `CHECK-NOT: insertvalue` (in the worker)
    - `CHECK-NOT: alloca` (in the worker)
* `cross_spec_pointer_param_llvm.mlir` — pointer‑element tuple. CHECK:
    - `CHECK: define {{.*}} @sum_int_with_extra$unboxed(i64 {{.*}}, ptr addrspace(1) {{.*}})`
    - `CHECK-NOT: { i64, ptr addrspace(1) }` in the signature.
* `cross_spec_returns_tuple_llvm.mlir` — multi‑return all‑primitive
  result. CHECK: worker returns either `{ i64, i64 }` (LLVM packed
  struct return) or two separate scalar returns depending on what
  the LLVM lowering produces; assert no `alloca` in the worker for
  the result.

**Empirical step (the actual work).** The CHECK lines above are
templates — the precise opcodes / register names / SROA‑residue
patterns depend on what the LLVM mid‑end actually produces. The
implementer must:

1. Run `ecoc <input>.mlir -emit=llvm -enable-unboxed-agg` on each
   target input and capture the IR.
2. Verify by inspection that the worker function shows scalar
   params/results, no leftover `insertvalue`/`extractvalue`/`alloca`
   chains over the boundary struct, and (for pointer‑containing
   tuples) `ptr addrspace(1)` in the param list rather than a
   struct.
3. Pin the relevant lines as CHECK / CHECK‑NOT directives. Pay
   attention to LLVM IR's stable spelling vs. variable parts —
   prefer `{{.*}}` for register numbers and SSA names.

If step 2 reveals that the boundary structs are *not* eliminated
(e.g. SROA leaves a residual `alloca`), that's a finding for the
harness itself and may surface a real bug in the SROA‑before‑RS4GC
ordering or in `FoldExtractValuePass`'s coverage. The harness's
value is exactly catching this: 3.1 closed the "MLIR boundary is
scalar" question by build inspection; the harness closes the
"LLVM boundary is scalar after the standard opt pipeline" question
empirically.

**Allocation‑counter microbenchmark.** Plan defers if test infra
doesn't expose counters. Two observable signals exist in the
codebase: `ECO_GC_PHASE_PROFILE=1` (per‑cycle GC stderr line) and
the `eco_alloc_*` runtime call counts. Neither is currently
queryable from a test fixture, so this half stays out of scope
for §3.2 #2 — revisit if the harness's `.ll` checks turn out to
be insufficient.

**Effort.** Fixture list and draft CHECK templates: ~30 min.
Empirical capture + refining CHECK lines: ~1 hour (most of the
work). Land as one commit with 3 fixtures + any CGEN_064 / CGEN_066
note clarifying that the harness empirically validates them.

### Phase 3.3 — sret‑style ABI for aggregate results containing `!eco.value`

Phase 3.1 / 3.2 keep aggregate results carrying any `!eco.value` element
boxed (the `isAllPrimitiveAggregate` filter at
`EcoUnboxedAggCrossSpec.cpp:1020`). The 3.3 work lifts that restriction
by giving such results a dedicated **caller‑allocated outparam** (sret)
calling convention in the worker. Single change of scope: results that
contain a heap pointer become eligible; everything else (params,
all‑primitive results, all other passes) is unchanged.

#### 0. Goals and non‑goals

- **Goal.** Promote aggregate results whose element list contains at
  least one `!eco.value`, e.g. `( Int, List a )`, `{ value, rest }`,
  `Maybe Int`'s `Just a` payload. These shapes are common in compiler
  hot paths (parser → `( token, rest )`, monomorphization → record of
  state, etc.) and represent the bulk of residual boxing the current
  cross‑spec pipeline cannot eliminate.
- **Secondary goal.** Widen the `customMaxFields = 3` gate in
  `LogicalTypes.elm` to ~8. The runtime parser and flatten pass
  already tolerate arbitrary N; only the Elm‑side gate is artificial.
  Bundling this here multiplies the surface area sret unlocks
  (most record‑heavy compiler code has 4–6 fields). See §9 below.
- **Non‑goals.** Doesn't touch all‑primitive result aggregates (those
  keep the existing direct‑return path — LLVM packs them into a
  struct return that RS4GC handles fine because no field is GC‑managed).
  Doesn't touch params (already flattened to scalar args). Doesn't
  touch cons (§8.2), multi‑ctor customs, or any aggregate kind not
  already eligible. No new dialect ops.

#### 1. Why params worked but results need a different shape

Recap (from the May 2026 analysis):

- `EcoFlattenAggBoundary` rewrites aggregate params into N scalar
  params. LLVM IR has multi‑arg natively, so a `(i64, !eco.value)`
  param tuple becomes two separate LLVM args (`i64`, `ptr addrspace(1)`).
  RS4GC tracks each pointer arg individually through statepoints.
- The symmetric move for results — expanding into N `func.func`
  results — looks fine at the MLIR level, but
  `populateFuncToLLVMConversionPatterns` packs multi‑result `func.func`
  into a `!llvm.struct<>` return on the `llvm.func` because LLVM IR
  has no multi‑return. A struct return containing `ptr addrspace(1)`
  is exactly the case RS4GC's FCA‑unimplemented assertion fires on.

The asymmetry isn't about primitives vs pointers — it's about LLVM
having multi‑arg but not multi‑return. sret sidesteps both: no
struct value crosses the call boundary, and the alloca holds the
fields as scattered ptr / scalar slots that RS4GC roots normally.

#### 2. ABI shape

For each result position whose `LogicalShape` is aggregate *and*
contains at least one `!eco.value` element:

- **Drop** the position from the worker's `func.func` result list.
- **Prepend** a `!llvm.ptr` (addrspace 0; i.e. a host‑memory pointer
  into the caller's frame) to the worker's input list. Convention:
  sret outparams come first, in result‑position order, then the
  original params.
- The worker body, at every `func.return`, projects each field of
  the would‑be aggregate result and stores it to the matching slot
  in the sret outparam via per‑element GEP + store. The
  `func.return` then carries only the surviving (non‑sret) result
  operands.

Workers may mix: an all‑primitive aggregate result stays as a direct
return (existing path); a pointer‑containing aggregate result becomes
sret. The two coexist on the same function. Scalars and `!eco.value`
results (non‑aggregate) also stay direct.

A worker with sole result going to sret has `func.return` with zero
operands and a `void`‑equivalent `func.func` result list — exactly
the void‑return form LLVM already produces for procedures.

#### 3. Sret slot layout

The slot is the LLVM struct matching the aggregate's element types,
but it is only used as a typed alloca — no struct value ever passes
through a call. Field stores are at indexed GEPs:

```llvm
%slot = alloca { i64, ptr addrspace(1) }
call void @worker$unboxed(ptr %slot, i64 %arg, ...)
%field0_ptr = getelementptr ..., ptr %slot, i32 0, i32 0
%field0 = load i64, ptr %field0_ptr
%field1_ptr = getelementptr ..., ptr %slot, i32 0, i32 1
%field1 = load ptr addrspace(1), ptr %field1_ptr
```

For pointer fields, stored pointers are live‑on‑exit from the
worker — the worker writes the field after its last statepoint
(naturally enforced by storing right before `func.return`, which
has no body after it). On the caller side, the loaded
`ptr addrspace(1)` is a normal SSA value that RS4GC will track
across any subsequent statepoint via standard relocation rules.
The alloca itself is in addrspace 0 (host memory in the caller's
frame), which is not GC‑managed.

We do **not** advertise the LLVM `sret` parameter attribute — the
attribute carries TBAA / no‑capture assumptions we don't need
and that interact awkwardly with `gc-leaf-function` lowering.
A plain `ptr` argument with the same calling pattern is sufficient
and is what `eco_alloc_*` already uses for similar callee‑writes‑to‑
caller‑slot patterns.

#### 4. Implementation steps

The change is mostly localised to `EcoUnboxedAggCrossSpec.cpp`. No
changes to escape analysis, flatten, or LLVM lowering passes are
required — sret slots are plain `!llvm.ptr` params and plain
GEP/load/store inside function bodies, which everything downstream
already handles.

**A. Lift the all‑primitive guard, gated per result.**

Replace the unconditional demotion at
`EcoUnboxedAggCrossSpec.cpp:1020-1024` with a per‑result classification:

- All‑primitive aggregate → **direct‑return** (existing path).
- Aggregate with ≥1 `!eco.value` element → **sret** (new path).
- Aggregate with otherwise‑ineligible shape (cons, etc.) → demote.

Carry the per‑result ABI choice on `Candidate` as a new
`SmallVector<ResultAbi, 4> resultAbis` where
`ResultAbi ∈ {Direct, Sret, Boxed}`. The Boxed entries are the
demoted ones; everything else is eligible.

**B. Extend `buildWorkerType`.**

Build the new signature as: sret pointers first (one per Sret
result), then the existing inputs; outputs are the original
results minus the Sret positions.

```cpp
SmallVector<Type, 8> inputs;
for (auto &s : sretResults) inputs.push_back(llvmPtrTy);
for (auto &s : paramShapes) inputs.push_back(s.asWorkerType(ctx));

SmallVector<Type, 4> outputs;
for (unsigned i = 0; i < originalResults.size(); ++i) {
    switch (resultAbis[i]) {
    case ResultAbi::Direct:
        outputs.push_back(resultShapes[i].isAggregate()
                          ? resultShapes[i].asWorkerType(ctx)
                          : originalResults[i]);
        break;
    case ResultAbi::Sret:
        /* dropped from outputs */
        break;
    case ResultAbi::Boxed:
        outputs.push_back(originalResults[i]);
        break;
    }
}
```

`CalleeRedirect` gains a parallel `sretPositions` vector so call‑site
rewriting (cross‑worker calls and the wrapper's call) knows which
inputs are sret slots and which are real params.

**C. `cloneAsWorker` result‑side rewriting for Sret positions.**

For each `func.return` in the worker body, for each result position
flagged Sret:

1. The operand is currently an aggregate SSA value (after Phase 3.1
   #4's construct→make rewrite). Walk its element types.
2. For each element index k, emit `eco.project.*` on the aggregate
   (or, if the aggregate was just produced by an `eco.make.*`,
   SROA will fold this — same shortcut as 3.1).
3. Build a GEP+store pair into the leading sret input.
4. Drop the operand from the return list.

The leading sret block‑arg is added at worker entry alongside the
existing parameter block‑args, with type `!llvm.ptr`.

**D. `replaceBodyWithWrapper` allocates the slot.**

For each Sret result position:

1. At wrapper entry, `llvm.alloca` (or `memref.alloca` lowered the
   same way) a struct matching the aggregate's element MLIR types.
2. Prepend the slot pointer to the worker call's operand list.
3. After the worker call, GEP + load each element from the slot,
   feed them to `eco.make.<kind>` to rebuild the aggregate, then
   feed that into `eco.to_heap` exactly as today (the `boxedTy`,
   `unboxed_bitmap`, `tag`, `head_kind` attributes are computed
   the same way as the existing Direct path).

The wrapper's outer `func.return` still produces the original
boxed `!eco.value` — the wrapper's ABI is preserved.

**E. Inter‑worker call rewriting.**

Inside `cloneAsWorker`'s redirect loop, when a redirected callee
has Sret result positions:

1. Allocate slots for each Sret result at the call site.
2. Build the new operand list: sret slots first, then bridged
   aggregate / scalar operands.
3. After the call, load each Sret field, `eco.make.*` the
   aggregate, and replace uses of the original call's result.

Self‑recursion uses the same path via `selfRedirect`.

**F. Use‑check extension.**

`resultPositionHasAggregateProducer` (the result‑side use check)
needs no behavioural change — it already accepts call‑result
passthrough, block‑arg passthrough, `from_heap`, and matching
`construct.*` ops. With Sret returns the *worker* sees the
aggregate as the operand of `func.return`, which the new step C
handles. The eligibility analysis is unchanged.

**G. Cross‑SCC interaction.**

Phase 3.2 #1's SCC fixpoint runs over tentative shapes and uses
`aggregateShapesMatch` for slot compatibility. Sret vs Direct is a
*lowering* decision derived from the shape's element types, not a
shape distinction — both ABIs share the same `LogicalShape`. SCC
admission therefore works without modification: an SCC member
producing `(i64, !eco.value)` via Sret can flow into another
member's matching slot regardless of how the receiver chose to
lower the result, because the *aggregate value* the caller sees
after load is identical to the aggregate value the Direct path
would have returned.

#### 5. RS4GC interaction (the actual safety argument)

Worker side. Between the last statepoint inside the worker and the
field stores there must be no further statepoint, or else the stored
pointer could be moved by GC between store and return. This is
enforced naturally: `func.return`'s terminator semantics leave no
body after it, and the stores immediately precede the return.
SROA collapses any intermediate `make.* / project.*` chain, so the
lowered IR is `<compute> ; store ; store ; ret void`.

Caller side. The alloca is in addrspace 0 and is not GC‑managed.
The loaded `ptr addrspace(1)` becomes an SSA value live across any
subsequent statepoint (typically the `eco.to_heap` in the wrapper);
RS4GC handles that via standard SSA relocation. No struct‑typed
value ever passes through a call.

No new GC‑leaf functions, no new safepoint markers, no statepoint
bundle changes.

#### 6. EcoFlattenAggBoundary interaction

None. The flatten pass walks the function signature looking for
aggregate types (`Tuple2/3Type`, `RecordType`, `CustomType`). Sret
adds `!llvm.ptr` params and drops aggregate result entries, so
after 3.3 emits the worker its signature has *no* aggregate types
left at the boundary — flatten sees nothing to do and is a no‑op
on Sret workers, exactly as desired.

Equivalently: the order of `cross-spec → flatten` still holds.
Cross‑spec already emits aggregate types in worker boundaries; for
Sret results, the aggregate vanishes from the result list and is
replaced by a `ptr` param. Flatten then handles any remaining
aggregate *params* the same way it does today.

#### 7. Tests

Codegen fixtures (gated behind `-enable-unboxed-agg`):

- `cross_spec_sret_tuple2_pointer.mlir` — `tuple2<i64, !eco.value>`
  return. Worker becomes `void @f$unboxed(ptr, i64, ...)`; wrapper
  allocates the slot, loads two fields, rebuilds, calls `to_heap`.
- `cross_spec_sret_record_mixed.mlir` — record with mixed primitive
  and `!eco.value` fields.
- `cross_spec_sret_chain.mlir` — `f → g`, both returning Sret
  aggregates; intra‑worker `f$unboxed` calls `g$unboxed` directly
  with an alloca'd slot, no wrapper round‑trip.
- `cross_spec_sret_scc.mlir` — Phase 3.2 #1 SCC with a Sret result
  on one of the members; verifies SCC admission works through the
  Sret path.

LLVM‑IR harness fixtures (per Phase 3.2 #2 conventions):

- `cross_spec_sret_tuple2_pointer_llvm.mlir` — assert
  `define void @f$unboxed(ptr {{.*}}, i64 {{.*}})`, two
  `store` instructions, no `{ i64, ptr addrspace(1) }` struct
  return anywhere.

Elm‑source fixture:

- `CrossSpecReturnPointerTupleTest.elm` — a function returning
  `( Int, List Int )` used in a `Debug.log` to force end‑to‑end
  evaluation. Positive `// CHECK: result: …` plus
  `// CHECK: @<name>$unboxed`.

#### 8. Invariants

- **CGEN_064** (extend): worker signatures may carry leading
  `!llvm.ptr` sret outparams, one per aggregate result whose
  shape contains an `!eco.value` element. Sret outparams are
  ordered before any original parameters. Wrappers allocate the
  slot, pass it to the worker, and rebuild the aggregate from
  the slot fields before re‑boxing via `eco.to_heap`.
- **CGEN_066** (extend): `EcoFlattenAggBoundary` is the sole
  introducer of multi‑arg / multi‑result `func.func` signatures
  *for aggregate boundary types*; sret outparam introduction by
  `EcoUnboxedAggCrossSpec` is the only other source of new
  `func.func` parameters, and those parameters are `!llvm.ptr`,
  not aggregate types.
- **REP_AGG_001** (extend): aggregate types may appear at function
  *boundary* in Eco IR after cross‑spec but before flatten /
  sret rewriting; after both passes, aggregate types appear only
  inside function bodies. Sret outparams use `!llvm.ptr`, never
  an aggregate type.
- New **CGEN_067**: a worker function with an sret outparam must
  store every field of the would‑be aggregate result via
  per‑element GEP + store immediately before its `func.return`,
  with no intervening statepoint or GC‑may‑call op. Verified by
  a small invariant‑test walk over `kUnboxedWorkerAttr` funcs.

#### 9. Widening `customMaxFields` (additional scope)

Orthogonal one‑line change bundled into this phase because it
multiplies the surface area sret unlocks. `customMaxFields` at
`compiler/src/Compiler/Generate/MLIR/LogicalTypes.elm:60` is
currently **3**: a single‑constructor `MCustom` with 4+ fields
gets `LValue` instead of `LCustom`, so it never enters cross‑spec
at all. The same cap effectively bounds records too, since records
flow through the same encoding path.

Bumping the cap to **8** is one constant edit:

```elm
customMaxFields : Int
customMaxFields =
    8
```

**Impact.** Stage 7 is full of records (closure info, parse state,
module metadata) and 4–6‑field customs are common. Plausibly the
single highest‑leverage knob in the codebase — could roughly
double the savings on workloads dominated by record‑heavy
compiler code. With Phase 3.3 sret in place, the doubling
applies to both param and result aggregates, including those
carrying `!eco.value` elements.

**Risk.** The C++ side already tolerates arbitrary N: the cross‑
spec parser asserts only on `parts.size` mismatch (record:
`parts.size() != 2 + n` at `EcoUnboxedAggCrossSpec.cpp:188`;
custom: `parts.size() != 3 + n` at line 200), and `EcoFlattenAggBoundary`'s
slot decomposition is O(N) over element arrays. The heap layout's
hard limit is 24 fields (`Eco_CustomConstructOp` description in
`Ops.td`), well above any reasonable Elm shape. Only the Elm
gate is artificial.

**Validation.** Before flipping the constant, instrument
`monoTypeToLogical` (or just `grep` the post‑Stage 5 MLIR) for
the distribution of field counts of single‑ctor customs and
records in real Elm code (Stage 7 self‑compile gives a
representative sample). If the histogram has a long tail past
8, pick a cap matching the 95th percentile rather than 8.

**Test impact.** Existing cross‑spec fixtures with ≤3‑field
customs / records continue to pass unchanged. Add one new
codegen fixture covering a 6‑field record and a 5‑field
single‑ctor custom (`cross_spec_wide_record.mlir`,
`cross_spec_wide_custom.mlir`) and one Elm‑source fixture
exercising a real ≥4‑field record (`CrossSpecWideRecordTest.elm`).

#### 10. Implementation staging

Five reviewable commits:

1. **`ResultAbi` classification + signature changes.** Add the
   per‑result ABI vector to `Candidate`, replace the all‑primitive
   guard, extend `buildWorkerType` and `CalleeRedirect` to carry
   sret positions. No body rewriting yet — workers with would‑be
   Sret results stay disqualified at the end of Step A so this
   commit is a pure refactor with no behavioural change.
2. **Worker body rewriting + wrapper slot allocation.** Implement
   steps C and D. Land the first fixture
   (`cross_spec_sret_tuple2_pointer.mlir`) and confirm the LLVM
   harness sibling.
3. **Inter‑worker calls + SCC interaction.** Implement step E,
   wire through Phase 3.2 #1's SCC fixpoint, add the chain and
   SCC fixtures. Re‑run stress and E2E.
4. **Elm‑source fixture + invariant updates.** Add
   `CrossSpecReturnPointerTupleTest.elm`, amend CGEN_064 /
   CGEN_066 / REP_AGG_001, add new CGEN_067 and its invariant
   test. Land any harness updates.
5. **Widen `customMaxFields` from 3 to 8.** One‑line edit in
   `LogicalTypes.elm`, plus the wide‑record / wide‑custom
   codegen fixtures and the Elm‑source wide‑record fixture
   from §9. Run heap‑profile ON vs OFF before and after to
   confirm the alloc‑bucket histogram shifts as expected.
   Lands last so the empirical impact can be attributed
   cleanly — the sret work in commits 1–4 should produce a
   measurable delta on its own first, then commit 5 doubles
   it (or doesn't — that's the experiment).

Estimated effort: ~400–550 LOC C++ + ~150 LOC fixtures over
commits 1–4, plus ~10 LOC + ~80 LOC fixtures for commit 5.
The Step 1 refactor is the largest mechanical change; Step 2
is the trickiest because it touches every `func.return` in
eligible workers; Steps 3, 4, and 5 are short.

#### 11. Open questions

- **Do we want the LLVM `sret` attribute?** Skipped above for
  TBAA simplicity. Adding it later is a non‑breaking change: the
  ABI is identical, and downstream consumers (clang, LLVM mid‑end)
  only treat the attribute as an optimisation hint. Decide if /
  when profiling shows the load/store pair isn't being optimised
  away in the caller.
- **Should pure all‑primitive results also move to sret for
  uniformity?** No (decided here). The Direct path already works
  cleanly for all‑primitive returns and removing it would force
  a needless alloca + load on every call. Keep both paths.

### Phase 3.4 — Join and loop‑carry shapes for aggregate eligibility

Phase 3.1–3.3 require every aggregate flow to be a *straight‑line*
producer/consumer chain: the use‑check at
`EcoUnboxedAggCrossSpec.cpp:allUsesAreProjectionsOrCallsToEligible`
and the result‑side check at `resultPositionHasAggregateProducer`
both reject any value reached through `arith.select`, `eco.case`,
or `eco.joinpoint`. Real Elm code routinely produces such shapes —
`if … then (a, b) else (c, d)` for joins, `let go acc = case … of …`
tail loops compiled to `eco.joinpoint` for loop carries — and every
such pattern currently demotes to Boxed.

Phase 3.4 lifts both gates. Two independent extensions land
together because they share a recursive walk through region‑bearing
ops and a chain‑rewrite step that retypes intermediate
`arith.select` / `eco.case` / `eco.joinpoint` results once the
leaves of the chain have been rewritten to aggregate producers.

**Pipeline placement note.** Cross‑spec runs in
`buildEcoToEcoPipeline` *before* `JoinpointNormalization` /
`EcoControlFlowToSCFPass`, so `scf.if` / `scf.while` / `scf.for`
do not yet exist in the IR when Phase 3.4 fires. The Eco‑dialect
equivalents `eco.case` (with `eco.yield` terminators in its
alternative regions) and `eco.joinpoint` (with `eco.jump` carrying
the iter‑args and `eco.return` terminating the function) are the
actual targets. After the SCF lowering, these patterns are gone;
Phase 3.4 must catch them at the Eco‑dialect stage.

#### 0. Goals and non‑goals

- **Goal #1.** Extend the result‑side producer check to accept
  `arith.select` and `eco.case` join points: an aggregate operand
  of `func.return` reached through one of these ops is accepted
  iff every leaf of the join chain (every `arith.select` arm; every
  `eco.yield` operand at the matching position across all `eco.case`
  alternative regions) is itself an accepted producer
  (construct.*, from_heap, eligible/same‑SCC call, block‑arg
  passthrough — the existing leaf set). `eco.case` is the
  cross‑spec‑time analog of `scf.if`; an `eco.case` whose
  *scrutinee* is an aggregate continues to be classified as
  escaping (Q4 unchanged) — Phase 3.4 only relaxes the *result*
  side, where each alternative region's `eco.yield` produces the
  aggregate.
- **Goal #2.** Extend the param use‑check to accept `eco.joinpoint`
  loop‑carry uses: an aggregate block‑arg that flows into a
  joinpoint's body region as an iter‑arg at position k is accepted
  iff (a) every use of the joinpoint's body block‑arg at k is
  itself accepted, (b) every `eco.jump` op carrying iter‑args
  passes an accepted producer at position k, and (c) the
  joinpoint's continuation region's uses (if any aggregate flows
  there) are likewise accepted. The joinpoint op itself has no SSA
  results — the aggregate either exits via `eco.return` (handled
  by the result‑side check) or stays scoped to the joinpoint body.
- **Non‑goals.** Doesn't widen the *leaf* producer set (no
  `arith.select` of two `eco.allocate_*` results; the leaves stay
  the existing five kinds). Doesn't introduce new dialect ops.
  Doesn't lift Q4's `eco.case`‑as‑scrutinee restriction. Doesn't
  change the sret ABI from Phase 3.3 — Sret results reached
  through a join are admissible because the join's aggregate
  result is what gets stored to the slot.

#### 1. `arith.select` / `eco.case` as result producers

The result‑side check at `resultPositionHasAggregateProducer`
currently walks one operand back to a defining op and accepts a
fixed set of kinds. Phase 3.4 #1 makes that walk recursive: the
defining op may be a join (`arith.select`, `eco.case`), in which
case every arm / every alternative's matching `eco.yield` operand
must itself satisfy the same recursive check.

**A. Recursive acceptance.**

```cpp
static bool isAcceptedAggregateProducer(
        Value v, const LogicalShape &expectedShape,
        ArrayRef<LogicalShape> ownParamShapes, ...,
        unsigned depthBudget = 16);
```

The function consolidates today's inline checks (block‑arg, construct.*,
from_heap, eligible/same‑SCC call) into a single helper that can be
called recursively from join arms. The depth budget is set to **16**
— Real Elm rarely nests joins past 3–4 levels and 16 is comfortably
generous; if exceeded, the value is rejected.

For `arith.select %cond, %t, %f`: both `%t` and `%f` must satisfy
`isAcceptedAggregateProducer` with the same `expectedShape` and
depth − 1.

For `eco.case %scrutinee [tags] -> (T) { … eco.yield %y0 }, { … eco.yield %y1 }, …`:
walk every alternative region, find each terminating `eco.yield`, and
recurse on the yield operand at the same position as the value of
interest. A multi‑result `eco.case` is handled by indexing into the
yield operand list. Q4 still applies to the *scrutinee*: an aggregate
flowing into `eco.case` as `%scrutinee` continues to demote — this
extension touches only the case's *result*, which is what the yields
produce.

**B. Chain rewrite during `cloneAsWorker`.**

Today's first pass over `func.return` operands at
`EcoUnboxedAggCrossSpec.cpp:986‑995` rewrites a leaf `construct.*`
into the matching `make.*` and lets RAUW propagate the new aggregate
type to the immediate consumer (the return op). With joins, the
consumer chain is longer — `construct → arith.select → return`
or `construct → eco.yield → eco.case → return` — and RAUW alone
leaves the join's result type as `!eco.value` while its operand
is now aggregate‑typed. SSA verification fails.

Fix: after rewriting all leaves on a return‑reachable join chain,
walk the chain bottom‑up and re‑type each intermediate result.
`arith.select` retyping is just an in‑place type swap of the result;
`eco.case` retyping requires updating the op's result types AND
verifying that every matching `eco.yield` operand type aligns (if not
already aggregate, that alternative was rejected by the recursive
acceptance check and the whole join would have been demoted). A
helper:

```cpp
static void retypeJoinChain(Value root, Type aggTy);
```

walks consumers of `root`, retypes `arith.select` / `eco.case`
results along the way, and stops at the boundary (the `func.return`).

**C. Edge case: mixed‑leaf joins.**

If one arm of a join has an accepted leaf but the other arm doesn't
(e.g. one alternative yields a same‑SCC call result, the other
yields an `eco.jump`‑derived value whose joinpoint carry hasn't
been promoted yet), the join is rejected. The fixpoint then handles
the cascade: the join's return demotes, possibly demoting the
function's result shape, which propagates through any cross‑spec
callers.

**D. Fixture sketch.**

`test/codegen/cross_spec_join_select_tuple.mlir`:

```mlir
// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s

module {
  func.func @pick(%cond: i1, %a: i64, %b: i64) -> !eco.value
      attributes {
          eco.logical_param_types = ["i1", "i64", "i64"],
          eco.logical_result_types = ["tuple2:i:i"]
      } {
    %z = arith.constant 0 : i64
    %x = eco.construct.tuple2 %a, %z : i64, i64 -> !eco.value
    %y = eco.construct.tuple2 %z, %b : i64, i64 -> !eco.value
    %r = arith.select %cond, %x, %y : !eco.value
    return %r : !eco.value
  }
}

// CHECK: llvm.func @pick$unboxed
// CHECK-NOT: eco.construct.tuple2
```

Parallel `cross_spec_join_eco_case_tuple.mlir` exercises the
`eco.case` path with two alternative regions each ending in
`eco.yield`.

`CrossSpecConditionalReturnTest.elm`:

```elm
pick : Bool -> Int -> Int -> ( Int, Int )
pick c a b =
    if c then ( a, 0 ) else ( 0, b )
```

#### 2. `eco.joinpoint` loop‑carry aggregates

An `eco.joinpoint N(%acc: !eco.value, …) result_types […] { … }
continuation { … }` defines a local loop head whose body region's
entry block‑args are the iter‑args. Recursion happens via
`eco.jump N(%acc', …)` ops in the body. The joinpoint op itself
has no SSA results — values that escape the loop do so via
`eco.return` (function exit) or by flowing into the continuation
region. Phase 3.3 demotes any aggregate block‑arg that reaches
`eco.joinpoint` because the use‑check rejects it. Phase 3.4 #2
lifts that by walking into both regions and verifying the
iter‑arg slot's uses across the loop.

**A. Loop‑carry slot mapping.**

For `eco.joinpoint`:
* The k‑th body‑region block‑arg is the iter‑arg slot k. There is
  no separate "init operand" on the joinpoint op — the first
  iteration's iter‑args come from the SSA values defined just
  before the joinpoint and reached via a fall‑through `eco.jump`.
* Every `eco.jump N(...)` inside the body carries fresh iter‑arg
  values at position k for the next iteration. There may be
  multiple `eco.jump`s scattered through the body (one per
  loop‑restart branch).
* Control exits the loop via `eco.return` (function exit) or by
  falling through to the continuation region. The continuation
  region's block‑args (if any) are the post‑loop binding; aggregate
  flows there are checked the same way as block‑arg uses.

For all paths to share an aggregate shape, every `eco.jump`'s k‑th
operand AND the body block‑arg at k must agree.

**B. Extended use‑check.**

When the use‑check sees `arg` flowing into an `eco.jump` at operand
position k whose target joinpoint has its k‑th body block‑arg
matching `paramShape`, accept iff:

1. The body region's block‑arg at position k has all‑accepted uses
   (recursive call to `allUsesAreProjectionsOrCallsToEligible` using
   the same `paramShape`).
2. Every other `eco.jump` to the same joinpoint passes an accepted
   producer at position k (recursive call to
   `isAcceptedAggregateProducer` from Phase 3.4 #1).
3. If the joinpoint's continuation region binds the k‑th iter‑arg
   (continuation block‑args correspond positionally to iter‑args),
   that continuation block‑arg's uses are likewise all‑accepted.

Step 1 makes this a *bi‑directional* check on the body slot:
aggregate flows in via the iter‑arg and back out via the next
`eco.jump`'s operand; both flows must be admissible. The existing
`allUsesAreProjectionsOrCallsToEligible` already handles
return‑forwarding for block‑args; continuation block‑args use the
same code path.

**C. Chain rewrite during `cloneAsWorker`.**

When iter‑arg slot k promotes:
1. Retype the body region's block‑arg at k from `!eco.value` to the
   aggregate type.
2. Retype the matching continuation region block‑arg (if any).
3. Retype every `eco.jump`'s k‑th operand. If the original operand
   was `!eco.value`, insert an `eco.from_heap` bridge at each jump
   site to feed the aggregate.
4. Verify (by re‑running the use‑check post‑rewrite) that the body
   block‑arg's downstream uses are aggregate‑compatible (they will
   be, by step 1's acceptance check, but a debug assertion costs
   nothing).

The init bridging in step 3 unconditionally inserts an
`eco.from_heap`; downstream canonicalisation collapses the
`eco.from_heap` whenever its operand is already aggregate‑typed
(e.g. when the jump's operand came from another promoted slot).
Avoids special‑casing in the rewriter at the cost of trivial dead
bridges the canonicaliser sweeps up.

**D. Recursion guard.**

The recursive walk through joinpoint regions could theoretically
nest deeply (nested loops). In practice Elm compiles to ≤ 2–3
levels of nested `eco.joinpoint` (inner / outer loops in parsers,
monomorphisation worklists). The Phase 3.4 #1 depth budget of 16
covers loop nesting too — the same counter decrements across both
join recursion and joinpoint recursion to give a single cost
ceiling.

**E. Fixture sketch.**

`test/codegen/cross_spec_joinpoint_loop_carry.mlir`:

```mlir
// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s

module {
  func.func @sum_pair_to_zero(%t: !eco.value) -> i64
      attributes {
          eco.logical_param_types = ["tuple2:i:i"],
          eco.logical_result_types = ["i64"]
      } {
    %zero = arith.constant 0 : i64
    eco.joinpoint 0(%acc: !eco.value) result_types [i64] {
      %a = eco.project.tuple2 %acc[0] : !eco.value -> i64
      %done = arith.cmpi eq, %a, %zero : i64
      cf.cond_br %done, ^exit, ^recurse
    ^exit:
      %b = eco.project.tuple2 %acc[1] : !eco.value -> i64
      eco.return %b : i64
    ^recurse:
      %one = arith.constant 1 : i64
      %am1 = arith.subi %a, %one : i64
      %b = eco.project.tuple2 %acc[1] : !eco.value -> i64
      %next = eco.construct.tuple2 %am1, %b : i64, i64 -> !eco.value
      eco.jump 0(%next : !eco.value)
    } continuation {
    }
    // Initial jump into the joinpoint:
    eco.jump 0(%t : !eco.value)
  }
}

// Loop carry was promoted — no eco.construct.tuple2 / eco.allocate_*
// inside the worker:
// CHECK: llvm.func @sum_pair_to_zero$unboxed
// CHECK-NOT: llvm.call @eco_alloc_tuple2
```

Elm‑source fixture `CrossSpecLoopCarryTest.elm` runs the construct
end‑to‑end through real Elm tail recursion that lowers to
`eco.joinpoint`.

**F. Post‑lowering invariance check.**

Once the IR is lowered to `scf.while` (via
`EcoControlFlowToSCFPass`), the aggregate‑typed iter‑args remain
intact — `scf.while` accepts any element type. SROA later
scalarises the loop carry's struct value. Phase 3.4 does not
emit any `scf.*` ops directly; all rewriting happens at the
Eco‑dialect level.

#### 3. Implementation staging

Four reviewable commits:

1. **Extract `isAcceptedAggregateProducer` helper.** Pure refactor:
   consolidate the existing leaf‑acceptance logic from
   `resultPositionHasAggregateProducer` into a standalone
   recursive‑capable helper with a depth budget. No new accepted
   kinds yet; behaviour unchanged. Lets later commits add cases
   in one place.
2. **`arith.select` / `eco.case` join support.** Extend the helper
   with the join‑recursion cases and add the `retypeJoinChain`
   bottom‑up rewriter to `cloneAsWorker`. Land the
   `cross_spec_join_select_tuple.mlir` and
   `cross_spec_join_eco_case_tuple.mlir` fixtures plus the
   Elm‑source `CrossSpecConditionalReturnTest.elm`.
3. **`eco.joinpoint` loop‑carry support — DEFERRED.** Extend
   `allUsesAreProjectionsOrCallsToEligible` with the joinpoint
   recursion (steps B.1–B.3 above), add the region‑aware retyping
   in `cloneAsWorker`. Land the
   `cross_spec_joinpoint_loop_carry.mlir` fixture plus the
   Elm‑source `CrossSpecLoopCarryTest.elm`. *Not implemented in
   the initial Phase 3.4 landing — the joinpoint use‑check needs
   region traversal through both the joinpoint body and every
   `eco.jump` site, plus widening of `eco.jump`'s variadic args.
   Re‑opens when there's a profiled workload showing loop‑carried
   aggregates dominating.*
4. **Invariant updates.** Amend CGEN_064 with the join /
   loop‑carry clauses (the use‑check accepts a broader set; the
   leaf producer set is unchanged). REP_AGG_001's wording about
   "intra‑function values" already covers the lifted SSA chains.

Estimated effort: ~120 LOC for #1 + #2, ~180 LOC for #3, ~30 LOC
for #4 invariant text. Total ~330 LOC C++ + ~200 LOC fixtures.

#### 4. Composition with earlier phases

- **Phase 3.2 #1 SCC.** Loop‑carry slots inside an SCC member
  participate in the inner fixpoint exactly like straight‑line
  slots; the tentative `paramShapes` / `resultShapes` are unchanged
  in shape, only the *use‑check* now traces through additional ops.
  No SCC‑level changes required.
- **Phase 3.3 Sret.** A join chain whose root flows into a
  Sret‑classified return is accepted because the chain's final
  type is aggregate; the sret store happens on the aggregate value
  produced by the join's final `arith.select` / `eco.case`, with
  no special handling needed. CGEN_067's "store‑before‑return,
  no intervening statepoint" invariant holds because the join ops
  don't introduce statepoints (`arith.select` is `Pure`;
  `eco.case` alternative regions don't carry safepoints at this
  stage of the pipeline — those are inserted later by `EcoGCPrepare`).
- **EcoFlattenAggBoundary.** The flatten pass continues to work
  on function *boundaries* only. Intra‑function joins and loop
  carries it ignores; their aggregate SSA values get scalarised
  by SROA later (`addEcoGCPipeline` runs SROA before RS4GC).

#### 5. Resolved design decisions

The three open questions raised during planning are resolved as
follows; the resolutions are folded into the relevant sections
above:

- **Eco‑dialect join shapes are in scope.** The recursive
  acceptance helper walks both `arith.select` and `eco.case`
  (with its `eco.yield` terminators), and the loop‑carry check
  walks `eco.joinpoint` / `eco.jump`. `scf.if` / `scf.while` /
  `scf.for` are post‑lowering forms that do not exist at
  cross‑spec time and are therefore not targets of Phase 3.4
  (see Pipeline placement note above).
- **Depth budget = 16.** Pinned in §1.A and shared across both
  join recursion (§1) and joinpoint recursion (§2). Real Elm
  rarely nests joins past 3–4 levels, so 16 is comfortably
  generous; revisit only if a benchmark turns up a regression.
- **Always bridge init values with `eco.from_heap`.** §2.C
  unconditionally inserts an `eco.from_heap` at every `eco.jump`
  whose original operand was `!eco.value`. Downstream
  canonicalisation collapses the bridge whenever the source is
  already aggregate‑typed (e.g. another promoted slot). Avoids
  special‑casing in the rewriter at the cost of trivial dead
  bridges the canonicaliser sweeps up.

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

## 8. Later follow‑ups (data‑gated)

Potential extensions to the data‑aggregate unboxing path that are
gated on benchmark or profiling data the 3.1 / 3.2 work doesn't yet
produce. Each item requires its own design pass before it's plan‑
ready — the sketches here are placeholders for future memos, not
approved scope.

Two prerequisites are common to all three:

- A 3.1 / 3.2 benchmarking pass: allocation counter delta between
  flag‑off and flag‑on for representative pipelines (made possible
  by §3.2 #2's LLVM‑IR validation harness if the optional counter
  half lands there).
- A profile of real Elm code: which aggregate shapes actually show
  up (Custom field‑count distribution, record sizes, frequency of
  `head :: rest` destructure patterns).

Without that data, picking the wrong ABI for results‑with‑pointers
or implementing speculative cons‑cell specialisation risks throwaway
work. Each item below stays here until the relevant data justifies
elaboration.

### 8.1 Aggregate results carrying `!eco.value` elements — promoted to Phase 3.3

Originally a deferred ABI question with three competing options
(sret, LLVM‑dialect multi‑return, flatten‑on‑results). The May 2026
analysis showed that the multi‑return and flatten‑on‑results variants
both reintroduce a `!llvm.struct<>` return containing `ptr addrspace(1)`,
which hits RS4GC's FCA‑unimplemented assertion. Only the sret variant
avoids the GC interaction.

The sret design is now spec'd as **Phase 3.3** above. See there for
the worker ABI, slot layout, RS4GC argument, and implementation
staging.

### 8.2 Cons cell specialisation

Phase 3.1 encodes `LCons` in attributes but cross‑spec maps it to
`AggKind::None` (Q4). Resolution forks on profiling data:

- **Implement** cons cell specialisation if real Elm code shows
  enough single non‑empty `head :: rest` destructure patterns to
  justify it. Design unspecified — would need to settle how the
  recursive tail interacts with the value‑level `!eco.cons` type,
  what ops admit `!eco.cons` operands, and how the projection
  lowering handles the boxed tail.
- **Remove** `LCons` from the encoder if it remains unused after
  3.1 / 3.2 stabilise.

### 8.3 Relaxing other conservative guards

Catch‑all bucket for tightening eligibility once 3.2 is stable.
Each sub‑item needs its own elaboration before implementation:

- **Higher‑arity customs (> `customMaxFields`)**: the heap layout's
  hard limit is 24 fields with typed slots (`Eco_CustomConstructOp`
  description in `Ops.td`). Picking a new `customMaxFields` value
  is a profiling decision.
- **Records beyond the current size cap**: identify the cap, the
  bottleneck it's defending against, and the data justifying a
  raise.
- **Tail‑recursive scaffolding patterns**: `scf.while` with
  aggregate loop carries currently demoted by the use check.
  Lifting this requires walking into the loop body's nested region
  to check the aggregate's actual uses inside — not sketched yet.
