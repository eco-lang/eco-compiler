/**
 * Heap Object Definitions for Elm Runtime.
 *
 * This file defines all heap-allocated value types for the Elm runtime.
 * Every object begins with a 64-bit Header containing type tag, GC color,
 * age, and size information.
 *
 * Memory layout:
 *   - All objects are 8-byte aligned.
 *   - Pointers (HPointer) are 40-bit logical offsets, allowing 8TB heap.
 *   - Common constants (Nil, True, False, etc.) are embedded in pointers.
 *   - Primitive values can be unboxed directly into container fields.
 *
 * Object types:
 *   - ElmInt, ElmFloat, ElmChar: Boxed primitives.
 *   - ElmString: Variable-length UTF-16 string.
 *   - Tuple2, Tuple3: Fixed-size tuples with unboxing support.
 *   - Cons: List cons cell with unboxable head.
 *   - Custom: Algebraic data type variants.
 *   - Record, DynRecord: Fixed and dynamic records.
 *   - Closure: Function closure with captured values.
 *   - Process, Task: Concurrency primitives.
 *   - Forward: Forwarding pointer for GC compaction.
 */

#ifndef ECO_HEAP_H
#define ECO_HEAP_H

#include <assert.h>
#include <stddef.h>
#include <bit>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace Elm {

// ============================================================================
// Primitive Type Aliases
// ============================================================================

typedef unsigned long long int u64;  // 64-bit unsigned integer.
typedef unsigned int u32;            // 32-bit unsigned integer.
typedef unsigned char u8;            // 8-bit unsigned byte.
typedef unsigned short u16;          // 16-bit unsigned integer.
typedef long long int i64;           // 64-bit signed integer.
typedef double f64;                  // 64-bit floating point.

// ============================================================================
// Header and Pointer Layout
// ============================================================================

/**
 * Headers are always 64-bits in size, and every heap element always has a
 * header at its start. The first 5-bits contain a tag, denoting which kind of
 * heap element it is.
 *
 * Pointers are 40 bits, allowing > 8 terabytes address space. This allows for
 * a pointer to be fitted into a 64-bit word with space for other bit annotations
 * against pointers that may be used for garbage collection or other optimizations,
 * such as commonly used constants.
 */

// Bit widths for header and pointer fields.
#define TAG_BITS 5
#define CTOR_BITS 16
#define POINTER_BITS 40
#define ID_BITS 16  // Process and Task ID field

// Upper bound (exclusive) on any raw heap address. The HPointer `ptr` field is
// POINTER_BITS wide and sits at bit offset 3 (above the 3-bit constant/ptr_ind
// low field), so a raw 8-byte-aligned heap address occupies bits
// [0, POINTER_BITS+3). The whole heap must be reserved below this limit (8 TB)
// so an address round-trips through an HPointer word without loss. See D1/D7.
#define HPOINTER_ADDRESS_LIMIT (1ULL << (POINTER_BITS + 3))

typedef enum {
    Tag_Int,
    Tag_Float,
    Tag_Char,
    Tag_String,
    Tag_Tuple2,
    Tag_Tuple3,
    Tag_Cons,
    Tag_Custom,
    Tag_Record,
    Tag_DynRecord,
    Tag_FieldGroup,
    Tag_Closure,
    Tag_Process,
    Tag_Task,
    Tag_ByteBuffer,  // Immutable byte array for binary data.
    Tag_Array,       // Mutable/growable array of Elm values.
    // Tag_Tensor - Tensors (future).
    Tag_StringRope,  // Concat tree node: HPointer left, HPointer right, height, leafCount.
    Tag_StringSlice, // Structural view: HPointer base + offset + length over a String leaf.
    Tag_ByteBufferSlice, // Structural view: HPointer base + offset over a Tag_ByteBuffer / Tag_LargeByteHeader.
    // Split-header forms for large strings / byte buffers. The header (these
    // tags) lives in the nursery, while the body (Tag_String / Tag_ByteBuffer)
    // lives in old gen and is never copied. See HEAP_026 and
    // plans/large-object-split-header-bodies.md.
    Tag_LargeStringHeader, // header.size = logical UTF-16 length, body -> Tag_String.
    Tag_LargeByteHeader,   // header.size = logical byte count,    body -> Tag_ByteBuffer.
    // UTF-8 (all-ASCII) String forms. header.size = logical UTF-16 unit count
    // (== byte count under the ASCII invariant). Produced only by runtime
    // String ops / Bytes.Decode.string / kernel string ingestion
    // (alloc::allocStringFromUTF8: File.readString, Console, Env, Http, ports) /
    // interned literals; never by MLIR codegen. Kept BEFORE Tag_Free/Tag_Forward
    // so every live object stays `< Tag_Forward` (Allocator.cpp resolution
    // assert) and "Forward is last" holds. See
    // plans/utf8-string-pipeline-wiring.md, HEAP_032.
    Tag_StringUtf8View,  // Zero-copy byte view: HPointer base + u32 offset + u32 byteLen.
    Tag_StringUtf8Leaf,  // Inline ASCII bytes: header.size = byte count, u8 bytes[].
    // Chunked-list forms (plans/chunked-list-representation.md §2.2/§6 hybrid
    // spines). A list spine may freely MIX classic Cons cells and chunk view
    // nodes; walkers, GC, eq/compare/toString handle both. v1 chunks are
    // built whole (builder-bit rooted during construction) and IMMUTABLE
    // once observable: hd == 0 always, no front-slack fill (§10 deferred).
    // Kept BEFORE Tag_Free/Tag_Forward ("Forward is last" holds).
    Tag_ConsChunk,   // Chunk view: HPointer backing, u32 offset, u32 len, HPointer next.
    Tag_ListBacking, // Dense element array: header.size = capacity (elem count),
                     // u32 hd (frontmost claimed; v1 always 0), Unboxable elems[].
                     // Header.unboxed bits 1:0 = uniform element kind.
    Tag_Free,        // Free cell on a segregated free list (header.size = byte size).
    Tag_Forward,     // Used for forwarding pointers during GC.
} Tag;

