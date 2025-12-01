# Layout Definitions - Pseudocode Summary

This document summarizes the data structures and algorithms from `layout_definitions.rs`, which defines how types are represented in memory.

## Core Concept

A **Layout** represents the concrete memory representation of a type. Unlike the type system (which has type variables), layouts are fully monomorphic - every type variable is resolved to a concrete type.

## Data Structures

### LayoutRepr - Memory Layout Representation

```
enum LayoutRepr:
    # Primitive types
    Builtin(Builtin)

    # Product type: record/tuple with fields stored contiguously
    # Memory: [field0][field1][field2]...
    Struct(List<Layout>)

    # Raw pointer (non-refcounted, internal use)
    Ptr(Layout)

    # Sum type: tagged union with variants
    Union(UnionLayout)

    # Set of possible function implementations
    LambdaSet(LambdaSet)

    # Pointer within recursive data structure
    RecursivePointer(Layout)

    # Type-erased function pointer
    FunctionPointer(FunctionPointer)

    # Fully type-erased value
    Erased
```

### Builtin - Primitive Types

```
enum Builtin:
    Int(IntWidth)       # Signed/unsigned integers
    Float(FloatWidth)   # Floating point numbers
    Bool                # Boolean (1 bit, stored as byte)
    Decimal             # Fixed-point decimal (128-bit)
    Str                 # String with small string optimization
    List(Layout)        # Dynamic array with element layout

enum IntWidth:
    U8, U16, U32, U64, U128    # Unsigned
    I8, I16, I32, I64, I128    # Signed

enum FloatWidth:
    F32, F64
```

### UnionLayout - Tag Union Representations

Different optimizations based on union structure:

```
enum UnionLayout:
    # Standard non-recursive tag union
    # Example: Result a e : [Ok a, Err e]
    # Memory: { tag_id: u8/u16, payload: max_variant_size }
    NonRecursive(List<List<Layout>>)

    # Recursive tag union (general case)
    # Example: Expr : [Sym Str, Add Expr Expr]
    # Memory: heap-allocated { tag_id, payload }, pointer is value
    Recursive(List<List<Layout>>)

    # Recursive union with single constructor
    # Example: RoseTree a : [Tree a (List (RoseTree a))]
    # Optimization: No tag ID needed
    # Memory: heap-allocated payload only
    NonNullableUnwrapped(List<Layout>)

    # Recursive union with empty variant + others
    # Example: FingerTree a : [Empty, Single a, More ...]
    # Optimization: Empty variant = NULL pointer
    # Memory: NULL or heap-allocated { tag_id, payload }
    NullableWrapped:
        nullable_id: u16           # Tag represented as NULL
        other_tags: List<List<Layout>>

    # Recursive union with exactly two variants, one empty
    # Example: ConsList a : [Nil, Cons a (ConsList a)]
    # Optimization: Nil = NULL, no tag ID for Cons
    # Memory: NULL or heap-allocated payload (no tag)
    NullableUnwrapped:
        nullable_id: bool          # true = tag 1 is null
        other_fields: List<Layout>
```

### Memory Layout Examples

```
NonRecursive [Ok Int, Err Str]:
    Stack allocation:
    ┌──────────┬────────────────────────────┐
    │ tag: u8  │ union { ok: i64,           │
    │          │         err: {ptr,len,cap}}│
    └──────────┴────────────────────────────┘

Recursive [Leaf Int, Node Tree Tree]:
    Heap allocation (pointer is the value):
    ┌──────────┬────────────────────────────┐
    │ tag: u8  │ union { leaf: i64,         │
    │          │         node: {ptr, ptr} } │
    └──────────┴────────────────────────────┘

NullableUnwrapped [Nil, Cons Int ConsList]:
    NULL = Nil
    Heap pointer = Cons { value: i64, next: ptr }
    ┌──────────┬────────────┐
    │ value:i64│ next: ptr  │  (no tag ID needed)
    └──────────┴────────────┘
```

### LambdaSet - Function Value Representation

