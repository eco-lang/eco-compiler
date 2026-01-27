# Fix Destructor Type Projection for Closure Arguments

## Problem Summary

When `Result.andThen half (Ok 42)` is executed:
1. The value `42` is extracted from `Ok` via `eco.project.custom` as `i64`
2. But then it's **boxed back to `!eco.value`** because the destructor's type variable maps to `!eco.value`
3. The boxed HPointer is passed to `papExtend` and stored in the closure
4. The wrapper passes the HPointer to `half(i64)`, which treats it as an integer → **wrong result**

## Root Cause (VERIFIED)

### Investigation Results

Debug output from `specializeDestructor`:
```
canType = TVar "value"
subst = { a -> Result String Int, b -> MInt, x -> MString }
monoType = MVar "value" CEcoValue  ← WRONG, should be MInt
```

**The problem**: The `canType` in the `TOpt.Destructor` is `TVar "value"` (from the Result type definition: `type Result error value = Ok value | Err error`), but the substitution map has type variables `a`, `b`, `x` (from the function signature: `andThen : (a -> Result x b) -> Result x a -> Result x b`).

### Type Variable Name Mismatch

The type flows as follows:
1. During canonicalization, `PatternCtorArg` stores the generic type from the constructor definition (`TVar "value"`)
2. During type inference, the type checker unifies types but uses variables from the function context (`a`, `b`, `x`)
3. During monomorphization, `TypeSubst.applySubst` looks up `"value"` in the substitution but only finds `"a"`, `"b"`, `"x"`
4. Since `"value"` is not in the substitution, it becomes `MVar "value" CEcoValue`
5. `monoTypeToAbi (MVar _ CEcoValue)` returns `!eco.value`, causing boxing

### Source of the Bug

**File**: `compiler/src/Compiler/Optimize/Typed/Expression.elm`
**Function**: `destructCtorArg` (lines 1263-1264)

```elm
destructCtorArg exprTypes ctorName path revDs (Can.PatternCtorArg index argType arg) =
    destructHelpWithType exprTypes Nothing (Just argType) ...
```

The function passes `argType` (the generic type from the constructor definition) instead of looking up the actual inferred type from `exprTypes`.

---

## Step-by-Step Implementation Plan

### Step 1: Fix `destructCtorArg` to Use Inferred Types

**File:** `compiler/src/Compiler/Optimize/Typed/Expression.elm`
**Location:** Lines 1263-1264

**Current code:**
```elm
destructCtorArg exprTypes ctorName path revDs (Can.PatternCtorArg index argType arg) =
    destructHelpWithType exprTypes Nothing (Just argType) (TOpt.Index index (TOpt.HintCustom ctorName) path) arg revDs
```

**New code:**
```elm
destructCtorArg exprTypes ctorName path revDs (Can.PatternCtorArg index _argType arg) =
    let
        patternId =
            (A.toValue arg).id

        actualType =
            case Dict.get identity patternId exprTypes of
                Just t ->
                    Just t

                Nothing ->
                    -- Pattern IDs from canonicalization must be in exprTypes.
                    -- If missing, this indicates a compiler bug in earlier phases.
                    Utils.Crash.crash
                        ("destructCtorArg: Pattern ID "
                            ++ String.fromInt patternId
                            ++ " not found in exprTypes for constructor "
                            ++ ctorName
                            ++ ". This is a compiler bug."
                        )
    in
    destructHelpWithType exprTypes Nothing actualType (TOpt.Index index (TOpt.HintCustom ctorName) path) arg revDs
```

**Rationale:**
- For non-synthetic patterns, `(A.toValue arg).id` is always ≥ 0 and present in `exprTypes` (existing invariant relied upon by `lookupPatternType`, `destruct`, and `toTypedExpr`)
- Do NOT fall back to `argType` on `Nothing` - that would silently mask inconsistencies and reintroduce the bug
- Crash explicitly with a descriptive message if the invariant is violated

### Step 2: Fix Singleton-Argument Constructor Case

**File:** `compiler/src/Compiler/Optimize/Typed/Expression.elm`
**Location:** In `destructHelpWithType`, the `Can.PCtor` case with singleton args

Find the code that looks like:
```elm
Can.PCtor { union, name, args } ->
    case args of
        [ Can.PatternCtorArg _ argType arg ] ->
            ... destructHelpWithType exprTypes Nothing (Just argType) ... arg ...
```

Apply the same fix: Look up the pattern's inferred type from `exprTypes` instead of using `argType` directly.

### Step 3: Audit and Clean Up `generateDestruct`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`
**Location:** `generateDestruct` function (lines 2276-2319)