// Heap header that every heap object must have.
//
// The `unboxed` bitfield holds 2 bits per slot: 00=boxed HPointer, 01=Int (i64),
// 10=Float (f64), 11=Char (u16). Cons uses 1 slot (bits 1:0), Tuple2 uses 2
// slots (bits 3:0), Tuple3 uses 3 slots (bits 5:0), ElmArray uses 1 uniform
// kind (bits 1:0).
//
// `age` semantics depend on `tag`:
//   - For non-`Tag_Free` tags: nursery promotion counter (0..3 minor cycles).
//   - For `Tag_Free` in old gen:
//       * `age & 0b01 == 1`  → "already on a free list" sentinel; the lazy
//         sweep coalescer must NOT merge across this cell, NOT rewrite its
//         header, and NOT touch its free-list link.
//       * `age & 0b01 == 0`  → coalescable free cell (default).
//       * `age & 0b10`       → reserved for future use; must remain 0 in
//         `Tag_Free` cells. Legal `age` values for `Tag_Free` are exactly
//         `0` (coalescable) and `1` (sentinel).
//
// `builder` semantics:
//   - When `builder == 1`, the object is a "builder" currently being mutated
//     by runtime code (e.g. ElmArray under incremental construction). The bit
//     pins the object to the nursery while construction runs, so children
//     written into it during the loop cannot become old-gen→young pointers.
//   - Builder objects:
//       * Must live in the nursery; it is a GC invariant (HEAP_BUILDER_001)
//         that no builder object ever appears in old gen.
//       * Are fully traced as roots/children during minor GC, but are never
//         promoted and never aged while `builder == 1`. The invariant
//         `builder ⇒ age == 0` (HEAP_BUILDER_002) holds at every GC-visible
//         point and is asserted under ECO_HEAP_VALIDATE.
//       * Are expected to be short-lived. Runtime kernels must clear the
//         flag (HEAP_BUILDER_003) once construction is complete, before the
//         object becomes reachable to user Elm code.
//   - `builder` and `pin` are orthogonal: `pin` forbids relocation, `builder`
//     forbids promotion. The canonical promotion predicate is
//       `!pin && !builder && age >= promotion_age`.
typedef struct {
    u32 tag : TAG_BITS;
    u32 color : 2; // White, Grey, or Black for tri-color mark-and-sweep.
    u32 pin : 1; // Memory-pinned object (prevents relocation).
    u32 age : 2; // Nursery promotion counter; doubles as on-free-list
                 // sentinel for Tag_Free cells (see above).
    u32 unboxed : 6; // 2 bits per slot; used by Cons/Tuple2/Tuple3/ElmArray.
    u32 refcount : 15; // Reference count (unused currently).
    u32 builder : 1; // Builder flag: object is under construction; pinned
                     // to nursery (no aging, no promotion) while set.
    u32 size; // Object size in type-specific units.
} Header;
static_assert(sizeof(Header) == 8, "Header must be 64 bits");

// Frequently used constants in Elm can be embedded directly into HPointer.
// There is no need to trace a pointer to reach them. The `constant` field is a
// 2-bit code, meaningful only when `ptr_ind == 1`:
//   bit 0 = Bool value (0 = False, 1 = True) — matches the SSA/ABI i1 value.
//   bit 1 = Empty flag — the single unified nullary/empty constant, shared by
//           Unit, EmptyRec, Nil, Nothing, and "" (the type checker guarantees a
//           merged empty is only produced/matched where its type is expected).
// See plan D3. The old distinct Unit/EmptyRec/Nil/Nothing/EmptyString constants
// collapse into Const_Empty.
typedef enum {
    Const_False = 0, // bit 0 clear
    Const_True  = 1, // bit 0 set
    Const_Empty = 2, // bit 1 set — unifies Unit / EmptyRec / Nil / Nothing / ""
    Const_NullCons = 3, // nullary ctor; tag in null_cons_idx (bits [43,53)).
                        // See plans/null-cons-hpointer-embedding.md (HEAP_044).
} Constant;

// A pointer into the heap, or an embedded constant. Layout (LSB first):
//   [0-1]   constant : 2   — see Constant above (valid only when ptr_ind == 1)
//   [2]     ptr_ind  : 1   — 0 = heap pointer, 1 = not a pointer (constant/enum)
//   [3-42]  ptr      : 40  — absolute, 8-byte-aligned heap address. Because the
//                            field starts at bit 3, the low 43 bits of the word
//                            ARE the raw address (its low 3 bits are 0 and land
//                            in constant/ptr_ind): no heap_base, no shift. Plan D1.
//   [43-52] null_cons_idx : 10 — the zero-based declaration index of a nullary
//                            constructor when constant == Const_NullCons
//                            (HEAP_044); 0 for every other word (pointers and
//                            the legacy False/True/Empty constants).
//   [53-63] padding  : 11  — reserved, always 0.
typedef struct {
    u64 constant : 2;
    u64 ptr_ind  : 1;
    u64 ptr      : POINTER_BITS;
    u64 null_cons_idx : 10;
    u64 padding  : 11;
} HPointer;
static_assert(sizeof(HPointer) == 8, "HPointer must be 64 bits");

// Golden-word checks (plan D6): the bitfield packing must produce the canonical
// constant/pointer words (False 0x4, True 0x5, Empty 0x6, null 0x0, and a heap
// pointer's word == its address). These cannot be static_asserts because
// std::bit_cast of a bit-field struct is not a constant expression (bit-field
// layout is implementation-defined); they are validated at runtime by
// HPointerLayoutTest, which catches any ABI/compiler bitfield-layout surprise.

// Bit position of the pointer/non-pointer discriminator within the 64-bit word.
// Equals CONST_BITS (2) + 0; the ptr field begins at PTR_IND_BIT + 1 = bit 3.
#define PTR_IND_BIT 2

// Opaque 64-bit HPointer representation for C-linkage boundaries.
// On the LLVM side this is declared as ptr addrspace(1); on x86-64 SysV ABI
// a single-member struct and a pointer are both passed/returned in a register,
// so the calling convention matches. Internal code converts to/from HPointer
// via memcpy (same as before with uint64_t).
struct HPtr {
    u64 bits;
    static HPtr fromBits(u64 b) { return HPtr{b}; }
    u64 toBits() const { return bits; }
    static HPtr fromHPointer(HPointer hp) { HPtr h; memcpy(&h.bits, &hp, 8); return h; }
    HPointer toHPointer() const { HPointer hp; memcpy(&hp, &bits, 8); return hp; }
};
static_assert(sizeof(HPtr) == 8, "HPtr must be 64 bits");

// A pointer or unboxed primitive.
// Used in structures with an unboxed bitmap that indicates which fields are pointers vs primitives.
typedef union {
    HPointer p;
    i64 i;
    f64 f;
    u16 c;
} Unboxable;
static_assert(sizeof(Unboxable) == 8, "Unboxable must be 64 bits");

// ============================================================================
// 2-Bit Unboxed Bitmap Accessors
// ============================================================================
//
// Every container bitmap (Cons/Tuple header.unboxed, Custom.unboxed,
// Record.unboxed, DynRecord.unboxed, Closure.unboxed, ElmArray header.unboxed)
// encodes 2 bits per slot:
//   00 = boxed HPointer (`.p`)
//   01 = unboxed Int i64 (`.i`)
//   10 = unboxed Float f64 (`.f`)
//   11 = unboxed Char u16 (`.c`)
//
// Slot i's kind lives at bits [2i, 2i+1]. Bool and String are always boxed.

