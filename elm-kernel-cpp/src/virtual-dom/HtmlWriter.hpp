//===- HtmlWriter.hpp - HTML serialization of native VirtualDom values ------===//
//
// plans/elm-html-native-kernel.md §8 and Appendix B.5. Self-contained: eco/system
// includes it (as "virtual-dom/HtmlWriter.hpp"), so it includes nothing from
// elm-kernel-cpp (§1.1 E3).
//
//===----------------------------------------------------------------------===//

#ifndef ECO_HTMLWRITER_H
#define ECO_HTMLWRITER_H

#include <cstdint>
#include <string>

namespace Elm::Kernel::VirtualDom {

// Appends the HTML serialization (plan §8) of a VirtualDom.Node / Http.Dom.Node value to `out` as
// UTF-8. `nodeBits` is an encoded word (heap pointer or raw literal pointer, R3). Never allocates
// on the Eco heap, never calls Elm (VDOM_004), never fails (D17). Callers: eco/system's
// Http.Dom.toString kernel (src/eco-system/Dom/DomExports.cpp) and httpServerRespondHtmlBody.
// (Do not spell out eco/system C symbols in elm-kernel-cpp, even in comments:
// check-kernel-homes.sh reads them as kernel homes.)
void writeHtml(uint64_t nodeBits, std::string& out);

} // namespace Elm::Kernel::VirtualDom

#endif // ECO_HTMLWRITER_H
