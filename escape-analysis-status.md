# Escape Analysis & Unboxed Aggregates — Compilation Phase Status

Status snapshot of the escape-analysis / unboxed-aggregate work as of 2026-05-21. Cross-references the five active plans:

- `plans/escape-analysis-implementation.md` (master plan — Phases 0–4)
- `plans/widen-construct-make-call-aggregates.md`
- `plans/cross-spec-bridgeoperands-regressions.md`
- `plans/wrapper-fca-fix.md`
- `plans/cross-spec-nested-shape-dsl.md`

This is a code survey, not a re-plan. Every claim below is checked against the current source. Where a plan's stated status is out of date (notably `wrapper-fca-fix.md`'s "deferred chunks" banner), the code reality is reported and the banner identified as stale.

---

## 1. What we are trying to do

Elm semantics force every constructed compound value — a 2-tuple, a record, a custom-ADT payload, a list cons cell, a closure environment — to live on the GC heap as an `!eco.value` pointer. Each construction therefore costs a runtime allocation and each access costs a heap load. For values whose lifetime is locally bounded (a tuple built, immediately projected, never escaping the function) the allocation is wasted: LLVM's mid-end (mem2reg, SROA, InstCombine) could keep the components in registers if the IR exposed them as a value-level aggregate rather than a heap object.

The escape-analysis project introduces a parallel value-level representation for small aggregates — `!eco.tuple2<…>`, `!eco.tuple3<…>`, `!eco.record<…>`, `!eco.custom<…>`, `!eco.cons<…>`, `!eco.closure_env<…>` — and a set of compiler passes that promote constructions whose results don't escape into this value-level form. A promoted construction lowers to LLVM `insertvalue` rather than to a heap allocator call; downstream SROA scalarises the struct into registers. The work spans three axes:

1. **Intra-function** escape detection + rewrite (Phase 1 / 2).
2. **Cross-function** worker / wrapper splitting so that a function returning or accepting an aggregate exposes a scalar-or-aggregate ABI to other promoted callers while preserving the boxed ABI for indirect / PAP / foreign callers (Phase 3 and its sub-phases).
3. **LLVM-IR-level** correctness work to keep `RewriteStatepointsForGC` (RS4GC) happy: RS4GC rejects first-class aggregates whose element list contains a `ptr addrspace(1)` live across a safepoint ("support for FCA unimplemented"). Multiple sub-plans (`wrapper-fca-fix.md`, `widen-construct-make-call-aggregates.md`, `cross-spec-nested-shape-dsl.md`) exist specifically to keep IR shape compatible with this constraint.

All work is gated behind the `-enable-unboxed-agg` flag (default ON since Phase 3.2). The default flip means the entire pipeline below now runs on every native compile.

---

## 2. Pipeline order — pass-by-pass

Defined in `runtime/src/codegen/EcoPipeline.cpp:49-92` (`buildEcoToEcoPipeline`) and `:94-130` (`buildEcoToLLVMPipeline`). Highlighted passes are the escape / aggregate ones.

```
Eco-to-Eco:
  RCElimination
  EcoPAPSimplify
  ─── -enable-unboxed-agg gate ────────────────────────────────────
  EcoUnboxedAggCrossSpec       (module-level — cross-function spec)
  EcoEscapeAnalysis            (per-func — classify constructs)
  EcoUnboxedAggSpecialize      (per-func — construct → make rewrite)
  EcoFlattenAggBoundary        (module-level — scalarise boundaries)
  ─── end gate ────────────────────────────────────────────────────
  UndefinedFunction

Eco-to-LLVM bridge:
  JoinpointNormalization
  EcoControlFlowToSCF
  Canonicalizer
  EcoBoxAggregateOperands      (post-spec rebox at construct/call sinks)
  EcoGCPrepare
  BFToLLVM
  EcoToLLVM                    (pattern-based — Heap/ValueAgg/Closures/…)
  SCFToControlFlow
  ConvertControlFlowToLLVM
  ArithToLLVMConversion
  ReconcileUnrealizedCasts

LLVM-IR level (eco::addEcoGCPipeline, EcoPtrIntVerify.cpp:448):
  mem2reg → SROA → FoldExtractValuePass → RewriteStatepointsForGC
```

The remainder of this report walks these passes in pipeline order, identifying which plan items have landed and which remain open.

---

## 3. Status by compiler phase

### 3.1 Elm front-end — `Compiler.Generate.MLIR.LogicalTypes`