inline u64 fieldKind(u64 bitmap, unsigned index) {
    assert(index < 32 && "fieldKind: index past one 64-bit kind word (use the slot-kind accessors)");
    return (bitmap >> (2 * index)) & 0x3ULL;
}

inline u32 tupleFieldKind(u32 headerUnboxed, unsigned index) {
    assert(index < 3 && "tupleFieldKind: header.unboxed holds 3 slots");
    return (headerUnboxed >> (2 * index)) & 0x3U;
}

inline u64 bitmapSetKind(u64 bitmap, unsigned index, u64 kind) {
    assert(index < 32 && "bitmapSetKind: index past one 64-bit kind word");
    const u64 shift = 2ULL * index;
    const u64 mask  = 0x3ULL << shift;
    return (bitmap & ~mask) | ((kind & 0x3ULL) << shift);
}

// Derives a 1-bit-per-slot HPointer mask from a 2-bit-per-slot kind bitmap.
// Output bit i is set iff the kind at slot i is 0 (boxed).
inline u64 pointerMaskFromKindBitmap(u64 kindBitmap, unsigned numSlots) {
    // One kind word describes slots 0..31; slots 32..63 have no kind here and read as boxed
    // (D semantics). The mask itself is 64 bits wide; wider buffers use pushRootsByKinds.
    assert(numSlots <= 64 && "pointerMaskFromKindBitmap: mask covers 64 slots; use pushRootsByKinds");
    u64 mask = 0;
    for (unsigned i = 0; i < numSlots; ++i)
        if (i >= 32 || fieldKind(kindBitmap, i) == 0) mask |= (1ULL << i);
    return mask;
}

// ---- Wide-object slot kinds (plans/wide-object-tail-kind-words.md §S.1; Phase 1 bodies) ----
// The accessors that dereference Custom/Record/Closure follow the Closure typedef below.
constexpr u32 CUSTOM_HDR_SLOTS   = 24;    // Custom::unboxed:48
constexpr u32 RECORD_HDR_SLOTS   = 32;    // Record::unboxed:64
constexpr u32 CLOSURE_HDR_SLOTS  = 20;    // Closure::unboxed:40 (Phase 2)
constexpr u32 SLOTS_PER_EXT_WORD = 32;
constexpr u32 CUSTOM_MAX_FIELDS  = 2040;
constexpr u32 RECORD_MAX_FIELDS  = 2047;
constexpr u32 CLOSURE_MAX_ARITY  = 2047;  // n_values:11 / max_values:11 (HEAP_078)
// Sat fast path serves only closures whose kinds are all inline; the guard (EcoBackend.cpp)
// and the descriptor emitters must use this one constant. sat[] is empty above it.
constexpr u32 SAT_MAX_ARITY      = CLOSURE_HDR_SLOTS;
static_assert(SAT_MAX_ARITY <= CLOSURE_HDR_SLOTS, "c3 reads kinds from the header word only");

constexpr u32 extWords(u32 n, u32 hdrSlots) {
    return n > hdrSlots ? (n - hdrSlots + SLOTS_PER_EXT_WORD - 1) / SLOTS_PER_EXT_WORD : 0;
}
// Kind of slot i (< 32) within one 64-bit kind word. The ONLY shift on kind words.
inline u32 kindInWord(u64 word, u32 i) {
    assert(i < 32);
    return static_cast<u32>(word >> (2 * i)) & 3u;
}

// ============================================================================
// Centralized low-level HPointer bit access (see plan D1/D2/D8)
// ============================================================================
//
// Single source of truth for turning an HPointer into a 64-bit word, resolving
// a heap pointer to its raw address, classifying it as a constant vs a heap
// pointer, and encoding/decoding forwarding pointers. The representation is
// defined by these bodies plus the HPointer struct above.
//
// New layout (plan D1/D3/D6/D8): `ptr` is a raw absolute 8-byte-aligned address
// occupying bits [3, 43); `ptr_ind` (bit 2) discriminates pointer (0) vs
// constant/enum (1); `constant` (bits 0-1) is False=0 / True=1 / Empty=2.
// Golden words: null = 0x0, False = 0x4, True = 0x5, Empty = 0x6, and a heap
// pointer's word IS its address.

// Bit-preserving reinterpretation between an HPointer and its 64-bit word.
inline u64 hpBits(HPointer hp) {
    u64 b;
    std::memcpy(&b, &hp, sizeof(b));
    return b;
}
inline HPointer hpFromBits(u64 b) {
    HPointer hp;
    std::memcpy(&hp, &b, sizeof(hp));
    return hp;
}

// Resolve a heap-pointer HPointer to its raw absolute address. The low
// POINTER_BITS+3 (= 43) bits of the word are the 8-byte-aligned address itself
// (constant/ptr_ind are 0 for a pointer, and encode zeroes null_cons_idx/padding).
// No heap_base, no shift. Only valid when the HPointer is a pointer (ptr_ind==0).
inline void* hpToAddr(HPointer hp) {
    return reinterpret_cast<void*>(hpBits(hp) & ((1ULL << (POINTER_BITS + 3)) - 1));
}

// "Is this word an embedded constant rather than a heap pointer?" Discriminated
// by ptr_ind (bit 2), since a False constant has constant field 0 just like a
// heap pointer.
inline bool isConstantBits(u64 b) { return hpFromBits(b).ptr_ind != 0; }

// "Is this word the unified empty constant (not Bool)?" i.e. ptr_ind set and the
// empty bit (bit 1 of the constant field) set.
inline bool isEmptyBits(u64 b) {
    HPointer hp = hpFromBits(b);
    return hp.ptr_ind != 0 && hp.constant == Const_Empty;
}

// For a Bool-constant word, the i1 value (0 = False, 1 = True) — bit 0 of the
// constant field. Only meaningful when the word is a Bool constant
// (isConstantBits && !isEmptyBits && !isNullConsBits).
inline u64 boolValueBits(u64 b) {
    return hpFromBits(b).constant & 1u;
}

// Null-cons embedding (plans/null-cons-hpointer-embedding.md, HEAP_044): a
// nullary constructor value is the embedded word (idx << 43) | 0b111 —
// ptr_ind set, constant == Const_NullCons, and the ctor's zero-based
// declaration index in null_cons_idx. Single representation: after P4 no
// live heap Tag_Custom with 0 fields exists.
#define NULL_CONS_SHIFT 43
#define NULL_CONS_MAX   1023          // 10 bits; the full range is usable

