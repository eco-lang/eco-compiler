# Compiler Pipeline Summary (refreshed 2026-02-19)

This memory summarizes the ECO compiler backend pipeline. Read at startup.

## Pipeline Stages

```
Elm Source
    ↓ Standard Elm Frontend (Parse, Canonicalize, Type Check)
    ↓
PostSolve (fix Group B types, infer kernel types)
    ↓
Typed Optimization (preserve types, decision trees)
    ↓
Monomorphization (specialize polymorphism, compute layouts, staging-agnostic)
    ↓
GlobalOpt (canonicalize staging, normalize ABI, compute CallInfo)
    ↓
MLIR Generation (ECO dialect)
    ↓
Stage 2 Passes (JoinPoint norm, SCF conversion, RC elimination)
    ↓
EcoToLLVM (final lowering)
    ↓
LLVM IR → Native Code
```

## Key Passes (see design_docs/theory/ for details)

### PostSolve
- Fixes "Group B" expression types (Str, List, Lambda, etc.)
- Infers kernel function types from usage
- File: `compiler/src/Compiler/Type/PostSolve.elm`

### Typed Optimization
- Preserves Can.Type on every expression
- Compiles patterns to decision trees (Decider structures)
- Files: `compiler/src/Compiler/Optimize/Typed/`

### Monomorphization
- Worklist algorithm: specialize polymorphic functions
- MonoType: MInt, MFloat, MBool, MChar, MString, MList, MTuple, MRecord, MCustom, MFunction, MVar
- Computes RecordLayout, TupleLayout, CtorLayout with unboxedBitmap
- SpecId uniquely identifies each specialization
- **Staging-agnostic**: Preserves curried type structure, defers staging to GlobalOpt
- File: `compiler/src/Compiler/Monomorphize/Monomorphize.elm`

### GlobalOpt
- Canonicalizes closure staging (GOPT_001): flattens types to match param counts
- Normalizes case/if ABI (GOPT_003): ensures compatible staging across branches
- Computes CallInfo metadata for MLIR (callModel, stageArities, etc.)
- Validates closure staging invariants
- File: `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

### MLIR Generation
- 11 modules under `compiler/src/Compiler/Generate/MLIR/`
- Key: Types.elm, Context.elm, Ops.elm, Expr.elm, Functions.elm, Intrinsics.elm
- Generates eco.* operations, type table, kernel declarations
- **Intrinsics**: Basics/Bitwise ops emit direct eco.int.*/eco.float.* ops (see intrinsics_theory.md)

### EcoToLLVM
- Converts !eco.value → i64 (tagged pointer)
- Embedded constants: Unit=1<<40, True=3<<40, False=4<<40, Nil=5<<40
- Runtime function calls: eco_alloc_*, eco_store_*, etc.
- File: `runtime/src/codegen/Passes/EcoToLLVM*.cpp`

## Type Flow

```
Can.Type → (PostSolve) → Can.Type (complete)
→ (TypedOpt) → TOpt.Expr with Can.Type
→ (Mono) → MonoType (curried, e.g., MFunction [a] (MFunction [b] c))
→ (GlobalOpt) → MonoType (canonical, e.g., MFunction [a,b] c) + CallInfo
→ (MLIR) → MlirType (i64, f64, !eco.value)
→ (EcoToLLVM) → LLVM types
```

## Key Data Structures

- **SpecId**: Unique ID for each function specialization
- **MonoGraph**: All specialized nodes + ctorLayouts
- **RecordLayout/TupleLayout/CtorLayout**: Field order + unboxedBitmap
- **MlirOp**: MLIR operation with operands, results, attrs, regions

## Staged Currying (GOPT_003)

Functions segment arguments into stages: `[2,1]` = take 2 args, return closure taking 1.
All MonoCase branches returning functions must have compatible staging signatures.
Staging is now enforced by GlobalOpt (GOPT_001 for closures, GOPT_003 for case branches).
