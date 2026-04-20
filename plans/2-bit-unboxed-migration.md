# 2-Bit Unboxed Migration Plan

This plan migrates Eco from the current 1-bit-per-slot "boxed vs. unboxed" bitmap scheme to a 2-bit-per-slot **primitive kind** scheme. It combines the design with the file:line impact audit so the document can be executed directly against the tree at `/work`.

All file:line references were captured from the tree at audit time. Re-check line numbers before editing — they may drift.

**Step 0 pre-flight findings (2026-04-20):** Audited `test/codegen/*.mlir` for capacity breaches. No PAP test exceeds 26 captures (largest: `pap_unboxed_captured` with 2 captures; `papextend_*` with ≤4). No construct_* test exceeds 24 Custom / 32 Record field-indices (largest: `construct_max_unboxed` at 8, `construct_many_unboxed` at 5). Safe to proceed under new capacity limits.

---

## §0 Encoding and scope

### 0.1 The new 2-bit encoding

Every bitmap we touch (Cons/Tuple header bits, Custom.unboxed, Record.unboxed, DynRecord.unboxed, Closure.unboxed, ElmArray header bits, all MLIR `unboxed_bitmap` / `head_unboxed` / `newargs_unboxed_bitmap` / `capture_unboxed` attributes) interprets each slot as a 2-bit **primitive kind**:

| Bits | Kind | Slot storage (`Unboxable` arm) |
|---|---|---|
| `00` | Boxed HPointer | `.p` |
| `01` | Unboxed `Int` (i64) | `.i` |
| `10` | Unboxed `Float` (f64) | `.f` |
| `11` | Unboxed `Char` (u16) | `.c` (low 16 bits) |

Bool and String remain **always boxed** (kind `00`). There is deliberately no encoding for unboxed Bool or unboxed String; they live behind HPointer constants / heap strings respectively.

Slot `i`'s kind is at bit positions `[2*i, 2*i+1]`:
`kind = (bitmap >> (2*i)) & 0x3`.

### 0.2 Per-container capacities under the new scheme

| Container | Bitmap width | Max slots (1-bit today) | Max typed slots (2-bit) |
|---|---|---|---|
| `Cons.header.unboxed` | 3 (only bit 0 used) | 1 head | 1 head |
| `Tuple2.header.unboxed` | 3 (bits 0,1) | 2 | 2 |
| `Tuple3.header.unboxed` | 3 (bits 0,1,2) | 3 | 3 |
| `ElmArray.header.unboxed` | 3 (uniform bit 0) | 1 uniform flag | 1 uniform kind |
| `Custom.unboxed` | 48 | 48 | **24** |
| `Record.unboxed` | 64 | 64 | **32** |
| `DynRecord.unboxed` | 64 | 64 | **32** |
| `Closure.unboxed` | 52 | 52 | **26** |

**Non-goals (explicit):**

- `ElmArray` stays uniform-kind. Mixed-primitive unboxed arrays are not introduced. The existing single "all boxed vs all unboxed" flag becomes a single 2-bit "boxed / Int / Float / Char" kind for the whole array.
- No change to attribute *types* in MLIR ops (they remain `I64Attr` / `BoolAttr`). Only docstrings and verifier logic change.
- No change to the `eco_alloc_custom` C ABI signature (still takes no bitmap; bitmap continues to be installed post-alloc via `eco_set_unboxed`).

### 0.3 Capacity-regression risk items requiring a pre-step

These drops must be verified against the test corpus before landing:

| Field | Old max slots | New max slots | Action |
|---|---|---|---|
| Closure captures | 52 | 26 | Grep test corpus for large-capture PAPs (see §9.3 / §10 Step 0). |
| Record fields unboxed | 64 | 32 | Same. |
| Custom fields unboxed | 32 (current Types.elm clamp) / 48 (struct) | 24 | Types.elm:523 clamp currently hides this; see §3.3. |

**Overflow policy** (applies to Record / DynRecord / Custom / Closure): fields whose index exceeds the new maximum are encoded as **boxed (kind `00`)**, i.e. they stay in `Unboxable.p` as HPointers. The compiler must also emit a debug log / invariant violation when overflow occurs so tests can detect it.

### 0.4 Already-present 2-bit infrastructure to reuse

- `enum ParamKind { PK_Boxed=0, PK_Int=1, PK_Float=2, PK_Char=3 }` at `runtime/src/allocator/Heap.hpp:252-257` — already the target encoding.
- `EvalParamLayout` at `Heap.hpp:262-265` — already encodes per-slot primitive kind in 2 bits.
- `mlirTypeToParamKind` at `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:854` — already maps MLIR type → `ParamKind` and is the intended helper for deriving kinds from SSA types.

---

## §1 Heap layout: Header bitfield change

### 1.1 Redefine `Header`

**File**: `runtime/src/allocator/Heap.hpp` (current def at Heap.hpp:94).

Replace the `Header` struct with:

```cpp
typedef struct {
    u32 tag      : TAG_BITS;
    u32 color    : 2;    // White / Grey / Black for tri-color mark-and-sweep
    u32 pin      : 1;    // Memory-pinned object (prevents relocation)
    u32 age      : 2;    // Minor-GC survival counter
    u32 unboxed  : 6;    // 2 bits/field; used by Cons (1 field), Tuple2/3 (2/3 fields), ElmArray (uniform)
    u32 refcount : 16;   // Currently unused; reserved
    u32 size;            // Object size in type-specific units
} Header;
static_assert(sizeof(Header) == 8, "Header must be 64 bits");
```

**Removed fields**: `epoch : 2` and `padding : 1`.

**Evidence this is safe**: a grep across `runtime/src` (allocator/GC/runtime code) finds `epoch` only in the `Header` definition itself and in theory docs — no reads/writes of `hdr->epoch` in allocator/GC/runtime code. GC tracks its own `current_epoch` in `OldGenSpace`.

**Doc sync required**:
- `design_docs/theory/heap_representation_theory.md` (mentions epoch at lines 145, 260, 334).
- `THEORY.md` references to the header layout.
- `old_design_docs/eco-lowering.md:24, 27` (stale anyway; review and prune).

### 1.2 Interpretation per container

No struct-level type changes other than `Header` itself. The following bitmap fields keep their widths; only semantics change:

- `Cons.header.unboxed` (3 bits total) — bits 1:0 = head kind; bits 5:2 reserved / zero. Defined at Heap.hpp:94 via shared `Header`.
- `Tuple2.header.unboxed` — bits 1:0 = a, bits 3:2 = b, bits 5:4 reserved.
- `Tuple3.header.unboxed` — bits 1:0 = a, bits 3:2 = b, bits 5:4 = c.
- `ElmArray.header.unboxed` — bits 1:0 = uniform element kind; bits 5:2 reserved. Heap.hpp:358.
- `Custom.ctor_unboxed` at Heap.hpp:204-205 — low 16 bits `ctor`, upper 48 bits hold 24 × 2-bit kinds.
- `Record.unboxed` at Heap.hpp:211 — full u64; 32 × 2-bit kinds.
- `DynRecord.unboxed` at Heap.hpp:217 — full u64; 32 × 2-bit kinds.
- `Closure.unboxed` at Heap.hpp:243-245 (bitfield `u64 unboxed : 52`) — 26 × 2-bit kinds.