// Is this word an embedded nullary-constructor constant?
inline bool isNullConsBits(u64 b) {
    HPointer hp = hpFromBits(b);
    return hp.ptr_ind != 0 && hp.constant == Const_NullCons;
}

// The ctor's zero-based declaration index, verbatim.
// Only valid when isNullConsBits(b).
inline u32 nullConsTagBits(u64 b) {
    return static_cast<u32>(hpFromBits(b).null_cons_idx);
}

// Compose the word for a ctor's declaration index. Callers guarantee
// idx <= NULL_CONS_MAX (the compiler crashes past capacity at emission).
inline u64 nullConsWordFor(u32 idx) {
    return (static_cast<u64>(idx) << NULL_CONS_SHIFT)
         | (1ULL << PTR_IND_BIT) | Const_NullCons;                  // …0b111
}

// Reserved constructor tag for embedded "empty" constants (Nil / Nothing / Unit /
// EmptyRec / EmptyString), which under the merged representation share one bit
// pattern and can no longer be told apart by constant value. The reserved set
// is {0xFFFF RBNode, 0xFFFD CONSTANT_TAG} — RBEmpty reverted to its plain
// declaration index 1 when it became an embedded null-cons constant
// (HEAP_044, plans/null-cons-hpointer-embedding.md P3.0). The compiler emits
// this tag for embedded-constant constructor branches; the runtime derives it
// in eco_get_tag and the eco.case lowering. Must stay in sync with
// `Compiler.Data.CtorTag.constantTag` and `value_enc::ConstantTag`. See plan D9.
#define CONSTANT_TAG 0xFFFD

// Forwarding-pointer field (POINTER_BITS wide) <-> physical address. Unlike the
// HPointer `ptr` field, the Forward header's `forward_ptr` cannot start at bit 3
// (bits 0-4 hold the Tag_Forward tag), so it stores the absolute address in
// 8-byte units (addr >> 3) and decodes with addr = forward_ptr << 3 — the ÷8
// unit stays, only the heap_base term is dropped (plan D8). The `heap_base`
// parameter is retained for call-site stability and is unused.
inline u64 encodeForwardPtr(void* newObj, char* /*heap_base*/) {
    return static_cast<u64>(reinterpret_cast<uintptr_t>(newObj)) >> 3;
}
inline char* decodeForwardPtr(u64 forwardPtr, char* /*heap_base*/) {
    return reinterpret_cast<char*>(static_cast<uintptr_t>(forwardPtr) << 3);
}

// ============================================================================
// Elm Value Types
// ============================================================================

// Boxed 64-bit floating point value.
typedef struct {
    Header header;
    f64 value;
} ElmFloat;

// Boxed 64-bit signed integer value.
typedef struct {
    Header header;
    i64 value;
} ElmInt;

// Boxed Unicode character (UTF-16 code unit).
typedef struct {
    Header header;
    u16 value;
    u16 padding1;  // Padding to maintain 8-byte alignment.
    u16 padding2;
    u16 padding3;
} ElmChar;

// Note: Empty strings use Const_EmptyString constant instead of heap allocation.
// This prevents the issue where an 8-byte empty string would be overwritten by
// a 16-byte forward pointer, corrupting adjacent heap objects.

// Ensure strings are 8-byte aligned on 64-bit targets.
// Without explicit alignment, the compiler might truncate trailing padding.
#define ALIGN(X) __attribute__((aligned(X)))
struct ALIGN(8) elm_string {
    Header header; // header.size = logical UTF-16 length, up to 4G characters.
    u16 chars[];
};
typedef struct elm_string ElmString;

// Structural view over a String leaf: header.size = logical UTF-16 length;
// `base` points to a Tag_String leaf (rope/leaf-of-leaf indirection collapsed
// at construction). `offset` is the starting index in `base->chars[]`.
//
// header.unboxed is always 0 for slices: the only non-Header field is the
// fully-boxed `base` HPointer; `offset` and `_padding` are scalars and never
// read by GC. `_padding` is reserved for future flags (e.g. all-ASCII bit).
struct ALIGN(8) elm_string_slice {
    Header header;
    HPointer base;
    u32 offset;
    u32 _padding;
};
typedef struct elm_string_slice ElmStringSlice;

// Concat-tree node: header.size = total logical UTF-16 length;
// `left` and `right` are fully-boxed HPointers to either leaves, slices, or
// other ropes. `height` and `leafCount` are scalars used by the rebalance
// heuristics. header.unboxed is always 0 (no per-slot bitmap consulted).
struct ALIGN(8) elm_string_rope {
    Header header;
    HPointer left;
    HPointer right;
    u32 height;     // 1 + max(leftHeight, rightHeight); pure leaves have height 0.
    u32 leafCount;  // sum of left + right leaf counts.
};
typedef struct elm_string_rope ElmStringRope;

// Split-header for large strings: a small fixed-size object that lives in the
// nursery and points to a Tag_String body in old gen. header.size is the
// logical UTF-16 length (matches the body's own header.size). The body is
// never copied; minor GC reads `body` only to mark the body as still-live.
// See plans/large-object-split-header-bodies.md.
struct ALIGN(8) elm_large_string_header {
    Header header;     // tag = Tag_LargeStringHeader; header.size = logical UTF-16 length.
    HPointer body;     // -> Tag_String body in old gen.
};
typedef struct elm_large_string_header LargeStringHeader;

// Split-header for large byte buffers; mirrors LargeStringHeader but the body
// is a Tag_ByteBuffer in old gen. header.size is the logical byte count.
struct ALIGN(8) elm_large_byte_header {
    Header header;     // tag = Tag_LargeByteHeader; header.size = logical byte count.
    HPointer body;     // -> Tag_ByteBuffer body in old gen.
};
typedef struct elm_large_byte_header LargeByteHeader;
static_assert(sizeof(LargeStringHeader) == 16, "LargeStringHeader must be 16 bytes");
static_assert(sizeof(LargeByteHeader) == 16, "LargeByteHeader must be 16 bytes");

