# Kernel Function ABI Theory

## Overview

Kernel functions are C++ implementations of Elm's core library functions. Unlike user-defined functions that are monomorphized to concrete types, kernels have fixed ABIs that must work across multiple type instantiations. This document describes how the compiler determines and uses kernel ABIs.

**Phases**: PostSolve, Monomorphization, MLIR Generation

**Pipeline Position**: Cross-cutting concern from type inference through codegen

**Related Modules**:
- `compiler/src/Compiler/Monomorphize/KernelAbi.elm`
- `compiler/src/Compiler/Type/PostSolve.elm`
- `compiler/src/Compiler/Generate/MLIR/Context.elm`
- `elm-kernel-cpp/src/` (C++ implementations)

## Motivation

Consider `List.cons : a -> List a -> List a`. This function is polymorphic—it works on lists of any element type. But C++ doesn't have Elm-style polymorphism. The kernel must:

1. Accept values of any type uniformly
2. Store them in the list without type-specific code
3. Work with the garbage collector

This requires a **boxed ABI** where all values are passed as `uint64_t` (HPointer representation).

However, some kernels (like `Basics.add : Int -> Int -> Int`) are monomorphic and can use typed parameters directly.

## ABI Modes

The `KernelAbiMode` type determines how kernel function types are derived:

```elm
type KernelAbiMode
    = UseSubstitution  -- Monomorphic: use call-site types
    | PreserveVars     -- Polymorphic: preserve type vars as CEcoValue
    | NumberBoxed      -- Number-polymorphic: treat CNumber as CEcoValue
```

### UseSubstitution (Monomorphic)

For kernels with no type variables:

```elm
Basics.modBy : Int -> Int -> Int
-- ABI: (i64, i64) -> i64 (unboxed integers)
```

The call-site substitution is applied directly. These kernels have fully typed ABIs.

### PreserveVars (Polymorphic)

For kernels with type variables that must remain polymorphic:

```elm
List.cons : a -> List a -> List a
-- ABI: (eco.value, eco.value) -> eco.value (all boxed)
```

Type variables become `MVar _ CEcoValue`, indicating boxed `eco.value` parameters.

### NumberBoxed (Number-Polymorphic)

For kernels polymorphic over `number` (Int or Float):

```elm
String.fromNumber : number -> String
-- ABI: (eco.value) -> eco.value (boxed number)
```

The `CNumber` constraint is treated as `CEcoValue` for ABI purposes. The C++ kernel receives a boxed value and dispatches based on the runtime type tag.

**Number-boxed kernels**:
- `Basics.add`, `sub`, `mul`, `pow`
- `String.fromNumber`

## ABI Mode Selection

The `deriveKernelAbiMode` function determines which mode to use:

```elm
deriveKernelAbiMode : ( String, String ) -> Can.Type -> KernelAbiMode
deriveKernelAbiMode ( home, name ) canFuncType =
    if isAlwaysPolymorphicModule home then
        PreserveVars  -- Debug module, etc.

    else
        let
            vars = freeTypeVariablesWithConstraints canFuncType
            hasNumberVars = hasConstraint CNumber vars
        in
        if isEmpty vars then
            UseSubstitution  -- Monomorphic

        else if hasNumberVars && isNumberBoxedKernel (home, name) then
            NumberBoxed  -- Number-polymorphic

        else
            PreserveVars  -- General polymorphic
```

## Type Conversion Functions

### canTypeToMonoType_preserveVars

For `PreserveVars` mode—converts canonical types to MonoTypes while preserving type variables:

```elm
canTypeToMonoType_preserveVars : Can.Type -> Mono.MonoType
-- TVar "a" CNumber → MVar "a" CNumber (constraint preserved)
-- TVar "b" CNone   → MVar "b" CEcoValue (converted to boxed)
```

### canTypeToMonoType_numberBoxed

For `NumberBoxed` mode—treats `CNumber` variables as boxed:

```elm
canTypeToMonoType_numberBoxed : Can.Type -> Mono.MonoType
-- TVar "n" CNumber → MVar "n" CEcoValue (boxed for ABI)
```

## Container Specialization

Some kernels can benefit from element-aware specialization at the **Elm wrapper level**, even though the C++ ABI remains boxed.

```elm
containerSpecializedKernels : Set ( String, String )
containerSpecializedKernels =
    [ ( "List", "cons" )
    ]
```

For `List.cons`:
- The C++ kernel always uses boxed ABI (`eco.value`)
- But the Elm wrapper can specialize: `List_cons_Int`, `List_cons_String`, etc.
- This enables unboxing in heap representation (storing `Int` unboxed in Cons cells)

### Backend ABI Policy

`Context.elm` defines `kernelBackendAbiPolicy` which may override specialization:

```elm
kernelBackendAbiPolicy : ( String, String ) -> AbiPolicy
kernelBackendAbiPolicy ( home, name ) =
    case ( home, name ) of
        ( "String", "fromNumber" ) -> AllBoxed
        ( "List", "cons" ) -> AllBoxed
        _ -> UseMonoType
```

