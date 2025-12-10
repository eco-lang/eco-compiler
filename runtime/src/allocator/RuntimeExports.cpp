//===- RuntimeExports.cpp - C-linkage runtime function implementations ----===//
//
// This file implements the C-linkage functions that are called from
// LLVM-generated code.
//
//===----------------------------------------------------------------------===//

#include "RuntimeExports.h"
#include "Allocator.hpp"
#include "Heap.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>

using namespace Elm;

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
    // TODO: Implement PAP extension
    // Similar to eco_apply_closure but for extending existing PAPs

    fprintf(stderr, "eco_pap_extend: not yet implemented\n");
    return nullptr;
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

    std::abort();
}

// Forward declaration for recursive printing
static void print_value(uint64_t val, int depth);

// Print a string value to stderr
static void print_string(ElmString* str) {
    Header* header = &str->header;
    fputc('"', stderr);
    for (uint32_t i = 0; i < header->size; i++) {
        u16 c = str->chars[i];
        if (c == '"') {
            fputs("\\\"", stderr);
        } else if (c == '\\') {
            fputs("\\\\", stderr);
        } else if (c == '\n') {
            fputs("\\n", stderr);
        } else if (c == '\r') {
            fputs("\\r", stderr);
        } else if (c == '\t') {
            fputs("\\t", stderr);
        } else if (c < 32 || c >= 127) {
            fprintf(stderr, "\\u%04X", c);
        } else {
            fputc(static_cast<char>(c), stderr);
        }
    }
    fputc('"', stderr);
}

// Print a character value in Elm syntax
static void print_char(u16 c) {
    fputc('\'', stderr);
    if (c == '\'') {
        fputs("\\'", stderr);
    } else if (c == '\\') {
        fputs("\\\\", stderr);
    } else if (c == '\n') {
        fputs("\\n", stderr);
    } else if (c == '\r') {
        fputs("\\r", stderr);
    } else if (c == '\t') {
        fputs("\\t", stderr);
    } else if (c < 32 || c >= 127) {
        fprintf(stderr, "\\u%04X", c);
    } else {
        fputc(static_cast<char>(c), stderr);
    }
    fputc('\'', stderr);
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
                fputs("()", stderr);
                return true;
            case MlirConst_EmptyRec:
                fputs("{}", stderr);
                return true;
            case MlirConst_True:
                fputs("True", stderr);
                return true;
            case MlirConst_False:
                fputs("False", stderr);
                return true;
            case MlirConst_Nil:
                fputs("[]", stderr);
                return true;
            case MlirConst_Nothing:
                fputs("Nothing", stderr);
                return true;
            case MlirConst_EmptyString:
                fputs("\"\"", stderr);
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
    fputc('[', stderr);

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
            if (!first) fputs(", ", stderr);
            fputs("<invalid_list_tail>", stderr);
            break;
        }

        // Use full 64-bit pointer for JIT
        void* ptr = reinterpret_cast<void*>(current);
        if (!ptr) {
            if (!first) fputs(", ", stderr);
            fputs("<null>", stderr);
            break;
        }

        Header* header = static_cast<Header*>(ptr);

        // eco.construct uses Tag_Custom with ctor=0 for list cons cells
        // Native Cons type uses Tag_Cons
        if (header->tag == Tag_Custom) {
            Custom* custom = static_cast<Custom*>(ptr);
            if (custom->ctor != 0 || custom->header.size != 2) {
                if (!first) fputs(", ", stderr);
                fputs("<non_cons_custom>", stderr);
                break;
            }

            if (!first) {
                fputs(", ", stderr);
            }
            first = false;

            // Print the head element (field 0)
            // In JIT mode, values are stored as full 64-bit integers
            if (custom->unboxed & 1) {
                fprintf(stderr, "%lld", (long long)custom->values[0].i);
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
                fputs(", ", stderr);
            }
            first = false;

            // Print the head element
            if (header->unboxed & 1) {
                fprintf(stderr, "%lld", (long long)cons->head.i);
            } else {
                uint64_t head_val = cons->head.p.ptr |
                                   (static_cast<uint64_t>(cons->head.p.constant) << 40);
                print_value(head_val, depth + 1);
            }

            // Move to tail
            current = cons->tail.ptr | (static_cast<uint64_t>(cons->tail.constant) << 40);
        } else {
            if (!first) fputs(", ", stderr);
            fprintf(stderr, "<non_cons_tag_%d>", header->tag);
            break;
        }

        count++;
    }

    if (count >= MAX_LIST_ITEMS) {
        fputs(", ...", stderr);
    }

    fputc(']', stderr);
}

