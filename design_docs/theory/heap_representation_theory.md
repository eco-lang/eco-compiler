# Heap Representation Theory

> **Note (HPointer representation redesign):** The HPointer layout and embedded
> constants described in some sections below are superseded. HPointers now store a
> raw absolute 8-byte-aligned address (no heap_base offset, no shift; the word is
> the address), discriminated by a `ptr_ind` bit, and the embedded constants are
> just three — `False` (0x4), `True` (0x5), and the merged `Empty` (0x6) which
> subsumes Unit/Nil/Nothing/""/{}. Bool's low bit equals the SSA/ABI `i1` value.
> See the "HPointers: Raw Absolute Addresses" section of `THEORY.md`, invariants
> HEAP_008/010/017/028/029 and REP_CONSTANT_00x, and
> `plans/hpointer-representation-redesign.md` (Design Decisions D1–D11) for the
> authoritative description.

## Overview

This document describes how Elm values are represented in memory, bridging compile-time type decisions with runtime heap layout. It covers the four representation models, unboxing optimization, and the invariants that ensure correctness across compilation phases.

**Phases**: Monomorphization → MLIR Generation → Runtime

**Pipeline Position**: Cross-cutting concern from type specialization to GC

**Key Invariants**: REP_*, REP_LLVM_*, HEAP_*, XPHASE_*

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

### LLVM Representation (REP_LLVM_001, Apr 17 2026)

At the LLVM dialect and below:
- `!eco.value` → `ptr addrspace(1)` (GC-managed pointer)
- Primitives (`i64`, `f64`, `i16`) pass through unchanged
- `ptrtoint`/`inttoptr` conversions only at:
  - Heap storage boundaries (fields stored as i64 in heap layout)
  - Global storage boundaries (globals have i64 slots)
  - Closure capture storage boundaries (closure values are i64)
  - Embedded-constant encoding (40-bit tagged word)
  - Bit manipulation of constant field on ADT-case scrutinee (via `valueToI64`)
- The BF dialect's `BFTypeConverter` is unified with `EcoTypeConverter` so BF runtime declarations also use `ptr<1>` for HPtr params/returns
- Bool widening in heap/record/custom field stores: `widenFieldToI64` dispatches on type (Bool constants go through `PtrToIntOp`; primitives use `ZExt`)
- **i64-encoded heap-storage ABI**: `EcoPtrIntVerify` permits `i64` storage in heap slots (values arrays) and globals — these are the allow-listed `ptrtoint`/`inttoptr` boundaries. `i64` is **forbidden** as the return type of functions whose logical result is an HPtr; returns must be `ptr addrspace(1)`.

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

The `unboxed` bits in the heap object Header indicate whether container elements are stored unboxed. *(Apr 20, 2026)* The field holds **2 bits per slot**, replacing the earlier 1-bit (boxed / unboxed) bitmap. The 2-bit kind scheme applies uniformly to `Record.unboxed`, `Custom.unboxed`, `Closure.unboxed`, the `ElmArray` header kind, and `Cons.header.unboxed`:

| Bits | Kind | Storage |
|---|---|---|
| `00` | Boxed HPointer | `.p` |
| `01` | Int (i64) | `.i` |
| `10` | Float (f64) | `.f` |
| `11` | Char (u16) | `.c` |

```cpp
u32 unboxed : 6; // 2 bits/slot; Cons (1 slot), Tuple2 (2), Tuple3 (3), ElmArray (1 uniform).
```

Header.unboxed was widened from 3 bits → **6 bits** to hold up to 3 per-slot kinds for Tuple3 / ElmArray header. Bitmap capacity limits:

| Container | Max slots |
|---|---|
| Custom (ADT) | 24 fields (2×24 = 48 bits within `ctor_unboxed`) |
| Record | 32 fields (64-bit `unboxed`) |
| Closure | 26 captures (52-bit `unboxed` field of `packed`) |

New runtime helpers:
- `fieldKind(bitmap, idx)` — extract the 2-bit kind for slot `idx`
- `bitmapSetKind(bitmap, idx, kind)` — set the 2-bit kind for slot `idx`
- `pointerMaskFromKindBitmap(bitmap, count)` — derive a 1-bit-per-slot pointer mask (kind==0 ⇒ trace) for Cheney/mark-sweep scanning

