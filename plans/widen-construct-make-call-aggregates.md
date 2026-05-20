# Widen construct.* / make.* / eco.call to Accept Aggregate Operands

## 0. Goal

Lift the `Eco_AnyValue` operand-type restriction on every position that today
rejects aggregate-typed SSA values, so that the cross-spec optimisation
(`plans/wrapper-fca-fix.md`) can keep its win when an aggregate-promoted call
result flows into a "non-friendly" position. Concretely the positions are:

- `eco.construct.tuple2 / tuple3 / record / custom`: field operands.
- `eco.construct.list`: head operand (tail stays boxed by definition).
- `eco.make.tuple2 / tuple3 / record / custom`: operands.
- `eco.make.cons`: head operand.
- `eco.call`: operand list (results stay `Eco_AnyValue` — the only `eco.call`
  paths that survive cross-spec target a non-eligible/closure callee whose
  ABI is boxed).

After this plan, the verifier accepts aggregate operands at each of those
positions, and the Eco → LLVM lowering handles them per-position:

- `construct.*` (heap path): boxes the inner aggregate to `!eco.value`
  and stores its HPointer in the heap slot. The heap layout reserves one
  64-bit slot per field, so the inner aggregate has to live as its own
  heap object regardless — there is no shape that avoids the inner
  allocation here.
- `make.*` (SSA path): **nests the inner aggregate directly** into the
  outer FCA via `insertvalue` when the inner contains no
  `ptr addrspace(1)` (pure-primitive inner). Falls back to boxing via
  `eco.to_heap` only when the inner does contain a GC pointer, because
  nested FCAs with `ptr<1>` inside trip RS4GC's "support for FCA
  unimplemented" path and the current strip-aggregates code at
  safepoints only handles one level of FCA.
- `eco.call`: boxes the inner aggregate. The `eco.call` sites that
  survive cross-spec target a boxed-ABI callee (closure / PAP /
  foreign), so every operand has to be `!eco.value` going into the call.

Boxed slots' bitmap entries stay kind=0 (boxed HPointer); the heap
layout, GC scan, and `eco.project.*` consumers are unchanged. The fuller
story — recursive cross-spec ABI promotion + recursive strip-aggregates,
so even GC-pointer-inner `make.*` cases can stay un-boxed — is captured
as Phase 2 (§9).

This unblocks the eco-compiler self-compile (Stage 6 of the bootstrap)
which today crashes the post-cross-spec verifier on every nested-aggregate
shape the eco-compiler emits.

## 1. Background — what's broken

`plans/wrapper-fca-fix.md`'s Chunk 4 lifted the all-primitive gate on
`eco.return` so that cross-spec admits mixed-element aggregate results.
With the gate down, callees whose result type is e.g.
`!eco.record<i64, !eco.value>` get promoted to a Direct or Sret ABI: their
worker returns the aggregate; the caller's worker-body call rewriter
substitutes the aggregate-typed call result into every use site of the
former boxed `!eco.value` result.

If a use site is "friendly" (`eco.project.*`, the function's
`func.return`/`eco.return` at a matching result position, or another
eligible-callee call site) the rewrite is sound. If it's "non-friendly"
— a `construct.tuple2` field operand, a `make.record` operand, an
`eco.call` operand to a closure / PAP / non-eligible callee — the verifier
rejects the aggregate-typed value because each of those operands is
declared `Eco_AnyValue` (= `!eco.value` or a primitive scalar). The
pre-Chunk-4 gate kept those rare in practice; the gate lift exposes them
everywhere the eco-compiler builds nested aggregates (which is to say,
essentially every record-returning Elm function in the front-end).

The verifier diagnostics observed on the eco-compiler MLIR after the
wrapper-fca-fix plan landed:

- `'eco.construct.record' op operand #3 must be variadic of eco value or
  primitive, but got '!eco.record<i64, !eco.value>'`
- `'eco.construct.tuple2' op operand #1 must be eco value or primitive,
  but got '!eco.tuple2<!eco.value, !eco.value>'`
- `'eco.make.record' op operand #0 must be variadic of eco value or
  primitive, but got '!eco.record<i64, i64, !eco.value, ...>'`
