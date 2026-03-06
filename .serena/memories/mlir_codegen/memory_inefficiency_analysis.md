# MLIR Generation Pass - Memory Inefficiency Analysis

## Executive Summary
The MLIR generation pass exhibits several significant memory inefficiencies, primarily stemming from:
1. **O(n) list concatenation in hot loops** (++ operator)
2. **Unbounded Context growth** without scope cleanup
3. **Repeated string operations** and conversions
4. **Inefficient type registry building**
5. **Excessive lambda deduplication overhead**

## Critical Issues Found

### 1. Context Type Growth (CRITICAL)
**File**: `Context.elm:211-224`
**Issue**: The Context type accumulates data unbounded across the entire compilation:

```elm
type alias Context =
    { nextVar : Int
    , nextOpId : Int
    , mode : Mode.Mode
    , registry : Mono.SpecializationRegistry
    , pendingLambdas : List PendingLambda         -- UNBOUNDED
    , pendingFuncOps : List MlirOp                -- UNBOUNDED
    , signatures : Dict.Dict Int FuncSignature    -- UNBOUNDED
    , varMappings : Dict.Dict String VarInfo      -- Per-scope, not cleared
    , currentLetSiblings : Dict.Dict String VarInfo
    , kernelDecls : Dict.Dict String (...)        -- ACCUMULATES
    , typeRegistry : TypeRegistry                 -- GROWS FOREVER
    , decoderExprs : Dict.Dict String Mono.MonoExpr -- UNBOUNDED
    }
```

**Evidence of accumulation**:
- `pendingLambdas` accumulates across the entire program (Backend.elm:66-74)
- `kernelDecls` accumulates kernel declarations across all functions
- `typeRegistry.typeInfos` is a List that grows monotonically (line 233)

**Impact**: Memory usage grows O(n) where n = total program size. After processing 1000s of functions, the Context holds ALL previous data.

**Severity**: HIGH - Affects compilation speed on large projects

### 2. O(n²) List Concatenation in Hot Loops
**Primary Pattern**: `accOps ++ nodeOps` and `accOps ++ result.ops`

**Occurrences**:
- Backend.elm:68: `accOps ++ nodeOps` (folding over ALL nodes)
- Backend.elm:94: `accOps ++ [declOp]` (accumulating kernel decls)
- Expr.elm:825-860: List.foldr with `accOps ++ ...` in EVERY list cons
- Expr.elm:885-892: `accOps ++ result.ops` in closure capture loop
- Expr.elm:2714-2720: `accOps ++ result.ops` in record field loops
- Functions.elm:478-496: `accOps ++ [projectOp]` in closure capture loop
- TailRec.elm:384-387: `opsAcc ++ argResult.ops` in argument evaluation
- Lambdas.elm:66-71: `accOps ++ ops` in lambda processing

**Cost**: 
- Each `++` is O(n) where n = length of left operand
- In hot loops (iterating N items), total is O(N²)
- Example: Processing 100 list items with `List.foldr` + `++ each iteration = 100 * 50 avg = 5,000 ops

**Code Example**:
```elm
-- Backend.elm:62-71 (Expr.elm similar)
EveryDict.foldl compare
    (\specId node ( accOps, accCtx ) ->
        let ( nodeOps, newCtx ) = Functions.generateNode accCtx specId node
        in ( accOps ++ nodeOps, newCtx )  -- O(n) append repeated N times = O(n²)
    )
    ( [], ctx )
    nodes
```

**Severity**: CRITICAL - Quadratic memory and time cost

### 3. Type Registry Building Inefficiency
**File**: `Context.elm:288-424` (getOrCreateTypeIdForMonoType)

**Issues**:
1. **Worklist uses List operations**:
   - Line 396-407: Checking type membership via `List.any` with `Mono.toComparableMonoType` equality
   - This is O(n) per check in a worklist of potentially unbounded size
   
2. **Type key computation repeated**:
   - Lines 309, 354, 389-390, 414-415: `Mono.toComparableMonoType mt` called repeatedly
   - Should be cached to avoid recomputation

3. **Nested type traversal**:
   - `getNestedTypes` at lines 293-348 rebuilds type lists for every type
   - Called inside `processWorklist` in a loop

**Example inefficiency**:
```elm
-- Lines 388-407: for each type in worklist...
current :: rest ->
    let currentKey = Mono.toComparableMonoType current  -- RECOMPUTED CONSTANTLY
    in
    if Dict.member currentKey c.typeRegistry.typeIds then
        processWorklist rest toRegister c  -- But list membership check uses List.any
    else if List.any (\t -> Mono.toComparableMonoType t == currentKey) toRegister then
        -- O(n) LIST SCAN with repeated toComparableMonoType calls
        processWorklist rest toRegister c
```

**Severity**: MEDIUM - Type registry building can be slow on large programs with deep types

### 4. String Operations in Type Output
**File**: `Context.elm:512`, `Types.elm:352-356`

```elm
-- Context.elm:512 (Kernel signature mismatch error)
showTypes ts = ts |> List.map Types.mlirTypeToString |> String.join ", "
-- Called for EVERY kernel call mismatch (potentially many times)

-- Types.elm:352-356 (mlirTypeToString for function types)
ins = sig.inputs |> List.map mlirTypeToString |> String.join ", "
outs = sig.results |> List.map mlirTypeToString |> String.join ", "
-- Creates intermediate lists, maps, joins
```

**Issue**: Multiple allocations and string joins for error messages and debug output
**Severity**: LOW - Not in performance-critical path (only for errors/debug)

### 5. Inefficient Lambda Deduplication
**File**: `Lambdas.elm:45-62`

```elm
dedupedLambdas =
    let
        ( _, result ) =
            List.foldl
                (\lambda ( seen, acc ) ->
                    if Set.member lambda.name seen then
                        ( seen, acc )
                    else
                        ( Set.insert lambda.name seen, acc ++ [ lambda ] )
                        -- ^^^ LIST APPEND O(n) repeated n times = O(n²)
                )
                ( Set.empty, [] )
                lambdas
    in
    result