The compiler emits 2-bit bitmaps via `computeRecordLayout`, `computeCtorLayout`, and `computeTupleLayout`. `eco.construct.list` gained a `head_kind` attribute (vs. the old `head_unboxed` bit). MLIR verifiers enforce that each declared per-slot kind matches the SSA type of the operand stored into that slot.

**Lists** can store unboxed head values:

```elm
myList : List Int
-- Cons cells store head as i64, not HPointer
```

Cons layout with unboxed head:
```
[Header:8][head:i64][tail:HPointer]
         ^-- unboxed bit 0 in header
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

**Arrays** use the `unboxed` bit 0 in the header to indicate element storage:

- `unboxed` bit 0 = 1: Elements are stored as unboxed primitives (e.g., raw `int64_t` values)
- `unboxed` bit 0 = 0: Elements are stored as boxed `HPointer` values (default)

```elm
myArray : Array Int
-- Elements stored as raw i64, not HPointer
```

Heap layout with unboxed elements:
```
[Header:8][size:8][elem0:i64][elem1:i64][...]
          ^-- unboxed bit 0 in header indicates all elements are unboxed
```

This enables arrays of Int, Float, or Char to store elements without boxing overhead, similar to how `Cons` cells store unboxed head values.

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

## Embedded Constants (REP_CONSTANT_001, REP_CONSTANT_002, REP_CONSTANT_003)

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

*(Apr 2026)* Embedded constants — `Nil`, `Unit`, `True`, `False`, `EmptyRecord` (`EmptyRec`), `Nothing`, `EmptyString` — are stored as tagged-pointer constants and never live in the heap. GC rooting machinery treats them specially:

- `stripIntToPtr` returns `nullptr` for `inttoptr(ConstantInt)`, so constants can never enter GC root sets at statepoints.
- `compareUnboxableSlot`, `Utils::eqHelp`/`Utils::cmp`, and kernel equality code consult `header.unboxed` / the 2-bit bitmap to decide whether a given slot holds an unboxed primitive vs. a HPointer, and to compare constants directly when the bits match.

### REP_CONSTANT_003: Constants Are Type-Minimum, Not Raw Null *(May 12, 2026)*

`Elm_Kernel_Utils_equal` / `notEqual` used to convert their HPointer args through `Export::toPtr`, which returns `nullptr` for any embedded-constant HPointer. Both `True` and `False` thus compared equal to "null", silently breaking every Bool pattern match and equality comparison of constructor constants.

The fix: equality and ordering kernels treat embedded HPointer constants as **type-minimum** values — they participate in compare/equal directly by their `constant` bits, not by dereferencing through `toPtr`. `compareUnboxableSlot` was updated to give `Const_EmptyString` and `Const_Nil` their appropriate type-minimum positions in the ordering.

This is captured as **REP_CONSTANT_003** in `design_docs/invariants.csv`. The bug was caught by the new MLIR-equivalence runner (`test/mlir_equivalence_main.cpp`) comparing Stage 2 (JS) vs Stage 6 (native) MLIR output and finding identical MLIR producing divergent runtime behaviour.

## Heap Object Layouts

### Header (HEAP_001)

Every heap object starts with an 8-byte header:

```cpp
struct Header {
    uint32_t tag : 5;        // Object kind (Tag enum)
    uint32_t color : 2;      // GC color
    uint32_t pin : 1;        // Pinned flag
    uint32_t age : 2;        // Survival count
    uint32_t unboxed : 6;    // 2 bits/slot — kinds for Cons/Tuple2/Tuple3/ElmArray
    uint32_t refcount : 16;  // Reserved
    uint32_t size;           // Object-specific (varies by type)
};
```

The `unboxed` field holds per-slot primitive kinds (2 bits each): `00` = boxed HPointer, `01` = Int, `10` = Float, `11` = Char. Slot `i` lives at bits `[2i, 2i+1]`. For `Cons`, slot 0 is the head kind. For `Tuple2`/`Tuple3`, slots 0..1 / 0..2 are per-element kinds. For `ElmArray`, slot 0 is a uniform kind applied to all elements.

### Cons (List Node)

```cpp
struct Cons {
    Header header;           // tag = Tag_Cons
    Unboxable head;          // 8 bytes (unboxed or HPointer)
    HPointer tail;           // 8 bytes
};
// header.unboxed bit 0 encodes unboxed_head flag
```

### Tuple2/Tuple3

```cpp
struct Tuple2 {
    Header header;           // tag = Tag_Tuple2
    Unboxable a, b;          // 8 bytes each
};
// header.unboxed encodes unboxed_bitmap (2 bits)

