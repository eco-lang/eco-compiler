// The bit layout of every Eco heap object and of the word that refers to one.
//
// The collector, the runtime kernels and the code generator all read and write heap objects
// directly, so they must agree on every bit. This header is that agreement. It includes nothing
// from the rest of the project.
//
// Two words are the vocabulary of everything below.
//
// A `Header` is the 64-bit word at the start of every heap object. Its `tag` says what kind of
// object follows, and its `size` is a count whose unit depends on the tag. An object's footprint
// is a function of its header word alone, which is what lets a collector stride through memory
// object by object; `getObjectSizeFromHeader` in AllocatorCommon.hpp computes it.
//
// An `HPointer` is the 64-bit word for an Elm value held anywhere a boxed value goes. It is one of
// three things, told apart by bit 2, `ptr_ind`:
//   - with `ptr_ind` clear, the word is the absolute address of a heap object, unchanged: there is
//     no base and no shift. The word 0 is null. This works because objects are 8-byte aligned and
//     the heap is reserved below `HPOINTER_ADDRESS_LIMIT`;
//   - with `ptr_ind` set, it is an embedded constant, a value with no object behind it: False
//     (0x4), True (0x5), or Empty (0x6), the one constant shared by Unit, the empty record, Nil,
//     Nothing, the empty String and the empty Bytes;
//   - or, also with `ptr_ind` set, a null-cons word, `(idx << 43) | 0b111`, which is a nullary
//     constructor stored as its zero-based declaration index.
// The `constant` field of False is 0, as it is for a heap pointer, so a constant is recognised by
// `ptr_ind` and never by a non-zero `constant`.
//
// A field of a container need not hold an HPointer. Int, Float and Char may be stored unboxed, as
// the raw value, and every container records a 2-bit slot kind per field: 00 boxed HPointer, 01
// Int, 10 Float, 11 Char. Bool is never unboxed in a heap field. Where the kinds live depends on
// the object: in `Header.unboxed` for tuples, Cons, Task and the uniform-kind arrays, and in a
// kinds bitmap after the header for Custom, Record and Closure. Objects with more fields than that
// bitmap covers carry extension kind words in their tail; the accessors below are the only code
// that should locate them.
//
// Large Strings and Bytes are split in two. A small header object (`LargeStringHeader`,
// `LargeByteHeader`) is an ordinary heap object; its `body` addresses a payload with no Header of
// its own, which is pinned and never moved. Such a body is reached only through
// `largeBodyAddr` and the accessors beside it.
//
// The rules in design_docs/invariants.csv in the eco repository that this layout carries are
// cited by id (HEAP_*).

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

// The width in bits of `Header.tag` and of the tag of a `Forward` word.
#define TAG_BITS 5
// The width in bits of the constructor index of a `Custom` and of a `Task`.
#define CTOR_BITS 16
// The width in bits of an address in 8-byte units: `HPointer.ptr` and `Forward`'s `forward_ptr`.
#define POINTER_BITS 40
// The width in bits of `Task.id`. A `Process` id is a full 64-bit word.
#define ID_BITS 16

// The exclusive upper bound on any heap address (2^43, 8 TB).
//
// `HPointer.ptr` is `POINTER_BITS` wide and starts at bit 3, so an 8-byte-aligned address below
// this bound is its own HPointer word. The whole heap must be reserved below it (HEAP_008).
#define HPOINTER_ADDRESS_LIMIT (1ULL << (POINTER_BITS + 3))

/**
 * The kind of a heap object, stored in `Header.tag`.
 *
 * The values are written into compiled code and read by every heap walker, so they must not be
 * renumbered. Order is significant: `Tag_Forward` must be last and `Tag_Free` just before it, so
 * that every live object's tag is below `Tag_Free`.
 */
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
    Tag_ByteBuffer,  // A `ByteBuffer`.
    Tag_Array,       // An `ElmArray`.
    Tag_StringRope,  // An `ElmStringRope`.
    Tag_StringSlice, // An `ElmStringSlice`.
    Tag_ByteBufferSlice, // An `ElmByteBufferSlice`.
    Tag_LargeStringHeader, // A `LargeStringHeader`; `header.size` is the length in UTF-16 units.
    Tag_LargeByteHeader,   // A `LargeByteHeader`; `header.size` is the length in bytes.
    // The two all-ASCII String forms. The runtime creates them; compiled code does not.
    Tag_StringUtf8View,  // An `ElmStringUtf8View`.
    Tag_StringUtf8Leaf,  // An `ElmStringUtf8Leaf`.
    // The two chunked-list forms. A list spine may mix `Cons` cells and `ConsChunk` nodes.
    Tag_ConsChunk,   // A `ConsChunk`.
    Tag_ListBacking, // A `ListBacking`.
    Tag_Free,        // A free cell in the old generation; `header.size` is its size in bytes.
    Tag_Forward,     // A `Forward` word replacing the header of an object a collector has moved.
} Tag;

