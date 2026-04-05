# MonoDirect: Solver-Directed Monomorphization (Experimental)

## Status

**Experimental / Incomplete.** MonoDirect is a test-only alternative to the production monomorphization pass. It is not wired into the compiler pipeline and its test suites are currently `Test.skip`'d. This document describes the design intent and current state for reference and future development.

## Overview

MonoDirect is an experimental reimplementation of the monomorphization pass that resolves types directly from the type solver's union-find structure rather than through string-based type substitution. The hypothesis is that solver-directed resolution is more direct, less error-prone, and avoids the canonicalization issues inherent in reconstructing types from textual `Can.Type` representations.

**Files**: `compiler/src/Compiler/MonoDirect/` (4 modules), `compiler/tests/TestLogic/Monomorphize/MonoDirect*.elm`

**Pipeline Position**: Same as production monomorphization — after Typed Optimization, before GlobalOpt. Accessed only via `TestPipeline.runToMonoDirect`.

## Motivation

The production monomorphizer (`Compiler.Monomorphize.*`) resolves polymorphic types through `TypeSubst`: it unifies a function's `Can.Type` annotation against the requested `MonoType` to build a `Dict String MonoType` substitution, then applies that substitution to every sub-expression's type. This works but has known friction points:

1. **String-based matching**: Type variable names must align between the annotation and the solver's output. Alpha-renaming, shadowing, and let-generalization can create mismatches.
2. **Reconstruction overhead**: Converting between `Can.Type` and `MonoType` via substitution is an indirect path — the solver already computed the concrete types.
3. **Two-phase accessor specialization**: Accessors (`.fieldName`) require deferred specialization because their record type depends on the call site. The TypeSubst approach handles this but adds complexity.

MonoDirect's approach: instead of reconstructing types from annotations, ask the solver snapshot directly for each expression's concrete type via its type variable.

## Architecture

### Type Resolution via SolverSnapshot

The key abstraction is `SolverSnapshot`, a frozen copy of the type solver's union-find state. For each specialization, MonoDirect:

1. Installs the requested type binding into the union-find: `(annotationTvar, requestedMonoType)`
2. Resolves each sub-expression's type by calling `view.monoTypeOf tvar` on its solver type variable
3. Falls back to TypeSubst for expressions without solver tvars (rare edge cases)

```
Production path:  Can.Type + MonoType → TypeSubst.unify → Dict String MonoType → applySubst
MonoDirect path:  tvar + MonoType → SolverSnapshot.specializeChainedWithSubst → view.monoTypeOf
```

### Module Organization

```
compiler/src/Compiler/MonoDirect/
├── Monomorphize.elm      -- Entry point, worklist driver, graph assembly
├── Specialize.elm        -- Expression/node specialization (main logic, ~2400 lines)
├── State.elm             -- MonoDirectState, VarEnv, LocalMultiState
└── JoinpointFlatten.elm  -- Post-pass joinpoint flattening
```

### Shared Infrastructure

MonoDirect reuses significant infrastructure from the production monomorphizer:
- `Registry` — SpecId allocation and SpecializationRegistry management
- `Prune` — unreachable specialization pruning (MONO_022)
- `MonoTraverse` — graph traversal utilities
- `KernelAbi` — kernel function ABI policy
- `Closure` — closure capture analysis
- `TypeSubst` — fallback type substitution (for expressions without tvars)
- `Analysis` — type analysis utilities

### State Design

MonoDirect uses a flat `MonoDirectState` record instead of the production monomorphizer's split `accum`/`ctx` pattern:

```elm
type alias MonoDirectState =
    { worklist : List WorkItem
    , nodes : Dict Int MonoNode
    , inProgress : BitSet
    , scheduled : BitSet
    , registry : SpecializationRegistry
    , lambdaCounter : Int
    , varEnv : VarEnv          -- maps local variable names to (SSA name, MonoType)
    , snapshot : SolverSnapshot
    , globalTypeEnv : GlobalTypeEnv
    , toptNodes : ...          -- source TypedOptimized nodes
    , ...
    }
```

