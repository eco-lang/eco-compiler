//===- StringExports.cpp - C-linkage exports for String module -------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "../DirectCall.hpp"
#include "String.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"
#include <cassert>
#include <cstring>
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

HPtr Elm_Kernel_String_append(HPtr a, HPtr b) {
    HPointer result = String::append(Export::toPtr(a.toBits()), Export::toPtr(b.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_join(HPtr sep, HPtr stringList) {
    HPointer result = String::join(Export::toPtr(sep.toBits()), Export::decode(stringList.toBits()));
    return HPtr::fromBits(Export::encode(result));
}

// See CharExports.cpp for why this takes uint64_t instead of uint32_t. The
// Char is a code point; String::cons encodes it as 1 or 2 UTF-16 units.
HPtr Elm_Kernel_String_cons(uint64_t c_raw, HPtr str) {
    uint32_t c = static_cast<uint32_t>(c_raw & 0xFFFFFFFFu);
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

// The Int and Float variants format through the same StringOps functions as `String::fromNumber`
// and the intrinsic trampolines below, so every route gives the same text.
HPtr Elm_Kernel_String_fromNumber_Int(int64_t n) {
    HPointer result = Elm::StringOps::fromInt(n);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_String_fromNumber_Float(double n) {
    HPointer result = Elm::StringOps::fromFloat(n);
    return HPtr::fromBits(Export::encode(result));
}

// The call targets of the eco.string.from_int and eco.string.from_float intrinsics, formatting
// through the same StringOps functions as `String::fromNumber`.
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
// A closure these kernels are given may take all its arguments at once or one at a time, and
// nothing here says which. So each is applied through `eco_apply_closure_eval` or
// `eco_apply_closure_typed`, which read the closure's header and handle a closure that takes fewer
// or more arguments than it is given. A call may collect and move the closure, so each kernel
// roots it and encodes it afresh before every call.
//===----------------------------------------------------------------------===//

// The argument layouts for the calls below, which tell the apply call each argument's slot kind
// (3 is Char, 0 boxed) so it can box or unbox an argument to match the closure. The result kind given
// is not read.
//
// The layout of a call with one unboxed Char argument.
static constexpr auto kLayoutChar1     = Elm::makeEvalParamLayout<1>(0, {3});      // (Char)
// The layout of a call with an unboxed Char argument followed by a boxed one.
static constexpr auto kLayoutCharBoxed = Elm::makeEvalParamLayout<2>(0, {3, 0});   // (Char, a)

// Returns the Char that `closure_hptr` returns for the Char `c`. The argument is passed unboxed,
// and the result is asked for unboxed, so a closure that returns a boxed `ElmChar` has it read.
static uint32_t callCharToCharClosure(HPtr closure_hptr, uint32_t c) {
    const auto* layout = Elm::asLayout(&kLayoutChar1);
    int64_t args[1] = { static_cast<int64_t>(c) };
    uint32_t result = 0;
    eco_apply_closure_eval(closure_hptr, args, 1, layout, &result, /*desired_kind=*/3);
    return result;
}

// Returns whether `closure_hptr` returns True for the Char `c`. The argument is passed unboxed; a
// Bool is never unboxed, so the result is the True or False constant word and is decoded here.
static bool callCharToBoolClosure(HPtr closure_hptr, uint32_t c) {
    const auto* layout = Elm::asLayout(&kLayoutChar1);
    int64_t args[1] = { static_cast<int64_t>(c) };
    HPtr result_hptr = eco_apply_closure_typed(closure_hptr, args, 1, layout);
    return Export::decodeBoxedBool(result_hptr.toBits());
}

// Returns the encoded accumulator that the fold step `closure_hptr` returns for the Char `c` and
// the encoded accumulator `acc`. The Char is passed unboxed and the accumulator boxed.
static uint64_t callFoldClosure(HPtr closure_hptr, uint32_t c, uint64_t acc) {
    const auto* layout = Elm::asLayout(&kLayoutCharBoxed);
    int64_t args[2] = { static_cast<int64_t>(c), static_cast<int64_t>(acc) };
    return eco_apply_closure_typed(closure_hptr, args, 2, layout).toBits();
}

// Whether a fold step can be called through `dc` with the Char unboxed and the accumulator in
// one kind, `accKind`, that its slot takes and the step returns: then the fold carries the
// accumulator in that kind, unboxed for an Int, Float or Char, from one call to the next.
static bool foldCallFits(const Elm::DirectCall& dc, uint32_t& accKind) {
    if (!dc.ok() || dc.argKind(0) != 3 || dc.argKind(1) != dc.resultKind()) return false;
    accKind = dc.resultKind();
    return true;
}

// A copy of the UTF-16 units of the String `str`, of any form, empty for null. The copy is C++
// memory, outside the collected heap, so closures called while it is walked may allocate without
// invalidating it. A UTF-8 form's bytes are ASCII, so each is copied as one unit.
//
// Most strings these kernels see are short (a word, a line of text), so up to `kInline` units are
// copied into the object itself, on the caller's stack, and only a longer string is copied to the C
// heap. The kernels that use it call a closure per character, and two heap allocations per call (the
// u16string and then the vector) used to cost as much as a short string's closure calls.
class CharSnapshot {
public:
    explicit CharSnapshot(void* str) {
        if (!str) return;
        n_ = static_cast<Header*>(str)->size;
        u16* dst = inline_;
        if (n_ > kInline) {
            heap_.resize(n_);
            dst = heap_.data();
        }
        data_ = dst;
        if (Elm::StringOps::isUtf8(str)) {
            auto pr = Elm::StringOps::utf8Bytes(str);
            n_ = pr.second;
            for (size_t i = 0; i < n_; ++i) dst[i] = pr.first[i];
            return;
        }
        size_t at = 0;
        Elm::StringOps::forEachSegment(str, [&](const u16* p, u32 k) {
            std::memcpy(dst + at, p, k * sizeof(u16));
            at += k;
        });
        n_ = at;
    }
    CharSnapshot(const CharSnapshot&) = delete;
    CharSnapshot& operator=(const CharSnapshot&) = delete;

    const u16* data() const { return data_; }
    size_t size() const { return n_; }
    bool empty() const { return n_ == 0; }

private:
    static constexpr size_t kInline = 256;
    u16 inline_[kInline];
    std::vector<u16> heap_;
    const u16* data_ = inline_;
    size_t n_ = 0;
};

// Returns the String of the UTF-16 units in `result`: the Empty constant when there are none, a
// UTF-8 form when they are all ASCII and UTF-8 Strings are enabled, and a UTF-16 String otherwise.
// `result` is C++ memory, so the allocation cannot move it. A GC point.
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
    CharSnapshot chars(Export::toPtr(str.toBits()));
    if (chars.empty()) {
        return HPtr::fromBits(Export::encode(Elm::alloc::emptyString()));
    }

    HPointer closureHP = Export::decode(closure.toBits());
    Elm::StackRootGuard closureRoot(&closureHP);

    std::vector<u16> result;
    result.reserve(chars.size());
    const size_t n = chars.size();
    for (size_t i = 0; i < n;) {
        uint32_t c = Elm::StringOps::nextCodePoint(chars.data(), n, i);
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        Elm::StringOps::appendCodePoint(result, callCharToCharClosure(cl, c));
    }
    return materializeString(result);
}

HPtr Elm_Kernel_String_filter(HPtr closure, HPtr str) {
    CharSnapshot chars(Export::toPtr(str.toBits()));
    if (chars.empty()) {
        return HPtr::fromBits(Export::encode(Elm::alloc::emptyString()));
    }

    HPointer closureHP = Export::decode(closure.toBits());
    Elm::StackRootGuard closureRoot(&closureHP);

    std::vector<u16> result;
    result.reserve(chars.size());
    const size_t n = chars.size();
    for (size_t i = 0; i < n;) {
        size_t start = i;
        uint32_t c = Elm::StringOps::nextCodePoint(chars.data(), n, i);
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        // The kept Char's own units are copied, so a lone surrogate stays as it was.
        if (callCharToBoolClosure(cl, c))
            result.insert(result.end(), chars.data() + start, chars.data() + i);
    }
    return materializeString(result);
}

HPtr Elm_Kernel_String_any(HPtr closure, HPtr str) {
    CharSnapshot chars(Export::toPtr(str.toBits()));
    if (chars.empty()) {
        return HPtr::fromBits(Export::encodeBoxedBool(false));
    }

    HPointer closureHP = Export::decode(closure.toBits());
    Elm::StackRootGuard closureRoot(&closureHP);

    const size_t n = chars.size();
    for (size_t i = 0; i < n;) {
        uint32_t c = Elm::StringOps::nextCodePoint(chars.data(), n, i);
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        if (callCharToBoolClosure(cl, c)) {
            return HPtr::fromBits(Export::encodeBoxedBool(true));
        }
    }
    return HPtr::fromBits(Export::encodeBoxedBool(false));
}

HPtr Elm_Kernel_String_all(HPtr closure, HPtr str) {
    CharSnapshot chars(Export::toPtr(str.toBits()));
    if (chars.empty()) {
        return HPtr::fromBits(Export::encodeBoxedBool(true));
    }

    HPointer closureHP = Export::decode(closure.toBits());
    Elm::StackRootGuard closureRoot(&closureHP);

    const size_t n = chars.size();
    for (size_t i = 0; i < n;) {
        uint32_t c = Elm::StringOps::nextCodePoint(chars.data(), n, i);
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        if (!callCharToBoolClosure(cl, c)) {
            return HPtr::fromBits(Export::encodeBoxedBool(false));
        }
    }
    return HPtr::fromBits(Export::encodeBoxedBool(true));
}

HPtr Elm_Kernel_String_foldl(HPtr closure, HPtr acc, HPtr str) {
    CharSnapshot chars(Export::toPtr(str.toBits()));
    if (chars.empty()) return acc;

    HPointer closureHP = Export::decode(closure.toBits());
    HPointer accHP     = Export::decode(acc.toBits());
    Elm::StackRootGuard loopRoots(&closureHP, &accHP);

    const size_t n = chars.size();
    {
        Elm::DirectCall dc(&closureHP, 2);
        uint32_t ak;
        if (foldCallFits(dc, ak)) {
            uint64_t a = Elm::DirectCall::unbox(Export::encode(accHP), ak);
            for (size_t i = 0; i < n;) {
                uint32_t c = Elm::StringOps::nextCodePoint(chars.data(), n, i);
                uint64_t args[2] = { c, ak == 0 ? Export::encode(accHP) : a };
                a = dc.call(args);
                if (ak == 0) accHP = Export::decode(a);
            }
            if (ak != 0) return HPtr::fromBits(Elm::DirectCall::box(a, ak));
            return HPtr::fromBits(Export::encode(accHP));
        }
    }
    for (size_t i = 0; i < n;) {
        uint32_t c = Elm::StringOps::nextCodePoint(chars.data(), n, i);
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t newAcc = callFoldClosure(cl, c, Export::encode(accHP));
        accHP = Export::decode(newAcc);
    }
    return HPtr::fromBits(Export::encode(accHP));
}

HPtr Elm_Kernel_String_foldr(HPtr closure, HPtr acc, HPtr str) {
    CharSnapshot chars(Export::toPtr(str.toBits()));
    if (chars.empty()) return acc;

    HPointer closureHP = Export::decode(closure.toBits());
    HPointer accHP     = Export::decode(acc.toBits());
    Elm::StackRootGuard loopRoots(&closureHP, &accHP);

    // Walk back by code point: a low surrogate combines only with a
    // preceding high one (StringOps::prevCodePoint).
    {
        Elm::DirectCall dc(&closureHP, 2);
        uint32_t ak;
        if (foldCallFits(dc, ak)) {
            uint64_t a = Elm::DirectCall::unbox(Export::encode(accHP), ak);
            for (size_t i = chars.size(); i > 0;) {
                uint32_t c = Elm::StringOps::prevCodePoint(chars.data(), i);
                uint64_t args[2] = { c, ak == 0 ? Export::encode(accHP) : a };
                a = dc.call(args);
                if (ak == 0) accHP = Export::decode(a);
            }
            if (ak != 0) return HPtr::fromBits(Elm::DirectCall::box(a, ak));
            return HPtr::fromBits(Export::encode(accHP));
        }
    }
    for (size_t i = chars.size(); i > 0;) {
        uint32_t c = Elm::StringOps::prevCodePoint(chars.data(), i);
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t newAcc = callFoldClosure(cl, c, Export::encode(accHP));
        accHP = Export::decode(newAcc);
    }
    return HPtr::fromBits(Export::encode(accHP));
}

} // extern "C"