```

**Problem**: Uses `acc ++ [lambda]` instead of building in reverse
**Cost**: O(n²) for deduplication
**Severity**: MEDIUM - Only for lambdas, but common operation

### 6. Pattern Match Compilation - Excessive Temporary Structures
**File**: `Patterns.elm:36-54` (lookupFieldByName)

```elm
findFieldInfoByName : Name.Name -> List Types.FieldInfo -> Maybe Types.FieldInfo
findFieldInfoByName targetName fields =
    List.filter (\fi -> fi.name == targetName) fields  -- Creates intermediate list!
        |> List.head

-- Should be:
List.find (\fi -> fi.name == targetName) fields
```

Similar pattern at `Expr.elm:373-376`:
```elm
ListX.find (\( n, _ ) -> n == fieldInfo.name) namedFields
    |> Maybe.map Tuple.second
    |> Maybe.withDefault Mono.MonoUnit
-- Better than List.filter but still allocation-heavy
```

**Severity**: LOW to MEDIUM - Pattern matching is not hot, but could be optimized

### 7. EveryDict Operations with Redundant Comparisons
**File**: `Backend.elm:62`, `Context.elm:680`, `Context.elm:303`

```elm
EveryDict.foldl compare (\specId node ...)  -- Manual comparator
EveryDict.values compare fields              -- Manual comparator for every call
```

**Issue**: Comparators like `compare` are passed and potentially applied multiple times
**Cost**: Minor but adds up in large folds
**Severity**: LOW - Design constraint, not critical

### 8. Dict.fromList Used Repeatedly in Op Building
**File**: Multiple files (Ops.elm, Expr.elm, Functions.elm)

Examples: `Dict.fromList [ ("field", ...), ("value", ...) ]` appears 100+ times
Each creates a dictionary from scratch even though most are static patterns.

**Occurrences**:
- Ops.elm: 196, 214, 232, 262, 302, 357, 375, 393, 411, 484, 579, 749, 818, 848
- Expr.elm: 564, 673, 746, 1024, 1328, 1429, 2240, 2788, 3325, 3899, 4078
- Functions.elm: 484, 769, 850, 928
- TailRec.elm: 494
- BytesFusion/Emit.elm: 308, 340, 372, 404, 1287, 1709, 1875, 2068, 2144

**Severity**: LOW - Individual calls are cheap, but aggregate overhead

### 9. Tail-Recursive Compilation - Variable Allocation Overhead
**File**: `TailRec.elm:124-129` and throughout

```elm
( resultVars, ctx4 ) = allocateFreshVars ctx3 (List.length stateTypes)
-- allocateFreshVars (line 1095-1107):
allocateFreshVars ctx n =
    let ( vars, newCtx ) = foldl (\_ (acc, c) -> 
            let (v, c') = Ctx.freshVar c in (v :: acc, c')
        ) ([], ctx) (List.range 0 (n-1))
    in ( List.reverse vars, newCtx )
```

**Issue**: Allocates fresh var names for every loop state element repeatedly
**Cost**: O(n) allocations per loop structure
**Severity**: MEDIUM - Multiple loops per function

### 10. BytesFusion Type Registry Duplication
**File**: `TypeTable.elm:126-153`

```elm
generateTypeTable : Ctx.Context -> MlirOp
generateTypeTable ctx =
    let
        sortedTypes : List ( Int, Mono.MonoType )
        sortedTypes = ctx.typeRegistry.typeInfos |> List.sortBy Tuple.first
        -- FULL SORT even for large type lists
        
        finalAccum = List.foldl processType emptyAccum sortedTypes
        -- Processing each type with dictionary lookups
```

The type registry already computed type IDs, but sortBy/foldl reprocesses all types.

**Severity**: MEDIUM - Type table generation is not hot path but inefficient

## Summary of Memory Issues

| Issue | Type | File | Severity | Impact |
|-------|------|------|----------|--------|
| Context unbounded growth | Design | Context.elm | HIGH | O(program_size) memory per context |
| O(n²) list concatenation | Algorithm | Backend.elm, Expr.elm | CRITICAL | Quadratic time/memory in hot loops |
| Type registry worklist scan | Algorithm | Context.elm | MEDIUM | Slow on deep types |
| Lambda deduplication | Algorithm | Lambdas.elm | MEDIUM | O(n²) dedup |
| Repeated Mono.toComparableMonoType | Computation | Context.elm | MEDIUM | Redundant work |
| Dict.fromList repetition | Micro | Ops.elm | LOW | 100+ allocations |
| Temporary list creation | Micro | Patterns.elm | LOW | Filter before find |
| Allocate vars in loops | Algorithm | TailRec.elm | MEDIUM | Repeated SSA allocation |
| Full type table sort | Algorithm | TypeTable.elm | MEDIUM | Unnecessary sort of known types |

## Recommendations (High Priority)

1. **Split Context into function-local and global scopes**
   - Clear varMappings between functions
   - Accumulate only truly global data (kernelDecls, typeRegistry)

2. **Replace ++ with builder pattern**
   - Use List.concatMap instead of fold + ++
   - Or use accumulator with reverse

3. **Cache type keys**
   - Compute `Mono.toComparableMonoType` once per type
   - Store in a map for worklist algorithm

4. **Use Set instead of List for worklist**
   - Membership testing becomes O(log n) instead of O(n)

5. **Batch process lambdas efficiently**
   - Use proper accumulator pattern instead of append
