# Plan: Lock In Staging-Agnostic Monomorphization

## Overview

This plan "locks in" the four architectural pieces that make Monomorphize purely about type substitution and closure construction, with all staging/ABI decisions owned by GlobalOpt.

**Current State:**
- Monomorphize produces closures with flat params but nested MFunction types
- GlobalOpt validates GOPT_016 but crashes (`Debug.todo`) instead of fixing the mismatch
- 1131 tests fail because GlobalOpt can't handle the staging mismatch

**Target State:**
- TOpt decides function structure; Monomorphize just specializes it
- `TypeSubst` preserves curried TLambda semantics
- `Specialize` produces closures whose types match TOpt exactly (after substitution)
- GlobalOpt canonicalizes staging and enforces GOPT_016/018

---

## Confirmed Design Decisions

### Q1: Flatten types or nest closures?

**Decision: Option A - Flatten types to match params**

For each `MonoClosure`:
```
Before: params=[(x,Int),(y,Int)], type=MFunction [Int] (MFunction [Int] Int)
After:  params=[(x,Int),(y,Int)], type=MFunction [Int, Int] Int
```

Rationale:
- Types "look like" what the backend wants (flat argument list)
- Simple invariant: `length params == length args-of(MonoType)`
- Option B (nesting closures) would require synthesizing nested closures and rewriting all uses

### Q2: What about `MonoTailFunc`?

**Decision: Treat `MonoTailFunc` exactly like `MonoClosure`**

- `MonoTailFunc` has flat params + potentially curried function type
- Apply same canonicalization: flatten type to match params
- Keeps call sites simple and backends happy
- GOPT_016 applies to all "callable things", not just closures

### Q3: Order of operations?

**Decision: `canonicalizeClosureStaging` runs BEFORE `normalizeCaseIfAbi`**

Pipeline order:
1. `canonicalizeClosureStaging` - Flatten closure/tail-func types
2. `normalizeCaseIfAbi` - Align branch ABIs and case result types (GOPT_018)
3. `validateClosureStaging` - Assert GOPT_016 (can fold into step 1)
4. `annotateReturnedClosureArity`

Rationale:
- If we canonicalize first, every closure's type is flat
- `normalizeCaseIfAbi` then only reconciles case result types, not local param/type mismatches
- Running in reverse order would require reasoning about mixed curried/flat types

### Q4: Can `params < stageArity`?

**Decision: No - treat as GOPT_016 violation**

Under this design:
- Each `MonoClosure` comes from a single TOpt lambda
- Lambda's `Can.Type` has `paramCount` TLambdas for `paramCount` syntactic params
- After substitution, MonoType has same logical arity
- After flattening, `stage arity == paramCount`

Partial applications are represented via PAPs/calls, not under-parametrized closures.
If `params < flattened-arity` ever occurs, it's a genuine bug.

### Q5: Does `annotateReturnedClosureArity` still work?

**Decision: Yes, it simplifies**

After canonicalization:
- All closure/tail-func types are flat `MFunction [arg1..argN] ret`
- "Remaining arity of returned closure" is simply `N`
- Use same helper as `canonicalizeClosureStaging` to compute arg list

---

## The Four Pieces

### Piece 1: Rely on TOpt Invariants (No Changes Needed)

**TOPT_005**: Every `TOpt.Function` / `TOpt.TrackedFunction` has a `Can.Type` that exactly encodes its params and result as a TLambda chain.

**What Monomorphize Must Do:**
- Trust the `Can.Type` as authoritative about logical arity
- Never re-derive function shape from syntax
- Apply substitution to the type, preserving its structure

**Action:** Add documentation comment in `specializeLambda`:
```elm
-- Invariant: `canType` is the TLambda encoding of this function (TOPT_005).
-- Monomorphize must not change its staging; only apply substitution.
-- The flat param list from TOpt.Function is syntactic; the type is semantic.
-- GlobalOpt (GOPT_016) will canonicalize by flattening the type to match params.
```

### Piece 2: `TypeSubst.applySubst` Purely Curried (Already Correct)

Current implementation preserves TLambda staging:
```elm
Can.TLambda from to ->
    Mono.MFunction [ argMono ] resultMono
```

**Action:** Add documentation comment:
```elm
-- INVARIANT: Preserves TLambda staging.
-- a -> b -> c becomes MFunction [a] (MFunction [b] c), NOT MFunction [a, b] c.
-- GlobalOpt will flatten these types to match closure param counts.
```

### Piece 3: `Specialize` = Substitution + Closure Construction (Already Correct)

