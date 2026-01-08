# UndefinedFunctionStub Pass

## Overview

The UndefinedFunctionStub pass identifies `eco.call` operations that reference functions not defined in the current module and generates external function declarations for them. This enables linking with runtime-provided kernel functions and external libraries.

**File**: `runtime/src/codegen/Passes/UndefinedFunctionStub.cpp`

## Pseudocode

```
FUNCTION runOnOperation(module):
    // Step 1: Collect all defined function names
    definedFunctions = SET()
    FOR EACH funcOp IN module:
        definedFunctions.add(funcOp.getName())

    // Step 2: Collect undefined function names from eco.call ops
    undefinedFunctions = SET()
    FOR EACH callOp IN module:
        callee = callOp.getCalleeAttr()
        IF callee IS NULL:
            CONTINUE  // Indirect call, skip

        calleeName = callee.getValue()
        IF calleeName NOT IN definedFunctions:
            undefinedFunctions.add(calleeName)

    IF undefinedFunctions.empty():
        RETURN  // No declarations needed

    // Step 3: Generate external declarations
    builder.setInsertionPointToEnd(module.body)

    FOR EACH funcName IN undefinedFunctions:
        // Find first call site to determine signature
        argTypes = []
        resultType = NULL

        FOR EACH callOp IN module:
            IF callOp.callee == funcName:
                FOR EACH operand IN callOp.operands:
                    argTypes.append(operand.getType())
                IF callOp.numResults > 0:
                    resultType = callOp.getResult(0).getType()
                BREAK  // Found signature

        // Build function type
        IF resultType:
            funcType = FunctionType(argTypes, [resultType])
        ELSE:
            funcType = FunctionType(argTypes, [])

        // Create external declaration (no body)
        funcOp = func.func(funcName, funcType)
        funcOp.setVisibility(Private)
        // Note: No entry block = external declaration
```

## Purpose

This pass bridges the gap between:
1. **Elm code** calling kernel functions (e.g., `Elm_Kernel_Basics_add`)
2. **C++ implementations** in the ECO runtime

By generating `func.func` declarations without bodies, MLIR's later lowering and LLVM's linker can resolve these symbols at link time.

## Pre-conditions

1. Input module contains valid ECO dialect IR
2. All `eco.call` operations have valid callee attributes or are indirect calls
3. For each undefined function, at least one call site exists (to infer signature)
4. All call sites to the same function use consistent signatures

## Post-conditions

1. For every undefined function referenced by `eco.call`:
   - A `func.func` declaration exists at the module level
   - The declaration has no body (external symbol)
   - The declaration has `Private` visibility

2. Defined functions remain unchanged
3. Indirect calls (no callee attribute) are not affected

## Invariants

1. **Signature Inference**: Function signature is derived from first call site found
2. **Assumption of Consistency**: All calls to same function must have identical signatures
3. **No Duplicate Declarations**: Each function is declared at most once
4. **Order Independence**: Declarations are added in iteration order (deterministic)

## Example Transformation

**Before:**
```mlir
module {
    func.func @user_defined(%arg: !eco.value) -> !eco.value {
        %result = eco.call @Elm_Kernel_Basics_add(%arg, %arg) : (!eco.value, !eco.value) -> !eco.value
        eco.return %result : !eco.value
    }
}
```

**After:**
```mlir
module {
    func.func @user_defined(%arg: !eco.value) -> !eco.value {
        %result = eco.call @Elm_Kernel_Basics_add(%arg, %arg) : (!eco.value, !eco.value) -> !eco.value
        eco.return %result : !eco.value
    }

    // Generated declaration
    func.func private @Elm_Kernel_Basics_add(!eco.value, !eco.value) -> !eco.value
}
```

## Handling Indirect Calls

Indirect calls (function pointers, closure calls) don't have a callee attribute:

```mlir
// Direct call - has @symbol
eco.call @some_function(%arg) : (!eco.value) -> !eco.value

// Indirect call - no @symbol, first operand is function value
eco.call %fn_ptr(%arg) : (!eco.value, !eco.value) -> !eco.value
```

The pass skips indirect calls since the callee isn't known at compile time.

## Relationship to Kernel Functions

The ECO runtime provides ~272 kernel functions:

| Package | Example Functions |
|---------|-------------------|
| `Basics` | `Elm_Kernel_Basics_add`, `_sub`, `_mul`, ... |
| `List` | `Elm_Kernel_List_cons`, `_map`, `_filter`, ... |
| `String` | `Elm_Kernel_String_append`, `_length`, ... |
| `Json` | `Elm_Kernel_Json_decode*`, `_encode*`, ... |

These are implemented in C++ files under `runtime/src/kernel/` and linked as static libraries.

## Visibility: Why Private?

The generated declarations use `Private` visibility:
- Symbol is visible only within the module
- Prevents symbol conflicts with other modules
- LLVM linker still resolves to external symbol

This matches the typical pattern for extern declarations.

## Relationship to Other Passes

- **Runs Before**: `EcoToLLVM` (which needs complete function declarations)
- **Enables**: Linking with runtime kernel libraries
- **Alternative**: Could be done at link time, but early declaration enables MLIR verification

## Limitations

1. **No Type Checking**: Assumes all call sites have correct types
2. **No Arity Checking**: Doesn't verify consistent argument counts
3. **Single Signature**: Takes first call site's signature (doesn't merge)

These are acceptable because the Elm type system guarantees consistency.