**Current code uses `Mono.getMonoPathType path` as a workaround:**
```elm
generateDestruct ctx (Mono.MonoDestructor name path monoType) body _ =
    let
        pathResultType =
            Mono.getMonoPathType path  -- ← path-type workaround

        destructorMlirType =
            Types.monoTypeToAbi pathResultType
        ...
```

**After Steps 1 & 2 are complete**, update to use `monoType` directly:
```elm
generateDestruct ctx (Mono.MonoDestructor name path monoType) body _ =
    let
        -- The destructor's monoType is now reliably the correct field type
        -- after the fix to destructCtorArg ensures canType matches exprTypes.
        destructorMlirType =
            Types.monoTypeToAbi monoType

        targetType =
            destructorMlirType

        ( pathOps, pathVar, ctx1 ) =
            Patterns.generateMonoPath ctx path targetType

        ctx2 =
            Ctx.addVarMapping name pathVar targetType ctx1

        bodyResult =
            generateExpr ctx2 body
    in
    { ops = pathOps ++ bodyResult.ops
    , resultVar = bodyResult.resultVar
    , resultType = bodyResult.resultType
    , ctx = bodyResult.ctx
    , isTerminated = bodyResult.isTerminated
    }
```

Also remove the explanatory comment about type variable name mismatches since it will no longer be relevant.

### Step 4: Grep for Other Uses of `PatternCtorArg.argType`

**Command:**
```bash
cd compiler && grep -rn "PatternCtorArg" src/
```

**Purpose:** Verify no other layout-affecting sites use `argType` in a problematic way. Based on analysis, the only sensitive uses are in `destructHelpWithType` / `destructCtorArg`, but this confirms it.

### Step 5: Testing

```bash
# 1. Run the specific failing test
TEST_FILTER=elm-core/ResultAndThenTest cmake --build build --target check

# 2. Run full E2E test suite
cmake --build build --target check

# 3. Run Elm frontend tests
cd compiler && npx elm-test --fuzz 1
```

**Expected results:**
- `andThen1: Ok 21` (42 / 2 = 21)
- `andThen2: Err "odd"` (41 is odd)
- `andThen3: Err "original"` (Err case passes through)

---

## Implementation Order & Dependencies

```
Step 1: Fix destructCtorArg
    |
    v
Step 2: Fix singleton-arg constructor case (same file, same pattern)
    |
    v
Step 3: Clean up generateDestruct (depends on Steps 1 & 2 working)
    |
    v
Step 4: Grep verification (can be done in parallel with Step 3)
    |
    v
Step 5: Testing (after all code changes)
```

---

## Files to Modify

| File | Change |
|------|--------|
| `compiler/src/Compiler/Optimize/Typed/Expression.elm` | Fix `destructCtorArg` and singleton-arg case to use `exprTypes` |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Clean up `generateDestruct` to use `monoType` directly |

---

## Design Decisions

### Why Crash Instead of Falling Back to `argType`?

Given the invariants that pattern IDs from canonicalization are always in `exprTypes`:
- `lookupPatternType` assumes any `patId >= 0` must be present and crashes otherwise
- `destruct` uses `patternInfo.id` directly and will crash if missing
- `toTypedExpr` does the same for expression IDs

Hitting `Nothing` on a non-synthetic pattern means `exprTypes` is incomplete or out of sync - a compiler bug. Falling back to `argType` would:
1. Silently mask that inconsistency
2. Reintroduce the risk of using less-precise types for layout-sensitive decisions

### Why Update `generateDestruct` After the Fix?

The `MonoDestructor` type already carries the destructed value type as its `monoType`:
```elm
type MonoDestructor = MonoDestructor Name MonoPath MonoType
```

Once the fix guarantees that `canType` on `TOpt.Destructor` is always the correct field type, then `monoType` (from `TypeSubst.applySubst subst canType`) will be reliable. Using `monoType` directly is cleaner than the path-type workaround.

### Are There Other Affected Sites?

The only sensitive uses of `PatternCtorArg.argType` are in `destructHelpWithType` / `destructCtorArg`. Container layout and field unboxing decisions are handled later from `MonoType` and `CtorShape`/`CtorLayout` at monomorphization + MLIR codegen time, not from `Can.Type` alone.

---

## Risk Assessment

| Factor | Assessment |
|--------|------------|
| **Scope** | Low - changes localized to 2 files, 2-3 functions |
| **Complexity** | Low - conceptually simple: use inferred types instead of generic types |
| **Regression risk** | Low - existing test suite should catch issues; change aligns with existing invariants |
| **Invariant reliance** | Safe - relying on existing invariant that pattern IDs are in `exprTypes` |
