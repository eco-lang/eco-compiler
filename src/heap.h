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
#define SIZE_BITS       32
#define CTOR_BITS       16
#define POINTER_BITS    40
#define ID_BITS         16
#define NVAL_BITS        6
#define MAXVAL_BITS      6
#define UNBOXED_BITS    32

typedef struct {
  uint64_t tag     : TAG_BITS;
} Header_Tagged; // ElmInt, ElmFloat, ElmChar

typedef struct {
  uint64_t tag     : TAG_BITS;
  uint64_t unboxed : 3;
} Header_UnboxedOnly; // ElmTuple2, ElmTuple3

typedef struct {
  uint64_t tag    : TAG_BITS;
  uint64_t size   : SIZE_BITS;
} Header_SizeOnly; // ElmDynCons, ElmString, ElmRecord, ElmDynRecord, ElmFieldGroup

typedef struct {
  uint64_t tag     : TAG_BITS;
  uint64_t size    : 27;
  uint64_t unboxed : 32;
} Header_SizeUnboxed; // ElmCons, ElmRecordSmall

typedef struct {
  uint64_t tag     : TAG_BITS;
  uint64_t size    : 8;
  uint64_t ctor    : CTOR_BITS;
  uint64_t unboxed : 35; // Considered padding by ElmCustom
} Header_Custom; // ElmCustomSmall, ElmCustom

typedef struct {
  uint64_t tag       : TAG_BITS;
  uint64_t n_values  : NVAL_BITS;
  uint64_t max_values: MAXVAL_BITS;
  uint64_t unboxed   : 47;
} Header_Closure; // ElmClosure

typedef struct {
  uint64_t tag     : TAG_BITS;
  uint64_t id      : ID_BITS;
} Header_Process; // ElmProcess

typedef struct {
  uint64_t tag     : TAG_BITS;
  uint64_t ctor    : CTOR_BITS;
  uint64_t id      : ID_BITS;
} Header_Task; // ElmTask

typedef struct {
  uint64_t tag     : TAG_BITS;
  uint64_t pointer : POINTER_BITS;
} Header_GCForward; // ElmGCForward

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
  uint64_t ptr   : 40;
  uint64_t _pad  : 24;       // Reserved for GC bits.
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
} ElmTuple2;

typedef struct {
  Header header;
  Unboxable a;
  Unboxable b;
  Unboxable c;
} ElmTuple3;

typedef struct {
  Header header;
  Unboxable head;
  HPointer tail;
} ElmCons;

typedef struct {
  Header header;
  void* head;
  void* tail;
} ElmDynCons;

typedef struct {
  Header header;
  Unboxable values[];
} ElmCustomSmall;

typedef struct {
  Header header;
  HPointer values[];
} ElmCustom;

typedef struct {
  Header header;
  Unboxable values[];
} ElmRecordSmall;

typedef struct {
  Header header;
  HPointer values[];
} ElmRecord;

typedef struct {
  Header header;
  HPointer fieldgroup;
  HPointer values[];
} ElmDynRecord;

typedef struct {
  Header header;
  uint32_t count;
  uint32_t fields[];
} ElmFieldGroup;

typedef void* (*EvalFunction)(void*[]);

typedef struct {
  Header header;
  EvalFunction evaluator;
  Unboxable values[];
} ElmClosure;

typedef struct {
  Header header;
  HPointer root;
  HPointer stack;
  HPointer mailbox;
} ElmProcess;

typedef struct {
  Header header;
  HPointer value;
  HPointer callback;
  HPointer kill;
  HPointer task;
} ElmTask;

typedef struct {
  Header header;
} ElmGCForward;

typedef union HeapValue {
  ElmInt intval;
  ElmFloat floatval;
  ElmChar charval;
  ElmCons cons;
  ElmDynCons dyncons;
  ElmTuple2 tuple2;
  ElmTuple3 tuple3;
  ElmString string;
  ElmCustom custom;
  ElmCustomSmall custom_small;
  ElmRecordSmall record_small;
  ElmRecord record;
  ElmDynRecord dynrecord;
  ElmFieldGroup fieldgroup;
  ElmClosure closure;
  ElmProcess process;
  ElmTask task;
  ElmGCForward fwd;
} HeapValue;


// STATIC CONSTANTS

extern ElmCustomSmall Nil;
extern void* pNil;

extern ElmCustomSmall Unit;
extern void* pUnit;

extern ElmCustomSmall False;
extern void* pFalse;

extern ElmCustomSmall True;
extern void* pTrue;


#endif // ECO_RUNTIME_HEAP_H
