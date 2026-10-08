//===- XssFilters.hpp - elm/virtual-dom 1.0.5 XSS filters (PROD arms) -------===//
//
// plans/elm-html-native-kernel.md §6 and VDOM_003. Pure predicates on UTF-16
// text that return exactly what elm/virtual-dom 1.0.5's JavaScript regexes
// return:
//
//   _VirtualDom_RE_script       /^script$/i
//   _VirtualDom_RE_on_formAction /^(on|formAction$)/i
//   _VirtualDom_RE_js           /^\s*j\s*a\s*v\s*a\s*s\s*c\s*r\s*i\s*p\s*t\s*:/i
//   _VirtualDom_RE_js_html      /^\s*(j\s*a…t\s*:|d\s*a\s*t\s*a\s*:\s*t\s*e\s*x\s*t\s*\/\s*h\s*t\s*m\s*l\s*(,|;))/i
//
// `\s` is ECMAScript WhiteSpace ∪ LineTerminator, and `/i` without `u` folds
// only ASCII letters here (a non-ASCII character never matches an ASCII one).
// No Eco heap access.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_XSSFILTERS_H
#define ECO_XSSFILTERS_H

#include <string>

namespace Elm::Kernel::Xss {

bool isJsSpace(char16_t c);

// The end index of a loose match of `pattern` (ASCII) at `s[i]`: before each
// pattern character any run of isJsSpace characters is skipped, letters match
// ASCII-case-insensitively, punctuation exactly. std::u16string::npos if none.
size_t looseMatch(const std::u16string& s, size_t i, const char* pattern);

bool isScriptTag(const std::u16string& s);
bool isOnOrFormAction(const std::u16string& s);
bool isInnerHtmlOrFormAction(const std::u16string& s);
bool isJavaScriptUri(const std::u16string& s);
bool isJavaScriptOrHtmlUri(const std::u16string& s);

} // namespace Elm::Kernel::Xss

#endif // ECO_XSSFILTERS_H
