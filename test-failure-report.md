# Test Failure Report — Full Trace Evidence

**Date**: 2026-03-17

## Summary

| Suite | Passed | Failed |
|-------|--------|--------|
| Elm frontend (elm-test-rs) | 10,752 | 3 |
| E2E backend (cmake check) | 869 | 3 |

**6 total failures across 3 distinct bugs:**

| Bug ID | Frontend Failures | E2E Failures | Root Cause |
|--------|-------------------|--------------|------------|
| BUG-1: PapExtend arity | CGEN_052 x2, CGEN_056 x1 | PapExtendArityTest | `sourceArityForCallee` returns total arity instead of first-stage arity for function parameters |
| BUG-2: Saturated papExtend result type | — | PapSaturatePolyPipeMinimalTest | MonoInlineSimplify over-application preserves inner `CEcoValue` result type through `apR` inlining |
| BUG-3: Tail-rec SSA dominance | — | TailRecDeciderSearchTest | Sibling mapping SSA var from outer scope used inside separate `func.func` via leaked `varMappings` |

### Previously Fixed (no longer failing)

| Former Bug | Former Tests | Status |
|------------|-------------|--------|
| Bool closure capture (i1 in papCreate) | ClosureCaptureBoolTest | **FIXED** |
| Tail-rec Bool carry (i1 vs !eco.value) | TailRecBoolCarryTest | **FIXED** |
| Dbg type IDs (-1 sentinel) | CGEN_036 | **FIXED** (String now registered in type table) |

---

## BUG-1: PapExtend `remaining_arity` Mismatch for Multi-Stage Function Types

### Errors
- **Frontend (CGEN_052, Function expressions)**: `eco.papExtend remaining_arity=4 but source PAP has remaining=2`
- **Frontend (CGEN_052, Partial application type)**: `eco.papExtend remaining_arity=2 but source PAP has remaining=1`
- **Frontend (CGEN_056, Partial application type)**: `Saturated eco.papExtend result type !eco.value does not match func.func return type i64`
- **E2E (PapExtendArityTest)**: Runtime SIGABRT — `closure->n_values + num_newargs == max_values && "eco_closure_call_saturated: argument count mismatch"`

### Affected Tests
- **Elm-test**: CGEN_052 x2 (Function expressions, Partial application type), CGEN_056 x1 (Partial application type)
- **E2E**: `PapExtendArityTest.elm`

### Source Example 1 — E2E test (`PapExtendArityTest.elm`)

`/work/test/elm/src/PapExtendArityTest.elm`:
```elm
-- Multi-stage function: type is MFunction [Int] (MFunction [Int] Int), NOT MFunction [Int, Int] Int
curried : Int -> Int -> Int
curried x =
    \y -> x + y

-- f is a parameter NOT tracked in varSourceArity
applyPartial : (Int -> Int -> Int) -> Int -> (Int -> Int)
applyPartial f a =
    f a

-- Takes a binary function parameter, reorders args
flip : (a -> b -> c) -> b -> a -> c
flip f b a =
    f a b
```

**Why it fails:** `curried` is defined with an explicit return lambda, so after staging it has a multi-stage type: `MFunction [Int] (MFunction [Int] Int)` — two stages of arity 1 each. When `applyPartial` calls `f a`, the parameter `f` is a `MonoVarLocal`. Function parameters are never entered into `CallEnv.varSourceArity` (only `MonoDef` let-bindings are). So `sourceArityForExpr` returns `Nothing`, and the fallback `countTotalArityFromType` fires. That function recurses through all `MFunction` layers, returning `1 + 1 = 2` (total arity) instead of `1` (first-stage arity). The generated `papExtend` then claims `remaining_arity = 2`, but the actual PAP `%f` has `arity = 2, num_captured = 1`, so its real remaining is `1`. The same pattern appears in `flip f b a = f a b` — any higher-order function that receives a multi-stage closure as a parameter and calls it.

