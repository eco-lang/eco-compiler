# Global Optimization Pass

## Overview

The Global Optimization (GlobalOpt) pass transforms the monomorphized IR to prepare it for MLIR code generation. Its primary responsibilities are regrouping function types to their closures' parameter counts, specializing closure ABIs (AbiCloning), and computing call metadata for the code generator.

**Phase**: Global Optimization

**Pipeline Position**: After Monomorphization, before MLIR Generation

**Key Invariants**:
- **GOPT_001** — Closure types match param counts
- **GOPT_002** — Returned closure param counts are tracked
- **GOPT_003** — A function-valued case/if claims no staging beyond what all its branches agree on *(rewritten Oct 2026)*
- **GOPT_011-014** — Calling convention invariants (source arity, TailDef arity, closure capture arity, let-bound function arity) *(Mar 2026)*

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
- Case/if expressions whose function-valued branches may have different stagings
- No call metadata (`CallInfo` uses defaults)

**Output**: `MonoGraph` with:
- Canonical flat function types (e.g., `MFunction [Int, Int] Int`)
- All closures have types matching their param counts (GOPT_001)
- Case/if branches keep their own staging; no call claims a staging the branches do not all share (GOPT_003)
- All calls have computed `CallInfo` metadata for codegen

## The Phases

GlobalOpt runs several sequential phases, coordinated by a common traversal infrastructure:

```elm
-- MonoInlineSimplify.optimize is applied externally before globalOptimize.

globalOptimizeWithStats census stagingCensus borrowCfg listMapTemplate graph0 =
    let
        -- Phase 1: Wrap top-level callables in closures
        graph1 = wrapTopLevelCallables graph0

        -- Phase 2: Regroup closure types to their param counts (GOPT_001)
        graph2 = Staging.regroup graph1

        -- (No Phase 3: the no-op validateClosureStaging was removed, Oct 2026)

        -- Phase 4: ABI Cloning
        ( graph4Full, abiStats ) = AbiCloning.abiCloningPass census graph2

        -- Drop the LSS member tables AbiCloning was the last reader of
        graph4 = Mono.clearLssTables { keepOrigins = ... } graph4Full

        -- Phase 5: Annotate call staging metadata
        graph5 = annotateCallStaging graph4

        -- Phase 6: Borrow inference (only when borrow.enabled)
        ( graph6, borrowStats ) = Borrow.run borrowCfg graph5
    in
    ( graph6, stats )
```

`globalOptimize` is `globalOptimizeWithStats` at the default configuration. In a
build, `Builder.Generate` runs it through `Compiler.Pipeline.Steps` (the middle-end
steps shared with the test harness `TestLogic.TestPipeline`), which then runs CSE,
CAF dedupe and CAF hoisting, each behind its flag. Under `mono.validate`
(`ECO_MONO_VALIDATE=1`) `Steps.checkClosureStaging` checks GOPT_001 after global
optimization.

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

### Phase 1: Wrap Top-Level Callables

**Function**: `wrapTopLevelCallables` (calls `ensureCallableForNode` per node)

**Purpose**: Ensure all top-level function-typed values (Define, PortIncoming, PortOutgoing) are `MonoClosure` before staging regroups their types. Bare `MonoVarKernel` and `MonoVarGlobal` references are wrapped in alias closures; other function-typed expressions become general closures.

**Why before staging**: Regrouping only rewrites the types of closures and tail functions. Wrapping first means every top-level function value is a closure (user functions and alias wrappers) or a tail function/`MonoExtern`, whose param count determines its first stage; a bare `MonoVarKernel`/`MonoVarGlobal` reference has no param list to regroup to.

### Phase 2: Staging Regroup

**Function**: `Staging.regroup : MonoGraph -> MonoGraph`

**Purpose**: Establish GOPT_001. Monomorphization keeps every function type curried, one argument per stage. `regroup` rewrites the type of every `MonoClosure` and `MonoTailFunc` with `flattenTypeToArity (number of params)`: the first stage takes exactly the closure's parameters and the remaining arguments form one further stage, with the head lambda-set annotation copied onto every stage arrow. Every `MonoDefine` takes its rewritten expression's type. It creates no values (no wrappers).

