# Fix papExtend remaining_arity for MonoLet-wrapped callees

## 1. Problem Recap

We're seeing CGEN_052 failures of the form:
> `eco.papExtend remaining_arity = 1 but source PAP has remaining = 3`

for patterns like:
```elm
testValue =
    let
        compose = \f g x -> f (g x)
    in
    compose  -- returned as a value, not applied
```

and similar let‑bound multi‑arg lambdas. The trace shows:
- GlobalOpt wraps the let‑bound value in a closure, but the **MonoLet's type remains curried** (e.g. `MFunction [CEcoValue] (MFunction [CEcoValue] (MFunction [CEcoValue] CEcoValue))`).
- Later, `annotateCallStaging` computes `CallInfo` for a call whose callee is a `MonoLet` expression. It tries to get the source arity via `sourceArityForExpr`.
- `sourceArityForExpr` does **not** handle `MonoLet`, so it returns `Nothing`.
- `sourceArityForCallee` falls back to a type‑based arity from `Mono.typeOf funcExpr`. Even though in this repo that fallback is already using **first‑stage** arity instead of total, it's still looking at the stale **curried** MonoLet type, so it sees only 1 param instead of the closure's true param count.
- This incorrect `sourceArity` is used as `callInfo.initialRemaining`, and MLIR codegen then emits `eco.papExtend remaining_arity = 1` while the actual PAP has remaining = 3, violating CGEN_052.

The key: **Call analysis can't see through `MonoLet` aliases to the underlying closure**, so it guesses from type instead of using the real closure arity.

---

## 2. High‑Level Fix

### Goal

Make `sourceArityForExpr` correctly resolve the **source arity** (PAP creation arity) for expressions wrapped in `MonoLet`, so that:
- For a let alias of a closure (or other function value), we reuse the alias's `varSourceArity` in the `CallEnv`, and
- Calls whose callee is a `MonoLet` resolve to the **closure's actual param count**, not a type‑based approximation on a stale curried type.

### Strategy

1. **Extend `sourceArityForExpr`** to handle `Mono.MonoLet`. For a `MonoLet def body _`, we:
   - Run `annotateDefCalls` on `def` to update the `CallEnv` with that binding's source arity.
   - Recurse into `body` with this extended env and return whatever `sourceArityForExpr` gives there.
2. Leave all MLIR codegen logic (`Expr.applyByStages`, `generateClosureApplication`, etc.) unchanged; they already use `CallInfo.initialRemaining` to set `remaining_arity`.
3. Rely on the already‑corrected fallback in `sourceArityForCallee`, which uses **first‑stage arity from type** rather than total arity, for truly unknown callees (function parameters, etc.).

This is the "surgical fix" formalized.

---

## 3. Detailed Code Changes

### 3.1. Add `MonoLet` Handling to `sourceArityForExpr`

**File:**
`compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

Find the definition of `sourceArityForExpr` (line ~1410). Insert a `Mono.MonoLet` case **before** the `_ -> Nothing` wildcard:

```elm
        -- NEW: handle let-bound aliases by extending CallEnv, then recursing
        Mono.MonoLet def body _ ->
            let
                ( _, env1 ) =
                    annotateDefCalls graph env def
            in
            sourceArityForExpr graph env1 body
```

**Why this works:**
- `annotateDefCalls` already encapsulates the logic to derive `varSourceArity` and `varCallModel` from a `MonoDef` (it runs `annotateExprCalls` on the bound expression, then populates the environment with the resulting call model and source arity).
- A very common wrapper pattern is exactly:
  ```elm
  MonoLet (Mono.MonoDef "f" (Mono.MonoClosure info body closureType))
          (Mono.MonoVarLocal "f" closureType)
          closureType
  ```
  After we run `( _, env1 ) = annotateDefCalls graph env def`, `env1.varSourceArity["f"]` is set to `List.length info.params`. Then recursive `sourceArityForExpr graph env1 body` hits the `Mono.MonoVarLocal` branch and returns that arity.
- This means we now recover the true **closure param count** for let‑aliases, even if the `MonoLet` type annotation is still curried.

### 3.2. Confirm `sourceArityForCallee` Uses First‑Stage Fallback

In this repo the fallback is already correct:
```elm
sourceArityForCallee graph env funcExpr =
    case sourceArityForExpr graph env funcExpr of
        Just arity ->
            arity

        Nothing ->
            firstStageArityFromType (Mono.typeOf funcExpr)
```

and:
```elm
firstStageArityFromType monoType =
    case monoType of
        Mono.MFunction argTypes _ ->
            List.length argTypes

        _ ->
            0
```

No changes needed here. The new MonoLet case ensures we only hit this fallback when we truly have no better information (genuinely unknown callees like function parameters).

---

## 4. How This Fix Addresses the Compose / Let‑Bound Lambda Bug

Consider the problematic pattern:
```elm
testValue =
    let
        compose = \f g x -> f (g x)
    in
    compose