### 1.3 Shared C++ decode helpers (add)

Add small inline helpers in `runtime/src/allocator/HeapHelpers.hpp` (or a new `HeapBitmap.hpp`) so all GC / kernel / printer code goes through a single accessor:

```cpp
inline uint64_t fieldKind(uint64_t bitmap, unsigned index) {
    return (bitmap >> (2 * index)) & 0x3ULL;
}

inline uint32_t tupleFieldKind(uint32_t headerUnboxed, unsigned index) {
    return (headerUnboxed >> (2 * index)) & 0x3U;
}

inline uint64_t bitmapSetKind(uint64_t bitmap, unsigned index, uint64_t kind) {
    const uint64_t shift = 2ULL * index;
    const uint64_t mask  = 0x3ULL << shift;
    return (bitmap & ~mask) | ((kind & 0x3ULL) << shift);
}
```

Every GC / kernel / printer / verifier site below should use these helpers rather than inlining `>> (2*i) & 3`.

---

## §2 GC and allocator rewrites

### 2.1 Record / DynRecord / Custom / Closure field scanning

Under the new encoding, a GC trace step treats `kind == 0` as "boxed pointer, trace it" and every other kind as "primitive, skip."

**Rewrite pattern:**

```cpp
// Old
for (int i = 0; i < hdr->size; ++i) {
    if (!(rec->unboxed & (1ULL << i))) trace(rec->values[i].p);
}

// New
for (int i = 0; i < hdr->size; ++i) {
    if (fieldKind(rec->unboxed, i) == 0) trace(rec->values[i].p);
}
```

**Apply at every audited 1-bit test site:**

- `NurserySpace.cpp` — Record 616; Custom 608, 957; Closure 624, 979.
- `OldGenSpace.cpp` — Custom 480, 1142; Record 487, 1149; Closure 502, 1164.
- `RuntimeExports.cpp` — Custom 1549, 1663, 2290, 2376, 1493 (also 2043 for `custom->unboxed & 1`); Record 1701, 2216; Closure 338, 603, 617, 990, 1176, 1223.
- Tests: `test/allocator/HeapSnapshot.hpp:172, 346` (`closure->unboxed & (1ULL << i)`).

### 2.2 Tuple2 / Tuple3 header-bit tests

Header-stored bitmaps for tuples used 1 bit per element (bits 0,1[,2]). Under the new scheme each element uses 2 bits (at `2*i`).

**Rewrite at these sites:**

- `NurserySpace.cpp` — 588, 594-595, 600-602, 943-944, 949-951, 996, 1016, 1135, 1224.
- `OldGenSpace.cpp` — 460-461, 466-468, 473, 1122-1123, 1128-1130, 1135.
- `RuntimeExports.cpp` — 1599, 1608, 1621, 1630, 1639.

**Example rewrite (NurserySpace.cpp:588 style):**

```cpp
// Old
if (!(tuple->header.unboxed & 0x1)) trace(tuple->a.p);
if (!(tuple->header.unboxed & 0x2)) trace(tuple->b.p);

// New
if (tupleFieldKind(tuple->header.unboxed, 0) == 0) trace(tuple->a.p);
if (tupleFieldKind(tuple->header.unboxed, 1) == 0) trace(tuple->b.p);
```

### 2.3 Cons head bit

Currently spread across a lot of kernels and GC code — widest touch surface in the migration.

**Rewrite at these sites** (all currently test `header.unboxed & 1`, sometimes via `& 0x1`):

- `ListOps.cpp` — 22, 55, 84, 106, 135, 164, 194, 209, 237, 269, 296, 333, 381, 416, 458, 565-566, 626-628, 682-683.
- `ListOps.hpp` — 257, 281, 319, 341, 404.
- `RuntimeExports.cpp` — 2037, 2564, 2592, 2620.
- Kernels: see §7.2.

**Rewrite pattern:**

```cpp
// Old: "head is unboxed?"
if (cons->header.unboxed & 1) { /* primitive head */ }

// New: decode 2-bit kind at slot 0
uint32_t headKind = tupleFieldKind(cons->header.unboxed, 0);
switch (headKind) {
    case 0: /* boxed head: cons->head.p */ break;
    case 1: /* Int: cons->head.i */ break;
    case 2: /* Float: cons->head.f */ break;
    case 3: /* Char: cons->head.c */ break;
}
```

Where the old code only distinguished boxed/unboxed, replace `& 1` with `tupleFieldKind(..., 0) != 0`. Where the old code assumed "unboxed ⇒ Int" (kernels), switch on the kind instead — see §7.

### 2.4 ElmArray uniform flag

**Files**: `NurserySpace.cpp`, `OldGenSpace.cpp` (array scan sites), plus all kernels enumerated below.

```cpp
// Old
if (!(arr->header.unboxed & 1)) { /* trace elements */ }

// New
uint32_t kind = arr->header.unboxed & 0x3;
if (kind == 0) {
    for (u32 i = 0; i < arr->length; ++i) trace(arr->elements[i].p);
}
// else: skip (uniform primitive array; no pointers inside)
```

### 2.5 Inline tuple-mask writes in `HeapHelpers.hpp`

- Heap.hpp:94 header `unboxed : 3` becomes `unboxed : 6`, so the mask widens.
- `HeapHelpers.hpp:603` — `tuple->header.unboxed = unboxed_mask & 0x3;` must become `& 0xF` (4 bits used: 2 slots × 2).
- `HeapHelpers.hpp:628` — `tuple->header.unboxed = unboxed_mask & 0x7;` must become `& 0x3F` (6 bits used: 3 slots × 2).
- `HeapHelpers.hpp:670` — Custom: `obj->unboxed = unboxed_mask;` stays structurally (still a 48-bit fit assumption), but the *caller* is now passing a 2-bit-encoded value. Add an `assert((unboxed_mask >> 48) == 0)` to catch encoding overflow.

### 2.6 `arrayIsUnboxed`

**File**: `runtime/src/allocator/HeapHelpers.hpp:961`.

```cpp
inline bool arrayIsUnboxed(void* arr) {
    ElmArray* a = static_cast<ElmArray*>(arr);
    return (a->header.unboxed & 0x3) != 0;
}
```

