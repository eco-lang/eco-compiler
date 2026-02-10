//===- RuntimeExports.cpp - C-linkage runtime function implementations ----===//
//
// This file implements the C-linkage functions that are called from
// LLVM-generated code.
//
//===----------------------------------------------------------------------===//

#include "RuntimeExports.h"
#include "Allocator.hpp"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "TypeInfo.hpp"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>

using namespace Elm;

//===----------------------------------------------------------------------===//
// HPointer Conversion Helpers
//===----------------------------------------------------------------------===//

namespace {

/// Convert a raw void* pointer to a uint64_t HPointer representation.
/// The HPointer will have constant=0, indicating a regular heap pointer.
/// Note: Elm never produces null pointers, so obj must be a valid heap pointer.
/// Validation is performed in Allocator::wrap().
inline uint64_t ptrToHPointer(void* obj) {
    HPointer hp = Allocator::instance().wrap(obj);
    uint64_t result;
    memcpy(&result, &hp, sizeof(result));
    return result;
}

/// Convert a uint64_t HPointer representation to a raw void* pointer.
/// Uses Allocator::resolve() to handle forwarding pointers during GC.
/// Returns nullptr for embedded constants (Nil, True, False, Unit, etc.)
/// since they don't have actual heap objects.
inline void* hpointerToPtr(uint64_t val) {
    HPointer hp;
    memcpy(&hp, &val, sizeof(hp));
    // Embedded constants don't have heap objects - return nullptr.
    if (hp.constant != 0) {
        return nullptr;
    }
    return Allocator::instance().resolve(hp);
}

} // anonymous namespace

//===----------------------------------------------------------------------===//
// Thread-Local Output Stream for Capture Support
//===----------------------------------------------------------------------===//

namespace {

/// Thread-local output stream. When non-null, print output goes here instead of stderr.
thread_local std::ostringstream* tl_output_stream = nullptr;

/// Helper to output text - either to capture stream or stderr.
void output_text(const char* text) {
    if (tl_output_stream) {
        *tl_output_stream << text;
    } else {
        fputs(text, stderr);
    }
}

/// Helper to output formatted text.
template<typename... Args>
void output_format(const char* fmt, Args... args) {
    char buffer[256];
    snprintf(buffer, sizeof(buffer), fmt, args...);
    output_text(buffer);
}

/// Helper to output a single character.
void output_char(char c) {
    if (tl_output_stream) {
        *tl_output_stream << c;
    } else {
        fputc(c, stderr);
    }
}

/// Helper to print float values with proper Infinity and NaN formatting.
/// Elm uses "Infinity", "-Infinity", and "NaN" (not "inf", "-inf", "nan").
/// -0.0 is printed as "0", like Elm does.
void print_float(double d) {
    if (std::isinf(d)) {
        if (d > 0) {
            output_text("Infinity");
        } else {
            output_text("-Infinity");
        }
    } else if (std::isnan(d)) {
        output_text("NaN");
    } else if (d == 0.0) {
        // Print both +0.0 and -0.0 as "0", like Elm does.
        output_text("0");
    } else {
        output_format("%g", d);
    }
}

} // namespace

//===----------------------------------------------------------------------===//
// Output Capture API Implementation
//===----------------------------------------------------------------------===//

extern "C" void* eco_set_output_stream(void* stream) {
    void* prev = tl_output_stream;
    tl_output_stream = static_cast<std::ostringstream*>(stream);
    return prev;
}

extern "C" void* eco_get_output_stream() {
    return tl_output_stream;
}

//===----------------------------------------------------------------------===//
// Allocation Functions
//===----------------------------------------------------------------------===//

extern "C" uint64_t eco_alloc_custom(uint32_t ctor_id, uint32_t field_count, uint32_t scalar_bytes) {
    // Calculate size: Header + ctor/unboxed (8 bytes) + fields
    size_t size = sizeof(Header) + 8 + field_count * sizeof(Unboxable) + scalar_bytes;

    void* obj = Allocator::instance().allocate(size, Tag_Custom);
    if (!obj) return 0;

    Custom* custom = static_cast<Custom*>(obj);
    custom->ctor = ctor_id;
    custom->unboxed = 0;  // Will be set by caller if needed

    return ptrToHPointer(obj);
}

extern "C" void eco_set_unboxed(uint64_t obj_hptr, uint64_t bitmap) {
    void* obj = hpointerToPtr(obj_hptr);
    if (!obj) return;

    Header* header = static_cast<Header*>(obj);
    switch (header->tag) {
        case Tag_Custom: {
            Custom* custom = static_cast<Custom*>(obj);
            custom->unboxed = static_cast<u32>(bitmap);
            break;
        }
        case Tag_Tuple2: {
            Tuple2* tuple = static_cast<Tuple2*>(obj);
            tuple->header.unboxed = static_cast<u8>(bitmap);
            break;
        }
        case Tag_Tuple3: {
            Tuple3* tuple = static_cast<Tuple3*>(obj);
            tuple->header.unboxed = static_cast<u8>(bitmap);
            break;
        }
        case Tag_Cons: {
            Cons* cons = static_cast<Cons*>(obj);
            cons->header.unboxed = static_cast<u8>(bitmap);
            break;
        }
        default:
            // For other types, set in header
            header->unboxed = static_cast<u8>(bitmap);
            break;
    }
}

extern "C" uint64_t eco_alloc_cons(uint64_t head, uint64_t tail, uint32_t head_unboxed) {
    size_t size = sizeof(Cons);
    void* obj = Allocator::instance().allocate(size, Tag_Cons);
    if (!obj) return 0;

    Cons* cons = static_cast<Cons*>(obj);
    cons->header.unboxed = static_cast<u8>(head_unboxed);

    // Store head as raw 64-bit value (handles both ptr and primitive).
    cons->head.i = static_cast<i64>(head);

    // Tail is always a boxed list pointer - store the HPointer directly.
    HPointer tail_hp;
    memcpy(&tail_hp, &tail, sizeof(tail_hp));
    cons->tail = tail_hp;

    return ptrToHPointer(obj);
}

extern "C" uint64_t eco_alloc_tuple2(uint64_t a, uint64_t b, uint32_t unboxed_mask) {
    size_t size = sizeof(Tuple2);
    void* obj = Allocator::instance().allocate(size, Tag_Tuple2);
    if (!obj) return 0;

    Tuple2* tup = static_cast<Tuple2*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask);

    // Store as raw 64-bit values (HPointers or unboxed primitives).
    tup->a.i = static_cast<i64>(a);
    tup->b.i = static_cast<i64>(b);

    return ptrToHPointer(obj);
}

extern "C" uint64_t eco_alloc_tuple3(uint64_t a, uint64_t b, uint64_t c, uint32_t unboxed_mask) {
    size_t size = sizeof(Tuple3);
    void* obj = Allocator::instance().allocate(size, Tag_Tuple3);
    if (!obj) return 0;

    Tuple3* tup = static_cast<Tuple3*>(obj);
    tup->header.unboxed = static_cast<u8>(unboxed_mask);

    // Store as raw 64-bit values (HPointers or unboxed primitives).
    tup->a.i = static_cast<i64>(a);
    tup->b.i = static_cast<i64>(b);
    tup->c.i = static_cast<i64>(c);

    return ptrToHPointer(obj);
}

extern "C" uint64_t eco_alloc_record(uint32_t field_count, uint64_t unboxed_bitmap) {
    // Size: Header (8) + unboxed bitmap (8) + fields (N * 8).
    size_t size = sizeof(Header) + 8 + field_count * sizeof(Unboxable);
    void* obj = Allocator::instance().allocate(size, Tag_Record);
    if (!obj) return 0;

    Record* rec = static_cast<Record*>(obj);
    rec->header.size = field_count;
    rec->unboxed = unboxed_bitmap;

    return ptrToHPointer(obj);
}

extern "C" void eco_store_record_field(uint64_t record_hptr, uint32_t index, uint64_t value) {
    void* record = hpointerToPtr(record_hptr);
    if (!record) return;
    Record* rec = static_cast<Record*>(record);
    // Store as raw 64-bit value (HPointer).
    rec->values[index].i = static_cast<i64>(value);
}

