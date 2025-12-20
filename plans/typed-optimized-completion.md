# Typed Optimization Completion Plan

This plan addresses all gaps identified between `design_docs/typed-optimized-trans.md` and the current implementation in `Compiler/Optimize/Typed/`.

## Overview

The implementation has the architectural skeleton but ~75% of expression cases are stubs. This plan organizes the work into phases that can be implemented and tested incrementally.

## Key Design Decisions (Confirmed)

1. **TypedCanonical Structure:** Shallow wrapper. `TCan.Expr` wraps `Can.Expr_` with a `tipe : Can.Type`.

2. **Type Source:** `fromCanonical` builds `TCan.Module` using the `Dict Int Can.Type` mapping from `constrainWithExprVars`/`runWithExprVars`. The optimizer sees `TCan.Expr` nodes that already carry their type.

3. **Case Optimization:** Port all case optimization from Erased, or reuse `Erased.DecisionTree` directly.

4. **Tail Call Optimization:** `optimizePotentialTailCallDef` must be fully implemented (not a stub).

## Architecture for Subexpression Access

Since TypedCanonical is a shallow wrapper, when we pattern match on `Can.Expr_` and encounter subexpressions (e.g., `Can.Let def body` where `body : Can.Expr`), we need a way to get the typed version.

**Solution:** The optimizer needs access to a conversion function or the expr ID → type mapping:

```elm
-- Helper to wrap a Can.Expr with its type from the mapping
wrapExpr : ExprTypeMap -> Can.Expr -> TCan.Expr
wrapExpr mapping (A.At region (Can.Expr_ id node)) =
    A.At region
        (TCan.TypedExpr
            { expr = node
            , tipe = Dict.get id mapping |> Maybe.withDefault (Can.TVar "?")
            }
        )
```

This helper (or access to the mapping) should be threaded through the optimizer.

---

## Phase 1: Foundation Helpers

Before implementing expression cases, we need supporting infrastructure.

### 1.1 Add `TOpt.typeOf` Helper

**File:** `Compiler/AST/TypedOptimized.elm`

Add a function to extract the type from any `TOpt.Expr`:

```elm
typeOf : Expr -> Can.Type
typeOf expr =
    case expr of
        VarLocal _ _ tipe -> tipe
        VarGlobal _ _ tipe -> tipe
        VarEnum _ _ _ tipe -> tipe
        VarBox _ _ tipe -> tipe
        VarCycle _ _ _ tipe -> tipe
        VarDebug _ _ _ _ tipe -> tipe
        VarKernel _ _ _ tipe -> tipe
        TrackedVarLocal _ _ tipe -> tipe
        Chr _ _ tipe -> tipe
        Str _ _ tipe -> tipe
        Int _ _ tipe -> tipe
        Float _ _ tipe -> tipe
        List _ _ tipe -> tipe
        Function _ _ tipe -> tipe
        TrackedFunction _ _ tipe -> tipe
        Call _ _ _ tipe -> tipe
        TailCall _ _ tipe -> tipe
        If _ _ tipe -> tipe
        Let _ _ tipe -> tipe
        Destruct _ _ tipe -> tipe
        Case _ _ _ _ tipe -> tipe
        Accessor _ _ tipe -> tipe
        Access _ _ _ tipe -> tipe
        Update _ _ _ tipe -> tipe
        Record _ tipe -> tipe
        TrackedRecord _ _ tipe -> tipe
        Unit tipe -> tipe
        Tuple _ _ _ _ tipe -> tipe
        Shader _ _ _ tipe -> tipe
        Bool _ _ tipe -> tipe
```

### 1.2 Add `buildFunctionType` Helper

**File:** `Compiler/Optimize/Typed/Expression.elm`

```elm
buildFunctionType : List Can.Type -> Can.Type -> Can.Type
buildFunctionType argTypes resultType =
    List.foldr Can.TLambda resultType argTypes
```

### 1.3 Enhance Destructuring with Type Computation

**File:** `Compiler/Optimize/Typed/Expression.elm`

The current `destructHelp` uses `Can.TVar "?"` for all bindings. We need a version that computes actual types from the scrutinee type.

**Option A (Simpler):** Change signature of `destructArgs` to also accept argument types when available:

```elm
destructTypedArgs :
    List ( Can.Pattern, Can.Type )
    -> Names.Tracker
        ( List ( A.Located Name, Can.Type )
        , List TOpt.Destructor
        )
```

