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
#define ID_BITS 16

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
    Tag_Forward,
    // Tag_ByteBuffer - Buffers of bytes or UTF-8 encoded strings.
    // Tag_Slice - String or even List or Array or Bytes slice.
    // Tag_Array - Packed arrays.
    // Tag_Tensor - Tensors.
} Tag;

// Heap header that every heap object must have.
typedef struct {
    u32 tag : TAG_BITS;
    u32 color : 2; // Black, white, grey for concurrent mark and sweep.
    u32 pin : 1; // Memory-pinned object.
    u32 epoch : 2; // Object marked during this GC cycle.
    u32 age : 2; // Number of GC cycles survived.
    u32 unboxed : 3; // Unboxed flags for cons, tuple2, tuple3 only.
    u32 padding : 1;
    u32 refcount : 16; // Reference count.
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
    Const_Nil,
    Const_Nothing,
    Const_EmptyString
} Constant;

// A logical pointer into the heap.
typedef struct {
    u64 ptr : POINTER_BITS;
    u64 constant : 4; // Index of embedded Elm constant (0 = regular pointer).
    u64 padding : 20; // Reserved for future use.
} HPointer;
static_assert(sizeof(HPointer) == 8, "HPointer must be 64 bits");

// A pointer or unboxed primitive. Used when there is an "unboxed" bitmap in a structure.
// The bitmap describes which fields are boxed or unboxed.
typedef union {
    HPointer p;
    i64 i;
    f64 f;
    u16 c;
} Unboxable;
static_assert(sizeof(Unboxable) == 8, "Unboxable must be 64 bits");

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
    u16 padding1;
    u16 padding2;
    u16 padding3;
} ElmChar;

// Note: Empty strings use Const_EmptyString constant instead of heap allocation.
// This prevents the issue where an 8-byte empty string would be overwritten by
// a 16-byte forward pointer, corrupting adjacent heap objects.

// Make sure strings are properly aligned on 64-bit target.
// Otherwise the C compiler can truncate any zero padding at the end.
#define ALIGN(X) __attribute__((aligned(X)))
struct ALIGN(8) elm_string {
    Header header; // Size in header, up to 4G characters.
    u16 chars[];
};
typedef struct elm_string ElmString;

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
    Header header; // Header.size contains field count (up to 63).
    u64 ctor : CTOR_BITS;
    u64 unboxed : 48; // Bitmap indicating which of the first 48 fields are unboxed.
    Unboxable values[];
} Custom;

typedef struct {
    Header header; // Header.size contains field count (up to 127).
    u64 unboxed; // Bitmap indicating which of the first 64 fields are unboxed.
    Unboxable values[];
} Record;

typedef struct {
    Header header;
    u64 unboxed; // Bitmap indicating which of the first 64 fields are unboxed.
    HPointer fieldgroup;
    HPointer values[];
} DynRecord;

typedef struct {
    Header header;
    u32 count;
    u32 fields[];
} FieldGroup;

typedef void *(*EvalFunction)(void *[]);

typedef struct {
    Header header;
    u64 n_values : 6;      // Number of captured values currently stored.
    u64 max_values : 6;    // Maximum number of values this closure can hold.
    u64 unboxed : 52;      // Bitmap indicating which captured values are unboxed.
    EvalFunction evaluator;
    Unboxable values[];
} Closure;

typedef struct {
    Header header;
    u64 id : ID_BITS;
    u64 padding : 48;
    HPointer root;
    HPointer stack;
    HPointer mailbox;
} Process;

typedef struct {
    Header header;
    u64 ctor : CTOR_BITS;
    u64 id : ID_BITS;
    u64 padding : 32;
    HPointer value;
    HPointer callback;
    HPointer kill;
    HPointer task;
} Task;

// Forward object for compaction - uses special header layout.
// The header fields are repurposed: tag identifies it as Forward,
// and the remaining bits store the forwarding pointer.
typedef struct {
    struct {
        u64 tag : TAG_BITS;           // Tag_Forward (identifies this as a forwarding pointer).
        u64 color : 2;                // Must use u64 to match other bitfields for correct packing.
        u64 forward_ptr : POINTER_BITS;  // Logical pointer offset to new location.
        u64 unused : 17;              // Unused bits (could store metadata if needed).
    } header;
    // No additional fields - this replaces the evacuated object's header.
} Forward;

typedef union HeapValue {
    ElmInt intval;
    ElmFloat floatval;
    ElmChar charval;
    ElmString string;
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
} HeapValue;

} // namespace Elm

#endif // ECO_HEAP_H
