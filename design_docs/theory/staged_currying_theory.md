# Staged Currying Theory

## Overview

Staged currying is a technique for determining how functions should segment their arguments when generating efficient native code. Rather than naively currying all functions (creating closures for each argument), or requiring all arguments at once (losing Elm's currying semantics), staged currying finds an optimal balance.

**Phase**: Monomorphization

**Pipeline Position**: Integrated into monomorphization pass

**Related Invariant**: **MONO_018** — All branches of a MonoCase must have compatible calling conventions (staged currying signatures).

## Motivation

Elm functions are semantically curried: `add : Int -> Int -> Int` can be partially applied as `add 1` to get an `Int -> Int` function. However, native code generation benefits from knowing when multiple arguments will always be applied together.

Consider:
```elm
map2 : (a -> b -> c) -> List a -> List b -> List c
map2 f xs ys = ...
```

In practice, `map2` is almost always called with all three arguments. Generating a fully curried version (closure for each argument) wastes allocation and introduces indirection. Staged currying detects this pattern and generates a version that takes all three arguments at once.

## Core Concepts

### Staging Signature

A staging signature describes how a function's arguments are grouped:

```elm
-- Staging [3] means: take 3 args at once, return result
-- Staging [2,1] means: take 2 args, return closure taking 1 arg
-- Staging [1,1,1] means: fully curried
```

For `\a b -> \c -> body`:
- The programmer wrote two lambdas: one taking `a,b` and one taking `c`
- Natural staging is `[2,1]`: take 2 args, return closure that takes 1 arg

### Staged Function Representation

```elm
type MonoStagedFunction
    = MonoStagedFunction
        { params : List (Name, MonoType)      -- All parameters
        , staging : List Int                   -- Argument grouping
        , captures : List (Name, MonoType)    -- Captured variables
        , body : MonoExpr
        , resultType : MonoType
        }
```

### Compatibility

Two staging signatures are compatible if they have the same total arity and grouping:

```
[3] compatible with [3]           -- same
[2,1] compatible with [2,1]       -- same
[3] NOT compatible with [2,1]     -- different grouping
```

## Joinpoint Matching Algorithm

When a case expression returns functions from different branches, we must ensure all branches have compatible calling conventions. The joinpoint matching algorithm determines a common staging and transforms non-conforming branches.

### The Problem

```elm
chooser : Bool -> (Int -> Int -> Int)
chooser b =
    if b then
        \x y -> x + y          -- natural staging: [2]
    else
        \x -> \y -> x * y      -- natural staging: [1,1]
```

Each branch has a different natural staging. We cannot return different function types from the same case expression.

### Algorithm: Majority Staging

1. **Collect stagings**: Gather the natural staging from each branch
2. **Find majority**: Select the most common staging pattern
3. **Transform non-conforming**: Wrap branches with different stagings in eta-wrappers

```
FUNCTION computeJoinpointStaging(branches):
    stagings = [getStaging(branch) | branch <- branches]

    -- Count occurrences of each staging
    counts = groupAndCount(stagings)

    -- Select majority (ties broken by preferring larger groups)
    majorityStaging = selectMajority(counts)

    -- Transform branches
    FOR EACH branch IN branches:
        branchStaging = getStaging(branch)
        IF branchStaging != majorityStaging:
            branch' = wrapWithEta(branch, majorityStaging)
            REPLACE branch WITH branch'

    RETURN majorityStaging
```

### Eta-Wrapping

To convert a `[1,1]` function to `[2]`:

```elm
-- Original: \x -> \y -> x * y
-- Wrapped:  \x y -> (\x -> \y -> x * y) x y
```

The wrapper immediately applies all arguments, eliminating the intermediate closure.

### Example Transformation

```elm
-- Before:
chooser b =
    if b then
        \x y -> x + y          -- [2]
    else
        \x -> \y -> x * y      -- [1,1]

-- After (majority is [2]):
chooser b =
    if b then
        \x y -> x + y          -- [2], unchanged
    else
        \x y -> (\x -> \y -> x * y) x y   -- [1,1] wrapped to [2]
```

## Invariant MONO_018

**Statement**: All branches of a MonoCase that return functions must have compatible staged currying signatures.

**Rationale**: The case expression's result type must be uniform. If branches return functions with different calling conventions, the caller cannot know how to invoke the result.

**Enforcement**: The joinpoint matching algorithm runs during monomorphization for any case expression whose result type is a function.

**Violation Detection**: If no majority can be determined (e.g., all branches different) or transformation fails, this is a compiler bug.

## Kernel Function Special Case

Kernel functions (runtime primitives implemented in C++) cannot be stage-curried. They have fixed ABIs that expect all arguments at once.

```elm
-- Kernel function: List.map
-- ABI: (fn: eco.value, list: eco.value) -> eco.value
-- Cannot be split into stages
```

When a kernel function is partially applied in Elm code:
1. A PAP (partial application) wrapper is generated
2. The wrapper accumulates arguments until all are available
3. Only then is the kernel function called

```elm
-- Elm code:
mappedList = List.map f

-- Generated wrapper:
-- pap_List_map_1 : eco.value -> eco.value -> eco.value
-- pap_List_map_1 arg0 arg1 = List_map(arg0, arg1)
```

## Implementation Details

### Staging Detection

During monomorphization, when processing a function:

```
FUNCTION detectStaging(monoExpr):
    CASE monoExpr OF
        MonoFunction params _ body _:
            innerStaging = detectStaging(body)
            RETURN [length(params)] ++ innerStaging

        _:
            RETURN []  -- Not a function, no more stages
```

### Integration with Monomorphization

The joinpoint matching algorithm is invoked:
1. When monomorphizing a `MonoCase` expression
2. Whose branches return `MFunction` types
3. Before the branches are individually specialized

### Cost Model

Eta-wrapping has a cost: it creates a closure and introduces an extra call. The algorithm prefers to minimize total wrapping:

```
FUNCTION selectMajority(counts):
    -- Sort by (count DESC, totalArgs DESC)
    -- Larger groups preferred (fewer wraps needed)
    -- More args preferred (bigger functions worth preserving)
    sorted = sortBy(counts, \(staging, count) -> (-count, -sum(staging)))
    RETURN first(sorted).staging
```

## Example: Complex Case

```elm
process : Int -> (Int -> Int -> Int)
process n =
    case n of
        0 -> \x y -> x
        1 -> \x -> \y -> y
        2 -> \x y -> x + y
        _ -> \x -> \y -> x - y
```

Stagings: `[2]`, `[1,1]`, `[2]`, `[1,1]`

Counts: `[2] -> 2`, `[1,1] -> 2`

Tie-breaker: `[2]` wins (larger first group, more args at once)

Result: Branches 1 and 3 get eta-wrapped to `[2]`.

## Relationship to Other Passes

- **Requires**: Type-checked monomorphized expressions
- **Enables**: Consistent function ABIs for code generation
- **Key Insight**: Function staging is a code generation concern, not a semantic one; all stagings produce the same values, just with different performance characteristics
