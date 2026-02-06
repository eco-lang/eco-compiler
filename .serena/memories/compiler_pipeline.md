# Compiler Pipeline Summary

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
Monomorphization (specialize polymorphism, compute layouts)
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
- File: `compiler/src/Compiler/Generate/Monomorphize.elm`

### MLIR Generation
- 11 modules under `compiler/src/Compiler/Generate/MLIR/`
- Key: Types.elm, Context.elm, Ops.elm, Expr.elm, Functions.elm
- Generates eco.* operations, type table, kernel declarations

### EcoToLLVM
- Converts !eco.value → i64 (tagged pointer)
- Embedded constants: Unit=1<<40, True=3<<40, False=4<<40, Nil=5<<40
- Runtime function calls: eco_alloc_*, eco_store_*, etc.
- File: `runtime/src/codegen/Passes/EcoToLLVM*.cpp`

## Type Flow

```
Can.Type → (PostSolve) → Can.Type (complete)
→ (TypedOpt) → TOpt.Expr with Can.Type
→ (Mono) → MonoType (MInt, MFloat, etc.)
→ (MLIR) → MlirType (i64, f64, !eco.value)
→ (EcoToLLVM) → LLVM types
```

## Key Data Structures

- **SpecId**: Unique ID for each function specialization
- **MonoGraph**: All specialized nodes + ctorLayouts
- **RecordLayout/TupleLayout/CtorLayout**: Field order + unboxedBitmap
- **MlirOp**: MLIR operation with operands, results, attrs, regions

## Staged Currying (GOPT_018)

Functions segment arguments into stages: `[2,1]` = take 2 args, return closure taking 1.
All MonoCase branches returning functions must have compatible staging signatures.
Staging is now enforced by GlobalOpt (GOPT_016 for closures, GOPT_018 for case branches).