**Option B (Full design compliance):** Implement `destructHelpCollectBindings` that walks pattern + type in lockstep:

```elm
destructHelpWithType :
    TOpt.Path
    -> Can.Type           -- scrutinee type
    -> Can.Pattern
    -> List TOpt.Destructor
    -> Names.Tracker (List TOpt.Destructor)
```

This extracts element types from tuple types, field types from record types, etc.

**Recommendation:** Start with Option A for typed args, then extend to Option B for Case patterns.

---

## Phase 2: Simple Expression Cases

These cases don't involve scoping or definitions. They require converting `Can.Expr` children to `TCan.Expr` using the expr ID → type mapping.

### 2.1 Can.List

**Current (line 119-122):** Returns empty list

**Fix:**
```elm
Can.List entries ->
    Names.traverse (\entry -> optimize kernelEnv cycle annotations (wrapExpr exprTypes entry)) entries
        |> Names.map (\optEntries -> TOpt.List region optEntries tipe)
```

### 2.2 Can.Negate

**Current (line 124-135):** Doesn't optimize subExpr

**Fix:**
```elm
Can.Negate subExpr ->
    optimize kernelEnv cycle annotations (wrapExpr exprTypes subExpr)
        |> Names.andThen
            (\optSub ->
                Names.registerGlobal region ModuleName.basics Name.negate (Can.TLambda tipe tipe)
                    |> Names.map (\negateFunc -> TOpt.Call region negateFunc [ optSub ] tipe)
            )
```

### 2.3 Can.Binop

**Current (line 137-142):** Doesn't optimize operands

**Fix:**
```elm
Can.Binop _ home name _ left right ->
    Names.registerGlobal region home name tipe
        |> Names.andThen
            (\optFunc ->
                optimize kernelEnv cycle annotations (wrapExpr exprTypes left)
                    |> Names.andThen
                        (\optLeft ->
                            optimize kernelEnv cycle annotations (wrapExpr exprTypes right)
                                |> Names.map (\optRight -> TOpt.Call region optFunc [ optLeft, optRight ] tipe)
                        )
            )
```

### 2.4 Can.Tuple

**Current (line 186-187):** Returns placeholders

**Fix:**
```elm
Can.Tuple a b cs ->
    optimize kernelEnv cycle annotations (wrapExpr exprTypes a)
        |> Names.andThen
            (\optA ->
                optimize kernelEnv cycle annotations (wrapExpr exprTypes b)
                    |> Names.andThen
                        (\optB ->
                            Names.traverse (\c -> optimize kernelEnv cycle annotations (wrapExpr exprTypes c)) cs
                                |> Names.andThen
                                    (\optCs ->
                                        Names.registerKernel Name.utils (TOpt.Tuple region optA optB optCs tipe)
                                    )
                        )
            )
```

### 2.5 Can.Record

**Current (line 175-181):** Returns empty dict

**Fix:**
```elm
Can.Record fields ->
    Names.mapTraverse identity compare
        (\(A.At _ fieldExpr) -> optimize kernelEnv cycle annotations (wrapExpr exprTypes fieldExpr))
        fields
        |> Names.andThen
            (\optFields ->
                Names.registerFieldDict (Utils.mapMapKeys identity A.compareLocated A.toValue fields)
                    (TOpt.TrackedRecord region optFields tipe)
            )
```

### 2.6 Can.Access

**Current (line 169-170):** Only registers field

**Fix:**
```elm
Can.Access record (A.At _ field) ->
    optimize kernelEnv cycle annotations (wrapExpr exprTypes record)
        |> Names.andThen
            (\optRecord ->
                Names.registerField field (TOpt.Access region optRecord field tipe)
            )
```

### 2.7 Can.Update

**Current (line 172-173):** Stub

**Fix:**
```elm
Can.Update (A.At _ name) fields ->
    -- Get the record being updated from local scope
    Names.lookupLocalType name
        |> Names.andThen
            (\recordType ->
                Names.mapTraverse identity compare
                    (\(A.At _ fieldExpr) -> optimize kernelEnv cycle annotations (wrapExpr exprTypes fieldExpr))
                    fields
                    |> Names.andThen
                        (\optFields ->
                            Names.registerFieldDict (Utils.mapMapKeys identity A.compareLocated A.toValue fields)
                                (TOpt.Update region (TOpt.VarLocal name recordType) optFields tipe)
                        )
            )
```