`compiler/src/Compiler/Generate/MLIR/LogicalTypes.elm`. The Elm-to-MLIR generator attaches two array-of-StringAttr attributes to every emitted `func.func`: `eco.logical_param_types` and `eco.logical_result_types`. Each entry is a single string in the DSL (`"i64"`, `"value"`, `"tuple2:i:v"`, `"record:3:i:i:v"`, `"custom:tag:N:k0:…:kN-1"`, `"cons:k:v"`). Cross-spec reads them as the authoritative source of "logical Elm type of this `!eco.value` slot."

**Landed:**
- All seven `LogicalTypeDesc` constructors emit (`:84-95`): `LValue`, `LI64`, `LF64`, `LI16`, `LI1`, `LTuple2/3`, `LRecord`, `LCustom`, `LCons`, `LUnknown`.
- `customMaxFields` bumped from 3 → 8 (`:60-67`) — Phase 3.3 commit 5 from the master plan.
- `addLogicalTypesAttr` / `addLogicalTypesAttrUnknown` cover every emitter site enumerated by Phase 3.1 §4 (closure clones, tail funcs, externs, kernel decls, ctors).

**Open:**
- The DSL parser admits a bracket form for nested shapes (`record:2:[tuple2:i:i]:v`) — see §3.4 below — but the Elm encoder does not emit it. `kindOf` at `:175-188` collapses any non-primitive `MonoType` to `AKValue`, so a `Record { inner : (Int, Int), other : List a }` always wires as `record:2:v:v` rather than `record:2:[tuple2:i:i]:v`. The bracket form is currently exercised only by hand-written `.mlir` fixtures (`cross_spec_nested_shape_dsl.md` §7 "Out of scope" defers this).

### 3.2 `EcoUnboxedAggCrossSpec` (module pass)

`runtime/src/codegen/Passes/EcoUnboxedAggCrossSpec.cpp`, ~2 700 LoC. The single largest pass in the system and the pivot point of every cross-function plan. Reads each `func.func`'s logical-type attributes, runs a fixpoint eligibility analysis, and for each eligible function emits a `@f$unboxed` worker (aggregate signature) plus rewrites the original `@f` body into a wrapper that bridges the boxed and unboxed forms.

