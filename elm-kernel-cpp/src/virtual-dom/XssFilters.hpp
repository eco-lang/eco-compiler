//===- XssFilters.hpp - elm/virtual-dom 1.0.5 XSS filters -------------------===//
//
// The native HTML writer must sanitise tag names, attribute keys and URI values
// exactly as elm/virtual-dom 1.0.5's JavaScript runtime does (invariant VDOM_003).
// These are pure predicates on UTF-16 text that return what that runtime's
// checks return. Four of them mirror its regexes:
//
//   _VirtualDom_RE_script       /^script$/i
//   _VirtualDom_RE_on_formAction /^(on|formAction$)/i
//   _VirtualDom_RE_js           /^\s*j\s*a\s*v\s*a\s*s\s*c\s*r\s*i\s*p\s*t\s*:/i
//   _VirtualDom_RE_js_html      /^\s*(j\s*a…t\s*:|d\s*a\s*t\s*a\s*:\s*t\s*e\s*x\s*t\s*\/\s*h\s*t\s*m\s*l\s*(,|;))/i
//
// The fifth, isInnerHtmlOrFormAction, is an exact, case-sensitive string
// comparison rather than a regex.
//
// `\s` is ECMAScript WhiteSpace ∪ LineTerminator (isJsSpace). `/i` without the
// `u` flag folds only ASCII letters for these patterns: a non-ASCII character
// never matches an ASCII one. Nothing here touches the Eco heap.
//
//===----------------------------------------------------------------------===//

#ifndef ECO_XSSFILTERS_H
#define ECO_XSSFILTERS_H

#include <string>

namespace Elm::Kernel::Xss {

/// Tests whether `c` is a JavaScript `\s` character: U+0009 to U+000D, U+0020,
/// U+00A0, U+1680, U+2000 to U+200A, U+2028, U+2029, U+202F, U+205F, U+3000 or
/// U+FEFF.
bool isJsSpace(char16_t c);

/// Returns the index just past a loose match of `pattern` starting at `s[i]`, or
/// std::u16string::npos if there is none. Before each pattern character any run
/// of isJsSpace characters is skipped; letters match ASCII-case-insensitively and
/// every other character must be equal. Spaces after the last pattern character
/// are not consumed. `pattern` is a NUL-terminated ASCII string.
size_t looseMatch(const std::u16string& s, size_t i, const char* pattern);

/// Tests whether `s` is `script` in any ASCII case (/^script$/i).
bool isScriptTag(const std::u16string& s);

/// Tests whether `s` starts with `on`, or is `formaction`, in any ASCII case
/// (/^(on|formAction$)/i).
bool isOnOrFormAction(const std::u16string& s);

/// Tests whether `s` is exactly `innerHTML`, `outerHTML` or `formAction`; case
/// matters.
bool isInnerHtmlOrFormAction(const std::u16string& s);

/// Tests whether `s` starts with `javascript:`, allowing JavaScript spaces before
/// each character and any ASCII case (_VirtualDom_RE_js).
bool isJavaScriptUri(const std::u16string& s);

/// Tests whether `s` is a JavaScript URI as isJavaScriptUri decides, or starts
/// with `data:text/html` followed by `,` or `;`, with the same space and case
/// rules (_VirtualDom_RE_js_html).
bool isJavaScriptOrHtmlUri(const std::u16string& s);

} // namespace Elm::Kernel::Xss

#endif // ECO_XSSFILTERS_H
