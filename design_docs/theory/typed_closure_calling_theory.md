# Typed Closure Calling Theory

## Overview

Typed Closure Calling is a compiler optimization that eliminates evaluator wrapper functions and enables direct typed function calls even when partial application and closures are involved. This eliminates the overhead of the uniform `void* (*)(void*[])` calling convention for closures.

**Phase**: GlobalOpt (ABI Cloning) + MLIR Generation + LLVM Lowering

**Pipeline Position**: Spans GlobalOpt through EcoToLLVM

**Related Modules**:
- `compiler/src/Compiler/GlobalOpt/AbiCloning.elm`
- `compiler/src/Compiler/Generate/MLIR/Functions.elm`
- `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

## Motivation

### The Problem: Uniform Evaluator ABI

Previously, all closures used a uniform evaluator signature:

```cpp
typedef void *(*EvalFunction)(void *[]);
```

This required:
1. A wrapper function for every closure that unpacks `void*[]` into typed arguments
2. Runtime packing of captures and arguments into an array
3. Runtime type erasure and recovery

### The Cost

```elm
applyTwice f x = f (f x)
```

Each call to `f`:
1. Allocates or fills an argument array
2. Calls through the generic evaluator
3. Wrapper unpacks, calls real function, repacks result

This adds indirection and prevents LLVM from optimizing across call boundaries.

## Solution: Two-Clone Model

For closures with captures, the compiler generates **two entry points**:

### 1. Fast Clone (`lambdaName$cap`)

Signature: `(C1..Cc, P1..Pn) -> R`

- Captures are explicit typed parameters
- Full typed ABI, no indirection
- Used when closure structure is statically known

### 2. Generic Clone (`lambdaName$clo`)

Signature: `(Closure*, P1..Pn) -> R`

- Takes closure pointer + typed parameters
- Loads captures from closure, calls fast clone
- Used when closure structure varies at runtime

**Zero-capture closures** need no cloning—the original function is used directly.

## Closure Kind Analysis

The compiler tracks which closure kind each SSA value has:

```elm
type ClosureKind
    = Known ClosureKindId    -- Definitely this specific closure kind
    | Heterogeneous          -- One of several closure kinds

type alias MaybeClosureKind = Maybe ClosureKind
```

### Three-Way Lattice

| State | Meaning |
|-------|---------|
| `Just (Known id)` | Homogeneous: SSA value is definitely closure kind `id` |
| `Just Heterogeneous` | Heterogeneous: SSA value is one of multiple closure kinds |
| `Nothing` | Unknown: No closure-kind info (non-closure or analysis gap) |

### Merge Rules (for phi/join)

Given inputs `k1, k2, ..., kn`:

1. If any input is `Just Heterogeneous` → result is `Just Heterogeneous`
2. If all `Known` IDs are the same → `Just (Known thatId)`
3. If `Known` IDs differ → `Just Heterogeneous`
4. If any `Nothing` with `Known` IDs → `Just Heterogeneous` (conservative)

## ABI Cloning Pass

The `AbiCloning.elm` pass ensures closure parameters are homogeneous within each function:

### Algorithm

```
FUNCTION abiCloningPass(graph):
    -- Collect all parameter ABIs used at call sites
    paramAbis = collectAllParameterAbis(graph)

    FOR EACH function IN graph:
        FOR EACH closure-typed parameter p:
            abis = paramAbis[function][p]

            IF shouldClone(abis):
                -- Multiple different capture ABIs used
                FOR EACH abi IN dedupeAbis(abis):
                    clone = cloneFunction(function, p, abi)
                    graph.add(clone)
                    rewriteCallSites(function, p, abi, clone)
```

### Capture ABI

A **capture ABI** describes the structure of a closure's captured values:

```elm
type alias CaptureAbi =
    { captureTypes : List MonoType
    , paramTypes : List MonoType
    , returnType : MonoType
    }
```

Two closures have the same ABI if their capture types match exactly.

### When to Clone

```elm
shouldClone : List CaptureAbi -> Bool
shouldClone abis =
    List.length (dedupeAbis abis) > 1
