//===- ParserExports.cpp - C-linkage exports for Parser module ------------===//
//
// Full implementation mirroring elm/parser's Elm/Kernel/Parser.js.
//
// Elm strings are stored as UTF-16 code units (ElmString::chars); offsets are
// UTF-16 code-unit indices, matching the JS kernel's use of charCodeAt/length.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"

using namespace Elm;
using namespace Elm::Kernel;
using namespace Elm::alloc;

namespace {

// Unboxed-kind bitmaps for tuples of Ints (2 bits/slot, 01 = unboxed Int).
// A (Int, Int) tuple is 0b0101 = 0x5; a (Int, Int, Int) tuple is 0b010101 = 0x15.
constexpr u32 TUPLE2_INT_INT       = 0x5;
constexpr u32 TUPLE3_INT_INT_INT   = 0x15;

// Resolves an HPtr-encoded string into a ParserStr the hot loops can index via
// at(i). A UTF-8 (all-ASCII) source exposes its bytes directly — no allocation,
// no transcode — so repeated primitive calls over a decoded UTF-8 source stay
// linear. Any other form (UTF-16 leaf / slice / rope / large-header) is
// flattened once per call to a u16 leaf (HEAP_026: ensureFlat may return a
// Tag_LargeStringHeader, resolved through `body`), exactly as before. The
// empty-string constant yields an empty ParserStr.
// A resolved parser string: either a UTF-16 payload (`wide`) or a UTF-8/ASCII
// byte payload (`narrow`). A UTF-8 (all-ASCII) source exposes its bytes
// directly — no flatten, no transcode, no allocation per primitive call —
// which keeps parsing a decoded UTF-8 source linear rather than O(n^2) (each
// primitive would otherwise re-widen the whole source via ensureFlat). UTF-16 /
// rope / slice sources flatten to a leaf once per call as before. `at(i)`
// widens an ASCII byte to a u16 unit; ASCII has no surrogates, so the surrogate
// branches in the loops below are simply never taken.
struct ParserStr {
    const u16* wide = nullptr;
    const u8* narrow = nullptr;
    int64_t len = 0;
    u16 at(int64_t i) const {
        return wide ? wide[i] : static_cast<u16>(narrow[i]);
    }
    bool valid() const { return wide != nullptr || narrow != nullptr; }
};

// Flatten `hp` (if needed) to a form whose payload can be indexed without
// further allocation. UTF-8 (ASCII) and already-flat forms pass through;
// UTF-16 rope/slice sources flatten to a leaf via ensureFlat — which
// ALLOCATES and is therefore a GC point. Callers holding raw payload
// pointers (or unrooted HPointers/closures) across this call must root or
// re-derive them.
inline HPointer parserFlatten(HPointer hp) {
    if (alloc::isEmbeddedConstant(hp)) return hp;  // empty string
    void* obj = Allocator::instance().resolve(hp);
    if (obj && StringOps::isUtf8(obj)) return hp;
    return StringOps::ensureFlat(hp);
}

// Derive the raw payload view from an already-flattened string. Performs no
// allocation; the returned raw pointers stay valid only until the next GC
// point.
inline ParserStr parserView(HPointer hp) {
    if (alloc::isEmbeddedConstant(hp)) return {};  // empty string
    void* obj = Allocator::instance().resolve(hp);
    if (obj && StringOps::isUtf8(obj)) {
        // UTF-8 (ASCII): index the bytes directly, no transcode.
        auto pr = StringOps::utf8Bytes(obj);
        return ParserStr{nullptr, pr.first, static_cast<int64_t>(pr.second)};
    }
    ElmString* s = alloc::resolveStringBody(obj);
    return ParserStr{s->chars, nullptr, static_cast<int64_t>(s->header.size)};
}

inline ParserStr resolveString(HPtr str) {
    HPointer hp;
    uint64_t bits = str.toBits();
    std::memcpy(&hp, &bits, sizeof(hp));
    return parserView(parserFlatten(hp));
}

inline int64_t stringLen(const ParserStr& s) { return s.len; }

inline bool isHighSurrogate(u16 c) {
    return (c & 0xF800) == 0xD800;
}

// Walks offset..target updating row/col, skipping the low surrogate of any
// surrogate pair. Matches the inner loop of the JS kernel's findSubString.
inline void advancePosition(const ParserStr& s, int64_t& offset, int64_t target,
                            int64_t& row, int64_t& col) {
    while (offset < target) {
        u16 code = s.at(offset++);
        if (code == 0x000A) {
            col = 1;
            row++;
        } else {
            col++;
            if (isHighSurrogate(code) && offset < target) {
                offset++;
            }
        }
    }
}

// Builds a (Int, Int) tuple on the heap with both fields unboxed.
inline HPtr intIntTuple(int64_t a, int64_t b) {
    return HPtr::fromBits(Export::encode(
        tuple2(unboxedInt(a), unboxedInt(b), TUPLE2_INT_INT)));
}

// Builds a (Int, Int, Int) tuple on the heap with all fields unboxed.
inline HPtr intIntIntTuple(int64_t a, int64_t b, int64_t c) {
    return HPtr::fromBits(Export::encode(
        tuple3(unboxedInt(a), unboxedInt(b), unboxedInt(c), TUPLE3_INT_INT_INT)));
}

} // namespace

