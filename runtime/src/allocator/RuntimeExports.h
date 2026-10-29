//===- RuntimeExports.h - C-linkage runtime functions for LLVM calls ------===//
//
// Compiled Elm code, whether built ahead of time or by the JIT, cannot call C++ member functions or include
// headers: it calls runtime functions by symbol name. This header declares those functions, the C ABI of the
// runtime, so that generated code and the C++ kernels share one way to build Elm values, read them, apply
// closures and talk to the collector.
//
// A value crosses this ABI in one of two forms. A boxed value is an `HPtr`, the 64-bit HPointer word that
// `Heap.hpp` defines: the address of a heap object, or an embedded constant (Bool, the Empty constant, a
// nullary constructor) told apart by its `ptr_ind` bit. Word 0 is neither. An unboxed Int, Float or Char is
// the raw 64-bit word itself (a Float's bits, a Char's 32-bit value zero-extended). Which form a slot holds
// is its slot kind, the 2-bit code `Heap.hpp` defines (0 boxed, 1 Int, 2 Float, 3 Char); several functions
// take a kind bitmap that packs one such code per slot, slot i at bits 2i+1..2i. Bool is always boxed. A
// parameter kind (`ParamKind`, `PK_Boxed` to `PK_Char`) uses the same four codes for an argument or a
// result.
//
// Three facts shape the functions below.
//
// Any allocation may run a collection, and a collection moves nursery objects. A function here that
// allocates keeps its own HPointer arguments rooted across that allocation and re-reads them afterwards,
// but it cannot see the caller's copies: the caller must keep any HPointer it still needs rooted, as
// `HeapHelpers.hpp` sets out. A function that never allocates or collects is called gc-leaf here, and the
// code generator declares such functions so that LLVM places no statepoint around a call to them. The
// field getters, the stores, `eco_bump_state`, `eco_resolve_hptr` and `eco_follow_forward` are gc-leaf;
// each comment below says when a function may collect.
//
// A read of a heap field must stay inside one runtime call ("Pattern C"). If generated code computed the
// field's address itself, LLVM could move that arithmetic past a statepoint and load from where the
// object used to be. The getters resolve the object and load the field in the same call.
//
// Allocation comes in several families with the same object layouts: a plain function that roots its
// arguments and may collect; a `_fast` function that bumps the nursery and returns 0 when that fails,
// never collecting; a `_slow` function that may collect and returns an object or aborts; and an `_at`
// function that writes an object into storage the caller has already reserved. A fresh object's fields
// other than those its allocator writes are not initialised, and the caller must write every field before
// its next allocation or safepoint (HEAP_034).
//
// All heap operations act on the calling thread's heap, which must exist (`Allocator::initThread`), and
// run on the mutator thread as `Allocator` sets out. The per-thread state this component keeps of its own
// is the print destination, the literal cache and the list scratch stack.

#ifndef ECO_RUNTIME_EXPORTS_H
#define ECO_RUNTIME_EXPORTS_H

#include <algorithm>
#include <cstddef>
#include <cstdint>

#include "Heap.hpp"

#if !defined(_WIN32)
#include <pthread.h>
#endif

namespace Elm { struct EvalParamLayout; }

using Elm::HPtr;

// Returns the `HPtr` whose bits are the bits of `p`, a closure result returned as `void*` by an evaluator
// with a boxed result (`void *(void *[])`).
inline HPtr ptr0ToHPtr(void* p) {
    return HPtr::fromBits(reinterpret_cast<uint64_t>(p));
}