Callers in `elm-kernel-cpp/src/core/JsArray.cpp` (100, 135, 168, 202, 243, 279, 332, 368-369) and tests (`HeapHelpersTest.cpp:438, 463, 489, 716, 785`) inherit the new semantics without source change but will need behavioral review per §7.2.

### 2.7 `closureCapture`

**File**: `runtime/src/allocator/HeapHelpers.hpp:999` (body at ~1010 currently does `cl->unboxed |= (1ULL << idx)`).

**Signature change (Option A chosen):**

```cpp
inline bool closureCapture(void* closure, Unboxable value, bool is_boxed, ParamKind kind);
```

**New body:**

```cpp
Closure* cl = static_cast<Closure*>(closure);
if (cl->n_values >= cl->max_values) return false;

const size_t idx = cl->n_values;
cl->values[idx] = value;

// Only 26 typed slots fit in the 52-bit bitfield (2 bits each).
if (!is_boxed && idx < 26) {
    uint64_t code = 0;
    switch (kind) {
        case PK_Int:   code = 0x1; break;
        case PK_Float: code = 0x2; break;
        case PK_Char:  code = 0x3; break;
        default:       code = 0x0; break;  // PK_Boxed / unsupported
    }
    cl->unboxed = bitmapSetKind(cl->unboxed, static_cast<unsigned>(idx), code);
}

cl->n_values++;
return true;
```

**Caller updates — must pass the correct `ParamKind`:**

- `runtime/src/platform/PlatformRuntime.cpp:470`
- `runtime/src/platform/Scheduler.cpp:485`  ← **spot-check required** (confirm the capture is always typed at the call site and not an "opaque HPointer of unknown primitive")
- `elm-kernel-cpp/src/time/TimeEffectManager.cpp:294-295` ← **spot-check required**
- `elm-kernel-cpp/src/http/HttpExports.cpp:566, 618-619`
- `elm-kernel-cpp/src/http/HttpEffectManager.cpp:174, 232`
- `elm-kernel-cpp/src/core/ProcessExports.cpp:89`
- `elm-kernel-cpp/src/core/TaskEffectManager.cpp:86`
- Tests: `test/allocator/HeapHelpersTest.cpp:1272, 1307-1309`.

For the "boxed" path (`is_boxed == true`) pass `PK_Boxed`; for unboxed primitives pass the matching `ParamKind`. If any spot-check reveals a site that captures an unboxed value *without* knowing its primitive type at the call (shouldn't happen given how the union arm is populated), fall back to Option B (derive kind from an MLIR-emitted attribute stored in the closure).

### 2.8 `eco_pap_extend` bitmap merge

**File**: `runtime/src/allocator/RuntimeExports.cpp:1165-1234`, specifically the merge at 1221-1223 and the mask at 1193-1197.

Old arithmetic:

```cpp
uint64_t merged = old_unboxed | (new_bitmap << old_n_values);
```

**New arithmetic:**

```cpp
uint64_t merged = old_unboxed | (new_bitmap << (2 * old_n_values));
```

And the pointer-mask used by `hptr_mask_clamp` must be derived from the new encoding (kind == 0 ⇒ pointer):

```cpp
uint64_t pointerMask = 0;
for (unsigned i = 0; i < (old_n_values + num_newargs); ++i) {
    if (fieldKind(merged, i) == 0) pointerMask |= (1ULL << i);
}
```

Any other `(new_bitmap << old_n_values)` arithmetic in this function or its helpers must adopt the `* 2` factor.

### 2.9 Capacity constants

- `(1ULL << 52)` bound at `runtime/src/codegen/EcoOps.cpp:352, 404` — **unchanged** as a *bitmap width* guard; but the corresponding `numCaptured` limit becomes 26 (see §5.3).
- `unboxedBitmap << 12` at `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:616` — unchanged; the width is still 52.
- Closure capture helper `cl->unboxed |= (1ULL << idx)` at HeapHelpers.hpp:1010 — replaced by `bitmapSetKind` per §2.7.
- `buildUnboxedBitmap` test helper at `test/allocator/HeapGenerators.cpp:22-30` — body rewritten to fill 2-bit kinds; callers' `max_bits` (48/64/52 at lines 254, 269, 330, 467, 485, 553) stay the same (they're widths). See §9.3.

---

## §3 Compiler layout computation (Elm-side)

**File**: `compiler/src/Compiler/Generate/MLIR/Types.elm`.

### 3.1 Add `encodeUnboxedKind`

Near the layout functions (around Types.elm:373), add:

```elm
encodeUnboxedKind : Mono.MonoType -> Int
encodeUnboxedKind monoType =
    case monoType of
        Mono.MInt ->
            1

        Mono.MFloat ->
            2

        Mono.MChar ->
            3

        _ ->
            0
```

This is the single source of truth for the 2-bit encoding on the compiler side. Bool/String and all other types → `0` (boxed).

### 3.2 Rewrite `computeRecordLayout` (Types.elm:423-466)

- Remove the "fields reordered unboxed-first, bitmap = `(2^unboxedCount) - 1`" shortcut.
- Iterate fields in final index order; for each field encode its kind at position `2 * field.index`.
- Overflow: if `field.index >= 32`, force kind to `0` and emit a compile-time debug log (see §0.3).

```elm
bitmap =
    List.foldl
        (\field acc ->
            let
                kind =
                    if field.isUnboxed && field.index < 32 then
                        encodeUnboxedKind field.monoType

                    else
                        0
            in
            Bitwise.or acc (Bitwise.shiftLeftBy (2 * field.index) kind)
        )
        0
        fields
```

`unboxedCount` may be retained for stats / test use; if tests don't need it, remove it.

### 3.3 Rewrite `computeCtorLayout` (Types.elm:505-540)

- Fix the outdated comment at Types.elm:519 ("32 bits") — should read "48 bits; 24 typed slots with 2-bit encoding."
- Change the clamp from `field.index < 32` (Types.elm:523) to `field.index < 24`.
- Use `encodeUnboxedKind` as in §3.2.

### 3.4 Rewrite `computeTupleLayout` (Types.elm:475-496)

- `elements : List (MonoType, Bool)` remains the input shape.
- Bitmap building:

```elm
bitmap =
    List.indexedFoldl
        (\i ( elemType, isUnboxed ) acc ->
            let
                kind =
                    if isUnboxed then
                        encodeUnboxedKind elemType

                    else
                        0
            in
            Bitwise.or acc (Bitwise.shiftLeftBy (2 * i) kind)
        )
        0
        elements
```

Valid tuple indices are 0/1/2 → 4 or 6 bits of header.unboxed, which fits in the new 6-bit Header.unboxed field.

### 3.5 Keep `isUnboxed` as a derived boolean

`FieldInfo.isUnboxed : Bool` (Types.elm:383-388) and the `(MonoType, Bool)` pair in `TupleLayout` remain — they still decide SSA types at projection (`i64`/`f64`/`i16` vs `!eco.value`). Only the *bitmap producer* changes.

