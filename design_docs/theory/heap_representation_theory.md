# Heap Representation Theory

## Overview

This document describes how Elm values are represented in memory, bridging compile-time type decisions with runtime heap layout. It covers the four representation models, unboxing optimization, and the invariants that ensure correctness across compilation phases.

**Phases**: Monomorphization → MLIR Generation → Runtime

**Pipeline Position**: Cross-cutting concern from type specialization to GC

**Key Invariants**: REP_*, HEAP_*, XPHASE_*

## The Four Representation Models

The compiler defines four distinct data representation models (REP_001):

| Model | Purpose | Where Used |
|-------|---------|------------|
| **ABI** | Function call boundaries | Kernel calls, compiled function calls |
| **SSA** | MLIR operand types | IR values during compilation |
| **Heap** | Runtime object fields | Heap-allocated data structures |
| **Logical** | Elm semantics | Type checking, program logic |

**Key insight**: Rules in one model do not imply rules in another unless explicitly linked by an invariant.

### ABI Representation (REP_ABI_001, REP_ABI_002)

At function call boundaries:
- **Int, Float, Char**: Pass-by-value MLIR types (`i64`, `f64`, `i16`)
- **All other Elm values**: Pass as `!eco.value` (including Bool)

```
Function: add : Int -> Int -> Int
ABI:      (i64, i64) -> i64

Function: identity : a -> a
ABI:      (!eco.value) -> !eco.value
```

### SSA Representation (REP_SSA_001)

SSA operands in MLIR:
- **Int**: `i64`
- **Float**: `f64`
- **Char**: `i16`
- **Bool**: `i1` (within a function only)
- **All other values**: `!eco.value`

Note: Bool uses `i1` in SSA but `!eco.value` at ABI boundaries.

### Heap Representation (REP_HEAP_001, REP_HEAP_002)

Heap object fields:
- Determined by layout metadata (RecordLayout, TupleLayout, CtorLayout)
- Independent of ABI and SSA representation
- Uses unboxed bitmaps to mark inline fields

### Logical Representation

Elm semantic types:
- `Int`, `Float`, `Bool`, `Char`, `String`
- `List a`, `Maybe a`, `Result e a`
- Records, tuples, custom types

## Unboxing Optimization

### Which Types Can Be Unboxed?

Only three primitive types can be stored unboxed in heap fields:

| Type | Heap Storage | Size |
|------|--------------|------|
| Int | `i64` unboxed | 8 bytes |
| Float | `f64` unboxed | 8 bytes |
| Char | `i16` unboxed (padded to 8) | 2 bytes |

**Bool is NOT unboxed in heap fields**. It's stored as `!eco.value` pointing to the embedded True/False constants.

### Layout Metadata

During monomorphization, layouts are computed:

```elm
type alias RecordLayout =
    { fieldCount : Int
    , unboxedCount : Int
    , unboxedBitmap : Int      -- Bitmask of unboxed fields
    , fields : List FieldInfo
    }

type alias FieldInfo =
    { name : Name
    , index : Int
    , monoType : MonoType
    , isUnboxed : Bool
    }
```

The `unboxedBitmap` indicates which fields are stored inline vs as heap pointers.

### Example: Record Unboxing

```elm
type alias Point = { x : Int, y : Int, label : String }
```

Layout:
```
RecordLayout
    { fieldCount = 3
    , unboxedCount = 2
    , unboxedBitmap = 0b011  -- x and y unboxed
    , fields =
        [ { name = "x", index = 0, monoType = MInt, isUnboxed = True }
        , { name = "y", index = 1, monoType = MInt, isUnboxed = True }
        , { name = "label", index = 2, monoType = MString, isUnboxed = False }
        ]
    }
```

Heap layout:
```
[Header:8][unboxed_bitmap:8][x:i64][y:i64][label:HPointer]
```

### Container Unboxing

**Lists** can store unboxed head values:

```elm
myList : List Int
-- Cons cells store head as i64, not HPointer
```

Cons layout with unboxed head:
```
[Header:8][head:i64][tail:HPointer]
         ^-- unboxed_head flag in header
```

**Tuples** use per-element bitmap:

```elm
(Int, String, Float)
-- unboxedBitmap = 0b101 (first and third unboxed)
```

Heap layout:
```
[Header:8][a:i64][b:HPointer][c:f64]
```

## Representation Boundaries

### Projection: Heap → SSA (REP_BOUNDARY_001)

When extracting a field from a heap object:

```mlir
// If layout says field is unboxed:
%value = eco.project.record %record, 0 : !eco.value -> i64

// If layout says field is boxed:
%value = eco.project.record %record, 2 : !eco.value -> !eco.value
```

**Invariant**: Projection type matches physical storage, not logical type.

### Construction: SSA → Heap (REP_BOUNDARY_002)

When building a heap object:

```mlir
// Set unboxed bitmap based on SSA operand types
eco.construct.record %field0, %field1, %field2
    { unboxed_bitmap = 5 }  // 0b101
```

The bitmap is computed from SSA operand types (`i64`, `f64`, `i16` → unboxed).

### Closure Captures (REP_CLOSURE_001, REP_CLOSURE_002)

Closures follow SSA representation rules:
- Only `i64`, `f64`, `i16` operands are stored unboxed
- All other values (including Bool as `i1`) are stored as `!eco.value`

