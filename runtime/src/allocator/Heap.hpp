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
    Tag_ByteBuffer,  // Immutable byte array for binary data.
    Tag_Array,       // Mutable/growable array of Elm values.
    // Tag_Slice - String or even List or Array or Bytes slice (future).
    // Tag_Tensor - Tensors (future).
    Tag_Forward,     // Must be last - used for forwarding pointers during GC.
} Tag;

// Heap header that every heap object must have.
typedef struct {
    u32 tag : TAG_BITS;
    u32 color : 2; // White, Grey, or Black for tri-color mark-and-sweep.
    u32 pin : 1; // Memory-pinned object (prevents relocation).
    u32 epoch : 2; // GC epoch when this object was last marked.
    u32 age : 2; // Number of minor GC cycles survived.
    u32 unboxed : 3; // Unboxed flags for Cons, Tuple2, Tuple3 only.
    u32 padding : 1;
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
    Header header;           // Header.size contains field count (max 63).
    u64 ctor : CTOR_BITS;    // Constructor index within this Elm custom type (16 bits).
    u64 id : ID_BITS;        // Custom type id (global across program, 16 bits).
    u64 unboxed : 32;        // Bitmap: bit N set means field N is unboxed (max 32 fields).
    Unboxable values[];
} Custom;

typedef struct {
    Header header; // Header.size contains field count (max 127).
    u64 unboxed; // Bitmap: bit N set means field N is unboxed (primitive value).
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

typedef struct {
    Header header;
    u64 n_values : 6;      // Number of captured values currently stored (0-63).
    u64 max_values : 6;    // Maximum capacity for captured values (0-63).
    u64 unboxed : 52;      // Bitmap: bit N set means captured value N is unboxed.
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
 *   - unboxed = bitmap indicating which elements are unboxed primitives
 *   - elements[] = array of Unboxable values
 *
 * Capacity vs Length:
 *   - capacity (header.size) = total allocated slots
 *   - length = number of slots currently in use
 *   - Allows efficient push() without reallocating every time
 *
 * GC notes:
 *   - Must scan elements[0..length-1] for pointers
 *   - Check unboxed bitmap to skip unboxed primitives
 *   - When copying, only copy header + used elements (not full capacity)
 */
typedef struct {
    Header header;     // header.size = capacity (allocated element count)
    u32 length;        // Current number of elements in use
    u32 padding;       // Alignment padding
    u64 unboxed;       // Bitmap: bit N set means elements[N] is unboxed primitive
    Unboxable elements[];  // Flexible array of values (up to 64 elements with unboxing)
} ElmArray;

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
    ByteBuffer bytebuffer;
    ElmArray array;
} HeapValue;

} // namespace Elm

#endif // ECO_HEAP_H
