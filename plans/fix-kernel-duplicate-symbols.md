# Plan: Fix Duplicate Kernel Symbol Definitions

## Status: COMPLETED

## Problem Statement

When running the compiled Elm code, we got:
```
duplicate definition of symbol 'Elm_Kernel_List_cons'
```

This happened because:
1. The MLIR code calls kernel functions like `@Elm_Kernel_List_cons` via `eco.call`
2. The `UndefinedFunctionStubPass` generated stub functions with bodies that crash
3. The JIT's `symbolMap` in `ecoc.cpp` also registers the real kernel implementations
4. Result: both a stub definition and the real implementation exist -> duplicate symbol error

## Root Cause

The original `UndefinedFunctionStubPass` created **function definitions** (with crash bodies) for ALL undefined functions, including kernel functions. But kernel functions are provided by the runtime and registered via the JIT symbol map. Having both a definition and a JIT symbol caused duplicate definition errors.

## Solution Implemented

Modified `UndefinedFunctionStubPass` to create **external declarations** (func.func without a body) instead of stub definitions. This allows:
1. LLVM lowering to work (it needs declarations for called functions)
2. The JIT to resolve the symbols at runtime from the symbol map
3. No duplicate definitions since declarations don't conflict with JIT symbols

## Changes Made

1. `/work/runtime/src/codegen/Passes/UndefinedFunctionStub.cpp`:
   - Removed the code that creates function bodies (entry block, eco.crash, etc.)
   - Now only creates `func::FuncOp` declarations without bodies
   - Updated header comment to reflect new behavior

## Testing

After the fix:
```
$ /work/build/runtime/src/codegen/ecoc Simple.mlir --emit=jit
main() returned: 67108887
JIT execution completed successfully
```

The duplicate symbol error is resolved and the program runs successfully.
