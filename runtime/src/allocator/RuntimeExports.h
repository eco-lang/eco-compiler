//===- RuntimeExports.h - C-linkage runtime functions for LLVM calls ------===//
//
// This file declares the C-linkage functions that are called from LLVM-generated
// code. These wrap the C++ Allocator API for use by the Eco compiler.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_RUNTIME_EXPORTS_H
#define ECO_RUNTIME_EXPORTS_H

#include <cstdint>

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

/// Allocates a Custom ADT object.
/// @param ctor_id     Constructor tag (per Elm ADT, stored in Custom.ctor)
/// @param field_count Number of pointer-sized fields
/// @param scalar_bytes Additional bytes for unboxed scalar fields
/// @return HPointer (as uint64_t) to the allocated object
uint64_t eco_alloc_custom(uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes);

/// Allocates and initializes a Cons cell (list node).
/// @param head The head element value (HPointer or unboxed primitive as uint64_t)
/// @param tail The tail list HPointer (as uint64_t)
/// @param head_unboxed 0 if head is a boxed pointer, 1 if head is an unboxed primitive
/// @return HPointer (as uint64_t) to the allocated Cons object
uint64_t eco_alloc_cons(uint64_t head, uint64_t tail, uint32_t head_unboxed);

/// Allocates and initializes a Tuple2.
/// @param a First element (HPointer or unboxed primitive as uint64_t)
/// @param b Second element (HPointer or unboxed primitive as uint64_t)
/// @param unboxed_mask Bitmap: bit 0 = a is unboxed, bit 1 = b is unboxed
/// @return HPointer (as uint64_t) to the allocated Tuple2 object
uint64_t eco_alloc_tuple2(uint64_t a, uint64_t b, uint32_t unboxed_mask);

/// Allocates and initializes a Tuple3.
/// @param a First element (HPointer or unboxed primitive as uint64_t)
/// @param b Second element (HPointer or unboxed primitive as uint64_t)
/// @param c Third element (HPointer or unboxed primitive as uint64_t)
/// @param unboxed_mask Bitmap: bit 0 = a, bit 1 = b, bit 2 = c
/// @return HPointer (as uint64_t) to the allocated Tuple3 object
uint64_t eco_alloc_tuple3(uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask);

/// Allocates a Record with the specified number of fields.
/// Fields must be stored separately using eco_store_record_field* functions.
/// @param field_count Number of fields in the record
/// @param unboxed_bitmap Bitmap indicating which fields are unboxed primitives
/// @return HPointer (as uint64_t) to the allocated Record object
uint64_t eco_alloc_record(uint32_t field_count, uint64_t unboxed_bitmap);

/// Stores a boxed pointer field in a Record.
/// @param record HPointer (as uint64_t) to the Record object
/// @param index Field index
/// @param value HPointer value to store (as uint64_t)
void eco_store_record_field(uint64_t record, uint32_t index, uint64_t value);

/// Stores an unboxed i64 field in a Record.
/// @param record HPointer (as uint64_t) to the Record object
/// @param index Field index
/// @param value Integer value to store
void eco_store_record_field_i64(uint64_t record, uint32_t index, int64_t value);

/// Stores an unboxed f64 field in a Record.
/// @param record HPointer (as uint64_t) to the Record object
/// @param index Field index
/// @param value Float value to store
void eco_store_record_field_f64(uint64_t record, uint32_t index, double value);

/// Allocates a string with the specified length.
/// @param length Number of UTF-16 code units
/// @return HPointer (as uint64_t) to the allocated ElmString object
uint64_t eco_alloc_string(uint32_t length);

/// Allocates a string literal directly in old generation (permanent, never collected).
/// Used for compile-time string constants.
/// @param chars Pointer to UTF-16 character data
/// @param length Number of UTF-16 code units
/// @return HPointer (as uint64_t) to the allocated ElmString object
uint64_t eco_alloc_string_literal(const uint16_t* chars, uint32_t length);