// plans/large-object-space.md D4: the ONLY way to reach a large body's payload.
// Bodies are pinned and never forwarded, so they are read raw (hpToAddr) and never
// through Allocator::resolve: a header-less payload's first byte would be read as a
// tag (Tag_Forward = 26). The length is ALWAYS the outer header's header.size.
// Bodies are header-less (HEAP_081): the body address IS the payload.
constexpr size_t kLargeBodyPayloadOffset = 0;
inline void* largeBodyAddr(const LargeStringHeader* h) { return hpToAddr(h->body); }
inline void* largeBodyAddr(const LargeByteHeader* h) { return hpToAddr(h->body); }
inline u16* largeStringChars(const LargeStringHeader* h) {
    return reinterpret_cast<u16*>(static_cast<char*>(largeBodyAddr(h)) + kLargeBodyPayloadOffset);
}
inline u8* largeBytesData(const LargeByteHeader* h) {
    return reinterpret_cast<u8*>(static_cast<char*>(largeBodyAddr(h)) + kLargeBodyPayloadOffset);
}
// The UTF-16 units of a flat string: a Tag_String leaf or a Tag_LargeStringHeader.
inline u16* flatStringChars(void* obj) {
    if (static_cast<Header*>(obj)->tag == Tag_LargeStringHeader)
        return largeStringChars(static_cast<LargeStringHeader*>(obj));
    return static_cast<ElmString*>(obj)->chars;
}

// Structural view over a ByteBuffer: header.size = logical byte count;
// `base` points to a Tag_ByteBuffer leaf or Tag_LargeByteHeader; `offset`
// is the starting index. Slice-of-slice collapses at construction by
// resolving through the inner slice's base + adjusted offset.
// header.unboxed is always 0 (the only HPointer field is `base`).
struct ALIGN(8) elm_bytebuffer_slice {
    Header header;
    HPointer base;
    u32 offset;
    u32 _padding;
};
typedef struct elm_bytebuffer_slice ElmByteBufferSlice;
// Header (8) + HPointer (8) + u32 (4) + u32 (4) = 24 bytes. Same layout
// as ElmStringSlice (24 bytes); we mirror its design without overlap.
static_assert(sizeof(ElmByteBufferSlice) == 24, "ElmByteBufferSlice must be 24 bytes");

typedef struct {
    Header header; // Header.unboxed indicates which fields are unboxed.
    Unboxable a;
    Unboxable b;
} Tuple2;

typedef struct {
    Header header; // Header.unboxed indicates which fields are unboxed.
    Unboxable a;
    Unboxable b;
    Unboxable c;
} Tuple3;

typedef struct {
    Header header; // Header.unboxed indicates if head is unboxed.
    Unboxable head;
    HPointer tail;
} Cons;

// Chunk view node (Tag_ConsChunk): a non-empty list whose first elements are
// the dense run `backing.elems[offset .. offset + k)` followed by `next`,
// where k = min(len, backing capacity - offset) and `len` is the TOTAL
// logical length of this list value. CONSISTENCY INVARIANT (never
// truncating): len == k + logicalLength(next); in particular len <= run
// implies next is Nil. O(1) `take n` therefore materializes a fresh view
// {backing, offset, n, Nil} with n <= run rather than bounding `next`.
// Immutable once observable. `next` is Nil, a Cons cell, or another view —
// spines mix freely (hybrid spines, plans/chunked-list-representation.md §6).
// Element kind: Header.unboxed bits 1:0 mirror the backing's uniform kind so
// head projections type without touching the backing header.
typedef struct {
    Header header;    // Header.unboxed bits 1:0 = element kind (mirror of backing).
    HPointer backing; // -> Tag_ListBacking.
    u32 offset;       // First live index in the backing.
    u32 len;          // Total logical length of this list value (>= 1).
    HPointer next;    // Rest of the spine after this chunk's run.
} ConsChunk;

// Dense element storage for chunk views (Tag_ListBacking). header.size is the
// CAPACITY in elements. Live slots are [hd, capacity); v1 always builds whole
// chunks with hd == 0 and never mutates after construction (front-slack fill
// is the deferred §10 ladder). GC scans [hd, capacity) by the uniform 2-bit
// element kind in Header.unboxed bits 1:0; slots below hd are uninitialized
// and must never be traced.
typedef struct {
    Header header;  // header.size = capacity (element count); unboxed bits 1:0 = kind.
    u32 hd;         // Frontmost claimed slot (v1: always 0).
    u32 _pad;
    Unboxable elems[];
} ListBacking;

typedef struct {
    Header header;           // Header.size contains field count.
    u64 ctor : CTOR_BITS;    // Constructor index within this Elm custom type (16 bits).
    u64 unboxed : 48;        // 2-bit kinds for fields 0..23 (24 slots); fields 24+ per HEAP_019
    Unboxable values[];
} Custom;

typedef struct {
    Header header; // Header.size contains field count.
    u64 unboxed; // 2-bit kinds for fields 0..31 (32 slots); fields 32+ per HEAP_019
    Unboxable values[];
} Record;

typedef struct {
    Header header;
    u64 unboxed; // Bitmap: bit N set means field N is unboxed (primitive value).
    HPointer fieldgroup;
    HPointer values[];
} DynRecord;

typedef struct {
    Header header;
    u32 count;
    u32 fields[];
} FieldGroup;

typedef void *(*EvalFunction)(void *[]);

/// Closure / PAP (partial application) object.
///
/// The header fields encode per-stage arity:
///   n_values    = number of arguments already applied to this stage (applied arity)
///   max_values  = total number of arguments this stage's evaluator expects (stage arity)
///   remaining   = max_values - n_values
///
/// Generic apply (eco_apply_closure) is staging-agnostic: it uses only these
/// header fields to determine saturation. Over-saturated calls are handled by
/// chaining: saturate this stage's evaluator, then recursively apply remaining
/// args to the result closure (which has its own n_values/max_values header).
/// Per-evaluator static descriptor (plans/gc-root-registration-cost.md Phase 2).
///
/// `Closure.evaluator` used to hold the `__closure_wrapper_*` address directly.
/// It now holds the address of one of these instead — a **static data global**
/// emitted beside each wrapper, never a heap object, so nothing about GC,
/// scanning or HEAP_0xx changes. The mapping is 1:1 with the wrapper, which is
/// what keeps HEAP_033's interning ("one permanent singleton per evaluator
/// descriptor") and every census join key meaningful.
///
/// LAYOUT IS FROZEN — `EcoToLLVMClosures.cpp` emits these and
/// `EvaluatorDescSatOffset` hard-codes `sat` at +24.
///
/// `sat[N]` is the arity-monomorphised entry for a call supplying exactly N new
/// arguments: it loads the closure's C = stage_arity - N captures in place and
/// tail-calls the typed target, so the caller needs no args array, no root
/// range, and no runtime splice. `sat` has `stage_arity + 1` slots when
/// `stage_arity <= SAT_MAX_ARITY`, else it is empty. The
/// `max_values <= SAT_MAX_ARITY` guard makes it unreadable, so every load the
/// guards admit is in bounds; slots with no generated entry are null and fail
/// the guard closed.
struct EvaluatorDesc {
    EvalFunction   generic;      // +0   the __closure_wrapper_* address
    u64            kinds;        // +8   advisory: 2 bits/param, params 0..31 only
    unsigned char  _pad_sa;      // +16  (was stage_arity:u8; always 0 now)
    unsigned char  result_kind;  // +17  ParamKind of the wrapper's compiled return
    unsigned short stage_arity;  // +18  P (<= CLOSURE_MAX_ARITY)
    unsigned int   _pad1;        // +20
    void*          sat[];        // +24  sat[0..stage_arity] if stage_arity <= SAT_MAX_ARITY, else empty; sat[0] unused
};

