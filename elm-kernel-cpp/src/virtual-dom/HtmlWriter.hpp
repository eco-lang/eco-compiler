//===- HtmlWriter.hpp - HTML serialization of native VirtualDom values ------===//
//
// Turns a native VirtualDom node tree (an `Html msg` or `Svg msg` value, seen from
// Elm as `Html.Dom.Node`) into HTML text, in a form that can run where a garbage
// collection must not happen.
//
// The tree is a graph of ordinary heap objects whose layout
// `VirtualDomLayout.hpp` owns. Reading it needs no allocation, so a writer that
// never allocates on the Eco heap and never calls Elm code
// can hold raw pointers into it for the whole walk: no collection can run and
// move anything. That is the reason this writer exists alongside the Elm
// serializer `Html.Dom.toString`, whose output it must match byte for byte.
//
// The header includes only standard headers, because eco/system code outside
// elm-kernel-cpp includes it as "virtual-dom/HtmlWriter.hpp".
//
//===----------------------------------------------------------------------===//

#ifndef ECO_HTMLWRITER_H
#define ECO_HTMLWRITER_H

#include <cstdint>
#include <string>

namespace Elm::Kernel::VirtualDom {

// (Do not spell out eco/system C symbols in elm-kernel-cpp, even in comments:
// check-kernel-homes.sh reads them as kernel homes.)
/// Appends the HTML text of the node `nodeBits` to `out`, as UTF-8.
///
/// `nodeBits` is an encoded `eco.value` word for an `Html.Dom.Node`. A word that is not a heap
/// `Custom` object, or whose constructor tag is not a node's, contributes nothing, at the top or
/// as a child. The fields of a node or fact object must be well formed (lists where a list is
/// expected, strings where a string is); they are read unchecked. An element whose tag name is
/// empty or contains a character that would end an HTML token is not written, but its children
/// are. Event handlers are never written. The function itself neither asserts nor throws, apart
/// from `std::bad_alloc` from `out` and its C++ containers, and it walks the tree with an explicit
/// stack, so its C++ call depth does not grow with the tree.
///
/// It never allocates on the Eco heap and never calls Elm code, so nothing it reads moves while
/// it runs.
void writeHtml(uint64_t nodeBits, std::string& out);

} // namespace Elm::Kernel::VirtualDom

#endif // ECO_HTMLWRITER_H
