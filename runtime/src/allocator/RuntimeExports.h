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

/// Extends a PAP with more arguments.
/// @param closure Pointer to the Closure object
/// @param args Array of new arguments
/// @param num_newargs Number of new arguments
/// @return Result value or new closure (as pointer)
void* eco_pap_extend(void* closure, uint64_t* args, uint32_t num_newargs);

//===----------------------------------------------------------------------===//
// Runtime Utilities
//===----------------------------------------------------------------------===//

/// Crashes the program with an error message.
/// @param message Pointer to an ElmString containing the error message
[[noreturn]] void eco_crash(void* message);

/// Debug print (for eco.dbg op).
/// @param args Array of values to print
/// @param num_args Number of values
void eco_dbg_print(uint64_t* args, uint32_t num_args);

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

} // extern "C"

#endif // ECO_RUNTIME_EXPORTS_H
