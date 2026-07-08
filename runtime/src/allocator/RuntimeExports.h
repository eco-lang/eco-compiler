//===- RuntimeExports.h - C-linkage runtime functions for LLVM calls ------===//
//
// This file declares the C-linkage functions that are called from LLVM-generated
// code. These wrap the C++ Allocator API for use by the Eco compiler.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_RUNTIME_EXPORTS_H
#define ECO_RUNTIME_EXPORTS_H

#include <cstddef>
#include <cstdint>

#include "Heap.hpp"

namespace Elm { struct EvalParamLayout; }

using Elm::HPtr;

/// Inline helper: reinterpret a `void*` from the evaluator-return ABI as an
/// HPtr. The wrapper protocol (`void *(void *[])`) carries the closure
/// result as a raw 64-bit pointer-shaped word; this helper centralises the
/// cast at one site so future ABI tweaks have a single place to land.
inline HPtr ptr0ToHPtr(void* p) {
    return HPtr::fromBits(reinterpret_cast<uint64_t>(p));
}

extern "C" {

//===----------------------------------------------------------------------===//
// Output Capture API (for EcoRunner)
//===----------------------------------------------------------------------===//

/// Sets the output stream for eco_dbg_print functions.
/// Pass a pointer to an std::ostringstream to capture output.
/// Pass nullptr to restore default behavior (output to stderr).
/// Returns the previous stream pointer.
void* eco_set_output_stream(void* stream);

/// Gets the current output stream for eco_dbg_print functions.
/// Returns nullptr if output goes to stderr.
void* eco_get_output_stream();

//===----------------------------------------------------------------------===//
// Allocation Functions
//===----------------------------------------------------------------------===//

/// Generic allocation with caller-supplied roots. The primary entry point
/// for kernel C++ allocation: handles the fast-path (no rooting) /
/// slow-path (rooted) split internally. Returns the raw heap object
/// pointer with `Header.tag` and `Header.size` pre-initialised by
/// initHeaderForTag; the caller fills in tag-specific fields (ctor,
/// unboxed bitmap, values, etc.) afterwards.
///
/// On the fast path no rooting happens — `allocateFast` cannot trigger
/// GC, so values in `roots[]` are not at risk. On the slow path the
/// helper opens a stack root range over `roots[]` with `hptr_mask`,
/// runs `allocateSlow` (which may GC), then closes the range. After the
/// call returns, callers must read post-GC HPointer values back from
/// `roots[]` (the GC updates the addresses in place).
///
/// @param tag        Heap tag of the object to allocate (Tag_Cons, ...).
/// @param size       Aligned byte size of the object.
/// @param roots      Caller-owned uint64_t buffer of HPointer-bearing
///                   values to keep live across a possible slow-path GC.
///                   May be nullptr if `n_roots`/`hptr_mask` are 0.
/// @param n_roots    Number of slots in `roots[]` (max 64).
/// @param hptr_mask  Bit i set iff `roots[i]` is an HPointer the GC
///                   should evacuate; cleared bits are left untouched
///                   (use for unboxed Int/Float/Char fields).
/// @return Raw heap pointer (NOT an HPointer); use `Allocator::wrap` if
///         you need an HPointer.
void* eco_alloc_with_roots(uint32_t tag, uint64_t size,
                            uint64_t* roots, uint32_t n_roots,
                            uint64_t hptr_mask);

/// Allocates a Custom ADT object.
/// @param ctor_id     Constructor tag (per Elm ADT, stored in Custom.ctor)
/// @param field_count Number of pointer-sized fields
/// @param scalar_bytes Additional bytes for unboxed scalar fields
/// @return HPointer (as uint64_t) to the allocated object
HPtr eco_alloc_custom(uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes);

/// Allocates and initializes a Cons cell (list node).
/// @param head The head element value (HPointer or unboxed primitive as uint64_t)
/// @param tail The tail list HPointer (as uint64_t)
/// @param head_unboxed 0 if head is a boxed pointer, 1 if head is an unboxed primitive
/// @return HPointer (as uint64_t) to the allocated Cons object
HPtr eco_alloc_cons(uint64_t head, HPtr tail, uint32_t head_unboxed);

/// Allocates and initializes a Tuple2.
/// @param a First element (HPointer or unboxed primitive as uint64_t)
/// @param b Second element (HPointer or unboxed primitive as uint64_t)
/// @param unboxed_mask Bitmap: bit 0 = a is unboxed, bit 1 = b is unboxed
/// @return HPointer (as uint64_t) to the allocated Tuple2 object
HPtr eco_alloc_tuple2(uint64_t a, uint64_t b, uint32_t unboxed_mask);

/// Allocates and initializes a Tuple3.
/// @param a First element (HPointer or unboxed primitive as uint64_t)
/// @param b Second element (HPointer or unboxed primitive as uint64_t)
/// @param c Third element (HPointer or unboxed primitive as uint64_t)
/// @param unboxed_mask Bitmap: bit 0 = a, bit 1 = b, bit 2 = c
/// @return HPointer (as uint64_t) to the allocated Tuple3 object
HPtr eco_alloc_tuple3(uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask);

/// Allocates a Record with the specified number of fields.
/// Fields must be stored separately using eco_store_record_field* functions.
/// @param field_count Number of fields in the record
/// @param unboxed_bitmap Bitmap indicating which fields are unboxed primitives
/// @return HPointer (as uint64_t) to the allocated Record object
HPtr eco_alloc_record(uint32_t field_count, uint64_t unboxed_bitmap);

/// Stores a boxed pointer field in a Record.
/// @param record HPointer (as uint64_t) to the Record object
/// @param index Field index
/// @param value HPointer value to store (as uint64_t)
void eco_store_record_field(HPtr record, uint32_t index, HPtr value);

/// Stores an unboxed i64 field in a Record.
/// @param record HPointer (as uint64_t) to the Record object
/// @param index Field index
/// @param value Integer value to store
void eco_store_record_field_i64(HPtr record, uint32_t index, int64_t value);

/// Stores an unboxed f64 field in a Record.
/// @param record HPointer (as uint64_t) to the Record object
/// @param index Field index
/// @param value Float value to store
void eco_store_record_field_f64(HPtr record, uint32_t index, double value);

//===----------------------------------------------------------------------===//
// Uninit Allocators + Field Stores (alloc-then-store pattern; future work)
//
// Forward-compatible runtime ABI introduced by the wrapper-fca-fix plan.
// The companion lowering changes are NOT enabled in the current build — see
// plans/wrapper-fca-fix.md for the deferred portions. The runtime entries
// land here so subsequent re-enable lands without further ABI churn.
//===----------------------------------------------------------------------===//

HPtr eco_alloc_tuple2_uninit(uint32_t unboxed_mask);
HPtr eco_alloc_tuple3_uninit(uint32_t unboxed_mask);
HPtr eco_alloc_cons_uninit(uint32_t head_kind);
void eco_store_tuple_field(HPtr tuple, uint32_t index, HPtr value);
void eco_store_tuple_field_i64(HPtr tuple, uint32_t index, int64_t value);
void eco_store_tuple_field_f64(HPtr tuple, uint32_t index, double value);
void eco_store_cons_head(HPtr cons, HPtr value);
void eco_store_cons_head_i64(HPtr cons, int64_t value);
void eco_store_cons_head_f64(HPtr cons, double value);
void eco_store_cons_tail(HPtr cons, HPtr value);

/// Allocates a string with the specified length.
/// @param length Number of UTF-16 code units
/// @return HPointer (as uint64_t) to the allocated ElmString object
HPtr eco_alloc_string(uint32_t length);

/// Allocates a string literal directly in old generation (permanent, never collected).
/// Used for compile-time string constants.
/// @param chars Pointer to UTF-16 character data
/// @param length Number of UTF-16 code units
/// @return HPointer (as uint64_t) to the allocated ElmString object
HPtr eco_alloc_string_literal(const uint16_t* chars, uint32_t length);

/// Allocates an ASCII string literal as a permanent inline UTF-8 leaf
/// (Tag_StringUtf8Leaf). The compiler emits this for literals whose bytes are
/// all < 0x80, passing an [N x i8] global. Interned by the global's address.
/// @param bytes  Pointer to the ASCII byte data (each < 0x80)
/// @param byteLen Number of bytes == logical UTF-16 code-unit count
/// @return HPointer (as uint64_t) to the allocated string
HPtr eco_alloc_string_literal_utf8(const uint8_t* bytes, uint32_t byteLen);

/// Allocates a closure object with PK_Boxed result kind (legacy entry).
/// Forwards to `eco_alloc_closure_k(func_ptr, num_captures, PK_Boxed)` so
/// existing callers (which all return boxed Tasks/HPointers) keep working
/// byte-for-byte.
/// @param func_ptr Pointer to the evaluator function
/// @param num_captures Number of captured values
/// @return HPointer (as uint64_t) to the allocated Closure object
HPtr eco_alloc_closure(void* func_ptr, uint32_t num_captures);

/// Allocates a closure object with an explicit result kind.
/// `result_kind` records the C-ABI return type of `func_ptr` (ParamKind:
/// 0 = PK_Boxed / HPtr, 1 = PK_Int, 2 = PK_Float, 3 = PK_Char). Stored on
/// the closure header so every closure-invocation entry point (legacy and
/// typed) can cast `closure->evaluator` correctly without per-call-site
/// plumbing.
/// @param func_ptr Pointer to the evaluator function
/// @param num_captures Number of captured values
/// @param result_kind ParamKind value matching `func_ptr`'s return ABI
/// @return HPointer (as uint64_t) to the allocated Closure object
HPtr eco_alloc_closure_k(void* func_ptr, uint32_t num_captures,
                         uint8_t result_kind);

/// Allocates a boxed Int.
/// @param value The integer value
/// @return HPointer (as uint64_t) to the allocated ElmInt object
HPtr eco_alloc_int(int64_t value);

/// Allocates a boxed Float.
/// @param value The floating-point value
/// @return HPointer (as uint64_t) to the allocated ElmFloat object
HPtr eco_alloc_float(double value);

/// Allocates a boxed Char.
/// @param value The character (Unicode code point)
/// @return HPointer (as uint64_t) to the allocated ElmChar object
HPtr eco_alloc_char(uint32_t value);

/// Generic allocation with specified size and tag.
/// @param size Size in bytes to allocate
/// @param tag Object type tag (Tag enum value)
/// @return HPointer (as uint64_t) to the allocated object
HPtr eco_allocate(uint64_t size, uint32_t tag);

/// Sets the unboxed bitmap for a heap object.
/// @param obj HPointer (as uint64_t) to the heap object
/// @param bitmap Bitmap indicating which fields are unboxed
void eco_set_unboxed(HPtr obj, uint64_t bitmap);

//===----------------------------------------------------------------------===//
// Fast Allocation Functions (bump-pointer only, no GC, return 0 on failure)
//===----------------------------------------------------------------------===//

HPtr eco_alloc_custom_fast(uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes);
HPtr eco_alloc_cons_fast(uint64_t head, HPtr tail, uint32_t head_unboxed);
HPtr eco_alloc_tuple2_fast(uint64_t a, uint64_t b, uint32_t unboxed_mask);
HPtr eco_alloc_tuple3_fast(uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask);
HPtr eco_alloc_record_fast(uint32_t field_count, uint64_t unboxed_bitmap);
HPtr eco_alloc_string_fast(uint32_t length);
HPtr eco_alloc_closure_fast(void* func_ptr, uint32_t num_captures);
HPtr eco_alloc_int_fast(int64_t value);
HPtr eco_alloc_float_fast(double value);
HPtr eco_alloc_char_fast(uint32_t value);

//===----------------------------------------------------------------------===//
// Slow Allocation Functions (may GC, always succeed — used behind statepoint)
//===----------------------------------------------------------------------===//

HPtr eco_alloc_custom_slow(uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes);
HPtr eco_alloc_cons_slow(uint64_t head, HPtr tail, uint32_t head_unboxed);
HPtr eco_alloc_tuple2_slow(uint64_t a, uint64_t b, uint32_t unboxed_mask);
HPtr eco_alloc_tuple3_slow(uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask);
HPtr eco_alloc_record_slow(uint32_t field_count, uint64_t unboxed_bitmap);
HPtr eco_alloc_string_slow(uint32_t length);
HPtr eco_alloc_closure_slow(void* func_ptr, uint32_t num_captures);

/// Allocate a group of sibling closures atomically for mutually-recursive
/// let-rec. All siblings co-reside in a single contiguous region, so
/// cross-sibling HPointer stores after allocation need no write barrier
/// (same-generation). `arities[i]` is max_values (total closure capacity),
/// `numCaptured[i]` is n_values (the count of already-captured slots).
/// Non-sibling captures are written from a flat `captures[]` array
/// partitioned by `captureOffsets` (prefix sums, length numSiblings+1).
/// Cross-sibling captures are written after all HPointers are known,
/// using `crossEdges` flat triples [producer, consumer, slot] of length
/// `3 * numCrossEdges`. The resulting HPointers are stored in
/// `outClosures[0..numSiblings)` in sibling order.
/// `resultKinds[i]` is the ParamKind value (0..3) recording the C-ABI
/// return type of `evaluators[i]`. Stored on each sibling's closure
/// header so dispatch paths can cast `closure->evaluator` correctly.
void eco_alloc_closure_group_slow(
    uint64_t numSiblings,
    const void* const* evaluators,
    const uint32_t* arities,
    const uint32_t* numCaptured,
    const uint64_t* unboxedBitmaps,
    const uint8_t* resultKinds,
    const uint32_t* captureOffsets,
    const uint64_t* captures,
    const uint64_t* crossEdges,
    uint64_t numCrossEdges,
    uint64_t* outClosures);
HPtr eco_alloc_int_slow(int64_t value);
HPtr eco_alloc_float_slow(double value);
HPtr eco_alloc_char_slow(uint32_t value);

//===----------------------------------------------------------------------===//
// Region Allocation (fast returns nullptr, slow may GC)
//===----------------------------------------------------------------------===//

void* eco_gc_alloc_region_fast(size_t total);
void* eco_gc_alloc_region_slow(size_t total);

//===----------------------------------------------------------------------===//
// Init-at-pointer Functions (for group allocation)
// Initialize an object at a pre-allocated pointer and return HPointer.
//===----------------------------------------------------------------------===//

HPtr eco_init_int_at(void* ptr, int64_t value);
HPtr eco_init_float_at(void* ptr, double value);
HPtr eco_init_char_at(void* ptr, uint32_t value);
HPtr eco_init_cons_at(void* ptr, uint64_t head, HPtr tail, uint32_t head_unboxed);
HPtr eco_init_tuple2_at(void* ptr, uint64_t a, uint64_t b, uint32_t unboxed_mask);
HPtr eco_init_tuple3_at(void* ptr, uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask);
HPtr eco_init_record_at(void* ptr, uint32_t field_count, uint64_t unboxed_bitmap);
HPtr eco_init_custom_at(void* ptr, uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes);
HPtr eco_init_string_at(void* ptr, uint32_t length);

//===----------------------------------------------------------------------===//
// Field Store Functions
//===----------------------------------------------------------------------===//

/// Stores a pointer field in an object.
/// @param obj HPointer (as uint64_t) to the heap object
/// @param index Field index
/// @param value Value to store (as i64 tagged pointer)
void eco_store_field(HPtr obj, uint32_t index, HPtr value);

/// Stores an unboxed i64 field in an object.
/// @param obj HPointer (as uint64_t) to the heap object
/// @param index Field index
/// @param value Value to store
void eco_store_field_i64(HPtr obj, uint32_t index, int64_t value);

/// Stores an unboxed f64 field in an object.
/// @param obj HPointer (as uint64_t) to the heap object
/// @param index Field index
/// @param value Value to store
void eco_store_field_f64(HPtr obj, uint32_t index, double value);

//===----------------------------------------------------------------------===//
// Closure Operations
//===----------------------------------------------------------------------===//

/// Generic apply: applies arguments to a closure, handling all saturation cases.
/// - Under-saturated (num_args < remaining): returns new PAP with additional captures.
/// - Exactly saturated (num_args == remaining): calls evaluator, returns result.
/// - Over-saturated (num_args > remaining): saturates this stage, then recursively
///   applies remaining args to the result closure (chaining per-stage evaluators).
/// @param closure HPointer (as uint64_t) to the Closure object
/// @param args Array of arguments (as i64 tagged pointers / HPointer-encoded)
/// @param num_args Number of arguments
/// @return Result value or new closure (as HPointer uint64_t)
HPtr eco_apply_closure(HPtr closure, uint64_t* args, uint32_t num_args);

/// Phase D typed-args entry point for generic apply.
/// Takes args as a typed `int64_t*` buffer where each slot's interpretation
/// is given by `args_layout->kinds[i]` (0=PK_Boxed HPointer, 1=PK_Int,
/// 2=PK_Float, 3=PK_Char). Re-boxes any non-PK_Boxed slot via
/// `eco_alloc_int` / `eco_alloc_float` / `eco_alloc_char` then forwards to
/// `eco_apply_closure`. When `args_layout` is null all slots are treated
/// as PK_Boxed (legacy semantics).
/// @param closure HPointer to the Closure object
/// @param typed_args Typed args buffer (slot interpretation per `args_layout->kinds`)
/// @param num_args Number of new arguments
/// @param args_layout Per-slot kind descriptor (may be null)
/// @return Result value or new closure
HPtr eco_apply_closure_typed(HPtr closure, int64_t* typed_args,
                             uint32_t num_args,
                             const Elm::EvalParamLayout* args_layout);

/// Generic apply with a fully typed result.
///
/// Reads the closure's intrinsic result kind from `args_layout->result_kind`
/// (set by the frontend at the call site to match the closure evaluator's
/// real C ABI). The closure header is unchanged from `eco_apply_closure_typed`;
/// the result kind lives in the layout.
///
/// `desired_kind` is the kind the caller wants the result delivered as
/// (typically derived from the call op's MLIR result type via
/// `mlirTypeToParamKind`). The helper either passes the evaluator's result
/// straight through (when `desired_kind == result_kind`), or boxes/unboxes
/// across the kind boundary to satisfy the caller.
///
/// `result_slot` must point to storage of the matching desired_kind:
///   - PK_Boxed → `HPtr*`
///   - PK_Int   → `int64_t*`
///   - PK_Float → `double*`
///   - PK_Char  → `uint16_t*`
///
/// Saturation is dispatched the same way `eco_apply_closure_typed` does
/// (reads the closure header). Under-saturated calls produce a closure
/// HPtr; the helper asserts `desired_kind == PK_Boxed` in that case (a
/// well-typed primitive-result call is by construction saturated).
///
/// @param closure HPtr to the Closure object
/// @param typed_args Typed args buffer (slot kinds per `args_layout->kinds`)
/// @param num_args Number of new arguments
/// @param args_layout Per-slot kind descriptor + closure result kind
/// @param result_slot Pointer to storage receiving the result
/// @param desired_kind Caller's desired result kind (ParamKind)
void eco_apply_closure_eval(HPtr closure, int64_t* typed_args,
                            uint32_t num_args,
                            const Elm::EvalParamLayout* args_layout,
                            void* result_slot,
                            uint8_t desired_kind);

/// Extends a PAP with more arguments (partial application).
/// Creates a new closure with the combined captured values.
/// @param closure HPointer (as uint64_t) to the Closure object
/// @param args Array of new arguments
/// @param num_newargs Number of new arguments
/// @param new_unboxed_bitmap Bitmap indicating which new args are unboxed primitives
/// @return New closure with additional captured values (as HPointer uint64_t)
HPtr eco_pap_extend(HPtr closure, uint64_t* args, uint32_t num_newargs, uint64_t new_unboxed_bitmap);

/// Calls a fully saturated closure.
/// Combines captured values with new args and invokes the evaluator.
/// @param closure HPointer (as uint64_t) to the Closure object
/// @param new_args Array of new arguments
/// @param num_newargs Number of new arguments (n_values + num_newargs must equal max_values)
/// @return Result of the function call (as i64)
HPtr eco_closure_call_saturated(HPtr closure, uint64_t* new_args, uint32_t num_newargs, const Elm::EvalParamLayout* layout);

/// Typed-result sibling of `eco_closure_call_saturated`. Writes the result
/// into `result_slot` cast to the type implied by `desired_kind`
/// (0=HPtr, 1=int64_t, 2=double, 3=uint16_t). When the closure evaluator's
/// real return kind matches `desired_kind`, no boxing happens — the
/// primitive flows directly from the wrapper into the slot. Used by the JIT
/// at saturated call sites whose SSA result type is primitive.
void eco_closure_call_saturated_eval(
    HPtr closure, uint64_t* new_args, uint32_t num_newargs,
    const Elm::EvalParamLayout* layout, void* result_slot,
    uint8_t desired_kind);

/// Applies arguments to a closure with known ABI but unknown staging.
/// Reads the closure header to determine saturation at runtime, then routes:
///   - under-saturated → eco_pap_extend (typed args + bitmap derived from layout)
///   - saturated/over → eco_apply_closure_typed (centralises any re-boxing)
/// @param closure HPointer (as uint64_t) to the Closure object
/// @param typed_args Array of typed args (raw i64 storage; per-slot kind in `args_layout`)
/// @param num_args Number of new arguments
/// @param args_layout Per-slot ParamKind descriptor (may be null = all PK_Boxed)
/// @return Result of the application (as HPointer i64)
HPtr eco_apply_segmentation_unknown(HPtr closure, int64_t* typed_args,
                                    uint32_t num_args,
                                    const Elm::EvalParamLayout* args_layout);

//===----------------------------------------------------------------------===//
// Runtime Utilities
//===----------------------------------------------------------------------===//

/// Crashes the program with an error message.
/// @param message HPointer (as uint64_t) to an ElmString containing the error message
[[noreturn]] void eco_crash(HPtr message);

/// Debug print for boxed values (for eco.dbg op).
/// @param args Array of values to print
/// @param num_args Number of values
void eco_dbg_print(uint64_t* args, uint32_t num_args);

/// Debug print for unboxed integer.
/// @param value The integer value
void eco_dbg_print_int(int64_t value);

/// Debug print for unboxed float.
/// @param value The float value
void eco_dbg_print_float(double value);

/// Debug print for unboxed char.
/// @param value The character (Unicode code point)
void eco_dbg_print_char(int32_t value);

/// Debug print with full type information (for eco.dbg with arg_type_ids).
/// Uses the global type graph (__eco_type_graph) to pretty-print values
/// with proper Elm syntax including field names and constructor names.
/// @param values Array of 64-bit values (pointers or unboxed numbers)
/// @param type_ids Array of TypeIds (one per value)
/// @param num_args Number of values
void eco_dbg_print_typed(uint64_t* values, uint32_t* type_ids, uint32_t num_args);

/// Register the global type graph from JITed code.
/// Called at module initialization before main runs.
/// @param graph Pointer to the EcoTypeGraph structure (opaque, uses void* for C linkage)
void eco_register_type_graph(const void* graph);

/// Outputs text to the current output stream (stderr or capture buffer).
/// Used by kernel functions like Debug.log.
/// @param text The text to output
void eco_output_text(const char* text);

/// Prints an Elm value to the current output stream in Elm syntax.
/// Used by eco.dbg and Debug.toString.
/// @param value The value to print (as 64-bit encoded pointer)
void eco_print_value(HPtr value);

/// Prints an Elm value, unwrapping Ctor0 box wrappers from Guida compiler.
/// Used by Debug.log to show clean Elm values without internal wrappers.
/// @param value The value to print (as 64-bit encoded pointer)
void eco_print_elm_value(HPtr value);

/// Converts an Elm value to its string representation.
/// Allocates and returns a new ElmString.
/// @param value The value to convert (as 64-bit encoded pointer)
/// @return HPointer (as uint64_t) to the allocated ElmString
HPtr eco_value_to_string(HPtr value);

/// Convert a value to its string representation using type graph information.
/// @param value The value to convert (as 64-bit encoded pointer)
/// @param type_id The type graph type ID for the value (-1 for untyped fallback)
/// @return HPointer (as uint64_t) to the allocated ElmString
HPtr eco_value_to_string_typed(HPtr value, int64_t type_id);

//===----------------------------------------------------------------------===//
// GC Interface
//===----------------------------------------------------------------------===//

/// GC safepoint check (currently no-op).
/// In the future, this will check if GC needs to run.
void eco_safepoint();

/// GC safepoint poll — statepoint target call.
/// Checks nursery threshold + force flag; triggers collection if needed.
void __eco_safepoint_poll();

/// Triggers a minor GC.
void eco_minor_gc();

/// Triggers a major GC.
void eco_major_gc();

/// Registers a JIT global as a GC root.
/// @param root_ptr Pointer to a location holding a raw 64-bit heap pointer.
/// This is used by JIT-compiled globals which store full heap addresses
/// rather than HPointer-encoded values.
void eco_gc_add_root(uint64_t* root_ptr);

/// Unregisters a JIT global from the GC root set.
/// @param root_ptr Pointer previously registered with eco_gc_add_root.
void eco_gc_remove_root(uint64_t* root_ptr);

/// Returns the number of registered JIT roots (for testing).
uint64_t eco_gc_jit_root_count();

/// Registers an Elm value slot as a GC root (encoded HPointer).
/// @param value_ptr Pointer to a location holding an encoded Elm value
///        (HPointer representation: heap offsets + embedded constants).
/// The collector treats *value_ptr as an HPointer: heap objects are traced
/// and updated in place; embedded constants (constant!=0) are ignored.
void eco_gc_add_value_root(uint64_t* value_ptr);

/// Unregisters an Elm value root previously registered with eco_gc_add_value_root.
void eco_gc_remove_value_root(uint64_t* value_ptr);

/// Stack root range management for compiled code and C++ runtime.
/// Registers contiguous stack arrays as GC root ranges so the collector
/// can trace HPointers stored in alloca- or stack-backed args arrays
/// (e.g., LLVM alloca args, C++ combined_args for closure evaluators).
size_t   eco_gc_stack_range_point();
void     eco_gc_push_stack_range(uint64_t* base, size_t count, uint64_t hpointer_mask);
void     eco_gc_restore_stack_range_point(size_t point);

//===----------------------------------------------------------------------===//
// Tag Extraction
//===----------------------------------------------------------------------===//

/// Extracts the Header.tag field from a heap object.
/// @param obj HPointer (as uint64_t) to the heap object
/// @return The tag value (Tag enum)
uint32_t eco_get_header_tag(HPtr obj);

/// Extracts the Custom.ctor field from a Custom object.
/// @param obj HPointer (as uint64_t) to the Custom object
/// @return The constructor tag
uint32_t eco_get_custom_ctor(HPtr obj);

/// Get constructor tag for a value, handling both heap objects and embedded constants.
/// For heap Custom objects: returns the ctor field (16-bit constructor tag).
/// For embedded constants: returns the appropriate ctor tag:
///   - Nothing (kind=6) -> tag=1 (second constructor of Maybe)
///   - Nil (kind=5) -> tag=0 (first constructor of List)
///   - Other embedded constants -> tag=0
/// @param val HPointer (as uint64_t) to the value
/// @return The constructor tag
uint32_t eco_get_tag(HPtr val);

//===----------------------------------------------------------------------===//
// List Element Access
//===----------------------------------------------------------------------===//

/// Gets the head of a Cons cell as an unboxed i64.
/// Handles both boxed and unboxed heads:
/// - If head is unboxed: returns the value directly from Cons.head
/// - If head is boxed: resolves the HPointer and loads from ElmInt.value
/// @param cons HPointer (as uint64_t) to the Cons cell
/// @return The head value as i64
int64_t eco_cons_head_i64(HPtr cons);

/// Gets the head of a Cons cell as an unboxed f64.
/// Handles both boxed and unboxed heads:
/// - If head is unboxed: returns the value directly from Cons.head
/// - If head is boxed: resolves the HPointer and loads from ElmFloat.value
/// @param cons HPointer (as uint64_t) to the Cons cell
/// @return The head value as f64
double eco_cons_head_f64(HPtr cons);

/// Gets the head of a Cons cell as an unboxed i16 (Elm Char).
/// Handles both boxed and unboxed heads:
/// - If head is unboxed: returns the value directly from Cons.head
/// - If head is boxed: resolves the HPointer and loads from ElmChar.value
/// @param cons HPointer (as uint64_t) to the Cons cell
/// @return The head value as i16
int16_t eco_cons_head_i16(HPtr cons);

//===----------------------------------------------------------------------===//
// Tuple field access (gc-leaf, non-allocating).
//
// Reads the requested slot unconditionally as the requested primitive type.
// Per the 2-bit unboxed kind bitmap, an `i64`-typed slot is always stored as
// the unboxed `i` union member, etc. — no dual boxed/unboxed path needed
// (unlike eco_cons_head_*).
//
// Pattern C fix: keeping resolve+load inside a runtime call (rather than
// emitting the GEP+load in user IR between two safepoints) prevents
// RS4GC + later code motion from rematerialising heap-pointer arithmetic
// past a statepoint and reloading from a stale address.
//===----------------------------------------------------------------------===//

int64_t eco_tuple2_get0_i64(HPtr tup);
int64_t eco_tuple2_get1_i64(HPtr tup);
double  eco_tuple2_get0_f64(HPtr tup);
double  eco_tuple2_get1_f64(HPtr tup);
int16_t eco_tuple2_get0_i16(HPtr tup);
int16_t eco_tuple2_get1_i16(HPtr tup);

int64_t eco_tuple3_get0_i64(HPtr tup);
int64_t eco_tuple3_get1_i64(HPtr tup);
int64_t eco_tuple3_get2_i64(HPtr tup);
double  eco_tuple3_get0_f64(HPtr tup);
double  eco_tuple3_get1_f64(HPtr tup);
double  eco_tuple3_get2_f64(HPtr tup);
int16_t eco_tuple3_get0_i16(HPtr tup);
int16_t eco_tuple3_get1_i16(HPtr tup);
int16_t eco_tuple3_get2_i16(HPtr tup);

//===----------------------------------------------------------------------===//
// Record / Custom field access (gc-leaf, non-allocating).
// Same Pattern-C rationale as the tuple helpers.
//===----------------------------------------------------------------------===//

int64_t eco_record_get_i64(HPtr rec, uint32_t field_index);
double  eco_record_get_f64(HPtr rec, uint32_t field_index);
int16_t eco_record_get_i16(HPtr rec, uint32_t field_index);

int64_t eco_custom_get_i64(HPtr val, uint32_t field_index);
double  eco_custom_get_f64(HPtr val, uint32_t field_index);
int16_t eco_custom_get_i16(HPtr val, uint32_t field_index);

//===----------------------------------------------------------------------===//
// Array element access (gc-leaf, non-allocating).
// Index is `int64_t` to mirror the `Eco_Int` SSA operand on `eco.array.get`.
//===----------------------------------------------------------------------===//

int64_t eco_array_get_i64(HPtr arr, int64_t index);
double  eco_array_get_f64(HPtr arr, int64_t index);
int16_t eco_array_get_i16(HPtr arr, int64_t index);

//===----------------------------------------------------------------------===//
// Arithmetic Helpers
//===----------------------------------------------------------------------===//

/// Integer exponentiation: base^exp
/// Returns 0 for negative exponents (since result would be fractional).
/// @param base The base value
/// @param exp The exponent value
/// @return base raised to the power of exp
int64_t eco_int_pow(int64_t base, int64_t exp);

//===----------------------------------------------------------------------===//
// HPointer Conversion
//===----------------------------------------------------------------------===//

/// Convert an HPointer-encoded uint64_t to a raw heap pointer.
/// Uses Allocator::resolve() to handle forwarding pointers during GC.
/// Returns nullptr for embedded constants (Nil, True, False, etc.).
///
/// GC INVARIANT: This function MUST NOT allocate or trigger GC.
/// Closure wrappers call eco_resolve_hptr without safepoint markers,
/// relying on it being non-allocating. Any allocation here would
/// require adding safepoints around all wrapper resolve calls.
///
/// @param hptr HPointer value (as uint64_t)
/// @return Raw pointer to the heap object, or nullptr
void* eco_resolve_hptr(HPtr hptr);

/// Stale-pointer barrier emitted by the EcoBoxedStoreVerify pass before
/// each compiled-Elm direct heap store of a boxed value. Routes the bits
/// through Elm::alloc::validateNurseryHPtrBits, which resolves the
/// HPointer; resolves that land in the just-evacuated from-space trip
/// the always-on debugAssertValidNurseryPointer with diagnostics
/// pinpointing the offending compiled frame. No-op for null/embedded
/// constants. Always exported so the JIT can resolve the symbol; the
/// pass that inserts the call is gated by ECO_LOWERING_VALIDATION.
void eco_validate_nursery_hptr_bits(uint64_t bits);

/// Clone an ElmArray, returning a new array with the same contents.
/// Used by eco.array.set lowering for functional array update.
/// @param array_hptr HPointer to source ElmArray (as uint64_t)
/// @return HPointer to new ElmArray copy (as uint64_t)
HPtr eco_clone_array(HPtr array_hptr);

/// Force the unboxed-kind flag on an ElmArray to match what its slots actually
/// hold. Emitted right after `eco_clone_array` by the eco.array.set lowering
/// so the cloned array's kind flag tracks the value the new slot stores —
/// otherwise the next minor GC misreads a raw i64 as an HPointer.
/// @param array_hptr HPointer to ElmArray.
/// @param intended_kind Desired uniform kind (0=boxed, 1=Int, 2=Float, 3=Char).
void eco_array_set_fix_kind(HPtr array_hptr, uint32_t intended_kind);

} // extern "C"

#endif // ECO_RUNTIME_EXPORTS_H
