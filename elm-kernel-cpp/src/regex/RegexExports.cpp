//===- RegexExports.cpp - C-linkage exports for Regex module --------------===//
//
// elm/regex's kernel functions, implemented with the vendored SRELL library
// (a header-only engine with a std::regex-compatible interface).
//
// A compiled pattern is a C++ object and cannot live on the Elm heap, so an Elm
// `Regex` value is a heap Custom with constructor `CTOR_REGEX` whose first field
// is an integer id into a process-wide side table of compiled patterns. Equal
// patterns compiled with equal flags share one entry and one id (they are
// interned), so the table grows with the number of distinct patterns, not with
// the number of compiles. Entries are never removed, so a compiled pattern
// outlives every Elm value that names it and a GC never has to update the table.
//
// Patterns and subjects are matched as UTF-16 code units, as JavaScript matches a
// regex without the `u` flag (elm/regex never passes it): `.` is one unit, so a
// character above U+FFFF is two matches, one per surrogate, and a lone surrogate
// is a character like any other. The engine is SRELL's `char16_t` instantiation
// with `UnitTraits`, which, unlike SRELL's own `u16regex`, does not decode
// surrogate pairs. Every export copies the subject into a `std::u16string` and
// matches that, so a match's position is already the UTF-16 index that a `Match`
// record's `index` reports, and the strings it builds keep every unit, lone
// surrogates included.
//
// Case-insensitive matching uses SRELL's Unicode simple case folding, where
// JavaScript's non-Unicode mode compares `toUpperCase` results and never maps a
// non-ASCII unit to an ASCII one; the two differ only on a few characters, such
// as U+017F and U+212A, which fold to `s` and `k` here but not in JavaScript.
//
// A count `n` limits the matches used: 0 means none, and a negative `n` means
// no limit. The engine copy is on the C++ heap and immune to GC, but the heap
// values built along the way (match records, strings, list parts) and the
// subject itself, which the error paths return, are rooted across the
// allocations and closure calls that follow them, as the allocation rules in
// `ExportHelpers.hpp` require.
//
// Only the engine's own failure, `srell::regex_error` (an invalid pattern, or a
// match that runs out of its backtracking budget), is caught. Anything else, such
// as an exception thrown out of the replacer that `Regex.replace` calls,
// propagates.
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
#include <limits>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

using namespace Elm;
using namespace Elm::Kernel;
using namespace Elm::alloc;