// Print a tuple
static void print_tuple2(Tuple2* tuple, int depth) {
    fputc('(', stderr);

    // Print first element - read as full 64-bit value for JIT mode
    if (tuple->header.unboxed & 1) {
        fprintf(stderr, "%lld", (long long)tuple->a.i);
    } else {
        print_value(static_cast<uint64_t>(tuple->a.i), depth + 1);
    }

    fputs(", ", stderr);

    // Print second element
    if (tuple->header.unboxed & 2) {
        fprintf(stderr, "%lld", (long long)tuple->b.i);
    } else {
        print_value(static_cast<uint64_t>(tuple->b.i), depth + 1);
    }

    fputc(')', stderr);
}

static void print_tuple3(Tuple3* tuple, int depth) {
    fputc('(', stderr);

    // Print first element - read as full 64-bit value for JIT mode
    if (tuple->header.unboxed & 1) {
        fprintf(stderr, "%lld", (long long)tuple->a.i);
    } else {
        print_value(static_cast<uint64_t>(tuple->a.i), depth + 1);
    }

    fputs(", ", stderr);

    // Print second element
    if (tuple->header.unboxed & 2) {
        fprintf(stderr, "%lld", (long long)tuple->b.i);
    } else {
        print_value(static_cast<uint64_t>(tuple->b.i), depth + 1);
    }

    fputs(", ", stderr);

    // Print third element
    if (tuple->header.unboxed & 4) {
        fprintf(stderr, "%lld", (long long)tuple->c.i);
    } else {
        print_value(static_cast<uint64_t>(tuple->c.i), depth + 1);
    }

    fputc(')', stderr);
}

// Print a custom type constructor
static void print_custom(Custom* custom, int depth) {
    uint32_t ctor = custom->ctor;
    uint32_t size = custom->header.size;

    // Print constructor tag
    fprintf(stderr, "Ctor%u", ctor);

    // Print fields if any
    if (size > 0) {
        fputc(' ', stderr);
        for (uint32_t i = 0; i < size; i++) {
            if (i > 0) fputc(' ', stderr);

            // Check if field is unboxed
            if (custom->unboxed & (1ULL << i)) {
                fprintf(stderr, "%lld", (long long)custom->values[i].i);
            } else {
                // Read as full 64-bit value for JIT mode
                uint64_t val = static_cast<uint64_t>(custom->values[i].i);
                // Wrap complex values in parens
                bool needs_parens = false;
                // Check if this is a non-constant pointer to a Custom with fields
                if (!print_if_constant(val)) {
                    void* ptr = reinterpret_cast<void*>(val);
                    if (ptr) {
                        Header* h = static_cast<Header*>(ptr);
                        needs_parens = (h->tag == Tag_Custom && static_cast<Custom*>(ptr)->header.size > 0);
                    }
                }
                if (needs_parens) fputc('(', stderr);
                print_value(val, depth + 1);
                if (needs_parens) fputc(')', stderr);
            }
        }
    }
}

// Print a record
static void print_record(Record* record, int depth) {
    uint32_t size = record->header.size;

    fputs("{ ", stderr);
    for (uint32_t i = 0; i < size; i++) {
        if (i > 0) fputs(", ", stderr);

        // We don't have field names, so use numeric indices
        fprintf(stderr, "f%u = ", i);

        // Check if field is unboxed
        if (record->unboxed & (1ULL << i)) {
            fprintf(stderr, "%lld", (long long)record->values[i].i);
        } else {
            // Read as full 64-bit value for JIT mode
            print_value(static_cast<uint64_t>(record->values[i].i), depth + 1);
        }
    }
    fputs(" }", stderr);
}