/**
 * The 64-bit word at the start of every heap object.
 *
 * `tag` is a `Tag` and decides how the rest of the object, and the other fields of this word, are
 * read. `size` counts in a unit the tag decides; each object type's comment says which.
 *
 * `unboxed` has one meaning per tag. For `Tuple2`, `Tuple3` and `Cons` it holds the 2-bit kinds
 * of the fields, slot i at bits [2i, 2i+1]. For `Task` it holds the kind of `value` in bits 1:0.
 * For `ElmArray`, `ListBacking` and `ConsChunk` bits 1:0 are the one kind every element has. For
 * `Custom` and `Record` it is K, the number of extension kind words in the object's tail.
 *
 * `age` counts the minor collections a young object has survived. On a `Tag_Free` cell, when
 * `old_gen_bitmap_alloc` is off, bit 0 of `age` is a sentinel instead (HEAP_027): set means the
 * cell is already on a free list and must not be coalesced with its neighbours or rewritten.
 *
 * `builder` set marks an object still under construction by runtime code. A builder must be
 * young (HEAP_BUILDER_001), is never promoted and keeps `age` 0 while the bit is set
 * (HEAP_BUILDER_002), and must have the bit cleared before Elm code can reach it
 * (HEAP_BUILDER_003). `pin` forbids moving an object;
 * `builder` forbids promoting it. An object is promoted when
 * `!pin && !builder && age >= promotion_age`.
 *
 * `refcount` holds no reference count. On a `Tag_Free` cell the old generation keeps free-list
 * link bits in it (OldGenSpace.hpp).
 */
typedef struct {
    u32 tag : TAG_BITS;
    u32 color : 2; // Mark colour.
    u32 pin : 1; // Set on an object that must not be moved.
    u32 age : 2; // Minor collections survived; the free-list sentinel on Tag_Free cells.
    u32 unboxed : 6; // Kinds or K; see the type comment.
    u32 refcount : 15; // Not a reference count; see the type comment.
    u32 builder : 1; // Set while the object is under construction.
    u32 size; // Size in the unit the tag decides.
} Header;
static_assert(sizeof(Header) == 8, "Header must be 64 bits");

/**
 * The code in `HPointer.constant` that says which embedded constant a word is.
 *
 * It means something only when `ptr_ind` is set; a heap pointer has 0 here, as False does. The
 * Bool values are the same as the i1 value of the Bool in SSA and at the ABI.
 */
typedef enum {
    Const_False = 0,
    Const_True  = 1,
    Const_Empty = 2, // Unit, the empty record, Nil, Nothing, the empty String and the empty Bytes.
    Const_NullCons = 3, // A nullary constructor; its declaration index is in `null_cons_idx`.
} Constant;

/**
 * The word for a boxed Elm value: a heap address, an embedded constant, or a null-cons word.
 *
 * From the least significant bit: `constant` (bits 0-1) and `ptr_ind` (bit 2), then `ptr` (bits
 * 3-42), `null_cons_idx` (bits 43-52) and `padding` (bits 53-63). For a heap pointer the whole
 * word is the object's address, so `ptr` is the address divided by 8 and every other field is 0.
 * `null_cons_idx` is non-zero only in a null-cons word. `padding` is 0 in every well-formed word.
 *
 * The bit-field layout is implementation-defined, and these words cannot be checked with
 * `static_assert` because `std::bit_cast` of a bit-field struct is not a constant expression.
 * HPointerLayoutTest checks at run time that the canonical words come out as stated.
 */
typedef struct {
    u64 constant : 2;
    u64 ptr_ind  : 1;
    u64 ptr      : POINTER_BITS;
    u64 null_cons_idx : 10;
    u64 padding  : 11;
} HPointer;
static_assert(sizeof(HPointer) == 8, "HPointer must be 64 bits");

// The bit position of `HPointer.ptr_ind` within the word.
#define PTR_IND_BIT 2

/**
 * An HPointer word as it crosses a C-linkage boundary.
 *
 * Compiled code declares the same value as `ptr addrspace(1)`. A struct with one 64-bit member is
 * passed and returned in a register as a pointer is, which is what makes the two declarations
 * agree; this header relies on the platform ABI for that and checks only the size.
 */
struct HPtr {
    u64 bits;
    // Returns the `HPtr` whose word is `b`.
    static HPtr fromBits(u64 b) { return HPtr{b}; }
    // Returns the word.
    u64 toBits() const { return bits; }
    // Returns the `HPtr` with the same word as `hp`.
    static HPtr fromHPointer(HPointer hp) { HPtr h; memcpy(&h.bits, &hp, 8); return h; }
    // Returns the `HPointer` with the same word.
    HPointer toHPointer() const { HPointer hp; memcpy(&hp, &bits, 8); return hp; }
};
static_assert(sizeof(HPtr) == 8, "HPtr must be 64 bits");

/**
 * One field of a container: a boxed `HPointer` or an unboxed Int, Float or Char.
 *
 * Nothing in the union says which member is live. The container's slot kind for the field does,
 * and reading any other member gives a meaningless value.
 */
typedef union {
    HPointer p;
    i64 i;
    f64 f;
    u32 c;  // Char: Unicode code point. Write via unboxedChar() so bits 32..63 are zero.
} Unboxable;
static_assert(sizeof(Unboxable) == 8, "Unboxable must be 64 bits");

// ============================================================================
// 2-Bit Slot Kind Accessors
// ============================================================================
//
// A kind word holds the 2-bit kinds of up to 32 slots, slot i at bits [2i, 2i+1]: 00 boxed
// HPointer (`.p`), 01 Int (`.i`), 10 Float (`.f`), 11 Char (`.c`, a u32 code point zero-extended to
// 64 bits). Bool and String are always boxed.

// Returns the kind of slot `index` in the kind word `bitmap`. `index` must be below 32 (asserted).
inline u64 fieldKind(u64 bitmap, unsigned index) {
    assert(index < 32 && "fieldKind: index past one 64-bit kind word (use the slot-kind accessors)");
    return (bitmap >> (2 * index)) & 0x3ULL;
}

// Returns the kind of field `index` of a tuple, given its `header.unboxed`. `index` must be below
// 3 (asserted).
inline u32 tupleFieldKind(u32 headerUnboxed, unsigned index) {
    assert(index < 3 && "tupleFieldKind: header.unboxed holds 3 slots");
    return (headerUnboxed >> (2 * index)) & 0x3U;
}

