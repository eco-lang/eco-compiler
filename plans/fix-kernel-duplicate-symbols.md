# Plan: Fix Duplicate Kernel Symbol Definitions

## Status: COMPLETED (superseded by CGEN_011)

## Problem Statement

When running the compiled Elm code, we got:
```
duplicate definition of symbol 'Elm_Kernel_List_cons'
```

This happened because:
1. The MLIR code calls kernel functions like `@Elm_Kernel_List_cons` via `eco.call`
2. The original `UndefinedFunctionStubPass` generated stub functions with bodies
3. The JIT's `symbolMap` in `ecoc.cpp` also registers the real kernel implementations
4. Result: both a stub definition and the real implementation exist -> duplicate symbol error

## Solution Evolution

### Original Solution (superseded)

Modified the pass to create **external declarations** instead of stub definitions.

### Current Solution (CGEN_011)

The pass has been redesigned as `UndefinedFunctionPass` which:
1. **Does NOT generate any stubs or declarations**
2. **Validates** that all called functions are already defined/declared
3. **Fails the build** if any undefined functions are found

This enforces invariant **CGEN_011**: MLIR codegen must generate all function declarations before this validation pass runs.

## Rationale for Change

1. **Masks bugs**: Auto-generating stubs hides codegen bugs
2. **Wrong signatures**: Inferring signatures from call sites may be incorrect
3. **Single responsibility**: MLIR codegen should own declaration generation
4. **Fail fast**: Better to fail early with clear error than link-time issues

## Files Changed

- `/work/runtime/src/codegen/Passes/UndefinedFunction.cpp` (renamed from UndefinedFunctionStub.cpp)
- `/work/runtime/src/codegen/Passes.h`
- `/work/design_docs/pass_undefined_function_theory.md`
- `/work/design_docs/invariants.csv` (added CGEN_011)

## See Also

- Design doc: `design_docs/pass_undefined_function_theory.md`
- Invariant: CGEN_011 in `design_docs/invariants.csv`