- `'eco.call' op operand #1 must be variadic of eco value or primitive,
  but got '!eco.tuple2<!eco.value, !eco.value>'`
- (cascade) `'eco.from_heap' op operand #0 must be eco.value, but got
  '!llvm.ptr'` — this disappears once the verifier no longer bails
  mid-conversion on the construct/make errors.

## 2. Why "implicit box" is the only sensible semantics

A heap-resident aggregate field is a single 64-bit slot
(`Tuple2.a` / `Record.fields[k]` / `Custom.fields[k]`); a value-aggregate
field is a single LLVM struct element. Either way an inner aggregate
doesn't fit inline. The choices are:

1. **Implicit box** — at lowering time, box the inner aggregate to
   `!eco.value` and store its HPointer in the slot. The bitmap stays
   kind=0 (boxed). GC scan, projection, and the wrapper's re-box pipeline
   are unchanged.
2. **Nested SSA aggregate** — allow `make.tuple2 %inner_agg, %x` to
   produce an LLVM `struct<(struct<...>, X)>`. Tractable for
   nested-primitive shapes, but if the inner contains any
   `ptr addrspace(1)`, RS4GC's `support for FCA unimplemented` assertion
   fires the moment the nested struct crosses any safepoint.
3. **Caller-mandatory explicit `eco.to_heap`** — the verifier stays
   strict; cross-spec's rewriter inserts the `eco.to_heap` instead. This
   is what `plans/wrapper-fca-fix.md`'s author's "Option B" was; it
   works but pessimises the IR (every cross-spec consumer must
   special-case the boxing).

The chosen approach is a hybrid:

- For `construct.*` and `eco.call`: **Option 1**. The heap slot / callee
  ABI forces a boxed `!eco.value` at the boundary, and `to_heap` of an
  aggregate IS the necessary allocation — there is no cheaper shape. At
  `construct.*` what the plan calls an "implicit box" is exactly the
  inner heap allocation the heap layout requires anyway; no double
  allocation.
- For `make.*`: **Option 2** when the inner aggregate is GC-pointer-free
  (nested FCA at the LLVM level — pure SSA `insertvalue` chain,
  near-zero runtime cost; RS4GC is happy because no `ptr<1>` lives
  inside the nested FCA), **Option 1** when the inner contains a GC
  pointer (boxing flattens the outer w.r.t. `ptr<1>`, keeping RS4GC and
  strip-aggregates on their existing one-level path).

The mixed scheme costs almost nothing extra to implement (one
`containsGCPointer(type)` recursion in the lowering helper) and recovers
the zero-alloc path for chained primitive-heavy aggregates — the
dominant shape in eco-compiler self-compile (records of `Int` / `String`
/ small `Custom`). Boxing only happens where the IR genuinely has no
other choice today; Phase 2 (§9) lifts that constraint for `make.*`
too.

## 3. Design

### 3.1 Op widening (`runtime/src/codegen/Ops.td`)

