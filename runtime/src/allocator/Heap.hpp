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
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace Elm {

// ============================================================================
// Primitive Type Aliases
// ============================================================================

typedef unsigned long long int u64;  // 64-bit unsigned integer.
typedef unsigned int u32;            // 32-bit unsigned integer.
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
    // Split-header forms for large strings / byte buffers. The header (these
    // tags) lives in the nursery, while the body (Tag_String / Tag_ByteBuffer)
    // lives in old gen and is never copied. See HEAP_026 and
    // plans/large-object-split-header-bodies.md.
    Tag_LargeStringHeader, // header.size = logical UTF-16 length, body -> Tag_String.
    Tag_LargeByteHeader,   // header.size = logical byte count,    body -> Tag_ByteBuffer.
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
//   - The 8-byte heap-base sentinel installed by `installHeapBaseSentinel`
//     is EXEMPT from the `age & 1` convention: it carries `age = 0` and is
//     identified by address (`isHeapBasePage`), not by the age bit.
typedef struct {
    u32 tag : TAG_BITS;
    u32 color : 2; // White, Grey, or Black for tri-color mark-and-sweep.
    u32 pin : 1; // Memory-pinned object (prevents relocation).
    u32 age : 2; // Nursery promotion counter; doubles as on-free-list
                 // sentinel for Tag_Free cells (see above).
    u32 unboxed : 6; // 2 bits per slot; used by Cons/Tuple2/Tuple3/ElmArray.
    u32 refcount : 16; // Reference count (unused currently).
    u32 size; // Object size in type-specific units.
} Header;
static_assert(sizeof(Header) == 8, "Header must be 64 bits");

// Frequently used constants in Elm can be embedded directly into HPointer.
// There is no need to trace a pointer to reach them.
typedef enum {
    Const_Unit,
    Const_EmptyRec,
    Const_True,
    Const_False,
    Const_Nil, // Empty list
    Const_Nothing,
    Const_EmptyString
} Constant;

// A logical pointer into the heap.
typedef struct {
    u64 ptr : POINTER_BITS;
    u64 constant : 4; // Embedded constant index (0 means regular pointer, 1-15 encode constants).
    u64 padding : 20; // Reserved for future use.
} HPointer;
static_assert(sizeof(HPointer) == 8, "HPointer must be 64 bits");

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
    return (bitmap >> (2 * index)) & 0x3ULL;
}

inline u32 tupleFieldKind(u32 headerUnboxed, unsigned index) {
    return (headerUnboxed >> (2 * index)) & 0x3U;
}

inline u64 bitmapSetKind(u64 bitmap, unsigned index, u64 kind) {
    const u64 shift = 2ULL * index;
    const u64 mask  = 0x3ULL << shift;
    return (bitmap & ~mask) | ((kind & 0x3ULL) << shift);
}

// Derives a 1-bit-per-slot HPointer mask from a 2-bit-per-slot kind bitmap.
// Output bit i is set iff the kind at slot i is 0 (boxed).
inline u64 pointerMaskFromKindBitmap(u64 kindBitmap, unsigned numSlots) {
    u64 mask = 0;
    for (unsigned i = 0; i < numSlots; ++i) {
        if (fieldKind(kindBitmap, i) == 0) mask |= (1ULL << i);
    }
    return mask;
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

typedef struct {
    Header header;           // Header.size contains field count.
    u64 ctor : CTOR_BITS;    // Constructor index within this Elm custom type (16 bits).
    u64 unboxed : 48;        // Bitmap: bit N set means field N is unboxed (max 48 fields with unboxing).
    Unboxable values[];
} Custom;

typedef struct {
    Header header; // Header.size contains field count.
    u64 unboxed; // Bitmap: bit N set means field N is unboxed (max 64 fields with unboxing).
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
typedef struct {
    Header header;
    u64 n_values  : 6;     // Applied arity: args already captured for this stage (0-63).
    u64 max_values: 6;     // Stage arity: total args this evaluator expects (0-63).
    u64 unboxed   : 52;    // 2-bit-per-slot kinds for captures 0..25 (52 = 26 slots).
    EvalFunction evaluator;
    Unboxable values[];
} Closure;

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
/// `kinds[i] == ParamKind`. The capability bit "evaluator accepts typed
/// newargs without re-boxing" lives on `Closure::flags`, not here — the
/// caller cannot statically know what evaluator a dynamically-dispatched
/// closure has, so the gate must be readable from the closure header.
/// Memory layout: { num_params: u8, kinds[num_params]: u8[] }
struct EvalParamLayout {
    unsigned char num_params;
    unsigned char kinds[];  // flexible array member, length = num_params
};

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

typedef unsigned char u8;  // 8-bit unsigned byte.

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
} HeapValue;

} // namespace Elm

#endif // ECO_HEAP_H
