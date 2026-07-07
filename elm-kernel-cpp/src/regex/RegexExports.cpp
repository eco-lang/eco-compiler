//===- RegexExports.cpp - C-linkage exports for Regex module --------------===//
//
// Full implementation using SRELL (std::regex-compatible header-only library).
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"
#include "../../vendor/srell.hpp"

// eco_apply_closure is declared in RuntimeExports.h (included above)
#include <cmath>
#include <deque>
#include <string>
#include <unordered_map>
#include <vector>

using namespace Elm;
using namespace Elm::Kernel;
using namespace Elm::alloc;

namespace {

// Custom type ctor for storing compiled regex
// We store: regexId (integer), caseInsensitive flag, multiline flag
// The compiled srell::regex lives in a static side table, NOT on the Elm heap.
static constexpr u16 CTOR_REGEX = 0xFF00;

// Side table mapping integer IDs to compiled regex objects.
// Regex objects live here for their entire lifetime (never freed, matching
// the JS runtime behavior where compiled regexes are never collected).
static int64_t s_nextRegexId = 1;
static std::unordered_map<int64_t, srell::regex*>& regexTable() {
    static std::unordered_map<int64_t, srell::regex*> table;
    return table;
}

static int64_t registerRegex(srell::regex* re) {
    int64_t id = s_nextRegexId++;
    regexTable()[id] = re;
    return id;
}

// Helper: Convert any Elm String form (leaf or slice) to UTF-8 std::string
// for SRELL. Routes through StringOps::toStdString.
std::string elmStringToUTF8(uint64_t strEnc) {
    HPointer hp = Export::decode(strEnc);
    if (Elm::alloc::isEmptyString(hp)) return "";

    void* ptr = Export::toPtr(strEnc);
    if (!ptr) return "";
    return Elm::StringOps::toStdString(ptr);
}

// Helper: Create an Elm string from UTF-8
HPointer utf8ToElmString(const std::string& utf8) {
    return allocStringFromUTF8(utf8);
}

// Helper: Get compiled regex from Elm Regex Custom type
srell::regex* getCompiledRegex(uint64_t regexEnc) {
    void* ptr = Export::toPtr(regexEnc);
    if (!ptr) return nullptr;

    Custom* c = static_cast<Custom*>(ptr);
    if (c->ctor != CTOR_REGEX) return nullptr;

    // values[0] stores an integer ID into the regex side table
    int64_t id = c->values[0].i;
    auto& table = regexTable();
    auto it = table.find(id);
    if (it == table.end()) return nullptr;
    return it->second;
}

// Helper: Create a Match record
// Match = { match : String, index : Int, number : Int, submatches : List (Maybe String) }
// Fields in canonical order: index, match, number, submatches
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

    // Create record: fields in canonical order (index, match, number, submatches)
    matchStrHP = utf8ToElmString(matchStr);

    std::vector<Unboxable> fields(4);
    fields[0].i = index;                    // index (Int) - unboxed
    fields[1].p = matchStrHP;               // match (String) - boxed
    fields[2].i = number;                   // number (Int) - unboxed
    fields[3].p = submatchList;             // submatches (List) - boxed

    // Unboxed mask: bit 0 = index unboxed, bit 2 = number unboxed
    // Fields 1 and 3 are boxed (strings/lists)
    u64 unboxedMask = 0b0101;  // bits 0 and 2 are set

    // record() roots all boxed entries of `fields` internally before alloc.
    return record(fields, unboxedMask);
}

// Helper: Calculate byte offset to character index in UTF-8
int64_t byteOffsetToCharIndex(const std::string& str, size_t byteOffset) {
    int64_t charIndex = 0;
    size_t i = 0;
    while (i < byteOffset && i < str.size()) {
        unsigned char c = static_cast<unsigned char>(str[i]);
        if ((c & 0x80) == 0) {
            i += 1;
        } else if ((c & 0xE0) == 0xC0) {
            i += 2;
        } else if ((c & 0xF0) == 0xE0) {
            i += 3;
        } else if ((c & 0xF8) == 0xF0) {
            i += 4;
        } else {
            i += 1;  // Invalid byte, skip
        }
        ++charIndex;
    }
    return charIndex;
}

} // anonymous namespace

