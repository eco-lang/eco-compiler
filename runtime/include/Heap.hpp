#ifndef ECO_HEAP_H
#define ECO_HEAP_H

#include <assert.h>

namespace Elm {

typedef unsigned long long int u64;
typedef unsigned int u32;
typedef unsigned short u16;
typedef long long int i64;
typedef double f64;

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

// Default bit widths.
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
    u32 epoch : 2; // Object marked this cycle.
    u32 age : 2; // Survival age.
    u32 unboxed : 3; // Unboxed flags for cons, tuple2, tuple3 only.
    u32 padding : 1;
    u32 refcount : 16; // Reference count; 16 bits is more than needed.
    u32 size; // Size bits.
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
    u64 constant : 4; // For frequently used Elm constants.
    u64 padding : 20; // Spare space.
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

typedef struct {
    Header header;
    f64 value;
} ElmFloat;

typedef struct {
    Header header;
    i64 value;
} ElmInt;

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
    Header header; // Contains unboxed bits for tuples.
    Unboxable a;
    Unboxable b;
} Tuple2;

typedef struct {
    Header header; // Contains unboxed bits for tuples.
    Unboxable a;
    Unboxable b;
    Unboxable c;
} Tuple3;

typedef struct {
    Header header; // Contains unboxed bits for cons.
    Unboxable head;
    HPointer tail;
} Cons;

typedef struct {
    Header header; // Size in bottom 6 bits of size in header, but unboxed bitset in next word.
    u64 ctor : CTOR_BITS;
    u64 unboxed : 48; // First 48 fields can be unboxed, so compiler can sort primitive fields to come first.
    Unboxable values[];
} Custom;

typedef struct {
    Header header; // Size in bottom 7 bits of size in header, but unboxed bitset in next word.
    u64 unboxed; // First 64 fields can be unboxed, so compiler should sort primitive fields to come first.
    Unboxable values[];
} Record;

typedef struct {
    Header header;
    u64 unboxed; // First 64 fields can be unboxed, so compiler should sort primitive fields to come first.
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
    u64 n_values : 6;
    u64 max_values : 6;
    u64 unboxed : 52;
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