extern "C" void eco_store_record_field_i64(uint64_t record_hptr, uint32_t index, int64_t value) {
    void* record = hpointerToPtr(record_hptr);
    if (!record) return;
    Record* rec = static_cast<Record*>(record);
    rec->values[index].i = value;
}

extern "C" void eco_store_record_field_f64(uint64_t record_hptr, uint32_t index, double value) {
    void* record = hpointerToPtr(record_hptr);
    if (!record) return;
    Record* rec = static_cast<Record*>(record);
    rec->values[index].f = value;
}

extern "C" uint64_t eco_alloc_string(uint32_t length) {
    // Size: Header + length * sizeof(u16), aligned to 8 bytes
    size_t size = sizeof(Header) + length * sizeof(u16);
    size = (size + 7) & ~7;  // Align to 8 bytes

    void* obj = Allocator::instance().allocate(size, Tag_String);
    if (!obj) return 0;

    ElmString* str = static_cast<ElmString*>(obj);
    str->header.size = length;

    return ptrToHPointer(obj);
}

extern "C" uint64_t eco_alloc_string_literal(const uint16_t* chars, uint32_t length) {
    // Allocate string literal directly in old generation (permanent, never collected).
    // Size: Header + length * sizeof(u16), aligned to 8 bytes
    size_t size = sizeof(Header) + length * sizeof(u16);
    size = (size + 7) & ~7;  // Align to 8 bytes

    void* obj = Allocator::instance().allocatePermanent(size, Tag_String);
    if (!obj) return 0;

    ElmString* str = static_cast<ElmString*>(obj);
    str->header.size = length;
    std::memcpy(str->chars, chars, length * sizeof(u16));

    return ptrToHPointer(obj);
}

extern "C" uint64_t eco_alloc_closure(void* func_ptr, uint32_t num_captures) {
    // Size: Header + metadata (8 bytes) + evaluator ptr + captures
    size_t size = sizeof(Header) + 8 + sizeof(EvalFunction) + num_captures * sizeof(Unboxable);

    void* obj = Allocator::instance().allocate(size, Tag_Closure);
    if (!obj) return 0;

    Closure* closure = static_cast<Closure*>(obj);
    closure->n_values = 0;
    closure->max_values = num_captures;
    closure->unboxed = 0;
    closure->evaluator = reinterpret_cast<EvalFunction>(func_ptr);

    return ptrToHPointer(obj);
}

extern "C" uint64_t eco_alloc_int(int64_t value) {
    void* obj = Allocator::instance().allocate(sizeof(ElmInt), Tag_Int);
    if (!obj) return 0;

    ElmInt* elmInt = static_cast<ElmInt*>(obj);
    elmInt->value = value;

    return ptrToHPointer(obj);
}

extern "C" uint64_t eco_alloc_float(double value) {
    void* obj = Allocator::instance().allocate(sizeof(ElmFloat), Tag_Float);
    if (!obj) return 0;

    ElmFloat* elmFloat = static_cast<ElmFloat*>(obj);
    elmFloat->value = value;

    return ptrToHPointer(obj);
}

extern "C" uint64_t eco_alloc_char(uint32_t value) {
    void* obj = Allocator::instance().allocate(sizeof(ElmChar), Tag_Char);
    if (!obj) return 0;

    ElmChar* elmChar = static_cast<ElmChar*>(obj);
    elmChar->value = static_cast<u16>(value);

    return ptrToHPointer(obj);
}

extern "C" uint64_t eco_allocate(uint64_t size, uint32_t tag) {
    // Generic allocation with specified size and tag.
    // The tag should be one of the Tag enum values from Heap.hpp.
    void* obj = Allocator::instance().allocate(static_cast<size_t>(size), static_cast<Tag>(tag));
    return ptrToHPointer(obj);
}

//===----------------------------------------------------------------------===//
// Field Store Functions
//===----------------------------------------------------------------------===//

extern "C" void eco_store_field(uint64_t obj_hptr, uint32_t index, uint64_t value) {
    void* obj = hpointerToPtr(obj_hptr);
    if (!obj) return;

    // Get the header to determine object type
    Header* header = static_cast<Header*>(obj);

    // In JIT mode, pointers are full 64-bit addresses.
    // Store the full value directly in the Unboxable union's i field.
    // This preserves all 64 bits for proper pointer traversal.

    switch (header->tag) {
        case Tag_Custom: {
            Custom* custom = static_cast<Custom*>(obj);
            custom->values[index].i = static_cast<i64>(value);
            break;
        }
        case Tag_Tuple2: {
            Tuple2* tuple = static_cast<Tuple2*>(obj);
            Unboxable* field = (index == 0) ? &tuple->a : &tuple->b;
            field->i = static_cast<i64>(value);
            break;
        }
        case Tag_Tuple3: {
            Tuple3* tuple = static_cast<Tuple3*>(obj);
            Unboxable* field = (index == 0) ? &tuple->a : (index == 1) ? &tuple->b : &tuple->c;
            field->i = static_cast<i64>(value);
            break;
        }
        case Tag_Cons: {
            Cons* cons = static_cast<Cons*>(obj);
            if (index == 0) {
                cons->head.i = static_cast<i64>(value);
            } else {
                // Tail is HPointer, not Unboxable - store as raw bits
                // Note: This may cause issues with 64-bit pointers in JIT mode
                cons->tail.ptr = value & 0xFFFFFFFFFF;
                cons->tail.constant = (value >> 40) & 0xF;
                cons->tail.padding = 0;
            }
            break;
        }
        case Tag_Closure: {
            Closure* closure = static_cast<Closure*>(obj);
            closure->values[index].i = static_cast<i64>(value);
            break;
        }
        default:
            // Unknown object type
            fprintf(stderr, "eco_store_field: unknown object type %d\n", header->tag);
            break;
    }
}

extern "C" void eco_store_field_i64(uint64_t obj_hptr, uint32_t index, int64_t value) {
    void* obj = hpointerToPtr(obj_hptr);
    if (!obj) return;

    Header* header = static_cast<Header*>(obj);

    switch (header->tag) {
        case Tag_Custom: {
            Custom* custom = static_cast<Custom*>(obj);
            custom->values[index].i = value;
            break;
        }
        case Tag_Tuple2: {
            Tuple2* tuple = static_cast<Tuple2*>(obj);
            if (index == 0) tuple->a.i = value;
            else tuple->b.i = value;
            break;
        }
        case Tag_Tuple3: {
            Tuple3* tuple = static_cast<Tuple3*>(obj);
            if (index == 0) tuple->a.i = value;
            else if (index == 1) tuple->b.i = value;
            else tuple->c.i = value;
            break;
        }
        case Tag_Cons: {
            Cons* cons = static_cast<Cons*>(obj);
            if (index == 0) cons->head.i = value;
            break;
        }
        case Tag_Closure: {
            Closure* closure = static_cast<Closure*>(obj);
            closure->values[index].i = value;
            break;
        }
        default:
            fprintf(stderr, "eco_store_field_i64: unknown object type %d\n", header->tag);
            break;
    }
}

extern "C" void eco_store_field_f64(uint64_t obj_hptr, uint32_t index, double value) {
    void* obj = hpointerToPtr(obj_hptr);
    if (!obj) return;

    Header* header = static_cast<Header*>(obj);

    switch (header->tag) {
        case Tag_Custom: {
            Custom* custom = static_cast<Custom*>(obj);
            custom->values[index].f = value;
            break;
        }
        case Tag_Tuple2: {
            Tuple2* tuple = static_cast<Tuple2*>(obj);
            if (index == 0) tuple->a.f = value;
            else tuple->b.f = value;
            break;
        }
        case Tag_Tuple3: {
            Tuple3* tuple = static_cast<Tuple3*>(obj);
            if (index == 0) tuple->a.f = value;
            else if (index == 1) tuple->b.f = value;
            else tuple->c.f = value;
            break;
        }
        case Tag_Closure: {
            Closure* closure = static_cast<Closure*>(obj);
            closure->values[index].f = value;
            break;
        }
        default:
            fprintf(stderr, "eco_store_field_f64: unknown object type %d\n", header->tag);
            break;
    }
}

