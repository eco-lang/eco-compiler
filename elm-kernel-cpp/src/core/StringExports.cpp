//===- StringExports.cpp - C-linkage exports for String module -------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "String.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
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
    // n is an HPointer to either ElmInt or ElmFloat (polymorphic number type).
    void* ptr = Export::toPtr(n);
    HPointer result = String::fromNumber(ptr);
    return Export::encode(result);
}

//===----------------------------------------------------------------------===//
// Higher-order String functions (closure-based)
//===----------------------------------------------------------------------===//

//===----------------------------------------------------------------------===//
// Closure-calling helpers (INV_2: delegate to runtime via eco_closure_call_saturated)
//===----------------------------------------------------------------------===//

// Call a closure with a single Char argument and get Char result.
// Char arg is boxed via eco_alloc_char. Result is unboxed from ElmChar.
static uint16_t callCharToCharClosure(uint64_t closure_hptr, uint16_t c) {
    uint64_t boxed_char = eco_alloc_char(static_cast<uint32_t>(c));
    uint64_t result_hptr = eco_closure_call_saturated(closure_hptr, &boxed_char, 1);
    // Unbox: resolve HPointer, read Char value
    void* charObj = reinterpret_cast<void*>(eco_resolve_hptr(result_hptr));
    ElmChar* ec = static_cast<ElmChar*>(charObj);
    return ec->value;
}

// Call a closure with a single Char argument and get Bool result.
// Bool is !eco.value (True/False embedded constants), not a primitive.
static bool callCharToBoolClosure(uint64_t closure_hptr, uint16_t c) {
    uint64_t boxed_char = eco_alloc_char(static_cast<uint32_t>(c));
    uint64_t result_hptr = eco_closure_call_saturated(closure_hptr, &boxed_char, 1);
    return Export::decodeBoxedBool(result_hptr);
}

// Call a fold closure: (Char, acc) -> acc
// Char is boxed via eco_alloc_char, acc flows through as HPointer-encoded.
static uint64_t callFoldClosure(uint64_t closure_hptr, uint16_t c, uint64_t acc) {
    uint64_t args[2] = { eco_alloc_char(static_cast<uint32_t>(c)), acc };
    return eco_closure_call_saturated(closure_hptr, args, 2);
}

uint64_t Elm_Kernel_String_map(uint64_t closure, uint64_t str) {
    ElmString* s = static_cast<ElmString*>(Export::toPtr(str));
    if (!s) {
        return Export::encode(Elm::alloc::emptyString());
    }

    u32 len = s->header.size;
    std::vector<u16> result;
    result.reserve(len);

    for (u32 i = 0; i < len; i++) {
        u16 mappedChar = callCharToCharClosure(closure, s->chars[i]);
        result.push_back(mappedChar);
    }

    return Export::encode(Elm::alloc::allocString(result.data(), result.size()));
}

uint64_t Elm_Kernel_String_filter(uint64_t closure, uint64_t str) {
    ElmString* s = static_cast<ElmString*>(Export::toPtr(str));
    if (!s) {
        return Export::encode(Elm::alloc::emptyString());
    }

    u32 len = s->header.size;
    std::vector<u16> result;
    result.reserve(len);

    for (u32 i = 0; i < len; i++) {
        if (callCharToBoolClosure(closure, s->chars[i])) {
            result.push_back(s->chars[i]);
        }
    }

    return Export::encode(Elm::alloc::allocString(result.data(), result.size()));
}

uint64_t Elm_Kernel_String_any(uint64_t closure, uint64_t str) {
    ElmString* s = static_cast<ElmString*>(Export::toPtr(str));
    if (!s) {
        return Export::encodeBoxedBool(false);
    }

    u32 len = s->header.size;
    for (u32 i = 0; i < len; i++) {
        if (callCharToBoolClosure(closure, s->chars[i])) {
            return Export::encodeBoxedBool(true);
        }
    }
    return Export::encodeBoxedBool(false);
}

uint64_t Elm_Kernel_String_all(uint64_t closure, uint64_t str) {
    ElmString* s = static_cast<ElmString*>(Export::toPtr(str));
    if (!s) {
        return Export::encodeBoxedBool(true); // Empty string: all chars satisfy any predicate.
    }

    u32 len = s->header.size;
    for (u32 i = 0; i < len; i++) {
        if (!callCharToBoolClosure(closure, s->chars[i])) {
            return Export::encodeBoxedBool(false);
        }
    }
    return Export::encodeBoxedBool(true);
}

uint64_t Elm_Kernel_String_foldl(uint64_t closure, uint64_t acc, uint64_t str) {
    ElmString* s = static_cast<ElmString*>(Export::toPtr(str));
    if (!s) {
        return acc;
    }

    uint64_t accumulator = acc;
    u32 len = s->header.size;
    for (u32 i = 0; i < len; i++) {
        accumulator = callFoldClosure(closure, s->chars[i], accumulator);
    }
    return accumulator;
}

uint64_t Elm_Kernel_String_foldr(uint64_t closure, uint64_t acc, uint64_t str) {
    ElmString* s = static_cast<ElmString*>(Export::toPtr(str));
    if (!s) {
        return acc;
    }

    uint64_t accumulator = acc;
    u32 len = s->header.size;
    for (u32 i = len; i > 0; i--) {
        accumulator = callFoldClosure(closure, s->chars[i - 1], accumulator);
    }
    return accumulator;
}

} // extern "C"