// Returns `bitmap` with the kind of slot `index` replaced by the low 2 bits of `kind`. `index`
// must be below 32 (asserted).
inline u64 bitmapSetKind(u64 bitmap, unsigned index, u64 kind) {
    assert(index < 32 && "bitmapSetKind: index past one 64-bit kind word");
    const u64 shift = 2ULL * index;
    const u64 mask  = 0x3ULL << shift;
    return (bitmap & ~mask) | ((kind & 0x3ULL) << shift);
}

// Returns a mask with bit i set for each of the first `numSlots` slots that holds an HPointer.
//
// `kindBitmap` describes slots 0 to 31; slots 32 to 63 are treated as boxed. `numSlots` must be at
// most 64 (asserted).
inline u64 pointerMaskFromKindBitmap(u64 kindBitmap, unsigned numSlots) {
    assert(numSlots <= 64 && "pointerMaskFromKindBitmap: mask covers 64 slots; use pushRootsByKinds");
    u64 mask = 0;
    for (unsigned i = 0; i < numSlots; ++i)
        if (i >= 32 || fieldKind(kindBitmap, i) == 0) mask |= (1ULL << i);
    return mask;
}

// ---- Wide objects ----
// A Custom, Record or Closure keeps the kinds of its first fields in a bitmap after the header.
// The kinds of the rest are in extension kind words, 32 slots per word, in the object's tail. The
// accessors that read them follow the Closure type below.

// The number of field kinds a `Custom`'s own `unboxed` bitmap holds.
constexpr u32 CUSTOM_HDR_SLOTS   = 24;    // Custom::unboxed:48
// The number of field kinds a `Record`'s own `unboxed` bitmap holds.
constexpr u32 RECORD_HDR_SLOTS   = 32;    // Record::unboxed:64
// The number of parameter kinds a `Closure`'s own `unboxed` bitmap holds.
constexpr u32 CLOSURE_HDR_SLOTS  = 20;    // Closure::unboxed:40
// The number of slot kinds in one extension kind word.
constexpr u32 SLOTS_PER_EXT_WORD = 32;
// The most fields a `Custom` may have; K then fits `Header.unboxed`, as checked below.
constexpr u32 CUSTOM_MAX_FIELDS  = 2040;
// The most fields a `Record` may have; K then fits `Header.unboxed`, as checked below.
constexpr u32 RECORD_MAX_FIELDS  = 2047;
// The largest stage arity of a `Closure`, the most its 11-bit `max_values` can hold.
constexpr u32 CLOSURE_MAX_ARITY  = 2047;  // n_values:11 / max_values:11 (HEAP_078)
// The largest stage arity for which an `EvaluatorDesc` has a `sat` table.
//
// It equals `CLOSURE_HDR_SLOTS`, so a closure served by `sat` has every kind in its own bitmap.
// The code that guards a `sat` call and the code that emits descriptors must both use this value.
constexpr u32 SAT_MAX_ARITY      = CLOSURE_HDR_SLOTS;
static_assert(SAT_MAX_ARITY <= CLOSURE_HDR_SLOTS, "c3 reads kinds from the header word only");

// Returns how many extension kind words an object with `n` slots needs when its own bitmap holds
// `hdrSlots` of them.
constexpr u32 extWords(u32 n, u32 hdrSlots) {
    return n > hdrSlots ? (n - hdrSlots + SLOTS_PER_EXT_WORD - 1) / SLOTS_PER_EXT_WORD : 0;
}
// Returns the kind of slot `i` in the kind word `word`. `i` must be below 32 (asserted).
inline u32 kindInWord(u64 word, u32 i) {
    assert(i < 32);
    return static_cast<u32>(word >> (2 * i)) & 3u;
}

// ============================================================================
// HPointer words
// ============================================================================
//
// The functions that turn an HPointer into its word and back, classify a word, and encode a
// forwarding address.

// Returns the 64-bit word of `hp`.
inline u64 hpBits(HPointer hp) {
    u64 b;
    std::memcpy(&b, &hp, sizeof(b));
    return b;
}
// Returns the HPointer whose word is `b`.
inline HPointer hpFromBits(u64 b) {
    HPointer hp;
    std::memcpy(&hp, &b, sizeof(hp));
    return hp;
}

// Returns the address `hp` refers to: the low 43 bits of its word.
//
// `hp` must be a heap pointer; for a constant the result is not an address. Nothing here follows
// a `Forward` word.
inline void* hpToAddr(HPointer hp) {
    return reinterpret_cast<void*>(hpBits(hp) & ((1ULL << (POINTER_BITS + 3)) - 1));
}

// Returns whether the word `b` is an embedded constant or null-cons word rather than a heap
// pointer, by its `ptr_ind` bit. The null word 0 is not a constant.
inline bool isConstantBits(u64 b) { return hpFromBits(b).ptr_ind != 0; }

// Returns whether the word `b` is the Empty constant.
inline bool isEmptyBits(u64 b) {
    HPointer hp = hpFromBits(b);
    return hp.ptr_ind != 0 && hp.constant == Const_Empty;
}

// Returns the Bool value, 0 or 1, of the word `b`. The result means something only when `b` is
// False or True.
inline u64 boolValueBits(u64 b) {
    return hpFromBits(b).constant & 1u;
}