//===----------------------------------------------------------------------===//
// Closure Operations
//===----------------------------------------------------------------------===//

extern "C" uint64_t eco_apply_closure(uint64_t closure_hptr, uint64_t* args, uint32_t num_args) {
    void* closure_ptr = hpointerToPtr(closure_hptr);
    if (!closure_ptr) return 0;

    // TODO: Implement closure application
    // This needs to:
    // 1. Check if closure becomes fully saturated
    // 2. If so, call the evaluator function
    // 3. Otherwise, create a new PAP with additional captured args

    fprintf(stderr, "eco_apply_closure: not yet implemented\n");
    return 0;
}

extern "C" uint64_t eco_pap_extend(uint64_t closure_hptr, uint64_t* args, uint32_t num_newargs,
                                   uint64_t new_unboxed_bitmap) {
    void* closure_ptr = hpointerToPtr(closure_hptr);
    if (!closure_ptr) return 0;

    Closure* old_closure = static_cast<Closure*>(closure_ptr);

    // Get the current state of the closure.
    uint32_t old_n_values = old_closure->n_values;
    uint32_t max_values = old_closure->max_values;
    uint64_t old_unboxed = old_closure->unboxed;

    // Calculate new n_values.
    uint32_t new_n_values = old_n_values + num_newargs;

    // Sanity check: should not exceed max_values for partial application.
    // (Saturated calls should use eco_closure_call_saturated instead.)
    if (new_n_values > max_values) {
        fprintf(stderr, "eco_pap_extend: new_n_values (%u) exceeds max_values (%u)\n",
                new_n_values, max_values);
        return 0;
    }

    // Allocate a new closure with room for all captured values.
    size_t size = sizeof(Header) + 8 + sizeof(EvalFunction) + new_n_values * sizeof(Unboxable);
    void* obj = Allocator::instance().allocate(size, Tag_Closure);
    if (!obj) return 0;

    Closure* new_closure = static_cast<Closure*>(obj);

    // Copy metadata from old closure.
    new_closure->n_values = new_n_values;
    new_closure->max_values = max_values;
    new_closure->evaluator = old_closure->evaluator;

    // Merge unboxed bitmaps: old bits + new bits shifted by old_n_values.
    // Mask new_unboxed_bitmap to num_newargs bits, then shift into position.
    uint64_t masked_new_bitmap = new_unboxed_bitmap & ((1ULL << num_newargs) - 1);
    uint64_t shifted_new_bitmap = masked_new_bitmap << old_n_values;
    new_closure->unboxed = old_unboxed | shifted_new_bitmap;

    // Copy old captured values.
    for (uint32_t i = 0; i < old_n_values; i++) {
        new_closure->values[i] = old_closure->values[i];
    }

    // Copy new arguments.
    for (uint32_t i = 0; i < num_newargs; i++) {
        new_closure->values[old_n_values + i].i = static_cast<i64>(args[i]);
    }

    return ptrToHPointer(obj);
}

extern "C" uint64_t eco_closure_call_saturated(uint64_t closure_hptr, uint64_t* new_args, uint32_t num_newargs) {
    void* closure_ptr = hpointerToPtr(closure_hptr);
    if (!closure_ptr) return 0;

    Closure* closure = static_cast<Closure*>(closure_ptr);

    // Get the closure state.
    uint32_t n_values = closure->n_values;
    uint32_t max_values = closure->max_values;

    // Sanity check: n_values + num_newargs should equal max_values for a saturated call.
    if (n_values + num_newargs != max_values) {
        fprintf(stderr, "eco_closure_call_saturated: argument count mismatch "
                "(n_values=%u + num_newargs=%u != max_values=%u)\n",
                n_values, num_newargs, max_values);
        return 0;
    }

    // Build the combined argument array.
    // Stack-allocate for small arities, heap-allocate for large.
    void* stack_args[16];
    void** combined_args = (max_values <= 16) ? stack_args :
                           static_cast<void**>(alloca(max_values * sizeof(void*)));

    // Copy captured values from closure.
    for (uint32_t i = 0; i < n_values; i++) {
        combined_args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }

    // Copy new arguments.
    for (uint32_t i = 0; i < num_newargs; i++) {
        combined_args[n_values + i] = reinterpret_cast<void*>(new_args[i]);
    }

    // Call the evaluator function.
    EvalFunction evaluator = closure->evaluator;
    void* result = evaluator(combined_args);

    return reinterpret_cast<uint64_t>(result);
}

//===----------------------------------------------------------------------===//
// Runtime Utilities
//===----------------------------------------------------------------------===//

extern "C" [[noreturn]] void eco_crash(uint64_t message_val) {
    // message_val must be an HPointer to a heap-allocated string
    void* message = hpointerToPtr(message_val);

    // Print error message if it's a valid string
    if (message) {
        Header* header = static_cast<Header*>(message);
        if (header->tag == Tag_String) {
            ElmString* str = static_cast<ElmString*>(message);
            // Convert UTF-16 to UTF-8 for printing
            fprintf(stderr, "Elm runtime error: ");
            for (uint32_t i = 0; i < header->size; i++) {
                // Simple ASCII conversion for now
                char c = (str->chars[i] < 128) ? static_cast<char>(str->chars[i]) : '?';
                fputc(c, stderr);
            }
            fputc('\n', stderr);
        }
    }

    // Use exit(1) instead of abort() to avoid triggering LLVM's signal handlers
    // which would print a misleading "PLEASE submit a bug report" message.
    std::exit(1);
}

// Forward declaration for recursive printing
static void print_value(uint64_t val, int depth);

// Print string content (without quotes) - for Debug.log labels
static void print_string_content(ElmString* str) {
    Header* header = &str->header;
    for (uint32_t i = 0; i < header->size; i++) {
        u16 c = str->chars[i];
        if (c < 128) {
            output_char(static_cast<char>(c));
        } else {
            // Print non-ASCII as unicode escape
            output_format("\\u%04X", c);
        }
    }
}

// Print a string value (with quotes)
static void print_string(ElmString* str) {
    Header* header = &str->header;
    output_char('"');
    for (uint32_t i = 0; i < header->size; i++) {
        u16 c = str->chars[i];
        if (c == '"') {
            output_text("\\\"");
        } else if (c == '\\') {
            output_text("\\\\");
        } else if (c == '\n') {
            output_text("\\n");
        } else if (c == '\r') {
            output_text("\\r");
        } else if (c == '\t') {
            output_text("\\t");
        } else if (c < 32 || c >= 127) {
            output_format("\\u%04X", c);
        } else {
            output_char(static_cast<char>(c));
        }
    }
    output_char('"');
}

// Print a character value in Elm syntax
static void print_char(u16 c) {
    output_char('\'');
    if (c == '\'') {
        output_text("\\'");
    } else if (c == '\\') {
        output_text("\\\\");
    } else if (c == '\n') {
        output_text("\\n");
    } else if (c == '\r') {
        output_text("\\r");
    } else if (c == '\t') {
        output_text("\\t");
    } else if (c < 32 || c >= 127) {
        output_format("\\u%04X", c);
    } else {
        output_char(static_cast<char>(c));
    }
    output_char('\'');
}

// Print an unboxed primitive value from a container field.
// ONLY called when: (1) unboxed bitmap indicates field is unboxed, AND
//                   (2) type graph says field type is primitive.
// NEVER called from eco_dbg_print_typed directly - that always receives
// boxed HPointer values.
static void printPrimitive(uint64_t bits, Elm::EcoPrimKind kind) {
    switch (kind) {
    case Elm::EcoPrimKind::Int:
        output_format("%lld", (long long)static_cast<int64_t>(bits));
        break;
    case Elm::EcoPrimKind::Float: {
        double d;
        std::memcpy(&d, &bits, sizeof(d));
        print_float(d);
        break;
    }
    case Elm::EcoPrimKind::Char:
        print_char(static_cast<u16>(bits));
        break;
    case Elm::EcoPrimKind::Bool:
        output_text(bits ? "True" : "False");
        break;
    case Elm::EcoPrimKind::String:
        // String is NEVER unboxed - if we get here, it's a bug.
        // Fall through to print as pointer (will likely show <null> or garbage).
        assert(false && "String cannot be unboxed");
        output_text("<unboxed-string-bug>");
        break;
    }
}