`MonoInlineSimplify.elm` propagation at lines 876-881, 1214-1221, 1808-1813, 2258 needs no semantic change; it still carries `(name, expr, isUnboxed)` triples.

---

## §4 MLIR-gen propagation of bitmaps

All Elm-side code that *builds* an `unboxed_bitmap` / `head_unboxed` / `capture_unboxed` / `newargs_unboxed_bitmap` attribute must use the 2-bit encoding. The `isUnboxed : Bool` flag stays; bitmaps change.

Add a small shared helper alongside the existing builders in `Compiler/Generate/MLIR/Ops.elm`:

```elm
bitmapSetKind : Int -> Int -> Int -> Int
bitmapSetKind bitmap index kind =
    let
        shift =
            2 * index

        mask =
            Bitwise.shiftLeftBy shift 3
    in
    Bitwise.or
        (Bitwise.and bitmap (Bitwise.complement mask))
        (Bitwise.shiftLeftBy shift (Bitwise.and kind 3))
```

### 4.1 Ops.elm builders

**File**: `compiler/src/Compiler/Generate/MLIR/Ops.elm`.

- `ecoConstructList` at Ops.elm:201 — `head_unboxed` stays `BoolAttr` (no kind info encoded in this attribute; see §5.1). No change here beyond using the layout's boolean flag.
- `ecoConstructTuple2` at Ops.elm:219, `ecoConstructTuple3` at Ops.elm:237 — receive `unboxed_bitmap : Int` from the updated layout (§3.4).
- `ecoConstructRecord` at Ops.elm:267 — receives `unboxed_bitmap` from §3.2.
- `ecoConstructCustom` at Ops.elm:308 — receives `unboxed_bitmap` from §3.3.

No signature changes to these builders; only the integer values they receive change meaning.

### 4.2 Emitters in compiler passes

- `Compiler/Generate/MLIR/Expr.elm` — construction/projection at 415-417, 1023-1130, 3861-3895; capture emission at 4660, 4689, 4704, 4717, 4730, 4802, 4854, 4884-4937; `unboxed_bitmap` uses at 612, 1130, 1429, 1528, 1679, 1815, 3895.
- `Compiler/Generate/MLIR/Lambdas.elm:249` — closure capture bitmap.
- `Compiler/Generate/MLIR/Functions.elm:475-476, 545, 555-563, 737, 761` — capture attribute and function wrapping.
- `Compiler/Generate/MLIR/Patterns.elm:598, 653, 750` — projection dispatch using `isUnboxed`.
- `Compiler/Generate/MLIR/BytesFusion/Emit.elm:1287, 2076, 2150` — bytes fusion emission.

For each of the above, anywhere the current code does `bitmap .|. (2 ^ idx)` or `Bitwise.or bitmap (Bitwise.shiftLeftBy idx 1)`, substitute `bitmapSetKind bitmap idx (encodeUnboxedKind ty)` where `ty` is the field/capture MonoType (or `0` for already-boxed slots).

### 4.3 `MonoRecordAccess` index/isUnboxed

`compiler/src/Compiler/AST/Monomorphized.elm:527` — the annotation saying codegen computes index/isUnboxed at MLIR emission time stays accurate. Nothing to change here; projections still read `isUnboxed` and type to pick the right SSA type. The 2-bit bitmap only lives at the construction side and in the heap.

---

## §5 MLIR op definitions and verifiers

### 5.1 `Ops.td` docstring updates (only)

**File**: `runtime/src/codegen/Ops.td`. Keep attribute *types* unchanged; rewrite the docstrings to describe the 2-bit encoding and the 26-slot closure limit.

Docstring line ranges to rewrite:

- `eco.construct.list` at Ops.td:496-500, attribute at Ops.td:509 (`BoolAttr:$head_unboxed`).
- `eco.construct.tuple2` at Ops.td:562-567, attribute at Ops.td:576 (`I64Attr:$unboxed_bitmap`).
- `eco.construct.tuple3` at Ops.td:588-593, attribute at Ops.td:603.
- `eco.construct.record` at Ops.td:655-664, attribute at Ops.td:672.
- `eco.construct.custom` at Ops.td:713-728, attribute at Ops.td:738.
- `eco.papCreate` at Ops.td:916-933, attribute at Ops.td:945.
- `eco.papExtend` at Ops.td:981-1002, attribute at Ops.td:1011.

Every docstring must state: *"Each slot occupies 2 bits: `00` = boxed HPointer, `01` = Int, `10` = Float, `11` = Char. Slot i's kind lives at bits [2i, 2i+1]."*

For closure-bearing ops (`papCreate` / `papExtend`), also state: *"At most 26 captures may have non-boxed kind (52 bits / 2)."*

For `eco.construct.list`, `head_unboxed` remains a Bool; the primitive kind is recovered from the head SSA type at lowering time and stored into `Cons.header.unboxed` slot 0.

### 5.2 `ConstructCustom` verifier rewrite

**File**: `runtime/src/codegen/EcoOps.cpp:291-311`.

Replace the 1-bit per-field loop:

```cpp
for (int64_t i = 0; i < size; ++i) {
    const uint64_t shift = 2 * static_cast<uint64_t>(i);
    const uint64_t kind  = (unboxedBits >> shift) & 0x3ULL;
    auto fieldType = fields[i].getType();

    switch (kind) {
        case 0:
            if (!fieldType.isa<EcoValueType>())
                return op.emitOpError("field ") << i
                    << " has kind=boxed but non-boxed SSA type " << fieldType;
            break;
        case 1:
            if (!fieldType.isInteger(64))
                return op.emitOpError("field ") << i
                    << " has kind=Int but SSA type " << fieldType;
            break;
        case 2:
            if (!fieldType.isF64())
                return op.emitOpError("field ") << i
                    << " has kind=Float but SSA type " << fieldType;
            break;
        case 3:
            if (!fieldType.isInteger(16))
                return op.emitOpError("field ") << i
                    << " has kind=Char but SSA type " << fieldType;
            break;
    }
}
```

