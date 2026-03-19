# Generic Apply & Staging-Agnostic Closure Model

**Status: IMPLEMENTED** (2026-03-18)

All infrastructure is in place. `CallGenericApply` is currently conservative
(set to `CallDirectKnownSegmentation` for all StageCurried calls). To activate
generic apply for specific callsites, update the `callKind` logic in
`computeCallInfo` to use closure kind analysis (`closureKind` field on CallInfo)
once ABI cloning populates it with `Heterogeneous` for mixed closure flows.

## Goal

Make all higher-order calls correct by:
1. Introducing a **generic apply** path that chains existing per-stage evaluators using closure headers at runtime
2. Adding `CallGenericApply` as a third call lowering strategy alongside `CallDirectFlat` and `CallDirectKnownSegmentation`
3. Keeping GlobalOpt staging + typed closure calling as optimizations; generic apply is the fallback

## Key Design Decisions (from Q&A)

1. **No flat evaluators.** Generic apply chains existing per-stage evaluators via closure headers. A function `f : A -> B -> C -> D` with staging [2,1] keeps its stage-1 evaluator (A,B)→closure and stage-2 evaluator (C)→D. Over-saturated calls saturate stage-1, get the stage-2 closure, then apply remaining args to it.

2. **No duplicate closures.** One `eco.papCreate` per stage per function. `arity` remains per-stage (not total logical arity). Both fast and generic paths interpret the header the same way. The difference is purely at the callsite: fast paths may call `$cap` directly; generic paths treat the callee as a closure and use `eco.papExtend` against its header.

3. **Generic apply always uses `$clo` clones** (typed generic clones), not legacy `void*[]` evaluator wrappers. The `evaluator` pointer in Closure is already the `$clo` clone. No legacy evaluators are reintroduced.

4. **`remaining_arity` absence = generic mode.** `eco.papExtend` without `remaining_arity` is generic apply; result type always `!eco.value`. CGEN_052/CGEN_056 only enforced when `remaining_arity` is present.