// MLIR ConstantKind enum (1-based, from Ops.td)
// These values are stored directly in bits 40-43 of the pointer
enum MlirConstantKind {
    MlirConst_Unit = 1,
    MlirConst_EmptyRec = 2,
    MlirConst_True = 3,
    MlirConst_False = 4,
    MlirConst_Nil = 5,
    MlirConst_Nothing = 6,
    MlirConst_EmptyString = 7,
};

// Check if a value is an embedded constant and print it
// Returns true if it was a constant, false otherwise
static bool print_if_constant(uint64_t val) {
    // For JIT execution, pointers are full 64-bit addresses.
    // Constants are small values with only bits 40-43 set (values 1-7 shifted left by 40).
    // A real pointer will have bits above 43 set (e.g., 0x7f...).
    // So we check: if val > (7 << 40), it's definitely a pointer, not a constant.
    // And if val > 0 and val <= (7 << 40), it's a constant.

    // Constants are in range [1<<40, 7<<40] = [0x10000000000, 0x70000000000]
    // Real heap pointers will be above 0x100000000000 (bit 44 set for typical 48-bit addresses)

    // Simple check: constants have zero in the low 40 bits AND a small value in upper bits
    uint64_t ptr_part = val & 0xFFFFFFFFFF;  // Lower 40 bits
    uint64_t const_part = val >> 40;          // Upper 24 bits

    // If there's a pointer component, it's not a pure constant
    if (ptr_part != 0) {
        return false;
    }

    // Pure constant: ptr_part is 0, const_part is 1-7
    if (const_part >= 1 && const_part <= 7) {
        switch (const_part) {
            case MlirConst_Unit:
                output_text("()");
                return true;
            case MlirConst_EmptyRec:
                output_text("{}");
                return true;
            case MlirConst_True:
                output_text("True");
                return true;
            case MlirConst_False:
                output_text("False");
                return true;
            case MlirConst_Nil:
                output_text("[]");
                return true;
            case MlirConst_Nothing:
                output_text("Nothing");
                return true;
            case MlirConst_EmptyString:
                output_text("\"\"");
                return true;
        }
    }

    return false;  // Regular pointer
}

// Check if a value is Nil constant
static bool is_nil(uint64_t val) {
    // Nil is encoded as MlirConst_Nil << 40 with zero in lower bits
    return (val & 0xFFFFFFFFFF) == 0 && (val >> 40) == MlirConst_Nil;
}

// Check if a Custom object is a list cons cell.
// MLIR generates: List Nil with tag=0, size=0; List Cons with tag=1, size=2.
// The tail (field 1) must be boxed (not unboxed) since it points to next cell or Nil.
static inline bool is_list_cons(const Custom* custom) {
    return custom->ctor == 1 &&
           custom->header.size == 2 &&
           (custom->unboxed & 2) == 0;
}

// Print a list in Elm syntax: [1, 2, 3]
static void print_list(uint64_t val, int depth) {
    output_char('[');

    bool first = true;
    uint64_t current = val;
    int count = 0;
    const int MAX_LIST_ITEMS = 100;  // Prevent infinite loops

    while (count < MAX_LIST_ITEMS) {
        // Check for Nil (end of list)
        if (is_nil(current)) {
            break;
        }

        // Check for other embedded constants (invalid in list tail)
        uint64_t ptr_part = current & 0xFFFFFFFFFF;
        uint64_t const_part = current >> 40;
        if (ptr_part == 0 && const_part >= 1 && const_part <= 7) {
            if (!first) output_text(", ");
            output_text("<invalid_list_tail>");
            break;
        }

        // Convert HPointer to raw pointer
        void* ptr = hpointerToPtr(current);
        if (!ptr) {
            if (!first) output_text(", ");
            output_text("<null>");
            break;
        }

        Header* header = static_cast<Header*>(ptr);

        // eco.construct uses Tag_Custom with ctor=1 for list cons cells
        // MLIR: List Nil has tag=0, size=0; List Cons has tag=1, size=2
        // Native Cons type uses Tag_Cons
        if (header->tag == Tag_Custom) {
            Custom* custom = static_cast<Custom*>(ptr);
            // Use is_list_cons helper to validate cons cell
            if (!is_list_cons(custom)) {
                if (!first) output_text(", ");
                output_text("<non_cons_custom>");
                break;
            }

            if (!first) {
                output_text(", ");
            }
            first = false;

            // Print the head element (field 0)
            // In JIT mode, values are stored as full 64-bit integers
            if (custom->unboxed & 1) {
                output_format("%lld", (long long)custom->values[0].i);
            } else {
                // Read the full 64-bit value
                uint64_t head_val = static_cast<uint64_t>(custom->values[0].i);
                print_value(head_val, depth + 1);
            }

            // Move to tail (field 1) - read as full 64-bit value
            current = static_cast<uint64_t>(custom->values[1].i);
        } else if (header->tag == Tag_Cons) {
            Cons* cons = static_cast<Cons*>(ptr);

            if (!first) {
                output_text(", ");
            }
            first = false;

            // Print the head element
            if (header->unboxed & 1) {
                output_format("%lld", (long long)cons->head.i);
            } else {
                uint64_t head_val = cons->head.p.ptr |
                                   (static_cast<uint64_t>(cons->head.p.constant) << 40);
                print_value(head_val, depth + 1);
            }

            // Move to tail
            current = cons->tail.ptr | (static_cast<uint64_t>(cons->tail.constant) << 40);
        } else {
            if (!first) output_text(", ");
            output_format("<non_cons_tag_%d>", header->tag);
            break;
        }

        count++;
    }

    if (count >= MAX_LIST_ITEMS) {
        output_text(", ...");
    }

    output_char(']');
}

// Print a tuple
static void print_tuple2(Tuple2* tuple, int depth) {
    output_char('(');

    // Print first element - read as full 64-bit value for JIT mode
    if (tuple->header.unboxed & 1) {
        output_format("%lld", (long long)tuple->a.i);
    } else {
        print_value(static_cast<uint64_t>(tuple->a.i), depth + 1);
    }

    output_text(", ");

    // Print second element
    if (tuple->header.unboxed & 2) {
        output_format("%lld", (long long)tuple->b.i);
    } else {
        print_value(static_cast<uint64_t>(tuple->b.i), depth + 1);
    }

    output_char(')');
}

static void print_tuple3(Tuple3* tuple, int depth) {
    output_char('(');

    // Print first element - read as full 64-bit value for JIT mode
    if (tuple->header.unboxed & 1) {
        output_format("%lld", (long long)tuple->a.i);
    } else {
        print_value(static_cast<uint64_t>(tuple->a.i), depth + 1);
    }

    output_text(", ");

    // Print second element
    if (tuple->header.unboxed & 2) {
        output_format("%lld", (long long)tuple->b.i);
    } else {
        print_value(static_cast<uint64_t>(tuple->b.i), depth + 1);
    }

    output_text(", ");

    // Print third element
    if (tuple->header.unboxed & 4) {
        output_format("%lld", (long long)tuple->c.i);
    } else {
        print_value(static_cast<uint64_t>(tuple->c.i), depth + 1);
    }

    output_char(')');
}