---

## Phase 3: Lambda and Call

### 3.1 Can.Lambda

**Current (line 144-146):** Complete stub

**Fix:**
```elm
Can.Lambda args body ->
    destructArgs annotations args
        |> Names.andThen
            (\( argNamesWithTypes, destructors ) ->
                let
                    argBindings = List.map (\( A.At _ n, t ) -> ( n, t )) argNamesWithTypes
                    destructorBindings = List.map (\(TOpt.Destructor n _ t) -> ( n, t )) destructors
                    allBindings = argBindings ++ destructorBindings
                    bodyType = peelFunctionType (List.length args) tipe
                in
                Names.withVarTypes allBindings
                    (optimize kernelEnv cycle annotations (wrapExpr exprTypes body))
                    |> Names.map
                        (\obody ->
                            let
                                wrappedBody = List.foldr (wrapDestruct bodyType) obody destructors
                            in
                            TOpt.TrackedFunction argNamesWithTypes wrappedBody tipe
                        )
            )
```

### 3.2 Can.Call

**Current (line 148-149):** Complete stub

**Fix:**
```elm
Can.Call func args ->
    optimize kernelEnv cycle annotations (wrapExpr exprTypes func)
        |> Names.andThen
            (\optFunc ->
                Names.traverse (\arg -> optimize kernelEnv cycle annotations (wrapExpr exprTypes arg)) args
                    |> Names.map (\optArgs -> TOpt.Call region optFunc optArgs tipe)
            )
```

---

## Phase 4: Control Flow (If, Case)

### 4.1 Can.If

**Current (line 151-152):** Stub

**Fix:**
```elm
Can.If branches final ->
    let
        optimizeBranch ( cond, branch ) =
            optimize kernelEnv cycle annotations (wrapExpr exprTypes cond)
                |> Names.andThen
                    (\optCond ->
                        optimize kernelEnv cycle annotations (wrapExpr exprTypes branch)
                            |> Names.map (\optBranch -> ( optCond, optBranch ))
                    )
    in
    Names.traverse optimizeBranch branches
        |> Names.andThen
            (\optBranches ->
                optimize kernelEnv cycle annotations (wrapExpr exprTypes final)
                    |> Names.map (\optFinal -> TOpt.If optBranches optFinal tipe)
            )
```

### 4.2 Can.Case

**Current (line 163-164):** Stub

This is the most complex case because:
1. Each branch pattern binds variables that must be in scope for the branch body
2. Full case optimization requires decision trees (pattern compilation)

**Approach:** Reuse `Erased.DecisionTree` for pattern compilation, or port to `Typed.DecisionTree`.

**Fix (simplified version without full decision tree):**
```elm
Can.Case scrutinee branches ->
    optimize kernelEnv cycle annotations (wrapExpr exprTypes scrutinee)
        |> Names.andThen
            (\optScrutinee ->
                let
                    scrutineeType = TOpt.typeOf optScrutinee
                in
                Names.traverse (optimizeCaseBranch kernelEnv cycle annotations exprTypes scrutineeType) branches
                    |> Names.map
                        (\optBranches ->
                            -- Full implementation needs DecisionTree.compile
                            TOpt.Case label optScrutinee optBranches [] tipe
                        )
            )
```

**Helper for branch optimization:**
```elm
optimizeCaseBranch :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> ExprTypeMap
    -> Can.Type  -- scrutinee type for pattern destructuring
    -> Can.CaseBranch
    -> Names.Tracker ( TOpt.Pattern, TOpt.Expr )
optimizeCaseBranch kernelEnv cycle annotations exprTypes scrutineeType (Can.CaseBranch pattern body) =
    destructPatternWithType scrutineeType pattern
        |> Names.andThen
            (\( destructors, bindings ) ->
                Names.withVarTypes bindings
                    (optimize kernelEnv cycle annotations (wrapExpr exprTypes body))
                    |> Names.map
                        (\obody ->
                            let
                                wrappedBody = List.foldr (wrapDestruct (TOpt.typeOf obody)) obody destructors
                            in
                            ( patternToOpt pattern, wrappedBody )
                        )
            )
```

**Full implementation note:** The erased optimizer uses `DecisionTree.compile` to transform patterns into efficient decision trees with `Decider` and `Choice` nodes. This should be ported or reused for the typed version.