extern "C" {

HPtr Elm_Kernel_Regex_never() {
    // Return a regex that never matches anything.
    try {
        srell::regex* re = new srell::regex("(?!)", srell::regex::ECMAScript);
        int64_t id = registerRegex(re);

        std::vector<Unboxable> values(3);
        values[0].i = id;  // Integer ID into side table
        values[1].i = 0;   // caseInsensitive = false
        values[2].i = 0;   // multiline = false

        // All fields are unboxed (plain integers, not heap pointers)
        HPointer regex = custom(CTOR_REGEX, values, 0b111);
        return HPtr::fromBits(Export::encode(regex));
    } catch (...) {
        return HPtr::fromBits(Export::encode(nothing()));
    }
}

double Elm_Kernel_Regex_infinity() {
    // Return positive infinity (used for "match all" in replaceAtMost, etc.).
    return std::numeric_limits<double>::infinity();
}

HPtr Elm_Kernel_Regex_fromStringWith(HPtr options, HPtr pattern) {
    uint64_t optionsEnc = options.toBits();
    uint64_t patternEnc = pattern.toBits();
    // Options is a record: { caseInsensitive : Bool, multiline : Bool }
    // Fields in canonical order: caseInsensitive, multiline
    // Returns Maybe Regex

    void* optPtr = Export::toPtr(optionsEnc);
    if (!optPtr) {
        return HPtr::fromBits(Export::encode(nothing()));
    }

    Record* opts = static_cast<Record*>(optPtr);
    // Both fields are boxed Bool (HPointer constants)
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

        HPointer regex = custom(CTOR_REGEX, values, 0b111);
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
    // Returns Bool (boxed as True/False HPointer constant)
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
    uint64_t regexEnc = regex.toBits();
    uint64_t strEnc = str.toBits();
    // Returns List Match
    // n is the maximum number of matches to find (negative = unlimited)

    if (n == 0) {
        return HPtr::fromBits(Export::encode(listNil()));
    }

    srell::regex* re = getCompiledRegex(regexEnc);
    if (!re) {
        return HPtr::fromBits(Export::encode(listNil()));
    }

    std::string strUtf8 = elmStringToUTF8(strEnc);

    // std::deque has stable per-element addresses across push_back, so we
    // can register each accumulated HPointer as its own stack root range.
    // A std::vector<HPointer> would invalidate addresses on capacity growth.
    std::deque<HPointer> matches;
    auto& rs = Allocator::instance().getRootSet();
    size_t savedRange = rs.stackRangePoint();
    int64_t matchNum = 0;

    try {
        auto begin = srell::sregex_iterator(strUtf8.begin(), strUtf8.end(), *re);
        auto end = srell::sregex_iterator();

        for (auto it = begin; it != end; ++it) {
            if (n > 0 && matchNum >= n) break;

            const srell::smatch& match = *it;

            std::string matchStr = match.str();
            size_t byteOffset = static_cast<size_t>(match.position());
            int64_t charIndex = byteOffsetToCharIndex(strUtf8, byteOffset);

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
            matches.push_back(matchRecord);
            // Root the just-pushed slot. Subsequent createMatch calls allocate;
            // without this, prior matches[i] become stale across the GC.
            rs.pushStackRootRange(&matches.back(), 1, 1);
            ++matchNum;
        }
    } catch (...) {
        rs.restoreStackRangePoint(savedRange);
        return HPtr::fromBits(Export::encode(listNil()));
    }

    // Snapshot current (post-GC) HPointers into a vector for listFromPointers,
    // which roots its own copies internally.
    std::vector<HPointer> matchesVec(matches.begin(), matches.end());
    HPointer result = listFromPointers(matchesVec);
    rs.restoreStackRangePoint(savedRange);
    return HPtr::fromBits(Export::encode(result));
}

HPtr Elm_Kernel_Regex_replaceAtMost(int64_t n, HPtr regex, HPtr closure, HPtr str) {
    uint64_t regexEnc = regex.toBits();
    uint64_t strEnc = str.toBits();
    // Replaces up to n matches using the callback closure
    // closure : Match -> String
    // Returns String

    srell::regex* re = getCompiledRegex(regexEnc);
    if (!re) {
        // Return original string if no regex
        return str;
    }

    if (n == 0) {
        return str;
    }

    // Snapshot the input string into UTF-8 BEFORE rooting begins. After the
    // first GC point inside the loop, `strEnc` (the original heap string)
    // may have been moved, but the std::string copy on the C stack is stable.
    std::string strUtf8 = elmStringToUTF8(strEnc);

    // Root the closure across every iteration: createMatch + eco_apply_closure
    // + utf8ToElmString (called transitively by elmStringToUTF8 on the result)
    // are all GC points.
    HPointer closureHP = Export::decode(closure.toBits());
    Elm::StackRootGuard closureRoot(&closureHP);

    std::string result;
    size_t lastEnd = 0;
    int64_t matchNum = 0;

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
            int64_t charIndex = byteOffsetToCharIndex(strUtf8, matchStart);

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
        // On error, return original string
        return str;
    }

    HPointer resultStr = utf8ToElmString(result);
    return HPtr::fromBits(Export::encode(resultStr));
}

HPtr Elm_Kernel_Regex_splitAtMost(int64_t n, HPtr regex, HPtr str) {
    uint64_t regexEnc = regex.toBits();
    uint64_t strEnc = str.toBits();
    // Splits the string at up to n regex matches
    // Returns List String

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

    // std::deque so per-element addresses stay valid across push_back —
    // see findAtMost above for the rationale.
    std::deque<HPointer> parts;
    auto& rs = Allocator::instance().getRootSet();
    size_t savedRange = rs.stackRangePoint();
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
            parts.push_back(utf8ToElmString(part));
            rs.pushStackRootRange(&parts.back(), 1, 1);

            lastEnd = matchStart + matchLen;
            ++splitCount;
        }

        // Add final part after last match
        std::string finalPart = strUtf8.substr(lastEnd);
        parts.push_back(utf8ToElmString(finalPart));
        rs.pushStackRootRange(&parts.back(), 1, 1);

    } catch (...) {
        rs.restoreStackRangePoint(savedRange);
        // On error, return list with just original string
        HPointer elmStr = Export::decode(strEnc);
        return HPtr::fromBits(Export::encode(cons(boxed(elmStr), listNil(), true)));
    }

    std::vector<HPointer> partsVec(parts.begin(), parts.end());
    HPointer result = listFromPointers(partsVec);
    rs.restoreStackRangePoint(savedRange);
    return HPtr::fromBits(Export::encode(result));
}

} // extern "C"