// The bit position of `HPointer.null_cons_idx` within the word.
//
// A nullary constructor is never a heap object. Its value is the null-cons word
// `(idx << NULL_CONS_SHIFT) | 0b111`, where idx is its zero-based declaration index (HEAP_044).
#define NULL_CONS_SHIFT 43
// The largest declaration index a null-cons word can hold, all 10 bits of `null_cons_idx`.
#define NULL_CONS_MAX   1023          // 10 bits; the full range is usable

// Returns whether the word `b` is a null-cons word.
inline bool isNullConsBits(u64 b) {
    HPointer hp = hpFromBits(b);
    return hp.ptr_ind != 0 && hp.constant == Const_NullCons;
}

// Returns the declaration index held in the null-cons word `b`. `b` must be a null-cons word.
inline u32 nullConsTagBits(u64 b) {
    return static_cast<u32>(hpFromBits(b).null_cons_idx);
}

// Returns the null-cons word for declaration index `idx`. `idx` must be at most `NULL_CONS_MAX`;
// nothing here checks it, and a larger index spills into `padding`.
inline u64 nullConsWordFor(u32 idx) {
    return (static_cast<u64>(idx) << NULL_CONS_SHIFT)
         | (1ULL << PTR_IND_BIT) | Const_NullCons;                  // …0b111
}

// The constructor tag reported for the Empty constant, which stands for several types' empty
// values and so has no declaration index of its own (HEAP_029).
//
// The compiler tags case branches on such values with the same number, so it must equal
// `Compiler.Data.CtorTag.constantTag` in the compiler and `value_enc::ConstantTag` in codegen;
// check-ctor-tags.sh checks that.
#define CONSTANT_TAG 0xFFFD

// Returns the `Forward::forward_ptr` value for the address `newObj`: the address divided by 8.
//
// Unlike an HPointer, a forward word cannot hold the address in place, because its low bits hold
// the tag. The second parameter is unused and kept so that callers need not change.
inline u64 encodeForwardPtr(void* newObj, char* /*heap_base*/) {
    return static_cast<u64>(reinterpret_cast<uintptr_t>(newObj)) >> 3;
}
// Returns the address a `Forward::forward_ptr` value `forwardPtr` encodes. The second parameter is
// unused.
inline char* decodeForwardPtr(u64 forwardPtr, char* /*heap_base*/) {
    return reinterpret_cast<char*>(static_cast<uintptr_t>(forwardPtr) << 3);
}

// ============================================================================
// Elm Value Types
// ============================================================================

/**
 * A boxed Float.
 */
typedef struct {
    Header header;
    f64 value;
} ElmFloat;

/**
 * A boxed Int.
 */
typedef struct {
    Header header;
    i64 value;
} ElmInt;

/**
 * A boxed Char (KERN_008, CharValue.hpp): one Unicode code point (0 to 0x10FFFF; a lone surrogate is
 * its unit value) or, when ECO_CHAR_CASE_EXPANSION is on, an encoded case-mapping result whose first
 * code point is in bits 0-20 and whose rank is above them.
 */
typedef struct {
    Header header;
    u32 value;
    u32 padding;  // Padding to maintain 8-byte alignment.
} ElmChar;

// Expands to the attribute that aligns a type to `X` bytes. The variable-length object types use
// it so that their size is a multiple of 8 even when their trailing array is narrower.
#define ALIGN(X) __attribute__((aligned(X)))
/**
 * A String stored as UTF-16 code units in the object.
 *
 * `header.size` is the length in UTF-16 units. A String of length 0 is never allocated; the empty
 * String is the Empty constant (HEAP_071).
 */
struct ALIGN(8) elm_string {
    Header header; // header.size = length in UTF-16 units.
    u16 chars[];
};
typedef struct elm_string ElmString;

/**
 * A String that is a run of the UTF-16 units of another String, shared rather than copied.
 *
 * `header.size` is the length of the run and `offset` its first index in `base`'s units. `base` is
 * the only field a collector traces; `header.unboxed` is 0.
 */
struct ALIGN(8) elm_string_slice {
    Header header;
    HPointer base;
    u32 offset;
    u32 _padding;
};
typedef struct elm_string_slice ElmStringSlice;

/**
 * A String that is the concatenation of two others, `left` then `right`.
 *
 * `header.size` is the total length in UTF-16 units. `left` and `right` are the only fields a
 * collector traces; `header.unboxed` is 0. `height` and `leafCount` are used to keep the tree
 * balanced.
 */
struct ALIGN(8) elm_string_rope {
    Header header;
    HPointer left;
    HPointer right;
    u32 height;     // 1 + the greater height of `left` and `right`; a non-rope String has height 0.
    u32 leafCount;  // The leaf count of `left` plus that of `right`.
};
typedef struct elm_string_rope ElmStringRope;

/**
 * A large String: an ordinary heap object that refers to its UTF-16 units held elsewhere.
 *
 * `header.size` is the length in UTF-16 units, and the only record of it. `body` is the address
 * of the first unit; the units have no Header in front of them, are pinned and are never moved
 * (HEAP_081). They are read only through `largeStringChars`, never by resolving `body` as an
 * object.
 */
struct ALIGN(8) elm_large_string_header {
    Header header;     // header.size = length in UTF-16 units.
    HPointer body;     // The address of the first unit.
};
typedef struct elm_large_string_header LargeStringHeader;

/**
 * Large Bytes: the byte counterpart of `LargeStringHeader`. `header.size` is the length in
 * bytes, and the header-less body is read only through `largeBytesData`.
 */
struct ALIGN(8) elm_large_byte_header {
    Header header;     // header.size = length in bytes.
    HPointer body;     // The address of the first byte.
};
typedef struct elm_large_byte_header LargeByteHeader;
static_assert(sizeof(LargeStringHeader) == 16, "LargeStringHeader must be 16 bytes");
static_assert(sizeof(LargeByteHeader) == 16, "LargeByteHeader must be 16 bytes");