struct Tuple3 {
    Header header;           // tag = Tag_Tuple3
    Unboxable a, b, c;       // 8 bytes each
};
// header.unboxed encodes unboxed_bitmap (3 bits)
```

### ElmArray

```cpp
struct ElmArray {
    Header header;           // tag = Tag_ElmArray
    Unboxable values[];      // Variable-length array of elements
};
// header.unboxed bit 0: 1 = elements are unboxed primitives, 0 = elements are boxed HPointer
// header.size = element count
```

When `unboxed` bit 0 is set, elements are stored as raw unboxed primitives (e.g., `int64_t` for Int, `double` for Float) instead of `HPointer` values. This avoids boxing overhead for arrays of Int, Float, or Char.

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
    uint64_t packed;         // n_values:6 | max_values:6 | result_kind:2 | unboxed:50
    EvalFunction evaluator;  // Function pointer
    Unboxable values[];      // Captured values
};
```

*(May 8-10, 2026)*: The `packed` word's `unboxed` field was narrowed from 52 bits to 50 to make room for a 2-bit `result_kind` (00 = boxed, 01 = Int, 10 = Float, 11 = Char). This drops the capture cap 26 → 25 captures but lets closures returning primitive Int / Float / Char return them **unboxed** end-to-end through `eco_apply_closure_eval` / `eco_closure_call_saturated_eval`. See [Kernel ABI Theory §Per-Instance ABI](kernel_abi_theory.md#per-instance-abi-replaces-numberboxed-may-6-8-2026) and the corresponding ops attrs `_result_kind` / `_result_kinds` on `PapCreate{,Group}` / `PapExtend`.

### String (Three Forms) *(Apr 27, 2026)*

`String` has three heap representations with a shared `header.size` semantics — logical UTF-16 code-unit count for all three. Compiler/MLIR allocations only ever produce `Tag_String`; ropes and slices arise inside `Elm::StringOps`.

```cpp
struct ElmString {                  // Tag_String — flat UTF-16 leaf
    Header header;                  // header.size = code units
    u16 chars[];
};

struct ALIGN(8) ElmStringSlice {    // Tag_StringSlice — view over a leaf
    Header header;                  // header.size = slice length
    HPointer base;                  // points to a leaf only (slice-of-slice collapsed)
    u32 offset;
    u32 _padding;
};

struct ALIGN(8) ElmStringRope {     // Tag_StringRope — concat tree node
    Header header;                  // header.size = total length
    HPointer left;
    HPointer right;
    u32 height;                     // 0 for leaf/slice
    u32 leafCount;
};
```

`header.unboxed` is always 0 for slice and rope (no per-slot kind bitmap). Tracing forwards `base` for slices and `left`/`right` for ropes; `getObjectSize` has dedicated `Tag_StringSlice` / `Tag_StringRope` arms returning the fixed-size struct sizes. See [string_rope_representation_theory.md](string_rope_representation_theory.md) and HEAP_025 for the full contract.

## Cross-Phase Invariants (XPHASE_*)

### Layout Consistency (XPHASE_001)

Layouts from monomorphization must match:
- `eco.construct` attributes (`tag`, `size`, `unboxed_bitmap`)
- C++ struct definitions in `Heap.hpp`

