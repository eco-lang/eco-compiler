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

## The Phases

GlobalOpt runs several sequential phases, coordinated by a common traversal infrastructure:

```elm
globalOptimize typeEnv graph0 =
    let
        -- Phase 0: Inlining and simplification
        (graph0a, _) = MonoInlineSimplify.optimize typeEnv graph0

        -- Phase 0.5: Wrap top-level callables in closures
        graph0b = wrapTopLevelCallables graph0a

        -- Phase 1: Staging analysis via graph-based solver
        stagingResult = Staging.solveStaging typeEnv graph0b

        -- Phase 2: Rewrite graph with staging solution
        graph1 = Staging.rewriteWithStaging stagingResult graph0b

        -- Phase 3: Validate closure staging
        graph2 = validateClosureStaging graph1

        -- Phase 4: Annotate call staging metadata
        graph3 = annotateCallStaging graph2
    in
    graph3
```

### MonoTraverse: Common Iteration Infrastructure

The `MonoTraverse` module provides a unified way to walk the `MonoGraph`:

```elm
-- Traverse all nodes, accumulating state
traverseGraph : (MonoNode -> State -> State) -> State -> MonoGraph -> State

-- Transform nodes, building new graph
mapGraph : (MonoNode -> MonoNode) -> MonoGraph -> MonoGraph

-- Walk expressions within a node
traverseExpr : (MonoExpr -> State -> State) -> State -> MonoExpr -> State
```

This eliminates duplicate traversal code and ensures consistent handling across all transformation phases.

### Phase 0.5: Wrap Top-Level Callables

**Function**: `wrapTopLevelCallables` (calls `ensureCallableForNode` per node)

**Purpose**: Ensure all top-level function-typed values (Define, PortIncoming, PortOutgoing) are `MonoClosure` before the staging solver runs. Bare `MonoVarKernel` and `MonoVarGlobal` references are wrapped in alias closures; other function-typed expressions become general closures.

**Why before staging**: The staging producer graph should only see closures (for user functions and alias wrappers) or tail-funcs/`MonoExtern`. Bare `MonoVarKernel`/`MonoVarGlobal` references have no segmentation info and would confuse staging analysis.

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
3. For closures: verify they're properly formed (wrapping was done in Phase 0.5)

**Key functions**:
- `chooseCanonicalSegmentation`: Picks the most common staging pattern
- `buildAbiWrapperGO`: Creates wrapper closures that adapt one staging to another
- `ensureCallableForNode`: Wraps non-closure function values in closures (called in Phase 0.5)

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

## The Staging Subsystem

The staging analysis is implemented as a graph-based constraint solver in `compiler/src/Compiler/GlobalOpt/Staging/`. This subsystem determines the canonical segmentation for all functions by analyzing data flow through the program.

### Architecture

The staging subsystem has six modules:

| Module | Purpose |
|--------|---------|
| `Types.elm` | Core types: Segmentation, ProducerId, SlotId, Node, StagingGraph |
| `GraphBuilder.elm` | Builds the staging graph from MonoGraph |
| `Solver.elm` | Union-find based solver choosing canonical segmentations |
| `Rewriter.elm` | Rewrites MonoGraph with solved segmentations |
| `ProducerInfo.elm` | Computes natural segmentation for each producer |
| `UnionFind.elm` | Union-find data structure for equivalence classes |

### The Staging Graph

The staging graph connects **producers** (functions) to **slots** (places where function values flow):

```elm
type ProducerId
    = ProducerClosure LambdaId    -- User-defined closure
    | ProducerTailFunc Int        -- Tail-recursive function
    | ProducerKernel String       -- Kernel function

type SlotId
    = SlotVar String Int          -- Variable binding
    | SlotParam Int Int           -- Function parameter
    | SlotCapture LambdaId Int    -- Closure capture
    | SlotIfResult Int            -- If branch result
    | SlotCaseResult Int          -- Case branch result
    | SlotRecord String String    -- Record field
    | SlotTuple String Int        -- Tuple element
    | SlotList String Int         -- List element
    | SlotCtor String Int         -- Constructor argument

type Node
    = NodeProducer ProducerId
    | NodeSlot SlotId
```

