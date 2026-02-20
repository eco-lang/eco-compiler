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
#include "../../vendor/srell.hpp"

// Declare closure call
extern "C" uint64_t eco_apply_closure(uint64_t closure, uint64_t* args, uint32_t num_args);
#include <cmath>
#include <string>
#include <vector>

using namespace Elm;
using namespace Elm::Kernel;
using namespace Elm::alloc;

namespace {

// Custom type ctor for storing compiled regex
// We store: srell::regex* pointer, caseInsensitive flag, multiline flag
static constexpr u16 CTOR_REGEX = 0xFF00;

// Helper: Convert Elm UTF-16 string to std::string (UTF-8) for SRELL
std::string elmStringToUTF8(uint64_t strEnc) {
    HPointer hp = Export::decode(strEnc);

    // Check for empty string constant
    if (hp.constant == Const_EmptyString + 1) {
        return "";
    }

    void* ptr = Export::toPtr(strEnc);
    if (!ptr) return "";

    ElmString* str = static_cast<ElmString*>(ptr);
    size_t len = str->header.size;
    if (len == 0) return "";

    // Convert UTF-16 to UTF-8
    std::string result;
    result.reserve(len * 3); // Conservative estimate

    for (size_t i = 0; i < len; ++i) {
        u16 c = str->chars[i];

        // Check for surrogate pair
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len) {
            u16 c2 = str->chars[i + 1];
            if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
                // Decode surrogate pair
                uint32_t cp = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
                result.push_back(static_cast<char>(0xF0 | (cp >> 18)));
                result.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
                result.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
                result.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
                ++i;
                continue;
            }
        }

        if (c < 0x80) {
            result.push_back(static_cast<char>(c));
        } else if (c < 0x800) {
            result.push_back(static_cast<char>(0xC0 | (c >> 6)));
            result.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        } else {
            result.push_back(static_cast<char>(0xE0 | (c >> 12)));
            result.push_back(static_cast<char>(0x80 | ((c >> 6) & 0x3F)));
            result.push_back(static_cast<char>(0x80 | (c & 0x3F)));
        }
    }

    return result;
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

    // values[0] stores the raw pointer to srell::regex
    return reinterpret_cast<srell::regex*>(c->values[0].i);
}

