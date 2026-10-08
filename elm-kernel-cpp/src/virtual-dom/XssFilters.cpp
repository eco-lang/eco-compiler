//===- XssFilters.cpp - elm/virtual-dom 1.0.5 XSS filters (PROD arms) -------===//
//
// plans/elm-html-native-kernel.md §6. See XssFilters.hpp.
//
//===----------------------------------------------------------------------===//

#include "XssFilters.hpp"

namespace Elm::Kernel::Xss {

namespace {

char16_t asciiLower(char16_t c) {
    return (c >= u'A' && c <= u'Z') ? static_cast<char16_t>(c + 32) : c;
}

bool isAsciiLetter(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

// `s` equals the ASCII `word`, ASCII-case-insensitively.
bool equalsIgnoreCase(const std::u16string& s, const char* word) {
    size_t i = 0;
    for (; word[i] != '\0'; ++i) {
        if (i >= s.size()) return false;
        if (asciiLower(s[i]) != static_cast<char16_t>(asciiLower(static_cast<char16_t>(word[i]))))
            return false;
    }
    return i == s.size();
}

} // namespace

bool isJsSpace(char16_t c) {
    return (c >= 0x0009 && c <= 0x000D) || c == 0x0020 || c == 0x00A0 || c == 0x1680 ||
           (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F ||
           c == 0x205F || c == 0x3000 || c == 0xFEFF;
}

size_t looseMatch(const std::u16string& s, size_t i, const char* pattern) {
    for (const char* p = pattern; *p != '\0'; ++p) {
        while (i < s.size() && isJsSpace(s[i])) ++i;
        if (i >= s.size()) return std::u16string::npos;
        char16_t want = static_cast<char16_t>(static_cast<unsigned char>(*p));
        char16_t got = s[i];
        if (isAsciiLetter(*p)) {
            if (asciiLower(got) != asciiLower(want)) return std::u16string::npos;
        } else if (got != want) {
            return std::u16string::npos;
        }
        ++i;
    }
    return i;
}

bool isScriptTag(const std::u16string& s) {
    return equalsIgnoreCase(s, "script");
}

bool isOnOrFormAction(const std::u16string& s) {
    if (s.size() >= 2 && asciiLower(s[0]) == u'o' && asciiLower(s[1]) == u'n') return true;
    return equalsIgnoreCase(s, "formaction");
}

bool isInnerHtmlOrFormAction(const std::u16string& s) {
    return s == u"innerHTML" || s == u"outerHTML" || s == u"formAction";
}

bool isJavaScriptUri(const std::u16string& s) {
    return looseMatch(s, 0, "javascript:") != std::u16string::npos;
}

bool isJavaScriptOrHtmlUri(const std::u16string& s) {
    if (isJavaScriptUri(s)) return true;
    size_t e = looseMatch(s, 0, "data:text/html");
    if (e == std::u16string::npos) return false;
    while (e < s.size() && isJsSpace(s[e])) ++e;
    return e < s.size() && (s[e] == u',' || s[e] == u';');
}

} // namespace Elm::Kernel::Xss
