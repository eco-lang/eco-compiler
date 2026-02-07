# Global Optimization Pass

## Overview

The Global Optimization (GlobalOpt) pass transforms the monomorphized IR to prepare it for MLIR code generation. Its primary responsibilities are canonicalizing function staging, normalizing calling conventions across case/if branches, and computing call metadata for the code generator.

**Phase**: Global Optimization

**Pipeline Position**: After Monomorphization, before MLIR Generation

**Key Invariants**:
- **GOPT_001** — Closure types match param counts
- **GOPT_002** — Returned closure param counts are tracked
- **GOPT_003** — Case/if branches have compatible staging

## Purpose

GlobalOpt exists to create a clean separation between:

1. **Monomorphization** — Focuses on specializing polymorphic code, producing curried, staging-agnostic types that reflect Elm semantics
2. **GlobalOpt** — Resolves all staging and calling-convention decisions
3. **MLIR Codegen** — Consumes canonical types without making independent staging decisions

This separation ensures that Monomorphization remains simple and focused, while all ABI complexity is isolated in one phase.

## Input and Output

**Input**: `MonoGraph` from Monomorphization with:
- Curried function types (e.g., `MFunction [Int] (MFunction [Int] Int)`)
- Closures with params that may not match their type's stage arity
- Case/if expressions with branches that may have incompatible stagings
- No call metadata (`CallInfo` uses defaults)

**Output**: `MonoGraph` with:
- Canonical flat function types (e.g., `MFunction [Int, Int] Int`)
- All closures have types matching their param counts (GOPT_001)
- All case/if branches have compatible stagings (GOPT_003)
- All calls have computed `CallInfo` metadata for codegen

## The Four Phases

GlobalOpt runs four sequential phases:

```elm
globalOptimize typeEnv graph0 =
    let
        -- Phase 1: Canonicalize closure/tail-func types (GOPT_001)
        graph1 = canonicalizeClosureStaging graph0

        -- Phase 2: ABI normalization (case/if result types, wrapper generation)
        graph2 = normalizeCaseIfAbi graph1

        -- Phase 3: Closure staging invariant validation
        graph3 = validateClosureStaging graph2

        -- Phase 4: Annotate call staging metadata
        graph4 = annotateCallStaging graph3
    in
    graph4
```

### Phase 1: Canonicalize Closure Staging

**Function**: `canonicalizeClosureStaging`

**Purpose**: Flatten nested `MFunction` types to match the closure's actual param count.

**Example**:
```elm
-- Before: closure with params=[x,y], type=MFunction [Int] (MFunction [Int] Int)
-- After:  closure with params=[x,y], type=MFunction [Int, Int] Int
```

**Algorithm**:
1. Walk all nodes in the graph
2. For each `MonoClosure`, use `flattenTypeToArity` to adjust its type
3. For each `MonoTailFunc`, similarly flatten its type

**Key function**: `flattenTypeToArity targetArity monoType`
- Flattens nested `MFunction` to match `targetArity`
- If type has more args than params, keeps the rest nested
- If type has fewer args than params, reports GOPT_001 violation

### Phase 2: ABI Normalization

**Function**: `normalizeCaseIfAbi`

**Purpose**: Ensure all case/if branches returning functions have compatible calling conventions.

**The Problem**:
```elm
chooser b =
    if b then
        \x y -> x + y          -- staging [2]
    else
        \x -> \y -> x * y      -- staging [1,1]
```

Each branch has a different staging signature. The caller cannot know how to invoke the result.

**Solution**:
1. Use `chooseCanonicalSegmentation` to pick the majority staging
2. Use `buildAbiWrapperGO` to wrap non-conforming branches

**Algorithm** (`rewriteExprForAbi`):
1. For case expressions: collect leaf types, pick canonical segmentation, wrap branches
2. For if expressions: similarly normalize branch results
3. For closures: ensure they're properly formed via `ensureCallableForNode`

**Key functions**:
- `chooseCanonicalSegmentation`: Picks the most common staging pattern
- `buildAbiWrapperGO`: Creates wrapper closures that adapt one staging to another
- `ensureCallableForNode`: Wraps non-closure function values in closures

### Phase 3: Validate Closure Staging

**Function**: `validateClosureStaging`

**Purpose**: Verify that all closures now satisfy GOPT_001 (types match param counts).

**Algorithm**: Walk all closures and check that `length(params) == stageParamCount(type)`.

**Failure**: If validation fails after phases 1-2, it indicates a bug in the transformation logic.

### Phase 4: Annotate Call Staging

**Function**: `annotateCallStaging`

