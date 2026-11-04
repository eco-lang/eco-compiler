//===- DomExports.cpp - C exports of Eco.Kernel.Dom ------------------------===//
//
// The C exports behind the kernel module `Eco.Kernel.Dom`, which let Elm code treat `elm/html` and
// `elm/svg` values as the `Html.Dom` types it can inspect and render.
//
// The module rests on one fact about the heap: a native VirtualDom node or attribute is a `Custom` object
// whose constructor tags and field layout are exactly those of `Html.Dom.Node` and `Html.Dom.Fact`, as
// `VirtualDomLayout.hpp` defines them. Converting between the two is therefore no work at all, and
// `fromNode` and `fromAttribute` return their argument unchanged.
//
// The kernel `toString` (behind `Html.Dom.htmlToString`) renders a node to HTML with
// `Elm::Kernel::VirtualDom::writeHtml`. That writer does not allocate on the Eco heap or call Elm code,
// so no collection can move the tree while it is read. The result String is built only after the walk has finished.
//
// None of the exports keeps state between calls.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/Core.hpp"
#include "virtual-dom/HtmlWriter.hpp"

#include <string>

using namespace Eco::System;

extern "C" {

/// Returns `node`, a `VirtualDom.Node msg`, as an `Html.Dom.Node`. The word is returned unchanged, because
/// the two types share one heap layout.
uint64_t Eco_Kernel_Dom_fromNode(uint64_t node) {
    ECO_KERNEL_GUARD(
        return node;
    )
}

/// Returns `fact`, a `VirtualDom.Attribute msg`, as an `Html.Dom.Fact`. The word is returned unchanged, because
/// the two types share one heap layout.
uint64_t Eco_Kernel_Dom_fromAttribute(uint64_t fact) {
    ECO_KERNEL_GUARD(
        return fact;
    )
}

/// Returns the HTML text of `node`, a `VirtualDom.Node msg`, as a String. What is written, and what is
/// skipped, is as `Elm::Kernel::VirtualDom::writeHtml` describes.
uint64_t Eco_Kernel_Dom_toString(uint64_t node) {
    ECO_KERNEL_GUARD(
        std::string out;
        ::Elm::Kernel::VirtualDom::writeHtml(node, out);
        // Building the String is the first Eco heap allocation, so it must come after the walk.
        return enc(alloc::allocStringFromUTF8(out));
    )
}

} // extern "C"
