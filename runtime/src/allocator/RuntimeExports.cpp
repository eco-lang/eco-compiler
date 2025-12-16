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

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>

using namespace Elm;

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

extern "C" void* eco_alloc_custom(uint32_t ctor_tag, uint32_t field_count, uint32_t scalar_bytes) {
    // Calculate size: Header + ctor/unboxed (8 bytes) + fields
    size_t size = sizeof(Header) + 8 + field_count * sizeof(Unboxable) + scalar_bytes;

    void* obj = Allocator::instance().allocate(size, Tag_Custom);
    if (!obj) return nullptr;

    Custom* custom = static_cast<Custom*>(obj);
    custom->ctor = ctor_tag;
    custom->unboxed = 0;  // Will be set by caller if needed

    return obj;
}

extern "C" void eco_set_unboxed(void* obj, uint64_t bitmap) {
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

extern "C" void* eco_alloc_cons() {
    size_t size = sizeof(Cons);
    void* obj = Allocator::instance().allocate(size, Tag_Cons);
    return obj;
}

extern "C" void* eco_alloc_tuple2() {
    size_t size = sizeof(Tuple2);
    void* obj = Allocator::instance().allocate(size, Tag_Tuple2);
    return obj;
}

extern "C" void* eco_alloc_tuple3() {
    size_t size = sizeof(Tuple3);
    void* obj = Allocator::instance().allocate(size, Tag_Tuple3);
    return obj;
}

extern "C" void* eco_alloc_string(uint32_t length) {
    // Size: Header + length * sizeof(u16), aligned to 8 bytes
    size_t size = sizeof(Header) + length * sizeof(u16);
    size = (size + 7) & ~7;  // Align to 8 bytes

    void* obj = Allocator::instance().allocate(size, Tag_String);
    if (!obj) return nullptr;

    ElmString* str = static_cast<ElmString*>(obj);
    str->header.size = length;

    return obj;
}

extern "C" void* eco_alloc_closure(void* func_ptr, uint32_t num_captures) {
    // Size: Header + metadata (8 bytes) + evaluator ptr + captures
    size_t size = sizeof(Header) + 8 + sizeof(EvalFunction) + num_captures * sizeof(Unboxable);

    void* obj = Allocator::instance().allocate(size, Tag_Closure);
    if (!obj) return nullptr;

    Closure* closure = static_cast<Closure*>(obj);
    closure->n_values = 0;
    closure->max_values = num_captures;
    closure->unboxed = 0;
    closure->evaluator = reinterpret_cast<EvalFunction>(func_ptr);

    return obj;
}

extern "C" void* eco_alloc_int(int64_t value) {
    void* obj = Allocator::instance().allocate(sizeof(ElmInt), Tag_Int);
    if (!obj) return nullptr;

    ElmInt* elmInt = static_cast<ElmInt*>(obj);
    elmInt->value = value;

    return obj;
}

extern "C" void* eco_alloc_float(double value) {
    void* obj = Allocator::instance().allocate(sizeof(ElmFloat), Tag_Float);
    if (!obj) return nullptr;

    ElmFloat* elmFloat = static_cast<ElmFloat*>(obj);
    elmFloat->value = value;

    return obj;
}

extern "C" void* eco_alloc_char(uint32_t value) {
    void* obj = Allocator::instance().allocate(sizeof(ElmChar), Tag_Char);
    if (!obj) return nullptr;

    ElmChar* elmChar = static_cast<ElmChar*>(obj);
    elmChar->value = static_cast<u16>(value);

    return obj;
}

extern "C" void* eco_allocate(uint64_t size, uint32_t tag) {
    // Generic allocation with specified size and tag.
    // The tag should be one of the Tag enum values from Heap.hpp.
    void* obj = Allocator::instance().allocate(static_cast<size_t>(size), static_cast<Tag>(tag));
    return obj;
}

//===----------------------------------------------------------------------===//
// Field Store Functions
//===----------------------------------------------------------------------===//

extern "C" void eco_store_field(void* obj, uint32_t index, uint64_t value) {
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

extern "C" void eco_store_field_i64(void* obj, uint32_t index, int64_t value) {
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

extern "C" void eco_store_field_f64(void* obj, uint32_t index, double value) {
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

extern "C" void* eco_apply_closure(void* closure_ptr, uint64_t* args, uint32_t num_args) {
    // TODO: Implement closure application
    // This needs to:
    // 1. Check if closure becomes fully saturated
    // 2. If so, call the evaluator function
    // 3. Otherwise, create a new PAP with additional captured args

    fprintf(stderr, "eco_apply_closure: not yet implemented\n");
    return nullptr;
}

extern "C" void* eco_pap_extend(void* closure_ptr, uint64_t* args, uint32_t num_newargs) {
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
        return nullptr;
    }

    // Allocate a new closure with room for all captured values.
    size_t size = sizeof(Header) + 8 + sizeof(EvalFunction) + new_n_values * sizeof(Unboxable);
    void* obj = Allocator::instance().allocate(size, Tag_Closure);
    if (!obj) return nullptr;

    Closure* new_closure = static_cast<Closure*>(obj);

    // Copy metadata from old closure.
    new_closure->n_values = new_n_values;
    new_closure->max_values = max_values;
    new_closure->evaluator = old_closure->evaluator;

    // Build the new unboxed bitmap: old bits + new args (assume all new args are boxed).
    // New args are treated as boxed pointers for GC tracing purposes.
    new_closure->unboxed = old_unboxed;

    // Copy old captured values.
    for (uint32_t i = 0; i < old_n_values; i++) {
        new_closure->values[i] = old_closure->values[i];
    }

    // Copy new arguments.
    for (uint32_t i = 0; i < num_newargs; i++) {
        new_closure->values[old_n_values + i].i = static_cast<i64>(args[i]);
    }

    return new_closure;
}

extern "C" uint64_t eco_closure_call_saturated(void* closure_ptr, uint64_t* new_args, uint32_t num_newargs) {
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

extern "C" [[noreturn]] void eco_crash(void* message) {
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

// Print a string value
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

        // Use full 64-bit pointer for JIT
        void* ptr = reinterpret_cast<void*>(current);
        if (!ptr) {
            if (!first) output_text(", ");
            output_text("<null>");
            break;
        }

        Header* header = static_cast<Header*>(ptr);

        // eco.construct uses Tag_Custom with ctor=0 for list cons cells
        // Native Cons type uses Tag_Cons
        if (header->tag == Tag_Custom) {
            Custom* custom = static_cast<Custom*>(ptr);
            // A valid list cons cell has ctor=0, size=2, and tail (field 1) not unboxed
            if (custom->ctor != 0 || custom->header.size != 2 || (custom->unboxed & 2)) {
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

    // Print constructor tag
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
                    // Regular pointer
                    void* ptr = reinterpret_cast<void*>(val);
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

    // Use full 64-bit pointer for JIT mode
    void* ptr = reinterpret_cast<void*>(val);
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
            output_format("%g", floatval->value);
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
            // Check if this is a list cons cell (ctor=0, size=2, tail not unboxed)
            // A list cons cell has: ctor=0, exactly 2 fields, and the tail (field 1)
            // must be a pointer (not unboxed) since it points to the next cell or Nil.
            bool isList = (custom->ctor == 0 &&
                          custom->header.size == 2 &&
                          !(custom->unboxed & 2));  // tail must be a pointer
            if (isList) {
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
    output_format("[eco.dbg] %g\n", value);
}

// Debug print for unboxed char (i32 Unicode code point)
extern "C" void eco_dbg_print_char(int32_t value) {
    output_text("[eco.dbg] ");
    print_char(static_cast<u16>(value));
    output_text("\n");
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

    void* ptr = reinterpret_cast<void*>(value);
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
extern "C" void* eco_value_to_string(uint64_t value) {
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

    // Return as raw pointer for JIT
    return Allocator::instance().resolve(strPtr);
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

extern "C" uint32_t eco_get_header_tag(void* obj) {
    Header* header = static_cast<Header*>(obj);
    return header->tag;
}

extern "C" uint32_t eco_get_custom_ctor(void* obj) {
    Custom* custom = static_cast<Custom*>(obj);
    return custom->ctor;
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