**Landed (Phase 3, 3.1, 3.2):**
- Logical-type DSL parser with five aggregate kinds (`parseLogicalShape` :387, `parseShape` :263, `parseElement` :224). Recursive descent supporting bracketed sub-shapes (§3.1 of `cross-spec-nested-shape-dsl.md`).
- DSL stringifier + `shapeFromMLIRType` for round-trip / diagnostics (`:416-521`).
- Fixpoint eligibility over a DAG of functions (`:2440-2510` ish). Per-param use check (`allUsesAreProjectionsOrCallsToEligible`, `:1119+`) and per-result producer check (`isAcceptedAggregateProducer` + `resultPositionHasAggregateProducer`, `:909+`).
- SCC-aware mutual recursion: Tarjan `computeSCCs` + a second inner fixpoint per SCC > 1 (the Phase 3.2 #1 lift of the original disqualification).
- Worker clone + signature rewrite (`cloneAsWorker`, `:1830+`), with `func.return` rewriting walking back to producer `construct.*` ops via `retypeJoinTree` (`:1334+`) and `rewriteConstructToMake` (`:1597+`).
- Wrapper construction (`replaceBodyWithWrapper`, `:2155+`).
- Call-site bridging via the `bridgeOperands` closure (`:1942+`) — supports both directions (`eco.from_heap` value→agg and `eco.to_heap` agg→value).

**Landed (Phase 3.3 — Sret ABI):**
- `ResultAbi { Direct, Sret, Boxed }` enum + per-result classification via `chooseResultAbi` (`:250-280`). Aggregate results carrying any `!eco.value` element route through Sret; all-primitive aggregates wider than `kMaxDirectFields = 3` (the SelectionDAG StatepointLowering wall, `:256-262`) also route through Sret; otherwise Direct.
- Worker signature builder prepends a `!llvm.ptr` per Sret result (`buildWorkerType`, `:1234+`).
- `emitSretStore` (`:1346+`) and `emitSretLoad` (`:1370+`) do per-outer-field GEP + single `llvm.store`/`llvm.load` of the (possibly converted nested) struct. The nested-element branch bridges to an LLVM struct value via `unrealized_conversion_cast` — covering §3.5 + §3.6 of the nested-shape-dsl plan.

**Landed (Phase 3.4 #1 — arith.select join recursion):**
- `arith.select` arms are recursively walked by `isAcceptedAggregateProducer` (`:1048-1061`). Both arms must be accepted leaves for the slot to promote; `retypeJoinTree` retypes intermediate select results in place.
- Bottom-up retyping in `retypeJoinTree` (`:1334+`) covers chained joins.

**Landed (Phase 2 of cross-spec-nested-shape-dsl.md):**
- Admission gate (`elementAdmitsNesting` + `admitOrDemote`, `:786-813`) — refuses nesting when the inner aggregate contains a GC pointer, demoting the slot back to `Boxed`. Wired at the parser entry sites (`readLogicalShapes` :544, :553).
- Recursive `elementToLLVMTy` (`:680-720`) lowers nested aggregate element types to nested LLVM structs.
- Use-side nested-projection recursion in `allUsesAreProjectionsOrCallsToEligible` (`:1156-1180`) for chained projections through a nested param shape.

**Landed (issues from `cross-spec-bridgeoperands-regressions.md`):**
- Issue 1 (sret-slot offset): `bridgeOperands` takes an `argOffset` parameter (`:1942-1986`). All three regression fixtures exist in `test/codegen/`.
- Issue 2 (agg → value bridge): the `else if (isAggSSAType(haveTy))` branch (`:1966-1976`) inserts `eco.to_heap` for promoted-producer-into-boxed-callee flows.
- Issue 3 (nested-aggregate make from rewriteConstructToMake): Phase 1.5 stopgap `boxIfMismatched` (`:1684-1700`) still in place — see §5 below.

**Open:**
- **`eco.case` as a result producer (Phase 3.4 #1)** is explicitly disabled at `:1071-1074` ("temporarily disabled — see plan §3.4 footnote. Stage 7 self-compile OOB in `retypeJoinTree`'s `eco.case` rebuild, not yet reproduced in a small fixture"). The dialect widening landed; only the analysis-side accept is gated off. Currently rejects 5 742 producer slots per eco-compiler self-compile.
- **Phase 3.4 #2 (`eco.joinpoint` loop-carry)** — not implemented. The plan itself defers this ("DEFERRED. Re-opens when there's a profiled workload showing loop-carried aggregates dominating", master plan §3.4 #3 ordering).
- **§3.3 bullet #1 of nested-shape-dsl plan** — construct.* field-type structural recursion. Currently the producer check accepts any matching-kind `construct.*` without verifying that its field operand types align with the expected nested `elementTys`. Combined with the stopgap below it's safe; combined without it (a hypothetical future drop of `boxIfMismatched`) it would expose a correctness gap. Documented but not landed.
- **§3.8 of nested-shape-dsl plan** — drop `boxIfMismatched`. Confirmed by experiment (this session) that removing it regresses one existing fixture; the gap can't be closed without either Elm-side nested DSL emission or an inverse shape-upgrade pass in eligibility.

### 3.3 `EcoEscapeAnalysis` (per-func pass)

`runtime/src/codegen/Passes/EcoEscapeAnalysis.cpp`, ~215 LoC.

Walks every `eco.construct.{tuple2,tuple3,record,custom,list}` op in a function and classifies its result as `non_escaping` (every use is the matching projection op at operand 0) or `escapes`. Verdict goes on an `eco.escape = "non_escaping" | "escapes"` attribute consumed by `EcoUnboxedAggSpecialize`.

**Landed (Phase 1 + 2):**
- All five aggregate construct kinds covered. The Phase 1 `allElementsPrimitive` guard is gone — Phase 2's mem2reg + SROA + FoldExtractValuePass + RS4GC ordering (see §3.10) made it unnecessary.

**Conservatism cost (this session's instrumentation):** the pass tags **30 908 / 30 910** constructs as `escapes` (99.99 %) on a self-compile. The top escape causes are `eco.construct.list` (9 184), `eco.return` (7 415), `eco.call` (5 110), `func.return` (4 708), `eco.yield` (2 435). Returns alone account for 40 % of "escapes" verdicts despite cross-spec being purpose-built to handle return aggregates — the two passes duplicate effort.

**Not landed:** Phase 4 closure-env escape detection.

### 3.4 `EcoUnboxedAggSpecialize` (per-func pass)

`runtime/src/codegen/Passes/EcoUnboxedAggSpecialize.cpp`, ~165 LoC.

Reads the `eco.escape` attribute and rewrites every `non_escaping` `eco.construct.*` into the matching `eco.make.*`. Strips the attribute on the way out.

**Landed (Phase 1 + 2):** all five aggregate kinds (`Tuple2ConstructOp` → `Tuple2MakeOp`, etc.).

**Empirical yield:** 2 rewrites per eco-compiler self-compile (both Tuple2). Direct consequence of the escape analysis's conservatism above.

### 3.5 `EcoFlattenAggBoundary` (module pass)

`runtime/src/codegen/Passes/EcoFlattenAggBoundary.cpp`. Runs after cross-spec to scalarise aggregate-typed function parameters into N scalar args (one per element), inserting `eco.make.*` at entry and `eco.project.*` at call sites so the body's intra-function uses remain unchanged.

**Landed (Phase 3.1 §3, master plan):** one-level flatten covering tuple2/tuple3/record/custom params. CGEN_066 invariant. Result-side flattening is by design only for Direct ABI; the Sret slot path delivers aggregate results without going through this pass.

**Open / Out of scope:**
- Recursive flatten (master plan §9 / Phase 2 of `widen-construct-make-call-aggregates.md`) — not landed.
- Nested-shape-dsl §3.9 explicitly leaves this pass at one level and relies on the §3.4 gate to keep nested boundary types from ever reaching it.

### 3.6 `EcoBoxAggregateOperands` (module pass)

`runtime/src/codegen/Passes/EcoBoxAggregateOperands.cpp`, ~190 LoC. Runs after cross-spec + the per-func passes, before `EcoGCPrepare`. Walks every `construct.*`, `eco.call`, and `func.call` whose operand carries an aggregate SSA type but whose sink expects `!eco.value`, and inserts `eco.to_heap`.

**Landed (Phase 1 of `widen-construct-make-call-aggregates.md`, Chunk 2 + Chunk 5 with delegation to a separate pass):** all three sinks covered with `materialiseAsBoxed` from `EcoToLLVMHeap.cpp:1919`. The `make.*` sink is deliberately a no-op (master plan §9 / Phase 2 not landed) — see `:152-160`.

**Empirical yield:** 14 `to_heap` insertions per self-compile, evenly split between construct.* (7) and `eco.call` (7); zero `func.call`. The `make.*` slot count comes back zero too.

### 3.7 Op widening — `Ops.td`

`runtime/src/codegen/Ops.td`. Chunk 1 of `widen-construct-make-call-aggregates.md` lifted the `Eco_AnyValue` operand-type restriction on every `construct.*` / `make.*` / `eco.call` field/operand position so aggregate-typed SSA values can flow through without verifier rejection. Sinks then either box (heap path) or nest-SSA (value path).

**Landed:**
- `Eco_AnyValueOrAggregate` is the type constraint on `Tuple2/3/Record/Custom ConstructOp` fields, all five `make.*` operands, `ListConstructOp` head, `CallOp` operands, and the result types of `CaseOp` / `YieldOp` / `ReturnOp` (the last three for the Phase 3.4 join-shape work).
- The `make.*` family (`Tuple2/3MakeOp`, `RecordMakeOp`, `CustomMakeOp`, `ConsMakeOp`, `ClosureEnvMakeOp`) is fully defined in `Ops.td:2887-2980`.
- Boundary ops: `Eco_ToHeapOp` (`:2985`), `Eco_FromHeapOp` (`:3029`), `Eco_MakeClosureOp` (`:3059`) — Phase 0 plumbing.

**Open:** `papCreate` / `papExtend` operand types stay `Eco_AnyValue` per Phase 1 §4 of the widen plan ("Out of scope").

### 3.8 Eco-to-LLVM — `EcoToLLVMValueAgg.cpp`

`runtime/src/codegen/Passes/EcoToLLVMValueAgg.cpp`, ~690 LoC. Pattern-based lowering for all `make.*` ops, plus the `to_heap` value-aggregate branches.

**Landed (Phase 0 + wrapper-fca-fix Chunks 1, 2.2, 2.3):**
- `Tuple2/3MakeOpLowering`, `RecordMakeOpLowering`, `CustomMakeOpLowering`, `ConsMakeOpLowering`, `ClosureEnvMakeOpLowering` — `LLVM::UndefOp` + `insertvalue` chains; `Pure`.
- `ToHeapOpLowering` for all five data-aggregate kinds. Record / Custom use the **Fix B reorder** (pre-extract every field as a scalar, alloc, then per-field store) — `:332-380` and `:384-450`. Comments at `:333-336` document the reasoning.
- Tuple2 / Tuple3 / Cons use **Fix C** (alloc-uninit + per-field store helpers): `getOrCreateAllocTuple2Uninit`, `getOrCreateAllocTuple3Uninit`, `getOrCreateAllocConsUninit`, plus `eco_store_tuple_field{,_i64,_f64}`, `eco_store_cons_head{,_i64,_f64}`, `eco_store_cons_tail`. The Tuple2 path is at `:230-322`; Cons at `:455-540`. RS4GC relocates the `ptr addrspace(1)` field values across the alloc safepoint via standard SSA tracking, no `ptrtoint` strips GC-pointer status.
- The `*MakeOpLowering` lowerings nest aggregate operands directly via `insertvalue` when the inner type passes `containsGCPointer(t) == false`; box them via `materialiseAsBoxed` otherwise (master plan §9 Phase 2 prerequisite still pending).

**Wrapper-fca-fix.md banner is stale.** The plan's own §8 says Chunks 1, 2.2, 2.3, 3, 4 are "deferred"; the code shows otherwise. Every chunk is in the tree.

### 3.9 Eco-to-LLVM — `EcoToLLVMHeap.cpp`

`runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`. The pattern-based lowering for `eco.construct.*` (heap path). Mirrors `EcoToLLVMValueAgg.cpp`'s `to_heap` patterns for the unboxed-source case.

**Landed:** Tuple2/3/Cons construct lowerings use the same alloc-uninit + per-field store pattern (verified above). Record/Custom use the existing alloc + store-loop pattern, with `materialiseAsBoxed` inserted on aggregate-typed operands before the alloc (Chunk 3 of the widen plan).

`materialiseAsBoxed` (`:1919`) and `containsGCPointer` (`:1885`) are file-scope helpers used by both EcoToLLVMHeap and EcoBoxAggregateOperands.

### 3.10 LLVM-IR pipeline — `eco::addEcoGCPipeline`

`runtime/src/codegen/Passes/EcoPtrIntVerify.cpp:448-470`. The Phase 2 prerequisite from the master plan (master §"Phase 2 — Records, customs, lists/cons"):

```cpp
FPM.addPass(PromotePass());                  // mem2reg
FPM.addPass(SROAPass(SROAOptions::ModifyCFG));
FPM.addPass(FoldExtractValuePass());          // local helper, :356
// then:
MPM.addPass(RewriteStatepointsForGC());
```

`FoldExtractValuePass` walks `extractvalue` chains back through `insertvalue` to collapse FCAs whose every consumer is an extract. With this in place, the wrapper's transient FCAs (Shape A in `wrapper-fca-fix.md` §1.0) become dead and are DCE'd before RS4GC sees them. RS4GC's "support for FCA unimplemented" assertion is structurally avoided for every IR shape cross-spec now emits.

`-emit=llvm` and `-emit=mlir-llvm` both lower through `addEcoGCPipeline`; the Phase 3.2 §2 LLVM-IR validation harness is realised via the existing `-emit=llvm` mode (no separate harness needed).

---

## 4. Cross-cutting infrastructure

### 4.1 Dialect ops in the value-level family

All landed via Phase 0 of the master plan:

| Op | Kind | Where |
|---|---|---|
| `eco.tuple2/3/record/custom/cons/closure_env` (types) | Aggregate value types | `Ops.td:113-180` |
| `eco.make.tuple2/3/record/custom/cons/closure_env` | Pure value-level construct | `Ops.td:2887-2980` |
| `eco.to_heap` | Boxing (GCRootCarrier; rejects closure_env) | `Ops.td:2985` |
| `eco.from_heap` | Unboxing (Pure; rejects closure_env) | `Ops.td:3029` |
| `eco.make.closure` | Closure realisation (GCRootCarrier, allocates) | `Ops.td:3059` |
| `eco.project.{tuple2,tuple3,record,custom}` | Existing ops widened to accept both heap and aggregate operand types | `Ops.td:1100-1180` |
| `eco.project.{list_head,list_tail}` | Same | — |

### 4.2 Type system extensions

- `Eco_AnyValueOrAggregate` constraint at `Ops.td:255`. Permits `Eco_Value` (boxed) or any of the six value-aggregate types in positions where downstream code can dispatch.
- `EcoTypeConverter` in `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` recursively converts every aggregate type to a nested LLVM struct (`:600+`).
- Cross-spec's `elementToLLVMTy` (`EcoUnboxedAggCrossSpec.cpp:680`) shadows the type converter for sret-slot layout — the §3.4 gate guarantees no GC-pointer-inner nested FCAs reach RS4GC at this level.

### 4.3 Runtime ABI additions (`eco-kernel-cpp` + JIT symbol map)

From `wrapper-fca-fix.md` Chunk 2.1, fully landed:

- `eco_alloc_tuple2_uninit(i32 bitmap)`, `eco_alloc_tuple3_uninit(i32 bitmap)`, `eco_alloc_cons_uninit(i32 head_kind)` — allocators that zero-initialise the body and set the header bitmap/kind up-front, leaving field stores to follow.
- `eco_store_tuple_field{,_i64,_f64}` and `eco_store_cons_head{,_i64,_f64}` / `eco_store_cons_tail` — gc-leaf store helpers (declared at `EcoToLLVMRuntime.cpp:489-519`).
- JIT symbol-map entries in `RuntimeSymbols.cpp` so the JIT path resolves the new symbols.
- Old `eco_alloc_tuple2/_tuple3/_cons` field-taking entries removed.

### 4.4 Logical-type DSL

Wire format (Elm side `LogicalTypes.elm:30-42`, parser side `EcoUnboxedAggCrossSpec.cpp:184-261`):

- Leaves: `"value" | "i64" | "f64" | "i16" | "i1"`.
- Aggregates: `"tuple2:K0:K1" | "tuple3:K0:K1:K2" | "record:N:K0…KN-1" | "custom:tag:N:K0…KN-1" | "cons:khead:ktail"`.
- Single-char element kinds: `i` / `f` / `c` / `v`.
- **Bracketed sub-shapes**: `record:2:[tuple2:i:i]:v` etc. Parser supports arbitrary nesting depth; admission gate refuses nesting when the inner contains a GC pointer.

### 4.5 Test corpus

`test/codegen/` contains 34 `cross_spec_*.mlir` files plus:
- Three sret-specific fixtures from Phase 3.3 (`cross_spec_sret_tuple2_pointer.mlir`, `_chain.mlir`, `_scc.mlir`).
- Two FCA-fix fixtures (`cross_spec_sret_record_construct.mlir`, `cross_spec_sret_mixed_tuple2_construct.mlir`) — `wrapper-fca-fix.md` Chunk 5 partial.
- Three bridgeOperands regression fixtures (`cross_spec_sret_plus_aggregate_param.mlir`, `_aggregate_into_boxed_param.mlir`, `_nested_make_record_from_construct.mlir`).
- Three nested-shape-DSL fixtures (`dsl_nested_shape_parse_round_trip.mlir`, `cross_spec_nested_record_primitive_inner.mlir`, `_gc_pointer_inner_demotes.mlir`).
- Two flatten fixtures (`flatten_tuple2_pointer.mlir`, `_returns.mlir`).
- Two join-shape fixtures (`cross_spec_join_select_tuple.mlir`, `_eco_case_tuple.mlir`).

All run via the standard `// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg | %FileCheck %s` template.

---

## 5. Outstanding items

Items landed in the tree but explicitly noted as gating, stopgap, or out-of-scope:

### 5.1 `boxIfMismatched` stopgap survives

`EcoUnboxedAggCrossSpec.cpp:1684-1700`. Originally the Phase 1.5 stopgap from `cross-spec-bridgeoperands-regressions.md` Issue 3 Chunk 4(a). `cross-spec-nested-shape-dsl.md` §3.8 calls for removing it; experimentation in this session confirmed removal regresses exactly one fixture (`cross_spec_nested_make_record_from_construct.mlir`), so it stays. The mechanism: when `rewriteConstructToMake` is invoked with an `expectedAggTy` whose element `i` is `!eco.value` but the actual field SSA type at `i` is aggregate, an `eco.to_heap` is inserted to box it. Comment at `:1660-1683` documents the gap honestly.

Closing it requires either (a) Elm-side nested-DSL emission, or (b) an inverse cross-spec shape-upgrade pass that promotes outer flat shapes to nested when chained producers would otherwise feed them. Neither is in scope of any landed plan.

### 5.2 `eco.case` as result producer — gated off

`EcoUnboxedAggCrossSpec.cpp:1065-1074`. The dialect widening for `Eco_AnyValueOrAggregate` on `CaseOp` results / `YieldOp` operands is in place; only the analysis-side `isAcceptedAggregateProducer` branch is short-circuited with `++ProdRejEcoCaseDisabled; return false;`. Reason given in the comment: Stage 7 self-compile OOB in `retypeJoinTree`'s `eco.case` rebuild, not yet reproduced in a small fixture. Cost (this session's instrumentation): 5 742 producer slots rejected per self-compile.

### 5.3 Phase 3.4 #2 — `eco.joinpoint` loop-carry

Not landed. The master plan §3.4 #3 explicitly marks this "DEFERRED — re-opens when there's a profiled workload showing loop-carried aggregates dominating." `scf.while` consumes 3 061 producer + 3 845 use rejections in the current instrumentation; that's the consequence.

### 5.4 Phase 4 — closure-env escape analysis

Phase 0 plumbing for `!eco.closure_env`, `eco.make.closure_env`, `eco.make.closure`, and `ProjectClosureFromEnvLowering` is in place. The analysis side (escape detection on `AllocateClosureOp` / `PapCreateOp` / `PapCreateGroupOp`) is not implemented. `eco.papExtend` accounts for 27 238 producer + 8 305 use rejections — by far the second-biggest blocker after safepoint — but unblocking it is genuinely hard work because closure capture turns SSA aggregates into heap-stored values.

### 5.5 Phase 2 of `widen-construct-make-call-aggregates.md`

Not landed (the plan's own §9 marks it out of scope). Would add recursive cross-spec ABI promotion + recursive strip-aggregates so that GC-pointer-inner `make.*` cases can also nest-SSA. With this, the `make.*` box branch in `EcoToLLVMValueAgg.cpp` becomes dead code; without it, GC-pointer-inner `make.*` cases get a single boxing alloc to flatten the outer FCA w.r.t. `ptr<1>`. The boxing is rare in real Elm (per instrumentation: zero observed) so the absence of Phase 2 is not currently load-bearing.

### 5.6 Cons-cell specialisation

`LCons` is parsed but mapped to `AggKind::None` in cross-spec (Phase 3.1 Q4). Master plan §8.2 leaves this dependent on profiling data. Current instrumentation: 12 446 `list` constructs analysed, 0 promoted. The escape analysis treats `eco.construct.list` itself as an escape cause (9 184 occurrences), reflecting Elm's recursive list spine.

### 5.7 Stale documentation

- `wrapper-fca-fix.md` §8 ("Status (2026-05-20)") lists Chunks 1, 2.2, 2.3, 3, 4 as "Deferred / Reverted". The code shows they are all in the tree. The banner pre-dates the re-land work.
- `cross-spec-nested-shape-dsl.md` §3.8 ("Drop the Phase 1.5 stopgap") describes a future state. The stopgap is still present.
- Several `// TODO(phase-2)` and similar markers reference plans/sections that have either been completed or absorbed into the wrapper-fca-fix re-land.

---

## 6. Instrumentation status

Following the diagnostic work earlier in this session, the pipeline carries a set of `ALWAYS_ENABLED_STATISTIC` counters that surface during `eco-boot-native --lowering-stats`:

| File | DEBUG_TYPE | Counters |
|---|---|---|
| `EcoUnboxedAggCrossSpec.cpp` | `eco-cross-spec` | Admission gate, producer / use accept and reject breakdowns, ABI classification, boxIfMismatched outcomes, bridgeOperands outcomes. Per-op-name DenseMap dumps for the two big "unknown op" rejection buckets. |
| `EcoEscapeAnalysis.cpp` | `eco-escape-analysis` | Construct verdicts (analysed, non_escaping, escapes) split by kind. Per-op-name DenseMap dump of first escape-causing op. |
| `EcoUnboxedAggSpecialize.cpp` | `eco-unboxed-agg-specialize` | Total rewrites + per-kind breakdown. |
| `EcoBoxAggregateOperands.cpp` | `eco-box-aggregate` | Per-sink reboxing counts (`construct.*` / `eco.call` / `func.call` / `make.*`-skip). |
| `eco-boot.cpp` | (driver) | `llvm::EnableStatistics()` + `llvm::PrintStatistics` at each `lowering-stats` exit site. |

Inserted `eco.to_heap` ops carry an `eco.rebox_source = "<gate-name>"` StringAttr so a single function dump can attribute each to_heap back to its origin gate.

`heap-profile.py diff <baseline-run> <target-run>` was added (~80 LoC in `heap-profile.py`) to emit a per-bucket allocation delta table across `alloc_size_{nursery,oldgen,strings}.tsv`.

---

## 7. Stats analysis — where we end up

Workload: `eco-boot-native --emit=obj --enable-unboxed-agg=true /work/build/compiler/build-kernel/bin/eco-compiler.mlir` (eco-compiler self-compile, ~62 181 functions). Numbers taken from `/tmp/stats_on2.txt`.

### 7.1 Cross-spec gate decisions

| Gate | Counter | Value |
|---|---|---:|
| §3.4 admission | `GateAdmitted` | 51 485 |
|   | `GateDemotedGCInner` | 0 (Elm never emits nested DSL today) |
| Producer accept | `ProdAccepted` | 4 741 |
|   | `ProdRejUnknownDefiningOp` | 30 621 |
|   | `ProdRejCallNotEligibleOrSCC` | 25 146 |
|   | `ProdRejEcoCaseDisabled` (§5.2 above) | 5 742 |
| Use accept | `UseAccepted` | 757 |
|   | `UseRejUnknownOp` | 80 437 |
|   | `UseRejCallNotEligibleOrSCC` | 26 500 |
| ABI classification | `AbiSretGC` | 4 638 |
|   | `AbiDirect` | 78 |
|   | `AbiSretWide` | 0 |
|   | `AbiBoxed` (demoted) | 629 |

Almost everything that promotes is Sret-with-GC-pointer (4 638 of 4 716 aggregate slots). Direct accounts for 78. The §3.4 admission gate never fires demotion because Elm never emits the nested DSL.

### 7.2 Per-op-name rejection breakdowns

`ProdRejUnknownDefiningOp` (30 621 total):
- `eco.papExtend`: 27 238 (89 %)
- `scf.while`: 3 061 (10 %)
- (everything else): 322

`UseRejUnknownOp` (80 437 total):
- `eco.safepoint`: 66 126 (82 %)
- `eco.papExtend`: 8 305 (10 %)
- `scf.while`: 3 845 (5 %)
- `eco.construct.tuple2`: 668
- (tail): 1 493

### 7.3 Escape-analysis verdicts

| Counter | Value |
|---|---:|
| Constructs analysed | 30 910 |
| Tagged `escapes` | 30 908 (99.99 %) |
| Tagged `non_escaping` | 2 (0.006 %) |
| Specialise rewrites applied | 2 |

Per-kind escape causes (top): `eco.construct.list` 9 184, `eco.return` 7 415, `eco.call` 5 110, `func.return` 4 708, `eco.yield` 2 435, `eco.papExtend` 551.

### 7.4 Reboxing volume

Total `eco.to_heap` insertions across the pipeline:

| Source | Count |
|---|---:|
| `boxIfMismatched` (§5.1 stopgap) | 7 |
| `bridgeOperands` (agg → value at non-promoted call slot) | 2 |
| `EcoBoxAggregateOperands` — `construct.*` sink | 7 |
| `EcoBoxAggregateOperands` — `eco.call` sink | 7 |
| `EcoBoxAggregateOperands` — `func.call` sink | 0 |
| **Total** | **23** |

`bridgeOperands` also inserts 100 `eco.from_heap` ops in the opposite direction (value → aggregate, at promoted callees).

### 7.5 Heap-profile delta — `-enable-unboxed-agg` ON vs OFF (100 s workload)

| Metric | ON | OFF | Δ |
|---|---:|---:|---:|
| alloc_MB | 67 397.02 | 67 294.34 | **+102.68** |
| peak_commit_MB | 1 478.30 | 1 564.98 | −86.68 |
| final_live_MB | 621.90 | 731.78 | −109.88 |
| major_s | 2.30 | 2.69 | −0.39 |

`heap-profile.py diff` per-bucket attribution: the +102.68 MB alloc rate lives in **5.5 M extra small-object (16–64 B) allocations**, roughly split between nursery (+3.46 M / +129 MB) and oldgen (+2.08 M / +69 MB). String allocations unchanged.

### 7.6 Reading

The system as a whole runs correctly. Coverage is the limiting factor:

- **Cross-spec promotes a thin slice.** 4 741 producer accepts and 757 use accepts out of tens of thousands of candidates. The bulk of the optimization opportunity is missed at the gates, not lost to incorrect handling.
- **`eco.safepoint` is the single biggest unblock available.** 66 126 use-side rejections under one op kind, with a tractable change in scope (safepoint live-roots are independent of whether the value is `!eco.value` or aggregate-typed once RS4GC sees it). Listed as the top recommended next move.
- **The +103 MB regression has a clear shape and a clear non-cause.** Direct reboxing volume from the cross-spec path (23 `to_heap` insertions) is microscopic; the +5.5 M small-object delta is from IR-shape differences that propagate through later optimisation passes — likely a combination of the `eco.escape` attribute affecting later canonicalisation, the make.*-then-rebox dance for the 14 EcoBoxAggregateOperands sites, and differences in inlining / SROA decisions on the post-cross-spec IR. The §3.8 stopgap was originally suspected as the cause; it isn't (only 7 firings).
- **The big leverage points are coordination, not new ABI work.** The escape pass treats `eco.return` as an escape; cross-spec then promotes the same returns. Removing the duplicated decision (either delete escape's return-classification or delegate it to cross-spec) would reclassify ~12 k constructs in one change.

The infrastructure to land these next moves — counters, attribution, heap-profile diff — is all in tree. The structural correctness layer (Phases 0 through 3.3 + the FCA fixes) is stable. What remains is widening the eligibility decisions and closing the few gating items in §5.