// Helper: Create a Match record
// Match = { match : String, index : Int, number : Int, submatches : List (Maybe String) }
// Fields in canonical order: index, match, number, submatches
HPointer createMatch(const std::string& matchStr, int64_t index, int64_t number,
                     const std::vector<std::pair<bool, std::string>>& submatches) {
    // Build submatches list (reversed for cons)
    HPointer submatchList = listNil();
    for (auto it = submatches.rbegin(); it != submatches.rend(); ++it) {
        HPointer submatchValue;
        if (it->first) {
            // Just string
            HPointer str = utf8ToElmString(it->second);
            submatchValue = just(boxed(str), true);
        } else {
            // Nothing
            submatchValue = nothing();
        }
        submatchList = cons(boxed(submatchValue), submatchList, true);
    }

    // Create record: fields in canonical order (index, match, number, submatches)
    HPointer matchStrHP = utf8ToElmString(matchStr);

    std::vector<Unboxable> fields(4);
    fields[0].i = index;                    // index (Int) - unboxed
    fields[1].p = matchStrHP;               // match (String) - boxed
    fields[2].i = number;                   // number (Int) - unboxed
    fields[3].p = submatchList;             // submatches (List) - boxed

    // Unboxed mask: bit 0 = index unboxed, bit 2 = number unboxed
    // Fields 1 and 3 are boxed (strings/lists)
    u64 unboxedMask = 0b0101;  // bits 0 and 2 are set

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

uint64_t Elm_Kernel_Regex_never() {
    // Return a regex that never matches anything.
    // Create a compiled regex for a pattern that can't match (negative lookahead of empty)
    try {
        srell::regex* re = new srell::regex("(?!)", srell::regex::ECMAScript);

        std::vector<Unboxable> values(3);
        values[0].i = reinterpret_cast<int64_t>(re);  // Store raw pointer
        values[1].i = 0;  // caseInsensitive = false
        values[2].i = 0;  // multiline = false

        // All fields are "unboxed" (raw values, not heap pointers)
        HPointer regex = custom(CTOR_REGEX, values, 0b111);
        return Export::encode(regex);
    } catch (...) {
        // If regex construction fails, return Nothing pattern
        // This shouldn't happen for the "never" pattern
        return Export::encode(nothing());
    }
}

double Elm_Kernel_Regex_infinity() {
    // Return positive infinity (used for "match all" in replaceAtMost, etc.).
    return std::numeric_limits<double>::infinity();
}

uint64_t Elm_Kernel_Regex_fromStringWith(uint64_t optionsEnc, uint64_t patternEnc) {
    // Options is a record: { caseInsensitive : Bool, multiline : Bool }
    // Fields in canonical order: caseInsensitive, multiline
    // Returns Maybe Regex

    void* optPtr = Export::toPtr(optionsEnc);
    if (!optPtr) {
        return Export::encode(nothing());
    }

    Record* opts = static_cast<Record*>(optPtr);
    // Both fields are boxed Bool (HPointer constants)
    bool caseInsensitive = Export::decodeBoxedBool(Export::encode(opts->values[0].p));
    bool multiline = Export::decodeBoxedBool(Export::encode(opts->values[1].p));

    std::string pattern = elmStringToUTF8(patternEnc);

    try {
        srell::regex_constants::syntax_option_type flags = srell::regex::ECMAScript;
        if (caseInsensitive) {
            flags |= srell::regex::icase;
        }
        if (multiline) {
            flags |= srell::regex::multiline;
        }

        srell::regex* re = new srell::regex(pattern, flags);

        std::vector<Unboxable> values(3);
        values[0].i = reinterpret_cast<int64_t>(re);
        values[1].i = caseInsensitive ? 1 : 0;
        values[2].i = multiline ? 1 : 0;

        HPointer regex = custom(CTOR_REGEX, values, 0b111);
        HPointer result = just(boxed(regex), true);
        return Export::encode(result);
    } catch (const srell::regex_error&) {
        // Invalid regex pattern
        return Export::encode(nothing());
    } catch (...) {
        return Export::encode(nothing());
    }
}

uint64_t Elm_Kernel_Regex_contains(uint64_t regexEnc, uint64_t strEnc) {
    // Returns Bool (boxed as True/False HPointer constant)
    srell::regex* re = getCompiledRegex(regexEnc);
    if (!re) {
        return Export::encodeBoxedBool(false);
    }

    std::string str = elmStringToUTF8(strEnc);

    try {
        bool result = srell::regex_search(str, *re);
        return Export::encodeBoxedBool(result);
    } catch (...) {
        return Export::encodeBoxedBool(false);
    }
}

uint64_t Elm_Kernel_Regex_findAtMost(int64_t n, uint64_t regexEnc, uint64_t strEnc) {
    // Returns List Match
    // n is the maximum number of matches to find (negative = unlimited)

    if (n == 0) {
        return Export::encode(listNil());
    }

    srell::regex* re = getCompiledRegex(regexEnc);
    if (!re) {
        return Export::encode(listNil());
    }

    std::string str = elmStringToUTF8(strEnc);

    std::vector<HPointer> matches;
    int64_t matchNum = 0;

    try {
        auto begin = srell::sregex_iterator(str.begin(), str.end(), *re);
        auto end = srell::sregex_iterator();

        for (auto it = begin; it != end; ++it) {
            if (n > 0 && matchNum >= n) break;

            const srell::smatch& match = *it;

            std::string matchStr = match.str();
            size_t byteOffset = static_cast<size_t>(match.position());
            int64_t charIndex = byteOffsetToCharIndex(str, byteOffset);

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
            ++matchNum;
        }
    } catch (...) {
        return Export::encode(listNil());
    }

    // Build list from matches (in order)
    return Export::encode(listFromPointers(matches));
}

uint64_t Elm_Kernel_Regex_replaceAtMost(int64_t n, uint64_t regexEnc,
                                         uint64_t closureEnc, uint64_t strEnc) {
    // Replaces up to n matches using the callback closure
    // closure : Match -> String
    // Returns String

    srell::regex* re = getCompiledRegex(regexEnc);
    if (!re) {
        // Return original string if no regex
        return strEnc;
    }

    if (n == 0) {
        return strEnc;
    }

    std::string str = elmStringToUTF8(strEnc);
    std::string result;
    size_t lastEnd = 0;
    int64_t matchNum = 0;

    try {
        auto begin = srell::sregex_iterator(str.begin(), str.end(), *re);
        auto end = srell::sregex_iterator();

        for (auto it = begin; it != end; ++it) {
            if (n > 0 && matchNum >= n) break;

            const srell::smatch& match = *it;
            size_t matchStart = static_cast<size_t>(match.position());
            size_t matchLen = match.length();

            // Append text before this match
            result.append(str.substr(lastEnd, matchStart - lastEnd));

            // Build Match record for callback
            std::string matchStr = match.str();
            int64_t charIndex = byteOffsetToCharIndex(str, matchStart);

            std::vector<std::pair<bool, std::string>> submatches;
            for (size_t i = 1; i < match.size(); ++i) {
                if (match[i].matched) {
                    submatches.push_back({true, match[i].str()});
                } else {
                    submatches.push_back({false, ""});
                }
            }

            HPointer matchRecord = createMatch(matchStr, charIndex, matchNum + 1, submatches);

            // Call the closure with the Match record
            uint64_t matchEnc = Export::encode(matchRecord);
            uint64_t replacementEnc = eco_apply_closure(closureEnc, &matchEnc, 1);

            // Get replacement string
            std::string replacement = elmStringToUTF8(replacementEnc);
            result.append(replacement);

            lastEnd = matchStart + matchLen;
            ++matchNum;
        }

        // Append remaining text after last match
        result.append(str.substr(lastEnd));

    } catch (...) {
        // On error, return original string
        return strEnc;
    }

    HPointer resultStr = utf8ToElmString(result);
    return Export::encode(resultStr);
}

uint64_t Elm_Kernel_Regex_splitAtMost(int64_t n, uint64_t regexEnc, uint64_t strEnc) {
    // Splits the string at up to n regex matches
    // Returns List String

    srell::regex* re = getCompiledRegex(regexEnc);
    if (!re) {
        // Return list containing just the original string
        HPointer str = Export::decode(strEnc);
        return Export::encode(cons(boxed(str), listNil(), true));
    }

    std::string str = elmStringToUTF8(strEnc);

    if (n == 0 || str.empty()) {
        HPointer elmStr = Export::decode(strEnc);
        return Export::encode(cons(boxed(elmStr), listNil(), true));
    }

    std::vector<HPointer> parts;
    size_t lastEnd = 0;
    int64_t splitCount = 0;

    try {
        auto begin = srell::sregex_iterator(str.begin(), str.end(), *re);
        auto end = srell::sregex_iterator();

        for (auto it = begin; it != end; ++it) {
            if (n > 0 && splitCount >= n) break;

            const srell::smatch& match = *it;
            size_t matchStart = static_cast<size_t>(match.position());
            size_t matchLen = match.length();

            // Add part before the match
            std::string part = str.substr(lastEnd, matchStart - lastEnd);
            parts.push_back(utf8ToElmString(part));

            lastEnd = matchStart + matchLen;
            ++splitCount;
        }

        // Add final part after last match
        std::string finalPart = str.substr(lastEnd);
        parts.push_back(utf8ToElmString(finalPart));

    } catch (...) {
        // On error, return list with just original string
        HPointer elmStr = Export::decode(strEnc);
        return Export::encode(cons(boxed(elmStr), listNil(), true));
    }

    return Export::encode(listFromPointers(parts));
}

} // extern "C"
