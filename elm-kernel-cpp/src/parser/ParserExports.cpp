//===- ParserExports.cpp - C-linkage exports for Parser module ------------===//
//
// The kernel primitives of elm/parser: the few operations its Elm code cannot do
// quickly by itself, each of which inspects the source string at an offset.
//
// Every offset here, taken or returned, counts UTF-16 code units, so a
// supplementary character occupies two offsets. A string reaching
// these functions may be in a UTF-16 form or in one of the all-ASCII UTF-8 forms;
// ASCII bytes and UTF-16 units coincide, so both are read through one view,
// `ParserStr`, without copying an ASCII string.
//
// Positions are tracked as a row and a column. A newline moves to column 1 of the
// next row, and any other character, a surrogate pair included, moves one column.
//
// Getting a view of a non-ASCII rope or slice may copy it, which allocates and so
// is a GC point. Each export therefore passes every string through `parserFlatten`
// first, with any heap value it still needs rooted, and only then takes raw views,
// which it uses before anything else can allocate.
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

// The unboxed-field mask of a tuple whose two fields are both unboxed Ints. A mask
// has 2 bits per field, 01 meaning an unboxed Int, so this is 0b0101.
constexpr u32 TUPLE2_INT_INT       = 0x5;
// The unboxed-field mask of a tuple whose three fields are all unboxed Ints (0b010101).
constexpr u32 TUPLE3_INT_INT_INT   = 0x15;

// A read-only view of a string as a run of `len` UTF-16 code units.
//
// The units are either UTF-16 (`wide`) or ASCII bytes (`narrow`), and `at` widens
// a byte to the unit it equals. Reading an ASCII string's bytes in place means a
// parse over it does not copy the whole source at every primitive call. A view
// with both pointers null is empty. It does not own what it points at, which
// stays valid only until the next allocation. `at` does no bounds check.
struct ParserStr {
    const u16* wide = nullptr;
    const u8* narrow = nullptr;
    int64_t len = 0;
    // Returns the unit at index `i`, which must be in [0, len).
    u16 at(int64_t i) const {
        return wide ? wide[i] : static_cast<u16>(narrow[i]);
    }
    // Returns whether either pointer is non-null. A default (empty-constant) view has
    // neither; a zero-length view of a heap string may still be valid.
    bool valid() const { return wide != nullptr || narrow != nullptr; }
};

// Prepares `hp` for `parserView`. An embedded constant, which here is the empty
// string, and a UTF-8 form are returned as they are; anything else goes through
// `StringOps::ensureFlat`, which leaves a slice or rope above `string_flatten_limit`
// unchanged, and `parserView` cannot read that. `ensureFlat` may allocate, so this
// is a GC point: a raw pointer or unrooted heap value held across it must be
// re-derived afterwards.
inline HPointer parserFlatten(HPointer hp) {
    if (alloc::isEmbeddedConstant(hp)) return hp;  // empty string
    void* obj = Allocator::instance().resolve(hp);
    if (obj && StringOps::isUtf8(obj)) return hp;
    return StringOps::ensureFlat(hp);
}

// Returns a view of `hp`, which must be an embedded constant (giving an empty view),
// a UTF-8 form, a UTF-16 leaf or a large String. Does not allocate.
inline ParserStr parserView(HPointer hp) {
    if (alloc::isEmbeddedConstant(hp)) return {};  // empty string
    void* obj = Allocator::instance().resolve(hp);
    if (obj && StringOps::isUtf8(obj)) {
        auto pr = StringOps::utf8Bytes(obj);
        return ParserStr{nullptr, pr.first, static_cast<int64_t>(pr.second)};
    }
    alloc::U16View s = alloc::flatStringView(obj);
    return ParserStr{s.chars, nullptr, static_cast<int64_t>(s.length)};
}

// Returns a view of the string `str`, passed through `parserFlatten` first, so
// this is a GC point.
inline ParserStr resolveString(HPtr str) {
    HPointer hp;
    uint64_t bits = str.toBits();
    std::memcpy(&hp, &bits, sizeof(hp));
    return parserView(parserFlatten(hp));
}

// Returns the length of `s` in UTF-16 units.
inline int64_t stringLen(const ParserStr& s) { return s.len; }

// Returns whether `c` is in 0xD800-0xDFFF, a high or a low surrogate.
inline bool isHighSurrogate(u16 c) {
    return (c & 0xF800) == 0xD800;
}

// Moves `offset` up to `target`, updating `row` and `col` for each character passed.
// After a unit `isHighSurrogate` accepts, the next unit, if before `target`, is
// passed without counting a column of its own.
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

// Returns a new `(a, b)` tuple with both fields unboxed. Allocates.
inline HPtr intIntTuple(int64_t a, int64_t b) {
    return HPtr::fromBits(Export::encode(
        tuple2(unboxedInt(a), unboxedInt(b), TUPLE2_INT_INT)));
}

// Returns a new `(a, b, c)` tuple with all fields unboxed. Allocates.
inline HPtr intIntIntTuple(int64_t a, int64_t b, int64_t c) {
    return HPtr::fromBits(Export::encode(
        tuple3(unboxedInt(a), unboxedInt(b), unboxedInt(c), TUPLE3_INT_INT_INT)));
}

} // namespace

