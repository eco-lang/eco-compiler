# Fix CEcoValue MVar Leakage & List Type Nesting Bug

## Problem Statement

Two distinct monomorphization bugs violate MONO_021, MONO_024, and MONO_025:

1. **CEcoValue MVars leaking into user function types** — When a specialization key is fully monomorphic, `MVar _ CEcoValue` can survive in lambda parameter/result types and `if`/control-flow result types. This happens when the substitution threading doesn't fully propagate concrete types into nested lambdas and local defs.

2. **List type constructor applied too many times** — For `filterMap` (and potentially other List-returning functions), the result type becomes `List List List Int` instead of `List Int`, indicating a double/triple wrapping bug somewhere in the type substitution pipeline.

## Current State Assessment

After thorough code inspection, the current implementation in `Specialize.elm` **already has the correct design** for problem (1):

- `specializeLambda` (lines 178–264) correctly uses `unifyExtend` to build `refinedSubst` and applies it to params and body
- `specializeFuncDefInCycle` (lines 561–616) correctly builds `augmentedSubst` and uses it for body specialization and `monoFuncType`
- `specializeDef` (lines 1766–1810) follows the same `augmentedSubst` pattern for local TailDef
- `TOpt.If` (lines 1022–1033) correctly uses `applySubst subst canType` for the result type
- `TOpt.Call` cases all use `unifyFuncCall` → `callSubst` correctly

For problem (2), `TypeSubst.applySubst` handles List correctly (wraps exactly once, lines 310–316), and `unifyHelp` handles `MList` correctly (lines 123–129). No double-wrapping vulnerability was found in the type substitution code itself.

**This means the bugs are likely in edge cases or interaction patterns, not in the main specialization functions.** The plan below focuses on identifying and fixing the specific failure paths.

---

## Investigation & Fix Plan

### Phase 1: Reproduce and Characterize Failures

**Goal:** Get concrete failing test output to pinpoint exact failure sites.

#### Step 1.1: Run the invariant test suite
- Run `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` and capture MONO_021, MONO_024, MONO_025 failures
- Record which test cases fail and what the violation messages say
- Categorize failures by type: (a) CEcoValue leak in lambda, (b) CEcoValue leak in if/control-flow, (c) List nesting bug

#### Step 1.2: Identify failing specialization keys
- From MONO_024 failures: note which fully-monomorphic keys still contain CEcoValue internally
- From MONO_025 failures: note which closures have type mismatches vs their keys
- Cross-reference with the source functions (identity, compose, filterMap, sign, conditional bitwise, etc.)

### Phase 2: Fix CEcoValue Leakage (MONO_021/024/025)

Based on the user's analysis and code review, the core specialization functions are already correct. The remaining leakage must come from one of these edge-case paths:

#### Step 2.1: Audit `augmentedSubst` in `specializeDef` for local TailDef

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`, lines 1766–1810

The current `specializeDef` for `TOpt.TailDef` builds `augmentedSubst` and specializes the body under it, but **does not compute or store a `monoFuncType`** — it produces `MonoTailDef name monoArgs monoExpr` without an explicit type.

Compare with `specializeFuncDefInCycle` which produces `MonoTailFunc monoArgs monoBody monoFuncType` (with explicit type from `augmentedSubst`).

**Fix:** The `MonoTailDef` constructor may not carry an explicit type (it's a local def within a let-binding), but verify that the enclosing Let logic correctly infers the type of the binding from the specialized expression. If the type is taken from the expression but the expression body was specialized under an incomplete substitution, the leakage would propagate.

**Action:** Check `MonoTailDef` and how its type is inferred/used downstream. If needed, ensure the substitution is propagated correctly.

#### Step 2.2: Audit `mergedSubst` in Let multi-specialization

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`, lines 1035–1160

The multi-specialization logic uses:
```elm
mergedSubst = Data.Map.union info.subst subst
```

`Data.Map.union` is left-biased — `info.subst` (call-site bindings) takes precedence over `subst` (outer scope bindings). This is correct when `info.subst` has more specific bindings. But verify:

- That `info.subst` is populated by `getOrCreateLocalInstance` with the `callSubst` from the call site
- That this `callSubst` was itself derived from `unifyFuncCall` which includes concrete argument types

**Action:** Trace through `getOrCreateLocalInstance` → `LocalMultiState` → `mergedSubst` → `specializeDef` → `specializeLambda` to confirm the full chain preserves concrete types. If `info.subst` is incomplete (e.g., missing bindings for type variables used inside lambda bodies), the leakage occurs.

#### Step 2.3: Check non-TVar param types in `augmentedSubst`

Both `specializeFuncDefInCycle` and `specializeDef` build `augmentedSubst` with:
```elm
case canParamType of
    Can.TVar varName ->
        Data.Map.insert identity varName monoParamType s
    _ ->
        s  -- Only augments for bare TVars
```

This only binds bare `TVar` params. If a param has type `List a` (a structured type containing a TVar), the `a` inside won't be added to the substitution. The outer `subst` should already have `a` bound, but if it doesn't (e.g., for a locally-defined recursive function whose type vars come from the function itself rather than the enclosing context), `a` would remain as `MVar "a" CEcoValue`.

**Action:** If this pattern is confirmed as a failure source, extend the augmentation to use `unifyExtend` (like `specializeLambda` does) instead of only handling bare `TVar`:
```elm
augmentedSubst =
    List.foldl
        (\((_, canParamType), (_, monoParamType)) s ->
            TypeSubst.unifyExtend canParamType monoParamType s
        )
        subst
        (List.map2 Tuple.pair args monoArgs)
```

