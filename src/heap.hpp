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
  Tag_DynCons,     // 7
  Tag_CustomSmall, // 8
  Tag_Custom,      // 9
  Tag_SmallRecord, // 10
  Tag_Record,      // 11
  Tag_DynRecord,   // 12
  Tag_FieldGroup,  // 13
  Tag_Closure,     // 14
  Tag_Process,     // 15
  Tag_Task,        // 16
} Tag;

typedef struct {
  u64 tag : TAG_BITS;
  u64 age : 2;
  u64 padding : 57;
} Header_Tagged; // ElmInt, ElmFloat, ElmChar
static_assert(sizeof(Header_Tagged) == 8, "Header_Tagged must be 64 bits");

typedef struct {
  u64 tag : TAG_BITS;
  u64 age : 2;
  u64 unboxed : 3;
  u64 padding : 54;
} Header_UnboxedOnly; // Tuple2, Tuple3
static_assert(sizeof(Header_UnboxedOnly) == 8, "Header_UnboxedOnly must be 64 bits");

typedef struct {
  u64 tag : TAG_BITS;
  u64 age : 2;
  u64 size : 32;
  u64 padding : 25;
} Header_SizeOnly; // DynCons, ElmString, Record, DynRecord, FieldGroup
static_assert(sizeof(Header_SizeOnly) == 8, "Header_SizeOnly must be 64 bits");

typedef struct {
  u64 tag : TAG_BITS;
  u64 age : 2;
  u64 size : 5;
  u64 unboxed : 32;
  u64 padding : 20;
} Header_SizeUnboxed; // Cons, RecordSmall
static_assert(sizeof(Header_SizeUnboxed) == 8, "Header_SizeUnboxed must be 64 bits");

typedef struct {
  u64 tag : TAG_BITS;
  u64 age : 2;
  u64 size : 8;
  u64 ctor : CTOR_BITS;
  u64 unboxed : 32; // Considered padding by Custom
  u64 padding : 1;
} Header_Custom;    // CustomSmall, Custom
static_assert(sizeof(Header_Custom) == 8, "Header_Custom must be 64 bits");

typedef struct {
  u64 tag : TAG_BITS;
  u64 age : 2;
  u64 n_values : 6;
  u64 max_values : 6;
  u64 unboxed : 32;
  u64 padding : 13;
} Header_Closure; // Closure
static_assert(sizeof(Header_Closure) == 8, "Header_Closure must be 64 bits");

typedef struct {
  u64 tag : TAG_BITS;
  u64 age : 2;
  u64 id : ID_BITS;
  u64 padding : 41;
} Header_Process; // Process
static_assert(sizeof(Header_Process) == 8, "Header_Process must be 64 bits");

typedef struct {
  u64 tag : TAG_BITS;
  u64 age : 2;
  u64 ctor : CTOR_BITS;
  u64 id : ID_BITS;
  u64 padding : 25;
} Header_Task; // Task
static_assert(sizeof(Header_Task) == 8, "Header_Task must be 64 bits");

typedef struct {
  u64 tag : TAG_BITS;
  u64 age : 2;
  u64 pointer : POINTER_BITS;
  u64 padding : 17; // Spare space for more GC flags
} Header_Forward; // Forward
static_assert(sizeof(Header_Forward) == 8, "Header_Forward must be 64 bits");

typedef union {
  Header_Tagged tagged_only;
  Header_UnboxedOnly unboxed_only;
  Header_SizeOnly size_only;
  Header_SizeUnboxed size_unboxed;
  Header_Custom custom;
  Header_Closure closure;
  Header_Process process;
  Header_Task task;
  Header_Forward Forward;
} HeaderUnion;

typedef struct {
  HeaderUnion bits;
} Header;
static_assert(sizeof(Header) == 8, "Header must be 64 bits");

// A logical pointer into the heap.
typedef struct {
  u64 ptr : POINTER_BITS;
  u64 color : 2;       // Black, white, grey
  u64 pin : 1;         // Mem pinned object
  u64 forwarding : 1;  // Nusery object forwarded
  u64 epoch : 2;       // Concurrent marking epoch.
  u64 padding : 18;    // Spare space for more GC bits.
} HPointer;
static_assert(sizeof(HPointer) == 8, "HPointer must be 64 bits");

// A pointer or unboxed primitive.
typedef union {
  HPointer p;
  i64 i;
  f64 f;
  u16 c;
} Unboxable;

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
  u16 chars[];
};
typedef struct elm_string ElmString;

typedef struct {
  Header header;
  Unboxable a;
  Unboxable b;
} Tuple2;

typedef struct {
  Header header;
  Unboxable a;
  Unboxable b;
  Unboxable c;
} Tuple3;

typedef struct {
  Header header;
  Unboxable head;
  HPointer tail;
} Cons;

typedef struct {
  Header header;
  void *head;
  void *tail;
} DynCons;

typedef struct {
  Header header;
  Unboxable values[];
} CustomSmall;

typedef struct {
  Header header;
  HPointer values[];
} Custom;

typedef struct {
  Header header;
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
  EvalFunction evaluator;
  Unboxable values[];
} Closure;

typedef struct {
  Header header;
  HPointer root;
  HPointer stack;
  HPointer mailbox;
} Process;

typedef struct {
  Header header;
  HPointer value;
  HPointer callback;
  HPointer kill;
  HPointer task;
} Task;

typedef struct {
  Header header;
} Forward;

typedef union HeapValue {
  ElmInt intval;
  ElmFloat floatval;
  ElmChar charval;
  ElmString string;
  Tuple2 tuple2;
  Tuple3 tuple3;
  Cons cons;
  DynCons dyncons;
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