/// Layout v2 (plans/wide-object-tail-kind-words.md §2.1/§2.2, HEAP_019/HEAP_078):
///   packed word = n_values:11 | max_values:11 | result_kind:2 | unboxed:40
/// Kinds of params 0..19 live inline in `unboxed`; params 20.. live in
/// K = extWords(max_values, CLOSURE_HDR_SLOTS) extension kind words (32 slots
/// per word), which are the LAST K words of the object. header.size counts the
/// allocated value slots plus K (the physical-size rule), so the object size is
/// a function of the header word alone. Read kinds only through
/// closureSlotKind / ClosureKinds.
typedef struct {
    Header header;           // header.size = allocated value slots + K
    u64 n_values   : 11;     // Applied arity: args already captured for this stage (0..2047).
    u64 max_values : 11;     // Stage arity: total args this evaluator expects (0..2047).
    u64 result_kind: 2;      // ParamKind: real C-ABI return kind of `evaluator`
                             //   0 = PK_Boxed (HPtr return), 1 = PK_Int (int64_t),
                             //   2 = PK_Float (double), 3 = PK_Char (uint16_t).
                             // Read by every closure-invocation entry point so
                             // C++ kernel callers can dispatch the function-pointer
                             // cast without per-call-site K plumbing.
    u64 unboxed    : 40;     // inline 2-bit kinds for params 0..19
    const EvaluatorDesc* evaluator;   // static descriptor, NOT a heap pointer
    Unboxable values[];      // [0 .. header.size - K) values, then K ext kind words
} Closure;

#ifdef __cplusplus
static_assert(sizeof(EvaluatorDesc) == 24,
              "EvaluatorDesc header is 24 bytes; sat[] starts at +24 and the "
              "backend hard-codes that (EvaluatorDescSatOffset)");
static_assert(offsetof(EvaluatorDesc, generic) == 0, "generic at +0");
static_assert(offsetof(EvaluatorDesc, kinds) == 8, "kinds at +8");
static_assert(offsetof(EvaluatorDesc, stage_arity) == 18, "stage_arity at +18");
static_assert(offsetof(EvaluatorDesc, result_kind) == 17, "result_kind at +17");
static_assert(offsetof(EvaluatorDesc, sat) == 24, "sat at +24");
static_assert(sizeof(Closure) == 24, "Closure base is 24 bytes");
#endif