// These accessors are the only code that reads a large body; check-large-body-access.sh rejects
// `->body` elsewhere. Resolving a body as an object would read its first payload bytes as a Header.
// The pointers they return stay valid while the body is live; a body never moves.

// The distance in bytes from a large body's address to its first payload unit. The body has no
// header, so it is zero.
constexpr size_t kLargeBodyPayloadOffset = 0;
// Returns the address of the body of the large String `h`. `h` must not be null.
inline void* largeBodyAddr(const LargeStringHeader* h) { return hpToAddr(h->body); }
// Returns the address of the body of the large Bytes `h`. `h` must not be null.
inline void* largeBodyAddr(const LargeByteHeader* h) { return hpToAddr(h->body); }
// Returns the UTF-16 units of the large String `h`; there are `h->header.size` of them.
inline u16* largeStringChars(const LargeStringHeader* h) {
    return reinterpret_cast<u16*>(static_cast<char*>(largeBodyAddr(h)) + kLargeBodyPayloadOffset);
}
// Returns the bytes of the large Bytes `h`; there are `h->header.size` of them.
inline u8* largeBytesData(const LargeByteHeader* h) {
    return reinterpret_cast<u8*>(static_cast<char*>(largeBodyAddr(h)) + kLargeBodyPayloadOffset);
}
// Returns the UTF-16 units of `obj`, which must be an `ElmString` or a `LargeStringHeader`. The
// pointer is into `obj` itself for an `ElmString`, so it is valid only until the next collection
// that may move `obj`.
inline u16* flatStringChars(void* obj) {
    if (static_cast<Header*>(obj)->tag == Tag_LargeStringHeader)
        return largeStringChars(static_cast<LargeStringHeader*>(obj));
    return static_cast<ElmString*>(obj)->chars;
}

/**
 * Bytes that are a run of the bytes of a `ByteBuffer` or `LargeByteHeader`, shared rather than
 * copied.
 *
 * `header.size` is the length of the run and `offset` its first index in `base`'s bytes. `base` is
 * the only field a collector traces; `header.unboxed` is 0.
 */
struct ALIGN(8) elm_bytebuffer_slice {
    Header header;
    HPointer base;
    u32 offset;
    u32 _padding;
};
typedef struct elm_bytebuffer_slice ElmByteBufferSlice;
static_assert(sizeof(ElmByteBufferSlice) == 24, "ElmByteBufferSlice must be 24 bytes");

/**
 * A pair. `header.unboxed` holds the kinds of `a` and `b`.
 */
typedef struct {
    Header header; // Header.unboxed holds the kinds of the fields.
    Unboxable a;
    Unboxable b;
} Tuple2;

/**
 * A triple. `header.unboxed` holds the kinds of `a`, `b` and `c`.
 */
typedef struct {
    Header header; // Header.unboxed holds the kinds of the fields.
    Unboxable a;
    Unboxable b;
    Unboxable c;
} Tuple3;

/**
 * A non-empty list cell. `header.unboxed` bits 1:0 hold the kind of `head`; `tail` is always
 * boxed, and is Nil, another `Cons` or a `ConsChunk`.
 */
typedef struct {
    Header header; // Header.unboxed bits 1:0 hold the kind of `head`.
    Unboxable head;
    HPointer tail;
} Cons;

/**
 * A non-empty list whose first elements are a run of a `ListBacking`, followed by `next`.
 *
 * The run is `backing->elems[offset, offset + k)`, where k is the smaller of `len` and the
 * backing's capacity less `offset`. `len` is the length of the whole list, run and `next`
 * together, and the rule is `len == k + length(next)`: when `len` does not exceed the run, `next`
 * is Nil. Taking a prefix therefore makes a new `ConsChunk` with a smaller `len` and Nil `next`.
 * `next` is Nil, a `Cons` or another `ConsChunk`. Nothing here enforces the rule; the code that
 * builds a chunk must keep it.
 */
typedef struct {
    Header header;    // Header.unboxed bits 1:0 = element kind, the same as the backing's.
    HPointer backing; // -> Tag_ListBacking.
    u32 offset;       // First live index in the backing.
    u32 len;          // Total logical length of this list value (>= 1).
    HPointer next;    // Rest of the spine after this chunk's run.
} ConsChunk;

/**
 * The elements that `ConsChunk` nodes share, all of one kind.
 *
 * `header.size` is the capacity in elements, and `header.unboxed` bits 1:0 the kind of every
 * element. The live elements are `elems[hd, capacity)`; slots below `hd` are uninitialized and
 * must not be traced. A `ListBacking` is not changed once Elm code can see it.
 */
typedef struct {
    Header header;  // header.size = capacity (element count); unboxed bits 1:0 = kind.
    u32 hd;         // The first live element.
    u32 _pad;
    Unboxable elems[];
} ListBacking;

/**
 * A value of a custom type built by a constructor with at least one field.
 *
 * `header.size` is the number of fields, and `header.unboxed` is K, the number of extension kind
 * words that follow `values[header.size]` for fields from `CUSTOM_HDR_SLOTS` on. Read a field's
 * kind with `customSlotKind`.
 */
typedef struct {
    Header header;           // Header.size contains field count.
    u64 ctor : CTOR_BITS;    // Constructor index within this Elm custom type.
    u64 unboxed : 48;        // Kinds of fields 0 to 23.
    Unboxable values[];
} Custom;

