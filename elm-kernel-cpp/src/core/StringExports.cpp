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
    if (Elm::alloc::isEmptyString(h)) {
        return 0;
    }
    void* ptr = Export::toPtr(str_bits);
    assert(ptr && "Elm_Kernel_String_length: unexpected null pointer");
    return String::length(ptr);
}

// kernel-opt-04. Code unit at a 0-based index; 0 when out of range, when the
// string is an embedded constant, or on a null resolve -- exactly
// StringOps::charAt's contract (StringOps.hpp:401-463). gc-leaf-safe: charAt
// allocates on none of its six tag paths (its only calls are
// Allocator::resolve, which follows forwarding and never allocates), so
// callers need no rooting.
uint16_t eco_string_code_unit_at(HPtr str, int64_t index) {
    void* p = Export::toPtr(str.toBits());
    if (!p) return 0;                       // Const_Empty and friends
    return Elm::StringOps::charAt(p, index);
}

HPtr Elm_Kernel_String_append(HPtr a, HPtr b) {
    HPointer result = String::append(Export::toPtr(a.toBits()), Export::toPtr(b.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_join(HPtr sep, HPtr stringList) {
    HPointer result = String::join(Export::toPtr(sep.toBits()), Export::decode(stringList.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

// See CharExports.cpp for why this takes uint64_t instead of uint16_t.
HPtr Elm_Kernel_String_cons(uint64_t c_raw, HPtr str) {
    uint16_t c = static_cast<uint16_t>(c_raw & 0xFFFFu);
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

// Phase C per-instance variants. Route through the same StringOps backend
// used by the from_int / from_float intrinsic trampolines so output
// formatting is identical.
HPtr Elm_Kernel_String_fromNumber_Int(int64_t n) {
    HPointer result = Elm::StringOps::fromInt(n);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_fromNumber_Float(double n) {
    HPointer result = Elm::StringOps::fromFloat(n);
    return HPtr::fromBits(Export::encode(result));
}

// Unboxed-arg trampolines used by the eco.string.from_int/from_float
// intrinsic lowering. Routed through the same StringOps backend as
// String::fromNumber so output formatting is identical.
HPtr elm_string_from_int(int64_t n) {
    HPointer result = Elm::StringOps::fromInt(n);
    return HPtr::fromBits(Export::encode(result));
}

HPtr elm_string_from_double(double f) {
    HPointer result = Elm::StringOps::fromFloat(f);
    return HPtr::fromBits(Export::encode(result));
}

//===----------------------------------------------------------------------===//
// Higher-order String functions (closure-based)
//===----------------------------------------------------------------------===//

//===----------------------------------------------------------------------===//
// Closure-calling helpers.
//
// Higher-order kernels can't statically tell whether the user closure has
// been monomorphised flat or as a multi-stage curry — both shapes are
// valid. So we route through `eco_apply_closure{,_eval}`, which read the
// closure header at runtime and dispatch under-saturated / saturated /
// over-saturated correctly. Strict-arity entries are an unsafe API for
// user-facing kernels (see closure-callback audit).
//===----------------------------------------------------------------------===//

// Layout descriptors for the closure invocations below. Each declares the
// per-arg ParamKind so the runtime can hand unboxed primitives straight to
// wrappers that accept them. Layout bytes match `EvalParamLayout`:
//   { num_params, result_kind, kinds... }
static constexpr unsigned char kLayoutChar1[3]      = { 1, 0, 3 };       // (Char)
static constexpr unsigned char kLayoutCharBoxed[4]  = { 2, 0, 3, 0 };    // (Char, a)

// Call a closure with a single Char argument and Char result.
// Both argument and result travel as unboxed `uint16_t`: `eco_apply_closure_eval`
// reads the closure's intrinsic `result_kind` and either delivers the i16 directly
// (modern Char-returning wrapper) or unboxes a returned ElmChar exactly once on
// our behalf — strictly less work than the previous boxed round-trip.
static uint16_t callCharToCharClosure(HPtr closure_hptr, uint16_t c) {
    const auto* layout = reinterpret_cast<const Elm::EvalParamLayout*>(kLayoutChar1);
    int64_t args[1] = { static_cast<int64_t>(c) };
    uint16_t result = 0;
    eco_apply_closure_eval(closure_hptr, args, 1, layout, &result, /*desired_kind=*/3);
    return result;
}

// Call a closure with a single Char argument and Bool result.
// Bool is an embedded HPointer constant (Const_True / Const_False) so the result
// stays in PK_Boxed form; only the Char argument is passed unboxed.
static bool callCharToBoolClosure(HPtr closure_hptr, uint16_t c) {
    const auto* layout = reinterpret_cast<const Elm::EvalParamLayout*>(kLayoutChar1);
    int64_t args[1] = { static_cast<int64_t>(c) };
    HPtr result_hptr = eco_apply_closure_typed(closure_hptr, args, 1, layout);
    return Export::decodeBoxedBool(result_hptr.toBits());
}

// Call a fold closure: `(Char, acc) -> acc`. Char goes through unboxed; the
// accumulator stays HPointer-encoded.
static uint64_t callFoldClosure(HPtr closure_hptr, uint16_t c, uint64_t acc) {
    const auto* layout = reinterpret_cast<const Elm::EvalParamLayout*>(kLayoutCharBoxed);
    int64_t args[2] = { static_cast<int64_t>(c), static_cast<int64_t>(acc) };
    return eco_apply_closure_typed(closure_hptr, args, 2, layout).toBits();
}

// Snapshot a String (any form) into a stable std::vector<u16>. The snapshot
// lives on the C stack so callbacks that allocate (and may trigger GC) can't
// invalidate it. Returns an empty vector for nullptr / empty input.
// UTF-8 forms zero-extend their ASCII bytes directly (no toStdU16String
// widen); the result is identical (1 byte == 1 unit under the gate). W4.e.
static std::vector<u16> snapshotChars(void* str) {
    if (!str) return {};
    if (Elm::StringOps::isUtf8(str)) {
        auto pr = Elm::StringOps::utf8Bytes(str);
        return std::vector<u16>(pr.first, pr.first + pr.second);
    }
    auto u16str = Elm::StringOps::toStdU16String(str);
    return std::vector<u16>(u16str.begin(), u16str.end());
}

// Materialize a computed char vector into a String, choosing a UTF-8 form when
// the content is all-ASCII (W4.e). `result` is C-heap, so allocAsciiOut/GC
// cannot invalidate it and no rooting is needed. Empty -> the Empty constant.
static HPtr materializeString(const std::vector<u16>& result) {
    if (result.empty()) return HPtr::fromBits(Export::encode(Elm::alloc::emptyString()));
    u16 acc = 0;
    for (u16 c : result) acc |= c;
    if (acc < 0x80 && Allocator::instance().getConfig().utf8_strings_enabled) {
        Elm::StringOps::AsciiOut out = Elm::StringOps::allocAsciiOut(result.size());
        for (size_t i = 0; i < result.size(); ++i) out.dst[i] = static_cast<u8>(result[i]);
        return HPtr::fromBits(Export::encode(Elm::StringOps::finishAsciiOut(out)));
    }
    return HPtr::fromBits(
        Export::encode(Elm::alloc::allocString(result.data(), result.size())));
}

HPtr Elm_Kernel_String_map(HPtr closure, HPtr str) {
    auto chars = snapshotChars(Export::toPtr(str.toBits()));
    if (chars.empty()) {
        return HPtr::fromBits(Export::encode(Elm::alloc::emptyString()));
    }

    HPointer closureHP = Export::decode(closure.toBits());
    Elm::StackRootGuard closureRoot(&closureHP);

    std::vector<u16> result;
    result.reserve(chars.size());
    for (u16 c : chars) {
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        result.push_back(callCharToCharClosure(cl, c));
    }
    return materializeString(result);
}

HPtr Elm_Kernel_String_filter(HPtr closure, HPtr str) {
    auto chars = snapshotChars(Export::toPtr(str.toBits()));
    if (chars.empty()) {
        return HPtr::fromBits(Export::encode(Elm::alloc::emptyString()));
    }

    HPointer closureHP = Export::decode(closure.toBits());
    Elm::StackRootGuard closureRoot(&closureHP);

    std::vector<u16> result;
    result.reserve(chars.size());
    for (u16 c : chars) {
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        if (callCharToBoolClosure(cl, c)) result.push_back(c);
    }
    return materializeString(result);
}

HPtr Elm_Kernel_String_any(HPtr closure, HPtr str) {
    auto chars = snapshotChars(Export::toPtr(str.toBits()));
    if (chars.empty()) {
        return HPtr::fromBits(Export::encodeBoxedBool(false));
    }

    HPointer closureHP = Export::decode(closure.toBits());
    Elm::StackRootGuard closureRoot(&closureHP);

    for (u16 c : chars) {
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        if (callCharToBoolClosure(cl, c)) {
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

    HPointer closureHP = Export::decode(closure.toBits());
    Elm::StackRootGuard closureRoot(&closureHP);

    for (u16 c : chars) {
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        if (!callCharToBoolClosure(cl, c)) {
            return HPtr::fromBits(Export::encodeBoxedBool(false));
        }
    }
    return HPtr::fromBits(Export::encodeBoxedBool(true));
}

HPtr Elm_Kernel_String_foldl(HPtr closure, HPtr acc, HPtr str) {
    auto chars = snapshotChars(Export::toPtr(str.toBits()));
    if (chars.empty()) return acc;

    HPointer closureHP = Export::decode(closure.toBits());
    HPointer accHP     = Export::decode(acc.toBits());
    Elm::StackRootGuard loopRoots(&closureHP, &accHP);

    for (u16 c : chars) {
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t newAcc = callFoldClosure(cl, c, Export::encode(accHP));
        accHP = Export::decode(newAcc);
    }
    return HPtr::fromBits(Export::encode(accHP));
}

HPtr Elm_Kernel_String_foldr(HPtr closure, HPtr acc, HPtr str) {
    auto chars = snapshotChars(Export::toPtr(str.toBits()));
    if (chars.empty()) return acc;

    HPointer closureHP = Export::decode(closure.toBits());
    HPointer accHP     = Export::decode(acc.toBits());
    Elm::StackRootGuard loopRoots(&closureHP, &accHP);

    for (size_t i = chars.size(); i > 0; --i) {
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t newAcc = callFoldClosure(cl, chars[i - 1], Export::encode(accHP));
        accHP = Export::decode(newAcc);
    }
    return HPtr::fromBits(Export::encode(accHP));
}

} // extern "C"
