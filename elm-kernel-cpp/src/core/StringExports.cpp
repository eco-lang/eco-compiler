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

int64_t Elm_Kernel_String_length(HPtr str) {
    uint64_t str_bits = str.toBits();
    HPointer h = Export::decode(str_bits);
    if (h.constant == Const_EmptyString + 1) {
        return 0;
    }
    void* ptr = Export::toPtr(str_bits);
    assert(ptr && "Elm_Kernel_String_length: unexpected null pointer");
    return String::length(ptr);
}

HPtr Elm_Kernel_String_append(HPtr a, HPtr b) {
    HPointer result = String::append(Export::toPtr(a.toBits()), Export::toPtr(b.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_join(HPtr sep, HPtr stringList) {
    HPointer result = String::join(Export::toPtr(sep.toBits()), Export::decode(stringList.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_cons(uint16_t c, HPtr str) {
    HPointer result = String::cons(c, Export::toPtr(str.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_uncons(HPtr str) {
    HPointer result = String::uncons(Export::toPtr(str.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_fromList(HPtr chars) {
    HPointer result = String::fromList(Export::decode(chars.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_slice(int64_t start, int64_t end, HPtr str) {
    HPointer result = String::slice(start, end, Export::toPtr(str.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_split(HPtr sep, HPtr str) {
    HPointer result = String::split(Export::toPtr(sep.toBits()), Export::toPtr(str.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_lines(HPtr str) {
    HPointer result = String::lines(Export::toPtr(str.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_words(HPtr str) {
    HPointer result = String::words(Export::toPtr(str.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_reverse(HPtr str) {
    HPointer result = String::reverse(Export::toPtr(str.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_toUpper(HPtr str) {
    HPointer result = String::toUpper(Export::toPtr(str.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_toLower(HPtr str) {
    HPointer result = String::toLower(Export::toPtr(str.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_trim(HPtr str) {
    HPointer result = String::trim(Export::toPtr(str.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_trimLeft(HPtr str) {
    HPointer result = String::trimLeft(Export::toPtr(str.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_trimRight(HPtr str) {
    HPointer result = String::trimRight(Export::toPtr(str.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_startsWith(HPtr prefix, HPtr str) {
    return HPtr::fromBits(Export::encodeBoxedBool(String::startsWith(Export::toPtr(prefix.toBits()), Export::toPtr(str.toBits()))));
}

HPtr Elm_Kernel_String_endsWith(HPtr suffix, HPtr str) {
    return HPtr::fromBits(Export::encodeBoxedBool(String::endsWith(Export::toPtr(suffix.toBits()), Export::toPtr(str.toBits()))));
}

HPtr Elm_Kernel_String_contains(HPtr needle, HPtr haystack) {
    return HPtr::fromBits(Export::encodeBoxedBool(String::contains(Export::toPtr(needle.toBits()), Export::toPtr(haystack.toBits()))));
}

HPtr Elm_Kernel_String_indexes(HPtr needle, HPtr haystack) {
    HPointer result = String::indexes(Export::toPtr(needle.toBits()), Export::toPtr(haystack.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_toInt(HPtr str) {
    HPointer result = String::toInt(Export::toPtr(str.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_toFloat(HPtr str) {
    HPointer result = String::toFloat(Export::toPtr(str.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_fromNumber(HPtr n) {
    uint64_t n_bits = n.toBits();
    // n is an HPointer to either ElmInt or ElmFloat (polymorphic number type).
    void* ptr = Export::toPtr(n_bits);
    HPointer result = String::fromNumber(ptr);
    return HPtr::fromBits(Export::encode(result));
}

//===----------------------------------------------------------------------===//
// Higher-order String functions (closure-based)
//===----------------------------------------------------------------------===//

//===----------------------------------------------------------------------===//
// Closure-calling helpers (INV_2: delegate to runtime via eco_closure_call_saturated)
//===----------------------------------------------------------------------===//

// Call a closure with a single Char argument and get Char result.
// Char arg is boxed via eco_alloc_char. Result is unboxed from ElmChar.
static uint16_t callCharToCharClosure(HPtr closure_hptr, uint16_t c) {
    uint64_t boxed_char = eco_alloc_char(static_cast<uint32_t>(c)).toBits();
    uint64_t args[1] = { boxed_char };
    HPtr result_hptr = eco_closure_call_saturated(closure_hptr, args, 1, /*layout=*/nullptr);
    // Unbox: resolve HPointer, read Char value
    void* charObj = reinterpret_cast<void*>(eco_resolve_hptr(result_hptr));
    ElmChar* ec = static_cast<ElmChar*>(charObj);
    return ec->value;
}

// Call a closure with a single Char argument and get Bool result.
// Bool is !eco.value (True/False embedded constants), not a primitive.
static bool callCharToBoolClosure(HPtr closure_hptr, uint16_t c) {
    uint64_t boxed_char = eco_alloc_char(static_cast<uint32_t>(c)).toBits();
    uint64_t args[1] = { boxed_char };
    HPtr result_hptr = eco_closure_call_saturated(closure_hptr, args, 1, /*layout=*/nullptr);
    return Export::decodeBoxedBool(result_hptr.toBits());
}

// Call a fold closure: (Char, acc) -> acc
// Char is boxed via eco_alloc_char, acc flows through as HPointer-encoded.
static uint64_t callFoldClosure(HPtr closure_hptr, uint16_t c, uint64_t acc) {
    uint64_t args[2] = { eco_alloc_char(static_cast<uint32_t>(c)).toBits(), acc };
    return eco_closure_call_saturated(closure_hptr, args, 2, /*layout=*/nullptr).toBits();
}

// Snapshot a String (any form) into a stable std::vector<u16>. The snapshot
// lives on the C stack so callbacks that allocate (and may trigger GC) can't
// invalidate it. Returns an empty vector for nullptr / empty input.
static std::vector<u16> snapshotChars(void* str) {
    if (!str) return {};
    auto u16str = Elm::StringOps::toStdU16String(str);
    return std::vector<u16>(u16str.begin(), u16str.end());
}

HPtr Elm_Kernel_String_map(HPtr closure, HPtr str) {
    auto chars = snapshotChars(Export::toPtr(str.toBits()));
    if (chars.empty()) {
        return HPtr::fromBits(Export::encode(Elm::alloc::emptyString()));
    }

    std::vector<u16> result;
    result.reserve(chars.size());
    for (u16 c : chars) {
        result.push_back(callCharToCharClosure(closure, c));
    }
    return HPtr::fromBits(Export::encode(Elm::alloc::allocString(result.data(), result.size())));
}

HPtr Elm_Kernel_String_filter(HPtr closure, HPtr str) {
    auto chars = snapshotChars(Export::toPtr(str.toBits()));
    if (chars.empty()) {
        return HPtr::fromBits(Export::encode(Elm::alloc::emptyString()));
    }

    std::vector<u16> result;
    result.reserve(chars.size());
    for (u16 c : chars) {
        if (callCharToBoolClosure(closure, c)) result.push_back(c);
    }
    return HPtr::fromBits(Export::encode(Elm::alloc::allocString(result.data(), result.size())));
}

HPtr Elm_Kernel_String_any(HPtr closure, HPtr str) {
    auto chars = snapshotChars(Export::toPtr(str.toBits()));
    if (chars.empty()) {
        return HPtr::fromBits(Export::encodeBoxedBool(false));
    }
    for (u16 c : chars) {
        if (callCharToBoolClosure(closure, c)) {
            return HPtr::fromBits(Export::encodeBoxedBool(true));
        }
    }
    return HPtr::fromBits(Export::encodeBoxedBool(false));
}

HPtr Elm_Kernel_String_all(HPtr closure, HPtr str) {
    auto chars = snapshotChars(Export::toPtr(str.toBits()));
    if (chars.empty()) {
        // Empty string: all chars satisfy any predicate.
        return HPtr::fromBits(Export::encodeBoxedBool(true));
    }
    for (u16 c : chars) {
        if (!callCharToBoolClosure(closure, c)) {
            return HPtr::fromBits(Export::encodeBoxedBool(false));
        }
    }
    return HPtr::fromBits(Export::encodeBoxedBool(true));
}

HPtr Elm_Kernel_String_foldl(HPtr closure, HPtr acc, HPtr str) {
    auto chars = snapshotChars(Export::toPtr(str.toBits()));
    if (chars.empty()) return acc;

    uint64_t accumulator = acc.toBits();
    for (u16 c : chars) {
        accumulator = callFoldClosure(closure, c, accumulator);
    }
    return HPtr::fromBits(accumulator);
}

HPtr Elm_Kernel_String_foldr(HPtr closure, HPtr acc, HPtr str) {
    auto chars = snapshotChars(Export::toPtr(str.toBits()));
    if (chars.empty()) return acc;

    uint64_t accumulator = acc.toBits();
    for (size_t i = chars.size(); i > 0; --i) {
        accumulator = callFoldClosure(closure, chars[i - 1], accumulator);
    }
    return HPtr::fromBits(accumulator);
}

} // extern "C"
