/**
 * Elm Kernel Regex Module - Runtime Heap Integration
 *
 * Provides regular expression operations using GC-managed heap values.
 * Note: This is a stub implementation - full regex support requires PCRE2.
 */

#include "Regex.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/StringOps.hpp"
#include "allocator/ListOps.hpp"

namespace Elm::Kernel::Regex {

RegexPtr never() {
    // Return a regex that never matches
    auto r = std::make_shared<Regex>();
    r->patternStr = {'.', '^'};  // Pattern that never matches
    r->caseInsensitive = false;
    r->multiline = false;
    try {
        r->pattern = srell::u16regex(u".^");
    } catch (...) {
        // If pattern fails, leave default
    }
    return r;
}

HPointer fromStringWith(void* pattern, bool caseInsensitive, bool multiline) {
    // Snapshot pattern via tag-aware StringOps so a slice input works.
    auto patternU16 = StringOps::toStdU16String(pattern);

    try {
        auto regex = std::make_shared<Regex>();
        regex->caseInsensitive = caseInsensitive;
        regex->multiline = multiline;
        regex->patternStr.assign(patternU16.begin(), patternU16.end());

        auto flags = srell::regex_constants::ECMAScript;
        if (caseInsensitive) {
            flags |= srell::regex_constants::icase;
        }
        if (multiline) {
            flags |= srell::regex_constants::multiline;
        }

        std::basic_string<char16_t> patternBuf(patternU16.begin(), patternU16.end());
        regex->pattern = srell::u16regex(patternBuf.data(), patternBuf.size(), flags);

        // TODO: Need proper way to store RegexPtr in heap
        // For now return Nothing
        return alloc::nothing();
    }
    catch (...) {
        return alloc::nothing();
    }
}

bool contains(RegexPtr regex, void* str) {
    if (!regex) return false;

    auto buf = StringOps::toStdU16String(str);
    std::basic_string<char16_t> strU16(buf.begin(), buf.end());

    try {
        return srell::regex_search(strU16.begin(), strU16.end(), regex->pattern);
    }
    catch (...) {
        return false;
    }
}

HPointer findAtMost(i64 n, RegexPtr regex, void* str) {
    // Return empty list - stub implementation
    (void)n;
    (void)regex;
    (void)str;
    return alloc::listNil();
}

HPointer replaceAtMost(i64 n, RegexPtr regex, ReplacerFn replacer, void* str) {
    // Return original string - stub implementation
    (void)n;
    (void)regex;
    (void)replacer;
    return Allocator::instance().wrap(str);
}

HPointer splitAtMost(i64 n, RegexPtr regex, void* str) {
    // Return list with single element (original string) - stub implementation
    (void)n;
    (void)regex;
    HPointer strPtr = Allocator::instance().wrap(str);
    return alloc::cons(alloc::boxed(strPtr), alloc::listNil(), true);
}

} // namespace Elm::Kernel::Regex