```
struct LambdaSet:
    # All possible function implementations
    set: List<(Symbol, List<Layout>)>

    # How to call functions in this set
    representation: ClosureRepresentation

    # Layout of the full closure data
    full_layout: Layout

# Example:
# f = if condition then \x -> x + 1 else \x -> x * 2
# Lambda set = { closure1, closure2 }
# Both have same signature but different implementations
```

### FunctionPointer - Type-Erased Function

```
struct FunctionPointer:
    args: List<Layout>
    ret: Layout

# Memory: { function_ptr, maybe_captures_ptr }
```

### InLayout - Interned Layout Reference

All layouts are interned for efficiency:

```
struct InLayout:
    index: u32    # Index into layout interner

# Benefits:
# - Deduplication (same layout = same index)
# - O(1) comparison (just compare indices)
# - Handles recursive types properly

# Pre-defined common layouts:
const VOID  = InLayout(0)
const UNIT  = InLayout(1)
const BOOL  = InLayout(2)
const U8    = InLayout(3)
const U16   = InLayout(4)
const U32   = InLayout(5)
const U64   = InLayout(6)
const U128  = InLayout(7)
const I8    = InLayout(8)
const I16   = InLayout(9)
const I32   = InLayout(10)
const I64   = InLayout(11)
const I128  = InLayout(12)
const F32   = InLayout(13)
const F64   = InLayout(14)
const DEC   = InLayout(15)
const STR   = InLayout(16)
```

### LayoutCache - Layout Computation Cache

```
struct LayoutCache:
    target: Target                    # Target architecture
    cache: List<CacheLayer<Result>>   # Layered cache for snapshots
    raw_function_cache: List<CacheLayer<Result>>
    interner: LayoutInterner

    # Convert type variable to layout
    function from_var(arena, var, subs) -> Result<Layout, Error>:
        if cached(var):
            return cache[var]
        layout = compute_layout_from_type(var, subs)
        cache[var] = layout
        return layout

    # Convert function type to layout
    function raw_from_var(arena, var, subs) -> Result<FunctionLayout, Error>:
        # Similar to from_var but for function types

    # Snapshot for rollback during specialization
    function snapshot() -> CacheSnapshot:
        push new cache layer

    # Rollback to previous state
    function rollback_to(snapshot):
        pop cache layer
```

### RawFunctionLayout - Function Layout Variants

```
enum RawFunctionLayout:
    # Normal function with arguments and possible closures
    Function:
        arguments: List<Layout>
        lambda_set: LambdaSet
        return_layout: Layout

    # Type-erased function (runtime dispatch)
    ErasedFunction:
        arguments: List<Layout>
        return_layout: Layout

    # Zero-argument thunk (lazy value)
    ZeroArgumentThunk(Layout)
```

## Target-Specific Information

### Tag ID in Pointer Optimization

```
impl UnionLayout:
    function stores_tag_id_in_pointer(target) -> bool:
        match self:
            Recursive(tags):
                # Can store tag in low bits if tags < alignment
                return len(tags) < target.ptr_width
            _:
                return false

    # Masks for extracting tag ID from pointer
    const POINTER_MASK_32BIT = 0b0000_0111  # 3 bits (8-byte alignment)
    const POINTER_MASK_64BIT = 0b0000_0011  # 2 bits (conservative)
```

### Memory Sizes by Target

```
| Type        | 32-bit    | 64-bit    |
|-------------|-----------|-----------|
| Pointer     | 4 bytes   | 8 bytes   |
| Str         | 12 bytes  | 24 bytes  |
| List        | 12 bytes  | 24 bytes  |
| I64         | 8 bytes   | 8 bytes   |
| Bool        | 1 byte    | 1 byte    |

# Alignment follows platform ABI rules
# Structs padded to alignment of largest field
```

## Key Concepts

1. **Monomorphic**: Layouts have no type variables - fully concrete
2. **Interning**: All layouts stored once and referenced by index
3. **Union Optimizations**: Multiple representations for sum types
4. **NULL Optimization**: Empty variants can use NULL pointer
5. **Lambda Sets**: Track all possible functions at call sites
6. **Target-Dependent**: Sizes/alignments vary by architecture