```

After monomorphization + GlobalOpt staging:
- `compose` is a `MonoClosure` with `params = [f, g, x]` and a flattened type `MFunction [CEcoValue, CEcoValue, CEcoValue] CEcoValue`.
- The expression bound to `testValue` is something like:
  ```elm
  Mono.MonoLet
      (Mono.MonoDef "compose" (Mono.MonoClosure info body closureType))
      (Mono.MonoVarLocal "compose" closureType)
      closureType
  ```

When `annotateExprCalls` later analyzes a call site where this `testValue` closure is invoked, and we invoke:
```elm
sourceArityForCallee graph env (MonoLet def (MonoVarLocal "compose" _) _)
```

the flow is now:
1. `sourceArityForCallee` calls `sourceArityForExpr graph env expr`.
2. `sourceArityForExpr` matches the **new** `Mono.MonoLet` case:
   - Runs `annotateDefCalls graph env def`, which:
     - Recursively annotates `Mono.MonoClosure info body closureType`.
     - Derives `maybeSourceArity = Just (List.length info.params) = Just 3`.
     - Inserts `"compose" -> 3` into `env1.varSourceArity`.
   - Recurses into the body `Mono.MonoVarLocal "compose" closureType` with `env1`.
3. In the recursive call, `sourceArityForExpr graph env1 (MonoVarLocal "compose" _)` returns `Dict.get "compose" env1.varSourceArity = Just 3`.
4. `sourceArityForCallee` receives `Just 3` and uses `sourceArity = 3` as `initialRemaining`.
5. MLIR codegen receives `CallInfo.initialRemaining = 3`, and `applyByStages` emits:
   ```mlir
   "eco.papExtend"(%compose, %arg0) { remaining_arity = 3, ... }
   ```

which now matches the PAP created with `arity=3, num_captured=0` → remaining = 3, satisfying CGEN_052.

---

## 5. Testing Plan

### 5.1. Existing MLIR‑level tests

The test suite already checks CGEN_052:
- **Invariant:** `eco.papExtend remaining_arity matches source PAP remaining` (CGEN_052).
- Tests: `compiler/tests/TestLogic/Generate/CodeGen/PapExtendArityTest.elm` and related function‑expression tests. These include patterns like:
  - Let‑bound multi‑arg closures returned as values (`compose`, `flip`, tuple constructors, etc.).
  - Partial applications of let‑bound multi‑arg functions.

After applying the code change above, re‑run:

```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

Expected behavior:
- The 2 existing CGEN_052 failures ("Compose functions", "Multiple pattern types in one function") should now pass.
- The 4 additional CGEN_052-triggering tests added recently (twoArgLambdaAsValue, fourArgLambdaAsValue, multiArgLambdaPartiallyApplied, flipAsLambdaValue) should also pass — these were masked by bulkCheck early-exit but exhibit the same bug.

Then run E2E tests:
```bash
cmake --build build --target check
```

Expected behavior:
- No more runtime aborts from `eco_closure_call_saturated: argument count mismatch` for patterns caused by this bug.

### 5.2. Test cases that exhibit the bug (for regression)

These are the test cases in SourceIR that trigger CGEN_052 violations:

| Test File | Label | Arity | Error |
|-----------|-------|-------|-------|
| `EdgeCaseCases.elm` | Multiple pattern types in one function | 5 | remaining_arity=1 but PAP has 5 |
| `FunctionCases.elm` | Compose functions | 3 | remaining_arity=1 but PAP has 3 |
| `FunctionCases.elm` | Two-arg lambda as value | 2 | remaining_arity=1 but PAP has 2 |
| `FunctionCases.elm` | Four-arg lambda as value | 4 | remaining_arity=1 but PAP has 4 |
| `FunctionCases.elm` | Multi-arg lambda partially applied | 3→2 | remaining_arity=1 but PAP has 2 |
| `FunctionCases.elm` | Flip as lambda value | 3 | remaining_arity=1 but PAP has 3 |

All share the same root cause pattern: `define "name" [] (lambdaExpr [args...] body)` — a multi-arg lambda bound to a let-variable.

---

## 6. Summary

- **Root cause:** `sourceArityForExpr` did not handle `MonoLet`, so calls whose callee was a let‑wrapped closure lost the real source arity and fell back to a type‑based approximation on a stale curried type, producing wrong `papExtend.remaining_arity`.
- **Fix:** In `MonoGlobalOptimize.elm`, add a `Mono.MonoLet` branch to `sourceArityForExpr` that:
  - Uses `annotateDefCalls` to enrich the `CallEnv` with the let‑bound definition's source arity.
  - Recurses into the body using that enriched env.
- **Impact:** `sourceArityForCallee` now recovers the correct closure param count for let‑aliases; MLIR codegen for `eco.papExtend` uses the correct `remaining_arity`, restoring CGEN_052 (and downstream CGEN_056) invariants for patterns like let‑bound `compose`, `flip`, and other multi‑arg lambdas.