Switch the field/operand types from `Eco_AnyValue` to `Eco_AnyValueOrAggregate`
on every position listed in §0. `Eco_AnyValueOrAggregate` already exists in
the dialect (added for `eco.case` Phase 3.4 #1), so no new type constraint
is needed. Specifically:

- `Eco_Tuple2ConstructOp`, `Eco_Tuple3ConstructOp`: `$a`, `$b`, `$c`.
- `Eco_RecordConstructOp`, `Eco_CustomConstructOp`: `$fields` (Variadic).
- `Eco_ListConstructOp`: `$head` (tail stays `Eco_Value`).
- `Eco_Tuple2MakeOp`, `Eco_Tuple3MakeOp`: `$a`, `$b`, `$c`.
- `Eco_RecordMakeOp`, `Eco_CustomMakeOp`: `$fields` (Variadic).
- `Eco_ConsMakeOp`: `$head`.
- `Eco_CallOp`: `$operands` (Variadic). Results stay `Eco_AnyValue`.

### 3.2 Shared helper `materialiseAsBoxed`

Add an inline helper in `EcoToLLVMInternal.h`:

```cpp
/// If `v` is an Eco-aggregate-typed SSA value, emit `eco.to_heap` to box
/// it into a fresh `!eco.value` and return that. Otherwise return the
/// value unchanged. Used by `construct.*` and `eco.call` lowerings
/// unconditionally, and by `make.*` only when the operand's inner
/// aggregate contains a GC pointer (see `containsGCPointer`).
///
/// `liveRoots` is forwarded to the inserted `eco.to_heap` so the boxing
/// safepoint sees the outer op's other live values. Callers gather the
/// live roots from the outer op's `getLiveRoots()` (when available) plus
/// any already-boxed sibling fields earlier in the operand list.
mlir::Value materialiseAsBoxed(mlir::OpBuilder &b, mlir::Location loc,
                                mlir::Value v, mlir::ValueRange liveRoots);

/// Returns true if `t` is, or recursively contains, an Eco type that
/// converts to `ptr addrspace(1)` (i.e. `!eco.value`, `!eco.list`, or
/// any aggregate that itself contains one). Used by `make.*` lowering
/// to decide between nest-SSA and box: nest when false (no `ptr<1>`
/// inside the nested FCA — RS4GC handles it), box when true (avoid
/// RS4GC's nested-FCA limit and the one-level strip-aggregates path).
bool containsGCPointer(mlir::Type t);
```

`materialiseAsBoxed` implementation: `if
(isFlattenableAggregateType(v.getType())) emit eco.to_heap`, else return
`v`. The op is created at the pattern-rewriter's insertion point so the
boxing is emitted before the current op's lowering proceeds.

`containsGCPointer` implementation: simple recursive walk —
`!eco.value` / `!eco.list` → true; tuple/record/custom → any-of
children; primitive (`i64`, `f64`, `i32`, `i1`, `i16`) → false.

### 3.3 Construct lowering (heap path)

In `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`:

- `Tuple2ConstructOpLowering`, `Tuple3ConstructOpLowering`: before passing
  each operand to the per-slot store dispatch, run `materialiseAsBoxed`.
- `ListConstructOpLowering`: same for the head operand.
- The Record / Custom lowerings already iterate over `op.getFields()` —
  pre-extract each field into a local `SmallVector<Value>` after running
  `materialiseAsBoxed` on every aggregate-typed entry, then continue with
  the existing alloc-then-store sequence.

The slot store function for a boxed slot (`eco_store_tuple_field`,
`eco_store_record_field`, `eco_store_field`) takes `ptr addrspace(1)`, so
the boxed `!eco.value` slots in naturally.

### 3.4 Make lowering (SSA path) — nest-SSA when safe, selective box

In `runtime/src/codegen/Passes/EcoToLLVMValueAgg.cpp`:

For each `*MakeOpLowering` (`Tuple2`, `Tuple3`, `Record`, `Custom`,
`Cons`, `ClosureEnvMake`), walk the operand list once before
`buildStruct` and route each operand by SSA type:

- Operand is primitive (`i64`, `f64`, `i32`, `i1`, `i16`) or
  `!eco.value`: unchanged — same path as today.
- Operand is an Eco aggregate AND `containsGCPointer(t)` is **false**:
  **pass through unchanged**. `buildStruct`'s `insertvalue` chain sees a
  flat-w.r.t.-`ptr<1>` nested FCA element whose LLVM type is the inner
  aggregate's converted struct type (e.g. `{ i64, i64 }`). The outer
  result is `{ {i64,i64}, X, ... }`. No `ptr<1>` lives inside the
  nested FCA, so RS4GC has no quarrel and the one-level
  strip-aggregates pass works as today.
- Operand is an Eco aggregate AND `containsGCPointer(t)` is **true**:
  route through `materialiseAsBoxed`. The operand becomes a `ptr<1>`,
  the outer FCA element at that slot flattens to `ptr<1>`, and the
  outer is once again w.r.t.-`ptr<1>` flat — exactly the
  pre-Chunk-4-style invariant that RS4GC and strip-aggregates rely on.

`buildStruct` itself doesn't change — by the time its `insertvalue`
chain runs each operand is either a primitive, a `ptr<1>`, or a
primitive-only nested FCA, all of which it already supports. The
result's LLVM type is derived from the operand LLVM types, which match
the type converter's view of the make.*'s declared result type because
cross-spec, when it promoted the function's result, propagated the
inner aggregate type into the make.*'s declared slot type. (Where
cross-spec did not propagate — declared slot is still `!eco.value` —
the operand's actual SSA type being an aggregate would still land in
the "box" branch, so the outer is `{ ptr<1>, ... }` and matches.)