Current `specializeLambda`:
- Applies `TypeSubst.applySubst` to types
- Takes params exactly from TOpt node
- Does NOT flatten or re-stage

**Action:** Add documentation comment explaining intentional mismatch:
```elm
-- NOTE: The closure may have more params than the type's stage arity.
-- This is intentional. Example:
--   \x y -> body has 2 params but type MFunction [a] (MFunction [b] c) has stage arity 1.
-- GlobalOpt will flatten the type to MFunction [a, b] c (GOPT_016).
```

### Piece 4: GlobalOpt Owns Staging (Core Implementation Work)

**This is the missing piece that causes 1131 test failures.**

---

## Implementation Plan

### Phase 1: Add `canonicalizeClosureStaging` to GlobalOpt

**File:** `Compiler/GlobalOpt/MonoGlobalOptimize.elm`

#### 1.1 Add the canonicalization function

```elm
{-| Canonicalize closure and tail-func types by flattening to match param counts.

After this pass, for all MonoClosure and MonoTailFunc nodes:
    length(closureInfo.params) == length(args of MFunction type)

This is the GOPT_016 canonicalization step.
-}
canonicalizeClosureStaging : Mono.MonoGraph -> Mono.MonoGraph
canonicalizeClosureStaging (Mono.MonoGraph data) =
    Mono.MonoGraph
        { data
            | nodes = Dict.map (\_ node -> canonicalizeNode node) data.nodes
        }


canonicalizeNode : Mono.MonoNode -> Mono.MonoNode
canonicalizeNode node =
    case node of
        Mono.MonoDefine expr monoType ->
            Mono.MonoDefine (canonicalizeExpr expr) (canonicalizeType expr monoType)

        Mono.MonoTailFunc params expr monoType ->
            let
                canonType = flattenTypeToArity (List.length params) monoType
            in
            Mono.MonoTailFunc params (canonicalizeExpr expr) canonType

        Mono.MonoPortIncoming expr monoType ->
            Mono.MonoPortIncoming (canonicalizeExpr expr) monoType

        Mono.MonoPortOutgoing expr monoType ->
            Mono.MonoPortOutgoing (canonicalizeExpr expr) monoType

        Mono.MonoCycle defs monoType ->
            Mono.MonoCycle
                (List.map (\( name, e ) -> ( name, canonicalizeExpr e )) defs)
                monoType

        _ ->
            node


canonicalizeExpr : Mono.MonoExpr -> Mono.MonoExpr
canonicalizeExpr expr =
    case expr of
        Mono.MonoClosure closureInfo body closureType ->
            let
                paramCount = List.length closureInfo.params
                canonType = flattenTypeToArity paramCount closureType
                canonBody = canonicalizeExpr body
                canonCaptures =
                    List.map (\( n, e, t ) -> ( n, canonicalizeExpr e, t )) closureInfo.captures
            in
            Mono.MonoClosure
                { closureInfo | captures = canonCaptures }
                canonBody
                canonType

        -- Recursively process all other expression forms...
        Mono.MonoCall callType fn args resultType ->
            Mono.MonoCall callType (canonicalizeExpr fn) (List.map canonicalizeExpr args) resultType

        Mono.MonoIf branches final resultType ->
            Mono.MonoIf
                (List.map (\( c, t ) -> ( canonicalizeExpr c, canonicalizeExpr t )) branches)
                (canonicalizeExpr final)
                resultType

        Mono.MonoLet def body resultType ->
            Mono.MonoLet (canonicalizeDef def) (canonicalizeExpr body) resultType

        Mono.MonoCase region scrutinee decider jumps resultType ->
            Mono.MonoCase region
                (canonicalizeExpr scrutinee)
                (canonicalizeDecider decider)
                (List.map (\( i, e ) -> ( i, canonicalizeExpr e )) jumps)
                resultType

        -- ... handle all other expression types
        _ ->
            expr
```

#### 1.2 Add helper `flattenTypeToArity`

```elm
{-| Flatten a function type to have exactly `targetArity` arguments in the outer MFunction.

Example:
    flattenTypeToArity 2 (MFunction [a] (MFunction [b] c))
    => MFunction [a, b] c
-}
flattenTypeToArity : Int -> Mono.MonoType -> Mono.MonoType
flattenTypeToArity targetArity monoType =
    let
        ( allArgs, finalResult ) =
            flattenFunctionType monoType
    in
    if List.length allArgs == targetArity then
        -- Already correct arity
        Mono.MFunction allArgs finalResult
    else if List.length allArgs > targetArity then
        -- More args than params - take first N, nest the rest
        let
            ( firstArgs, restArgs ) =
                splitAt targetArity allArgs

            nestedResult =
                if List.isEmpty restArgs then
                    finalResult
                else
                    Mono.MFunction restArgs finalResult
        in
        Mono.MFunction firstArgs nestedResult
    else
        -- Fewer args than params - this is a GOPT_016 violation
        Debug.todo
            ("GOPT_016: type has fewer args ("
                ++ String.fromInt (List.length allArgs)
                ++ ") than closure has params ("
                ++ String.fromInt targetArity
                ++ ")"
            )
```

