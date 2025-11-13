#ifndef ECO_RUNTIME_HEAP_H
#define ECO_RUNTIME_HEAP_H

#include <stdint.h>

// Default Bit widths
#define TAG_BITS         5
#define SIZE_BITS       32
#define CTOR_BITS       16
#define POINTER_BITS    40
#define ID_BITS         16
#define NVAL_BITS        6
#define MAXVAL_BITS      6
#define UNBOXED_BITS    32

/** Headers are always 64-bits in size, and every heap element always has a
header at its start. The first 5-bits contain a tag, denoting which kind of
heap element it is.

Pointers are 40 bits, allowing > 8 Terrabytes address space. This also allows
for a tag and pointer to be fitted into a 64-bit word, and leaves space for
other annotations against pointers that may be necessary for a garbage colector.
*/

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

typedef uint32_t ElmPtr32;   // compressed pointer
typedef uint64_t ElmWord;    // raw machine word

typedef struct {
  Header header;     // Header_Tagged
  double value;      // 64-bit float (fits Int32 and Float)
} ElmFloat;

typedef struct {
  Header header;
  double value;      // but Int32 fits fine as f64
} ElmInt;

// ElmChar stores a 32-bit scalar
typedef struct {
  Header header;
  uint32_t value;    // Unicode scalar value
  uint32_t padding;  // pad to 8 bytes
} ElmChar;

typedef struct {
  Header header;
  uint16_t words[];     // flexible array
} ElmString;

typedef struct {
  Header header;  // Header_UnboxedOnly
  ElmPtr32 a;
  ElmPtr32 b;
} ElmTuple2;

typedef struct {
  Header header;
  ElmPtr32 a;
  ElmPtr32 b;
  ElmPtr32 c;
} ElmTuple3;


typedef struct {
  Header header;     // Header_SizeUnboxed
  ElmPtr32 head;
  ElmPtr32 tail;
} ElmCons;


typedef struct {
  Header header;     // Header_SizeOnly (size=2)
  ElmPtr32 head;
  ElmPtr32 tail;
} ElmDynCons;

typedef struct {
  Header header;          // Header_Custom (size=childcount)
  ElmPtr32 values[];      // flexible array: size children
} ElmCustomSmall;

typedef struct {
  Header header;          // Header_Custom
  ElmPtr32 values[];      // child values (maybe > 32)
} ElmCustom;

typedef struct {
  Header header;         // Header_SizeUnboxed
  ElmPtr32 values[];     // one per field
} ElmRecordSmall;

typedef struct {
  Header header;
  ElmPtr32 values[];    // pointers only (no unboxed scalars)
} ElmRecord;

typedef struct {
  Header header;       // Header_SizeOnly
  ElmPtr32 fieldgroup; // pointer to ElmFieldGroup
  ElmPtr32 values[];   // dynamic field order
} ElmDynRecord;

typedef struct {
  Header header;      // Header_SizeOnly
  uint32_t count;     // number of fields
  uint32_t fields[];  // ElmField IDs
} ElmFieldGroup;

typedef void *(*EvalFunction)(ElmPtr32 *args);

typedef struct {
  Header header;           // Header_Closure
  EvalFunction evaluator;
  ElmPtr32 values[];       // captured values (n_values)
} ElmClosure;

typedef struct {
  Header header;      // Header_Process
  ElmPtr32 root;      // root task
  ElmPtr32 stack;     // process stack
  ElmPtr32 mailbox;   // queue
} ElmProcess;

typedef struct {
  Header header;      // Header_Task
  ElmPtr32 value;
  ElmPtr32 callback;
  ElmPtr32 kill;
  ElmPtr32 task;
} ElmTask;

typedef struct {
  Header header;    // Header_GCForward
  /* no additional payload needed */
} ElmGCForward;

typedef union ElmValue {
  Header header;
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
} ElmValue;


#endif // ECO_RUNTIME_HEAP_H
