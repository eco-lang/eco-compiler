//===- DomExports.cpp - C exports of Eco.Kernel.Dom ------------------------===//
//
// plans/elm-html-native-kernel.md §4.2 and plans/eco-system-library.md B1b. The
// VirtualDom side door: natively a VirtualDom.Node msg already has the heap
// layout of Http.Dom.Node (VirtualDomLayout.hpp, VDOM_001), so fromNode and
// fromAttribute are identities. toString runs ElmKernel_VirtualDom's
// writeHtml, which never allocates on the Eco heap (VDOM_004), then allocates
// the one result String. Pure kernels (B5): no binding, no table.
//
//===----------------------------------------------------------------------===//

#include "eco-system/Core/Core.hpp"
#include "virtual-dom/HtmlWriter.hpp"

#include <string>

using namespace Eco::System;

extern "C" {

// fromNode : VirtualDom.Node msg -> Http.Dom.Node
uint64_t Eco_Kernel_Dom_fromNode(uint64_t node) {
    ECO_KERNEL_GUARD(
        return node;   // R7: zero-copy (D3)
    )
}

// fromAttribute : VirtualDom.Attribute msg -> Http.Dom.Fact
uint64_t Eco_Kernel_Dom_fromAttribute(uint64_t fact) {
    ECO_KERNEL_GUARD(
        return fact;
    )
}

// toString : VirtualDom.Node msg -> String
uint64_t Eco_Kernel_Dom_toString(uint64_t node) {
    ECO_KERNEL_GUARD(
        std::string out;
        ::Elm::Kernel::VirtualDom::writeHtml(node, out);   // R8: no Eco allocation
        return enc(alloc::allocStringFromUTF8(out));       // the one allocation, after the walk
    )
}

} // extern "C"