### Phase 2: Update GlobalOpt Pipeline

**File:** `Compiler/GlobalOpt/MonoGlobalOptimize.elm`

Change `globalOptimize` to:

```elm
globalOptimize : TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> Mono.MonoGraph
globalOptimize typeEnv graph0 =
    let
        -- Step 1: Canonicalize closure/tail-func types (GOPT_016 fix)
        graph1 =
            canonicalizeClosureStaging graph0

        -- Step 2: Normalize case/if branch ABIs (GOPT_018)
        graph2 =
            normalizeCaseIfAbi typeEnv graph1

        -- Step 3: Validate staging invariants (should pass after steps 1-2)
        graph3 =
            validateClosureStaging graph2

        -- Step 4: Annotate returned closure arities
        graph4 =
            annotateReturnedClosureArity typeEnv graph3
    in
    graph4
```

### Phase 3: Update `validateClosureStaging`

Change from "crash on mismatch" to "assert canonicalization worked":

```elm
{-| Validate GOPT_016: closure params match type's flattened arity.

After canonicalizeClosureStaging, this should never fail.
A failure here indicates a bug in canonicalization.
-}
validateClosureStaging : Mono.MonoGraph -> Mono.MonoGraph
validateClosureStaging graph =
    -- Walk the graph and assert all closures are canonical
    -- If any fail, crash with detailed error (indicates bug)
    ...
```

### Phase 4: Add Documentation Comments

**File:** `Compiler/Monomorphize/Specialize.elm`

Add to `specializeLambda`:
```elm
-- Invariant: `canType` is the TLambda encoding of this function (TOPT_005).
-- Monomorphize preserves the curried structure from TypeSubst.applySubst.
-- The closure will have N params (from TOpt syntax) but type with stage arity < N.
-- Example: \x y -> body has params=2, type=MFunction [a] (MFunction [b] c) (stage arity 1).
-- GlobalOpt (GOPT_016) will flatten: MFunction [a, b] c.
```

**File:** `Compiler/Monomorphize/TypeSubst.elm`

Add to `applySubst` TLambda case:
```elm
-- INVARIANT: Preserves TLambda staging exactly.
-- a -> b -> c becomes MFunction [a] (MFunction [b] c).
-- GlobalOpt will flatten to match closure param counts (GOPT_016).
```

---

## Test Expectations

After implementation:

| Test Category | Expected Result |
|---------------|-----------------|
| GOPT_016 tests (51) | Pass - closures canonicalized |
| MLIR generation tests | Pass - types are flat |
| Other tests (6386) | Pass - no regressions |

---

## Files to Modify

| File | Changes |
|------|---------|
| `Compiler/GlobalOpt/MonoGlobalOptimize.elm` | Add `canonicalizeClosureStaging`, `flattenTypeToArity`, update pipeline |
| `Compiler/Monomorphize/Specialize.elm` | Documentation comments only |
| `Compiler/Monomorphize/TypeSubst.elm` | Documentation comments only |

---

## Implementation Checklist

- [ ] Add `flattenTypeToArity` helper
- [ ] Add `canonicalizeClosureStaging` function
- [ ] Add `canonicalizeNode` for MonoTailFunc handling
- [ ] Add `canonicalizeExpr` with full expression traversal
- [ ] Update `globalOptimize` pipeline order
- [ ] Update `validateClosureStaging` to be post-canonicalization assertion
- [ ] Add documentation comments to Specialize.elm
- [ ] Add documentation comments to TypeSubst.elm
- [ ] Run tests and verify all pass

---

## Risk Assessment

**Medium Risk:**
- `canonicalizeExpr` must handle ALL expression types recursively
- Missing a case would leave un-canonicalized closures

**Low Risk:**
- Pipeline ordering is straightforward
- `flattenTypeToArity` logic is simple

**Mitigation:**
- Use exhaustive pattern matching (no catch-all `_` in canonicalizeExpr)
- Add assertion in `validateClosureStaging` to catch any missed cases