// ---- Wide-object slot-kind accessors (plans/wide-object-tail-kind-words.md §S.1) ----
// Custom/Record (layout C, Phase 3A): slots 0..HDR-1 in the header bitmap, slots HDR.. in
// K = header.unboxed extension kind words after values[header.size] (32 slots per word).
// Readers never recompute K: a slot whose ext word index is >= header.unboxed reads boxed.
inline const u64* customExtWords(const Custom* c) { return reinterpret_cast<const u64*>(&c->values[c->header.size]); }
inline const u64* recordExtWords(const Record* r) { return reinterpret_cast<const u64*>(&r->values[r->header.size]); }
inline u64* customExtWordsMut(Custom* c) { return reinterpret_cast<u64*>(&c->values[c->header.size]); }
inline u64* recordExtWordsMut(Record* r) { return reinterpret_cast<u64*>(&r->values[r->header.size]); }
// The slot-kind accessors are split: the header-bitmap case is forced inline (it is on the
// equality and GC-walker hot paths, where an out-of-line call measurably cost ~1 % of a
// self-compile), and the extension-word case, reached only by wide objects, is a cold call.
[[gnu::noinline, gnu::cold]] inline u32 customExtSlotKind(const Custom* c, u32 i) {
    const u32 r = i - CUSTOM_HDR_SLOTS;
    const u32 j = r / SLOTS_PER_EXT_WORD;
    if (j >= c->header.unboxed) return 0u;   // bounded by the stored K
    return kindInWord(customExtWords(c)[j], r % SLOTS_PER_EXT_WORD);
}
[[gnu::always_inline]] inline u32 customSlotKind(const Custom* c, u32 i) {
    if (__builtin_expect(i < CUSTOM_HDR_SLOTS, 1)) return kindInWord(c->unboxed, i);
    return customExtSlotKind(c, i);
}
[[gnu::noinline, gnu::cold]] inline u32 recordExtSlotKind(const Record* r, u32 i) {
    const u32 q = i - RECORD_HDR_SLOTS;
    const u32 j = q / SLOTS_PER_EXT_WORD;
    if (j >= r->header.unboxed) return 0u;
    return kindInWord(recordExtWords(r)[j], q % SLOTS_PER_EXT_WORD);
}
[[gnu::always_inline]] inline u32 recordSlotKind(const Record* r, u32 i) {
    if (__builtin_expect(i < RECORD_HDR_SLOTS, 1)) return kindInWord(r->unboxed, i);
    return recordExtSlotKind(r, i);
}
// Physical value words W = n + extWords(n, cap) -> (n, K). W is strictly increasing in n
// (for m = n - cap >= 1, W = cap + m + ceil(m/32) steps by 1 or 2), so the inverse is unique;
// values of W not in the image (W - cap == 1 mod 33) return false.
constexpr bool splitPhysicalSlots(u32 W, u32 cap, u32& n, u32& k) {
    if (W <= cap) { n = W; k = 0; return true; }
    const u32 w = W - cap;               // w = m + ceil(m/32), m = n - cap >= 1
    if (w < 2) return false;             // w == 1 is not in the image
    const u32 q = (w - 2) / 33;          // m = 32q + r, r in [1,32]  =>  w = 33q + r + 1
    const u32 r = w - 33 * q - 1;
    if (r > 32) return false;            // w == 33(q+1) + 1 is not in the image
    n = cap + 32 * q + r;
    k = q + 1;                           // k = ceil(m/32) = q + 1
    return true;
}
// Pack kinds[0..n) for the header bitmap (slots < cap).
inline u64 packHeaderKinds(const u8* kinds, u32 n, u32 cap) {
    u64 w = 0;
    for (u32 i = 0; i < n && i < cap; ++i) w |= u64(kinds[i] & 3u) << (2 * i);
    return w;
}
// Pack kinds[cap..n) into the extWords(n, cap) words at `ext`, zero padding included (HEAP_077).
inline void packExtKinds(const u8* kinds, u32 n, u32 cap, u64* ext) {
    const u32 k = extWords(n, cap);
    for (u32 j = 0; j < k; ++j) ext[j] = 0;
    for (u32 i = cap; i < n; ++i) {
        const u32 r = i - cap;
        ext[r / SLOTS_PER_EXT_WORD] |= u64(kinds[i] & 3u) << (2 * (r % SLOTS_PER_EXT_WORD));
    }
}
static_assert(extWords(CUSTOM_MAX_FIELDS, CUSTOM_HDR_SLOTS) == 63, "Custom K must fit Header.unboxed:6");
static_assert(extWords(RECORD_MAX_FIELDS, RECORD_HDR_SLOTS) == 63, "Record K must fit Header.unboxed:6");
// 32 KiB = GroupLargeObjectThreshold (runtime/src/codegen/Passes/EcoGCPrepare.cpp): the born-old
// threshold, repeated here because the allocator cannot include the codegen tree.
static_assert(sizeof(Custom) + (CUSTOM_MAX_FIELDS + 63) * 8 < 32 * 1024, "wide Custom stays below born-old LOT");
static_assert(sizeof(Record) + (RECORD_MAX_FIELDS + 63) * 8 < 32 * 1024, "wide Record stays below born-old LOT");
// Closure extension kind words: the LAST K words of the object (physical-size rule).
inline const u64* closureExtWords(const Closure* cl) {
    return reinterpret_cast<const u64*>(
        &cl->values[cl->header.size - extWords(cl->max_values, CLOSURE_HDR_SLOTS)]);
}
// Direct closure accessor for NON-allocating readers (GC walkers, validate checks,
// printers). Allocating loops must use ClosureKinds (below).
[[gnu::noinline, gnu::cold]] inline u32 closureExtSlotKind(const Closure* cl, u32 i) {
    const u32 j = (i - CLOSURE_HDR_SLOTS) / SLOTS_PER_EXT_WORD;
    if (j >= extWords(cl->max_values, CLOSURE_HDR_SLOTS)) return 0u;
    return kindInWord(closureExtWords(cl)[j], (i - CLOSURE_HDR_SLOTS) % SLOTS_PER_EXT_WORD);
}
[[gnu::always_inline]] inline u32 closureSlotKind(const Closure* cl, u32 i) {
    if (__builtin_expect(i < CLOSURE_HDR_SLOTS, 1)) return kindInWord(cl->unboxed, i);
    return closureExtSlotKind(cl, i);
}
// Snapshot of a closure's kinds for every loop that can allocate (the closure may move).
struct ClosureKinds {
    u64 hdr;        // the 40-bit inline field (20 slots)
    u32 max;        // max_values
    u32 k;          // ext words copied into ext[] = extWords(max, CLOSURE_HDR_SLOTS) <= 64
    u64 ext[64];
};
static_assert(extWords(CLOSURE_MAX_ARITY, CLOSURE_HDR_SLOTS) <= 64, "ClosureKinds::ext holds every ext word");
inline void snapshotClosureKinds(const Closure* cl, ClosureKinds& out) {
    out.hdr = cl->unboxed;
    out.max = cl->max_values;
    out.k = extWords(out.max, CLOSURE_HDR_SLOTS);
    const u64* ext = out.k ? closureExtWords(cl) : nullptr;
    for (u32 j = 0; j < out.k; ++j) out.ext[j] = ext[j];
}
inline u32 closureKindAt(const ClosureKinds& ks, u32 slot) {
    if (slot < CLOSURE_HDR_SLOTS) return kindInWord(ks.hdr, slot);
    const u32 j = (slot - CLOSURE_HDR_SLOTS) / SLOTS_PER_EXT_WORD;
    return j < ks.k ? kindInWord(ks.ext[j], (slot - CLOSURE_HDR_SLOTS) % SLOTS_PER_EXT_WORD) : 0u;
}
// Validate-only well-formedness: header.size covers the values and the K ext
// words, n_values <= max_values <= CLOSURE_MAX_ARITY, and no ext kind bits are
// set past slot max_values - 1.
inline bool closureWellFormed(const Closure* cl) {
    const u32 n = cl->n_values, max = cl->max_values;
    const u32 K = extWords(max, CLOSURE_HDR_SLOTS);
    if (n > max || max > CLOSURE_MAX_ARITY) return false;
    if (cl->header.size < n + K) return false;
    if (K == 0) return true;
    const u64* ext = closureExtWords(cl);
    const u32 lastSlots = (max - CLOSURE_HDR_SLOTS) - (K - 1) * SLOTS_PER_EXT_WORD;  // 1..32
    if (lastSlots < SLOTS_PER_EXT_WORD && (ext[K - 1] >> (2 * lastSlots)) != 0) return false;
    return true;
}

/// Type tag for each evaluator parameter slot, used by buildEvaluatorArgs
/// to re-box unboxed captured values with the correct heap allocator.
enum ParamKind : unsigned char {
    PK_Boxed  = 0,
    PK_Int    = 1,
    PK_Float  = 2,
    PK_Char   = 3,
};

/// Layout descriptor for evaluator parameters. Emitted as an LLVM global
/// constant by the compiler. Describes the kind of each parameter slot;
/// `kinds[i] == ParamKind`. `result_kind` carries the closure evaluator's
/// real C-ABI return kind (per REP_ABI_001): `eco_apply_closure_eval`
/// reinterprets the evaluator function pointer based on this byte rather
/// than always treating it as `HPtr (*)(...)`.
///
/// The capability bit "evaluator accepts typed newargs without re-boxing"
/// lives on `Closure::flags`, not here — the caller cannot statically know
/// what evaluator a dynamically-dispatched closure has, so the gate must
/// be readable from the closure header.
/// Memory layout: { num_params: u16, result_kind: u8, _pad: u8, kinds[num_params]: u8[] }
struct EvalParamLayout {
    unsigned short num_params;   // +0
    unsigned char  result_kind;  // +2  ParamKind: closure evaluator's return kind
    unsigned char  _pad;         // +3
    unsigned char  kinds[];      // +4  flexible array member, length = num_params
};
#ifdef __cplusplus
static_assert(offsetof(EvalParamLayout, num_params) == 0, "num_params at +0");
static_assert(offsetof(EvalParamLayout, result_kind) == 2, "result_kind at +2");
static_assert(offsetof(EvalParamLayout, kinds) == 4, "kinds at +4");
/// Static layouts for kernels: EvalParamLayoutN<N> is layout-compatible with EvalParamLayout.
template <unsigned N> struct EvalParamLayoutN {
    unsigned short num_params;
    unsigned char  result_kind;
    unsigned char  _pad;
    unsigned char  kinds[N];
};
template <unsigned N>
constexpr EvalParamLayoutN<N> makeEvalParamLayout(unsigned char rk, const unsigned char (&k)[N]) {
    EvalParamLayoutN<N> l{};
    l.num_params = static_cast<unsigned short>(N);
    l.result_kind = rk;
    for (unsigned i = 0; i < N; ++i) l.kinds[i] = k[i];
    return l;
}
template <unsigned N>
inline const EvalParamLayout* asLayout(const EvalParamLayoutN<N>* p) {
    static_assert(offsetof(EvalParamLayoutN<N>, kinds) == offsetof(EvalParamLayout, kinds),
                  "EvalParamLayoutN is layout-compatible with EvalParamLayout");
    return reinterpret_cast<const EvalParamLayout*>(p);
}
#endif