extern "C" {

// isAsciiCode code offset src == (src.charCodeAt(offset) === code)
HPtr Elm_Kernel_Parser_isAsciiCode(int64_t code, int64_t offset, HPtr str) {
    ParserStr s = resolveString(str);
    i64 len = stringLen(s);
    bool result = (offset >= 0 && offset < len && s.at(offset) == code);
    return HPtr::fromBits(Export::encodeBoxedBool(result));
}

// isSubChar predicate offset src
//   returns  offset+advance  if predicate matches,
//            -2              if predicate matches and the char is '\n',
//            -1              otherwise (including end-of-string).
//
// Supplementary chars (surrogate pairs) advance offset by 2 when matched.
int64_t Elm_Kernel_Parser_isSubChar(HPtr closure, int64_t offset, HPtr str) {
    // Root the predicate closure across resolveString: flattening a rope/
    // slice source allocates (GC point), which would leave the by-value
    // closure bits stale when the predicate is applied below (mirrors
    // Elm_Kernel_String_map's closure rooting).
    HPointer closureHP = Export::decode(closure.toBits());
    Elm::StackRootGuard closureRoot(&closureHP);

    ParserStr s = resolveString(str);
    i64 len = stringLen(s);
    if (offset < 0 || offset >= len) {
        return -1;
    }

    // Load the char(s) at offset. Only the low 16 bits of the code point
    // survive the call (matching the JS kernel's BMP-only behaviour and the
    // u16 ABI of PK_Char); supplementary code points still advance offset by 2.
    u16 c0 = s.at(offset);
    i64 advance = 1;
    u32 codePoint = c0;
    if (isHighSurrogate(c0) && offset + 1 < len) {
        u16 c1 = s.at(offset + 1);
        if (c1 >= 0xDC00 && c1 <= 0xDFFF) {
            codePoint = 0x10000u + ((c0 - 0xD800u) << 10) + (c1 - 0xDC00u);
            advance = 2;
        }
    }

    // Invoke the predicate closure with the Char passed as an unboxed u16
    // (PK_Char). Use `eco_apply_closure_typed` (PAP-aware) so a curried
    // or partially-applied predicate is handled correctly — the strict-
    // arity entries assume the closure is exactly saturated by these
    // newargs, which isn't a contract user code is bound by.
    static constexpr unsigned char kLayoutChar1[3] = { 1, 0, 3 };
    const auto* layout = reinterpret_cast<const Elm::EvalParamLayout*>(kLayoutChar1);
    int64_t args[1] = { static_cast<int64_t>(codePoint & 0xFFFFu) };
    HPtr cl = HPtr::fromBits(Export::encode(closureHP));
    HPtr result = eco_apply_closure_typed(cl, args, 1, layout);
    if (!Export::decodeBoxedBool(result.toBits())) {
        return -1;
    }

    // '\n' is reported specially so callers can update row/col.
    if (codePoint == '\n') {
        return -2;
    }
    return offset + advance;
}

// isSubString small offset row col big
//   If `big` contains `small` starting at `offset`, returns (offset+len, row', col')
//   where row'/col' reflect the position after the match. Otherwise returns
//   (-1, row', col') with row'/col' advanced up to the first mismatch.
HPtr Elm_Kernel_Parser_isSubString(HPtr target, int64_t offset, int64_t row,
                                   int64_t col, HPtr str) {
    // Flatten both strings BEFORE deriving any raw payload pointers: either
    // flatten can allocate (GC point), which would invalidate a raw pointer
    // derived earlier. Both HPointers are rooted so each survives the
    // other's flatten; the views below perform no allocation.
    HPointer targetHP = Export::decode(target.toBits());
    HPointer strHP = Export::decode(str.toBits());
    Elm::StackRootGuard guard(&targetHP, &strHP);
    targetHP = parserFlatten(targetHP);
    strHP = parserFlatten(strHP);
    ParserStr small = parserView(targetHP);
    ParserStr big = parserView(strHP);
    i64 smallLen = stringLen(small);
    i64 bigLen = stringLen(big);

    bool isGood = (offset >= 0 && offset + smallLen <= bigLen);

    for (i64 i = 0; isGood && i < smallLen;) {
        u16 code = big.at(offset);
        isGood = (small.at(i++) == big.at(offset++));
        if (!isGood) break;

        if (code == 0x000A) {
            row++;
            col = 1;
        } else {
            col++;
            // For a surrogate pair, consume the paired low surrogate from both
            // strings and advance i/offset by one more. Matches JS semantics.
            if (isHighSurrogate(code) && i < smallLen) {
                isGood = (small.at(i++) == big.at(offset++));
            }
        }
    }

    i64 resultOffset = isGood ? offset : -1;
    return intIntIntTuple(resultOffset, row, col);
}

// findSubString small offset row col big
//   Returns (index, row', col') where `index` is the position of the first
//   occurrence of `small` in `big` at or after `offset`, or -1 if missing.
//   row'/col' end up at the position *after* the match (or at end-of-string
//   when not found) — mirrors JS, which advances through [offset, target).
HPtr Elm_Kernel_Parser_findSubString(HPtr target, int64_t offset, int64_t row,
                                     int64_t col, HPtr str) {
    // Same discipline as isSubString: flatten both (GC points) before
    // deriving raw payload pointers.
    HPointer targetHP = Export::decode(target.toBits());
    HPointer strHP = Export::decode(str.toBits());
    Elm::StackRootGuard guard(&targetHP, &strHP);
    targetHP = parserFlatten(targetHP);
    strHP = parserFlatten(strHP);
    ParserStr small = parserView(targetHP);
    ParserStr big = parserView(strHP);
    i64 smallLen = stringLen(small);
    i64 bigLen = stringLen(big);

    // indexOf(smallString, offset): naive scan is sufficient here — the JS
    // kernel delegates to String.prototype.indexOf, which is also linear.
    i64 index = -1;
    if (smallLen == 0) {
        index = (offset <= bigLen) ? offset : -1;
    } else if (offset >= 0) {
        for (i64 pos = offset; pos + smallLen <= bigLen; pos++) {
            bool match = true;
            for (i64 j = 0; j < smallLen; j++) {
                if (small.at(j) != big.at(pos + j)) {
                    match = false;
                    break;
                }
            }
            if (match) {
                index = pos;
                break;
            }
        }
    }

    i64 target_end = (index < 0) ? bigLen : (index + smallLen);
    if (big.valid() && offset >= 0) {
        advancePosition(big, offset, target_end, row, col);
    }

    return intIntIntTuple(index, row, col);
}

// chompBase10 offset src — advance past any run of ASCII '0'-'9', return new offset.
int64_t Elm_Kernel_Parser_chompBase10(int64_t offset, HPtr str) {
    ParserStr s = resolveString(str);
    i64 len = stringLen(s);
    while (offset < len) {
        u16 code = s.at(offset);
        if (code < 0x30 || code > 0x39) {
            break;
        }
        offset++;
    }
    return offset;
}

// consumeBase base offset src — parse a run of base-N digits ('0'..base-1),
// return (newOffset, accumulatedValue). Assumes base in [2, 10].
HPtr Elm_Kernel_Parser_consumeBase(int64_t base, int64_t offset, HPtr str) {
    ParserStr s = resolveString(str);
    i64 len = stringLen(s);
    i64 total = 0;
    while (offset < len) {
        i64 digit = static_cast<i64>(s.at(offset)) - 0x30;
        if (digit < 0 || digit >= base) {
            break;
        }
        total = base * total + digit;
        offset++;
    }
    return intIntTuple(offset, total);
}

// consumeBase16 offset src — parse a run of hex digits (0-9, A-F, a-f),
// return (newOffset, accumulatedValue).
HPtr Elm_Kernel_Parser_consumeBase16(int64_t offset, HPtr str) {
    ParserStr s = resolveString(str);
    i64 len = stringLen(s);
    i64 total = 0;
    while (offset < len) {
        u16 code = s.at(offset);
        i64 digit;
        if (code >= 0x30 && code <= 0x39) {
            digit = code - 0x30;
        } else if (code >= 0x41 && code <= 0x46) {
            digit = code - 55;           // 'A' (0x41) → 10
        } else if (code >= 0x61 && code <= 0x66) {
            digit = code - 87;           // 'a' (0x61) → 10
        } else {
            break;
        }
        total = 16 * total + digit;
        offset++;
    }
    return intIntTuple(offset, total);
}

} // extern "C"