extern "C" {

//===----------------------------------------------------------------------===//
// Output Capture API (for EcoRunner)
//===----------------------------------------------------------------------===//

// Sends the calling thread's printed output to `stream`, and returns the previous destination.
//
// The output is what `eco_dbg_print*`, `eco_output_text`, `eco_print_value` and `eco_print_elm_value`
// write; `eco_crash` always writes to stderr. `stream` must be null, meaning stderr, or point to a
// `std::ostringstream`. The pointer is kept, so the stream must outlive its use as the destination.
void* eco_set_output_stream(void* stream);

// Returns the calling thread's print destination as `eco_set_output_stream` set it, or null for stderr.
void* eco_get_output_stream();

//===----------------------------------------------------------------------===//
// Process exit code and main thread
//===----------------------------------------------------------------------===//

// Records `code` as the process's exit code. One value is kept for the whole process, 0 until set.
//
// The store is relaxed: it orders no other memory access.
void eco_set_exit_code(int code);

// Returns the code last recorded by `eco_set_exit_code`, or 0 if none was.
int eco_get_exit_code();

#if !defined(_WIN32)
// Records `thread` as the process's main thread, for `eco_process_main_thread`.
//
// Meant to be called once, before any other thread reads it; a second call overwrites the recorded thread
// with no synchronisation against a concurrent reader.
void eco_set_process_main_thread(pthread_t thread);

// Returns the thread recorded by `eco_set_process_main_thread`, or the calling thread if none was
// recorded.
pthread_t eco_process_main_thread();
#endif

//===----------------------------------------------------------------------===//
// Allocation Functions
//===----------------------------------------------------------------------===//

// Allocates `size` bytes for an object with tag `tag`, keeping the HPointers in `roots` current across
// any collection, and returns the object's address (not an HPointer; `Allocator::wrap` gives one).
//
// The header's tag and size are written as `initHeaderForTag` writes them; the caller writes the rest.
// Bit i of `hptr_mask` marks `roots[i]` as an HPointer to keep current; the other slots, such as unboxed
// Int, Float or Char values, are left alone. After the call the caller must read its HPointers back from
// `roots`, which a collection updates in place. `n_roots` must be at most 64 (asserted), and `roots` may
// be null when `n_roots` or `hptr_mask` is 0.
//
// A `size` at or above the large-object threshold goes through `Allocator::allocate`, which places it as
// the large-object policy says and may collect. A smaller one is bumped from the nursery without
// collecting if it fits, and otherwise allocated by `Allocator::allocateSlow`, which may collect.
void* eco_alloc_with_roots(uint32_t tag, uint64_t size,
                            uint64_t* roots, uint32_t n_roots,
                            uint64_t hptr_mask);

// Allocates a Custom value with constructor tag `ctor_id` and `field_count` fields, all boxed, and returns
// it. May collect.
//
// The extension kind words a value of more than `CUSTOM_HDR_SLOTS` fields needs are zeroed (HEAP_019);
// the fields are not written. `field_count` must not be 0 (asserted): a nullary constructor is an
// embedded constant (HEAP_044). Above `CUSTOM_MAX_FIELDS` it calls `ecoFatalWideObject`, which aborts.
HPtr eco_alloc_custom(uint32_t ctor_id, uint32_t field_count);

// Allocates a cons cell holding `head` and `tail`, and returns it. May collect.
//
// The third argument is the head's slot kind; `head` is an HPointer when it is 0 and a raw Int, Float or
// Char word otherwise. Both HPointer arguments are kept current across the allocation. When the global
// `eco_g_cons_sites` is set, the call is counted against its return address.
HPtr eco_alloc_cons(uint64_t head, HPtr tail, uint32_t head_unboxed);

// List scratch stack.
//
// A loop that builds a list by consing one element at a time can instead push each element onto this
// per-thread stack and build the list once at the end, with no cell allocated per iteration. An
// accumulation brackets its pushes between `eco_scratch_mark`, which returns the stack depth, and one of
// `eco_scratch_finish`, `eco_scratch_finish_fwd` or `eco_scratch_abandon` with that depth, which pops
// back to it; accumulations nest in stack order. The boxed entries are collector roots, kept current by
// an external root scanner (`RootSet::addExternalRootScanner`), so code may allocate between pushes.

// Returns the current depth of the calling thread's scratch stack, to pass to the call that ends this
// accumulation.
//
// Registers the stack's root scanner with the calling thread's root set the first time, and again (after
// emptying the stack) when the heap has been reset since (`Allocator::heapGeneration`). Every
// accumulation must start here: the push and finish functions do not check for a reset.
int64_t eco_scratch_mark(void);

// Pushes the HPointer `value` onto the calling thread's scratch stack.
void eco_scratch_push_boxed(HPtr value);

// Pushes the raw word `bits`, of slot kind `kind` (its low 2 bits), onto the calling thread's scratch
// stack.
void eco_scratch_push_scalar(uint64_t bits, int64_t kind);

// Returns the list `e[top-1] :: ... :: e[mark] :: next`, where `e` are the entries pushed since
// `eco_scratch_mark` returned `mark`, and pops them. May collect.
//
// Returns `next` itself when nothing was pushed. When list chunks are on (`eco_g_list_chunks`), and there
// are at least 4 entries and they fit one chunk chain (`alloc::chunkChainFits`), the entries become one
// chunk chain of the uniform kind `kind` (its low 2 bits), and the per-entry kinds are not read. Otherwise
// each entry becomes a cons cell of its own pushed kind. `mark` must not exceed the depth (asserted).
HPtr eco_scratch_finish(int64_t mark, HPtr next, int64_t kind);

// Returns the list `e[mark] :: e[mark+1] :: ... :: e[top-1] :: rest`, the entries in the order they were
// pushed, and pops them. May collect.
//
// Otherwise the same as `eco_scratch_finish`: `rest` when nothing was pushed, a chunk chain or cells by
// the same rule.
HPtr eco_scratch_finish_fwd(int64_t mark, HPtr rest, int64_t kind);

// Pops the entries pushed since `eco_scratch_mark` returned `mark`, building nothing. A `mark` above the
// current depth is ignored.
void eco_scratch_abandon(int64_t mark);

// Returns the list that starts `idx` elements into the list node `node`: `node` itself when `idx` is 0,
// and otherwise a new chunk view `idx` elements further into the run of the chunk view `node`. May
// collect when `idx` is not 0.
//
// A nonzero `idx` requires `node` to be a chunk view (asserted) whose list is longer than `idx`.
HPtr eco_list_pos_view(HPtr node, int64_t idx);

// Allocates a 2-tuple holding `a` and `b`, and returns it. May collect.
//
// `unboxed_mask` is the slots' kind bitmap (slot 0 in bits 1..0, slot 1 in bits 3..2); a slot of kind 0
// holds an HPointer, which is kept current across the allocation, and any other holds a raw word.
HPtr eco_alloc_tuple2(uint64_t a, uint64_t b, uint32_t unboxed_mask);

// Allocates a 3-tuple holding `a`, `b` and `c`, and returns it. May collect.
//
// `unboxed_mask` is the slots' kind bitmap, as for `eco_alloc_tuple2` with slot 2 in bits 5..4. Its low 8
// bits are stored, so bits 7..6 must be 0.
HPtr eco_alloc_tuple3(uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask);

// Allocates a Record of `field_count` fields whose inline kind bitmap is `unboxed_bitmap`, and returns it.
// May collect.
//
// The extension kind words a record wider than `RECORD_HDR_SLOTS` needs are zeroed, so those fields read
// as boxed until a kind is stored there (HEAP_077). The fields are not written; the `eco_store_record_field`
// functions write them. Above `RECORD_MAX_FIELDS` it calls `ecoFatalWideObject`, which aborts.
HPtr eco_alloc_record(uint32_t field_count, uint64_t unboxed_bitmap);

// Stores the HPointer `value` in field `index` of `record`, and does nothing if `record` is an embedded
// constant.
//
// `index` is not checked against the record's size. `record` must still be under construction (a
// builder, as `HeapHelpers.hpp` defines). In `ECO_HEAP_VALIDATE` builds `value` is first checked as
// `alloc::validateNurseryHPtrBits` describes.
void eco_store_record_field(HPtr record, uint32_t index, HPtr value);

// Stores the Int `value` in field `index` of `record`, as `eco_store_record_field` stores an HPointer,
// without the check. The field's kind is not changed.
void eco_store_record_field_i64(HPtr record, uint32_t index, int64_t value);

// Stores the Float `value` in field `index` of `record`, as `eco_store_record_field_i64` stores an Int.
void eco_store_record_field_f64(HPtr record, uint32_t index, double value);

//===----------------------------------------------------------------------===//
// Allocators that leave the fields to the caller
//===----------------------------------------------------------------------===//

// Allocates a 2-tuple whose kind bitmap is `unboxed_mask` (its low 4 bits) and whose slots are 0, and
// returns it. May collect. The caller fills the slots with the `eco_store_tuple_field` functions.
HPtr eco_alloc_tuple2_uninit(uint32_t unboxed_mask);

// Allocates a 3-tuple whose kind bitmap is `unboxed_mask` (its low 6 bits) and whose slots are 0, and
// returns it. May collect.
HPtr eco_alloc_tuple3_uninit(uint32_t unboxed_mask);

// Allocates a cons cell whose head kind is `head_kind` (its low 2 bits) and whose head and tail are 0,
// and returns it. May collect. The caller fills it with the `eco_store_cons_*` functions; a tail of 0 is
// not a list.
HPtr eco_alloc_cons_uninit(uint32_t head_kind);

//===----------------------------------------------------------------------===//
// Inline nursery allocation (HEAP_034)
//===----------------------------------------------------------------------===//

// Returns the address of the calling thread's nursery bump state, the pair {ptr at +0, end at +8} that
// compiled code bumps to allocate inline. gc-leaf.
//
// The address stays the same while the thread's heap lives; only its contents change. The thread must
// have a heap, and nothing checks it.
void* eco_bump_state(void);

// The address `eco_bump_state` returns, cached per thread so that compiled code can read it with a
// thread-local load instead of a call. `Allocator::setThreadHeap` keeps it current.
extern thread_local void* eco_tl_bump_state;

// Allocates `size` bytes of nursery storage after compiled code's inline bump failed, running a minor
// collection first, and returns its address as an HPointer.
//
// The storage is not initialised, not even its header: the caller must write the whole header word and
// every field before its next safepoint (HEAP_034). `size` must be a multiple of 8 and at most 4096
// (asserted). Without assertions, failure returns 0.
HPtr eco_alloc_inline_slow(uint64_t size);

// Makes at least `n` bytes free in the calling thread's nursery bump range without allocating them,
// collecting if needed, so that inline allocations totalling at most `n` bytes need no further check
// (HEAP_041). Not gc-leaf.
//
// `n` must be a multiple of 8 and at most 4096 (asserted).
void eco_ensure_nursery_slow(uint64_t n);

// Stores the HPointer `value` in slot `index` of the 2- or 3-tuple `tuple`, and does nothing if `tuple`
// is an embedded constant.
//
// `index` is not checked. `tuple` must be a builder. In `ECO_HEAP_VALIDATE` builds `value` is first
// checked as `alloc::validateNurseryHPtrBits` describes.
void eco_store_tuple_field(HPtr tuple, uint32_t index, HPtr value);

// Stores the Int `value` in slot `index` of `tuple`, as `eco_store_tuple_field` stores an HPointer,
// without the check.
void eco_store_tuple_field_i64(HPtr tuple, uint32_t index, int64_t value);

// Stores the Float `value` in slot `index` of `tuple`, as `eco_store_tuple_field_i64` stores an Int.
void eco_store_tuple_field_f64(HPtr tuple, uint32_t index, double value);

// Stores the HPointer `value` as the head of the cons cell `cons`, and does nothing if `cons` is an
// embedded constant. `cons` must be a builder. In `ECO_HEAP_VALIDATE` builds `value` is first checked as
// `alloc::validateNurseryHPtrBits` describes.
void eco_store_cons_head(HPtr cons, HPtr value);

// Stores the Int `value` as the head of `cons`, as `eco_store_cons_head` stores an HPointer, without the
// check.
void eco_store_cons_head_i64(HPtr cons, int64_t value);

// Stores the Float `value` as the head of `cons`, as `eco_store_cons_head_i64` stores an Int.
void eco_store_cons_head_f64(HPtr cons, double value);

// Stores the list `value` as the tail of `cons`, as `eco_store_cons_head` stores a head.
void eco_store_cons_tail(HPtr cons, HPtr value);

// Allocates a String of `length` UTF-16 units, whose units are not written, and returns it. May collect.
//
// A `length` of 0 returns the Empty constant and allocates nothing (HEAP_071).
HPtr eco_alloc_string(uint32_t length);

// Returns the String holding the `length` UTF-16 units at `chars`, interned by the address `chars`: the
// first call for an address on a thread builds the String and later calls on that thread return it.
//
// The String is allocated in `PermanentSpace`, where it is never moved or freed. When `PermanentSpace`
// is full, or disabled by `ECO_CAF_PERMANENT` starting with `0`, it is an old-generation object instead,
// kept alive by a root on the cached word. The cache is per thread and
// is dropped when the heap is reset (`Allocator::heapGeneration`). The units at `chars` must not change,
// since a later call with the same address gets the String built from the first call's units.
HPtr eco_alloc_string_literal(const uint16_t* chars, uint32_t length);

// Returns the String holding the `byteLen` ASCII bytes at `bytes`, interned by the address `bytes` as
// `eco_alloc_string_literal` interns by `chars`.
//
// Every byte must be below 0x80, and nothing checks it; the String is then `byteLen` UTF-16 units long.
// It is a UTF-8 leaf, or a UTF-16 leaf when the configuration turns UTF-8 strings off
// (`HeapConfig::utf8_strings_enabled`).
HPtr eco_alloc_string_literal_utf8(const uint8_t* bytes, uint32_t byteLen);

// Returns what `eco_alloc_string_literal(chars, length)` returns, and also stores it in `*slot` when it
// is a String in `PermanentSpace`.
//
// `*slot` is otherwise left as it is: for the Empty constant, and for an old-generation fallback, whose
// address a collection can change. The store is a relaxed atomic store; a word stored by any thread names
// an object that never moves or dies, so it is valid on every thread.
HPtr eco_string_literal_fill(const uint16_t* chars, uint32_t length,
                             uint64_t* slot);

// Returns what `eco_alloc_string_literal_utf8(bytes, byteLen)` returns, storing it in `*slot` as
// `eco_string_literal_fill` does.
HPtr eco_string_literal_utf8_fill(const uint8_t* bytes, uint32_t byteLen,
                                  uint64_t* slot);

// Allocates a closure as `eco_alloc_closure_k(func_ptr, num_captures, 0)` does, with a boxed result.
HPtr eco_alloc_closure(void* func_ptr, uint32_t num_captures);

// Allocates a closure as `eco_alloc_closure_k` does, for `fn`, a plain evaluator function rather than an
// `EvaluatorDesc`.
//
// The descriptor is the one `ecoDescForKernelEvaluator(fn, num_captures, result_kind)` interns, so the
// closure's stage arity is `num_captures`.
HPtr eco_alloc_closure_fn(void* fn, uint32_t num_captures, uint8_t result_kind);

// Allocates a closure with room for `num_captures` values and none captured yet, and returns it. May
// collect.
//
// `func_ptr` must point to the closure's `EvaluatorDesc`, and is kept as the closure's evaluator; it must
// outlive the closure. `result_kind` is the `ParamKind` the evaluator returns (asserted at most 3), which
// tells the apply functions how to call it. Every value kind is boxed and the extension kind words are
// zero; the caller captures values with `alloc::closureCapture`. Above `CLOSURE_MAX_ARITY` captures it
// prints a message and aborts.
HPtr eco_alloc_closure_k(void* func_ptr, uint32_t num_captures,
                         uint8_t result_kind);

// Returns the zero-capture closure for `func_ptr`, interned by `func_ptr` as `eco_alloc_string_literal`
// interns a String by its address: in `PermanentSpace` when it has room, otherwise in the old generation.
//
// `func_ptr` must point to an `EvaluatorDesc` that outlives the process's use of the closure. `packed` is
// stored verbatim as the closure's packed word (count, capacity, result kind and inline kinds,
// HEAP_078), and must say no value is captured; `arity` is the number of value slots, which must be at
// most `CLOSURE_HDR_SLOTS` (asserted), so there are no extension kind words. A cache hit returns the
// first closure whatever `arity` and `packed` are now, so both must be the same on every call for one
// `func_ptr`. The closure must never be written: applying it copies it.
HPtr eco_intern_closure0(void* func_ptr, uint32_t arity, uint64_t packed);

// Allocates a boxed Int holding `value`, and returns it. May collect.
HPtr eco_alloc_int(int64_t value);

// Allocates a boxed Float holding `value`, and returns it. May collect.
HPtr eco_alloc_float(double value);

// Allocates a boxed Char holding `value`, a Char word as `CharValue.hpp` defines it, and returns it. May
// collect.
HPtr eco_alloc_char(uint32_t value);

// Does nothing. Exactly one of the two is defined, the one matching this runtime's
// `ECO_CHAR_CASE_EXPANSION` setting (KERN_008, `CharValue::kBuildGuardSymbol`), so a program compiled for
// the other setting fails to link or, under the JIT, to resolve the symbol.
#if ECO_CHAR_CASE_EXPANSION
void eco_char_case_expansion_on(void);
#else
void eco_char_case_expansion_off(void);
#endif

// Allocates `size` bytes for an object with tag `tag`, as `eco_alloc_with_roots` does with no roots, and
// returns it. May collect. Only the header's tag and size are written.
HPtr eco_allocate(uint64_t size, uint32_t tag);

// Writes the kind bitmap `bitmap` into `obj`, and does nothing if `obj` is an embedded constant.
//
// For a Custom it is the 48-bit inline bitmap (asserted to fit); for a 2-tuple, 3-tuple or cons cell the
// header's kinds, masked to 4, 6 or 2 bits; for any other kind except Record and Closure, such as an
// Array's uniform kind, the header's low 2 bits. A Record or Closure keeps its kinds elsewhere, so for
// one it prints a message and aborts.
void eco_set_unboxed(HPtr obj, uint64_t bitmap);

//===----------------------------------------------------------------------===//
// Fast Allocation Functions (bump-pointer only, no GC, return 0 on failure)
//===----------------------------------------------------------------------===//

// Each `_fast` function allocates the same object as the plain function of the same name, by bumping the
// calling thread's nursery without regard to the large-object threshold, and returns it, or returns 0 if
// the nursery has no room. It never collects, so it roots nothing. `eco_alloc_closure_fast` always gives
// the closure a boxed result kind.

// Allocates as `eco_alloc_custom` does, or returns 0 when the nursery has no room.
HPtr eco_alloc_custom_fast(uint32_t ctor_id, uint32_t field_count);
// Allocates as `eco_alloc_cons` does, or returns 0 when the nursery has no room. Sites are not counted.
HPtr eco_alloc_cons_fast(uint64_t head, HPtr tail, uint32_t head_unboxed);
// Allocates as `eco_alloc_tuple2` does, or returns 0 when the nursery has no room.
HPtr eco_alloc_tuple2_fast(uint64_t a, uint64_t b, uint32_t unboxed_mask);
// Allocates as `eco_alloc_tuple3` does, keeping the low 6 bits of `unboxed_mask`, or returns 0 when the
// nursery has no room.
HPtr eco_alloc_tuple3_fast(uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask);
// Allocates as `eco_alloc_record` does, or returns 0 when the nursery has no room.
HPtr eco_alloc_record_fast(uint32_t field_count, uint64_t unboxed_bitmap);
// Allocates a String of `length` unwritten UTF-16 units, or returns 0 when the nursery has no room. Unlike
// `eco_alloc_string`, a `length` of 0 allocates a heap String.
HPtr eco_alloc_string_fast(uint32_t length);
// Allocates as `eco_alloc_closure` does, or returns 0 when the nursery has no room.
HPtr eco_alloc_closure_fast(void* func_ptr, uint32_t num_captures);
// Allocates as `eco_alloc_int` does, or returns 0 when the nursery has no room.
HPtr eco_alloc_int_fast(int64_t value);
// Allocates as `eco_alloc_float` does, or returns 0 when the nursery has no room.
HPtr eco_alloc_float_fast(double value);
// Allocates as `eco_alloc_char` does, or returns 0 when the nursery has no room.
HPtr eco_alloc_char_fast(uint32_t value);

//===----------------------------------------------------------------------===//
// Slow Allocation Functions (may GC)
//===----------------------------------------------------------------------===//

// Each `_slow` function allocates the same object as the plain function of the same name through
// `Allocator::allocateSlow`, which may collect. It aborts on failure when assertions are on; without them
// it can return null.

// Allocates as `eco_alloc_custom` does. May collect.
HPtr eco_alloc_custom_slow(uint32_t ctor_id, uint32_t field_count);
// Allocates as `eco_alloc_cons` does, keeping `head` (when boxed) and `tail` current across a collection.
// May collect. Sites are not counted.
HPtr eco_alloc_cons_slow(uint64_t head, HPtr tail, uint32_t head_unboxed);
// Allocates as `eco_alloc_tuple2` does, keeping the boxed slots' values current. May collect.
HPtr eco_alloc_tuple2_slow(uint64_t a, uint64_t b, uint32_t unboxed_mask);
// Allocates as `eco_alloc_tuple3` does, keeping the low 6 bits of `unboxed_mask` and the boxed slots'
// values current. May collect.
HPtr eco_alloc_tuple3_slow(uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask);
// Allocates as `eco_alloc_record` does. May collect.
HPtr eco_alloc_record_slow(uint32_t field_count, uint64_t unboxed_bitmap);
// Allocates a String of `length` unwritten UTF-16 units. May collect. Unlike `eco_alloc_string`, a
// `length` of 0 allocates a heap String.
HPtr eco_alloc_string_slow(uint32_t length);
// Allocates as `eco_alloc_closure` does. May collect.
HPtr eco_alloc_closure_slow(void* func_ptr, uint32_t num_captures);

// Allocates the `numSiblings` closures of one group of mutually recursive definitions in one contiguous
// region, writes their captures, including references from one sibling to another, and stores their
// HPointers in `outClosures[0..numSiblings)` in sibling order. May collect.
//
// Sibling i has the evaluator `evaluators[i]` (an `EvaluatorDesc`), capacity `arities[i]` (at most
// `CLOSURE_MAX_ARITY`, else it aborts), `numCaptured[i]` values already captured, result kind
// `resultKinds[i]` (low 2 bits) and inline kinds `hdrKinds[i]`. Its extension kind words are
// `extKinds[extOffsets[i] .. extOffsets[i+1])`, which must number `extWords(arities[i], CLOSURE_HDR_SLOTS)`
// (asserted). Its captures from outside the group, `captures[captureOffsets[i] .. captureOffsets[i+1])`,
// fill its slots from 0. Each of the `numCrossEdges` triples in `crossEdges` (producer, consumer, slot)
// then stores sibling `producer`'s HPointer in slot `slot` of sibling `consumer`.
//
// Any collection happens before anything is written, and `captures` is not rooted here: its HPointers
// must be ones the caller keeps current, and it must not reach this call with stale ones. Because all the
// siblings are allocated together, they are in the same space, and the edges between them need no
// further work.
void eco_alloc_closure_group_l(
    uint64_t numSiblings,
    const void* const* evaluators,
    const uint32_t* arities,
    const uint32_t* numCaptured,
    const uint64_t* hdrKinds,
    const uint64_t* extKinds,
    const uint32_t* extOffsets,
    const uint8_t*  resultKinds,
    const uint32_t* captureOffsets,
    const uint64_t* captures,
    const uint64_t* crossEdges,
    uint64_t numCrossEdges,
    uint64_t* outClosures);
// Allocates as `eco_alloc_int` does. May collect.
HPtr eco_alloc_int_slow(int64_t value);
// Allocates as `eco_alloc_float` does. May collect.
HPtr eco_alloc_float_slow(double value);
// Allocates as `eco_alloc_char` does. May collect.
HPtr eco_alloc_char_slow(uint32_t value);

//===----------------------------------------------------------------------===//
// Region Allocation (fast returns nullptr, slow may GC)
//===----------------------------------------------------------------------===//

// Bumps `total` bytes from the calling thread's nursery and returns their address, or null if they do
// not fit. Never collects, and writes nothing.
void* eco_gc_alloc_region_fast(size_t total);

// Allocates `total` contiguous bytes, which the caller divides into objects, as
// `Allocator::allocateRegionSlow` does. May collect. Writes nothing.
void* eco_gc_alloc_region_slow(size_t total);

//===----------------------------------------------------------------------===//
// Init-at-pointer Functions (for group allocation)
//===----------------------------------------------------------------------===//

// Each `_at` function writes, at `ptr`, the object the plain function of the same name would allocate, and
// returns its HPointer. It never allocates. `ptr` must be the start of enough reserved, unused heap storage
// for the object, such as part of a region from `eco_gc_alloc_region_*`.

// Writes a boxed Int holding `value` at `ptr`.
HPtr eco_init_int_at(void* ptr, int64_t value);
// Writes a boxed Float holding `value` at `ptr`.
HPtr eco_init_float_at(void* ptr, double value);
// Writes a boxed Char holding `value` at `ptr`.
HPtr eco_init_char_at(void* ptr, uint32_t value);
// Writes a cons cell at `ptr`, as `eco_alloc_cons` builds one.
HPtr eco_init_cons_at(void* ptr, uint64_t head, HPtr tail, uint32_t head_unboxed);
// Writes a 2-tuple at `ptr`, as `eco_alloc_tuple2` builds one.
HPtr eco_init_tuple2_at(void* ptr, uint64_t a, uint64_t b, uint32_t unboxed_mask);
// Writes a 3-tuple at `ptr`, as `eco_alloc_tuple3` builds one, keeping the low 6 bits of `unboxed_mask`.
HPtr eco_init_tuple3_at(void* ptr, uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask);
// Writes a Record header at `ptr`, as `eco_alloc_record` builds one; `wideByteSize(Tag_Record,
// field_count)` bytes must be reserved.
HPtr eco_init_record_at(void* ptr, uint32_t field_count, uint64_t unboxed_bitmap);
// Writes a Custom header at `ptr`, as `eco_alloc_custom` builds one, without the check that
// `field_count` is not 0; `wideByteSize(Tag_Custom, field_count)` bytes must be reserved.
HPtr eco_init_custom_at(void* ptr, uint32_t ctor_id, uint32_t field_count);
// Writes the header of a String of `length` unwritten UTF-16 units at `ptr`.
HPtr eco_init_string_at(void* ptr, uint32_t length);

//===----------------------------------------------------------------------===//
// Field Store Functions
//===----------------------------------------------------------------------===//

// Stores the HPointer `value` in field `index` of `obj`, a Custom, 2-tuple, 3-tuple or cons cell (index 0
// the head, any other the tail), and does nothing if `obj` is an embedded constant.
//
// `index` is not checked, and the field's kind is not changed. `obj` must be a builder. For any other
// kind of object it prints a message and stores nothing. A Closure must not be passed: its captures are
// written with `alloc::closureCapture`, and this function only asserts against it, so in a build without
// assertions it writes the slot, which the collector never traces. In `ECO_HEAP_VALIDATE` builds `value`
// is first checked as `alloc::validateNurseryHPtrBits` describes.
void eco_store_field(HPtr obj, uint32_t index, HPtr value);

// Stores the Int `value` in field `index` of `obj`, as `eco_store_field` stores an HPointer, without the
// check. For a cons cell only index 0, the head, is written.
void eco_store_field_i64(HPtr obj, uint32_t index, int64_t value);

// Stores the Float `value` in field `index` of `obj`, as `eco_store_field_i64` stores an Int, except that
// a cons cell is not handled and gets the message.
void eco_store_field_f64(HPtr obj, uint32_t index, double value);

//===----------------------------------------------------------------------===//
// Closure Operations
//===----------------------------------------------------------------------===//

// A closure holds an evaluator, a capacity (`max_values`, the stage arity) and the values captured so far
// (`n_values`); `remaining` is the difference. Applying `num_args` arguments to it has three cases: fewer
// than `remaining` makes a new closure with the arguments captured (partial application, a PAP), exactly
// `remaining` calls the evaluator with the captured values followed by the arguments, and more than
// `remaining` calls it with the first `remaining` and applies the rest to the result, which must be a
// closure. The evaluator's result kind is read from the closure (`Closure::result_kind`), never from a
// layout. An argument's kind as the caller holds it comes from an `EvalParamLayout`; where it differs from
// the kind the closure's slot expects, the argument is boxed or unboxed to match (REP_CLOSURE_002), and
// boxing allocates. Every function here may collect, since the evaluator may.

// Applies the `num_args` HPointer arguments in `args` to `closure`, as the closure functions above
// describe, and returns the result, boxed if the evaluator returns a primitive.
//
// `num_args` of 0 returns `closure`. An embedded-constant `closure` gives 0.
HPtr eco_apply_closure(HPtr closure, uint64_t* args, uint32_t num_args);

// Applies the `num_args` arguments in `typed_args` to `closure`, as `eco_apply_closure_eval` does, and
// returns the result, boxed if the evaluator returns a primitive.
HPtr eco_apply_closure_typed(HPtr closure, int64_t* typed_args,
                             uint32_t num_args,
                             const Elm::EvalParamLayout* args_layout);

// Applies the `num_args` arguments in `typed_args` to `closure`, as the closure functions above describe,
// and writes the result, converted to `desired_kind`, to `result_slot`.
//
// `args_layout->kinds[i]` is the kind of `typed_args[i]`; a null `args_layout` means every argument is
// boxed. Its `result_kind` is not read. `result_slot` must point to an `HPtr`, `int64_t`, `double` or
// `uint32_t` for a `desired_kind` of 0 to 3. A primitive result wanted boxed is allocated; a boxed result
// wanted as a primitive is read from its ElmInt, ElmFloat or ElmChar; any other mismatch is an assertion
// failure. Applying no arguments, or too few, gives a closure, so `desired_kind` must then be 0
// (asserted). An embedded-constant `closure` writes 0 of the wanted kind.
//
// The boxed arguments are kept current across collections only when `args_layout` is given; with a null
// one and more arguments than `remaining`, the arguments beyond the first `remaining` are not rooted while
// the first call runs.
void eco_apply_closure_eval(HPtr closure, int64_t* typed_args,
                            uint32_t num_args,
                            const Elm::EvalParamLayout* args_layout,
                            void* result_slot,
                            uint8_t desired_kind);

// Returns a new closure holding `closure`'s captured values followed by the `num_newargs` arguments in
// `args`, each converted from the kind `caller_layout` gives it (all boxed when it is null) to the kind
// the closure's slot expects. May collect.
//
// The new closure has `closure`'s evaluator, result kind, capacity and kinds, including its extension kind
// words (HEAP_078); `closure` is not changed. More values than the capacity print a message and abort. An
// embedded-constant `closure` gives 0.
HPtr eco_pap_extend_l(HPtr closure, uint64_t* args, uint32_t num_newargs,
                      const Elm::EvalParamLayout* caller_layout);

// Calls `closure`'s evaluator with its captured values followed by the `num_newargs` arguments in
// `new_args`, and returns the result, boxed if the evaluator returns a primitive.
//
// The arguments must exactly fill the closure (asserted). `layout` gives their kinds as for
// `eco_apply_closure_eval`, and may be null for all boxed. An embedded-constant `closure` gives 0.
HPtr eco_closure_call_saturated(HPtr closure, uint64_t* new_args, uint32_t num_newargs, const Elm::EvalParamLayout* layout);

// Calls `closure` as `eco_closure_call_saturated` does, and writes the result, converted to
// `desired_kind`, to `result_slot` as `eco_apply_closure_eval` does. A primitive result wanted as that
// primitive is not boxed.
void eco_closure_call_saturated_eval(
    HPtr closure, uint64_t* new_args, uint32_t num_newargs,
    const Elm::EvalParamLayout* layout, void* result_slot,
    uint8_t desired_kind);

//===----------------------------------------------------------------------===//
// Runtime Utilities
//===----------------------------------------------------------------------===//

// Prints `Elm runtime error: ` and the String `message` to stderr, then exits the process with status 1
// through `std::exit`, so `atexit` handlers run.
//
// Units of the message outside ASCII print as `?`; an empty message, or one that is not a String, prints
// nothing after the prefix.
[[noreturn]] void eco_crash(HPtr message);

// The print functions below write to the calling thread's print destination (`eco_set_output_stream`).
// The untyped printer renders a value from its heap representation alone: Ints, Floats, Chars and Strings
// in Elm syntax, lists as `[...]`, tuples, a Custom as `Ctor<n>` and its fields, a Record as
// `{ f0 = ... }`, a closure as `<fn>`, Bytes as `<bytes:n>`, an embedded constant as `True`, `False`,
// `<empty>` or `<ctor n>`. It prints `...` after 100 list elements and in place of a value nested more
// than 50 levels deep.

// Prints `[eco.dbg] `, then each of the `num_args` boxed values in `args` with the untyped printer,
// separated by spaces, then a newline.
void eco_dbg_print(uint64_t* args, uint32_t num_args);

// Prints `[eco.dbg] `, the Int `value` and a newline.
void eco_dbg_print_int(int64_t value);

// Prints `[eco.dbg] `, the Float `value` as Elm prints it (`Infinity`, `NaN`, `0` for -0.0) and a newline.
void eco_dbg_print_float(double value);

// Prints `[eco.dbg] `, the Char `value` in Elm syntax and a newline. An encoded case-mapping result
// prints as all its code points (KERN_008).
void eco_dbg_print_char(int32_t value);

// Prints the `num_args` boxed values in `values`, each with the type `type_ids[i]` in the registered type
// graph, which names constructors and record fields.
//
// When there are two values and the first's type is String, it prints `label: value` on one line, as
// `Debug.log` does; otherwise it prints each value on its own line. A Custom-typed value whose shape does
// not match its type prints as `<internals>`. A type graph must be registered (asserted); without one, a
// build without assertions falls back to the untyped printer.
void eco_dbg_print_typed(uint64_t* values, uint32_t* type_ids, uint32_t num_args);

// Makes `graph`, an `Elm::EcoTypeGraph`, the type graph the typed printers use, for every thread.
//
// The pointer is kept with no synchronisation, so this must happen before any typed print, and the graph
// must outlive every later print.
void eco_register_type_graph(const void* graph);

// Writes the C string `text` to the calling thread's print destination.
void eco_output_text(const char* text);

// Prints `value` with the untyped printer.
void eco_print_value(HPtr value);

// Prints `value` with the untyped printer, except that a Custom with constructor tag 0 and one field
// prints as that field alone, unwrapped again if it is such a Custom too.
//
// A boxed field below 0x10000 is taken for a small integer and printed as a number.
void eco_print_elm_value(HPtr value);

// Returns a new String holding what `eco_print_value(value)` would print. May collect.
HPtr eco_value_to_string(HPtr value);

// Returns a new String holding what the typed printer prints for `value` of type `type_id`, or what the
// untyped printer prints when `type_id` is negative, out of range or no type graph is registered. May
// collect.
HPtr eco_value_to_string_typed(HPtr value, int64_t type_id);

//===----------------------------------------------------------------------===//
// GC Interface
//===----------------------------------------------------------------------===//

// Does nothing.
void eco_safepoint();

// Runs the collection the calling thread's heap wants at a safepoint, if it wants one
// (`Allocator::shouldCollectAtSafepoint`).
void __eco_safepoint_poll();

// Runs a minor collection on the calling thread's heap.
void eco_minor_gc();

// Runs a major collection on the calling thread's heap.
void eco_major_gc();

// Registers `root_ptr`, the address of a word holding a raw heap address, as a root of the calling
// thread's heap until `eco_gc_remove_root`, as `RootSet::addJitRoot` describes.
//
// The word must stay valid while registered. A word holding an embedded constant is skipped.
void eco_gc_add_root(uint64_t* root_ptr);

// Unregisters `root_ptr` from the calling thread's heap. An address that is not registered is ignored.
void eco_gc_remove_root(uint64_t* root_ptr);

// Returns the number of words registered with `eco_gc_add_root` on the calling thread's heap.
uint64_t eco_gc_jit_root_count();

// Registers `value_ptr`, the address of a word holding an Elm value as an HPointer, as a root of the
// calling thread's heap until `eco_gc_remove_value_root`, as `RootSet::addRoot` describes.
//
// The word must stay valid while registered. A collection keeps the object it refers to alive and updates
// the word when the object moves; an embedded constant is left alone.
void eco_gc_add_value_root(uint64_t* value_ptr);

// Unregisters `value_ptr` from the calling thread's heap. An address that is not registered is ignored.
void eco_gc_remove_value_root(uint64_t* value_ptr);

// The stack root ranges of the calling thread's root set: runs of up to 64 words, such as an argument array
// on the stack, whose HPointer words a collection keeps alive and updates in place. A caller takes a restore
// point, pushes its ranges, and restores the point when it no longer needs them.

// Returns a restore point for the calling thread's root ranges.
size_t   eco_gc_stack_range_point();
// Pushes the `count` words at `base` as a root range in which bit i of `hpointer_mask` marks word i as an
// HPointer. A null `base` or a `count` of 0 pushes nothing; a `count` above 64 is an assertion failure.
// The words must stay valid until the range is popped.
void     eco_gc_push_stack_range(uint64_t* base, size_t count, uint64_t hpointer_mask);
// Pops the calling thread's root ranges back to `point`.
void     eco_gc_restore_stack_range_point(size_t point);

//===----------------------------------------------------------------------===//
// Tag Extraction
//===----------------------------------------------------------------------===//

// Returns the header tag of the heap object `obj`, or 0 if `obj` is an embedded constant. gc-leaf.
//
// 0 is also a real tag, so the result alone cannot tell the two apart.
uint32_t eco_get_header_tag(HPtr obj);

// Returns the constructor tag of the Custom `obj`, or 0 if `obj` is an embedded constant. gc-leaf. The
// object's kind is not checked.
uint32_t eco_get_custom_ctor(HPtr obj);

// Returns the constructor tag a `case` dispatches on for `val`. gc-leaf.
//
// For a nullary constructor (a null-cons constant, HEAP_044) it is the index the word carries; for the
// Empty constant (Nil, Nothing, Unit, the empty record or String) `CONSTANT_TAG`; for a Bool constant 0
// for False and 1 for True. For a heap object it is 1 for a cons cell or chunk view (the list's Cons), the
// `ctor` field for a Custom, and 0 for anything else. `CONSTANT_TAG` is also `CTOR_Router`'s value. `val`
// must not be 0 (asserted).
uint32_t eco_get_tag(HPtr val);

//===----------------------------------------------------------------------===//
// List Element Access
//===----------------------------------------------------------------------===//

// Returns the first element of the list node `cons`, a cons cell or chunk view, as an Int. gc-leaf.
//
// An unboxed element is read as it is stored; a boxed one is read from the ElmInt it refers to. A node of
// any other kind gives 0. `cons` must not be an embedded constant, so the list must not be empty.
int64_t eco_cons_head_i64(HPtr cons);

// Returns the first element of the list node `cons` as a Float, as `eco_cons_head_i64` returns an Int.
double eco_cons_head_f64(HPtr cons);

// Returns the first element of the list node `cons` as a Char word, as `eco_cons_head_i64` returns an
// Int.
uint32_t eco_cons_head_char(HPtr cons);

//===----------------------------------------------------------------------===//
// Tuple field access (gc-leaf, non-allocating).
//===----------------------------------------------------------------------===//

// Each function returns slot N of `tup`, a 2-tuple or 3-tuple as its name says, read as the type its name
// gives (Int, Float or Char word). It is gc-leaf. The slot is read as that type whatever kind the tuple
// records for it: these are for slots whose SSA type is that primitive, which is stored unboxed. `tup` must
// be a heap object of the named kind; that it is not null is asserted, and its kind is not checked.

// Returns slot 0 of the 2-tuple `tup` as an Int.
int64_t eco_tuple2_get0_i64(HPtr tup);
// Returns slot 1 of the 2-tuple `tup` as an Int.
int64_t eco_tuple2_get1_i64(HPtr tup);
// Returns slot 0 of the 2-tuple `tup` as a Float.
double  eco_tuple2_get0_f64(HPtr tup);
// Returns slot 1 of the 2-tuple `tup` as a Float.
double  eco_tuple2_get1_f64(HPtr tup);
// Returns slot 0 of the 2-tuple `tup` as a Char word.
uint32_t eco_tuple2_get0_char(HPtr tup);
// Returns slot 1 of the 2-tuple `tup` as a Char word.
uint32_t eco_tuple2_get1_char(HPtr tup);

// Returns slot 0 of the 3-tuple `tup` as an Int.
int64_t eco_tuple3_get0_i64(HPtr tup);
// Returns slot 1 of the 3-tuple `tup` as an Int.
int64_t eco_tuple3_get1_i64(HPtr tup);
// Returns slot 2 of the 3-tuple `tup` as an Int.
int64_t eco_tuple3_get2_i64(HPtr tup);
// Returns slot 0 of the 3-tuple `tup` as a Float.
double  eco_tuple3_get0_f64(HPtr tup);
// Returns slot 1 of the 3-tuple `tup` as a Float.
double  eco_tuple3_get1_f64(HPtr tup);
// Returns slot 2 of the 3-tuple `tup` as a Float.
double  eco_tuple3_get2_f64(HPtr tup);
// Returns slot 0 of the 3-tuple `tup` as a Char word.
uint32_t eco_tuple3_get0_char(HPtr tup);
// Returns slot 1 of the 3-tuple `tup` as a Char word.
uint32_t eco_tuple3_get1_char(HPtr tup);
// Returns slot 2 of the 3-tuple `tup` as a Char word.
uint32_t eco_tuple3_get2_char(HPtr tup);

//===----------------------------------------------------------------------===//
// Record / Custom field access (gc-leaf, non-allocating).
//===----------------------------------------------------------------------===//

// As the tuple getters: field `field_index` of a Record or Custom, read as the named type whatever its
// recorded kind. `field_index` is not checked.

// Returns field `field_index` of the Record `rec` as an Int.
int64_t eco_record_get_i64(HPtr rec, uint32_t field_index);
// Returns field `field_index` of the Record `rec` as a Float.
double  eco_record_get_f64(HPtr rec, uint32_t field_index);
// Returns field `field_index` of the Record `rec` as a Char word.
uint32_t eco_record_get_char(HPtr rec, uint32_t field_index);

// Returns field `field_index` of the Custom `val` as an Int.
int64_t eco_custom_get_i64(HPtr val, uint32_t field_index);
// Returns field `field_index` of the Custom `val` as a Float.
double  eco_custom_get_f64(HPtr val, uint32_t field_index);
// Returns field `field_index` of the Custom `val` as a Char word.
uint32_t eco_custom_get_char(HPtr val, uint32_t field_index);

//===----------------------------------------------------------------------===//
// Array element access (gc-leaf, non-allocating).
// Index is `int64_t` to mirror the `Eco_Int` SSA operand on `eco.array.get`.
//===----------------------------------------------------------------------===//

// As the tuple getters: element `index` of an Array, read as the named type. `index` is not checked.

// Returns element `index` of the Array `arr` as an Int.
int64_t eco_array_get_i64(HPtr arr, int64_t index);
// Returns element `index` of the Array `arr` as a Float.
double  eco_array_get_f64(HPtr arr, int64_t index);
// Returns element `index` of the Array `arr` as a Char word.
uint32_t eco_array_get_char(HPtr arr, int64_t index);

//===----------------------------------------------------------------------===//
// Arithmetic Helpers
//===----------------------------------------------------------------------===//

// Returns `base` raised to the power `exp`, or 0 when `exp` is negative.
//
// The arithmetic is plain signed multiplication, so a power whose computation overflows `int64_t` is
// undefined behaviour.
int64_t eco_int_pow(int64_t base, int64_t exp);

//===----------------------------------------------------------------------===//
// HPointer Conversion
//===----------------------------------------------------------------------===//

// Returns the address of the heap object `hptr` refers to, following forward headers as
// `Allocator::resolve` does, or null if `hptr` is an embedded constant (asserted against in
// `ECO_HEAP_VALIDATE` builds). gc-leaf, and must stay so: generated code calls it with no statepoint.
//
// `hptr` must not be 0.
void* eco_resolve_hptr(HPtr hptr);

// Returns the address `hptr` refers to after following any chain of forward headers, or `hptr`'s own
// address when its header is not a forward header. gc-leaf.
//
// `hptr` must refer to a heap object, not an embedded constant or 0; nothing checks it.
void* eco_follow_forward(HPtr hptr);

// Checks `bits`, an HPointer about to be stored in a heap field, as `alloc::validateNurseryHPtrBits`
// describes: in `ECO_HEAP_VALIDATE` builds it aborts when `bits` points into a free part of the calling
// thread's nursery, and in other builds it does nothing.
void eco_validate_nursery_hptr_bits(uint64_t bits);

// Returns a new Array with the length, element kind and elements of `array_hptr`. May collect; the source
// is kept current across that.
//
// `array_hptr` must be a heap Array, not an embedded constant.
HPtr eco_clone_array(HPtr array_hptr);

// Sets the element kind of the Array `array_hptr` to `intended_kind`, and does nothing if it is an
// embedded constant. It neither allocates nor collects.
//
// The kind is stored masked to 6 bits, not 2, so `intended_kind` must be at most 3. The array must be a
// builder, and its elements must be of the new kind before the next collection reads them.
void eco_array_set_fix_kind(HPtr array_hptr, uint32_t intended_kind);

} // extern "C"