*(May 14, 2026)*: A regression class where this invariant could be violated has been closed at its boundary. Container `MonoType`s for `TOpt.Tuple` / `TOpt.Record` / `TOpt.TrackedRecord` are now built from the already-specialised element expressions, not from `meta.tipe`, so the `unboxed_bitmap` cannot disagree with the SSA types of slot constructors even when an upstream constraint-flow gap leaves a slot's TVar unbound. See [Monomorphization Theory §Tuple/Record Specialised-Element MonoType](pass_monomorphization_theory.md#tuple--record-specialised-element-monotype) and the `TupleSlotBoxing*Test.elm` regression suite.

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
                if (fieldKind(rec->unboxed, i) == 0) {
                    // Slot is a boxed HPointer—trace it.
                    trace(rec->values[i].hptr);
                }
            }
            break;
        }
        case Tag_ElmArray: {
            ElmArray* arr = (ElmArray*)obj;
            if ((hdr->unboxed & 0x3) == 0) {
                // Uniform kind is boxed—trace every element.
                for (int i = 0; i < hdr->size; i++) {
                    trace(arr->values[i].hptr);
                }
            }
            // Non-zero uniform kind ⇒ elements are raw primitives—skip tracing.
            break;
        }
        // ...
    }
}
```

The GC implementations in `NurserySpace.cpp` and `OldGenSpace.cpp` check the `unboxed` flag in the header when scanning arrays. When elements are unboxed primitives (bit 0 set), the GC skips tracing them since they are not heap pointers.

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

## Old Generation Layout *(rewritten Apr 25-26, 2026)*

The old generation is a **segregated-fits allocator backed by a Big Bag of Pages (BBoP)**. The initial `initial_old_gen_size` (16 MiB by default) is committed up front and sliced into pages of `alloc_buffer_size` (128 KiB by default) sitting in `unassigned_blocks_` until first use. See `runtime/src/allocator/OldGenSpace.{hpp,cpp}` for the implementation and [THEORY.md](../../THEORY.md) for the full design.

The defaults shown here (`initial_old_gen_size`, `alloc_buffer_size`, `large_object_threshold`, `string_tiny_slice_limit`, etc.) live on `HeapConfig` in `AllocatorCommon.hpp` and are **runtime-tunable**: a `heap-config.json` file at startup (parsed by `HeapConfigJson.cpp`) overrides any subset, and the compiler-side `eco-config.json` *(May 21, 2026)* threads further tunables through the same loader. The defaults were retuned after a parameter sweep against the Stage 7 self-compile workload.

### Size Classes

| Range | Class scheme | Notes |
|---|---|---|
| 8 .. 256 B | 32 small classes, step 8 B | `(size+7)/8 - 1` indexes the class |
| 512 B .. 65536 B | up to 8 medium classes (powers of two) | runtime cap: `large_object_threshold` |
| `large_object_threshold` .. `alloc_buffer_size` | mid-range | wraps a single page-spanning `Tag_Free` cell, splits via larger-cell path |
| ≥ `alloc_buffer_size` | large/pinned | `allocateLargeBlock`; reused from `free_large_blocks_` first |

Each class lazily slices a bag page into uniform `Tag_Free` cells on first use; the cell header carries `Tag_Free` and the cell's full byte size, so any sweep walk can skip over it like any other heap object.

### Class-Selection Asymmetry

Two distinct class lookups are used:

- **`sizeClass(size)` — round up.** Used at allocation time. Returns the smallest class whose `cellSize ≥ size`, so a popped cell can always satisfy the request.
- **`freeListClassFor(span)` — round down.** Used at placement time (split tails, sweep coalesces, bag-page tails). Returns the largest class whose `cellSize ≤ span`, so cells on `free_lists_[cls]` always have at least `classToSize(cls)` bytes — the invariant the fast path relies on.

Without round-down placement, a 352-byte span placed via `sizeClass` would land on cls=32 (cellSize=512); the fast path would then hand it out as a 512-byte slot, overflowing on the first store. This was the root cause of a Stage 7 SEGV in `tryAllocateBySplittingLarger` *(Apr 25, 2026)*.

### Block Uniformity Invariant

`walkStep` walks size-class blocks by `classToSize(cls)`, so cells in those blocks must all be exactly that size. Split residuals and sweep coalesces respect this: tails that don't fit the current class are repushed at smaller classes via `freeListClassFor`. Mid-class allocations that leave slack (e.g. 360 B in a 512 B cell) write a `Tag_Free` trailer in the slack at allocation time via `padCellSlack` — sweep stride must land on a real header, not zeros it interprets as `Tag_Int(0)`.

### Per-Block Mark Bitmap *(Apr 26, 2026)*

Liveness for old-gen objects is tracked in **per-block bitmaps** (1 bit per 8-byte slot), not in object headers:

- `mark_bits_[i]` covers regular blocks
- `large_block_mark_[i]` is a single live/dead flag for `is_large` blocks (the matching `mark_bits_[i]` stays empty)
- Headers retain `header.color` for compaction's debug asserts but are no longer load-bearing for sweep liveness
- Invariant: `mark_bits_.size() == large_block_mark_.size() == blocks_.size()`

### Page Index *(Apr 26, 2026)*

`page_to_block_index_` maps page slot `(p - region_base_) / alloc_buffer_size` to the `blocks_` index that owns the page, so `blockIndexFor` is O(1) (was a linear `findBlockContaining` scan). Slots whose page belongs to no current `blocks_` entry hold the sentinel `NO_BLOCK`. For `is_large` blocks, every page slot the extent spans is filled with the same `blocks_` index.

## Large Object Allocation

*(Apr 2026)*: Objects larger than a nursery block are allocated in a dedicated pinned large-object space within the old generation. Large objects:

- Are never copied by the nursery's Cheney algorithm
- Are pinned in place and managed by mark-sweep
- Have their size tracked in the old generation's allocation metadata

This prevents excessively large objects from fragmenting the nursery's semi-space copying collector.

Large-object allocation is supported in-block as well: the OLD GEN tracks a per-block end-of-objects offset (`BlockInfo.end_of_objects`, HEAP_024) so sweep and reference-fixup walks stop at the last live object rather than walking into uninitialized tail bytes. The nursery needed the same bookkeeping while it was block-structured, but no longer does: since HEAP_042 each semi-space is one contiguous extent, evacuation is a single bump, and the Cheney scan simply runs while `scan_ptr_ < copy_ptr_` — there are no tail gaps to describe.

*(Apr 26, 2026)*: Released large blocks are kept in `free_large_blocks_`; `allocateLargeBlock` consults this list before asking the Allocator for a fresh page.

### Split-Header Large Objects (HEAP_026) *(May 1-2, 2026)*

Strings and byte buffers above ~2 KiB use a **split-header** representation:

- A small fixed-size header — `Tag_LargeStringHeader` or `Tag_LargeByteHeader` — lives in the **nursery** like any other small object. The header carries a `HPointer body` pointing into the old gen.
- The actual payload (UTF-16 code units or raw bytes) lives in a **pinned old-gen body**, allocated through `allocateLargeBlock` and reused from `free_large_blocks_` like any other large allocation.

The header is small enough to flow through Cheney copying for free; the body is never moved. This dodges two problems at once:

1. Repeatedly memcpying multi-kilobyte payloads through every minor GC.
2. Forcing all large strings / buffers to be allocated directly in the old gen, which would require major-GC rooting of every callsite that briefly materialises a large value.

39 audited kernel-C++ call sites now route through `alloc::resolveByteBufferBody` / `resolveStringBody`, which transparently follow the `body` pointer for split headers and fall through to the inline payload for `Tag_String` / `Tag_Bytes`. Released large bodies may be reclaimed in any old-gen GC state, not just `Idle`.

The compiler's MLIR allocations remain leaf-only (`Tag_String`, `Tag_Bytes`); the split-header variants are produced exclusively by kernel `String.fromBytes` / `String.append` / `Bytes` builders that know their final size up front.

See **HEAP_026** in `design_docs/invariants.csv`. Plan: `plans/large-object-split-header-bodies.md`.

## GC Root Safety for Heap Construction

*(Apr 2026)*: When constructing heap objects, any HPointers captured into a buffer before calling `allocator.allocate()` must be rooted. The `StackRootGuard` RAII helper pushes HPointers onto `RootSet::stack_root_ranges` (as 1-element ranges) and restores on destruction:

```cpp
StackRootGuard guard(rootSet, value, callback, innerTask);
auto result = allocator.allocate(sizeof(Task));
// guard destructor restores stack root point
```

This applies to `allocTask`, `allocProcess`, `cons`, `tuple2`, `tuple3`, `arrayFromPointers`, `listFromPointers`, and all helpers that capture HPointers across allocation.

## Relationship to Other Documents

- [Monomorphization Theory](pass_monomorphization_theory.md) — Layout computation
- [MLIR Generation Theory](pass_mlir_generation_theory.md) — Construction/projection ops
- [EcoToLLVM Theory](pass_eco_to_llvm_theory.md) — LLVM lowering of heap ops
- [String Rope Representation Theory](string_rope_representation_theory.md) — `Tag_String` / `Tag_StringRope` / `Tag_StringSlice` and the StringOps API
- [THEORY.md](../../THEORY.md) — Runtime GC details

## See Also

- `design_docs/invariants.csv` — Full invariant catalog
- `runtime/src/allocator/Heap.hpp` — C++ struct definitions
- `compiler/src/Compiler/AST/Monomorphized.elm` — Layout types
