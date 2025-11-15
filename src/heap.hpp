#ifndef ECO_HEAP_H
#define ECO_HEAP_H

#include <assert.h>

namespace Elm {

typedef unsigned long long int u64;
typedef unsigned int u32;
typedef unsigned char u16;
typedef long long int i64;
typedef double f64;

/** Headers are always 64-bits in size, and every heap element always has a
header at its start. The first 5-bits contain a tag, denoting which kind of
heap element it is.

Pointers are 40 bits, allowing > 8 Terrabytes address space. This also allows
for a tag and pointer to be fitted into a 64-bit word, and leaves space for
other bit annotations against pointers that may be use for garbage colection.
*/

// Default Bit widths
#define TAG_BITS 5
#define CTOR_BITS 16
#define POINTER_BITS 40
#define ID_BITS 16

typedef enum {
  Tag_Int,         // 0
  Tag_Float,       // 1
  Tag_Char,        // 2
  Tag_String,      // 3
  Tag_Tuple2,      // 4
  Tag_Tuple3,      // 5
  Tag_Cons,        // 6
  Tag_CustomSmall, // 7
  Tag_Custom,      // 8
  Tag_SmallRecord, // 9
  Tag_Record,      // 10
  Tag_DynRecord,   // 11
  Tag_FieldGroup,  // 12
  Tag_Closure,     // 13
  Tag_Process,     // 14
  Tag_Task,        // 15
// Tag_ByteBuffer - Buffers of bytes or UTF-8 encoded strings.
// Tag_Slice - String or even List or Array or Bytes slice.
// Tag_Array - Packed arrays
// Tag_Tensor - Tensors
} Tag;

// Heap header that every heap object must have.
typedef struct {
  u32 tag : TAG_BITS;
  u32 color : 2;       // Black, white, grey for concurrent mark and sweep.
  u32 pin : 1;         // Mem pinned object
  u32 forwarding : 1;  // Object evacuated this cycle.
  u32 epoch : 2;       // Object marked this cycle.
  u32 age : 2;         // Survival age.
  u32 unboxed : 3;     // Unboxed flags for cons, tuple2, tuple3 only.
  u32 size : 16;       // Size bits for smaller structures - records and custom type constructors.
  u32 refcount;
} Header;
static_assert(sizeof(Header) == 8, "Header must be 64 bits");

// Frequently used constants in Elm can be embeddede directly into HPointer, so there is no need to
// trace a pointer to reach them.
typedef enum {
  Const_Unit,
  Const_EmptyRec,
  Const_True,
  Const_False,
  Const_Nil,
  Const_Nothing,
} Constant;

// A logical pointer into the heap.
typedef struct {
  u64 ptr : POINTER_BITS;
  u64 constant : 4;  // For frequently used Elm constants.
  u64 padding : 20;  // Spare space.
} HPointer;
static_assert(sizeof(HPointer) == 8, "HPointer must be 64 bits");

// A pointer or unboxed primitive. Used when there is an "unboxed" bitmap in a structure, describing
// which fields are boxed or unboxed.
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

// Make sure strings are properly aligned on 64-bit target.
// Otherwise C compiler can truncate any zero padding at the end.
#define ALIGN(X) __attribute__((aligned(X)))
struct ALIGN(8) elm_string {
  Header header;
  u64 size : 40;
  u64 padding : 24;
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
  Header header;
  u64 ctor : CTOR_BITS;
  u64 unboxed : 48;
  Unboxable values[];
} CustomSmall;

typedef struct {
  Header header;
  u64 ctor : CTOR_BITS;
  u64 padding : 48;
  HPointer values[];
} Custom;

typedef struct {
  Header header;
  u64 unboxed;
  Unboxable values[];
} RecordSmall;

typedef struct {
  Header header;
  HPointer values[];
} Record;

typedef struct {
  Header header;
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

typedef struct {
  Header header;
  u64 pointer : POINTER_BITS;
  u64 padding : 24; // Spare space for more GC flags if needed.
} Forward;

typedef union HeapValue {
  ElmInt intval;
  ElmFloat floatval;
  ElmChar charval;
  ElmString string;
  Tuple2 tuple2;
  Tuple3 tuple3;
  Cons cons;
  CustomSmall custom_small;
  Custom custom;
  RecordSmall record_small;
  Record record;
  DynRecord dynrecord;
  FieldGroup fieldgroup;
  Closure closure;
  Process process;
  Task task;
  Forward fwd;
} HeapValue;

// STATIC CONSTANTS

extern CustomSmall Nil;
extern void *pNil;

extern CustomSmall Unit;
extern void *pUnit;

extern CustomSmall False;
extern void *pFalse;

extern CustomSmall True;
extern void *pTrue;
} // namespace Elm

#endif // ECO_HEAP_H