The `VarEnv` uses a frame stack for lexical scoping — `pushFrame`/`popFrame` bracket case branches and let bodies.

### Worklist Algorithm

Identical to production: a `List WorkItem` where each item is `SpecializeGlobal SpecId`. Cycle detection uses an `inProgress` BitSet. The `scheduled` BitSet prevents duplicate enqueuing. The driver loop pops items, specializes them, and enqueues newly discovered specializations.

### Pipeline

```
monomorphizeDirect entryPointName globalTypeEnv snapshot globalGraph
    1. Find entry point in TypedOptimized graph
    2. Resolve main function's MonoType via solver snapshot
    3. Run worklist specialization
    4. Assemble raw MonoGraph
    5. JoinpointFlatten — flatten joinpoint structures
    6. Prune unreachable specializations (shared Prune module)
    → Result: MonoGraph (same type as production output)
```

## What Works

The implementation covers all `TOpt.Expr` constructors: literals, variables (local/global/kernel), lists, closures/lambdas, calls, let-bindings, destructuring, case expressions, records, tuples, unit, accessors, field access, record update, ports, and cycles.

Key mechanisms implemented:
- **Two-phase call specialization**: `processCallArgs`/`finishProcessedArgs` with `PendingAccessor`, `PendingKernel`, and `LocalFunArg` deferral
- **Local multi-specialization**: Polymorphic let-bound functions get per-call-site instances via `LocalMultiState` stack
- **VarEnv save/reset**: Present in `specializeDecider`, `specializeJumps`, `specializeBranches` for correct scoping
- **Accessor specialization**: Two-phase — deferred at argument position, resolved at `finishProcessedArg` via `resolveAccessor`

## Known Differences and Gaps

### Curried vs Flat Function Types

The production monomorphizer preserves curried type structure from `Can.Type` (e.g., `MFunction [Int] (MFunction [Int] Int)` for a binary function). MonoDirect resolves types via `view.monoTypeOf`, which may produce flat `MFunction [Int, Int] Int` directly if the solver has unified the type that way. This staging difference is normally resolved by GlobalOpt (GOPT_001), but it represents a behavioral divergence that needs validation.

### CEcoValue Erasure

The production monomorphizer's `fillUnconstrainedCEcoWithErased` pass (converting dead-value `CEcoValue` type variables to `MErased`) was removed from both pipelines — both now rely on codegen mapping `MVar _ CEcoValue` directly to `!eco.value`. This was previously listed as a MonoDirect gap but the approaches have converged.

### Test Coverage

Both MonoDirect test suites are `Test.skip`'d:
- `MonoDirectTest.elm` — basic compile-succeeds invariant test
- `MonoDirectComparisonTest.elm` — structural graph comparison against production monomorphizer

These tests need to be un-skipped and passing before MonoDirect can be considered for production use.

## Potential Benefits

If completed and validated, MonoDirect could offer:

1. **Simpler type resolution**: Direct solver queries instead of string-based substitution
2. **Fewer canonicalization bugs**: No type variable name matching; the solver's union-find is the single source of truth
3. **Incremental specialization potential**: The solver snapshot could be extended to support incremental respecialization when types change (useful for IDE integration)

## Path to Production

For MonoDirect to replace the production monomorphizer, it would need:

1. **Un-skip and pass all comparison tests**: The structural graph comparison test must show MonoDirect produces equivalent output to the production monomorphizer for all test cases
2. **Validate staging behavior**: Confirm that GlobalOpt correctly normalizes any curried/flat function type differences
3. **Run full E2E test suite**: Wire MonoDirect into the pipeline (behind a flag) and run `cmake --build build --target full`
4. **Performance comparison**: Measure specialization time and peak memory for large programs (compiler self-compilation)
5. **Invariant compliance**: Verify MONO_001 through MONO_026 all hold for MonoDirect output

Until these are completed, the production `Compiler.Monomorphize.*` pipeline remains the only supported monomorphization path.