```mlir
// Capturing an Int and a Bool
eco.papCreate @fn, arity=2, captured=[%int_val, %bool_val]
    { capture_unboxed = 1 }  // Only first capture unboxed
```

## Embedded Constants (REP_CONSTANT_001, REP_CONSTANT_002)

Well-known constants are never heap-allocated:

| Constant | HPointer.constant Value |
|----------|-------------------------|
| Unit | 1 |
| True | 3 |
| False | 4 |
| Nil | 5 |
| EmptyString | 7 |
| Nothing | 8 |
| EmptyRec | 9 |

These use nonzero `constant` bits in HPointer and are distinguished from heap pointers by checking `constant != 0`.

## Heap Object Layouts

### Header (HEAP_001)

Every heap object starts with an 8-byte header:

```cpp
struct Header {
    uint64_t tag : 5;        // Object kind (Tag enum)
    uint64_t color : 2;      // GC color
    uint64_t age : 2;        // Survival count
    uint64_t epoch : 2;      // GC epoch
    uint64_t pin : 1;        // Pinned flag
    uint64_t size : 52;      // Object-specific (varies by type)
};
```

### Cons (List Node)

```cpp
struct Cons {
    Header header;           // tag = Tag_Cons
    Unboxable head;          // 8 bytes (unboxed or HPointer)
    HPointer tail;           // 8 bytes
};
// header.size encodes unboxed_head flag
```

### Tuple2/Tuple3

```cpp
struct Tuple2 {
    Header header;           // tag = Tag_Tuple2
    Unboxable a, b;          // 8 bytes each
};
// header.size encodes unboxed_bitmap (2 bits)

struct Tuple3 {
    Header header;           // tag = Tag_Tuple3
    Unboxable a, b, c;       // 8 bytes each
};
// header.size encodes unboxed_bitmap (3 bits)
```

### Record

```cpp
struct Record {
    Header header;           // tag = Tag_Record
    uint64_t unboxed;        // Bitmap of unboxed fields
    Unboxable values[];      // Variable-length array
};
// header.size = field count
```

### Custom (ADT)

```cpp
struct Custom {
    Header header;           // tag = Tag_Custom
    uint64_t ctor_unboxed;   // ctor_tag:8 | unboxed_bitmap:56
    Unboxable values[];      // Variable-length array
};
// header.size = field count
```

### Closure

```cpp
struct Closure {
    Header header;           // tag = Tag_Closure
    uint64_t packed;         // n_values:6 | max_values:6 | unboxed:52
    EvalFunction evaluator;  // Function pointer
    Unboxable values[];      // Captured values
};
```

## Cross-Phase Invariants (XPHASE_*)

### Layout Consistency (XPHASE_001)

Layouts from monomorphization must match:
- `eco.construct` attributes (`tag`, `size`, `unboxed_bitmap`)
- C++ struct definitions in `Heap.hpp`

### Type Consistency (XPHASE_002)

All `!eco.value` SSA operands must correspond to valid HPointer values:
- Heap pointers with proper alignment
- Embedded constants with nonzero constant bits

### CallInfo Authority (XPHASE_010)

MLIR codegen uses `CallInfo` from GlobalOpt as the single source of truth—it does not re-derive staging from MonoTypes.

## GC Implications

### Tracing (HEAP_019)

The GC uses unboxed bitmaps to distinguish pointers from inline values:

```cpp
void scanObject(void* obj) {
    Header* hdr = (Header*)obj;
    switch (hdr->tag) {
        case Tag_Record: {
            Record* rec = (Record*)obj;
            for (int i = 0; i < hdr->size; i++) {
                if (!(rec->unboxed & (1 << i))) {
                    // Field is a pointer—trace it
                    trace(rec->values[i].hptr);
                }
            }
            break;
        }
        // ...
    }
}
```

### No Cycles (HEAP_018)

Elm values are always acyclic (pure functional language), so GC traversal is guaranteed to terminate.

### Thread Ownership (HEAP_007)

Each heap region is owned by exactly one thread—no cross-thread heap pointers exist.

## Debugging Representation Bugs

Common issues and how to identify them:

| Symptom | Likely Cause |
|---------|--------------|
| Crash in GC | Bitmap mismatch—tracing unboxed value as pointer |
| Wrong value printed | Projection type mismatch with storage |
| Type error at call | ABI/SSA representation confusion |
| Memory corruption | Layout metadata doesn't match C++ struct |

### Debugging Checklist

1. **Check layout metadata**: Does `unboxedBitmap` match field types?
2. **Check projection ops**: Does result type match storage type?
3. **Check construction ops**: Does bitmap match operand types?
4. **Check ABI boundaries**: Are boxable values properly boxed/unboxed?

## Relationship to Other Documents

- [Monomorphization Theory](pass_monomorphization_theory.md) — Layout computation
- [MLIR Generation Theory](pass_mlir_generation_theory.md) — Construction/projection ops
- [EcoToLLVM Theory](pass_eco_to_llvm_theory.md) — LLVM lowering of heap ops
- [THEORY.md](../../THEORY.md) — Runtime GC details

## See Also

- `design_docs/invariants.csv` — Full invariant catalog
- `runtime/src/allocator/Heap.hpp` — C++ struct definitions
- `compiler/src/Compiler/AST/Monomorphized.elm` — Layout types