The decision falls out from the type check at lowering time; no
cross-spec change is needed for Phase 1. Phase 2 (§9) extends
cross-spec + strip-aggregates so the GC-pointer-inner branch above can
also nest-SSA — at which point the box branch becomes dead.

### 3.5 eco.call lowering

In `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` (or wherever
`eco.call` is lowered for the indirect / closure path):

- Walk `adaptor.getOperands()` and run `materialiseAsBoxed` on each.
  The callee for any remaining `eco.call` is reached via the boxed ABI —
  PAP / closure dispatch — so every operand needs to be `!eco.value`
  before the call.

The cross-spec call rewriter at `EcoUnboxedAggCrossSpec.cpp:1186-1275`
already converts `eco.call` → `func.call` when the callee is in the
eligible set, so this widening only matters for the calls that *don't*
get redirected — closure-mediated, indirect, foreign. Those are exactly
the calls where boxing back to `!eco.value` is the right semantics.

### 3.6 Live-roots for the boxing safepoint

Each inserted `eco.to_heap` is itself a GC-triggering call. Other
operands of the outer construct/make/call may be live across it, and
EcoGCPrepare won't have seen them yet (it runs before EcoToLLVM). The
helper takes `liveRoots` explicitly so each caller can supply its
context:

- For `construct.*` ops: pass the outer op's `getLiveRoots()` plus
  every `!eco.value`-typed sibling operand already extracted in this
  lowering. The simplest pattern is "gather all sibling operands first,
  box them in source order, and let each newly-boxed value feed into
  the next boxing's live-roots set".
- For `make.*` ops: only the GC-pointer-inner aggregates take this
  path. Same gather-then-box pattern as construct, but the set of
  boxed-this-op operands is typically smaller (or empty, for
  primitive-heavy aggregates).
- For `eco.call`: pass the existing `getLiveRoots()` of the call op (it
  carries `GCRootCarrier` already).

### 3.7 Pipeline ordering

No new pass. Each lowering pattern emits the `eco.to_heap` inline; the
conversion driver picks it up in the same conversion run and lowers it
via the existing `ToHeapOpLowering`. No re-entry / re-conversion needed.

## 4. Out of scope

- `eco.from_heap` operand type — stays `Eco_Value`. The cascading
  `!llvm.ptr` errors in the bootstrap log are an artefact of the
  conversion driver bailing mid-conversion on the construct/make
  errors; once the widening lands they vanish.
- `eco.safepoint` operand type — stays `Eco_Value`. Aggregates aren't
  GC roots; their `ptr addrspace(1)` constituents are tracked at the
  LLVM level by RS4GC. The existing strip-aggregates code at
  `EcoUnboxedAggCrossSpec.cpp:1278-1300` stays at one level of FCA in
  Phase 1; recursive strip-aggregates lives in Phase 2 (§9), which
  unlocks the nest-SSA path for GC-pointer-inner aggregates too.
- `eco.papCreate` / `eco.papExtend` operand types — these go through
  the closure-creation path which is already boxed-ABI; their operand
  constraints can stay as they are. If a future shape surfaces with
  aggregate-typed papCreate captures we widen those too, on the same
  template.

## 5. Implementation

### Chunk 1 — Ops.td widening

File: `runtime/src/codegen/Ops.td`.

For each op listed in §3.1, change the operand type from `Eco_AnyValue`
(or `Variadic<Eco_AnyValue>`) to `Eco_AnyValueOrAggregate`. Each is one
line. Total ~15 lines of one-token edits.

After this change the verifier accepts aggregate operands; lowering still
needs to handle them (Chunks 2-4).

### Chunk 2 — `materialiseAsBoxed` + `containsGCPointer` helpers