/**
 * A record.
 *
 * `header.size` is the number of fields, and `header.unboxed` is K, the number of extension kind
 * words that follow `values[header.size]` for fields from `RECORD_HDR_SLOTS` on. Read a field's
 * kind with `recordSlotKind`.
 */
typedef struct {
    Header header; // Header.size contains field count.
    u64 unboxed; // Kinds of fields 0 to 31.
    Unboxable values[];
} Record;

/**
 * A record whose field names are given at run time by a `FieldGroup`.
 *
 * `header.size` is the number of values. Every value is traced as an HPointer; `unboxed` is not
 * read by the collector's walkers.
 */
typedef struct {
    Header header;
    u64 unboxed; // Not read by the collector; every value is treated as boxed.
    HPointer fieldgroup;
    HPointer values[];
} DynRecord;

/**
 * The field names of a `DynRecord`: `count` 32-bit field identifiers. It holds no HPointers.
 */
typedef struct {
    Header header;
    u32 count;
    u32 fields[];
} FieldGroup;

// The type of an evaluator's generic entry, which takes its arguments as an array of words.
typedef void *(*EvalFunction)(void *[]);

/**
 * The static description of one evaluator, the compiled function a `Closure` calls.
 *
 * Compiled code emits one beside each evaluator as static data; it is not a heap object and is
 * never collected or traced. A `Closure` refers to one through `evaluator`. Its layout is fixed:
 * the compiler emits it and hard-codes `sat` at offset 24, which the assertions after `Closure`
 * check.
 *
 * `sat[N]` is the entry for a call that supplies exactly N new arguments to a closure of this
 * evaluator: it reads the closure's captures in place and calls the target directly. `sat` has
 * `stage_arity + 1` entries when `stage_arity <= SAT_MAX_ARITY`, and none otherwise, so a caller
 * must check `max_values <= SAT_MAX_ARITY` before reading it. An entry with no generated function
 * is null.
 */
struct EvaluatorDesc {
    EvalFunction   generic;      // +0   the entry taking an argument array
    u64            kinds;        // +8   advisory: 2 bits/param, params 0..31 only
    unsigned char  _pad_sa;      // +16  padding, 0
    unsigned char  result_kind;  // +17  ParamKind the evaluator returns
    unsigned short stage_arity;  // +18  <= CLOSURE_MAX_ARITY
    unsigned int   _pad1;        // +20
    void*          sat[];        // +24  sat[0..stage_arity] if stage_arity <= SAT_MAX_ARITY, else empty; sat[0] unused
};

/**
 * A function value: an evaluator together with the arguments already applied to it.
 *
 * `max_values` is the stage arity, the number of arguments the evaluator takes, and `n_values` the
 * number already held in `values`; the closure is saturated when the two are equal.
 *
 * The kinds of parameters 0 to 19 are in `unboxed`. The kinds of the rest are in K =
 * `extWords(max_values, CLOSURE_HDR_SLOTS)` extension kind words, which are the last K words of
 * the object. `header.size` counts the value slots allocated plus K, so the object's size follows
 * from its header word. Read kinds through `closureSlotKind` or `ClosureKinds`.
 */