typedef struct {
    Header header;
    u64 id : ID_BITS;
    u64 padding : 48;
    HPointer root;
    HPointer stack;
    HPointer mailbox;
} Process;

// Task.value carries either a boxed HPointer (header.unboxed slot 0 == 0) or
// an unboxed primitive (slot 0 == 1=Int, 2=Float, 3=Char). The other Unboxable
// fields are always pointers; the GC scanners and scheduler dispatch to the
// right path by reading slot 0 of header.unboxed.
typedef struct {
    Header header;
    u64 ctor : CTOR_BITS;
    u64 id : ID_BITS;
    u64 padding : 32;
    Unboxable value;
    HPointer callback;
    HPointer kill;
    HPointer task;
} Task;

// Forwarding pointer for copying collection.
// Replaces an evacuated object's header to redirect references to the new location.
// The tag field identifies this as Forward, and remaining bits store the target address.
typedef struct {
    struct {
        u64 tag : TAG_BITS;           // Tag_Forward (identifies this as a forwarding pointer).
        u64 color : 2;                // Must use u64 to match other bitfields for correct packing.
        u64 forward_ptr : POINTER_BITS;  // Logical pointer offset to new location.
        u64 unused : 17;              // Unused bits (could store metadata if needed).
    } header;
    // No additional fields - this replaces the evacuated object's header.
} Forward;

// ============================================================================
// Binary Data Types
// ============================================================================

/**
 * Immutable byte buffer for binary data.
 *
 * Used by:
 *   - Bytes module for encoding/decoding binary data
 *   - File module for file contents
 *   - Http module for request/response bodies
 *   - Base64 encoding operations
 *
 * Memory layout:
 *   - header.size = byte count (up to 4GB)
 *   - bytes[] = raw byte data, 8-byte aligned
 *
 * GC notes:
 *   - Contains no pointers, so no scanning needed
 *   - Can be directly copied during evacuation
 */
struct ALIGN(8) elm_bytebuffer {
    Header header;  // header.size = byte count
    u8 bytes[];     // Flexible array of raw bytes
};
typedef struct elm_bytebuffer ByteBuffer;

// UTF-8 (all-ASCII) String as a zero-copy view over a byte buffer. 24 bytes,
// mirroring ElmStringSlice. header.size = logical UTF-16 unit count, which
// equals byteLen because every char is a single ASCII byte (< 0x80).
// `base` points to a Tag_ByteBuffer, a Tag_LargeByteHeader (its *header*, not
// the pinned body — same lifetime rule as slice-of-large), or a
// Tag_StringUtf8Leaf. `base` is the only boxed field; `offset`/`byteLen` are
// scalars never read by GC (header.unboxed == 0). GC treats this exactly like
// Tag_StringSlice (trace `base`). See HEAP_032.
struct ALIGN(8) elm_string_utf8_view {
    Header header;
    HPointer base;
    u32 offset;    // byte offset into base's payload
    u32 byteLen;   // == header.size under the ASCII invariant
};
typedef struct elm_string_utf8_view ElmStringUtf8View;
static_assert(sizeof(ElmStringUtf8View) == 24, "ElmStringUtf8View must be 24 bytes");

// UTF-8 (all-ASCII) String with inline bytes; mirrors ElmString but 1 byte per
// code unit. header.size = logical UTF-16 unit count == payload byte count.
// Pointer-free (like Tag_String / Tag_ByteBuffer): GC copies it wholesale and
// traces no children. Not nul-terminated.
struct ALIGN(8) elm_string_utf8_leaf {
    Header header;  // header.size = byte count == UTF-16 unit count
    u8 bytes[];     // Flexible array of ASCII bytes (each < 0x80)
};
typedef struct elm_string_utf8_leaf ElmStringUtf8Leaf;

/**
 * Mutable/growable array of Elm values.
 *
 * Used by:
 *   - JsArray module for array operations (push, slice, etc.)
 *   - Json module for JSON arrays
 *   - Internal intermediate collections
 *
 * Memory layout:
 *   - header.size = allocated capacity (in elements)
 *   - length = current number of elements
 *   - unboxed = flag indicating if ALL elements are unboxed primitives
 *   - elements[] = array of Unboxable values
 *
 * Capacity vs Length:
 *   - capacity (header.size) = total allocated slots
 *   - length = number of slots currently in use
 *   - Allows efficient push() without reallocating every time
 *
 * Uniformity:
 *   - Arrays are uniform: either ALL elements are boxed or ALL are unboxed
 *   - Single bit flag replaces per-element bitmap
 *
 * GC notes:
 *   - Must scan elements[0..length-1] for pointers if !unboxed
 *   - If unboxed flag is set, all elements are primitives (skip scanning)
 *   - When copying, only copy header + used elements (not full capacity)
 */
typedef struct {
    Header header;     // header.size = capacity; header.unboxed bit 0 = all-unboxed flag
    u32 length;        // Current number of elements in use
    u32 padding;       // Alignment padding
    Unboxable elements[];  // Flexible array of values
} ElmArray;

typedef union HeapValue {
    ElmInt intval;
    ElmFloat floatval;
    ElmChar charval;
    ElmString string;
    ElmStringSlice stringSlice;
    ElmStringRope stringRope;
    Tuple2 tuple2;
    Tuple3 tuple3;
    Cons cons;
    Custom custom;
    Record record;
    DynRecord dynrecord;
    FieldGroup fieldgroup;
    Closure closure;
    Process process;
    Task task;
    Forward fwd;
    ByteBuffer bytebuffer;
    ElmArray array;
    LargeStringHeader largeStringHeader;
    LargeByteHeader   largeByteHeader;
    ElmByteBufferSlice byteBufferSlice;
    ElmStringUtf8View  stringUtf8View;
    ElmStringUtf8Leaf  stringUtf8Leaf;
} HeapValue;

} // namespace Elm

#endif // ECO_HEAP_H