```

If a function parameter receives closures with different capture ABIs, clone the function once per distinct ABI.

## MLIR Attributes

### `_closure_kind` (Value Metadata)

**Question**: What closure kind ID does this SSA value have?

```mlir
%closure = eco.papCreate @fn ... {_closure_kind = 42}
```

- **Present with integer**: Known homogeneous kind
- **Present as "heterogeneous"**: Known to be multiple kinds
- **Absent**: Non-closure or no analysis info

### `_dispatch_mode` (Call Strategy)

**Question**: What lowering strategy should be used at this call site?

```mlir
eco.call %closure(%args) {_dispatch_mode = "fast", _closure_kind = 42}
eco.call %closure(%args) {_dispatch_mode = "closure"}
eco.call %closure(%args) {_dispatch_mode = "unknown"}
```

| Mode | Meaning | Lowering |
|------|---------|----------|
| `"fast"` | Known homogeneous | Use fast clone with unpacked captures |
| `"closure"` | Known heterogeneous | Use generic clone with closure pointer |
| `"unknown"` | Analysis gap | Use generic clone, log diagnostic |

**Always present** on closure calls—absence indicates pipeline bug.

## Call Lowering

### Fast Path (`_dispatch_mode = "fast"`)

```llvm
; Compiler knows closure kind → direct call with unpacked captures
%cap0 = load ptr, ptr getelementptr(%closure, 0, 3)  ; offset 24
%cap1 = load ptr, ptr getelementptr(%closure, 0, 4)  ; offset 32
%result = call @lambda$cap(%cap0, %cap1, %arg0, %arg1)
```

### Generic Path (`_dispatch_mode = "closure"`)

```llvm
; Load evaluator (always points to generic clone)
%evaluator = load ptr, ptr getelementptr(%closure, 0, 2)  ; offset 16

; Cast to typed function pointer
%typed_fn = bitcast %evaluator to (ptr, i64, i64) -> i64

; Call with closure pointer + args
%result = call %typed_fn(%closure, %arg0, %arg1)
```

### Unknown Path (`_dispatch_mode = "unknown"`)

Same as generic path, but emits a diagnostic warning during lowering.

## Integration Points

### GlobalOpt

`AbiCloning.elm` runs after staging analysis to clone functions with heterogeneous closure parameters.

### MLIR Generation

`Functions.elm` and `Expr.elm`:
- Generate both clone entry points for closures with captures
- Annotate `eco.papCreate` with `_closure_kind`
- Annotate `eco.call` with `_dispatch_mode`

### EcoToLLVM

`EcoToLLVMClosures.cpp` (centralized as of Feb 2026):
- All closure calling logic consolidated into this single file (PAP create/extend, direct/indirect calls, kernel calls)
- `papCreate` stores generic clone pointer as evaluator
- Call lowering reads `_dispatch_mode` to choose lowering path
- Fast calls resolve symbols at compile time
- Kernel function calls use compiler-declared ABI types without inference or repair

## Example

### Source

```elm
applyBoth f g x = f (g x)

main =
    applyBoth (\a -> a + 1) (\b -> b * 2) 5
```

### Without Typed Closure Calling

```
; Each lambda has wrapper
@lambda1$wrapper: void* (void*[]) { ... unpack, call lambda1, pack ... }
@lambda2$wrapper: void* (void*[]) { ... unpack, call lambda2, pack ... }

; applyBoth makes generic calls
%args = alloca [2 x void*]
store %g, %args[0]
store %x, %args[1]
%tmp = call @evaluator(%args)  ; indirect, generic
...
```

### With Typed Closure Calling

```
; No wrappers needed—direct typed calls
@lambda1$cap: i64 (i64) { ... }
@lambda2$cap: i64 (i64) { ... }

; applyBoth makes direct calls (homogeneous case)
%tmp = call @lambda2$cap(%x)       ; direct, typed
%result = call @lambda1$cap(%tmp)  ; direct, typed
```

## Performance Benefits

1. **No wrapper overhead**: Direct typed calls instead of unpack/repack
2. **Better inlining**: LLVM can inline small closures
3. **Register allocation**: Captures as parameters, not memory indirection
4. **Branch prediction**: Direct calls are more predictable
5. **Smaller code**: No wrapper function generation

## Invariants

- **ABI_001**: Every closure-producing op has `_closure_kind` (Known/Heterogeneous/absent)
- **ABI_002**: Every closure call has `_dispatch_mode` (fast/closure/unknown)
- **ABI_003**: Fast calls only use closure kinds with matching capture ABIs
- **ABI_004**: Generic clone always unpacks captures and calls fast clone

## Relationship to Staged Currying

Typed Closure Calling is orthogonal to staged currying:

- **Staged currying**: How many arguments to take per stage (segmentation)
- **Typed closure calling**: How to pass captures at call sites (ABI)

Both are GlobalOpt concerns resolved before MLIR generation.

## See Also

- [Staged Currying Theory](staged_currying_theory.md) — Argument grouping
- [Global Optimization Theory](pass_global_optimization_theory.md) — ABI Cloning pass integration
- [EcoToLLVM Theory](pass_eco_to_llvm_theory.md) — Call lowering implementation