// Print a custom type constructor
static void print_custom(Custom* custom, int depth) {
    uint32_t ctor = custom->ctor;
    uint32_t size = custom->header.size;

    // Print generic constructor name (1-indexed for readability)
    output_format("Ctor%u", ctor);

    // Print fields if any
    if (size > 0) {
        output_char(' ');
        for (uint32_t i = 0; i < size; i++) {
            if (i > 0) output_char(' ');

            // Check if field is unboxed
            if (custom->unboxed & (1ULL << i)) {
                output_format("%lld", (long long)custom->values[i].i);
            } else {
                // Read as full 64-bit value for JIT mode
                uint64_t val = static_cast<uint64_t>(custom->values[i].i);

                if (val == 0) {
                    // Null pointer
                    output_text("<null>");
                } else if (!print_if_constant(val)) {
                    // Heap pointer - resolve HPointer
                    void* ptr = hpointerToPtr(val);
                    bool needs_parens = false;
                    if (ptr) {
                        Header* h = static_cast<Header*>(ptr);
                        needs_parens = (h->tag == Tag_Custom && static_cast<Custom*>(ptr)->header.size > 0);
                    }
                    if (needs_parens) output_char('(');
                    print_value(val, depth + 1);
                    if (needs_parens) output_char(')');
                }
            }
        }
    }
}

// Print a record
static void print_record(Record* record, int depth) {
    uint32_t size = record->header.size;

    output_text("{ ");
    for (uint32_t i = 0; i < size; i++) {
        if (i > 0) output_text(", ");

        // We don't have field names, so use numeric indices
        output_format("f%u = ", i);

        // Check if field is unboxed
        if (record->unboxed & (1ULL << i)) {
            output_format("%lld", (long long)record->values[i].i);
        } else {
            // Read as full 64-bit value for JIT mode
            print_value(static_cast<uint64_t>(record->values[i].i), depth + 1);
        }
    }
    output_text(" }");
}

// Print a dynamic record
static void print_dynrecord(DynRecord* dynrec, int depth) {
    uint32_t size = dynrec->header.size;

    output_text("{ ");
    for (uint32_t i = 0; i < size; i++) {
        if (i > 0) output_text(", ");

        // We don't have field names, so use numeric indices
        output_format("f%u = ", i);

        // DynRecord values are HPointer, not Unboxable
        // For JIT mode, we need to read the full pointer differently
        // Since HPointer is a bitfield struct, we can't easily store 64-bit pointers
        // Fall back to the 44-bit encoding for now
        uint64_t val = dynrec->values[i].ptr |
                      (static_cast<uint64_t>(dynrec->values[i].constant) << 40);
        print_value(val, depth + 1);
    }
    output_text(" }");
}

// Print an array
static void print_array(ElmArray* array, int depth) {
    output_text("Array.fromList [");
    for (uint32_t i = 0; i < array->length; i++) {
        if (i > 0) output_text(", ");

        if (array->unboxed & (1ULL << i)) {
            output_format("%lld", (long long)array->elements[i].i);
        } else {
            // Read as full 64-bit value for JIT mode
            print_value(static_cast<uint64_t>(array->elements[i].i), depth + 1);
        }
    }
    output_char(']');
}

// Main value printer
static void print_value(uint64_t val, int depth) {
    // Prevent infinite recursion
    if (depth > 50) {
        output_text("...");
        return;
    }

    // Check for embedded constants first
    if (print_if_constant(val)) {
        return;
    }

    // Convert HPointer to raw pointer via allocator
    void* ptr = hpointerToPtr(val);
    if (!ptr) {
        output_text("<null>");
        return;
    }

    Header* header = static_cast<Header*>(ptr);

    switch (header->tag) {
        case Tag_Int: {
            ElmInt* intval = static_cast<ElmInt*>(ptr);
            output_format("%lld", (long long)intval->value);
            break;
        }

        case Tag_Float: {
            ElmFloat* floatval = static_cast<ElmFloat*>(ptr);
            print_float(floatval->value);
            break;
        }

        case Tag_Char: {
            ElmChar* charval = static_cast<ElmChar*>(ptr);
            print_char(charval->value);
            break;
        }

        case Tag_String: {
            ElmString* strval = static_cast<ElmString*>(ptr);
            print_string(strval);
            break;
        }

        case Tag_Tuple2: {
            Tuple2* tuple = static_cast<Tuple2*>(ptr);
            print_tuple2(tuple, depth);
            break;
        }

        case Tag_Tuple3: {
            Tuple3* tuple = static_cast<Tuple3*>(ptr);
            print_tuple3(tuple, depth);
            break;
        }

        case Tag_Cons: {
            // Print as a list
            print_list(val, depth);
            break;
        }

        case Tag_Custom: {
            Custom* custom = static_cast<Custom*>(ptr);
            // Check if this is a list cons cell using the is_list_cons helper.
            // MLIR: List Cons has ctor=1, size=2 (NOT ctor=0 which is used for tuples).
            if (is_list_cons(custom)) {
                print_list(val, depth);
            } else {
                print_custom(custom, depth);
            }
            break;
        }

        case Tag_Record: {
            Record* record = static_cast<Record*>(ptr);
            print_record(record, depth);
            break;
        }

        case Tag_DynRecord: {
            DynRecord* dynrec = static_cast<DynRecord*>(ptr);
            print_dynrecord(dynrec, depth);
            break;
        }

        case Tag_Closure: {
            output_text("<fn>");
            break;
        }

        case Tag_Process: {
            Process* proc = static_cast<Process*>(ptr);
            output_format("<process:%llu>", (unsigned long long)proc->id);
            break;
        }

        case Tag_Task: {
            output_text("<task>");
            break;
        }

        case Tag_FieldGroup: {
            output_text("<fieldgroup>");
            break;
        }

        case Tag_ByteBuffer: {
            ByteBuffer* buf = static_cast<ByteBuffer*>(ptr);
            output_format("<bytes:%u>", buf->header.size);
            break;
        }

        case Tag_Array: {
            ElmArray* array = static_cast<ElmArray*>(ptr);
            print_array(array, depth);
            break;
        }

        case Tag_Forward: {
            output_text("<forward>");
            break;
        }

        default:
            output_format("<unknown_tag_%u>", header->tag);
            break;
    }
}

extern "C" void eco_dbg_print(uint64_t* args, uint32_t num_args) {
    output_text("[eco.dbg] ");
    for (uint32_t i = 0; i < num_args; i++) {
        if (i > 0) output_char(' ');
        print_value(args[i], 0);
    }
    output_text("\n");
}

// Debug print for unboxed integer (i64)
extern "C" void eco_dbg_print_int(int64_t value) {
    output_format("[eco.dbg] %lld\n", (long long)value);
}

// Debug print for unboxed float (f64)
extern "C" void eco_dbg_print_float(double value) {
    output_text("[eco.dbg] ");
    print_float(value);
    output_text("\n");
}

// Debug print for unboxed char (i32 Unicode code point)
extern "C" void eco_dbg_print_char(int32_t value) {
    output_text("[eco.dbg] ");
    print_char(static_cast<u16>(value));
    output_text("\n");
}

// Global type graph pointer - set by eco_register_type_graph from JITed code
static const Elm::EcoTypeGraph* g_type_graph = nullptr;

// Register the type graph from JITed code
extern "C" void eco_register_type_graph(const void* graph) {
    g_type_graph = static_cast<const Elm::EcoTypeGraph*>(graph);
}

// Forward declaration for recursive printing
static void print_typed_value(uint64_t value, uint32_t type_id, int depth);

// Helper to print a label (string value without quotes)
static void print_label(uint64_t value) {
    void* ptr = hpointerToPtr(value);
    if (ptr) {
        Header* header = static_cast<Header*>(ptr);
        if (header->tag == Tag_String) {
            ElmString* str = static_cast<ElmString*>(ptr);
            print_string_content(str);
        } else {
            // Not a string, print as value
            print_value(value, 0);
        }
    } else {
        output_text("<null>");
    }
}