Edges connect producers to slots when a function value flows to that location. When two slots must have the same segmentation (e.g., both branches of an if expression), they are unified.

### The Solving Algorithm

1. **Build Graph**: `GraphBuilder.buildStagingGraph` traverses the MonoGraph, creating nodes for all producers and slots, and edges for data flow.

2. **Compute ProducerInfo**: For each producer, determine its **natural segmentation** from its parameter structure:
   ```elm
   -- \x y -> \z -> body has natural segmentation [2, 1]
   detectNaturalSegFromParams : MonoClosure -> Segmentation
   ```

3. **Build Equivalence Classes**: Using union-find, group all nodes that must have the same segmentation (e.g., branches of case expressions).

4. **Choose Canonical Segmentation**: For each equivalence class, use majority voting:
   ```elm
   chooseCanonicalSegs : Dict ClassId (List Segmentation) -> Dict ClassId Segmentation
   ```
   - Kernel functions provide fixed segmentations
   - Among user functions, the most common segmentation wins
   - Ties broken by preferring larger first stage (more args at once)

5. **Rewrite Graph**: `Rewriter.applyStagingSolution` transforms closures whose natural segmentation differs from the canonical one by wrapping them in eta-expansion closures.

### Example: Solving Case Branch Staging

```elm
picker b =
    if b then
        \x y -> x + y      -- Producer P1, natural seg [2]
    else
        \x -> \y -> x * y  -- Producer P2, natural seg [1,1]
```

1. **Graph building**:
   - P1 → SlotIfResult(0)
   - P2 → SlotIfResult(0)
   - SlotIfResult(0) unified because both branches flow to same result

2. **Equivalence class**: {P1, P2, SlotIfResult(0)}

3. **Majority vote**: [2] appears once, [1,1] appears once → tie broken by larger first stage → [2] wins

4. **Rewrite**: P2 gets wrapped: `\x y -> ((\x -> \y -> x * y) x) y`

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

- `MonoTraverse.elm`: Common iteration infrastructure for graph traversal
- `MonoReturnArity.elm`: Stage arity computation utilities
- `MonoInlineSimplify.elm`: Small function inlining pass (Phase 0)
- `Staging/`: Graph-based staging solver subsystem
  - `Types.elm`: Core types (ProducerId, SlotId, Node, StagingGraph)
  - `GraphBuilder.elm`: Builds staging graph from MonoGraph
  - `Solver.elm`: Union-find solver with majority voting
  - `Rewriter.elm`: Applies staging solution to MonoGraph
  - `ProducerInfo.elm`: Computes natural segmentations
  - `UnionFind.elm`: Union-find data structure
- `Closure.elm` (in Monomorphize): Shared utilities like `flattenFunctionType`

### Key Functions

| Function | Module | Purpose |
|----------|--------|---------|
| `globalOptimize` | MonoGlobalOptimize | Main entry point |
| `wrapTopLevelCallables` | MonoGlobalOptimize | Phase 0.5: wrap bare globals/kernels |
| `buildStagingGraph` | Staging.GraphBuilder | Build staging constraint graph |
| `solveStagingGraph` | Staging.Solver | Solve for canonical segmentations |
| `applyStagingSolution` | Staging.Rewriter | Rewrite closures to canonical form |
| `computeProducerInfo` | Staging.ProducerInfo | Compute natural segmentations |
| `flattenTypeToArity` | Staging.Rewriter | Flatten MFunction types |
| `wrapClosureToCanonical` | Staging.Rewriter | Create staging adapters |
| `chooseCanonicalSegs` | Staging.Solver | Pick majority staging per class |
| `mapExpr` / `traverseExpr` | MonoTraverse | Common graph iteration |

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
