//===- StringExports.cpp - C-linkage exports for String module -------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "String.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/StringOps.hpp"
#include <cassert>
#include <vector>

using namespace Elm;
using namespace Elm::Kernel;

extern "C" {

int64_t Elm_Kernel_String_length(uint64_t str) {
    HPointer h = Export::decode(str);
    if (h.constant == Const_EmptyString + 1) {
        return 0;
    }
    void* ptr = Export::toPtr(str);
    assert(ptr && "Elm_Kernel_String_length: unexpected null pointer");
    return String::length(ptr);
}

uint64_t Elm_Kernel_String_append(uint64_t a, uint64_t b) {
    HPointer result = String::append(Export::toPtr(a), Export::toPtr(b));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_join(uint64_t sep, uint64_t stringList) {
    HPointer result = String::join(Export::toPtr(sep), Export::decode(stringList));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_cons(uint16_t c, uint64_t str) {
    HPointer result = String::cons(c, Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_uncons(uint64_t str) {
    HPointer result = String::uncons(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_fromList(uint64_t chars) {
    HPointer result = String::fromList(Export::decode(chars));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_slice(int64_t start, int64_t end, uint64_t str) {
    HPointer result = String::slice(start, end, Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_split(uint64_t sep, uint64_t str) {
    HPointer result = String::split(Export::toPtr(sep), Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_lines(uint64_t str) {
    HPointer result = String::lines(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_words(uint64_t str) {
    HPointer result = String::words(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_reverse(uint64_t str) {
    HPointer result = String::reverse(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_toUpper(uint64_t str) {
    HPointer result = String::toUpper(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_toLower(uint64_t str) {
    HPointer result = String::toLower(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_trim(uint64_t str) {
    HPointer result = String::trim(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_trimLeft(uint64_t str) {
    HPointer result = String::trimLeft(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_trimRight(uint64_t str) {
    HPointer result = String::trimRight(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_startsWith(uint64_t prefix, uint64_t str) {
    return Export::encodeBoxedBool(String::startsWith(Export::toPtr(prefix), Export::toPtr(str)));
}

uint64_t Elm_Kernel_String_endsWith(uint64_t suffix, uint64_t str) {
    return Export::encodeBoxedBool(String::endsWith(Export::toPtr(suffix), Export::toPtr(str)));
}

uint64_t Elm_Kernel_String_contains(uint64_t needle, uint64_t haystack) {
    return Export::encodeBoxedBool(String::contains(Export::toPtr(needle), Export::toPtr(haystack)));
}

uint64_t Elm_Kernel_String_indexes(uint64_t needle, uint64_t haystack) {
    HPointer result = String::indexes(Export::toPtr(needle), Export::toPtr(haystack));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_toInt(uint64_t str) {
    HPointer result = String::toInt(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_toFloat(uint64_t str) {
    HPointer result = String::toFloat(Export::toPtr(str));
    return Export::encode(result);
}

uint64_t Elm_Kernel_String_fromNumber(uint64_t n) {
    // The MLIR type signature is (i64) -> !eco.value, meaning we receive
    // an unboxed integer directly. Convert it to string.
    HPointer result = StringOps::fromInt(static_cast<int64_t>(n));
    return Export::encode(result);
}

//===----------------------------------------------------------------------===//
// Higher-order String functions (closure-based)
//===----------------------------------------------------------------------===//

// Helper to call a closure with a single Char argument and get Char result.
static uint16_t callCharToCharClosure(void* closure_ptr, uint16_t c) {
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;

    // Build argument array: captured values + the char argument.
    void* args[16];
    for (uint32_t i = 0; i < n_values; i++) {
        args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }
    args[n_values] = reinterpret_cast<void*>(static_cast<uint64_t>(c));

    // Call the evaluator.
    void* result = closure->evaluator(args);
    return static_cast<uint16_t>(reinterpret_cast<uint64_t>(result));
}

// Helper to call a closure with a single Char argument and get Bool result.
static bool callCharToBoolClosure(void* closure_ptr, uint16_t c) {
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;

    void* args[16];
    for (uint32_t i = 0; i < n_values; i++) {
        args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }
    args[n_values] = reinterpret_cast<void*>(static_cast<uint64_t>(c));

    void* result = closure->evaluator(args);
    return reinterpret_cast<uint64_t>(result) != 0;
}

// Helper to call a fold closure: (Char, acc) -> acc
static uint64_t callFoldClosure(void* closure_ptr, uint16_t c, uint64_t acc) {
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;

    void* args[16];
    for (uint32_t i = 0; i < n_values; i++) {
        args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }
    args[n_values] = reinterpret_cast<void*>(static_cast<uint64_t>(c));
    args[n_values + 1] = reinterpret_cast<void*>(acc);

    void* result = closure->evaluator(args);
    return reinterpret_cast<uint64_t>(result);
}

uint64_t Elm_Kernel_String_map(uint64_t closure, uint64_t str) {
    void* closure_ptr = reinterpret_cast<void*>(closure);
    ElmString* s = static_cast<ElmString*>(Export::toPtr(str));
    if (!s) {
        return Export::encode(Elm::alloc::emptyString());
    }

    u32 len = s->header.size;
    std::vector<u16> result;
    result.reserve(len);

    for (u32 i = 0; i < len; i++) {
        u16 mappedChar = callCharToCharClosure(closure_ptr, s->chars[i]);
        result.push_back(mappedChar);
    }

    return Export::encode(Elm::alloc::allocString(result.data(), result.size()));
}

uint64_t Elm_Kernel_String_filter(uint64_t closure, uint64_t str) {
    void* closure_ptr = reinterpret_cast<void*>(closure);
    ElmString* s = static_cast<ElmString*>(Export::toPtr(str));
    if (!s) {
        return Export::encode(Elm::alloc::emptyString());
    }

    u32 len = s->header.size;
    std::vector<u16> result;
    result.reserve(len);

    for (u32 i = 0; i < len; i++) {
        if (callCharToBoolClosure(closure_ptr, s->chars[i])) {
            result.push_back(s->chars[i]);
        }
    }

    return Export::encode(Elm::alloc::allocString(result.data(), result.size()));
}

uint64_t Elm_Kernel_String_any(uint64_t closure, uint64_t str) {
    void* closure_ptr = reinterpret_cast<void*>(closure);
    ElmString* s = static_cast<ElmString*>(Export::toPtr(str));
    if (!s) {
        return Export::encodeBoxedBool(false);
    }

    u32 len = s->header.size;
    for (u32 i = 0; i < len; i++) {
        if (callCharToBoolClosure(closure_ptr, s->chars[i])) {
            return Export::encodeBoxedBool(true);
        }
    }
    return Export::encodeBoxedBool(false);
}

uint64_t Elm_Kernel_String_all(uint64_t closure, uint64_t str) {
    void* closure_ptr = reinterpret_cast<void*>(closure);
    ElmString* s = static_cast<ElmString*>(Export::toPtr(str));
    if (!s) {
        return Export::encodeBoxedBool(true); // Empty string: all chars satisfy any predicate.
    }

    u32 len = s->header.size;
    for (u32 i = 0; i < len; i++) {
        if (!callCharToBoolClosure(closure_ptr, s->chars[i])) {
            return Export::encodeBoxedBool(false);
        }
    }
    return Export::encodeBoxedBool(true);
}

uint64_t Elm_Kernel_String_foldl(uint64_t closure, uint64_t acc, uint64_t str) {
    void* closure_ptr = reinterpret_cast<void*>(closure);
    ElmString* s = static_cast<ElmString*>(Export::toPtr(str));
    if (!s) {
        return acc;
    }

    uint64_t accumulator = acc;
    u32 len = s->header.size;
    for (u32 i = 0; i < len; i++) {
        accumulator = callFoldClosure(closure_ptr, s->chars[i], accumulator);
    }
    return accumulator;
}

uint64_t Elm_Kernel_String_foldr(uint64_t closure, uint64_t acc, uint64_t str) {
    void* closure_ptr = reinterpret_cast<void*>(closure);
    ElmString* s = static_cast<ElmString*>(Export::toPtr(str));
    if (!s) {
        return acc;
    }

    uint64_t accumulator = acc;
    u32 len = s->header.size;
    for (u32 i = len; i > 0; i--) {
        accumulator = callFoldClosure(closure_ptr, s->chars[i - 1], accumulator);
    }
    return accumulator;
}

} // extern "C"
