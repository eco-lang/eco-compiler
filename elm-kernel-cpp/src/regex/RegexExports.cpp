//===- RegexExports.cpp - C-linkage exports for Regex module --------------===//
//
// elm/regex's kernel functions, implemented with the vendored SRELL library
// (a header-only engine with a std::regex-compatible interface).
//
// A compiled `srell::regex` is a C++ object and cannot live on the Elm heap,
// so an Elm `Regex` value is a heap Custom with constructor `CTOR_REGEX` whose
// first field is an integer id into a process-wide side table of compiled
// patterns. Entries are never removed, so a compiled pattern outlives every
// Elm value that names it and a GC never has to update the table.
//
// Every export that matches a string first copies it into a UTF-8 `std::string` and
// matches it with `srell::regex`, the `char` instantiation, which treats the
// text as bytes. A `Match` record's `index` is converted back from the byte
// offset to UTF-16 code units, the index JavaScript reports.
//
// A count `n` limits the matches used: 0 means none, and a negative `n` means
// no limit. The engine copy is on the C++ heap and immune to GC, but the heap
// values built along the way (match records, strings, list parts) are rooted
// across the allocations and closure calls that follow them, as the
// allocation rules in `ExportHelpers.hpp` require.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"
#include "../../vendor/srell.hpp"

#include <cmath>
#include <string>
#include <unordered_map>
#include <vector>

using namespace Elm;
using namespace Elm::Kernel;
using namespace Elm::alloc;

namespace {

// The constructor tag of an Elm `Regex` value. Its fields are the side-table id,
// then the caseInsensitive and multiline options as 0 or 1.
static constexpr u16 CTOR_REGEX = 0xFF00;

// The next side-table id to hand out. Ids start at 1 and are never reused.
// Unsynchronised, like the table.
static int64_t s_nextRegexId = 1;
// Returns the side table from id to compiled pattern. Its entries are `new`ed,
// never removed and never freed, so every compiled pattern leaks for the life
// of the process.
static std::unordered_map<int64_t, srell::regex*>& regexTable() {
    static std::unordered_map<int64_t, srell::regex*> table;
    return table;
}

// Adds `re` to the side table, which takes ownership of it, and returns its new id.
static int64_t registerRegex(srell::regex* re) {
    int64_t id = s_nextRegexId++;
    regexTable()[id] = re;
    return id;
}

// Returns a UTF-8 copy of the Elm string encoded as `strEnc`, in any of its
// forms. The empty string, and any other word `toPtr` maps to null, give "".
// Does not allocate on the Elm heap.
std::string elmStringToUTF8(uint64_t strEnc) {
    HPointer hp = Export::decode(strEnc);
    if (Elm::alloc::isEmptyString(hp)) return "";

    void* ptr = Export::toPtr(strEnc);
    if (!ptr) return "";
    return Elm::StringOps::toStdString(ptr);
}

// Returns a new Elm string holding the UTF-8 text `utf8`. A GC point unless
// `utf8` is empty.
HPointer utf8ToElmString(const std::string& utf8) {
    return allocStringFromUTF8(utf8);
}

// Returns the compiled pattern that the Elm `Regex` value `regexEnc` names, or
// null if the word does not decode to a pointer, the object's constructor field
// is not `CTOR_REGEX`, or its id is not in the side table. The object's tag is
// not checked, so the caller must pass a Custom. The pointer is valid for the
// life of the process.
srell::regex* getCompiledRegex(uint64_t regexEnc) {
    void* ptr = Export::toPtr(regexEnc);
    if (!ptr) return nullptr;

    Custom* c = static_cast<Custom*>(ptr);
    if (c->ctor != CTOR_REGEX) return nullptr;

    int64_t id = c->values[0].i;
    auto& table = regexTable();
    auto it = table.find(id);
    if (it == table.end()) return nullptr;
    return it->second;
}

// Returns a new Elm `Match` record
// { match : String, index : Int, number : Int, submatches : List (Maybe String) }
// built from `matchStr`, `index`, `number` and `submatches`, where a
// submatch whose flag is false becomes `Nothing`. A GC point.
//
// The slots follow the compiler's record layout: unboxed fields first, then
// boxed ones, each group sorted by name, so the order is index, number, match,
// submatches. The kind mask `0b0101`, which `record` reads as 2 bits per slot,
// makes slots 0 and 1 Int and slots 2 and 3 boxed.
HPointer createMatch(const std::string& matchStr, int64_t index, int64_t number,
                     const std::vector<std::pair<bool, std::string>>& submatches) {
    // Root submatchList (built across the loop's allocs) and matchStrHP
    // (held across record's alloc) — each utf8ToElmString / just / cons /
    // record call is a GC point that would otherwise leave the by-value
    // copies pointing at the pre-swap location.
    HPointer submatchList = listNil();
    HPointer matchStrHP = listNil();
    Elm::StackRootGuard guards(&submatchList, &matchStrHP);

    // Build submatches list (reversed for cons)
    for (auto it = submatches.rbegin(); it != submatches.rend(); ++it) {
        HPointer submatchValue;
        if (it->first) {
            // Just string. utf8ToElmString allocates; just() also allocates
            // and roots `str` internally via roots[]. submatchValue ends up
            // fresh (post-just), so no extra rooting needed before cons.
            HPointer str = utf8ToElmString(it->second);
            submatchValue = just(boxed(str), true);
        } else {
            submatchValue = nothing();
        }
        // cons() roots its head/tail args internally via eco_alloc_with_roots.
        submatchList = cons(boxed(submatchValue), submatchList, true);
    }

    matchStrHP = utf8ToElmString(matchStr);

    std::vector<Unboxable> fields(4);
    fields[0].i = index;
    fields[1].i = number;
    fields[2].p = matchStrHP;
    fields[3].p = submatchList;

    u64 unboxedMask = 0b0101;

    // record() roots all boxed entries of `fields` internally before alloc.
    return record(fields, unboxedMask);
}

// Converts byte offsets in the UTF-8 text `str` to UTF-16 code unit indexes,
// the unit of Elm's `Match.index`, `String.length` and `String.slice`. The
// UTF-8 lead byte decides each step: a 4-byte sequence (a code point above
// U+FFFF) is two units, any other sequence one, and any other byte counts as
// one unit of one byte. Offsets must be asked for in non-decreasing order, as a
// match iterator yields them; each call carries on from the last, so a whole
// scan is linear.
class Utf16Index {
public:
    explicit Utf16Index(const std::string& str) : str_(str) {}