---

## Phase 5: Let Bindings

Let bindings require:
1. Optimizing the definition's body
2. Computing the local's type from the optimized RHS (using `TOpt.typeOf`)
3. Adding the local to scope before optimizing the body
4. **Never using annotations for local def types** - only top-level defs use annotations

### 5.1 Can.Let

```elm
Can.Let def body ->
    optimizeLocalDef kernelEnv cycle annotations exprTypes def
        |> Names.andThen
            (\odef ->
                let
                    ( defName, defType ) = extractDefNameAndType odef
                in
                Names.withVarType defName defType
                    (optimize kernelEnv cycle annotations (wrapExpr exprTypes body))
                    |> Names.map (\obody -> TOpt.Let odef obody tipe)
            )

extractDefNameAndType : TOpt.Def -> ( Name, Can.Type )
extractDefNameAndType odef =
    case odef of
        TOpt.Def _ n _ t -> ( n, t )
        TOpt.TailDef _ n _ _ t -> ( n, t )
```

### 5.2 Can.LetRec

Similar but for recursive definitions:

```elm
Can.LetRec defs body ->
    -- First, collect all def names and types (computed from RHS)
    optimizeLocalRecDefs kernelEnv cycle annotations exprTypes defs
        |> Names.andThen
            (\odefs ->
                let
                    bindings = List.map extractDefNameAndType odefs
                in
                Names.withVarTypes bindings
                    (optimize kernelEnv cycle annotations (wrapExpr exprTypes body))
                    |> Names.map (\obody -> TOpt.LetRec odefs obody tipe)
            )
```

**Critical:** Local def types must come from RHS, **never from annotations**:

```elm
optimizeLocalDef :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> ExprTypeMap
    -> Can.Def
    -> Names.Tracker TOpt.Def
optimizeLocalDef kernelEnv cycle annotations exprTypes def =
    case def of
        Can.Def (A.At region name) [] body ->
            -- Zero-arg def: type comes from optimized body
            optimize kernelEnv cycle annotations (wrapExpr exprTypes body)
                |> Names.map
                    (\oexpr ->
                        let
                            exprType = TOpt.typeOf oexpr
                        in
                        TOpt.Def region name oexpr exprType
                    )

        Can.Def (A.At region name) args body ->
            -- Function def: build function type from args + body
            destructArgs annotations args
                |> Names.andThen
                    (\( argNamesWithTypes, destructors ) ->
                        let
                            argBindings = List.map (\( A.At _ n, t ) -> ( n, t )) argNamesWithTypes
                            destructorBindings = List.map (\(TOpt.Destructor n _ t) -> ( n, t )) destructors
                            allBindings = argBindings ++ destructorBindings
                        in
                        Names.withVarTypes allBindings
                            (optimize kernelEnv cycle annotations (wrapExpr exprTypes body))
                            |> Names.map
                                (\obody ->
                                    let
                                        bodyType = TOpt.typeOf obody
                                        wrappedBody = List.foldr (wrapDestruct bodyType) obody destructors
                                        argTypes = List.map Tuple.second argNamesWithTypes
                                        funcType = buildFunctionType argTypes bodyType
                                        func = TOpt.TrackedFunction argNamesWithTypes wrappedBody funcType
                                    in
                                    TOpt.Def region name func funcType
                                )
                    )

        Can.TypedDef ... ->
            -- Similar but with explicit type annotations on args
            ...
```

### 5.3 Can.LetDestruct

```elm
Can.LetDestruct pattern expr body ->
    optimize kernelEnv cycle annotations (wrapExpr exprTypes expr)
        |> Names.andThen
            (\oexpr ->
                let
                    exprType = TOpt.typeOf oexpr
                in
                destructPatternWithType exprType pattern
                    |> Names.andThen
                        (\( destructors, bindings ) ->
                            Names.withVarTypes bindings
                                (optimize kernelEnv cycle annotations (wrapExpr exprTypes body))
                                |> Names.map
                                    (\obody ->
                                        let
                                            wrappedBody = List.foldr (wrapDestruct (TOpt.typeOf obody)) obody destructors
                                        in
                                        -- Emit as a Let with destructors
                                        TOpt.Let (TOpt.Def A.zero "_" oexpr exprType) wrappedBody tipe
                                    )
                        )
            )
```

---

## Phase 6: Tail Call Optimization

### 6.1 Add `optimizeTail` Function