typedef struct {
    Header header;           // header.size = allocated value slots + K
    u64 n_values   : 11;     // Arguments already applied.
    u64 max_values : 11;     // Stage arity.
    u64 result_kind: 2;      // The ParamKind the evaluator returns at the C ABI: 0 boxed, 1 Int,
                             // 2 Float, 3 Char (a uint32_t code point). Every closure call
                             // entry point reads it to pick the function-pointer type.
    u64 unboxed    : 40;     // Kinds of parameters 0 to 19.
    const EvaluatorDesc* evaluator;   // Static data, not a heap pointer.
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

// ---- Wide-object slot-kind accessors ----
// For Custom and Record, K is `header.unboxed`, and a slot whose extension word index is K or more
// reads as boxed. Each accessor is split in two: the common case is forced inline, and the case
// that reads an extension word is a separate cold function.
//
// The pointers these return point into the object and are valid only until it may next move.

// Returns the first extension kind word of `c`.
inline const u64* customExtWords(const Custom* c) { return reinterpret_cast<const u64*>(&c->values[c->header.size]); }
// Returns the first extension kind word of `r`.
inline const u64* recordExtWords(const Record* r) { return reinterpret_cast<const u64*>(&r->values[r->header.size]); }
// Returns the first extension kind word of `c`, for writing.
inline u64* customExtWordsMut(Custom* c) { return reinterpret_cast<u64*>(&c->values[c->header.size]); }
// Returns the first extension kind word of `r`, for writing.
inline u64* recordExtWordsMut(Record* r) { return reinterpret_cast<u64*>(&r->values[r->header.size]); }
// Returns the kind of field `i` of `c` from its extension words. `i` must be at least
// `CUSTOM_HDR_SLOTS`.
[[gnu::noinline, gnu::cold]] inline u32 customExtSlotKind(const Custom* c, u32 i) {
    const u32 r = i - CUSTOM_HDR_SLOTS;
    const u32 j = r / SLOTS_PER_EXT_WORD;
    if (j >= c->header.unboxed) return 0u;   // bounded by the stored K
    return kindInWord(customExtWords(c)[j], r % SLOTS_PER_EXT_WORD);
}
// Returns the kind of field `i` of `c`.
[[gnu::always_inline]] inline u32 customSlotKind(const Custom* c, u32 i) {
    if (__builtin_expect(i < CUSTOM_HDR_SLOTS, 1)) return kindInWord(c->unboxed, i);
    return customExtSlotKind(c, i);
}
// Returns the kind of field `i` of `r` from its extension words. `i` must be at least
// `RECORD_HDR_SLOTS`.
[[gnu::noinline, gnu::cold]] inline u32 recordExtSlotKind(const Record* r, u32 i) {
    const u32 q = i - RECORD_HDR_SLOTS;
    const u32 j = q / SLOTS_PER_EXT_WORD;
    if (j >= r->header.unboxed) return 0u;
    return kindInWord(recordExtWords(r)[j], q % SLOTS_PER_EXT_WORD);
}
// Returns the kind of field `i` of `r`.
[[gnu::always_inline]] inline u32 recordSlotKind(const Record* r, u32 i) {
    if (__builtin_expect(i < RECORD_HDR_SLOTS, 1)) return kindInWord(r->unboxed, i);
    return recordExtSlotKind(r, i);
}
// Splits `W` physical value words into `n` slots and `k` extension kind words, where
// `W = n + extWords(n, cap)`, and returns whether that is possible.
//
// W grows strictly with n, so a split is unique when it exists. Some W have none, and for them
// the result is false and `n` and `k` are not written.
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
// Returns the kind word for the first `cap` (at most 32) of the `n` kinds at `kinds`.
inline u64 packHeaderKinds(const u8* kinds, u32 n, u32 cap) {
    u64 w = 0;
    for (u32 i = 0; i < n && i < cap; ++i) w |= u64(kinds[i] & 3u) << (2 * i);
    return w;
}
// Writes the kinds `kinds[cap, n)` into the `extWords(n, cap)` words at `ext`, zeroing every one
// of them first, unused bits included (HEAP_077).
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
// 32 KiB is the code generator's threshold for allocating an object directly in the old
// generation, repeated here because this header cannot include the code generator.
static_assert(sizeof(Custom) + (CUSTOM_MAX_FIELDS + 63) * 8 < 32 * 1024, "wide Custom stays below born-old LOT");
static_assert(sizeof(Record) + (RECORD_MAX_FIELDS + 63) * 8 < 32 * 1024, "wide Record stays below born-old LOT");
// Returns the first extension kind word of `cl`, which is the K-th word from the end of the object.
inline const u64* closureExtWords(const Closure* cl) {
    return reinterpret_cast<const u64*>(
        &cl->values[cl->header.size - extWords(cl->max_values, CLOSURE_HDR_SLOTS)]);
}
// Returns the kind of parameter `i` of `cl` from its extension words. `i` must be at least
// `CLOSURE_HDR_SLOTS`.
[[gnu::noinline, gnu::cold]] inline u32 closureExtSlotKind(const Closure* cl, u32 i) {
    const u32 j = (i - CLOSURE_HDR_SLOTS) / SLOTS_PER_EXT_WORD;
    if (j >= extWords(cl->max_values, CLOSURE_HDR_SLOTS)) return 0u;
    return kindInWord(closureExtWords(cl)[j], (i - CLOSURE_HDR_SLOTS) % SLOTS_PER_EXT_WORD);
}
// Returns the kind of parameter `i` of `cl`. A loop that may allocate, and so move `cl`, must use
// `ClosureKinds` instead.
[[gnu::always_inline]] inline u32 closureSlotKind(const Closure* cl, u32 i) {
    if (__builtin_expect(i < CLOSURE_HDR_SLOTS, 1)) return kindInWord(cl->unboxed, i);
    return closureExtSlotKind(cl, i);
}
/**
 * A copy of a closure's parameter kinds, taken by `snapshotClosureKinds`, that stays valid when
 * the closure moves. Read it with `closureKindAt`.
 */
struct ClosureKinds {
    u64 hdr;        // The closure's `unboxed`.
    u32 max;        // max_values
    u32 k;          // The number of words of ext[] in use.
    u64 ext[64];
};
static_assert(extWords(CLOSURE_MAX_ARITY, CLOSURE_HDR_SLOTS) <= 64, "ClosureKinds::ext holds every ext word");
// Copies the parameter kinds of `cl` into `out`.
inline void snapshotClosureKinds(const Closure* cl, ClosureKinds& out) {
    out.hdr = cl->unboxed;
    out.max = cl->max_values;
    out.k = extWords(out.max, CLOSURE_HDR_SLOTS);
    const u64* ext = out.k ? closureExtWords(cl) : nullptr;
    for (u32 j = 0; j < out.k; ++j) out.ext[j] = ext[j];
}
// Returns the kind of parameter `slot` recorded in `ks`.
inline u32 closureKindAt(const ClosureKinds& ks, u32 slot) {
    if (slot < CLOSURE_HDR_SLOTS) return kindInWord(ks.hdr, slot);
    const u32 j = (slot - CLOSURE_HDR_SLOTS) / SLOTS_PER_EXT_WORD;
    return j < ks.k ? kindInWord(ks.ext[j], (slot - CLOSURE_HDR_SLOTS) % SLOTS_PER_EXT_WORD) : 0u;
}
// Returns whether `cl` is well formed: `n_values <= max_values <= CLOSURE_MAX_ARITY`,
// `header.size` covers the applied values and the K extension words, and no kind bits are set
// in the last extension word past parameter `max_values - 1`.
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

/**
 * The representation of an evaluator parameter or result at the C ABI. The values equal the
 * 2-bit slot kinds.
 */
enum ParamKind : unsigned char {
    PK_Boxed  = 0,
    PK_Int    = 1,
    PK_Float  = 2,
    PK_Char   = 3,
};

/**
 * The parameter and result kinds of an evaluator, as static data.
 *
 * `kinds` holds `num_params` `ParamKind` values, and `result_kind` is the `ParamKind` the
 * evaluator returns. The layout is fixed, as the assertions below check, because compiled code
 * emits these.
 */
struct EvalParamLayout {
    unsigned short num_params;   // +0
    unsigned char  result_kind;  // +2  ParamKind: the evaluator's return kind
    unsigned char  _pad;         // +3
    unsigned char  kinds[];      // +4  flexible array member, length = num_params
};
#ifdef __cplusplus
static_assert(offsetof(EvalParamLayout, num_params) == 0, "num_params at +0");
static_assert(offsetof(EvalParamLayout, result_kind) == 2, "result_kind at +2");
static_assert(offsetof(EvalParamLayout, kinds) == 4, "kinds at +4");
/**
 * An `EvalParamLayout` with `N` kinds, for runtime code to declare as a constant. Pass one where an
 * `EvalParamLayout` is wanted through `asLayout`.
 */
template <unsigned N> struct EvalParamLayoutN {
    unsigned short num_params;
    unsigned char  result_kind;
    unsigned char  _pad;
    unsigned char  kinds[N];
};
// Returns the layout with result kind `rk` and the `N` parameter kinds `k`.
template <unsigned N>
constexpr EvalParamLayoutN<N> makeEvalParamLayout(unsigned char rk, const unsigned char (&k)[N]) {
    EvalParamLayoutN<N> l{};
    l.num_params = static_cast<unsigned short>(N);
    l.result_kind = rk;
    for (unsigned i = 0; i < N; ++i) l.kinds[i] = k[i];
    return l;
}
// Returns `p` viewed as an `EvalParamLayout`, valid as long as `*p`.
template <unsigned N>
inline const EvalParamLayout* asLayout(const EvalParamLayoutN<N>* p) {
    static_assert(offsetof(EvalParamLayoutN<N>, kinds) == offsetof(EvalParamLayout, kinds),
                  "EvalParamLayoutN is layout-compatible with EvalParamLayout");
    return reinterpret_cast<const EvalParamLayout*>(p);
}
#endif

/**
 * An Elm process. `id` is a full 64-bit word.
 */
typedef struct {
    Header header;
    u64 id;
    HPointer root;
    HPointer stack;
    HPointer mailbox;
} Process;
static_assert(sizeof(Process) == 40, "Process layout: header, id word, 3 HPointers");

/**
 * An Elm task.
 *
 * `header.unboxed` bits 1:0 hold the kind of `value`, which may be boxed or unboxed. `callback`,
 * `kill` and `task` are always boxed.
 */
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

/**
 * The word a collector writes over the header of an object it has moved, giving the new address.
 *
 * `tag` is `Tag_Forward` and `forward_ptr` is the new address divided by 8; use
 * `decodeForwardPtr`. A forward word exists only during a collection (HEAP_006). A `forward_ptr`
 * of 0 marks an object that a parallel collector is still copying.
 */
typedef struct {
    struct {
        u64 tag : TAG_BITS;           // Tag_Forward.
        u64 color : 2;                // u64 like the other fields, so that they pack into one word.
        u64 forward_ptr : POINTER_BITS;  // New address >> 3.
        u64 unused : 17;
    } header;
} Forward;

// ============================================================================
// Binary Data Types
// ============================================================================

/**
 * Bytes held in the object. `header.size` is the length in bytes. It holds no HPointers.
 *
 * Bytes of length 0 are never allocated; the empty Bytes is the Empty constant (HEAP_071).
 */
struct ALIGN(8) elm_bytebuffer {
    Header header;  // header.size = byte count
    u8 bytes[];
};
typedef struct elm_bytebuffer ByteBuffer;

/**
 * An all-ASCII String that is a run of the bytes of another object, shared rather than copied.
 *
 * Every byte is below 0x80 and so is one UTF-16 unit, which makes `header.size`, the length in
 * UTF-16 units, equal to `byteLen`. `base` is a `ByteBuffer`, a `LargeByteHeader` (the header
 * object, never its body) or an `ElmStringUtf8Leaf`, and is the only field a collector traces.
 * Nothing here checks that the bytes are ASCII; the code that makes one must.
 */
struct ALIGN(8) elm_string_utf8_view {
    Header header;
    HPointer base;
    u32 offset;    // byte offset into base's payload
    u32 byteLen;   // == header.size
};
typedef struct elm_string_utf8_view ElmStringUtf8View;
static_assert(sizeof(ElmStringUtf8View) == 24, "ElmStringUtf8View must be 24 bytes");

/**
 * An all-ASCII String held in the object, one byte per character, with no terminating nul.
 * `header.size` is both the length in bytes and in UTF-16 units. It holds no HPointers.
 */
struct ALIGN(8) elm_string_utf8_leaf {
    Header header;  // header.size = byte count == UTF-16 unit count
    u8 bytes[];     // Each below 0x80.
};
typedef struct elm_string_utf8_leaf ElmStringUtf8Leaf;

/**
 * An array of Elm values, all of one kind.
 *
 * `header.size` is the capacity in elements, which decides the object's size, and `length` is
 * the number in use; the slots past `length` are uninitialized. `header.unboxed` bits 1:0 are the
 * kind of every element, and a collector traces `elements[0, length)` only when that kind is
 * boxed.
 */
typedef struct {
    Header header;     // header.size = capacity; header.unboxed bits 1:0 = element kind
    u32 length;        // Elements in use.
    u32 padding;
    Unboxable elements[];
} ElmArray;

/**
 * Most heap object layouts (not ConsChunk or ListBacking), for code that needs one type spanning
 * them. Its size is not the size of any object.
 */
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