5. **`CallGenericApply` trigger criteria:**
   - Only for `callModel = StageCurried`
   - Closure kind is `Heterogeneous` or `Nothing` (unknown)
   - OR staging slot is in `dynamicSlots` (solver couldn't unify)

6. **`buildEvaluatorArgs` boxing bug is separate.** Will not block this work; can be fixed independently as ABI hygiene.

7. **GC safety** follows existing patterns: intermediate results stored in SSA values / C locals before further heap access.

---

## Current State

### Runtime (`runtime/src/allocator/Heap.hpp:215-222`)
```cpp
typedef struct {
    Header header;
    u64 n_values : 6;      // Number of captured values currently stored
    u64 max_values : 6;    // Maximum capacity for captured values
    u64 unboxed : 52;      // Bitmap: unboxed capture slots
    EvalFunction evaluator;
    Unboxable values[];
} Closure;
```

- `n_values` = count of entries in `values[]` (= args applied to this stage so far)
- `max_values` = total capacity = this stage's evaluator arity
- `remaining = max_values - n_values`

### Runtime helpers (`runtime/src/allocator/RuntimeExports.cpp`)
- `eco_apply_closure` (line 537): dispatch on `n_values + num_args` vs `max_values`; **asserts on over-saturated**
- `eco_pap_extend` (line 561): allocates new closure, copies old captures + new args, merges bitmaps
- `eco_closure_call_saturated` (line 615): builds `void**` arg array via `buildEvaluatorArgs`, calls evaluator
- `buildEvaluatorArgs` (line 509): boxes ALL unboxed captures via `eco_alloc_int` (even Float/Char — known quirk)

### Eco dialect (`runtime/src/codegen/Ops.td`)
- `eco.papCreate`: required attrs `arity`, `num_captured`, `unboxed_bitmap`; optional `_fast_evaluator`, `_closure_kind`
- `eco.papExtend`: required `remaining_arity` (compile-time); optional `_dispatch_mode`, `_fast_evaluator`, `_closure_kind`
- `remaining_arity` is **statically known**; EcoToLLVM checks `numNewArgs == remainingArity` at compile time

### EcoToLLVM (`runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`)
- `PapCreateOpLowering` (line 381): packs `numCaptured | (arity << 6) | (unboxed << 12)` at offset 8
- `PapExtendOpLowering` (line 821): static `isSaturated = (numNewArgs == remainingArity)`, then dispatches to fast/generic/inline paths
- Saturation is decided at **compile time**, never at runtime in the MLIR path

### GlobalOpt (`compiler/src/Compiler/GlobalOpt/`)
- `CallModel`: `FlattenedExternal | StageCurried`
- `CallInfo`: 7 fields including `stageArities`, `isSingleStageSaturated`, `initialRemaining`, `closureKind`, `captureAbi`
- Staging solver uses union-find to compute canonical segmentations; rewriter wraps non-conforming producers
- `StagingSolution` has `classSeg`, `producerClass`, `slotClass` — no concept of "unsolvable" slots

### MLIR codegen (`compiler/src/Compiler/Generate/MLIR/Expr.elm`)
- `generateCall` dispatches on `callInfo.callModel` → `FlattenedExternal` or `StageCurried`
- `StageCurried` further checks `isSingleStageSaturated` → saturated call or `generateClosureApplication`
- `applyByStages` emits `eco.papExtend` with statically known `remaining_arity`

---

## Implementation Plan

### Phase 1: Runtime — Over-Saturated Support

#### 1.1 Handle over-saturated calls in `eco_apply_closure`
**File:** `runtime/src/allocator/RuntimeExports.cpp` (line 537)
- Remove the `assert(false)` for over-saturated case
- Implement chained dispatch: saturate this stage, then recursively apply remaining args to the result
```cpp
// Over-saturated: saturate this stage, then apply remaining args to result closure
uint32_t remaining = max_values - n_values;
uint64_t intermediate = eco_closure_call_saturated(closure_hptr, args, remaining);
return eco_apply_closure(intermediate, args + remaining, num_args - remaining);
```
- The intermediate result is a new closure (next stage) with its own `n_values`/`max_values` header
- GC safety: `intermediate` is a local variable on the C stack, rooted before recursive call

#### 1.2 Update field comments (documentation only)
**File:** `runtime/src/allocator/Heap.hpp` (line 215)
- Add comments clarifying that `n_values`/`max_values` represent per-stage applied/total arity
- No field renames — preserve ABI stability
- Add a comment block explaining the staging-agnostic interpretation: generic apply chains stages by following headers

### Phase 2: Eco Dialect — Two-Mode `eco.papExtend`

#### 2.1 Make `remaining_arity` optional on `eco.papExtend`
**File:** `runtime/src/codegen/Ops.td` (line 894)
- Change `remaining_arity` from required `I64Attr` to `OptionalAttr<I64Attr>`
- Update description to document the two modes:
  - **Typed mode** (has `remaining_arity`): compile-time saturation, typed result, CGEN_052/056 enforced
  - **Generic mode** (no `remaining_arity`): runtime saturation via header, result always `!eco.value`

#### 2.2 Update verifier for two-mode papExtend
**File:** `runtime/src/codegen/EcoOps.cpp` (PapExtendOp::verify, line 373)
- When `remaining_arity` is present: keep all existing checks (definition-chain walk, CGEN_052 consistency, result type vs callee signature)
- When `remaining_arity` is absent (generic mode):
  - Skip definition-chain walk and arity consistency checks
  - Still verify `newargs_unboxed_bitmap` consistency with operand types
  - Still enforce REP_CLOSURE_001 (no Bool at closure boundary)
  - Verify result type is `!eco.value`

#### 2.3 No new ops or attributes needed
- Absence of `remaining_arity` is sufficient to distinguish generic from typed mode
- No `_is_generic_apply` attribute needed
- `_dispatch_mode`, `_fast_evaluator`, `_closure_kind` are only meaningful in typed mode; generic mode ignores them

### Phase 3: EcoToLLVM — Runtime Saturation Path

#### 3.1 Add runtime saturation path in `PapExtendOpLowering`
**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` (line 821)

When `remaining_arity` is **absent** (generic apply mode):

1. Load `packed` from closure header at offset 8 (ClosurePackedOffset)
2. Extract `n_values = packed & 0x3F`, `max_values = (packed >> 6) & 0x3F`
3. Compute `remaining = max_values - n_values`
4. Compare `numNewArgs` (static, from op's newargs count) against `remaining` (dynamic)
5. Generate three-way LLVM IR branch:

   **Under-saturated** (`numNewArgs < remaining`):
   - Call `eco_pap_extend(closure_hptr, args_array, numNewArgs, newargs_unboxed_bitmap)`
   - Result is new closure `!eco.value`

   **Exactly saturated** (`numNewArgs == remaining`):
   - Call `eco_closure_call_saturated(closure_hptr, args_array, numNewArgs)`
   - Result is the evaluator's return (may be next-stage closure or final value)
   - Always treat as `!eco.value` in generic mode

   **Over-saturated** (`numNewArgs > remaining`):
   - Call `eco_apply_closure(closure_hptr, args_array, numNewArgs)` (which now handles chaining)
   - Result is `!eco.value`

6. Merge three branches into a single `!eco.value` result via phi node

When `remaining_arity` is **present**: keep existing compile-time path completely unchanged (fast/generic/inline dispatch via `_dispatch_mode`).

#### 3.2 Generic apply uses `$clo` clones via runtime helpers
- `eco_closure_call_saturated` calls `closure->evaluator`, which is the `$clo` clone
- The `$clo` clone takes `(Closure*, P1..Pn)` with typed params — NOT the legacy `void*[]` convention
- **Important**: `buildEvaluatorArgs` currently boxes everything into `void**` for the legacy wrapper. For `$clo` clones, we need to either:
  - Keep using `buildEvaluatorArgs` if the `$clo` clone has been wrapped to accept `void**` (check current state)
  - Or adapt `eco_closure_call_saturated` to pass typed args directly to `$clo`
- **TODO**: Verify whether current `eco_closure_call_saturated` is already compatible with `$clo` clones or only with legacy wrappers

#### 3.3 Args array construction for runtime helpers
- In generic mode, `PapExtendOpLowering` must build a `uint64_t*` args array on the stack for the runtime helpers
- Each newarg: if unboxed (per bitmap), store raw bits; if boxed, store HPointer value
- This mirrors the existing unsaturated path's args array construction (lines 872-906)

### Phase 4: GlobalOpt — CallKind and Dynamic Slots

#### 4.1 Add `CallKind` to AST types
**File:** `compiler/src/Compiler/AST/Monomorphized.elm` (near line 1015)
```elm
type CallKind
    = CallDirectKnownSegmentation   -- staging known, use fast/generic clone
    | CallDirectFlat                -- flattened external/kernel
    | CallGenericApply              -- unknown staging, runtime dispatch
```
Add `callKind : CallKind` field to `CallInfo` (line 1037).
Update `defaultCallInfo` to use `CallGenericApply` as safe default.

#### 4.2 Extend `StagingSolution` with `dynamicSlots`
**File:** `compiler/src/Compiler/GlobalOpt/Staging/Types.elm`
```elm
type alias StagingSolution =
    { classSeg : Array (Maybe Segmentation)
    , producerClass : Dict String ClassId
    , slotClass : Dict String ClassId
    , dynamicSlots : Set String              -- NEW
    }
```

#### 4.3 Identify dynamic slots in the staging solver
**File:** `compiler/src/Compiler/GlobalOpt/Staging/Solver.elm`
Mark all slots in a class as dynamic when:
- The class contains producers of mixed call models (e.g. kernel + user closure)
- The class contains edges from unknown/unmodeled producers (FFI, separate compilation)
- The class has no majority segmentation (all producers disagree)
- **Note**: Classes where majority voting succeeds AND the rewriter can wrap non-conforming producers are NOT dynamic — the existing mechanism handles those

#### 4.4 Skip wrapping for dynamic slots in rewriter
**File:** `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm`
- Check `dynamicSlots` before attempting eta-wrapping
- For dynamic slots: leave the closure/function value as-is; do not enforce canonical segmentation
- For non-dynamic slots: existing wrapping behavior unchanged

#### 4.5 Compute `callKind` in `annotateCallStaging`
**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` (in `computeCallInfo`)
```elm
callKind =
    case callModel of
        FlattenedExternal ->
            CallDirectFlat

        StageCurried ->
            if closureKindIsKnown && slotNotDynamic then
                CallDirectKnownSegmentation
            else
                CallGenericApply
```
Where:
- `closureKindIsKnown` = `closureKind == Just (Known _)` (not Heterogeneous, not Nothing)
- `slotNotDynamic` = the callee's slot is not in `StagingSolution.dynamicSlots`

#### 4.6 Thread `dynamicSlots` through the pipeline
- `Staging.analyzeAndSolveStaging` returns `StagingSolution` (already does)
- Pass `dynamicSlots` from `StagingSolution` into `annotateCallStaging` context
- `computeCallInfo` receives it and consults it for `callKind` determination

### Phase 5: MLIR Codegen — Emit Generic Apply

#### 5.1 Add `generateGenericApply` in Expr.elm
**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`
```elm
generateGenericApply : CallInfo -> MlirValue -> List MlirValue -> MlirBuilder MlirValue
generateGenericApply callInfo callee args =
    -- Emit eco.papExtend WITHOUT remaining_arity (generic mode)
    -- Result type: !eco.value
    -- newargs_unboxed_bitmap: computed from SSA operand types per CGEN_003
    Ops.papExtend
        { closure = callee
        , newArgs = args
        , newargs_unboxed_bitmap = computeUnboxedBitmapFromOperandTypes args
        -- NO remaining_arity
        -- NO _dispatch_mode, _fast_evaluator, _closure_kind
        }
```

#### 5.2 Update `generateCall` dispatch
**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm` (line 1193)
Add third branch:
```elm
generateCall callInfo callee args =
    case callInfo.callKind of
        CallDirectFlat ->
            -- existing FlattenedExternal path
            ...

        CallDirectKnownSegmentation ->
            -- existing StageCurried path (applyByStages / generateSaturatedCall)
            ...

        CallGenericApply ->
            generateGenericApply callInfo callee args
```

**Important**: The existing dispatch on `callInfo.callModel` + `callInfo.isSingleStageSaturated` is subsumed by `callKind`. For backward compatibility during rollout:
- `CallDirectFlat` maps to the existing `FlattenedExternal` code path
- `CallDirectKnownSegmentation` maps to the existing `StageCurried` code path
- `CallGenericApply` is new

#### 5.3 Closure creation unchanged
- `eco.papCreate` continues to use per-stage `arity` (not total logical arity)
- The `function` attribute references the `$clo` clone as before
- Generic apply works because it follows closure headers stage-by-stage
- **No changes needed** to `Functions.elm` or `Lambdas.elm` for closure creation

#### 5.4 Callee must be a closure value
- For `CallGenericApply`, the callee must already be an `!eco.value` (closure pointer)
- If the callee is a known function symbol (not a closure), it needs to be wrapped in a zero-capture `eco.papCreate` first
- This already happens in the existing pipeline for function values used as closures

### Phase 6: Invariants & Tests

#### 6.1 Update invariants
**File:** `design_docs/invariants.csv`

Add:
- `RUNTIME_CLOSURE_003_UPDATED`: Remove the "over-saturated is a compiler bug" assertion. Over-saturated calls are handled by chaining: saturate current stage, then recursively apply remaining args to result closure.
- `CGEN_PAPEXTEND_GENERIC`: `eco.papExtend` without `remaining_arity` is generic apply mode. Result type must be `!eco.value`. CGEN_052/CGEN_056 do not apply. Saturation is determined at runtime from closure header.

Update:
- `CGEN_052`: Clarify this only applies when `remaining_arity` is present (typed mode)
- `CGEN_056`: Clarify this only applies when `remaining_arity` is present (typed mode)

#### 6.2 Add targeted E2E tests
Elm programs that exercise the generic apply path:
1. **Cross-module higher-order**: Pass closures between modules through `List.map`, `List.foldl`, etc.
2. **Over-saturated calls**: `(\f x y -> f x y 1)` where `f` has staging [2,1]
3. **Mixed partial applications**: Build PAPs in different places, combine via higher-order combinator
4. **Heterogeneous closure kinds**: Case/if branches producing closures with different staging, passed to same HOF
5. **Multi-stage chaining**: Apply 5 args to a function with staging [2,2,1] in one generic apply call

#### 6.3 Add MLIR-level checks
- Verify that `CallGenericApply` callsites emit `eco.papExtend` without `remaining_arity`
- Verify that `CallDirectKnownSegmentation` callsites still emit `eco.papExtend` with `remaining_arity`
- Check no regressions in existing typed closure calling tests

#### 6.4 Run full regression suite
```bash
cmake --build build --target check
cd compiler && npx elm-test-rs --fuzz 1
```

---

## Implementation Order

```
Phase 1 (Runtime)          Phase 2 (Dialect)
  1.1 over-sat support       2.1 optional remaining_arity
  1.2 doc comments            2.2 verifier update
         \                      /
          \                    /
           Phase 3 (EcoToLLVM)
             3.1 runtime saturation path
             3.2 $clo clone compatibility
             3.3 args array construction
                    |
           Phase 4 (GlobalOpt)
             4.1 CallKind type
             4.2 dynamicSlots in StagingSolution
             4.3 solver: identify dynamic slots
             4.4 rewriter: skip dynamic wrapping
             4.5 computeCallInfo: set callKind
             4.6 thread dynamicSlots
                    |
           Phase 5 (MLIR Codegen)
             5.1 generateGenericApply
             5.2 generateCall dispatch
             5.3 (no closure creation changes)
             5.4 callee wrapping
                    |
           Phase 6 (Invariants & Tests)
             6.1 invariant updates
             6.2-6.4 tests
```

Phases 1 and 2 can proceed in parallel. Phase 3 depends on both. Phase 4 is independent of 1-3 (pure Elm compiler changes). Phase 5 depends on 4 (needs `CallKind` in `CallInfo`). Phase 6 validates everything.

---

## Remaining TODOs Before Implementation

1. **Verify `eco_closure_call_saturated` compatibility with `$clo` clones** (Phase 3.2): The current runtime helper calls `closure->evaluator(combined_args)` with a `void**` array. But `$clo` clones expect `(Closure*, P1..Pn)` with typed params. Need to confirm whether the evaluator pointer in the closure is a `$clo` clone or a wrapper that bridges `void**` → typed params. If it's a wrapper, the runtime helpers already work. If it's the raw `$clo`, we need an adapter.

2. **Determine exact `dynamicSlots` trigger conditions** (Phase 4.3): The criteria listed are a starting point. During implementation, we need to trace through the staging solver to find the exact code points where a class fails to unify and mark those slots.

3. **Performance baseline**: Before starting, measure current test suite timing. After implementation, compare to ensure generic apply doesn't regress the common (fast path) cases.
