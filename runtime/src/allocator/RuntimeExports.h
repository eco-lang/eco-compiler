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
/// @param ctor_tag The constructor tag (maps to Custom.ctor field)
/// @param field_count Number of pointer-sized fields
/// @param scalar_bytes Additional bytes for unboxed scalar fields
/// @return Pointer to the allocated object
void* eco_alloc_custom(uint32_t ctor_tag, uint32_t field_count, uint32_t scalar_bytes);

/// Allocates a Cons cell.
/// @return Pointer to the allocated Cons object
void* eco_alloc_cons();

/// Allocates a Tuple2.
/// @return Pointer to the allocated Tuple2 object
void* eco_alloc_tuple2();

/// Allocates a Tuple3.
/// @return Pointer to the allocated Tuple3 object
void* eco_alloc_tuple3();

/// Allocates a string with the specified length.
/// @param length Number of UTF-16 code units
/// @return Pointer to the allocated ElmString object
void* eco_alloc_string(uint32_t length);

/// Allocates a closure object.
/// @param func_ptr Pointer to the evaluator function
/// @param num_captures Number of captured values
/// @return Pointer to the allocated Closure object
void* eco_alloc_closure(void* func_ptr, uint32_t num_captures);

/// Allocates a boxed Int.
/// @param value The integer value
/// @return Pointer to the allocated ElmInt object
void* eco_alloc_int(int64_t value);

/// Allocates a boxed Float.
/// @param value The floating-point value
/// @return Pointer to the allocated ElmFloat object
void* eco_alloc_float(double value);

/// Allocates a boxed Char.
/// @param value The character (Unicode code point)
/// @return Pointer to the allocated ElmChar object
void* eco_alloc_char(uint32_t value);

/// Generic allocation with specified size and tag.
/// @param size Size in bytes to allocate
/// @param tag Object type tag (Tag enum value)
/// @return Pointer to the allocated object
void* eco_allocate(uint64_t size, uint32_t tag);

/// Sets the unboxed bitmap for a heap object.
/// @param obj Pointer to the heap object
/// @param bitmap Bitmap indicating which fields are unboxed
void eco_set_unboxed(void* obj, uint64_t bitmap);

//===----------------------------------------------------------------------===//
// Field Store Functions
//===----------------------------------------------------------------------===//

/// Stores a pointer field in an object.
/// @param obj Pointer to the heap object
/// @param index Field index
/// @param value Value to store (as i64 tagged pointer)
void eco_store_field(void* obj, uint32_t index, uint64_t value);

/// Stores an unboxed i64 field in an object.
/// @param obj Pointer to the heap object
/// @param index Field index
/// @param value Value to store
void eco_store_field_i64(void* obj, uint32_t index, int64_t value);

/// Stores an unboxed f64 field in an object.
/// @param obj Pointer to the heap object
/// @param index Field index
/// @param value Value to store
void eco_store_field_f64(void* obj, uint32_t index, double value);

//===----------------------------------------------------------------------===//
// Closure Operations
//===----------------------------------------------------------------------===//

/// Applies arguments to a closure.
/// If the closure becomes fully saturated, calls the function and returns result.
/// Otherwise, creates a new PAP with the additional arguments.
/// @param closure Pointer to the Closure object
/// @param args Array of arguments (as i64 tagged pointers)
/// @param num_args Number of arguments
/// @return Result value or new closure (as pointer)
void* eco_apply_closure(void* closure, uint64_t* args, uint32_t num_args);

/// Extends a PAP with more arguments (partial application).
/// Creates a new closure with the combined captured values.
/// @param closure Pointer to the Closure object
/// @param args Array of new arguments
/// @param num_newargs Number of new arguments
/// @return New closure with additional captured values
void* eco_pap_extend(void* closure, uint64_t* args, uint32_t num_newargs);

/// Calls a fully saturated closure.
/// Combines captured values with new args and invokes the evaluator.
/// @param closure Pointer to the Closure object
/// @param new_args Array of new arguments
/// @param num_newargs Number of new arguments (n_values + num_newargs must equal max_values)
/// @return Result of the function call (as i64)
uint64_t eco_closure_call_saturated(void* closure, uint64_t* new_args, uint32_t num_newargs);

//===----------------------------------------------------------------------===//
// Runtime Utilities
//===----------------------------------------------------------------------===//

/// Crashes the program with an error message.
/// @param message Pointer to an ElmString containing the error message
[[noreturn]] void eco_crash(void* message);

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
/// @param obj Pointer to the heap object
/// @return The tag value (Tag enum)
uint32_t eco_get_header_tag(void* obj);

/// Extracts the Custom.ctor field from a Custom object.
/// @param obj Pointer to the Custom object
/// @return The constructor tag
uint32_t eco_get_custom_ctor(void* obj);

//===----------------------------------------------------------------------===//
// Arithmetic Helpers
//===----------------------------------------------------------------------===//

/// Integer exponentiation: base^exp
/// Returns 0 for negative exponents (since result would be fractional).
/// @param base The base value
/// @param exp The exponent value
/// @return base raised to the power of exp
int64_t eco_int_pow(int64_t base, int64_t exp);

} // extern "C"

#endif // ECO_RUNTIME_EXPORTS_H