Also enforce `size <= 24` (Custom's 48-bit bitmap capacity under 2-bit encoding).

### 5.3 `PapCreate` / `PapExtend` verifier rewrites

**File**: `runtime/src/codegen/EcoOps.cpp:352-354, 404-405, 419-428`.

- Keep `bitmap < (1ULL << 52)` bound (bitmap width unchanged).
- Add `numCaptured <= 26` bound (typed-slot count).
- Per-operand type check becomes a four-way `kind` switch matching §5.2.
- Closure 6-bit `n_values` / arity checks at EcoOps.cpp:337-346 remain unchanged.

### 5.4 Pre-step (blocking)

Before landing verifier changes, grep the test corpus for any PAP or construct op whose bitmap implies more than 26 / 32 / 24 typed slots:

- Candidates to check explicitly: `pap_unboxed_captured.mlir`, `construct_max_unboxed.mlir`, `construct_max_fields.mlir`, `construct_many_unboxed.mlir`, `construct_large_unboxed_bitmap.mlir`, `papextend_exact_saturation.mlir`, `papextend_typed_saturation.mlir`, `papextend_saturated_float_result.mlir`.

For each case exceeding the new maximum, either accept demotion to boxed (per §0.3 overflow policy) or update the test inputs to stay within the new cap.

---

## §6 EcoToLLVM lowering

### 6.1 Closure `packed` word (no structural change)

**File**: `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:615-616`.

```cpp
uint64_t packedValue =
    static_cast<uint64_t>(numCaptured)
    | (static_cast<uint64_t>(arity) << 6)
    | (unboxedBitmap << 12);
```

Stays as-is. The *value* of `unboxedBitmap` is now 2-bit-encoded by the caller (Elm-side per §3–§4, or derived from `_capture_abi` at EcoToLLVMClosures.cpp:1318). No shift/width change here.

### 6.2 GC pointer-mask construction

**File**: `EcoToLLVMClosures.cpp:119-121, 976, 1172-1173, 1375-1376`.

These sites currently compute `~bitmap & countMask` assuming 1 bit per slot. Under 2-bit encoding that's wrong (an Int slot `01` would be interpreted as "pointer here, primitive there" when the `~` flips both bits).

Introduce a helper in the pass (in an appropriate TU-local anonymous namespace or `EcoToLLVMInternal.h`):

```cpp
// Derives a 1-bit-per-slot HPointer mask from a 2-bit-per-slot kind bitmap.
// Output bit i is set iff kind(i) == 0 (boxed).
static llvm::Value* emitPointerMaskFromKindBitmap(
    OpBuilder& b, Location loc, Value kindBitmap, unsigned numSlots);
```

At each of the four sites, replace `~newargsBitmap & countMask` with a call to `emitPointerMaskFromKindBitmap(..., numNewArgs)` and feed its result to `eco_gc_push_stack_range`.

The constant-folded path (when bitmap and slot count are known at compile time) can use the equivalent C++:

```cpp
uint64_t pointerMask = 0;
for (unsigned i = 0; i < numNewArgs; ++i) {
    if (((bitmap >> (2 * i)) & 0x3ULL) == 0) pointerMask |= (1ULL << i);
}
```

### 6.3 Runtime ABI calls

No API changes to:

- `eco_alloc_custom` (RuntimeExports.h:45) — still takes no bitmap.
- `eco_alloc_cons` (RuntimeExports.h:52) — still takes `head_unboxed : u32`; value is derived from the head SSA type and mapped into Cons slot 0 kind server-side (see §6.4).
- `eco_alloc_tuple2` (RuntimeExports.h:59), `eco_alloc_tuple3` (RuntimeExports.h:67), `eco_alloc_record` (RuntimeExports.h:74) — `unboxed_bitmap` keeps its type; value is now 2-bit-encoded.
- `eco_set_unboxed` (RuntimeExports.h:136) — same.
- `eco_pap_extend` (RuntimeExports.h:234) — same; but merge logic per §2.8.
- `eco_init_{cons,tuple2,tuple3,record,custom}_at` (RuntimeExports.h:183-187) — same.

**EcoToLLVM call sites** that assemble and pass these bitmaps:

- `EcoToLLVMHeap.cpp:225` (ctor alloc), 291 (cons), 461 (tuple2), 495 (tuple3), 621 (record), 739 (custom).
- `EcoToLLVMRuntime.cpp:117, 123, 129, 135, 317, 323, 329, 335, 341, 393, 403` — declarations.
- `RuntimeSymbols.cpp:34-232` — symbol table registration.

The `eco_set_unboxed` call at EcoToLLVMHeap.cpp:739 (per `pass_eco_to_llvm_theory.md:199`: `IF bitmap != 0: eco_set_unboxed(obj, bitmap)`) must now pass the 2-bit-encoded bitmap from the updated `computeCtorLayout`.

### 6.4 Cons head — `head_unboxed` Bool → slot-0 kind

Today `eco_alloc_cons` takes `head_unboxed : u32` (boolean). Inside the runtime, the allocator writes it into `cons->header.unboxed` as bit 0. Under 2-bit encoding, the runtime must convert from the boolean + head SSA type into the correct 2-bit kind at slot 0.

Two options; pick one and document it in the plan:

- **Option 1 (preferred)**: Extend the ABI: add a second parameter `head_kind : u32` to `eco_alloc_cons` (and `eco_init_cons_at`), and have the runtime store it directly. The Elm-side `ecoConstructList` builder emits `encodeUnboxedKind headType` as a new attribute; EcoToLLVM lowers it alongside `head_unboxed`.
- **Option 2 (minimal)**: Keep the boolean ABI, and at the call site in EcoToLLVM derive the kind from the head SSA operand type and fold it in before calling. This avoids an ABI break but requires an additional runtime helper `eco_alloc_cons_kind` or a post-alloc `eco_set_unboxed`.

Recommend Option 1: it's a clean, small ABI change (one integer param), mirrors the encoding everywhere else, and avoids a stealth codepath. The plan assumes Option 1 unless answered otherwise.

### 6.5 Closure ABI attribute `_capture_abi`

**File**: `EcoToLLVMClosures.cpp:1318` reads `_capture_abi` to fill `EvalParamLayout` kinds. `EcoToLLVM.cpp:254` pre-scans `origFuncTypes` from `func::FuncOp`; `EcoToLLVMClosures.cpp:323` reads them back for the wrapper.

No semantic change required here — `EvalParamLayout` is already 2-bit-per-slot. What changes is that the same 2-bit encoding is now mirrored in `cl->unboxed`, so the two must agree. Add an assertion in the wrapper builder that `kind(_capture_abi, i) == fieldKind(cl->unboxed, i)` for every captured slot.

---

## §7 Kernel C++ rewrites

Under 2-bit encoding every "is this slot unboxed?" site that previously read `.i` must instead decode kind and dispatch. This eliminates the "unboxed ⇒ Int" class of bugs.

### 7.1 `Utils.cpp` structural equality and compare

**File**: `elm-kernel-cpp/src/core/Utils.cpp` — equality / compare sites at 345, 361-362, 383-384, 400-401, 417-418, 441-442, 491-492, 525-526, 552-553.

For every pair `(A, B)` of container slots whose bitmap bit was previously compared:

```cpp
// Tuple2/Tuple3: header.unboxed
uint32_t kindA = tupleFieldKind(tupleA->header.unboxed, i);
uint32_t kindB = tupleFieldKind(tupleB->header.unboxed, i);

if (kindA == 0 && kindB == 0) {
    // recursive compare on HPointers
} else if (kindA != 0 && kindB != 0 && kindA == kindB) {
    switch (kindA) {
        case 1: /* compare .i as i64 */ break;
        case 2: /* compare .f as f64 (IEEE) */ break;
        case 3: /* compare .c as u16 */ break;
    }
} else {
    // Mixed or mismatched kind -> not equal (same rule as today's fallback).
}
```

Apply the analogous pattern to Record (`record->unboxed`), Custom (`custom->unboxed`), and ElmArray (uniform `header.unboxed & 0x3`).

### 7.2 List / JsArray kernels

**Files**:

- `elm-kernel-cpp/src/core/List.cpp:68, 117-119, 164-165, 214-216`
- `elm-kernel-cpp/src/core/ListExports.cpp:70, 124, 176, 218, 400, 427`
- `elm-kernel-cpp/src/core/JsArrayExports.cpp:97, 112, 134, 145, 169, 172, 205, 241, 278, 311, 341, 364`
- `elm-kernel-cpp/src/core/JsArray.cpp:71`
- `elm-kernel-cpp/src/core/ListOps.cpp` and `runtime/src/allocator/ListOps.cpp` per §2.3
- `elm-kernel-cpp/src/core/String.cpp:60` (`c->header.unboxed & 1` → `tupleFieldKind(..., 0) != 0`)
- `eco-kernel-cpp/src/eco/KernelHelpers.hpp:131` (`cell->header.unboxed == 0` → `tupleFieldKind(cell->header.unboxed, 0) == 0`)

Add a shared helper in a kernel header:

```cpp
inline HPointer boxElement(const Unboxable& v, uint32_t kind) {
    auto& alloc = Allocator::instance();
    switch (kind) {
        case 1: return alloc.wrap(alloc.allocInt(v.i));
        case 2: return alloc.wrap(alloc.allocFloat(v.f));
        case 3: return alloc.wrap(alloc.allocChar(v.c));
        default: return v.p; // already boxed
    }
}
```

Every site that currently re-boxes via `alloc.allocInt(val.i)` inside a "was unboxed?" branch must switch on `tupleFieldKind(...)` (Cons/List) or `header.unboxed & 0x3` (ElmArray) and call `boxElement(slot, kind)` instead.

This is the main behavioral fix for `List.toArray`, `List.mapN`, `List.sortBy/sortWith`, `JsArray.unsafeGet`, `JsArray.map`, `JsArray.indexedMap`, `JsArray.foldl`, `JsArray.foldr` on Float and Char lists/arrays.

### 7.3 File / Json / Bytes / String kernels

**File**: `elm-kernel-cpp/src/file/File.cpp:72, 86` — current `(rec->unboxed >> FIELD_SIZE) & 1`.

New: `fieldKind(rec->unboxed, FIELD_SIZE) != 0` (boxed vs unboxed) *and* read `.i` only after confirming `kind == 1`. Since these fields are statically typed `Int` (file size, modification time), a debug assertion can enforce `kind == 1`.

**File**: `elm-kernel-cpp/src/json/JsonExports.cpp` — 139, 155, 165, 198, 210, 223, 236, 249, 262, 275, 438-486, 1071-1170, 1252-1386. These are writes `.unboxed = 0/1` into Custom-like bitmaps; each must be rewritten to emit the correct 2-bit kind for the field being written (all are boxed → `0`, or specific primitive kinds).

**File**: `elm-kernel-cpp/src/bytes/BytesExports.cpp` — 41, 50, 59, 382-386, 606-679. Same treatment.

**File**: `elm-kernel-cpp/src/core/JsArrayExports.cpp` — 97, 112, 134, 145, 169, 172, 205, 241, 278, 311, 341, 364. All `header.unboxed` reads/writes must go through the uniform-kind accessor.

---

## §8 Debug printer and TypeInfo

**Files**: `runtime/src/allocator/TypeInfo.hpp:27-47, 85-91`; `runtime/src/allocator/RuntimeExports.cpp:1392-1409, 1944, 1987, 2055, 2061, 2114, 2124, 2142, 2152, 2162, 2216, 2219, 2290, 2314`.

### 8.1 EcoPrimKind ↔ 2-bit kind mapping

`EcoPrimKind` has five values (`Int`, `Float`, `Char`, `Bool`, `String`). The 2-bit bitmap only encodes four, and Bool/String are always boxed. Document explicitly:

```
bitmap kind == 0   ⇒ slot is boxed HPointer; EcoPrimKind (from the type graph) may be Bool, String, or any non-primitive Elm type.
bitmap kind == 1   ⇒ slot is unboxed Int; EcoPrimKind must be Int if present.
bitmap kind == 2   ⇒ slot is unboxed Float; EcoPrimKind must be Float.
bitmap kind == 3   ⇒ slot is unboxed Char; EcoPrimKind must be Char.
There is no encoding for unboxed Bool or unboxed String.
```

Update the doc block at TypeInfo.hpp:27-47 to reflect this.

### 8.2 Printer consumers

Debug printing continues to use the type graph (`EcoPrimKind`) to decide logical type, and uses the bitmap only to decide whether to deref a pointer or read `Unboxable` directly. Concretely:

- `printPrimitive(uint64_t bits, EcoPrimKind kind)` at RuntimeExports.cpp:1392 — unchanged.
- Container printers (lines 1944, 1987, 2055, 2114, 2124, 2142, 2152, 2162, 2219, 2314) — keep `EcoPrimKind` dispatch; only change the `unboxed & (1ULL << i)` tests at 2216 and 2290 to `fieldKind(..., i) != 0`.
- List-element unbox branch at RuntimeExports.cpp:2061 (`printPrimitive(head_val, EcoPrimKind::Int)`) — must now dispatch on the Cons slot-0 kind (`tupleFieldKind(cons->header.unboxed, 0)`) and pass the matching `EcoPrimKind`.

Optionally add an assertion that the bitmap kind agrees with `EcoPrimKind` from the type graph in debug builds. Not required for correctness; useful for catching cross-phase drift.

---

## §9 Tests and invariants

### 9.1 Compiler-side tests

**Files (from audit §9.2)**:

- `compiler/tests/TestLogic/Generate/CodeGen/UnboxedBitmap.elm` and `UnboxedBitmapTest.elm` (implement CGEN_026/027/003/049 checks).
- `CtorLayoutConsistency.elm:94, 128`.
- `ProjectionHeapLayoutConsistency.elm:17`.
- `BoxingValidation.elm`, `DestructorTypeProjection(Test).elm`, `Invariants.elm`, `MonoCtorLayoutIntegrity(Test).elm`, `ClosureCaptureBoolCases.elm`, `ClosureCases.elm`, `CaseCases.elm`, `CEcoValueLayout.elm`.

**Update strategy:** every expected `unboxed_bitmap` / `head_unboxed` / `newargs_unboxed_bitmap` integer constant is regenerated under the new encoding.

Example: a field list `[Int; Boxed; Float]` previously produced `0b101 = 5` (1-bit). It now produces `0b10_00_01 = 0x21` (2-bit).

### 9.2 MLIR golden files

**Directory**: `test/codegen/` (104 files, 536 occurrences).

**Regeneration strategy (selected)**: regenerate via the compiler itself, *not* a standalone parsing script.

1. Land the compiler and runtime changes that define the new encoding (§§1–6).
2. Run the compiler against the existing Elm test inputs that produce the goldens; capture the new `unboxed_bitmap` values.
3. A one-shot utility (Python or shell) replaces the old constants in the `.mlir` text files using op-name + field-type matching.
4. Re-run the test suite until stable.

Files that will definitely change include (partial list from audit §9.3): `construct_all_unboxed.mlir`, `construct_mixed_unboxed.mlir`, `construct_max_unboxed.mlir`, `construct_large_unboxed_bitmap.mlir`, `construct_many_unboxed.mlir`, `verify_constants_boxed.mlir`, `papextend_typed_saturation.mlir`, `papextend_exact_saturation.mlir`, `papextend_mixed_unboxed.mlir`, `papextend_chain.mlir`, `papextend_saturated_float_result.mlir`, `pap_simplify_chain_fusion.mlir`, `pap_simplify_multi_use_no_transform.mlir`, `pap_simplify_saturated_to_call.mlir`, `pap_unboxed_captured.mlir`, `project_unboxed_i32.mlir`, `project_unboxed_float.mlir`, `project_large_index.mlir`, `construct_list.mlir`, `unbox_bool.mlir`, `unbox_char.mlir`, `unbox_roundtrip.mlir`, `box_unbox_bool_roundtrip.mlir`, `box_unbox_nan_preservation.mlir`, `construct_alternating_types.mlir`, `construct_mixed_ordering.mlir`, `construct_max_fields.mlir`, `dbg_unboxed_types.mlir`, `integration_map.mlir`.

### 9.3 C++ tests

- `test/allocator/HeapGenerators.cpp:22-30` — `buildUnboxedBitmap` body is rewritten to fill 2-bit kinds; callers at 254/269/330/467/485/553 stay unchanged (their `max_bits` arguments 48/64/52 still express the bitmap width).
- `test/allocator/HeapHelpersTest.cpp` — uses of `arrayIsUnboxed` (438, 463, 489, 716, 785) and `closureCapture` (1272, 1307-1309) update mechanically via the new helper signature.
- `test/allocator/HeapSnapshot.hpp:172, 346` — `closure->unboxed & (1ULL << i)` becomes `fieldKind(closure->unboxed, i) != 0` or a full switch, depending on the assertion the test is making.
- Add a new C++ test that exercises the overflow policy from §0.3 for Record (>32 unboxable fields), Custom (>24), and Closure (>26).

### 9.4 Invariants

**File**: `design_docs/invariants.csv` (116 rows; affected ≥14).

Policy: **edit in place, keep the existing IDs.** IDs are referenced from tests and tooling; renumbering breaks cross-references.

Rows to rewrite:

- `REP_ABI_002` — no wording change expected; verify.
- `REP_HEAP_002` — "unboxed iff bit set" → "each slot has a 2-bit kind; boxed iff kind == 0; GC and debug rely exclusively on the bitmap (or HPointer constants)."
- `REP_BOUNDARY_001`, `REP_BOUNDARY_002` — projection/construction rules updated to reference kinds rather than bits.
- `REP_CLOSURE_001`, `REP_CLOSURE_002` — closure captures hold at most 26 typed slots; Bool always boxed at the closure boundary (kind 0).
- `MONO_006`, `MONO_013`, `MONO_014` — RecordLayout / CtorLayout / TupleLayout store a 2-bit-per-field unboxedBitmap.
- `CGEN_005`, `CGEN_006`, `CGEN_012` — projection/let/type-mapping rules restated in kind terms.
- `CGEN_020` — `eco.construct.custom` tag/size/unboxed_bitmap must match CtorLayout *under 2-bit encoding*.
- `CGEN_025`, `CGEN_026`, `CGEN_027` — `unboxed_bitmap` derived solely from SSA operand MLIR types *via `encodeUnboxedKind`*; `head_unboxed` now paired with a per-head kind (per §6.4 Option 1 if chosen).
- `CGEN_049` — PAP bitmap is 52 bits wide; supports 26 typed captures under 2-bit encoding.
- `CGEN_059` — generic `papExtend` boxes everything; wrapper unboxes via `origFuncTypes`. Wording largely unchanged; note kind encoding.
- `HEAP_019` — Cons / Tuple / Record / Custom / ElmArray carry a 2-bit-per-slot unboxed bitmap; GC and debug rely on it.
- `XPHASE_001` — cross-phase requirement: Elm layouts, MLIR attrs, and Heap.hpp structs all agree on 2-bit encoding.
- `FORBID_REP_001`, `FORBID_REP_002` — no phase may assume unbox/box without consulting the bitmap kind.

Add an "(Updated 2026-04-20: bitmap now encodes 2-bit primitive kinds; 00 boxed, 01 Int, 10 Float, 11 Char)" footnote to each rewritten row.

### 9.5 Theory docs and memories

- `design_docs/theory/heap_representation_theory.md:145, 260, 334` — struct layouts.
- `design_docs/theory/pass_eco_to_llvm_theory.md:161, 171, 178, 182, 189, 197, 199, 227, 550-551, 631-634` — alloc-API expectations and `packed` layout.
- `design_docs/theory/typed_closure_calling_theory.md` — closure ABI.
- `old_design_docs/eco-lowering.md:24, 27` — review whether to delete outright or annotate.
- `THEORY.md` — references to `origFuncTypes` / `buildEvaluatorArgs` / `loadCapturedValues` stay; header/bitmap semantics get updated.
- Serena memories `ecotollvm_closure_lowering.md`, `ecotollvm_closure_quick_reference.md`, `runtime_codegen_efficiency_issues.md` — update as a **final step in the same PR**, with a "Representation change (2026-04-20)" section.

---

## §10 Rollout order

**Step 0 — Pre-flight capacity check (blocking).**

Before touching code, audit:

- Every PAP in test corpus for capture count > 26.
- Every Record in test corpus for unboxed-field count > 32.
- Every Custom in test corpus for field-index > 24 (the current Types.elm clamp is at 32, so some existing constructs may sit between 24 and 32 and get demoted).

Record findings in a comment at the top of this plan. If any real workload breaches the new ceilings, revisit §0.3 overflow policy before proceeding.

**Step 1 — Heap layout & shared helpers (C++).**

- Edit `Heap.hpp` Header per §1.1.
- Add `fieldKind`, `tupleFieldKind`, `bitmapSetKind` helpers per §1.3.
- Update `heap_representation_theory.md` and `THEORY.md` header snippets.

**Step 2 — GC and allocator.**

- Rewrite every 1-bit test per §2.1–§2.4.
- Update inline tuple-mask widths (§2.5).
- Update `arrayIsUnboxed` (§2.6), `closureCapture` signature + body + all call sites (§2.7).
- Rewrite `eco_pap_extend` merge / mask (§2.8).

**Step 3 — Compiler layout computation.**

- Add `encodeUnboxedKind` and rewrite `computeRecordLayout`, `computeCtorLayout`, `computeTupleLayout` per §3.
- Update `Ops.elm` builders (same signatures; values change).
- Update all MLIR-gen emitters in `Expr.elm`, `Lambdas.elm`, `Functions.elm`, `Patterns.elm`, `BytesFusion/Emit.elm` per §4.

**Step 4 — MLIR op docstrings and verifiers.**

- Rewrite `Ops.td` docstrings per §5.1 (no attribute-type changes).
- Rewrite `EcoOps.cpp` `ConstructCustom` / `PapCreate` / `PapExtend` verifiers per §5.2–§5.3.

**Step 5 — EcoToLLVM lowering.**

- `emitPointerMaskFromKindBitmap` helper and four call-site rewrites (§6.2).
- Choose and implement Cons `head_kind` ABI option per §6.4.
- Add cross-check assertion between `_capture_abi` and `cl->unboxed` (§6.5).

**Step 6 — Kernel C++.**

- Rewrite `Utils.cpp` equality/compare (§7.1).
- Introduce `boxElement` helper; rewrite List / JsArray / String kernels (§7.2).
- Rewrite `File.cpp`, `JsonExports.cpp`, `BytesExports.cpp`, `JsArrayExports.cpp` sites (§7.3).

**Step 7 — Debug printer.**

- Update `TypeInfo.hpp` doc block; update RuntimeExports.cpp printer test sites per §8.

**Step 8 — Tests.**

- Rewrite compiler TestLogic bitmap constants (§9.1).
- Regenerate MLIR goldens via the compiler + one-shot constant replacement (§9.2).
- Rewrite C++ allocator tests (§9.3), add overflow-policy tests.

**Step 9 — Invariants and docs.**

- Edit `invariants.csv` rows in place (§9.4).
- Update theory docs (§9.5).
- Update Serena memories (§9.5).

**Step 10 — Full E2E run.**

`cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`. Iterate on failures strictly within the patterns above; do not reintroduce 1-bit assumptions.

---

## §11 Impact-surface index (appendix)

Preserved from the original audit for quick lookup. Every entry here is covered by one of the steps above; this section is informational.

### 11.1 Struct bit widths to re-size or re-interpret (6 fields)

`Heap.hpp`:
- `Header.unboxed : 3` → `:6` (the one actual width change).
- `Custom.unboxed : 48` — width unchanged, semantics change.
- `Record.unboxed : 64` — width unchanged, semantics change.
- `DynRecord.unboxed : 64` — width unchanged, semantics change.
- `Closure.unboxed : 52` — width unchanged, semantics change.
- Header `epoch` / `padding` removal may force a Forward/padding reshuffle; verify `sizeof(Header) == 8`.

### 11.2 Capacity constants

- `(1ULL << 52)` at `EcoOps.cpp:352, 404` — unchanged (width guard).
- Add `<= 26` `numCaptured` guard (typed-slot count).
- Types.elm:523 clamp `field.index < 32` → `< 24`.
- `buildUnboxedBitmap` callers at HeapGenerators.cpp:254/269/330/467/485/553 — unchanged signatures.
- `cl->unboxed |= (1ULL << idx)` at HeapHelpers.hpp:1010 — replaced by `bitmapSetKind`.

### 11.3 Bit-twiddling sites assuming 1 bit per slot

- **Tuple header:** `NurserySpace.cpp` 588, 594-602, 943-951, 996, 1016, 1135, 1224; `OldGenSpace.cpp` 460-468, 1122-1130, 1135; `RuntimeExports.cpp` 1599-1639; `HeapHelpers.hpp:603, 628`.
- **Cons head:** `ListOps.{hpp,cpp}`, `NurserySpace.cpp`, `OldGenSpace.cpp`, `RuntimeExports.cpp`, kernels `List.cpp`, `ListExports.cpp`, `JsArray.cpp`, `String.cpp`, `Utils.cpp`, `eco-kernel-cpp/src/eco/KernelHelpers.hpp:131`.
- **Custom / Record / Closure:** `NurserySpace.cpp` 608, 616, 624, 957, 964, 979; `OldGenSpace.cpp` 480, 487, 502, 1142, 1149, 1164; `RuntimeExports.cpp` 1549, 1663, 1701, 2216, 2290; kernels `JsonExports.cpp`, `BytesExports.cpp`, `File.cpp`, `Utils.cpp`, `JsArrayExports.cpp`.
- **Closure `packed` pack:** `EcoToLLVMClosures.cpp:616` (single authoritative write); `Heap.hpp:243-245` struct overlay.
- **GC-mask construction:** `EcoToLLVMClosures.cpp:119-121, 976, 1172-1173, 1375-1376`; `RuntimeExports.cpp:1193-1197` (`hptr_mask_clamp(~new_unboxed_bitmap, ...)`); `RuntimeExports.cpp:1221-1223` (bitmap merge).
- **PAP-extend bitmap merge:** `RuntimeExports.cpp:1165-1234`.

### 11.4 MLIR attribute layer

- `Ops.td` (7 attribute docstring sites — types unchanged).
- `EcoOps.cpp` verifiers (2 rewrites: ConstructCustom, PapCreate/PapExtend).
- `Ops.elm` builders (values change, signatures unchanged).
- Emitters in `Expr.elm`, `Lambdas.elm`, `Functions.elm`, `Patterns.elm`, `BytesFusion/Emit.elm`, `Types.elm`.

### 11.5 Test and doc surfaces

- `test/` directory: 104 files / 536 occurrences.
- `compiler/tests/TestLogic/`: 29 files / 215 occurrences.
- `design_docs/invariants.csv`: ≥14 rows to rewrite in place.
- `design_docs/theory/*`, `THEORY.md`, `TypeInfo.hpp` doc block.
- Serena memories: 3 files to refresh in the same PR.

### 11.6 Already-present 2-bit infrastructure to reuse

- `enum ParamKind { PK_Boxed=0, PK_Int=1, PK_Float=2, PK_Char=3 }` — `Heap.hpp:252-257`.
- `EvalParamLayout` — `Heap.hpp:262-265`.
- `mlirTypeToParamKind` — `EcoToLLVMClosures.cpp:854`.