### Source Example 2 — CGEN_052 "Function expressions" (`chainedPartialApplicationCustom`)

Built programmatically in `tests/SourceIR/FunctionCases.elm`:
```elm
type Wrapper = Wrapper Int

f : Wrapper -> Int -> Int -> Wrapper
f a b c = a

p1 : Int -> Int -> Wrapper
p1 = f (Wrapper 42)

testValue : Int -> Wrapper
testValue = p1 2
```

**Why it fails:** `f` has type `Wrapper -> Int -> Int -> Wrapper`. After staging, this is a multi-stage function: `MFunction [Wrapper] (MFunction [Int] (MFunction [Int] Wrapper))` — three stages of arity 1 each, total arity 3. When `p1` calls `f (Wrapper 42)`, `f` is a known global so the arity is resolved correctly — `p1` is a PAP with `arity = 3, num_captured = 1`, remaining = 2. When `testValue` calls `p1 2`, `sourceArityForCallee` resolves `p1`'s arity via `countTotalArityFromType` on the result type `Int -> Int -> Wrapper` (i.e., `MFunction [Int] (MFunction [Int] Wrapper)`), which returns `1 + 1 = 2`. But `p1`'s actual PAP has `remaining = 2`, and we're applying 1 arg, so `remaining_arity` should be `2 - 1 = 1`. Instead, the emitted `papExtend` claims `remaining_arity = 4` (the source arity was computed as total of the original function's type). The invariant `remaining_arity = source_remaining - num_new_args` is violated.

### Source Example 3 — CGEN_052 + CGEN_056 "Partial application type" (`partialApplicationType`)

Built programmatically in `tests/SourceIR/PostSolveExprCases.elm`:
```elm
add : Int -> Int -> Int
add a b = a + b

add5 : Int -> Int
add5 = add 5

testValue : Int
testValue = add5 10
```

