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
        r->pattern = std::basic_regex<char16_t>(u".^");
    } catch (...) {
        // If pattern fails, leave default
    }
    return r;
}

HPointer fromStringWith(void* pattern, bool caseInsensitive, bool multiline) {
    ElmString* s = static_cast<ElmString*>(pattern);

    try {
        auto regex = std::make_shared<Regex>();
        regex->caseInsensitive = caseInsensitive;
        regex->multiline = multiline;

        // Copy pattern string
        regex->patternStr.assign(s->chars, s->chars + s->header.size);

        // Build regex flags
        auto flags = std::regex_constants::ECMAScript;
        if (caseInsensitive) {
            flags |= std::regex_constants::icase;
        }
        if (multiline) {
            flags |= std::regex_constants::multiline;
        }

        // Compile the pattern
        std::basic_string<char16_t> patternU16(s->chars, s->chars + s->header.size);
        regex->pattern = std::basic_regex<char16_t>(patternU16, flags);

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

    ElmString* s = static_cast<ElmString*>(str);
    std::basic_string<char16_t> strU16(s->chars, s->chars + s->header.size);

    try {
        return std::regex_search(strU16, regex->pattern);
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
