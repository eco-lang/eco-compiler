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

**Important**: Many arithmetic operations from `Basics` and `Bitwise` modules are handled by [compiler intrinsics](intrinsics_theory.md) rather than kernel calls. Intrinsics bypass the kernel ABI entirely and emit direct MLIR operations. The kernel ABI is only used when intrinsics don't apply.

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

`Context.elm` defines `kernelBackendAbiPolicy` which determines whether a kernel's MLIR calling convention uses all-boxed `!eco.value` types or derives typed signatures from the Elm wrapper.

The type (renamed from the earlier `AbiPolicy`) is:

```elm
type KernelBackendAbiPolicy
    = AllBoxed     -- All args and result are !eco.value in MLIR
    | ElmDerived   -- ABI derived from the Elm wrapper's funcType via monoTypeToAbi
```

The policy function has been **audited against the actual C++ kernel exports** (elm-kernel-cpp/src/KernelExports.h) as of Feb 23, 2026. The comprehensive mapping is:

```elm
kernelBackendAbiPolicy : String -> String -> KernelBackendAbiPolicy
kernelBackendAbiPolicy home name =
    case ( home, name ) of
        --
        -- AllBoxed: C++ ABI is uniformly uint64_t for all params and return.
        -- Audited against elm-kernel-cpp/src/KernelExports.h.
        --
        -- List: cons, fromArray, toArray, map2..map5, sortBy, sortWith
        ( "List", _ ) ->
            AllBoxed

        -- Utils: compare, equal, notEqual, lt, le, gt, ge, append
        ( "Utils", _ ) ->
            AllBoxed

        -- String.fromNumber: number-polymorphic, C++ takes boxed uint64_t
        ( "String", "fromNumber" ) ->
            AllBoxed

        -- JsArray: C++ ABI uniformly uint64_t for all params and return.
        -- Integer arguments (index, length, etc.) are boxed Elm Int HPointers
        -- and unboxed inside the C++ implementations.
        ( "JsArray", _ ) ->
            AllBoxed

        -- Json.wrap: polymorphic (a -> Value), C++ inspects heap tag at runtime.
        -- Must be AllBoxed to avoid signature mismatch across monomorphized
        -- call sites (Encode.int passes i64, Encode.string passes !eco.value).
        ( "Json", "wrap" ) ->
            AllBoxed

        --
        -- ElmDerived: C++ ABI has typed (non-uint64_t) params or returns.
        -- ABI is derived from the Elm wrapper's funcType via monoTypeToAbi.
        --
        -- Basics:  double (trig, fdiv, toFloat), int64_t (idiv, modBy, floor, etc.)
        -- Bitwise: int64_t
        -- Char:    uint16_t (toCode, fromCode)
        -- String:  length(uint64_t)->i64, cons(i16,uint64_t)->uint64_t,
        --          slice(i64,i64,uint64_t)->uint64_t
        -- Json:    decodeIndex(i64, ...), encode(i64, ...)
        -- Browser, Bytes, Parser, Regex, File, Process, Time,
        -- Debugger, Platform: typed C++ signatures
        --
        -- Also ElmDerived (all uint64_t in C++ but no mismatch bug today):
        -- Debug, Scheduler, VirtualDom, Url, Http
        --
        _ ->
            ElmDerived
```

**AllBoxed modules/functions** (C++ ABI uniformly `uint64_t`):
- **List** (all functions): `cons`, `fromArray`, `toArray`, `map2`..`map5`, `sortBy`, `sortWith`
- **Utils** (all functions): `compare`, `equal`, `notEqual`, `lt`, `le`, `gt`, `ge`, `append`
- **String.fromNumber**: number-polymorphic, C++ takes boxed `uint64_t`
- **JsArray** (all functions): C++ ABI uniformly `uint64_t`; integer args (index, length) are boxed Elm Int HPointers, unboxed inside C++ implementations
- **Json.wrap**: polymorphic (`a -> Value`), C++ inspects heap tag at runtime