namespace Elm {
// Returns an `EvalParamLayout` of `n` parameters, all boxed, with result kind `K` (a `K` above 3 is taken
// as 0).
//
// `n` must be at most `CLOSURE_MAX_ARITY` (asserted). The layout is shared and never freed: for `n` up to
// 64 it is a static table entry, and above that it is built once per `(n, K)` under a mutex and kept for
// the life of the process.
const EvalParamLayout* getAllBoxedLayout(unsigned n, uint8_t K);
}

// Pushes root ranges covering the `n` words at `base`, in which word i is an HPointer when `kindOf(i)`
// returns 0.
//
// The words are pushed in ranges of at most 64, the limit of `eco_gc_push_stack_range`, and a range with
// no HPointer is not pushed. The caller pops them by restoring a point it took with
// `eco_gc_stack_range_point`, and the words must stay valid until then.
template <class KindOf>
inline void pushRootsByKinds(uint64_t* base, uint32_t n, KindOf kindOf) {
    for (uint32_t off = 0; off < n; off += 64) {
        uint32_t c = std::min<uint32_t>(64, n - off);
        uint64_t mask = 0;
        for (uint32_t i = 0; i < c; ++i) if (kindOf(off + i) == 0) mask |= uint64_t{1} << i;
        if (mask) eco_gc_push_stack_range(base + off, c, mask);
    }
}

#endif // ECO_RUNTIME_EXPORTS_H
