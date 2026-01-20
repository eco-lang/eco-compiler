# Plan: Fix Nested Case Terminators

## Problem Summary

When generating MLIR for nested case expressions (a case inside another case's branch), the inner `eco.case` operation appears as a block terminator instead of a proper terminator (`eco.return`, `eco.jump`, or `eco.crash`).

**Error Pattern:**
```
region N entry block terminator 'eco.case' is not a valid terminator
Branch 1 entry terminates with 'eco.case', expected eco.return, eco.jump, or eco.crash
```

**Failing Tests:** 14 total (7 in BlockTerminatorTest, 7 in CaseTerminationTest)
- Case on tuple with literal patterns
- List pattern with fallback
- Tuple with literals
- Deeply nested constructor
- Multiple fallbacks
- Overlapping patterns
- Case with nested patterns type

## Root Cause Analysis

### The Problem

The `mkRegionFromOps` function (Expr.elm:2230-2243) takes the last operation from an ops list and uses it as the region's terminator:

```elm
mkRegionFromOps ops =
    case List.reverse ops of
        [] -> ...
        terminator :: restReversed ->
            MlirRegion
                { entry = { args = [], body = List.reverse restReversed, terminator = terminator }
                , blocks = OrderedDict.empty
                }
```

When `generateDecider` is called recursively for a nested case, it returns ops ending with an `eco.case` operation (not `eco.return`). The callers pass these ops directly to `mkRegionFromOps`, which then treats `eco.case` as the terminator—but `eco.case` is not a valid MLIR region terminator.

### The Control Flow

1. `generateFanOutGeneral` calls `generateDecider` for each edge's subtree
2. `generateDecider` may recurse and generate another `eco.case` for nested patterns
3. The result is ops ending in `eco.case`
4. `mkRegionFromOps` uses that `eco.case` as the terminator
5. MLIR verifier rejects this because `eco.case` is not a valid terminator

### Valid Terminators

Valid MLIR region terminators for our dialect:
- `eco.return` - normal return from region
- `eco.jump` - tail-recursive jump to joinpoint
- `eco.crash` - program crash/unreachable
- `eco.unreachable` - (used as default)

## Solution

Create a helper function `mkCaseRegionFromDecider` that checks if the last operation is a valid terminator. If not, it appends a dummy `eco.return` operation before calling `mkRegionFromOps`.

### Helper: isValidTerminator

Check if an operation is a valid region terminator:

```elm
isValidTerminator : MlirOp -> Bool
isValidTerminator op =
    List.member op.name [ "eco.return", "eco.jump", "eco.crash", "eco.unreachable" ]
```

### Helper: mkCaseRegionFromDecider

```elm
{-| Create a region from decider ops, ensuring it ends with a valid terminator.

When generateDecider produces ops ending with eco.case (nested case), we need
to append a dummy eco.return to satisfy MLIR's terminator requirement.
-}
mkCaseRegionFromDecider : Ctx.Context -> List MlirOp -> MlirType -> ( MlirRegion, Ctx.Context )
mkCaseRegionFromDecider ctx ops resultTy =
    case List.reverse ops of
        [] ->
            -- Empty ops - return default region with unreachable
            ( mkRegionFromOps [], ctx )

        lastOp :: _ ->
            if isValidTerminator lastOp then
                -- Already has valid terminator, use as-is
                ( mkRegionFromOps ops, ctx )

            else
                -- Last op is not a terminator (e.g., eco.case)
                -- Append dummy value + eco.return
                let
                    ( dummyOps, dummyVar, ctx1 ) =
                        createDummyValue ctx resultTy

                    ( ctx2, returnOp ) =
                        Ops.ecoReturn ctx1 dummyVar resultTy
                in
                ( mkRegionFromOps (ops ++ dummyOps ++ [ returnOp ]), ctx2 )
```

## Implementation Steps

### Step 1: Add `isValidTerminator` helper

**Location:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`
**Insert after:** `defaultTerminator` function (around line 2259)

```elm
{-| Check if an operation is a valid region terminator.
-}
isValidTerminator : MlirOp -> Bool
isValidTerminator op =
    List.member op.name [ "eco.return", "eco.jump", "eco.crash", "eco.unreachable" ]
```

### Step 2: Add `mkCaseRegionFromDecider` helper

**Location:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`
**Insert after:** `isValidTerminator` function

```elm
{-| Create a region from decider ops, ensuring it ends with a valid terminator.

When generateDecider produces ops ending with eco.case (nested case), we need
to append a dummy eco.return to satisfy MLIR's terminator requirement.
The dummy return is unreachable at runtime (eco.case branches always exit
via their own returns), but satisfies the MLIR structure requirement.
-}
mkCaseRegionFromDecider : Ctx.Context -> List MlirOp -> MlirType -> ( MlirRegion, Ctx.Context )
mkCaseRegionFromDecider ctx ops resultTy =
    case List.reverse ops of
        [] ->
            ( mkRegionFromOps [], ctx )

        lastOp :: _ ->
            if isValidTerminator lastOp then
                ( mkRegionFromOps ops, ctx )

            else
                let
                    ( dummyOps, dummyVar, ctx1 ) =
                        createDummyValue ctx resultTy

                    ( ctx2, returnOp ) =
                        Ops.ecoReturn ctx1 dummyVar resultTy
                in
                ( mkRegionFromOps (ops ++ dummyOps ++ [ returnOp ]), ctx2 )
```

### Step 3: Update `generateBoolFanOut` (lines 2087-2124)

**Change:** Replace direct `mkRegionFromOps` calls with `mkCaseRegionFromDecider`

**Current:**
```elm
thenRegion =
    mkRegionFromOps thenRes.ops
...
elseRegion =
    mkRegionFromOps elseRes.ops
```

**Fixed:**
```elm
( thenRegion, ctx1a ) =
    mkCaseRegionFromDecider thenRes.ctx thenRes.ops resultTy
...
ctxForElse =
    { ctx1 | nextVar = ctx1a.nextVar }
...
( elseRegion, ctx1b ) =
    mkCaseRegionFromDecider elseRes.ctx elseRes.ops resultTy
```

**Note:** The context threading must be updated to pass through the new helper.

### Step 4: Update `generateChainForBoolADT` (lines 1980-2012)

**Change:** Same pattern as `generateBoolFanOut`

**Fixed:**
```elm
( thenRegion, ctx1a ) =
    mkCaseRegionFromDecider thenRes.ctx thenRes.ops resultTy

ctxForElse =
    { ctx1 | nextVar = ctx1a.nextVar }

elseRes =
    generateDecider ctxForElse root failure resultTy

( elseRegion, ctx1b ) =
    mkCaseRegionFromDecider elseRes.ctx elseRes.ops resultTy

( ctx2, caseOp ) =
    Ops.ecoCase ctx1b boolVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] [ resultTy ]
```

### Step 5: Update `generateChainGeneral` (lines 2019-2051)

**Change:** Same pattern as above

**Fixed:**
```elm
( thenRegion, ctx1a ) =
    mkCaseRegionFromDecider thenRes.ctx thenRes.ops resultTy

ctxForElse =
    { ctx1 | nextVar = ctx1a.nextVar }

elseRes =
    generateDecider ctxForElse root failure resultTy

( elseRegion, ctx1b ) =
    mkCaseRegionFromDecider elseRes.ctx elseRes.ops resultTy

( ctx2, caseOp ) =
    Ops.ecoCase ctx1b condVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] [ resultTy ]
```

### Step 6: Update `generateFanOutGeneral` (lines 2154-2224)

**Change:** Update the fold to thread context through `mkCaseRegionFromDecider`

**Current:**
```elm
( edgeRegions, ctx2 ) =
    List.foldl
        (\( _, subTree ) ( accRegions, accCtx ) ->
            let
                subRes =
                    generateDecider accCtx root subTree resultTy

                region =
                    mkRegionFromOps subRes.ops
            in
            ( accRegions ++ [ region ], subRes.ctx )
        )
        ( [], ctx1 )
        edges

fallbackRes =
    generateDecider ctx2 root fallback resultTy

fallbackRegion =
    mkRegionFromOps fallbackRes.ops
```

**Fixed:**
```elm
( edgeRegions, ctx2 ) =
    List.foldl
        (\( _, subTree ) ( accRegions, accCtx ) ->
            let
                subRes =
                    generateDecider accCtx root subTree resultTy

                ( region, ctxAfterRegion ) =
                    mkCaseRegionFromDecider subRes.ctx subRes.ops resultTy
            in
            ( accRegions ++ [ region ], ctxAfterRegion )
        )
        ( [], ctx1 )
        edges

fallbackRes =
    generateDecider ctx2 root fallback resultTy

( fallbackRegion, ctx2a ) =
    mkCaseRegionFromDecider fallbackRes.ctx fallbackRes.ops resultTy

( ctx3, caseOp ) =
    Ops.ecoCase ctx2a scrutineeVar Types.ecoValue caseKind tags allRegions [ resultTy ]
```

## Files to Modify

| File | Changes |
|------|---------|
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Add `isValidTerminator` helper |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Add `mkCaseRegionFromDecider` helper |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Update `generateBoolFanOut` |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Update `generateChainForBoolADT` |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Update `generateChainGeneral` |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Update `generateFanOutGeneral` |

## Test Commands

```bash
# Run specific failing test files
cd compiler
timeout 5 npx elm-test --fuzz 1 tests/Compiler/Generate/CodeGen/BlockTerminatorTest.elm
timeout 5 npx elm-test --fuzz 1 tests/Compiler/Generate/CodeGen/CaseTerminationTest.elm

# Run all CodeGen tests to ensure no regressions
timeout 60 npx elm-test --fuzz 1 tests/Compiler/Generate/CodeGen/
```

## Risk Assessment

**Low risk:** This change adds defensive handling without changing the happy path:
1. When ops already end with a valid terminator, behavior is unchanged
2. The dummy `eco.return` is unreachable at runtime (the `eco.case` branches exit via their own returns)
3. The fix is localized to 4 functions in one file

## Why This Fix Works

MLIR requires every region's entry block to end with a terminator operation. When we have nested case expressions:

```
eco.case (outer) {
  region 0 {
    eco.case (inner) {  <-- This eco.case is NOT a terminator!
      region 0 { ... eco.return }
      region 1 { ... eco.return }
    }
  }
}
```

The inner `eco.case` appears at the end of region 0's body, but `mkRegionFromOps` treats it as the terminator. By appending a dummy `eco.return` after the inner `eco.case`, we get:

```
eco.case (outer) {
  region 0 {
    eco.case (inner) {
      region 0 { ... eco.return }
      region 1 { ... eco.return }
    }
    eco.const.unit %dummy
    eco.return %dummy  <-- Valid terminator!
  }
}
```

The dummy return is never reached because control flow exits through the inner case's branches, but it satisfies MLIR's structural requirement.
