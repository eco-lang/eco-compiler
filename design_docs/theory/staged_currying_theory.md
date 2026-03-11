# Staged Currying Theory

## Overview

Staged currying is a technique for determining how functions should segment their arguments when generating efficient native code. Rather than naively currying all functions (creating closures for each argument), or requiring all arguments at once (losing Elm's currying semantics), staged currying finds an optimal balance.

**Phase**: Global Optimization (GlobalOpt)

**Pipeline Position**: After Monomorphization, before MLIR Generation

**Related Invariant**: **GOPT_003** — All branches of a MonoCase must have compatible calling conventions (staged currying signatures).

**Note**: This logic was moved from Monomorphization to GlobalOpt to achieve a clean separation of concerns: Monomorphization is staging-agnostic and focuses on specialization, while GlobalOpt handles all calling-convention and ABI decisions.

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

## Invariant GOPT_003

**Statement**: All branches of a MonoCase that return functions must have compatible staged currying signatures.

**Rationale**: The case expression's result type must be uniform. If branches return functions with different calling conventions, the caller cannot know how to invoke the result.

**Enforcement**: The `normalizeCaseIfAbi` pass runs during GlobalOpt for any case expression whose result type is a function. It uses `chooseCanonicalSegmentation` to pick a common staging and `buildAbiWrapperGO` to wrap branches that differ.

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

## Callsite Derivation Algorithm

The staging solver uses a graph-based approach to propagate staging constraints across the entire program. This **callsite derivation algorithm** ensures that every callsite uses the correct calling convention.

### The Problem

Consider a function that flows through multiple intermediate bindings:

```elm
adder = \x y -> x + y              -- natural staging [2]
alias = adder                       -- what staging?
result = alias 1 2                  -- how to call?
```

The callsite `alias 1 2` needs to know that `alias` has staging `[2]`. But this information must be propagated from the original closure definition.

### The Graph-Based Solution

1. **Producers**: Every closure/function definition is a **producer** with a natural segmentation.

2. **Slots**: Every place a function value can be stored is a **slot** (variable bindings, function parameters, captures, record fields, etc.).

3. **Edges**: When a producer flows to a slot, an edge is created.

4. **Unification**: When the same value must have consistent staging across locations (e.g., both branches of an if-expression), slots are unified.

5. **Solving**: All nodes in an equivalence class get the same canonical segmentation, chosen by majority vote among the producers in that class.

### Example: Variable Propagation

```elm
f = \x y -> x + y    -- Producer P1, staging [2]
g = f                -- Slot S1
h = g                -- Slot S2, unified with S1
r = h 1 2            -- Callsite: lookup S2's class → [2]
```

Graph edges: P1 → S1 → S2
After solving: class {P1, S1, S2} has staging [2]
The callsite at `h 1 2` queries the staging for S2 and gets [2].

### Kernel Function Integration

Kernel functions have fixed segmentations (all args at once):

```elm
kernelSeg("List_map") = [2]
kernelSeg("Basics_add") = [2]
```

When a kernel flows to a slot, it contributes its fixed segmentation to the equivalence class. If user-defined closures flow to the same class, the kernel's segmentation takes precedence (kernel ABIs are immutable).

## PAP Wrapper Elimination

**PAP Wrapper Elimination** is an optimization that enables direct function calls even when partial application and closures are involved, eliminating the overhead of PAP (partial application) wrapper functions.

### The Problem

Previously, when calling a function that might be a partial application:

```elm
applyTwice f x = f (f x)
```

The generated code had to:
1. Check if `f` is a PAP at runtime
2. If so, call through a generic `papExtend` mechanism
3. This added indirection and prevented optimization

### The Solution: Typed Closure Calling

The compiler now generates **direct calls** by leveraging type information:

1. **Homogeneous Call Path**: When all callsites can be statically determined to have the same closure structure (same captures, same parameter types), generate a direct call with captures unpacked as arguments.

2. **Heterogeneous Call Path**: When the closure structure varies across callsites (e.g., different branches return closures with different captures), generate a call that passes the entire closure pointer.

### ABI Splitting

For heterogeneous cases, the compiler generates two entry points:

```
-- Direct entry (homogeneous): captures unpacked
func_direct(capture1, capture2, arg1, arg2) -> result

-- Indirect entry (heterogeneous): closure passed
func_indirect(closure_ptr, arg1, arg2) -> result
```

The callsite derivation determines which entry point to use based on whether the callee's structure is statically known.

### Benefits

- **No runtime PAP checks**: The calling convention is determined at compile time
- **Direct calls**: Most calls are direct function calls, not indirect through PAP machinery
- **Better optimization**: LLVM can inline and optimize direct calls

## Implementation Details

### Staging Detection

During GlobalOpt, when processing a function:

```
FUNCTION detectStaging(monoExpr):
    CASE monoExpr OF
        MonoClosure closureInfo body _:
            innerStaging = detectStaging(body)
            RETURN [length(closureInfo.params)] ++ innerStaging

        _:
            RETURN []  -- Not a function, no more stages
```

### Integration with GlobalOpt

The GlobalOpt pass runs several phases:

0. *(External)*: `MonoInlineSimplify` - Inline small functions (applied before GlobalOpt)
1. **Phase 1**: `wrapTopLevelCallables` - Wrap bare kernel/global references in closures
2. **Phase 2**: `Staging.analyzeAndSolveStaging` - Build staging graph, solve, and rewrite
3. **Phase 3**: `Staging.validateClosureStaging` - Validate closure staging invariants
4. **Phase 4**: `AbiCloning.abiCloningPass` - Clone functions for homogeneous closure ABIs
5. **Phase 5**: `annotateCallStaging` - Annotate `CallInfo` metadata for MLIR codegen

The staging subsystem in `compiler/src/Compiler/GlobalOpt/Staging/` handles the graph-based solving:

| Module | Purpose |
|--------|---------|
| `Types.elm` | ProducerId, SlotId, Node, StagingGraph types |
| `GraphBuilder.elm` | Build constraint graph from MonoGraph |
| `Solver.elm` | Union-find solver with majority voting |
| `Rewriter.elm` | Apply solution via eta-wrapping |
| `ProducerInfo.elm` | Compute natural segmentations |
| `UnionFind.elm` | Union-find data structure |

The joinpoint matching is now integrated into the graph solver:
1. Both branches of an if/case are connected to the same result slot
2. The solver unifies these slots automatically
3. Non-conforming branches are eta-wrapped during rewriting

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

- **Requires**: Monomorphized expressions (MonoGraph from Monomorphization pass)
- **Enables**: Consistent function ABIs for MLIR code generation
- **Key Insight**: Function staging is a code generation concern, not a semantic one; all stagings produce the same values, just with different performance characteristics

### Why GlobalOpt, Not Monomorphization?

The staging logic was moved from Monomorphization to GlobalOpt to achieve a clean separation of concerns:

**Monomorphization responsibilities** (staging-agnostic):
- Specialize polymorphic functions
- Compute concrete layouts for records, tuples, custom types
- Preserve curried type structure from Elm semantics
- No closure wrappers created due to staging

**GlobalOpt responsibilities** (staging-aware):
- Canonicalize closure types to match param counts
- Generate ABI wrappers for incompatible case branches
- Compute call staging metadata (`CallInfo`) for MLIR
- All calling-convention decisions resolved

**MLIR codegen responsibilities** (staging-consuming):
- Switch on `CallInfo.callModel` (FlattenedExternal vs StageCurried)
- Use pre-computed `CallInfo` fields for partial application
- No independent staging computations

This separation ensures that Monomorphization remains focused on specialization semantics, while all ABI/calling-convention complexity is isolated in GlobalOpt.

**See also**: [Global Optimization Theory](pass_global_optimization_theory.md)