namespace {

// The constructor tag of an Elm `Regex` value. Its fields are the side-table id,
// then the caseInsensitive and multiline options as 0 or 1.
static constexpr u16 CTOR_REGEX = 0xFF00;

// SRELL traits that read each `charT` as one character: SRELL's `utf_traits_core`,
// rather than the `utf16_traits` its `u16regex` uses, which would combine a
// surrogate pair into one code point.
template <class charT>
struct UnitTraits : public srell::regex_traits<charT> {
    typedef srell::re_detail::utf_traits_core<charT> utf_traits;
};

// A pattern compiled over UTF-16 code units, and the iterator and match types over
// a `std::u16string` subject.
using UnitRegex = srell::basic_regex<char16_t, UnitTraits<char16_t>>;
using U16Iter = std::u16string::const_iterator;
using UnitIterator = srell::regex_iterator<U16Iter, char16_t, UnitTraits<char16_t>>;
using UnitMatch = srell::match_results<U16Iter>;

// The next side-table id to hand out. Ids start at 1 and are never reused.
// Unsynchronised, like the tables: only the one mutator thread compiles regexes.
static int64_t s_nextRegexId = 1;
// Returns the side table from id to compiled pattern. Its entries are `new`ed and
// never removed or freed, so each distinct compiled pattern lives as long as the
// process.
static std::unordered_map<int64_t, UnitRegex*>& regexTable() {
    static std::unordered_map<int64_t, UnitRegex*> table;
    return table;
}

// Returns the intern table, from `internKey` of a pattern and its flags to the id
// of its compiled entry in `regexTable`. A pattern that fails to compile is not
// entered.
static std::unordered_map<std::u16string, int64_t>& internTable() {
    static std::unordered_map<std::u16string, int64_t> table;
    return table;
}

// Returns the intern key of `pattern` compiled with `caseInsensitive` and
// `multiline`: one unit holding the two flag bits, then the pattern's units. The
// fixed-length prefix keeps keys of different flags apart whatever the pattern holds.
static std::u16string internKey(const std::u16string& pattern, bool caseInsensitive, bool multiline) {
    std::u16string key;
    key.reserve(pattern.size() + 1);
    key.push_back(static_cast<char16_t>((caseInsensitive ? 1 : 0) | (multiline ? 2 : 0)));
    key.append(pattern);
    return key;
}

// Adds `re` to the side table, which takes ownership of it, and returns its new id.
static int64_t registerRegex(UnitRegex* re) {
    int64_t id = s_nextRegexId++;
    regexTable()[id] = re;
    return id;
}

// Returns the id of `pattern` compiled with the given options: an interned entry's
// id when one exists, and otherwise the id of a new entry compiled now. Throws
// `srell::regex_error` when the pattern does not compile, entering nothing. Does
// not allocate on the Elm heap.
static int64_t internRegex(const std::u16string& pattern, bool caseInsensitive, bool multiline) {
    std::u16string key = internKey(pattern, caseInsensitive, multiline);
    auto& interned = internTable();
    auto it = interned.find(key);
    if (it != interned.end()) return it->second;

    srell::regex_constants::syntax_option_type flags = srell::regex_constants::ECMAScript;
    if (caseInsensitive) {
        flags |= srell::regex_constants::icase;
    }
    if (multiline) {
        flags |= srell::regex_constants::multiline;
    }
    UnitRegex* re = new UnitRegex(pattern.data(), pattern.size(), flags);
    int64_t id = registerRegex(re);
    interned.emplace(std::move(key), id);
    return id;
}

// Returns a new Elm `Regex` value naming side-table entry `id`, compiled with the
// given options. A GC point.
static HPointer regexValue(int64_t id, bool caseInsensitive, bool multiline) {
    std::vector<Unboxable> values(3);
    values[0].i = id;  // Integer ID into side table
    values[1].i = caseInsensitive ? 1 : 0;
    values[2].i = multiline ? 1 : 0;
    // All three fields are Ints: kind 01 in each 2-bit slot.
    return custom(CTOR_REGEX, values, 0x15);
}

// Returns a copy of the UTF-16 units of the Elm string encoded as `strEnc`, in any
// of its forms. The empty string, and any other word `toPtr` maps to null, give
// an empty copy. Does not allocate on the Elm heap.
std::u16string elmStringToU16(uint64_t strEnc) {
    HPointer hp = Export::decode(strEnc);
    if (Elm::alloc::isEmptyString(hp)) return {};

    void* ptr = Export::toPtr(strEnc);
    if (!ptr) return {};
    return Elm::StringOps::toStdU16String(ptr);
}

// Returns a new Elm string holding the units of `s`, every unit kept as it is, a
// lone surrogate included. A GC point unless `s` is empty.
HPointer u16ToElmString(const std::u16string& s) {
    return allocString(s);
}

// Returns the compiled pattern that the Elm `Regex` value `regexEnc` names, or
// null if the word does not decode to a pointer, the object's constructor field
// is not `CTOR_REGEX`, or its id is not in the side table. The object's tag is
// not checked, so the caller must pass a Custom. The pointer is valid for the
// life of the process.
UnitRegex* getCompiledRegex(uint64_t regexEnc) {
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

// The submatches of one match, in order: whether each matched, and its units.
using Submatches = std::vector<std::pair<bool, std::u16string>>;

// Returns the submatches of `match`, skipping index 0, the whole match.
Submatches submatchesOf(const UnitMatch& match) {
    Submatches out;
    for (size_t i = 1; i < match.size(); ++i) {
        if (match[i].matched) {
            out.push_back({true, match[i].str()});
        } else {
            out.push_back({false, std::u16string()});
        }
    }
    return out;
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
HPointer createMatch(const std::u16string& matchStr, int64_t index, int64_t number,
                     const Submatches& submatches) {
    // Root submatchList (built across the loop's allocs) and matchStrHP
    // (held across record's alloc) — each u16ToElmString / just / cons /
    // record call is a GC point that would otherwise leave the by-value
    // copies pointing at the pre-swap location.
    HPointer submatchList = listNil();
    HPointer matchStrHP = listNil();
    Elm::StackRootGuard guards(&submatchList, &matchStrHP);

    // Build submatches list (reversed for cons)
    for (auto it = submatches.rbegin(); it != submatches.rend(); ++it) {
        HPointer submatchValue;
        if (it->first) {
            // Just string. u16ToElmString allocates; just() also allocates
            // and roots `str` internally via roots[]. submatchValue ends up
            // fresh (post-just), so no extra rooting needed before cons.
            HPointer str = u16ToElmString(it->second);
            submatchValue = just(boxed(str), true);
        } else {
            submatchValue = nothing();
        }
        // cons() roots its head/tail args internally via eco_alloc_with_roots.
        submatchList = cons(boxed(submatchValue), submatchList, true);
    }

    matchStrHP = u16ToElmString(matchStr);

    std::vector<Unboxable> fields(4);
    fields[0].i = index;
    fields[1].i = number;
    fields[2].p = matchStrHP;
    fields[3].p = submatchList;

    u64 unboxedMask = 0b0101;

    // record() roots all boxed entries of `fields` internally before alloc.
    return record(fields, unboxedMask);
}

} // anonymous namespace

extern "C" {

HPtr Elm_Kernel_Regex_never() {
    // Returns a Regex compiled from `(?!)`, which matches nowhere. Every call names
    // the same side-table entry, compiled on the first call. If compiling throws,
    // returns the Nothing constant instead of a Regex.
    try {
        static const int64_t id = internRegex(u"(?!)", false, false);
        return HPtr::fromBits(Export::encode(regexValue(id, false, false)));
    } catch (const srell::regex_error&) {
        return HPtr::fromBits(Export::encode(nothing()));
    }
}

double Elm_Kernel_Regex_infinity() {
    // Returns a double positive infinity, Elm's count for "every match".
    return std::numeric_limits<double>::infinity();
}

HPtr Elm_Kernel_Regex_fromStringWith(HPtr options, HPtr pattern) {
    // Returns `Just` a Regex compiled from `pattern` as ECMAScript syntax, or
    // Nothing if `options` decodes to null or the pattern does not compile. A
    // pattern already compiled with the same options reuses its side-table entry.
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

    std::u16string patternU16 = elmStringToU16(patternEnc);

    int64_t id;
    try {
        id = internRegex(patternU16, caseInsensitive, multiline);
    } catch (const srell::regex_error&) {
        // Invalid regex pattern
        return HPtr::fromBits(Export::encode(nothing()));
    }

    HPointer regex = regexValue(id, caseInsensitive, multiline);
    HPointer result = just(boxed(regex), true);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_Regex_contains(HPtr regex, HPtr str) {
    // Returns, as a boxed Bool, whether `regex` matches anywhere in `str`; false
    // if `regex` is not a known Regex or the engine fails. Allocates nothing.
    uint64_t regexEnc = regex.toBits();
    uint64_t strEnc = str.toBits();
    UnitRegex* re = getCompiledRegex(regexEnc);
    if (!re) {
        return HPtr::fromBits(Export::encodeBoxedBool(false));
    }

    std::u16string subject = elmStringToU16(strEnc);

    try {
        bool result = srell::regex_search(subject.cbegin(), subject.cend(), *re);
        return HPtr::fromBits(Export::encodeBoxedBool(result));
    } catch (const srell::regex_error&) {
        return HPtr::fromBits(Export::encodeBoxedBool(false));
    }
}

HPtr Elm_Kernel_Regex_findAtMost(int64_t n, HPtr regex, HPtr str) {
    // Returns a list of Match records for the first `n` matches of `regex` in
    // `str`, numbered from 1, in order. Returns the empty list if `regex` is not
    // a known Regex or the engine fails.
    uint64_t regexEnc = regex.toBits();
    uint64_t strEnc = str.toBits();

    if (n == 0) {
        return HPtr::fromBits(Export::encode(listNil()));
    }

    UnitRegex* re = getCompiledRegex(regexEnc);
    if (!re) {
        return HPtr::fromBits(Export::encode(listNil()));
    }

    std::u16string subject = elmStringToU16(strEnc);

    // The accumulated match records cross later createMatch allocations, so
    // they are rooted, all of them with one shadow-stack record however many
    // there are (Elm::alloc::RootedSlots).
    Elm::alloc::RootedSlots matches;
    int64_t matchNum = 0;

    try {
        auto begin = UnitIterator(subject.cbegin(), subject.cend(), *re);
        auto end = UnitIterator();

        for (auto it = begin; it != end; ++it) {
            if (n > 0 && matchNum >= n) break;

            const UnitMatch& match = *it;
            HPointer matchRecord = createMatch(match.str(), static_cast<int64_t>(match.position()),
                                               matchNum + 1, submatchesOf(match));
            matches.push(matchRecord);
            ++matchNum;
        }
    } catch (const srell::regex_error&) {
        return HPtr::fromBits(Export::encode(listNil()));
    }

    HPointer result = listFromPointers(matches);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_Regex_replaceAtMost(int64_t n, HPtr regex, HPtr closure, HPtr str) {
    // Returns `str` with its first `n` matches of `regex` replaced by what the
    // Elm function `closure` (Match -> String) returns for each, called once per
    // match in order. Returns `str` unchanged if `regex` is not a known Regex or
    // `n` is 0, or if the engine fails part-way.
    uint64_t regexEnc = regex.toBits();

    UnitRegex* re = getCompiledRegex(regexEnc);
    if (!re) {
        return str;
    }

    if (n == 0) {
        return str;
    }

    // Root the closure and the subject across every iteration: createMatch and
    // eco_apply_closure are GC points, and the error path returns the subject.
    // The matching itself reads a C++ copy, which no GC moves.
    HPointer closureHP = Export::decode(closure.toBits());
    HPointer strHP = Export::decode(str.toBits());
    Elm::StackRootGuard roots(&closureHP, &strHP);
    std::u16string subject = elmStringToU16(str.toBits());

    std::u16string result;
    size_t lastEnd = 0;
    int64_t matchNum = 0;

    try {
        auto begin = UnitIterator(subject.cbegin(), subject.cend(), *re);
        auto end = UnitIterator();

        for (auto it = begin; it != end; ++it) {
            if (n > 0 && matchNum >= n) break;

            const UnitMatch& match = *it;
            size_t matchStart = static_cast<size_t>(match.position());
            size_t matchLen = static_cast<size_t>(match.length());

            // Append text before this match
            result.append(subject, lastEnd, matchStart - lastEnd);

            HPointer matchRecord = createMatch(match.str(), static_cast<int64_t>(matchStart),
                                               matchNum + 1, submatchesOf(match));

            // Root the just-built Match record over the closure call too:
            // closureHP is rooted by the outer guard, but matchRecord lives
            // only in this iteration's frame.
            Elm::StackRootGuard matchRoot(&matchRecord);
            HPtr cl = HPtr::fromBits(Export::encode(closureHP));
            uint64_t matchEnc = Export::encode(matchRecord);
            uint64_t replacementEnc =
                eco_apply_closure(cl, &matchEnc, 1).toBits();

            // Get replacement string
            result.append(elmStringToU16(replacementEnc));

            lastEnd = matchStart + matchLen;
            ++matchNum;
        }

        // Append remaining text after last match
        result.append(subject, lastEnd, std::u16string::npos);

    } catch (const srell::regex_error&) {
        // `strHP` is rooted, so it names the subject wherever a GC in the loop
        // moved it.
        return HPtr::fromBits(Export::encode(strHP));
    }

    HPointer resultStr = u16ToElmString(result);
    return HPtr::fromBits(Export::encode(resultStr));
}

HPtr Elm_Kernel_Regex_splitAtMost(int64_t n, HPtr regex, HPtr str) {
    // Returns the parts of `str` between its first `n` matches of `regex`, in
    // order, as a list of strings. Returns a one-element list holding `str` if
    // `regex` is not a known Regex, `n` is 0, `str` is empty, or the engine fails
    // part-way.
    uint64_t regexEnc = regex.toBits();
    uint64_t strEnc = str.toBits();

    UnitRegex* re = getCompiledRegex(regexEnc);
    if (!re) {
        // Return list containing just the original string
        HPointer strHP = Export::decode(strEnc);
        return HPtr::fromBits(Export::encode(cons(boxed(strHP), listNil(), true)));
    }

    std::u16string subject = elmStringToU16(strEnc);

    if (n == 0 || subject.empty()) {
        HPointer elmStr = Export::decode(strEnc);
        return HPtr::fromBits(Export::encode(cons(boxed(elmStr), listNil(), true)));
    }

    // The subject is rooted for the error path; the parts cross later string
    // allocations and are rooted with one record (see findAtMost).
    HPointer strHP = Export::decode(strEnc);
    Elm::StackRootGuard strRoot(&strHP);
    Elm::alloc::RootedSlots parts;
    size_t lastEnd = 0;
    int64_t splitCount = 0;

    try {
        auto begin = UnitIterator(subject.cbegin(), subject.cend(), *re);
        auto end = UnitIterator();

        for (auto it = begin; it != end; ++it) {
            if (n > 0 && splitCount >= n) break;

            const UnitMatch& match = *it;
            size_t matchStart = static_cast<size_t>(match.position());
            size_t matchLen = static_cast<size_t>(match.length());

            // Add part before the match
            parts.push(u16ToElmString(subject.substr(lastEnd, matchStart - lastEnd)));

            lastEnd = matchStart + matchLen;
            ++splitCount;
        }

        // Add final part after last match
        parts.push(u16ToElmString(subject.substr(lastEnd)));

    } catch (const srell::regex_error&) {
        // `strHP` is rooted, so it names the subject wherever a GC in the loop
        // moved it.
        return HPtr::fromBits(Export::encode(cons(boxed(strHP), listNil(), true)));
    }

    HPointer result = listFromPointers(parts);
    return HPtr::fromBits(Export::encode(result));
}

} // extern "C"