**Why it fails (CGEN_052):** `add` has type `Int -> Int -> Int`. With the explicit two-parameter definition, this is `MFunction [Int, Int] Int` — a single-stage function with arity 2. `add5 = add 5` creates a PAP: `arity = 2, num_captured = 1`, remaining = 1. When `testValue = add5 10` calls `add5`, `sourceArityForExpr` returns `Nothing` (the PAP expression isn't a simple var lookup into `CallEnv`), so it falls back to `countTotalArityFromType` on `MFunction [Int] Int` → returns 1. But `computeCallInfo` uses this as `initialRemaining = 2` because it's looking at the call model for `add5` as a local var with the full type `Int -> Int`. The emitted `papExtend` says `remaining_arity = 2` but the actual PAP only has `remaining = 1`. Invariant violated.

**Why it also fails (CGEN_056):** The incorrect `remaining_arity = 2` means the codegen thinks there's 1 arg remaining after this call (unsaturated), so it gives the result type `!eco.value` (a PAP/closure). But the call is actually saturated (the real remaining was 1, and we applied 1 arg), so the result should be `i64` — the return type of `add`'s `func.func`. The CGEN_056 check catches the mismatch: saturated `papExtend` result `!eco.value` ≠ `func.func` return type `i64`. In other words, CGEN_052 (wrong arity) and CGEN_056 (wrong result type) are two symptoms of the same root cause: the arity miscalculation cascades into an incorrect saturation determination, which then produces the wrong result type.

### MLIR Evidence

From `/work/test/elm/eco-stuff/mlir/PapExtendArityTest.mlir`:

**Pattern 1 — `applyPartial_$_4`**: Applies 1 arg to a multi-stage function parameter:
```mlir
^bb0(%f: !eco.value, %a: i64):
    %2 = "eco.papExtend"(%f, %a) {_operand_types = [!eco.value, i64],
         newargs_unboxed_bitmap = 1,
         remaining_arity = 2}                                        <- BUG: should be 1
         : (!eco.value, i64) -> !eco.value
```

The source PAP `%f` was created by `curried_$_1`:
```mlir
^bb0(%x: i64):
    %1 = "eco.papCreate"(%x) {_fast_evaluator = @PapExtendArityTest_lambda_6$cap,
         _operand_types = [i64], arity = 2,
         function = @PapExtendArityTest_lambda_6$clo,
         num_captured = 1, unboxed_bitmap = 1} : (i64) -> !eco.value
```
PAP has `remaining = arity - num_captured = 2 - 1 = 1`, but papExtend says `remaining_arity = 2`.

**Pattern 2 — `flip_$_2`**: Applies 2 args to a function parameter with remaining=1:
```mlir
^bb0(%f: !eco.value, %b: i64, %a: i64):
    %3 = "eco.papExtend"(%f, %a, %b) {_operand_types = [!eco.value, i64, i64],
         newargs_unboxed_bitmap = 3,
         remaining_arity = 2}                                        <- BUG: should be 1
         : (!eco.value, i64, i64) -> i64
```

**Runtime crash** at `/work/runtime/src/allocator/RuntimeExports.cpp:624`:
```cpp
assert(closure->n_values + num_newargs == max_values
       && "eco_closure_call_saturated: argument count mismatch");
```

### Source Code Trace

**`/work/compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`**:

1. **Lines 1488-1496** — `sourceArityForCallee`:
   ```elm
   sourceArityForCallee graph env funcExpr =
       case sourceArityForExpr graph env funcExpr of
           Just arity ->
               arity

           Nothing ->
               -- Fallback: use TOTAL arity for unknown callees (function parameters)
               -- Since they could be flattened externals, we must batch all args.
               countTotalArityFromType (Mono.typeOf funcExpr)            <- THE BUG
   ```

2. **Lines 1502-1508** — `countTotalArityFromType`:
   ```elm
   countTotalArityFromType monoType =
       case monoType of
           Mono.MFunction argTypes resultType ->
               List.length argTypes + countTotalArityFromType resultType  <- Sums ALL stages
           _ ->
               0
   ```
   For type `Int -> (Int -> Int)` (i.e., `MFunction [Int] (MFunction [Int] Int)`) this returns `1 + 1 = 2` instead of first-stage `1`.

3. **Lines 1417-1419** — `sourceArityForExpr` for `MonoVarLocal`:
   ```elm
   Mono.MonoVarLocal name _ ->
       -- Look up from CallEnv
       Dict.get name env.varSourceArity
   ```
   Function **parameters** like `f` in `applyPartial f a` are NOT tracked in `env.varSourceArity` (only `MonoDef` let-bindings are populated at lines 1237-1261). So `sourceArityForExpr` returns `Nothing`, and the fallback fires.

### Causation Chain
1. `f` is a function parameter with type `Int -> Int -> Int` (multi-stage: `MFunction [Int] (MFunction [Int] Int)`)
2. `sourceArityForExpr` returns `Nothing` for `MonoVarLocal "f"` (not in `varSourceArity`)
3. Fallback to `countTotalArityFromType` returns `2` (total arity across all stages) instead of `1` (first-stage arity)
4. `initialRemaining = sourceArity = 2` is used for the `papExtend`
5. MLIR emits `remaining_arity=2`, but the PAP's actual remaining arity is `1`
6. Runtime assertion fails: `closure->n_values + num_newargs != max_values`

### Invariants Violated
- **CGEN_052**: "papExtend remaining_arity must match the source PAP's actual remaining arity"
- **CGEN_056**: "Saturated papExtend result type must match the target function's return type" (downstream consequence of wrong arity)

---

## BUG-2: Saturated PapExtend Result Type Mismatch After `apR` Inlining

### Error
```
'eco.papExtend' op saturated papExtend result type '!eco.value' does not match function result type 'i64'
```

### Affected Tests
- **E2E**: `PapSaturatePolyPipeMinimalTest.elm`

### Source Example — E2E test (`PapSaturatePolyPipeMinimalTest.elm`)

`/work/test/elm/src/PapSaturatePolyPipeMinimalTest.elm`:
```elm
polyWithDefault : a -> Maybe a -> a
polyWithDefault default mx =
    mx |> Maybe.withDefault default     -- Pipe triggers apR inlining
```

Trigger conditions (ALL required):
1. Polymorphic function with type variable in result position
2. Pipe operator `|>` (desugars to `Basics.apR` call)
3. Right side of pipe is a partial application of a 2+ arg function

**Why it fails:** Three conditions conspire:

1. **Polymorphism**: `polyWithDefault` has type variable `a` in result position. When monomorphized at `a = Int`, the specialization of `apR` (which the pipe desugars to) was originally monomorphized with `b = CEcoValue` (the generic boxed type variable).
2. **Pipe operator**: `mx |> Maybe.withDefault default` desugars to `Basics.apR mx (Maybe.withDefault default)`. `MonoInlineSimplify` inlines `apR`'s body (`\x f -> f x`) into the call site, producing a new `MonoCall` where the inner expression is `Maybe.withDefault default` applied to `mx`.
3. **CEcoValue leak**: After inlining, the inner expression's type (from `Mono.typeOf body`) is still `MVar _ CEcoValue` — the polymorphic monomorphization never resolved `b` to `MInt` for this intermediate. The outer `MonoCall` inherits `resultType = CEcoValue` and gets `defaultCallInfo` (with `isSingleStageSaturated = False`).

When MLIR codegen processes the saturated `papExtend`, it derives the result type from this leaked `CEcoValue` → `!eco.value`, but `Maybe.withDefault`'s `func.func` actually returns `i64`. The MLIR verifier rejects the mismatch: saturated `papExtend` result `!eco.value` ≠ function return type `i64`.

Without the pipe (direct call `Maybe.withDefault default mx`), the inlining path is different and the type is correct. Without polymorphism (concrete `Int`), there's no `CEcoValue` to leak.

### MLIR Evidence

From `/work/test/elm/eco-stuff/mlir/PapSaturatePolyPipeMinimalTest.mlir`:

**`polyWithDefault_$_2`** — the inlined `apR` creates a papCreate + papExtend chain:
```mlir
^bb0(%default: i64, %mx: !eco.value):
    %4 = "eco.papCreate"() {arity = 2, function = @Maybe_withDefault_$_6,
         num_captured = 0, unboxed_bitmap = 0} : () -> !eco.value
    %3 = "eco.papExtend"(%4, %default) {_operand_types = [!eco.value, i64],
         newargs_unboxed_bitmap = 1, remaining_arity = 2}
         : (!eco.value, i64) -> !eco.value                           <- Partial (correct)
    %6 = "eco.papExtend"(%3, %mx) {_operand_types = [!eco.value, !eco.value],
         newargs_unboxed_bitmap = 0, remaining_arity = 1}
         : (!eco.value, !eco.value) -> !eco.value                    <- BUG: saturated, should be i64
    %7 = "eco.unbox"(%6) {_operand_types = [!eco.value]}
         : (!eco.value) -> i64
```

The second `papExtend` is **saturated** (`remaining_arity=1`, adding 1 arg fills the PAP). Its result type should match `Maybe_withDefault_$_6`'s return type:

```mlir
"func.func"() ({
    ^bb0(%default: i64, %maybe: !eco.value):
        ...
        "eco.return"(%7) {_operand_types = [i64]} : (i64) -> ()
}) {function_type = (i64, !eco.value) -> (i64),
    sym_name = "Maybe_withDefault_$_6"}                              <- Returns i64
```

The saturated papExtend should produce `i64`, not `!eco.value`.

### Source Code Trace

**`/work/compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`**:

1. **Lines 1498-1517** — Over-application inlining case (when `numArgs > numParams`):
   ```elm
   else if numArgs > numParams then
       let
           ( usedArgs, extraArgs ) =
               ( List.take numParams args, List.drop numParams args )

           ( bindings, ctx2 ) =
               createBindingsForInline ctx1 params usedArgs

           substituted =
               substituteAllForInline bindings remappedBody

           innerExpr =
               wrapInLetsForInline bindings substituted (Mono.typeOf body)
               --                                       ^^^^^^^^^^^^^^^^^
               -- Uses body's TYPE, which for apR is the polymorphic monomorphization
               -- result. When a=CEcoValue, this is CEcoValue (not MInt).

           inlined =
               MonoCall A.zero innerExpr extraArgs resultType Mono.defaultCallInfo
               --                                  ^^^^^^^^^^
               -- resultType inherited from the ORIGINAL call's result type (CEcoValue)
   ```

2. **`Mono.defaultCallInfo`** (`/work/compiler/src/Compiler/AST/Monomorphized.elm`):
   ```elm
   defaultCallInfo =
       { isSingleStageSaturated = False  -- No saturation metadata!
       , initialRemaining = 0
       , remainingStageArities = []
       , ... }
   ```

3. **`/work/compiler/src/Compiler/Generate/MLIR/Expr.elm`** — `applyByStages` result type logic:
   Since `defaultCallInfo.isSingleStageSaturated = False` and `initialRemaining = 0`, the codegen routes through `generateClosureApplication`, emitting papCreate + papExtend chain. The saturated papExtend's result type is derived from the `CEcoValue` result type → `!eco.value` instead of the target function's actual return type `i64`.

### Causation Chain
1. `mx |> Maybe.withDefault default` desugars to `Basics.apR mx (Maybe.withDefault default)`
2. `MonoInlineSimplify` inlines `apR`'s body (`f x` → `(Maybe.withDefault default) mx`)
3. The inner `MonoCall` body type is `CEcoValue` (from `apR`'s polymorphic monomorphization with `b = CEcoValue`)
4. New outer `MonoCall` gets `resultType = CEcoValue` and `defaultCallInfo` with `isSingleStageSaturated = False`
5. MLIR generation routes through `generateClosureApplication` (not saturated direct call)
6. `applyByStages` sees the final papExtend is saturated, but derives result type from `CEcoValue` → `!eco.value`
7. MLIR verifier rejects: saturated papExtend result `!eco.value` ≠ function return type `i64`

### Invariant Violated
- **CGEN_056**: "Saturated papExtend result type must match the target function's return type"

---

## BUG-3: Tail-Recursive Let-Binding SSA Dominance Violation

### Error
```
'eco.papExtend' op using value defined outside the region
```

### Affected Tests
- **E2E**: `TailRecDeciderSearchTest.elm`

### Source Example — E2E test (`TailRecDeciderSearchTest.elm`)

`/work/test/elm/src/TailRecDeciderSearchTest.elm`:
```elm
type Choice
    = Inline Int
    | Jump Int

type Decider
    = Leaf Choice
    | Chain Decider Decider

type Maybe_ a
    = Just_ a
    | Nothing_

search : Decider -> Maybe_ Int
search tree =
    let
        firstInlineExpr decider =
            case decider of
                Leaf choice ->
                    case choice of
                        Inline val -> Just_ val
                        Jump _ -> Nothing_

                Chain yes no ->
                    case firstInlineExpr yes of   -- NON-tail self-call
                        Just_ e -> Just_ e
                        Nothing_ ->
                            firstInlineExpr no    -- tail self-call
    in
    firstInlineExpr tree
```

**Why it fails:** `firstInlineExpr` is a let-bound function that the compiler identifies as tail-recursive (the `firstInlineExpr no` call is in tail position). It gets compiled as a `MonoTailDef`, which means it becomes a separate `func.func` with an `scf.while` loop.

The critical pattern is that `firstInlineExpr` also makes a **non-tail** recursive call to itself: `case firstInlineExpr yes of ...`. This call is inside the loop body, not in tail position.

Here's how the SSA dominance violation happens:

1. The outer function `search_$_5` creates a closure: `%1 = eco.papCreate(... @_tail_firstInlineExpr_31 ...)`. The SSA var `%1` lives in `search_$_5`'s scope.
2. When the compiler sets up `siblingMappings` for the let-rec group, it records `"firstInlineExpr" → {ssaVar = "%1"}` — pointing to the outer scope's `%1`.
3. When `generateLambdaFunc` compiles `_tail_firstInlineExpr_31` as a separate `func.func`, it merges `siblingMappings` into `varMappings`. Now inside this new function, the name `firstInlineExpr` resolves to `%1`.
4. In the `Chain` branch, the non-tail call `firstInlineExpr yes` looks up `firstInlineExpr` in `varMappings`, finds `{ssaVar = "%1"}`, and emits `eco.papExtend(%1, %30)`.
5. But `%1` was defined in `search_$_5`, not in `_tail_firstInlineExpr_31`. It doesn't exist in this `func.func`. The MLIR verifier rejects: `'eco.papExtend' op using value defined outside the region`.

The self-binding `firstInlineExpr` is explicitly excluded from the closure's captures (it's in `boundSet`), so there's no capture that would bring it into scope. The sibling mapping is the only way the name resolves, and it points to the wrong scope.

### MLIR Evidence

From `/work/test/elm/eco-stuff/mlir/TailRecDeciderSearchTest.mlir`:

**Outer function `search_$_5`** creates a closure for `firstInlineExpr`:
```mlir
"func.func"() ({
    ^bb0(%tree: !eco.value):
      %1 = "eco.papCreate"() {arity = 1,
           function = @_tail_firstInlineExpr_31,
           num_captured = 0, unboxed_bitmap = 0}
           : () -> !eco.value                                        <- %1 defined here
      %3 = "eco.papExtend"(%1, %tree) ...
      "eco.return"(%3) ...
}) {sym_name = "TailRecDeciderSearchTest_search_$_5"}
```

**Inner lambda `_tail_firstInlineExpr_31`** is a **separate `func.func`**:
```mlir
"func.func"() ({
    ^bb0(%decider: !eco.value):
      %3 = "arith.constant"() {value = false} : () -> i1            <- doneInitVar
      %4 = "eco.constant"() {kind = 1 : i32} : () -> !eco.value     <- resInitVar
      %5, %6, %7 = "scf.while"(%decider, %3, %4) ({
          ...  -- before-region
      }, {
          ^bb0(%13: !eco.value, %14: i1, %15: !eco.value):
            ...
            -- Chain branch: non-tail recursive call to self
            %34 = "eco.papExtend"(%1, %30) {...}                     <- BUG: %1 NOT DEFINED HERE
            ...
      })
}) {sym_name = "_tail_firstInlineExpr_31"}
```

**`%1` does not exist** inside `_tail_firstInlineExpr_31`. It was defined in `search_$_5` as the `eco.papCreate` result. The reference leaked through `siblingMappings`.

### Source Code Trace

**`/work/compiler/src/Compiler/Generate/MLIR/Lambdas.elm`** — `generateLambdaFunc`:

1. **Lines 147-153** — Sibling mapping resolution and nextVar calculation:
   ```elm
   maxSiblingIndex =
       lambda.siblingMappings
           |> Dict.values
           |> List.filterMap (\info -> parseNumericIndex info.ssaVar)
           |> List.maximum
           |> Maybe.withDefault -1

   nextVarBase =
       List.maximum [ ctx.nextVar, List.length allArgPairs, maxSiblingIndex + 1 ]
           |> Maybe.withDefault 0
   ```
   This ensures `nextVar` is past sibling indices (so no SSA number collision). However...

2. **Lines 157-161** — Sibling mappings merged into varMappings:
   ```elm
   varMappingsWithSiblings =
       Dict.union varMappingsWithArgs lambda.siblingMappings
       -- siblingMappings: "firstInlineExpr" -> {ssaVar="%1", mlirType=!eco.value}
   ```
   The sibling mapping for `firstInlineExpr` points to `%1`, which is the SSA var from the **outer** function's scope. When the lambda body references `firstInlineExpr` (the non-tail self-call), it resolves to `%1` — but `%1` doesn't exist in this `func.func`.

3. **The non-tail recursive self-call** — Inside the `Chain` branch, `firstInlineExpr yes` is a non-tail call. The codegen looks up `firstInlineExpr` in `varMappings`, finds the sibling mapping `{ssaVar="%1", mlirType=!eco.value}`, and emits `eco.papExtend(%1, %30)`. But `%1` is only valid in `search_$_5`, not in `_tail_firstInlineExpr_31`.

### Causation Chain
1. `search` contains a let-binding `firstInlineExpr` which is tail-recursive (compiled as `MonoTailDef`)
2. The Elm compiler generates `firstInlineExpr` as a separate lambda (separate `func.func`)
3. `search_$_5` allocates `%1 = eco.papCreate(... @_tail_firstInlineExpr_31 ...)` in its scope
4. `siblingMappings` records `"firstInlineExpr" -> {ssaVar="%1"}` — pointing to the outer scope's `%1`
5. When compiling `_tail_firstInlineExpr_31`, `siblingMappings` is merged into `varMappings`
6. Inside the `Chain` branch, the non-tail call `firstInlineExpr yes` resolves to `%1`
7. `eco.papExtend(%1, %30)` is emitted, but `%1` doesn't exist in this `func.func`
8. MLIR verifier rejects: `'eco.papExtend' op using value defined outside the region`

**Note**: The `nextVar` collision was fixed (sibling indices are now accounted for), but the fundamental issue remains: sibling mappings point to SSA vars in a **different function's scope**, and non-tail recursive self-calls emit references to those out-of-scope vars.

### The Deeper Issue

For tail-recursive let-bound functions that self-reference non-tail-recursively, the codegen needs a way to call itself that doesn't rely on the outer scope's SSA var. Options:
1. Emit a fresh `eco.papCreate` inside the lambda itself (duplicating the closure creation)
2. Pass the closure as an additional capture/parameter
3. Detect this pattern and generate the self-call differently (e.g., direct `eco.call` instead of `papExtend`)

---

## Root Cause Groupings

### Group A: Arity/Type Propagation in GlobalOpt (BUG-1, BUG-2)

Both involve incorrect metadata surviving through optimization passes into MLIR codegen:

| Issue | Where | Wrong Value | Correct Value |
|-------|-------|-------------|---------------|
| `remaining_arity` | `MonoGlobalOptimize.elm:1488-1496` `sourceArityForCallee` | Total arity (all stages) | First-stage arity |
| Result type | `MonoInlineSimplify.elm:1498-1517` over-application inlining | `CEcoValue` from inner call | Concrete type from call site |

**Common theme**: Function parameters (not tracked in `varSourceArity`) trigger fallback paths that use imprecise type/arity information.

### Group B: SSA Scope Leakage in Tail-Rec Lambdas (BUG-3)

Sibling mappings carry SSA vars from the outer function scope into a separate `func.func`. This is correct for non-tail-recursive lambdas (where sibling refs are used for `eco.call` within the same function), but breaks when the lambda is compiled to its own `func.func` as a tail-recursive function.

**Key difference from previously-fixed bugs**: This is NOT an SSA number collision (the `nextVar` fix addressed that). This is a **scope escape** — the SSA var `%1` physically does not exist in the target function.