This is the same pattern as `specializeLambda`'s `refinedSubst` and would correctly bind nested type variables.

#### Step 2.4: Verify `if` result types are resolved transitively

The `if` case uses `TypeSubst.applySubst subst canType`. If `subst` doesn't contain bindings for all type variables in `canType`, the result will contain `MVar _ CEcoValue`.

This is a transitive problem — if the enclosing lambda or function didn't properly propagate concrete types into `subst` (e.g., because `augmentedSubst` or `refinedSubst` is incomplete), then nested `if` expressions will leak.

**Action:** No code change needed in the `if` handler itself. Fixing the substitution construction in Steps 2.1–2.3 should resolve this transitively.

### Phase 3: Fix List Type Nesting Bug

#### Step 3.1: Add targeted debug logging for filterMap specialization

Temporarily instrument the monomorphization to log when specializing a node whose name contains "filterMap":
- Log the canonical type (`canType`)
- Log the substitution being applied
- Log the resulting `MonoType`

This will reveal exactly where the `List List List Int` type is constructed.

#### Step 3.2: Check canonical type annotations on filterMap implementation

The `filterMap` implementation in Elm core has type `(a -> Maybe b) -> List a -> List b`. When TypedOptimization processes it, the implementation may contain:
- A local helper that recurses over `List a` and builds `List b`
- Cons operations that construct the result list

If the canonical type annotation on a local helper or on the recursive result expression is incorrect (e.g., `List (List b)` instead of `List b`), the monomorphizer will faithfully produce `MList (MList ...)`.

**Action:** Inspect the TypedOptimized IR for `List.filterMap` to verify canonical types on all sub-expressions. This is likely a front-end / TypedOptimization bug, not a monomorphizer bug.

#### Step 3.3: Check alias expansion for List-related types

If there's a type alias like `type alias MyList a = List a`, and the alias isn't fully expanded before monomorphization, the alias layer could cause `applySubst` to process the List wrapping twice (once for the alias body, once for the inner List).

**Action:** In `TypeSubst.applySubst`, the `TAlias (Filled inner)` case directly recurses into `inner`. If `inner` is `TType ... "List" [TVar "a"]`, this produces `MList (applySubst subst (TVar "a"))` — correct. But check whether there's a case where the alias body is itself another alias, creating a chain that double-wraps.

#### Step 3.4: Check `unifyHelp` with `MList` nested in substitution

If the substitution already maps `a → MList MInt`, and the canonical type is `List a`, then:
- `applySubst subst (TType ... "List" [TVar "a"])` → `MList (applySubst subst (TVar "a"))` → `MList (MList MInt)`

This would produce `MList (MList MInt)` which is correct IF the original type variable `a` was indeed `List Int`. But if `a` was just `Int`, and the substitution incorrectly maps `a → MList MInt` instead of `a → MInt`, we get the nesting bug.

**Action:** This is the most likely root cause. Check whether the substitution for `filterMap`'s type variable `b` incorrectly wraps it in `MList` before the canonical `List b` wraps it again. This could happen if:
- `unifyFuncCall` sees the result type `List b` and binds `b → MList MInt` instead of `b → MInt`
- Or if a local helper's result type is `List b` and the unification with the expected `List Int` binds `b → List Int` instead of `b → Int`

Examine `unifyArgsOnly` to verify it correctly decomposes `List` types during unification.

### Phase 4: Implement & Verify

#### Step 4.1: Apply fixes from Phase 2 and 3
- Make targeted code changes as identified in the investigation
- Keep changes minimal and focused

#### Step 4.2: Run invariant tests
- Run `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1`
- Verify MONO_021, MONO_024, MONO_025 pass
- Verify no other invariant tests regress

#### Step 4.3: Run full E2E test suite
- Run `cmake --build build --target check`
- Verify no backend regressions

#### Step 4.4: Remove any temporary debug instrumentation

---

## Files Likely Modified

| File | Change |
|------|--------|
| `compiler/src/Compiler/Monomorphize/Specialize.elm` | Potentially extend `augmentedSubst` to use `unifyExtend` for structured param types (Step 2.3) |
| `compiler/src/Compiler/Monomorphize/TypeSubst.elm` | Potentially fix unification edge case for List types (Step 3.4) |
| Front-end / TypedOptimized code for `filterMap` | Fix canonical type annotations if found incorrect (Step 3.2) |

## Key Invariants to Satisfy

- **MONO_021**: No `MVar _ CEcoValue` in reachable user-defined function parameter/result positions
- **MONO_024**: For fully monomorphic specialization keys, no `MVar _ CEcoValue` anywhere in the expression tree
- **MONO_025**: Closure `MonoType` matches specialization key (flattened param/result types agree)

## Risk Assessment

- **Low risk for Step 2.3** (extending `augmentedSubst` to use `unifyExtend`): This is a strict generalization — currently only bare `TVar` params are augmented, the fix would also handle structured types containing TVars. The `unifyExtend` approach is already proven in `specializeLambda`.
- **Medium risk for Phase 3**: The List nesting bug may be in a different layer (TypedOptimization, canonical type annotations) rather than in the monomorphizer itself. Debugging requires inspecting intermediate IR.
- **Investigation-first approach**: Phase 1 (reproduction) is critical. The fixes in Phase 2 are largely confirmed by code review; Phase 3 requires empirical debugging to pinpoint the exact source.