**Type Flattening Example**:
```elm
-- Before: closure with params=[x,y], type=MFunction [Int] (MFunction [Int] Int)
-- After:  closure with params=[x,y], type=MFunction [Int, Int] Int
```

**Joins are not normalized.** A function-valued `case`/`if` whose branches are staged differently keeps each branch's own staging:

```elm
chooser b =
    if b then
        \x y -> x + y          -- staging [2]
    else
        \x -> \y -> x * y      -- staging [1,1]
```

GOPT_003: `closureBodyStageArities` returns `Nothing` unless every branch (case jump targets and decider `Inline` leaves; if branches and the else) is a closure with the same stage arities, so a call through such a join is `CallSegmentationUnknown`/`CallGenericApply` and the runtime applies it by the closure header. Pre-mono η-expansion to declared arity removes such a join when it is a definition's whole body (here `chooser` becomes a function of three arguments); joins that survive (let-bound, in a list, passed as an argument, in a record field) are applied generically.

### Phase 3 (removed)

`Staging.validateClosureStaging` was a no-op and was removed (Oct 2026). GOPT_001 is now checked at compile time under `mono.validate` (`ECO_MONO_VALIDATE=1`) by `Compiler.Pipeline.Steps.checkClosureStaging`, which reports every closure and tail function whose param count differs from its type's first stage (`Staging.checkClosureStaging`). The phase numbers below are kept as they appear in the code.

### Phase 4: ABI Cloning

**Function**: `AbiCloning.abiCloningPass`

**Purpose**: Ensure homogeneous closure parameters. Clones functions when a closure-typed parameter receives different capture ABIs at different call sites.

### Phase 5: Annotate Call Staging

**Function**: `annotateCallStaging`

**Purpose**: Compute `CallInfo` metadata that MLIR codegen needs.

A callee is *dynamic* (`isDynamicCallee`) when it is a `MonoVarLocal` naming a function-typed parameter of the enclosing `MonoTailFunc` (`CallEnv.dynamicParams`). This set used to be the staging solver's `dynamicSlots` output; it was always exactly these parameters.

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

**`sourceArityForCallee` fallback** *(Apr 2026)*: `sourceArityForCallee` now has a fallback path that fixes CGEN_052 (root cause: missing arity on some let-bound callees). After `InlineSimplify`, `callEdges`, `specHasEffects`, and `specValueUsed` are dropped for memory.

## The Staging Subsystem

Staging is the single module `compiler/src/Compiler/GlobalOpt/Staging.elm`, exposing `regroup` (Phase 2) and `checkClosureStaging` (the GOPT_001 check run by `Compiler.Pipeline.Steps` under `mono.validate`). See Phase 2 above.

### History: the staging solver (removed Oct 2026)

Until October 2026 staging was a graph-based constraint solver in `compiler/src/Compiler/GlobalOpt/Staging/` (`Types`, `GraphBuilder`, `ProducerInfo`, `UnionFind`, `Solver`, `Rewriter`). It built a graph of function producers (closures, tail functions, kernels) and slots (if/case results, captures, record/tuple/list slots, parameters), unioned them into equivalence classes, picked a canonical segmentation per class by majority vote (ties to the larger first stage), and wrapped disagreeing producers in eta-expansion closures. `MonoGlobalOptimize` also carried a separate case/if "ABI normalizer" (`rewriteExprForAbi`, `computeBranchNormalization`, `buildAbiWrapperGO`, `buildNestedCallsGO`, ...) that nothing called.

Both were removed (plans/staging-honesty-and-production-test-pipeline.md P2/P3). Measured, the solver inserted **zero** wrappers in the self-compile (38,624 classes, none disagreeing), the E2E corpus (936 programs, 8,412 classes) and 1,124 elm-test programs. The graph builder never looked into a case's decision-tree `Inline` leaves (where nearly all branches live), never connected function arguments to parameters, and never traced let-bound variables; pre-mono η-expansion to declared arity dissolves the joins a vote could have reconciled. The type regrouping was the only effect, and the output is byte-identical without the solver. Its other output, `dynamicSlots`, is now `CallEnv.dynamicParams` (Phase 5).

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

### CallKind *(Mar 2026)*

Determines the calling convention for each call site:

```elm
type CallKind
    = CallDirectKnownSegmentation  -- Arity statically known, staged call
    | CallDirectFlat               -- Flat external call (kernels)
    | CallGenericApply             -- Safe fallback: runtime arity dispatch
```

**`CallGenericApply` / `segmentation_unknown`**: When the compiler cannot statically determine a closure's arity (e.g., closures flowing through case branches with different staging, higher-order callbacks from polymorphic combinators), it falls back to `CallGenericApply`. The runtime `eco_apply_*` wrappers handle dynamic arity dispatch, avoiding over-application crashes.

### isPureExpr Fix *(Apr 2026)*

`isPureExpr` in `MonoInlineSimplify` had two bugs:
- `MonoLet` only checked the body for purity (ignoring the bound expression)
- `MonoCase` only checked the branch jump-target list (ignoring Inline expressions inside the Decider tree)

This caused effectful code (e.g., `Debug.log` inside a single-constructor case) to be incorrectly eliminated as dead code.

### Value-Only Recursive Cycles *(Apr 2026)*

Value-only recursive cycles (zero-arg bindings referencing each other) were previously compiled as a single `MonoCycle` node wrapping all bindings in an `eco.construct.record`, producing a spurious `Record(Custom(PAP))` at runtime. The fix compiles each zero-arg binding as its own `MonoDefine` node (mirroring how function cycles already work). The `MonoCycle` constructor was deleted as dead code.

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
2. **GlobalOpt** handles all staging and calling-convention decisions
3. **MLIR codegen** becomes straightforward — just consume pre-computed metadata

## Implementation Notes

### Module Location

`compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

### Helper Modules

- `MonoTraverse.elm`: Common iteration infrastructure for graph traversal
- `MonoReturnArity.elm`: Stage arity computation utilities
- `MonoInlineSimplify.elm`: Small function inlining pass (applied externally before GlobalOpt)
- `Staging.elm`: Type regrouping to param counts (`regroup`) and the GOPT_001 check (`checkClosureStaging`)
- `AbiCloning.elm`: Phase 4
- `Compiler/Pipeline/Steps.elm`: The middle-end steps shared by `Builder.Generate` and `TestLogic.TestPipeline` (runs GlobalOpt, then CSE/CAF dedupe/CAF hoist, and the `mono.validate` checks)
- `Closure.elm` (in Monomorphize): Shared utilities like `flattenFunctionType`

### Key Functions

| Function | Module | Purpose |
|----------|--------|---------|
| `globalOptimize` | MonoGlobalOptimize | Main entry point |
| `wrapTopLevelCallables` | MonoGlobalOptimize | Phase 1: wrap bare globals/kernels |
| `regroup` | Staging | Phase 2: regroup closure/tail-func types to param counts (GOPT_001) |
| `flattenTypeToArity` | Staging (internal) | Flatten MFunction types to a param count |
| `checkClosureStaging` | Staging | List GOPT_001 violations |
| `checkClosureStaging` | Pipeline.Steps | Run the GOPT_001 check under `mono.validate` |
| `closureBodyStageArities` | MonoGlobalOptimize | Stage arities of a callee body; `Nothing` for a join whose branches disagree (GOPT_003) |
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

**After Phase 2** (`Staging.regroup`):
```elm
-- Each closure's type is regrouped to its own param count; no wrapper is made.
chooser b =
    if b then
        MonoClosure {params=[x,y]} body1 (MFunction [Int, Int] Int)
    else
        MonoClosure {params=[x]} body2 (MFunction [Int] (MFunction [Int] Int))
```

**After Phase 5** (annotateCallStaging):
```elm
-- All MonoCall expressions now have CallInfo. A call through `chooser b`
-- reaches a join whose branches disagree, so closureBodyStageArities is
-- Nothing and the call is CallSegmentationUnknown / CallGenericApply:
-- the runtime applies the selected closure by its header (GOPT_003).
```

(In a production build pre-mono η-expansion rewrites `chooser` to take all three arguments, so this join does not survive to GlobalOpt.)

## See Also

- [Staged Currying Theory](staged_currying_theory.md) — Detailed theory of staging
- [Monomorphization Theory](pass_monomorphization_theory.md) — The preceding pass
- [MLIR Generation Theory](pass_mlir_generation_theory.md) — The following pass