For tail-recursive functions, we need a version of optimize that detects tail calls:

```elm
optimizeTail :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> Name            -- function being defined (for detecting self-calls)
    -> Int             -- arity
    -> TCan.Expr
    -> Names.Tracker TOpt.Expr
```

This is similar to `optimize` but:
- Tracks whether we're in tail position
- Converts `Can.Call` to function being defined into `TOpt.TailCall`
- Handles `Can.If` and `Can.Case` by recursing with `optimizeTail` on branches

---

## Implementation Order

### Wave 1: Infrastructure
1. Add `TOpt.typeOf` to `TypedOptimized.elm`
2. Add `buildFunctionType` helper to `Expression.elm`
3. Add `wrapExpr` helper or thread `ExprTypeMap` through optimizer
4. Add `destructPatternWithType` for typed pattern destructuring
5. Update `optimize` signature to receive `ExprTypeMap`

### Wave 2: Simple Expressions
1. Can.List - traverse entries
2. Can.Tuple - optimize elements
3. Can.Record - optimize field expressions
4. Can.Negate - optimize subexpr, build call
5. Can.Binop - optimize operands, build call
6. Can.Access - optimize record, access field
7. Can.Update - optimize record and fields

### Wave 3: Functions
1. Can.Lambda - destruct args, optimize body with bindings
2. Can.Call - optimize func and args

### Wave 4: Control Flow
1. Can.If - optimize branches and final
2. Can.Case - optimize scrutinee, destruct patterns per branch
   - Start with simplified version
   - Later: port/reuse DecisionTree for full pattern compilation

### Wave 5: Let Bindings
1. Add `optimizeLocalDef` (types from RHS, not annotations)
2. Can.Let - optimize def, add to scope, optimize body
3. Can.LetRec - optimize recursive defs, add all to scope, optimize body
4. Can.LetDestruct - optimize expr, destruct pattern, optimize body

### Wave 6: Tail Calls
1. Add `optimizeTail` function for tail position optimization
2. Update `optimizePotentialTailCallDef` to use `optimizeTail` for body
3. Handle tail calls in If/Case branches

---

## Testing Strategy

After each wave, test with examples that exercise the implemented cases:

**Wave 2 test:**
```elm
example = (1, 2)       -- Tuple
example = [1, 2, 3]    -- List
example = { x = 1 }    -- Record
```

**Wave 3 test:**
```elm
add x y = x + y        -- Lambda with Call
result = add 1 2       -- Call
```

**Wave 4 test:**
```elm
max x y = if x > y then x else y    -- If
describe n = case n of              -- Case
    0 -> "zero"
    _ -> "other"
```

**Wave 5 test:**
```elm
example =
    let
        helper x = x + 1    -- Let with function
        (a, b) = (1, 2)     -- LetDestruct
    in
    helper a + b
```

**Wave 6 test:**
```elm
sum acc list =    -- Tail recursive
    case list of
        [] -> acc
        x :: xs -> sum (acc + x) xs
```

---

## Resolved Design Questions

1. **TypedCanonical Structure:** Shallow wrapper - `TCan.Expr` wraps `Can.Expr_` with `tipe : Can.Type`.

2. **Type Access:** `fromCanonical` builds `TCan.Module` using `Dict Int Can.Type` from `constrainWithExprVars`/`runWithExprVars`. The optimizer sees `TCan.Expr` nodes with their types already attached.

3. **Case Optimization:** Port all case optimization from Erased, or reuse `Erased.DecisionTree` directly.

4. **Tail Calls:** `optimizePotentialTailCallDef` must be fully implemented.

---

## Implementation Notes

### Accessing Subexpression Types

Since TypedCanonical is shallow, when pattern matching on `Can.Expr_` and encountering child expressions like `Can.Let def body`:
- The `body : Can.Expr` needs to be converted to `TCan.Expr`
- Use the expr ID → type mapping to wrap `Can.Expr` with its type
- Thread this mapping (or a wrapper helper) through the optimizer

### Reusing DecisionTree

The `Erased.DecisionTree` module handles case optimization. Options:
1. **Direct reuse:** If DecisionTree produces structures compatible with `TOpt`, use it directly
2. **Typed port:** Create `Typed.DecisionTree` that mirrors the erased version but produces typed patterns/branches

Recommendation: Start with direct reuse if possible, port later if type information is needed in decision trees.