// Debug print with full type information using the global type graph.
// When called with 2 args where type_ids[0] == -1, this is a Debug.log call
// and we format as "label: value\n"
extern "C" void eco_dbg_print_typed(uint64_t* values, uint32_t* type_ids, uint32_t num_args) {
    // Special case for Debug.log: 2 args, first type_id is -1 (label)
    if (num_args == 2 && type_ids[0] == (uint32_t)-1) {
        print_label(values[0]);
        output_text(": ");
        print_typed_value(values[1], type_ids[1], 0);
        output_text("\n");
        return;
    }

    // General case: print each value on its own line
    for (uint32_t i = 0; i < num_args; ++i) {
        if (type_ids[i] == (uint32_t)-1) {
            // Raw label, print without quotes
            print_label(values[i]);
        } else {
            print_typed_value(values[i], type_ids[i], 0);
        }
        output_text("\n");
    }
}

// Print a value using type information from the type graph
static void print_typed_value(uint64_t value, uint32_t type_id, int depth) {
    // Prevent infinite recursion
    if (depth > 50) {
        output_text("...");
        return;
    }

    // Assert type graph is available and type_id is valid
    assert(g_type_graph && "Type graph not initialized");
    assert(g_type_graph->types && "Type graph has no types array");
    assert(type_id < g_type_graph->type_count && "Invalid type_id");
    if (!g_type_graph || !g_type_graph->types || type_id >= g_type_graph->type_count) {
        // Safety fallback in release builds
        print_value(value, depth);
        return;
    }

    const Elm::EcoTypeInfo* typeInfo = &g_type_graph->types[type_id];

    switch (typeInfo->kind) {
    case Elm::EcoTypeKind::Primitive:
        // INVARIANT: At the dbg boundary, primitives are ALWAYS boxed (!eco.value).
        // The value is an HPointer to a heap object (ElmInt, ElmFloat, ElmChar,
        // ElmString) or an embedded constant (True, False, EmptyString).
        // Just use the generic value printer which dispatches on heap tag.
        print_value(value, depth);
        break;

    case Elm::EcoTypeKind::List: {
        // Get element type for typed recursive printing
        uint32_t elem_type_id = typeInfo->data.list.elem_type_id;

        // Assert element type is in valid range
        assert(elem_type_id < g_type_graph->type_count && "Invalid elem_type_id in List type graph");

        output_char('[');
        bool first = true;
        uint64_t current = value;
        int count = 0;
        const int MAX_LIST_ITEMS = 100;

        while (count < MAX_LIST_ITEMS) {
            // Check for Nil (end of list)
            if (is_nil(current)) {
                break;
            }

            // Check for other embedded constants
            uint64_t ptr_part = current & 0xFFFFFFFFFF;
            uint64_t const_part = current >> 40;
            if (ptr_part == 0 && const_part >= 1 && const_part <= 7) {
                break;
            }

            void* ptr = hpointerToPtr(current);
            if (!ptr) break;

            Header* header = static_cast<Header*>(ptr);

            // Handle both Tag_Cons and Tag_Custom (ctor=1) for list cons cells
            uint64_t head_val;
            uint64_t tail_val;
            bool head_unboxed = false;

            if (header->tag == Tag_Cons) {
                Cons* cons = static_cast<Cons*>(ptr);
                head_val = static_cast<uint64_t>(cons->head.i);
                head_unboxed = (cons->header.unboxed & 1);
                tail_val = cons->tail.ptr | (static_cast<uint64_t>(cons->tail.constant) << 40);
            } else if (header->tag == Tag_Custom) {
                Custom* custom = static_cast<Custom*>(ptr);
                if (!is_list_cons(custom)) break;
                head_val = static_cast<uint64_t>(custom->values[0].i);
                head_unboxed = (custom->unboxed & 1);
                tail_val = static_cast<uint64_t>(custom->values[1].i);
            } else {
                break;
            }

            if (!first) output_text(", ");
            first = false;

            // Print head with type info
            if (head_unboxed) {
                // Value is unboxed - use printPrimitive based on element type
                const Elm::EcoTypeInfo* elemType = &g_type_graph->types[elem_type_id];
                if (elemType->kind == Elm::EcoTypeKind::Primitive) {
                    printPrimitive(head_val, elemType->data.primitive.prim_kind);
                } else if (elemType->kind == Elm::EcoTypeKind::Polymorphic &&
                           elemType->data.polymorphic.constraint == Elm::EcoConstraintKind::Number) {
                    // Number constraint with unboxed value - assume Int
                    printPrimitive(head_val, Elm::EcoPrimKind::Int);
                } else {
                    // Unboxed but type graph says non-primitive - type mismatch
                    assert(false && "List head is unboxed but element type is not primitive");
                    output_format("<unboxed-non-prim:0x%llx>", (unsigned long long)head_val);
                }
            } else {
                // Value is boxed (HPointer) - recurse with type info
                print_typed_value(head_val, elem_type_id, depth + 1);
            }

            current = tail_val;
            count++;
        }

        if (count >= MAX_LIST_ITEMS) {
            output_text(", ...");
        }
        output_char(']');
        break;
    }

    case Elm::EcoTypeKind::Tuple: {
        uint16_t arity = typeInfo->data.tuple.arity;
        uint32_t first_field = typeInfo->data.tuple.first_field;

        // Assert fields array is valid
        assert(g_type_graph->fields && "Type graph has no fields array");
        assert(first_field + arity <= g_type_graph->field_count && "Tuple field indices out of bounds");

        // Assert field types are in valid range
        for (uint16_t i = 0; i < arity; i++) {
            assert(g_type_graph->fields[first_field + i].type_id < g_type_graph->type_count &&
                   "Invalid field type_id in Tuple type graph");
        }

        void* ptr = hpointerToPtr(value);
        if (!ptr) {
            output_text("<null>");
            break;
        }

        Header* header = static_cast<Header*>(ptr);

        if (header->tag == Tag_Tuple2 && arity == 2) {
            Tuple2* tuple = static_cast<Tuple2*>(ptr);
            uint32_t type_a = g_type_graph->fields[first_field].type_id;
            uint32_t type_b = g_type_graph->fields[first_field + 1].type_id;
            uint8_t unboxed = tuple->header.unboxed;

            output_char('(');
            // Field a
            if (unboxed & 1) {
                const Elm::EcoTypeInfo* ft = &g_type_graph->types[type_a];
                assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                       "Tuple field a is unboxed but type is not primitive");
                printPrimitive(static_cast<uint64_t>(tuple->a.i), ft->data.primitive.prim_kind);
            } else {
                print_typed_value(static_cast<uint64_t>(tuple->a.i), type_a, depth + 1);
            }
            output_text(", ");
            // Field b
            if (unboxed & 2) {
                const Elm::EcoTypeInfo* ft = &g_type_graph->types[type_b];
                assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                       "Tuple field b is unboxed but type is not primitive");
                printPrimitive(static_cast<uint64_t>(tuple->b.i), ft->data.primitive.prim_kind);
            } else {
                print_typed_value(static_cast<uint64_t>(tuple->b.i), type_b, depth + 1);
            }
            output_char(')');
        } else if (header->tag == Tag_Tuple3 && arity == 3) {
            Tuple3* tuple = static_cast<Tuple3*>(ptr);
            uint32_t type_a = g_type_graph->fields[first_field].type_id;
            uint32_t type_b = g_type_graph->fields[first_field + 1].type_id;
            uint32_t type_c = g_type_graph->fields[first_field + 2].type_id;
            uint8_t unboxed = tuple->header.unboxed;

            output_char('(');
            // Field a
            if (unboxed & 1) {
                const Elm::EcoTypeInfo* ft = &g_type_graph->types[type_a];
                assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                       "Tuple3 field a is unboxed but type is not primitive");
                printPrimitive(static_cast<uint64_t>(tuple->a.i), ft->data.primitive.prim_kind);
            } else {
                print_typed_value(static_cast<uint64_t>(tuple->a.i), type_a, depth + 1);
            }
            output_text(", ");
            // Field b
            if (unboxed & 2) {
                const Elm::EcoTypeInfo* ft = &g_type_graph->types[type_b];
                assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                       "Tuple3 field b is unboxed but type is not primitive");
                printPrimitive(static_cast<uint64_t>(tuple->b.i), ft->data.primitive.prim_kind);
            } else {
                print_typed_value(static_cast<uint64_t>(tuple->b.i), type_b, depth + 1);
            }
            output_text(", ");
            // Field c
            if (unboxed & 4) {
                const Elm::EcoTypeInfo* ft = &g_type_graph->types[type_c];
                assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                       "Tuple3 field c is unboxed but type is not primitive");
                printPrimitive(static_cast<uint64_t>(tuple->c.i), ft->data.primitive.prim_kind);
            } else {
                print_typed_value(static_cast<uint64_t>(tuple->c.i), type_c, depth + 1);
            }
            output_char(')');
        } else {
            // Tag doesn't match expected tuple type
            assert(false && "Tuple tag mismatch - value doesn't match type");
            output_text("<tuple-mismatch>");
        }
        break;
    }

    case Elm::EcoTypeKind::Record: {
        uint32_t first_field = typeInfo->data.record.first_field;
        uint32_t field_count = typeInfo->data.record.field_count;

        void* ptr = hpointerToPtr(value);
        if (!ptr) {
            output_text("<null>");
            break;
        }

        Header* header = static_cast<Header*>(ptr);
        if (header->tag != Tag_Record) {
            print_value(value, depth);
            break;
        }

        Record* record = static_cast<Record*>(ptr);
        uint32_t actual_size = record->header.size;
        uint64_t unboxed = record->unboxed;

        output_text("{ ");
        for (uint32_t i = 0; i < actual_size && i < field_count; i++) {
            if (i > 0) output_text(", ");

            // Get field info from type graph
            if (g_type_graph->fields && first_field + i < g_type_graph->field_count) {
                const Elm::EcoFieldInfo* field = &g_type_graph->fields[first_field + i];

                // Print field name if available
                if (g_type_graph->strings && field->name_index < g_type_graph->string_count) {
                    output_text(g_type_graph->strings[field->name_index]);
                } else {
                    output_format("f%u", i);
                }
                output_text(" = ");

                // Print field value - check unboxed bitmap from heap
                uint64_t field_val = static_cast<uint64_t>(record->values[i].i);
                bool is_unboxed = (unboxed & (1ULL << i)) != 0;

                if (is_unboxed) {
                    const Elm::EcoTypeInfo* ft = &g_type_graph->types[field->type_id];
                    assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                           "Record field is unboxed but type is not primitive");
                    printPrimitive(field_val, ft->data.primitive.prim_kind);
                } else {
                    print_typed_value(field_val, field->type_id, depth + 1);
                }
            } else {
                // Fallback without type info
                output_format("f%u = ", i);
                uint64_t field_val = static_cast<uint64_t>(record->values[i].i);
                print_value(field_val, depth + 1);
            }
        }
        output_text(" }");
        break;
    }

    case Elm::EcoTypeKind::Custom: {
        uint32_t first_ctor = typeInfo->data.custom.first_ctor;
        uint32_t ctor_count = typeInfo->data.custom.ctor_count;

        // Check for embedded constants first
        if (print_if_constant(value)) {
            break;
        }

        void* ptr = hpointerToPtr(value);
        if (!ptr) {
            output_text("<null>");
            break;
        }

        Header* header = static_cast<Header*>(ptr);
        assert(header->tag == Tag_Custom && "Expected Custom tag for Custom type");
        if (header->tag != Tag_Custom) {
            output_text("<not-custom>");
            break;
        }

        Custom* custom = static_cast<Custom*>(ptr);
        uint32_t ctor_id = custom->ctor;
        uint32_t size = custom->header.size;

        // Assert constructor info is available
        assert(g_type_graph->ctors && "Type graph has no ctors array");
        assert(ctor_count > 0 && "Custom type has no constructors in type graph - codegen bug");
        assert(ctor_id < ctor_count && "Constructor id out of bounds");

        const Elm::EcoCtorInfo* ctor_info = &g_type_graph->ctors[first_ctor + ctor_id];

        // Assert constructor name is available
        assert(g_type_graph->strings && "Type graph has no strings array");
        assert(ctor_info->name_index < g_type_graph->string_count &&
               "Constructor name_index out of bounds");

        // Print constructor name
        output_text(g_type_graph->strings[ctor_info->name_index]);

        // Print fields if any
        if (size > 0) {
            // Assert field info is available
            assert(g_type_graph->fields && "Type graph has no fields array");
            assert(ctor_info->field_count == size && "Field count mismatch");
            assert(ctor_info->first_field + size <= g_type_graph->field_count &&
                   "Field indices out of bounds");

            for (uint32_t i = 0; i < size; i++) {
                output_char(' ');

                uint64_t field_val = static_cast<uint64_t>(custom->values[i].i);
                bool is_unboxed = (custom->unboxed & (1ULL << i)) != 0;

                // Get field type from ctor info
                uint32_t field_type_id = g_type_graph->fields[ctor_info->first_field + i].type_id;

                // Assert field type is in valid range
                assert(field_type_id < g_type_graph->type_count &&
                       "Invalid field type_id in Custom type graph");

                // Check if nested custom needs parentheses (only for boxed values)
                bool needs_parens = false;
                if (!is_unboxed) {
                    void* field_ptr = hpointerToPtr(field_val);
                    if (field_ptr) {
                        Header* h = static_cast<Header*>(field_ptr);
                        needs_parens = (h->tag == Tag_Custom &&
                                       static_cast<Custom*>(field_ptr)->header.size > 0);
                    }
                }

                if (needs_parens) output_char('(');

                if (is_unboxed) {
                    // Unboxed value - use printPrimitive with type from type graph
                    const Elm::EcoTypeInfo* ft = &g_type_graph->types[field_type_id];
                    assert(ft->kind == Elm::EcoTypeKind::Primitive &&
                           "Custom field is unboxed but type is not primitive");
                    printPrimitive(field_val, ft->data.primitive.prim_kind);
                } else {
                    print_typed_value(field_val, field_type_id, depth + 1);
                }

                if (needs_parens) output_char(')');
            }
        }
        break;
    }

    case Elm::EcoTypeKind::Function:
        // Functions are printed as closures
        output_text("<function>");
        break;

    case Elm::EcoTypeKind::Polymorphic:
        // Polymorphic type variable - value is always boxed (!eco.value).
        // Just dispatch based on heap tag via print_value.
        // For Number constraint, this will print Int or Float correctly.
        // For EcoValue constraint, it handles any heap type.
        print_value(value, depth);
        break;
    }
}