// Print a dynamic record
static void print_dynrecord(DynRecord* dynrec, int depth) {
    uint32_t size = dynrec->header.size;

    fputs("{ ", stderr);
    for (uint32_t i = 0; i < size; i++) {
        if (i > 0) fputs(", ", stderr);

        // We don't have field names, so use numeric indices
        fprintf(stderr, "f%u = ", i);

        // DynRecord values are HPointer, not Unboxable
        // For JIT mode, we need to read the full pointer differently
        // Since HPointer is a bitfield struct, we can't easily store 64-bit pointers
        // Fall back to the 44-bit encoding for now
        uint64_t val = dynrec->values[i].ptr |
                      (static_cast<uint64_t>(dynrec->values[i].constant) << 40);
        print_value(val, depth + 1);
    }
    fputs(" }", stderr);
}

// Print an array
static void print_array(ElmArray* array, int depth) {
    fputs("Array.fromList [", stderr);
    for (uint32_t i = 0; i < array->length; i++) {
        if (i > 0) fputs(", ", stderr);

        if (array->unboxed & (1ULL << i)) {
            fprintf(stderr, "%lld", (long long)array->elements[i].i);
        } else {
            // Read as full 64-bit value for JIT mode
            print_value(static_cast<uint64_t>(array->elements[i].i), depth + 1);
        }
    }
    fputc(']', stderr);
}

// Main value printer
static void print_value(uint64_t val, int depth) {
    // Prevent infinite recursion
    if (depth > 50) {
        fputs("...", stderr);
        return;
    }

    // Check for embedded constants first
    if (print_if_constant(val)) {
        return;
    }

    // Use full 64-bit pointer for JIT mode
    void* ptr = reinterpret_cast<void*>(val);
    if (!ptr) {
        fputs("<null>", stderr);
        return;
    }

    Header* header = static_cast<Header*>(ptr);

    switch (header->tag) {
        case Tag_Int: {
            ElmInt* intval = static_cast<ElmInt*>(ptr);
            fprintf(stderr, "%lld", (long long)intval->value);
            break;
        }

        case Tag_Float: {
            ElmFloat* floatval = static_cast<ElmFloat*>(ptr);
            fprintf(stderr, "%g", floatval->value);
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
            // Check if this is a list cons cell (ctor=0, size=2)
            if (custom->ctor == 0 && custom->header.size == 2) {
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
            fputs("<fn>", stderr);
            break;
        }

        case Tag_Process: {
            Process* proc = static_cast<Process*>(ptr);
            fprintf(stderr, "<process:%llu>", (unsigned long long)proc->id);
            break;
        }

        case Tag_Task: {
            fputs("<task>", stderr);
            break;
        }

        case Tag_FieldGroup: {
            fputs("<fieldgroup>", stderr);
            break;
        }

        case Tag_ByteBuffer: {
            ByteBuffer* buf = static_cast<ByteBuffer*>(ptr);
            fprintf(stderr, "<bytes:%u>", buf->header.size);
            break;
        }

        case Tag_Array: {
            ElmArray* array = static_cast<ElmArray*>(ptr);
            print_array(array, depth);
            break;
        }

        case Tag_Forward: {
            fputs("<forward>", stderr);
            break;
        }

        default:
            fprintf(stderr, "<unknown_tag_%u>", header->tag);
            break;
    }
}

extern "C" void eco_dbg_print(uint64_t* args, uint32_t num_args) {
    fprintf(stderr, "[eco.dbg] ");
    for (uint32_t i = 0; i < num_args; i++) {
        if (i > 0) fputc(' ', stderr);
        print_value(args[i], 0);
    }
    fprintf(stderr, "\n");
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