extern "C" {

// Returns True when `offset` is inside `str` and the unit there equals `code`, and
// False otherwise, as a boxed Bool.
HPtr Elm_Kernel_Parser_isAsciiCode(int64_t code, int64_t offset, HPtr str) {
    ParserStr s = resolveString(str);
    i64 len = stringLen(s);
    bool result = (offset >= 0 && offset < len && s.at(offset) == code);
    return HPtr::fromBits(Export::encodeBoxedBool(result));
}

// Applies the Char predicate `closure` to the character at `offset` in `str`.
// Returns -1 when `offset` is outside the string or the predicate gives False, -2
// when it accepts a newline, and otherwise the offset after the character: 2 units
// on for a surrogate pair, 1 for any other unit.
int64_t Elm_Kernel_Parser_isSubChar(HPtr closure, int64_t offset, HPtr str) {
    // The closure is rooted because resolveString can collect, which would leave
    // the closure's bits stale.
    HPointer closureHP = Export::decode(closure.toBits());
    Elm::StackRootGuard closureRoot(&closureHP);

    ParserStr s = resolveString(str);
    i64 len = stringLen(s);
    if (offset < 0 || offset >= len) {
        return -1;
    }

    // A surrogate followed by a low surrogate is decoded as one code point. Any
    // other unit is passed as a Char of its own value.
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

    // The Char goes unboxed (PK_Char). eco_apply_closure_typed handles a closure
    // of any arity, which a user's predicate may have. It may collect, so `s` is
    // not read after it.
    static constexpr auto kLayoutChar1 = Elm::makeEvalParamLayout<1>(0, {3});
    const auto* layout = Elm::asLayout(&kLayoutChar1);
    int64_t args[1] = { static_cast<int64_t>(codePoint) };
    HPtr cl = HPtr::fromBits(Export::encode(closureHP));
    HPtr result = eco_apply_closure_typed(cl, args, 1, layout);
    if (!Export::decodeBoxedBool(result.toBits())) {
        return -1;
    }

    if (codePoint == '\n') {
        return -2;
    }
    return offset + advance;
}

// Tests whether `str` holds `target` starting at `offset`, where the position is
// `row` and `col`. Returns `(offset', row', col')`: on a match, `offset'` is the end
// of the match and `row'`/`col'` the position there. Otherwise `offset'` is -1. If
// `offset` is negative or `target` does not fit between `offset` and the end, `row`
// and `col` come back unchanged; otherwise they have been advanced over the units
// that matched before the first that did not.
HPtr Elm_Kernel_Parser_isSubString(HPtr target, int64_t offset, int64_t row,
                                   int64_t col, HPtr str) {
    // Both strings are passed through `parserFlatten` before either view is taken,
    // because either flatten can collect. Both are rooted so each survives the other's flatten.
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
            // The unit after a surrogate is compared too, without a column of its own.
            if (isHighSurrogate(code) && i < smallLen) {
                isGood = (small.at(i++) == big.at(offset++));
            }
        }
    }

    i64 resultOffset = isGood ? offset : -1;
    return intIntIntTuple(resultOffset, row, col);
}

// Searches `str` for `target` from `offset`, where the position is `row` and `col`.
// Returns `(index, row', col')`: `index` is where the first occurrence at or after a
// non-negative `offset` starts, or -1 if there is none, and `row'`/`col'` are the
// position after that occurrence, or at the end of `str` when there is none. An
// empty `target` is found at `offset` itself when `offset` is at most the length.
// A negative `offset`, or one past the end, leaves `row` and `col` unchanged.
HPtr Elm_Kernel_Parser_findSubString(HPtr target, int64_t offset, int64_t row,
                                     int64_t col, HPtr str) {
    // As in isSubString, both strings are passed through `parserFlatten` before either
    // view is taken.
    HPointer targetHP = Export::decode(target.toBits());
    HPointer strHP = Export::decode(str.toBits());
    Elm::StackRootGuard guard(&targetHP, &strHP);
    targetHP = parserFlatten(targetHP);
    strHP = parserFlatten(strHP);
    ParserStr small = parserView(targetHP);
    ParserStr big = parserView(strHP);
    i64 smallLen = stringLen(small);
    i64 bigLen = stringLen(big);

    // A naive scan, which can take time proportional to the product of the lengths.
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

// Returns the offset after the run of ASCII digits '0'-'9' in `str` that starts at
// `offset`, or `offset` itself when there is none. `offset` must be non-negative;
// it is not checked.
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

// Reads the run of digits in base `base` starting at `offset` in `str`, and returns
// `(offset', value)`: the offset after the run and the number it spells, 0 for an
// empty run. A digit is a unit whose value minus '0' is below `base`, so only a base
// from 2 to 10 reads the usual digits. `offset` must be non-negative and the value
// must fit in a 64-bit Int; neither is checked.
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

// Reads the run of hexadecimal digits (0-9, A-F, a-f) starting at `offset` in `str`,
// and returns `(offset', value)` as consumeBase does, with the same unchecked
// requirements on `offset` and the value.
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