// Output text to the current output stream (for kernel functions)
extern "C" void eco_output_text(const char* text) {
    output_text(text);
}

// Print an Elm value to the current output stream
extern "C" void eco_print_value(uint64_t value) {
    print_value(value, 0);
}

// Print an Elm value, unwrapping the Ctor0 box wrapper used by Guida compiler.
// This is used by Debug.log to show clean Elm values.
extern "C" void eco_print_elm_value(uint64_t value) {
    // Check for embedded constants first
    if (print_if_constant(value)) {
        return;
    }

    // Convert HPointer to raw pointer via allocator
    void* ptr = hpointerToPtr(value);
    if (!ptr) {
        output_text("<null>");
        return;
    }

    Header* header = static_cast<Header*>(ptr);

    // Check if this is a Ctor0 size=1 wrapper (Guida's box for polymorphic values)
    if (header->tag == Tag_Custom) {
        Custom* custom = static_cast<Custom*>(ptr);
        if (custom->ctor == 0 && custom->header.size == 1) {
            // Unwrap: print the inner value directly
            if (custom->unboxed & 1) {
                // Field is unboxed integer
                output_format("%lld", (long long)custom->values[0].i);
            } else {
                uint64_t inner = static_cast<uint64_t>(custom->values[0].i);
                // Safety check for small integers
                if (inner < 0x10000) {
                    output_format("%lld", (long long)inner);
                } else if (!print_if_constant(inner)) {
                    // Recursively print the inner value (also unwrapping if needed)
                    eco_print_elm_value(inner);
                }
            }
            return;
        }
    }

    // Not a wrapper, print normally
    print_value(value, 0);
}