**Purpose**: Compute `CallInfo` metadata that MLIR codegen needs.

**CallInfo structure**:
```elm
type alias CallInfo =
    { callModel : CallModel         -- FlattenedExternal | StageCurried
    , stageArities : List Int       -- Full stage segmentation
    , isSingleStageSaturated : Bool -- All args provided in one call?
    , initialRemaining : Int        -- Source PAP's remaining_arity
    , remainingStageArities : List Int  -- Arities for subsequent stages
    }
```

**Algorithm** (`computeCallInfo`):
1. Determine `callModel` based on callee type (kernel vs user-defined)
2. For `StageCurried` calls:
   - Compute `stageArities` from function type
   - Compute `sourceArity` from closure's actual param count
   - Determine if call is single-stage saturated
   - Compute remaining stage arities for partial applications

**Why this matters**: MLIR's `generateCall` switches on `callInfo.callModel` and uses the pre-computed arities for `papExtend` operations.

## Key Data Structures

### Segmentation

```elm
type alias Segmentation = List Int
-- [2, 1] means: take 2 args, return closure taking 1 arg
```

### CallModel

```elm
type CallModel
    = FlattenedExternal  -- Kernel/extern: all args at once
    | StageCurried       -- User-defined: respect staging
```

### GlobalCtx

```elm
type alias GlobalCtx =
    { graph : MonoGraph
    , registry : SpecializationRegistry
    , nextLambdaIndex : Int  -- For generating fresh lambda IDs
    }
```

## Relationship to Other Passes

### Depends On

- **Monomorphization**: Provides `MonoGraph` with specialized functions and computed layouts

### Enables

- **MLIR Generation**: Consumes canonical types and `CallInfo` metadata

### Key Insight

By moving all staging logic to GlobalOpt:

1. **Monomorphization** remains simple — just specialize polymorphic code
2. **GlobalOpt** handles all the complexity of ABI normalization
3. **MLIR codegen** becomes straightforward — just consume pre-computed metadata

## Implementation Notes

### Module Location

`compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

### Helper Modules

- `MonoReturnArity.elm`: Stage arity computation utilities
- `Closure.elm` (in Monomorphize): Shared utilities like `flattenFunctionType`

### Key Functions

| Function | Purpose |
|----------|---------|
| `globalOptimize` | Main entry point |
| `canonicalizeClosureStaging` | Phase 1: flatten types |
| `normalizeCaseIfAbi` | Phase 2: ABI wrappers |
| `validateClosureStaging` | Phase 3: validation |
| `annotateCallStaging` | Phase 4: compute CallInfo |
| `flattenTypeToArity` | Flatten MFunction types |
| `buildAbiWrapperGO` | Create staging adapters |
| `chooseCanonicalSegmentation` | Pick majority staging |
| `computeCallInfo` | Build CallInfo for a call |

## Example: Full Transformation

**Input** (after Monomorphization):
```elm
chooser : Bool -> (Int -> Int -> Int)
chooser b =
    if b then
        MonoClosure {params=[x,y]} body1 (MFunction [Int] (MFunction [Int] Int))
    else
        MonoClosure {params=[x]} body2 (MFunction [Int] (MFunction [Int] Int))
            -- where body2 = MonoClosure {params=[y]} ... (MFunction [Int] Int)
```

**After Phase 1** (canonicalizeClosureStaging):
```elm
-- First closure: params=[x,y], type flattened to MFunction [Int, Int] Int
-- Second closure: params=[x], type remains MFunction [Int] (MFunction [Int] Int)
--   (because it only takes 1 param, returning another closure)
```

**After Phase 2** (normalizeCaseIfAbi):
```elm
-- Canonical staging chosen: [2] (majority wins)
-- First branch: unchanged (already [2])
-- Second branch: wrapped with buildAbiWrapperGO to become [2]
chooser b =
    if b then
        MonoClosure {params=[x,y]} body1 (MFunction [Int, Int] Int)
    else
        MonoClosure {params=[x,y]} wrapperBody (MFunction [Int, Int] Int)
            -- where wrapperBody calls the original [1,1] closure with x, then y
```

**After Phase 4** (annotateCallStaging):
```elm
-- All MonoCall expressions now have CallInfo:
--   callModel = StageCurried
--   stageArities = [2]
--   isSingleStageSaturated = true (if called with 2 args)
```

## See Also

- [Staged Currying Theory](staged_currying_theory.md) — Detailed theory of staging
- [Monomorphization Theory](pass_monomorphization_theory.md) — The preceding pass
- [MLIR Generation Theory](pass_mlir_generation_theory.md) — The following pass