    int64_t at(size_t byteOffset) {
        while (byte_ < byteOffset && byte_ < str_.size()) {
            unsigned char c = static_cast<unsigned char>(str_[byte_]);
            if ((c & 0x80) == 0) {
                byte_ += 1;
                units_ += 1;
            } else if ((c & 0xE0) == 0xC0) {
                byte_ += 2;
                units_ += 1;
            } else if ((c & 0xF0) == 0xE0) {
                byte_ += 3;
                units_ += 1;
            } else if ((c & 0xF8) == 0xF0) {
                byte_ += 4;
                units_ += 2;
            } else {
                byte_ += 1;  // Invalid byte, skip
                units_ += 1;
            }
        }
        return units_;
    }

private:
    const std::string& str_;
    size_t byte_ = 0;
    int64_t units_ = 0;
};

} // anonymous namespace

extern "C" {

HPtr Elm_Kernel_Regex_never() {
    // Compiles `(?!)`, which matches nowhere, under a new side-table id. If that
    // throws, returns the Nothing constant instead of a Regex.
    try {
        srell::regex* re = new srell::regex("(?!)", srell::regex::ECMAScript);
        int64_t id = registerRegex(re);

        std::vector<Unboxable> values(3);
        values[0].i = id;  // Integer ID into side table
        values[1].i = 0;   // caseInsensitive = false
        values[2].i = 0;   // multiline = false

        // All three fields are Ints: kind 01 in each 2-bit slot.
        HPointer regex = custom(CTOR_REGEX, values, 0x15);
        return HPtr::fromBits(Export::encode(regex));
    } catch (...) {
        return HPtr::fromBits(Export::encode(nothing()));
    }
}

double Elm_Kernel_Regex_infinity() {
    // Returns a double positive infinity, Elm's count for "every match".
    return std::numeric_limits<double>::infinity();
}

HPtr Elm_Kernel_Regex_fromStringWith(HPtr options, HPtr pattern) {
    // Returns `Just` a new Regex compiled from `pattern` as ECMAScript syntax,
    // or Nothing if `options` decodes to null or compiling throws.
    // `options` is { caseInsensitive : Bool, multiline : Bool }, two boxed Bool
    // slots in that order.
    uint64_t optionsEnc = options.toBits();
    uint64_t patternEnc = pattern.toBits();

    void* optPtr = Export::toPtr(optionsEnc);
    if (!optPtr) {
        return HPtr::fromBits(Export::encode(nothing()));
    }

    Record* opts = static_cast<Record*>(optPtr);
    bool caseInsensitive = Export::decodeBoxedBool(Export::encode(opts->values[0].p));
    bool multiline = Export::decodeBoxedBool(Export::encode(opts->values[1].p));

    std::string patternStr = elmStringToUTF8(patternEnc);

    try {
        srell::regex_constants::syntax_option_type flags = srell::regex::ECMAScript;
        if (caseInsensitive) {
            flags |= srell::regex::icase;
        }
        if (multiline) {
            flags |= srell::regex::multiline;
        }

        srell::regex* re = new srell::regex(patternStr, flags);
        int64_t id = registerRegex(re);

        std::vector<Unboxable> values(3);
        values[0].i = id;  // Integer ID into side table
        values[1].i = caseInsensitive ? 1 : 0;
        values[2].i = multiline ? 1 : 0;

        HPointer regex = custom(CTOR_REGEX, values, 0x15);  // three Ints
        HPointer result = just(boxed(regex), true);
        return HPtr::fromBits(Export::encode(result));
    } catch (const srell::regex_error&) {
        // Invalid regex pattern
        return HPtr::fromBits(Export::encode(nothing()));
    } catch (...) {
        return HPtr::fromBits(Export::encode(nothing()));
    }
}

HPtr Elm_Kernel_Regex_contains(HPtr regex, HPtr str) {
    // Returns, as a boxed Bool, whether `regex` matches anywhere in `str`; false
    // if `regex` is not a known Regex or matching throws. Allocates nothing.
    uint64_t regexEnc = regex.toBits();
    uint64_t strEnc = str.toBits();
    srell::regex* re = getCompiledRegex(regexEnc);
    if (!re) {
        return HPtr::fromBits(Export::encodeBoxedBool(false));
    }

    std::string strUtf8 = elmStringToUTF8(strEnc);

    try {
        bool result = srell::regex_search(strUtf8, *re);
        return HPtr::fromBits(Export::encodeBoxedBool(result));
    } catch (...) {
        return HPtr::fromBits(Export::encodeBoxedBool(false));
    }
}

HPtr Elm_Kernel_Regex_findAtMost(int64_t n, HPtr regex, HPtr str) {
    // Returns a list of Match records for the first `n` matches of `regex` in
    // `str`, numbered from 1, in order. Returns the empty list if `regex` is not
    // a known Regex or matching throws.
    uint64_t regexEnc = regex.toBits();
    uint64_t strEnc = str.toBits();

    if (n == 0) {
        return HPtr::fromBits(Export::encode(listNil()));
    }

    srell::regex* re = getCompiledRegex(regexEnc);
    if (!re) {
        return HPtr::fromBits(Export::encode(listNil()));
    }

    std::string strUtf8 = elmStringToUTF8(strEnc);

    // The accumulated match records cross later createMatch allocations, so
    // they are rooted, all of them with one shadow-stack record however many
    // there are (Elm::alloc::RootedSlots).
    Elm::alloc::RootedSlots matches;
    int64_t matchNum = 0;
    Utf16Index utf16Index(strUtf8);

    try {
        auto begin = srell::sregex_iterator(strUtf8.begin(), strUtf8.end(), *re);
        auto end = srell::sregex_iterator();

        for (auto it = begin; it != end; ++it) {
            if (n > 0 && matchNum >= n) break;

            const srell::smatch& match = *it;

            std::string matchStr = match.str();
            int64_t charIndex = utf16Index.at(static_cast<size_t>(match.position()));

            // Build submatches (skip index 0 which is the full match)
            std::vector<std::pair<bool, std::string>> submatches;
            for (size_t i = 1; i < match.size(); ++i) {
                if (match[i].matched) {
                    submatches.push_back({true, match[i].str()});
                } else {
                    submatches.push_back({false, ""});
                }
            }

            HPointer matchRecord = createMatch(matchStr, charIndex, matchNum + 1, submatches);
            matches.push(matchRecord);
            ++matchNum;
        }
    } catch (...) {
        return HPtr::fromBits(Export::encode(listNil()));
    }

    HPointer result = listFromPointers(matches);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_Regex_replaceAtMost(int64_t n, HPtr regex, HPtr closure, HPtr str) {
    // Returns `str` with its first `n` matches of `regex` replaced by what the
    // Elm function `closure` (Match -> String) returns for each, called once per
    // match in order. Returns `str` unchanged if `regex` is not a known Regex or
    // `n` is 0. If anything in the loop throws, returns the word `str` was passed as.
    uint64_t regexEnc = regex.toBits();
    uint64_t strEnc = str.toBits();

    srell::regex* re = getCompiledRegex(regexEnc);
    if (!re) {
        return str;
    }

    if (n == 0) {
        return str;
    }

    // Snapshot the input string into UTF-8 before the first GC point. After it,
    // `strEnc` may name a moved object, but the std::string copy is stable.
    std::string strUtf8 = elmStringToUTF8(strEnc);

    // Root the closure across every iteration: createMatch and
    // eco_apply_closure are GC points.
    HPointer closureHP = Export::decode(closure.toBits());
    Elm::StackRootGuard closureRoot(&closureHP);

    std::string result;
    size_t lastEnd = 0;
    int64_t matchNum = 0;
    Utf16Index utf16Index(strUtf8);

    try {
        auto begin = srell::sregex_iterator(strUtf8.begin(), strUtf8.end(), *re);
        auto end = srell::sregex_iterator();

        for (auto it = begin; it != end; ++it) {
            if (n > 0 && matchNum >= n) break;

            const srell::smatch& match = *it;
            size_t matchStart = static_cast<size_t>(match.position());
            size_t matchLen = match.length();

            // Append text before this match
            result.append(strUtf8.substr(lastEnd, matchStart - lastEnd));

            // Build Match record for callback
            std::string matchStr = match.str();
            int64_t charIndex = utf16Index.at(matchStart);

            std::vector<std::pair<bool, std::string>> submatches;
            for (size_t i = 1; i < match.size(); ++i) {
                if (match[i].matched) {
                    submatches.push_back({true, match[i].str()});
                } else {
                    submatches.push_back({false, ""});
                }
            }

            HPointer matchRecord = createMatch(matchStr, charIndex, matchNum + 1, submatches);

            // Root the just-built Match record over the closure call too:
            // closureHP is rooted by the outer guard, but matchRecord lives
            // only in this iteration's frame.
            Elm::StackRootGuard matchRoot(&matchRecord);
            HPtr cl = HPtr::fromBits(Export::encode(closureHP));
            uint64_t matchEnc = Export::encode(matchRecord);
            uint64_t replacementEnc =
                eco_apply_closure(cl, &matchEnc, 1).toBits();

            // Get replacement string
            std::string replacement = elmStringToUTF8(replacementEnc);
            result.append(replacement);

            lastEnd = matchStart + matchLen;
            ++matchNum;
        }

        // Append remaining text after last match
        result.append(strUtf8.substr(lastEnd));

    } catch (...) {
        // `str` is not rooted, and allocations in the loop may have moved it.
        return str;
    }

    HPointer resultStr = utf8ToElmString(result);
    return HPtr::fromBits(Export::encode(resultStr));
}

HPtr Elm_Kernel_Regex_splitAtMost(int64_t n, HPtr regex, HPtr str) {
    // Returns the parts of `str` between its first `n` matches of `regex`, in
    // order, as a list of strings. Returns a one-element list holding `str` if
    // `regex` is not a known Regex, `n` is 0, `str` is empty, or matching throws.
    uint64_t regexEnc = regex.toBits();
    uint64_t strEnc = str.toBits();

    srell::regex* re = getCompiledRegex(regexEnc);
    if (!re) {
        // Return list containing just the original string
        HPointer strHP = Export::decode(strEnc);
        return HPtr::fromBits(Export::encode(cons(boxed(strHP), listNil(), true)));
    }

    std::string strUtf8 = elmStringToUTF8(strEnc);

    if (n == 0 || strUtf8.empty()) {
        HPointer elmStr = Export::decode(strEnc);
        return HPtr::fromBits(Export::encode(cons(boxed(elmStr), listNil(), true)));
    }

    // The parts cross later string allocations; rooted with one record (see
    // findAtMost).
    Elm::alloc::RootedSlots parts;
    size_t lastEnd = 0;
    int64_t splitCount = 0;

    try {
        auto begin = srell::sregex_iterator(strUtf8.begin(), strUtf8.end(), *re);
        auto end = srell::sregex_iterator();

        for (auto it = begin; it != end; ++it) {
            if (n > 0 && splitCount >= n) break;

            const srell::smatch& match = *it;
            size_t matchStart = static_cast<size_t>(match.position());
            size_t matchLen = match.length();

            // Add part before the match
            std::string part = strUtf8.substr(lastEnd, matchStart - lastEnd);
            parts.push(utf8ToElmString(part));

            lastEnd = matchStart + matchLen;
            ++splitCount;
        }

        // Add final part after last match
        std::string finalPart = strUtf8.substr(lastEnd);
        parts.push(utf8ToElmString(finalPart));

    } catch (...) {
        // `strEnc` is not rooted, and allocations in the loop may have moved it.
        HPointer elmStr = Export::decode(strEnc);
        return HPtr::fromBits(Export::encode(cons(boxed(elmStr), listNil(), true)));
    }

    HPointer result = listFromPointers(parts);
    return HPtr::fromBits(Export::encode(result));
}

} // extern "C"