// Convert an Elm value to its string representation
extern "C" uint64_t eco_value_to_string(uint64_t value) {
    // Temporarily capture output to a string
    std::ostringstream capture;
    std::ostringstream* prev = tl_output_stream;
    tl_output_stream = &capture;

    // Print the value
    print_value(value, 0);

    // Restore previous stream
    tl_output_stream = prev;

    // Allocate and return an ElmString from the captured output
    std::string result = capture.str();
    HPointer strPtr = alloc::allocStringFromUTF8(result);

    // Return as HPointer (uint64_t)
    uint64_t hptr_result;
    memcpy(&hptr_result, &strPtr, sizeof(hptr_result));
    return hptr_result;
}

//===----------------------------------------------------------------------===//
// GC Interface
//===----------------------------------------------------------------------===//

extern "C" void eco_safepoint() {
    // No-op for now
    // In the future, this will check if GC needs to run
}

extern "C" void eco_minor_gc() {
    Allocator::instance().minorGC();
}

extern "C" void eco_major_gc() {
    Allocator::instance().majorGC();
}

extern "C" void eco_gc_add_root(uint64_t* root_ptr) {
    Allocator::instance().getRootSet().addJitRoot(root_ptr);
}

extern "C" void eco_gc_remove_root(uint64_t* root_ptr) {
    Allocator::instance().getRootSet().removeJitRoot(root_ptr);
}

extern "C" uint64_t eco_gc_jit_root_count() {
    return Allocator::instance().getRootSet().getJitRoots().size();
}

//===----------------------------------------------------------------------===//
// Tag Extraction
//===----------------------------------------------------------------------===//

extern "C" uint32_t eco_get_header_tag(uint64_t obj_hptr) {
    void* obj = hpointerToPtr(obj_hptr);
    if (!obj) return 0;

    Header* header = static_cast<Header*>(obj);
    return header->tag;
}

extern "C" uint32_t eco_get_custom_ctor(uint64_t obj_hptr) {
    void* obj = hpointerToPtr(obj_hptr);
    if (!obj) return 0;

    Custom* custom = static_cast<Custom*>(obj);
    return custom->ctor;
}

/// Get the constructor tag for a value, handling both heap objects and embedded constants.
/// For heap Custom objects: returns the ctor field (16-bit constructor tag).
/// For embedded constants: returns the appropriate ctor tag:
///   - Nothing (kind=6) -> tag=1 (second constructor of Maybe)
///   - Nil (kind=5) -> tag=0 (first constructor of List)
///   - Other embedded constants -> tag=0
extern "C" uint32_t eco_get_tag(uint64_t val) {
    HPointer hp;
    memcpy(&hp, &val, sizeof(hp));

    // Check if this is an embedded constant (constant field != 0).
    if (hp.constant != 0) {
        // Map constant kind to ctor tag.
        // HPointer::ConstantKind values (from Heap.hpp):
        //   Nothing = 6 -> ctor tag 1
        //   Nil = 5 -> ctor tag 0
        //   Others -> ctor tag 0
        if (hp.constant == 6) {  // Nothing
            return 1;
        }
        return 0;
    }

    // Heap object: resolve pointer and check header tag.
    void* obj = Allocator::instance().resolve(hp);
    if (!obj) return 0;

    // Get the header to check the object type.
    Header* header = static_cast<Header*>(obj);

    // Handle based on heap object type.
    switch (header->tag) {
        case Tag_Cons:
            // Cons cells represent non-empty lists (constructor index 1).
            // Nil (empty list) is embedded constant, so any heap Cons is non-empty.
            return 1;
        case Tag_Custom:
            // Custom ADT: read the ctor field.
            return static_cast<Custom*>(obj)->ctor;
        default:
            // Other heap objects don't have constructor tags.
            return 0;
    }
}

//===----------------------------------------------------------------------===//
// List Element Access
//===----------------------------------------------------------------------===//

/// Gets the head of a Cons cell as an unboxed i64.
/// Handles both boxed and unboxed heads.
extern "C" int64_t eco_cons_head_i64(uint64_t cons) {
    HPointer hp;
    memcpy(&hp, &cons, sizeof(hp));

    // Resolve the Cons cell pointer.
    void* obj = Allocator::instance().resolve(hp);
    if (!obj) return 0;  // Should not happen for valid Cons

    Cons* consCell = static_cast<Cons*>(obj);

    // Check if head is unboxed (bit 0 of Header.unboxed field).
    if (consCell->header.unboxed & 1) {
        // Head is unboxed: return the i64 value directly.
        return consCell->head.i;
    } else {
        // Head is boxed: resolve the HPointer and load from ElmInt.
        HPointer headHp = consCell->head.p;
        void* headObj = Allocator::instance().resolve(headHp);
        if (!headObj) return 0;  // Should not happen

        // ElmInt has layout: [Header:8][value:8]
        // value is at offset 8.
        ElmInt* elmInt = static_cast<ElmInt*>(headObj);
        return elmInt->value;
    }
}

/// Gets the head of a Cons cell as an unboxed f64.
/// Handles both boxed and unboxed heads.
extern "C" double eco_cons_head_f64(uint64_t cons) {
    HPointer hp;
    memcpy(&hp, &cons, sizeof(hp));

    // Resolve the Cons cell pointer.
    void* obj = Allocator::instance().resolve(hp);
    if (!obj) return 0.0;  // Should not happen for valid Cons

    Cons* consCell = static_cast<Cons*>(obj);

    // Check if head is unboxed (bit 0 of Header.unboxed field).
    if (consCell->header.unboxed & 1) {
        // Head is unboxed: return the f64 value directly.
        return consCell->head.f;
    } else {
        // Head is boxed: resolve the HPointer and load from ElmFloat.
        HPointer headHp = consCell->head.p;
        void* headObj = Allocator::instance().resolve(headHp);
        if (!headObj) return 0.0;  // Should not happen

        // ElmFloat has layout: [Header:8][value:8]
        // value is at offset 8.
        ElmFloat* elmFloat = static_cast<ElmFloat*>(headObj);
        return elmFloat->value;
    }
}

/// Gets the head of a Cons cell as an unboxed i16 (Elm Char).
/// Handles both boxed and unboxed heads.
extern "C" int16_t eco_cons_head_i16(uint64_t cons) {
    HPointer hp;
    memcpy(&hp, &cons, sizeof(hp));

    // Resolve the Cons cell pointer.
    void* obj = Allocator::instance().resolve(hp);
    if (!obj) return 0;  // Should not happen for valid Cons

    Cons* consCell = static_cast<Cons*>(obj);

    // Check if head is unboxed (bit 0 of Header.unboxed field).
    if (consCell->header.unboxed & 1) {
        // Head is unboxed: return the i16 value directly.
        return consCell->head.c;
    } else {
        // Head is boxed: resolve the HPointer and load from ElmChar.
        HPointer headHp = consCell->head.p;
        void* headObj = Allocator::instance().resolve(headHp);
        if (!headObj) return 0;  // Should not happen

        // ElmChar has layout: [Header:8][value:2][padding:6]
        // value is at offset 8.
        ElmChar* elmChar = static_cast<ElmChar*>(headObj);
        return static_cast<int16_t>(elmChar->value);
    }
}

//===----------------------------------------------------------------------===//
// Arithmetic Helpers
//===----------------------------------------------------------------------===//

// Integer exponentiation: base^exp
// Returns 0 for negative exponents (caller handles this)
extern "C" int64_t eco_int_pow(int64_t base, int64_t exp) {
    if (exp < 0) {
        // Negative exponent returns 0 (caller should prevent this,
        // but handle defensively)
        return 0;
    }
    if (exp == 0) {
        return 1;
    }

    // Binary exponentiation for efficiency
    int64_t result = 1;
    while (exp > 0) {
        if (exp & 1) {
            result *= base;
        }
        base *= base;
        exp >>= 1;
    }
    return result;
}

//===----------------------------------------------------------------------===//
// HPointer Conversion
//===----------------------------------------------------------------------===//

extern "C" void* eco_resolve_hptr(uint64_t hptr) {
    return hpointerToPtr(hptr);
}