This ensures the MLIR codegen emits boxing/unboxing when calling C++ kernels.

## Kernel Type Inference (PostSolve)

Kernel function types are inferred during PostSolve:

### VarKernel Type Resolution

```elm
-- Problem: kernel aliases like `fromFloat = Elm.Kernel.String.fromNumber`
-- may get wrong types from first-usage-wins in kernelEnv

-- Solution: For zero-arg TypedDef with VarKernel body,
-- use the definition's own resultType from the type solver
```

This ensures that aliased kernels get correct types rather than inheriting from the first usage.

## MLIR Codegen Integration

### Kernel Declarations

Kernels are declared (not defined) in MLIR:

```mlir
func.func private @Elm_Kernel_List_cons(!eco.value, !eco.value) -> !eco.value
    attributes {is_kernel = true}
```

The `is_kernel` attribute marks declarations for linker resolution.

### Boxing at Call Sites

When calling a boxed-ABI kernel with unboxed values:

```mlir
// Elm: List.cons 42 myList
// MonoType: List.cons : Int -> List Int -> List Int
// Kernel ABI: (eco.value, eco.value) -> eco.value

%boxed_42 = eco.box %int_42 : i64 -> !eco.value
%boxed_list = eco.box %myList : !eco.value  // already boxed
%result = func.call @Elm_Kernel_List_cons(%boxed_42, %boxed_list)
```

### Unboxing Results

When the kernel returns boxed but the result is used as unboxed:

```mlir
%boxed_result = func.call @Elm_Kernel_Basics_add(%a, %b)
%unboxed = eco.unbox %boxed_result : !eco.value -> i64
```

## C++ Kernel Implementation Patterns

### Boxed ABI (eco.value/HPointer)

```cpp
// List.cons : a -> List a -> List a
extern "C" uint64_t Elm_Kernel_List_cons(uint64_t head, uint64_t tail) {
    auto* heap = ThreadLocalHeap::get();
    auto* cons = heap->allocate<Cons>();
    cons->head = Export::toPtr(head);
    cons->tail = Export::toPtr(tail);
    return Export::toHPointer(cons);
}
```

### NumberBoxed ABI

```cpp
// String.fromNumber : number -> String
extern "C" uint64_t Elm_Kernel_String_fromNumber(uint64_t boxedNum) {
    auto* ptr = Export::toPtr(boxedNum);

    if (ptr->header.tag == Tag_Int) {
        auto* intVal = static_cast<ElmInt*>(ptr);
        return String::fromInt(intVal->value);
    } else {
        auto* floatVal = static_cast<ElmFloat*>(ptr);
        return String::fromFloat(floatVal->value);
    }
}
```

### Unboxed ABI (Monomorphic)

```cpp
// Basics.modBy : Int -> Int -> Int
extern "C" int64_t Elm_Kernel_Basics_modBy(int64_t modulus, int64_t x) {
    if (modulus == 0) return 0;
    int64_t result = x % modulus;
    // Elm's modBy uses floored division semantics
    if ((result > 0 && modulus < 0) || (result < 0 && modulus > 0)) {
        result += modulus;
    }
    return result;
}
```

## Key Constants

### Always-Polymorphic Modules

```elm
alwaysPolymorphicModules = [ "Debug" ]
```

Debug kernels always use boxed ABI regardless of type variables.

### Number-Boxed Kernels

```elm
numberBoxedKernels =
    [ ( "Basics", "add" )
    , ( "Basics", "sub" )
    , ( "Basics", "mul" )
    , ( "Basics", "pow" )
    , ( "String", "fromNumber" )
    ]
```

These receive boxed numbers and dispatch by runtime tag.

### Container-Specialized Kernels

```elm
containerSpecializedKernels =
    [ ( "List", "cons" )
    ]
```

These can have specialized Elm wrappers even though the C++ ABI is boxed.

## Invariants

- **KERN_001**: Monomorphic kernels have typed ABIs matching their signatures
- **KERN_002**: Polymorphic kernels have all-boxed ABIs (`eco.value` params)
- **KERN_003**: NumberBoxed kernels treat `CNumber` as boxed for ABI
- **KERN_004**: Container specialization doesn't affect C++ kernel ABI
- **KERN_005**: MLIR codegen inserts box/unbox at kernel call boundaries

## Relationship to Other Passes

- **PostSolve**: Infers kernel types from usage and aliases
- **Monomorphization**: Determines `KernelAbiMode` and converts types
- **MLIR Generation**: Emits kernel declarations and boxing/unboxing
- **Linking**: Resolves kernel symbols to C++ implementations

## See Also

- [Monomorphization Theory](pass_monomorphization_theory.md) — Type specialization context
- [MLIR Generation Theory](pass_mlir_generation_theory.md) — Kernel call emission
- [Heap Representation Theory](heap_representation_theory.md) — Boxing/unboxing semantics