/// Allocates a closure object.
/// @param func_ptr Pointer to the evaluator function
/// @param num_captures Number of captured values
/// @return HPointer (as uint64_t) to the allocated Closure object
uint64_t eco_alloc_closure(void* func_ptr, uint32_t num_captures);

/// Allocates a boxed Int.
/// @param value The integer value
/// @return HPointer (as uint64_t) to the allocated ElmInt object
uint64_t eco_alloc_int(int64_t value);

/// Allocates a boxed Float.
/// @param value The floating-point value
/// @return HPointer (as uint64_t) to the allocated ElmFloat object
uint64_t eco_alloc_float(double value);

/// Allocates a boxed Char.
/// @param value The character (Unicode code point)
/// @return HPointer (as uint64_t) to the allocated ElmChar object
uint64_t eco_alloc_char(uint32_t value);

/// Generic allocation with specified size and tag.
/// @param size Size in bytes to allocate
/// @param tag Object type tag (Tag enum value)
/// @return HPointer (as uint64_t) to the allocated object
uint64_t eco_allocate(uint64_t size, uint32_t tag);

/// Sets the unboxed bitmap for a heap object.
/// @param obj HPointer (as uint64_t) to the heap object
/// @param bitmap Bitmap indicating which fields are unboxed
void eco_set_unboxed(uint64_t obj, uint64_t bitmap);

//===----------------------------------------------------------------------===//
// Field Store Functions
//===----------------------------------------------------------------------===//

/// Stores a pointer field in an object.
/// @param obj HPointer (as uint64_t) to the heap object
/// @param index Field index
/// @param value Value to store (as i64 tagged pointer)
void eco_store_field(uint64_t obj, uint32_t index, uint64_t value);

/// Stores an unboxed i64 field in an object.
/// @param obj HPointer (as uint64_t) to the heap object
/// @param index Field index
/// @param value Value to store
void eco_store_field_i64(uint64_t obj, uint32_t index, int64_t value);

/// Stores an unboxed f64 field in an object.
/// @param obj HPointer (as uint64_t) to the heap object
/// @param index Field index
/// @param value Value to store
void eco_store_field_f64(uint64_t obj, uint32_t index, double value);

//===----------------------------------------------------------------------===//
// Closure Operations
//===----------------------------------------------------------------------===//

/// Applies arguments to a closure.
/// If the closure becomes fully saturated, calls the function and returns result.
/// Otherwise, creates a new PAP with the additional arguments.
/// @param closure HPointer (as uint64_t) to the Closure object
/// @param args Array of arguments (as i64 tagged pointers)
/// @param num_args Number of arguments
/// @return Result value or new closure (as HPointer uint64_t)
uint64_t eco_apply_closure(uint64_t closure, uint64_t* args, uint32_t num_args);

/// Extends a PAP with more arguments (partial application).
/// Creates a new closure with the combined captured values.
/// @param closure HPointer (as uint64_t) to the Closure object
/// @param args Array of new arguments
/// @param num_newargs Number of new arguments
/// @param new_unboxed_bitmap Bitmap indicating which new args are unboxed primitives
/// @return New closure with additional captured values (as HPointer uint64_t)
uint64_t eco_pap_extend(uint64_t closure, uint64_t* args, uint32_t num_newargs, uint64_t new_unboxed_bitmap);

/// Calls a fully saturated closure.
/// Combines captured values with new args and invokes the evaluator.
/// @param closure HPointer (as uint64_t) to the Closure object
/// @param new_args Array of new arguments
/// @param num_newargs Number of new arguments (n_values + num_newargs must equal max_values)
/// @return Result of the function call (as i64)
uint64_t eco_closure_call_saturated(uint64_t closure, uint64_t* new_args, uint32_t num_newargs);

//===----------------------------------------------------------------------===//
// Runtime Utilities
//===----------------------------------------------------------------------===//

/// Crashes the program with an error message.
/// @param message HPointer (as uint64_t) to an ElmString containing the error message
[[noreturn]] void eco_crash(uint64_t message);

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
void eco_print_value(uint64_t value);