**ElmDerived** (remaining functions): ABI derived from the Elm wrapper's `funcType` via `monoTypeToAbi`. This covers `Basics` (typed arithmetic), `Bitwise`, `Char`, `String` (length, cons, slice), `Json` (decodeIndex, encode), `Browser`, `Bytes`, `Parser`, `Regex`, `File`, `Process`, `Time`, `Debugger`, `Platform`, etc.

**AllBoxed return type rule**: For AllBoxed kernels with polymorphic return types, the call result type must be `!eco.value` regardless of what the monomorphized type says, because the C++ function always returns `uint64_t`. The compiler enforces this by using `ecoValueType` as the result type for AllBoxed kernels rather than `monoTypeToAbi` of the call-site return type.

This ensures the MLIR codegen emits correct boxing/unboxing when calling C++ kernels.

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

## Compiler as Sole ABI Arbiter (KERN_006)

As of Feb 25, 2026, the compiler is the **sole arbiter** of kernel ABI types. The architecture has been simplified to a clear three-layer model:

1. **Compiler determines ABI types**: `kernelBackendAbiPolicy` + `monoTypeToAbi` compute the definitive MLIR types for all kernel function parameters and return values. The compiler emits `func.func` declarations with these types and ensures all `eco.papCreate`, `eco.papExtend`, and `eco.call` operations match the declared types.

2. **MLIR enforces type-level consistency**: `func.func` declarations carry the ABI types as their `function_type` attribute. Any `eco.papCreate`, `eco.papExtend`, or `eco.call` that references a kernel symbol must have argument and result types consistent with the kernel's declaration. Mismatches are caught by MLIR verifiers and the `UndefinedFunctionPass`.

3. **EcoToLLVM simply reflects**: The LLVM lowering pass no longer tries to reverse-engineer or repair ABI types. It takes the MLIR types at face value and lowers them directly to LLVM IR. If the compiler emits correct MLIR types, the lowering is correct by construction.

This is captured in invariant **CGEN_057**: Every kernel function symbol (`Elm_Kernel_*`) that appears in a `papCreate`, `papExtend`, or `eco.call` must have a corresponding `func.func` declaration with `is_kernel=true` and a `function_type` whose parameter and result types match the ABI-level types computed by the Elm compiler.

**Why this matters**: Previously, some layers attempted to independently derive or fix up kernel ABI types, leading to subtle mismatches (e.g., an `eco.call` passing `i64` to a kernel declared with `!eco.value` parameters). By making the compiler the single source of truth and having downstream passes trust the MLIR types, the entire pipeline becomes simpler and more reliable.

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

**Note**: In practice, the `Basics` operations listed above (`add`, `sub`, `mul`, `pow`) are almost always handled by [intrinsics](intrinsics_theory.md) when argument types are concrete (`MInt` or `MFloat`). The NumberBoxed kernel path is only taken when types remain polymorphic after monomorphization—which is rare. The primary user of NumberBoxed is `String.fromNumber`, which has no intrinsic equivalent.

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
- **KERN_006**: The compiler is the sole source of truth for kernel ABI types. `kernelBackendAbiPolicy` + `monoTypeToAbi` determine the definitive MLIR types for all kernel parameters and return values. MLIR declarations carry these types; the LLVM lowering pass reflects them without repair. (See also CGEN_057.)

## Relationship to Other Passes

- **PostSolve**: Infers kernel types from usage and aliases
- **Monomorphization**: Determines `KernelAbiMode` and converts types
- **MLIR Generation**: Emits kernel declarations and boxing/unboxing
- **Linking**: Resolves kernel symbols to C++ implementations

## See Also

- [Intrinsics Theory](intrinsics_theory.md) — Direct MLIR ops that bypass kernel ABI
- [Monomorphization Theory](pass_monomorphization_theory.md) — Type specialization context
- [MLIR Generation Theory](pass_mlir_generation_theory.md) — Kernel call emission
- [Heap Representation Theory](heap_representation_theory.md) — Boxing/unboxing semantics
