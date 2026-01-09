# RCElimination Pass

## Overview

The RCElimination pass validates that no reference counting operations exist in the IR when targeting a tracing garbage collector. This is a verification pass that ensures the compiler is generating code appropriate for the ECO runtime's generational tracing GC.

**File**: `runtime/src/codegen/Passes/RCElimination.cpp`

**Phase**: MLIR_Codegen (see `invariants.csv` for related CGEN_* and HEAP_* invariants)

## Pseudocode

```
FUNCTION runOnOperation(module):
    hasErrors = false

    FOR EACH operation IN module (recursive walk):
        IF operation IS eco.incref:
            EMIT ERROR "eco.incref is not supported in tracing GC mode"
            hasErrors = true

        ELSE IF operation IS eco.decref:
            EMIT ERROR "eco.decref is not supported in tracing GC mode"
            hasErrors = true

        ELSE IF operation IS eco.decref_shallow:
            EMIT ERROR "eco.decref_shallow is not supported in tracing GC mode"
            hasErrors = true

        ELSE IF operation IS eco.free:
            EMIT ERROR "eco.free is not supported in tracing GC mode"
            hasErrors = true

        ELSE IF operation IS eco.reset:
            EMIT ERROR "eco.reset is not supported in tracing GC mode"
            hasErrors = true

        ELSE IF operation IS eco.reset_ref:
            EMIT ERROR "eco.reset_ref is not supported in tracing GC mode"
            hasErrors = true

    IF hasErrors:
        SIGNAL PASS FAILURE
```

## Purpose

The ECO runtime uses a **generational tracing garbage collector** rather than reference counting. Reference counting operations would be:

1. **Incorrect**: The runtime doesn't maintain reference counts
2. **Wasteful**: Would add unnecessary overhead
3. **Bug Indicators**: Their presence suggests codegen errors

This pass serves as a **verification checkpoint** in the compilation pipeline.

## Reference Counting Operations Detected

| Operation | Purpose (if RC were used) |
|-----------|---------------------------|
| `eco.incref` | Increment reference count |
| `eco.decref` | Decrement reference count (deep free if zero) |
| `eco.decref_shallow` | Decrement without recursive deallocation |
| `eco.free` | Immediate deallocation |
| `eco.reset` | Reset object to reuse memory |
| `eco.reset_ref` | Reset reference field |

## Pre-conditions

1. Input module contains ECO dialect IR
2. Pass is only run when targeting tracing GC (not hybrid/RC modes)

## Post-conditions

1. **If pass succeeds**: No RC operations exist in the module
2. **If pass fails**: At least one RC operation was found; compilation halts with error messages identifying the offending operations

## Pass Behavior Guarantees

These are behavioral properties of the pass itself, not system-wide invariants (see `invariants.csv` for CGEN_* and HEAP_* invariants):

1. **No Modification**: Pass never modifies IR, only inspects
2. **Complete Scan**: Every operation in the module is checked
3. **Fail-Fast**: All errors are collected before signaling failure (allows developer to see all issues at once)
4. **Location Tracking**: Error messages include source locations for debugging

## When This Pass Runs

In the ECO compilation pipeline:

```
Input IR (ECO dialect)
    |
    v
[ResultTypesInference]
    |
    v
[JoinpointNormalization]
    |
    v
[EcoControlFlowToSCF]
    |
    v
[RCElimination]  <-- Verification checkpoint
    |
    v
[EcoToLLVM]
    |
    v
Output (LLVM dialect)
```

## Future Considerations

This pass is a placeholder for potential future hybrid memory management:

1. **Perceus-style RC**: If ECO adopts Perceus (from Koka), RC ops would be valid
2. **Uniqueness Types**: Reference counting could optimize unique values
3. **Arena Allocation**: `eco.reset` could be valid for arena-allocated objects

For now, the pass ensures the simple tracing GC model is maintained.

## Relationship to GC Design

ECO's tracing GC provides:
- **No write barriers** (Elm's immutability guarantees no old-to-young pointers) — see **HEAP_005**
- **Generational collection** (nursery + old generation)
- **No reference counts** in object headers

This pass validates the IR matches these design assumptions.

## Error Messages

Example error output when RC operations are detected:

```
error: eco.incref is not supported in tracing GC mode
  eco.incref %0 : !eco.value
  ^

error: eco.decref is not supported in tracing GC mode
  eco.decref %1 : !eco.value
  ^
```