/// Prints an Elm value, unwrapping Ctor0 box wrappers from Guida compiler.
/// Used by Debug.log to show clean Elm values without internal wrappers.
/// @param value The value to print (as 64-bit encoded pointer)
void eco_print_elm_value(uint64_t value);

/// Converts an Elm value to its string representation.
/// Allocates and returns a new ElmString.
/// @param value The value to convert (as 64-bit encoded pointer)
/// @return HPointer (as uint64_t) to the allocated ElmString
uint64_t eco_value_to_string(uint64_t value);

//===----------------------------------------------------------------------===//
// GC Interface
//===----------------------------------------------------------------------===//

/// GC safepoint check (currently no-op).
/// In the future, this will check if GC needs to run.
void eco_safepoint();

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

//===----------------------------------------------------------------------===//
// Tag Extraction
//===----------------------------------------------------------------------===//

/// Extracts the Header.tag field from a heap object.
/// @param obj HPointer (as uint64_t) to the heap object
/// @return The tag value (Tag enum)
uint32_t eco_get_header_tag(uint64_t obj);

/// Extracts the Custom.ctor field from a Custom object.
/// @param obj HPointer (as uint64_t) to the Custom object
/// @return The constructor tag
uint32_t eco_get_custom_ctor(uint64_t obj);

/// Get constructor tag for a value, handling both heap objects and embedded constants.
/// For heap Custom objects: returns the ctor field (16-bit constructor tag).
/// For embedded constants: returns the appropriate ctor tag:
///   - Nothing (kind=6) -> tag=1 (second constructor of Maybe)
///   - Nil (kind=5) -> tag=0 (first constructor of List)
///   - Other embedded constants -> tag=0
/// @param val HPointer (as uint64_t) to the value
/// @return The constructor tag
uint32_t eco_get_tag(uint64_t val);

//===----------------------------------------------------------------------===//
// List Element Access
//===----------------------------------------------------------------------===//

/// Gets the head of a Cons cell as an unboxed i64.
/// Handles both boxed and unboxed heads:
/// - If head is unboxed: returns the value directly from Cons.head
/// - If head is boxed: resolves the HPointer and loads from ElmInt.value
/// @param cons HPointer (as uint64_t) to the Cons cell
/// @return The head value as i64
int64_t eco_cons_head_i64(uint64_t cons);

/// Gets the head of a Cons cell as an unboxed f64.
/// Handles both boxed and unboxed heads:
/// - If head is unboxed: returns the value directly from Cons.head
/// - If head is boxed: resolves the HPointer and loads from ElmFloat.value
/// @param cons HPointer (as uint64_t) to the Cons cell
/// @return The head value as f64
double eco_cons_head_f64(uint64_t cons);

/// Gets the head of a Cons cell as an unboxed i16 (Elm Char).
/// Handles both boxed and unboxed heads:
/// - If head is unboxed: returns the value directly from Cons.head
/// - If head is boxed: resolves the HPointer and loads from ElmChar.value
/// @param cons HPointer (as uint64_t) to the Cons cell
/// @return The head value as i16
int16_t eco_cons_head_i16(uint64_t cons);

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

/// Converts an HPointer (as uint64_t) to a raw pointer.
/// Uses Allocator::resolve() to handle forwarding pointers during GC.
/// Returns nullptr for embedded constants (Nil, True, False, etc.).
/// @param hptr HPointer value (as uint64_t)
/// @return Raw pointer to the heap object, or nullptr
void* eco_resolve_hptr(uint64_t hptr);

/// Clone an ElmArray, returning a new array with the same contents.
/// Used by eco.array.set lowering for functional array update.
/// @param array_hptr HPointer to source ElmArray (as uint64_t)
/// @return HPointer to new ElmArray copy (as uint64_t)
uint64_t eco_clone_array(uint64_t array_hptr);

} // extern "C"

#endif // ECO_RUNTIME_EXPORTS_H
