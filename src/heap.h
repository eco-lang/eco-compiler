#ifndef ECO_RUNTIME_HEAP_H
#define ECO_RUNTIME_HEAP_H

#include <stdint.h>

typedef unsigned char u16;
typedef long long int i64;
typedef double f64;
typedef unsigned int u32;

/** Headers are always 64-bits in size, and every heap element always has a
header at its start. The first 5-bits contain a tag, denoting which kind of
heap element it is.

Pointers are 40 bits, allowing > 8 Terrabytes address space. This also allows
for a tag and pointer to be fitted into a 64-bit word, and leaves space for
other bit annotations against pointers that may be use for garbage colection.
*/

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

// Default Bit widths
#define TAG_BITS         5
#define CTOR_BITS       16
#define POINTER_BITS    40
#define ID_BITS         16

typedef struct {
  uint64_t tag     : TAG_BITS;
} Header_Tagged; // ElmInt, ElmFloat, ElmChar

typedef struct {
  uint64_t tag     : TAG_BITS;
  uint64_t unboxed : 3;
} Header_UnboxedOnly; // Tuple2, Tuple3

typedef struct {
  uint64_t tag    : TAG_BITS;
  uint64_t size   : 32;
} Header_SizeOnly; // DynCons, ElmString, Record, DynRecord, FieldGroup

typedef struct {
  uint64_t tag     : TAG_BITS;
  uint64_t size    : 27;
  uint64_t unboxed : 32;
} Header_SizeUnboxed; // Cons, RecordSmall

typedef struct {
  uint64_t tag     : TAG_BITS;
  uint64_t size    : 8;
  uint64_t ctor    : CTOR_BITS;
  uint64_t unboxed : 35; // Considered padding by Custom
} Header_Custom; // CustomSmall, Custom

typedef struct {
  uint64_t tag       : TAG_BITS;
  uint64_t n_values  : 6;
  uint64_t max_values: 6;
  uint64_t unboxed   : 47;
} Header_Closure; // Closure

typedef struct {
  uint64_t tag     : TAG_BITS;
  uint64_t id      : ID_BITS;
} Header_Process; // Process

typedef struct {
  uint64_t tag     : TAG_BITS;
  uint64_t ctor    : CTOR_BITS;
  uint64_t id      : ID_BITS;
} Header_Task; // Task

typedef struct {
  uint64_t tag     : TAG_BITS;
  uint64_t pointer : POINTER_BITS;
  uint64_t padding : 19; // Spare space for GC flags
} Header_GCForward; // GCForward

typedef union {
  Header_Tagged       tagged_only;
  Header_UnboxedOnly  unboxed_only;
  Header_SizeOnly     size_only;
  Header_SizeUnboxed  size_unboxed;
  Header_Custom       custom;
  Header_Closure      closure;
  Header_Process      process;
  Header_Task         task;
  Header_GCForward    gcforward;
} HeaderUnion;

typedef struct {
  HeaderUnion bits;
} Header;

#include <assert.h>
_Static_assert(sizeof(Header) == 8, "HeapHeader must be 64 bits");

typedef struct {
  uint64_t ptr      : POINTER_BITS;
  uint64_t padding  : 24;       // Spare space for GC bits.
} HPointer;

typedef union {
  HPointer p;
  i64      i;
  f64      f;
  u16      c;
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
// Otherwise C compiler can truncate the zero padding at the end.
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
  void* head;
  void* tail;
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
  uint32_t count;
  uint32_t fields[];
} FieldGroup;

typedef void* (*EvalFunction)(void*[]);

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
} GCForward;

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
  GCForward fwd;
} HeapValue;


// STATIC CONSTANTS

extern CustomSmall Nil;
extern void* pNil;

extern CustomSmall Unit;
extern void* pUnit;

extern CustomSmall False;
extern void* pFalse;

extern CustomSmall True;
extern void* pTrue;


#endif // ECO_RUNTIME_HEAP_H