File: `runtime/src/codegen/Passes/EcoToLLVMInternal.h` (declarations) +
`runtime/src/codegen/Passes/EcoToLLVMHeap.cpp` (definitions, since heap
already includes the necessary headers).

Two small free functions as described in §3.2:
- `materialiseAsBoxed` — emits `eco.to_heap` when the operand is an
  aggregate, returns unchanged otherwise.
- `containsGCPointer` — recursive type predicate, used by `make.*`
  lowering to gate the box-vs-nest decision.

~40 LoC total.

### Chunk 3 — Construct lowering boxing

File: `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`.

- `Tuple2ConstructOpLowering`: gather `aLLVM`, `bLLVM` as today, then
  `aLLVM = materialiseAsBoxed(...)` and same for `bLLVM`. `aOrig`/`bOrig`
  are still the Eco types — but if `materialiseAsBoxed` boxed, the
  effective storage kind for that slot becomes `!eco.value`, regardless
  of the original. Update the per-slot dispatch to check
  `isHPtrLLVMType(aLLVM.getType())` (or "did we just box this") and
  route through the boxed-store helper.
- `Tuple3ConstructOpLowering`: same with three operands.
- `ListConstructOpLowering`: same on the head.
- `RecordConstructOpLowering` / `CustomConstructOpLowering`: walk the
  fields up-front; for each aggregate-typed field, box it before
  entering the alloc/store loop. The store loop already has a 4-way
  dispatch (f64 / i64 / i1|i16 / else); the "else" branch (which already
  calls `eco_store_record_field` / `eco_store_field`) becomes the path
  for the post-box `!eco.value`.

~80 LoC across the five patterns.

### Chunk 4 — Make lowering nest-SSA / selective box

File: `runtime/src/codegen/Passes/EcoToLLVMValueAgg.cpp`.

For each `*MakeOpLowering` (`Tuple2`, `Tuple3`, `Record`, `Custom`,
`Cons`, `ClosureEnvMake`): walk the operand list once before
`buildStruct` and decide per-operand:

- Primitive / `!eco.value`: leave as-is (today's path).
- Aggregate, `containsGCPointer(t) == false`: pass straight through
  to `buildStruct` (nested FCA, all-primitive inner — zero alloc).
- Aggregate, `containsGCPointer(t) == true`: `materialiseAsBoxed`
  (one heap alloc for the inner, outer FCA slot becomes `ptr<1>`).

`buildStruct` is unchanged; the type-converter's view of the make.*'s
result type matches the operand-derived LLVM struct because cross-spec
already propagated the inner aggregate's type into the make.*'s slot
when promoting the function (and when it didn't, the operand still has
an `!eco.value` declared slot and an aggregate SSA type — landing in
the box branch keeps everything consistent).

~55 LoC across six patterns (vs an unconditional-box version's ~40;
the extra ~15 is the per-operand type dispatch).

### Chunk 5 — `eco.call` operand boxing

File: `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`.

Locate the `CallOp` lowering pattern. Walk `adaptor.getOperands()` and
replace each aggregate-typed operand with `materialiseAsBoxed(...)`
before the existing operand-prep code runs.

If `eco.call` is lowered in multiple patterns (direct vs indirect,
saturated vs PAP), each gets the same one-loop prologue.

~30 LoC.

### Chunk 6 — Fixtures

Files under `test/codegen/`:

- `cross_spec_nested_aggregate_construct.mlir` — two functions: an
  inner that returns a mixed-element `!eco.record<i64, !eco.value>`,
  an outer that calls inner via the eligible-callee path and uses the
  result as a field of its own `eco.construct.record`. FileCheck on
  the lowered LLVM IR verifies the inserted `eco_alloc_record_uninit`
  (the implicit box's alloc) appears between the inner call and the
  outer alloc.
- `cross_spec_nested_aggregate_make.mlir` — same pattern but the
  outer op is an `eco.make.*` (when the outer is also a promoted
  worker whose return rewrites construct→make via `retypeJoinTree`).
  Two sub-fixtures exercising each branch of the nest-vs-box dispatch:
  - `_primitive_inner`: inner aggregate is `!eco.tuple2<i64, i64>`.
    FileCheck verifies the nested FCA appears in the IR (e.g.
    `insertvalue {{.*}}, { i64, i64 } %{{.*}}, 0`) and **no**
    `eco.to_heap` / `eco_alloc_*` is emitted for the inner aggregate.
  - `_ptr_inner`: inner aggregate is `!eco.tuple2<!eco.value, i64>`
    (contains a GC pointer). FileCheck verifies the `eco.to_heap`
    (post-box alloc) precedes the outer's insertvalue chain.
- `cross_spec_nested_aggregate_call.mlir` — closure-mediated call
  that takes a promoted-aggregate operand. FileCheck verifies the
  box-then-call sequence.

Plus a `test/elm/src/CrossSpecNestedAggregateTest.elm` mirroring an
eco-compiler-style chain (a record-returning helper used as a field of
another record).

### Chunk 7 — Invariant updates

File: `design_docs/invariants.csv`.

- `REP_AGG_001` — append a note that aggregate-typed values may appear
  as operands of `construct.*`, `make.*`, `eco.call`, and that the
  Eco → LLVM lowering emits an implicit `eco.to_heap` to box each such
  operand before storage / passing.
- `CGEN_064` Phase 3.4 #1 — replace the now-obsolete "Sret combined
  with eco.return ... is gated for now" sentence with a pointer to
  this plan as the resolution.

## 6. Verification

1. `cmake --build build --target check` — the existing E2E suite must
   stay green (1429 / 1429 from the wrapper-fca-fix baseline).
2. `cmake --build build --target full` — same suite, fresh compile path.
3. Bootstrap through Stage 7 per `guides/bootstrap.md`:
   - `cmake --build build --target guida`
   - `cmake --build build --target eco-boot`
   - `cmake --build build --target eco-boot-verify`
   - `cmake --build build --target eco-compiler-mlir`
   - `cmake --build build --target eco-compiler` — the previously-failing
     stage; must succeed now.
   - `cmake --build build --target eco-compiler-boot` — Stage 7 native
     self-compile.

## 7. Effort

| Chunk | LoC | Risk |
|---|---|---|
| 1 — Ops.td widening | ~15 | trivial; mechanical token edit |
| 2 — `materialiseAsBoxed` + `containsGCPointer` helpers | ~40 | trivial |
| 3 — Construct lowering | ~80 | low; existing per-slot dispatch carries the new branch |
| 4 — Make lowering nest-SSA / selective box | ~55 | low; per-operand type dispatch + helper |
| 5 — `eco.call` operand prep | ~30 | low–medium; need to identify all eco.call lowering patterns |
| 6 — Fixtures | ~200 | low; mechanical FileCheck, +1 sub-fixture for nest-SSA make |
| 7 — Invariants | ~3 sentence edits | trivial |

Total ~300 LoC.

## 8. Risks and mitigations

- **Live-roots for the inner box**: if a construct op has multiple
  aggregate-typed siblings, each box's safepoint sees the others as live
  pre-box. The helper takes an explicit `liveRoots` so callers thread
  the correct set; the construct/make patterns gather all siblings
  before any boxing begins.
- **Indirect `eco.call` paths**: there may be more than one lowering
  pattern (saturated direct vs PAP-extended vs typed-apply). Each needs
  the same one-loop operand-box prep; missing one shows up as the same
  verifier diagnostic on a different fixture, so coverage is easy to
  check.
- **Performance**: chained-promotion cases pay differently per op:
  - `construct.*` field: one heap alloc for the inner aggregate
    regardless — the heap layout forces it. (Same cost as if you'd
    written `construct.tuple2 inner_construct_result, x` by hand;
    nothing extra from the implicit box.)
  - `make.*` field with **primitive inner**: **zero** extra allocs —
    the inner nests as a flat FCA element into the outer.
  - `make.*` field with **GC-pointer inner**: one heap alloc to box
    the inner. Workaround for RS4GC's nested-FCA limit; lifted to
    zero in Phase 2 (§9) once strip-aggregates recurses.
  - `eco.call` operand: one heap alloc per aggregate operand — the
    boxed-ABI callee (closure / PAP / foreign) requires it.

  Strictly better than the pre-Chunk-4 baseline at every position,
  optimal already at `make.* primitive`, and the remaining boxes are
  exactly the ones the IR layout / RS4GC currently forces.

## 9. Phase 2 — Recursive ABI promotion + recursive strip-aggregates

Out of scope for this plan; lands as a follow-up once Phase 1 is in and
the eco-compiler self-compile is unblocked. Captured here so it's not
forgotten.

After Phase 1 the remaining unnecessary boxing happens in one place:
`make.*` with a GC-pointer-containing inner aggregate. Construct.* and
eco.call boxes are forced by the heap layout and the boxed-ABI calling
convention respectively — those are real costs, not workarounds.
`make.*` boxing of a GC-pointer-inner is a workaround for two specific
infrastructure limits:

1. RS4GC's "support for FCA unimplemented" path fires when a `ptr<1>`
   sits inside a nested FCA at a safepoint.
2. The strip-aggregates pass at `EcoUnboxedAggCrossSpec.cpp:1278-1300`
   decomposes one level of FCA before the safepoint and reassembles
   after; it doesn't recurse.

The fuller design is three pieces:

### 9.1 Recursive ABI promotion in cross-spec

Today cross-spec promotes a function's return / arg types one level: an
`!eco.value` slot becomes the eligible inner aggregate. Extend the
promotion to recurse — an inner aggregate slot itself gets promoted if
its own component types are eligible. This aligns the dialect-level
type with the SSA shape that the body emits, so the make.*'s declared
slot type is always the actual aggregate (no slot still saying
`!eco.value` while an aggregate flows in).

Knock-on effects to audit: `eco.return` type checks, the cross-spec
result-substitution rewriter, any verifier that compares declared vs
substituted types.

### 9.2 Recursive strip-aggregates

Today the pass at `EcoUnboxedAggCrossSpec.cpp:1278-1300` decomposes a
single level of FCA at each safepoint, feeding the leaf values to the
safepoint as separate operands and reassembling the FCA on the other
side. Extend it to recurse into nested FCAs: a
`{ {i64, ptr<1>}, ptr<1> }` would feed three top-level operands (two
leaf `ptr<1>` values + one i64), and reassemble both levels of FCA on
the relocation side.

The reassembly side is the tricky bit — `insertvalue` chains have to
respect the nested struct's field offsets. A clean way to write it is
a single recursive walk that emits the same shape for decomposition
and reassembly, with the safepoint operand list flattened in DFS
order.

### 9.3 Drop the `make.*` box branch

With (9.1) and (9.2) in place, the GC-pointer-inner make.* case can
nest SSA the same way primitive-inner does today. The
`containsGCPointer` dispatch and the `materialiseAsBoxed` call inside
`*MakeOpLowering` become dead code; delete them. `make.*` always
nests; the box helper stays for `construct.*` and `eco.call` callers.

### 9.4 Out of scope for Phase 2

`construct.*` and `eco.call` keep their Phase 1 behaviour — the heap
layout's "one 64-bit slot per field" and the boxed-ABI calling
convention aren't Phase-2 territory. If those positions become hot
later, a Phase 3 could add either an aggregate-layout heap record (one
heap object with multiple aggregate fields stored inline at known
offsets) or an aggregate-ABI `eco.call` (closure callees aware of
unboxed aggregate operands). Neither is on the path right now.

### 9.5 Effort estimate

| Piece | LoC | Risk |
|---|---|---|
| 9.1 recursive cross-spec promotion | ~80–150 | medium; type-prop bookkeeping |
| 9.2 recursive strip-aggregates | ~100–200 | medium–high; safepoint operand list + relocation reassembly |
| 9.3 make.* dead-code removal | -30 | trivial (deletion) |
| Phase 2 fixtures (GC-pointer-inner nest) | ~120 | low; mirror Phase 1 fixtures |

Worth landing on its own branch with its own fixtures and a bootstrap
run before merging. Phase 2's win is "chained aggregates with mixed
primitive + GC-pointer content also pay zero alloc"; Phase 1 already
covers the primitive-heavy majority, so this is an optimisation, not
a correctness fix.
