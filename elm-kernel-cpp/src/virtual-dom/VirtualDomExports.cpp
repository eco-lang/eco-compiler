//===- VirtualDomExports.cpp - C-linkage exports for VirtualDom module -----===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "VirtualDom.hpp"
#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include <cassert>
#include <string>
#include <cstring>

using namespace Elm;
using namespace Elm::Kernel;

namespace {

// Convert ElmString to std::string (UTF-16 to UTF-8)
std::string elmStringToStd(void* ptr) {
    if (!ptr) return "";
    ElmString* s = static_cast<ElmString*>(ptr);
    std::string result;
    result.reserve(s->header.size);
    for (u32 i = 0; i < s->header.size; i++) {
        u16 c = s->chars[i];
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

} // anonymous namespace

extern "C" {

HPtr Elm_Kernel_VirtualDom_text(HPtr str) {
    auto vnode = VirtualDom::text(Export::toPtr(str.toBits()));
    return HPtr::fromBits(Export::encode(VirtualDom::wrapVNode(vnode)));
}

HPtr Elm_Kernel_VirtualDom_node(HPtr tag, HPtr factList, HPtr kidList) {
    auto vnode = VirtualDom::node(
        Export::toPtr(tag.toBits()),
        Export::decode(factList.toBits()),
        Export::decode(kidList.toBits())
    );
    return HPtr::fromBits(Export::encode(VirtualDom::wrapVNode(vnode)));
}

HPtr Elm_Kernel_VirtualDom_nodeNS(HPtr ns, HPtr tag, HPtr factList, HPtr kidList) {
    auto vnode = VirtualDom::nodeNS(
        Export::toPtr(ns.toBits()),
        Export::toPtr(tag.toBits()),
        Export::decode(factList.toBits()),
        Export::decode(kidList.toBits())
    );
    return HPtr::fromBits(Export::encode(VirtualDom::wrapVNode(vnode)));
}

HPtr Elm_Kernel_VirtualDom_keyedNode(HPtr tag, HPtr factList, HPtr keyedKidList) {
    auto vnode = VirtualDom::keyedNode(
        Export::toPtr(tag.toBits()),
        Export::decode(factList.toBits()),
        Export::decode(keyedKidList.toBits())
    );
    return HPtr::fromBits(Export::encode(VirtualDom::wrapVNode(vnode)));
}

HPtr Elm_Kernel_VirtualDom_keyedNodeNS(HPtr ns, HPtr tag, HPtr factList, HPtr keyedKidList) {
    auto vnode = VirtualDom::keyedNodeNS(
        Export::toPtr(ns.toBits()),
        Export::toPtr(tag.toBits()),
        Export::decode(factList.toBits()),
        Export::decode(keyedKidList.toBits())
    );
    return HPtr::fromBits(Export::encode(VirtualDom::wrapVNode(vnode)));
}

HPtr Elm_Kernel_VirtualDom_attribute(HPtr key, HPtr value) {
    auto fact = VirtualDom::attribute(Export::toPtr(key.toBits()), Export::toPtr(value.toBits()));
    // For now, wrap the fact as a Custom type - full implementation needed
    // This is a stub that returns Nothing
    return HPtr::fromBits(Export::encode(Elm::alloc::nothing()));
}

HPtr Elm_Kernel_VirtualDom_attributeNS(HPtr ns, HPtr key, HPtr value) {
    auto fact = VirtualDom::attributeNS(Export::toPtr(ns.toBits()), Export::toPtr(key.toBits()), Export::toPtr(value.toBits()));
    return HPtr::fromBits(Export::encode(Elm::alloc::nothing()));
}

HPtr Elm_Kernel_VirtualDom_property(HPtr key, HPtr value) {
    auto fact = VirtualDom::property(Export::toPtr(key.toBits()), Export::decode(value.toBits()));
    return HPtr::fromBits(Export::encode(Elm::alloc::nothing()));
}

HPtr Elm_Kernel_VirtualDom_style(HPtr key, HPtr value) {
    auto fact = VirtualDom::style(Export::toPtr(key.toBits()), Export::toPtr(value.toBits()));
    return HPtr::fromBits(Export::encode(Elm::alloc::nothing()));
}

HPtr Elm_Kernel_VirtualDom_on(HPtr event, HPtr decoder) {
    (void)event;
    (void)decoder;
    assert(false && "Elm_Kernel_VirtualDom_on not implemented - requires event system");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_VirtualDom_map(HPtr closure, HPtr vnode) {
    (void)closure;
    (void)vnode;
    assert(false && "Elm_Kernel_VirtualDom_map not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_VirtualDom_mapAttribute(HPtr closure, HPtr fact) {
    (void)closure;
    (void)fact;
    assert(false && "Elm_Kernel_VirtualDom_mapAttribute not implemented");
    return HPtr::fromBits(0);
}

//===----------------------------------------------------------------------===//
// Lazy nodes (stubs)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_VirtualDom_lazy(HPtr closure, HPtr arg) {
    (void)closure;
    (void)arg;
    assert(false && "Elm_Kernel_VirtualDom_lazy not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_VirtualDom_lazy2(HPtr closure, HPtr a, HPtr b) {
    (void)closure; (void)a; (void)b;
    assert(false && "Elm_Kernel_VirtualDom_lazy2 not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_VirtualDom_lazy3(HPtr closure, HPtr a, HPtr b, HPtr c_arg) {
    (void)closure; (void)a; (void)b; (void)c_arg;
    assert(false && "Elm_Kernel_VirtualDom_lazy3 not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_VirtualDom_lazy4(HPtr closure, HPtr a, HPtr b, HPtr c_arg, HPtr d) {
    (void)closure; (void)a; (void)b; (void)c_arg; (void)d;
    assert(false && "Elm_Kernel_VirtualDom_lazy4 not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_VirtualDom_lazy5(HPtr closure, HPtr a, HPtr b, HPtr c_arg, HPtr d, HPtr e) {
    (void)closure; (void)a; (void)b; (void)c_arg; (void)d; (void)e;
    assert(false && "Elm_Kernel_VirtualDom_lazy5 not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_VirtualDom_lazy6(HPtr closure, HPtr a, HPtr b, HPtr c_arg, HPtr d, HPtr e, HPtr f) {
    (void)closure; (void)a; (void)b; (void)c_arg; (void)d; (void)e; (void)f;
    assert(false && "Elm_Kernel_VirtualDom_lazy6 not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_VirtualDom_lazy7(HPtr closure, HPtr a, HPtr b, HPtr c_arg, HPtr d, HPtr e, HPtr f, HPtr g) {
    (void)closure; (void)a; (void)b; (void)c_arg; (void)d; (void)e; (void)f; (void)g;
    assert(false && "Elm_Kernel_VirtualDom_lazy7 not implemented");
    return HPtr::fromBits(0);
}

HPtr Elm_Kernel_VirtualDom_lazy8(HPtr closure, HPtr a, HPtr b, HPtr c_arg, HPtr d, HPtr e, HPtr f, HPtr g, HPtr h) {
    (void)closure; (void)a; (void)b; (void)c_arg; (void)d; (void)e; (void)f; (void)g; (void)h;
    assert(false && "Elm_Kernel_VirtualDom_lazy8 not implemented");
    return HPtr::fromBits(0);
}

//===----------------------------------------------------------------------===//
// Security/XSS protection
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_VirtualDom_noScript(HPtr tag) {
    // Prevent <script> tags.
    std::string tagStr = elmStringToStd(Export::toPtr(tag.toBits()));

    if (tagStr == "script" || tagStr == "SCRIPT") {
        // Replace with a <p> tag.
        HPointer safe = alloc::allocStringFromUTF8("p");
        return HPtr::fromBits(Export::encode(safe));
    }
    return tag;
}

HPtr Elm_Kernel_VirtualDom_noOnOrFormAction(HPtr key) {
    // Prevent on* attributes and formaction.
    std::string keyStr = elmStringToStd(Export::toPtr(key.toBits()));

    if (keyStr.length() >= 2 && keyStr[0] == 'o' && keyStr[1] == 'n') {
        return HPtr::fromBits(Export::encode(alloc::nothing()));
    }
    if (keyStr == "formaction" || keyStr == "formAction") {
        return HPtr::fromBits(Export::encode(alloc::nothing()));
    }

    return HPtr::fromBits(Export::encode(alloc::just(alloc::boxed(Export::decode(key.toBits())), true)));
}

HPtr Elm_Kernel_VirtualDom_noInnerHtmlOrFormAction(HPtr key) {
    // Prevent innerHTML and formaction.
    std::string keyStr = elmStringToStd(Export::toPtr(key.toBits()));

    if (keyStr == "innerHTML" || keyStr == "formaction" || keyStr == "formAction") {
        return HPtr::fromBits(Export::encode(alloc::nothing()));
    }

    return HPtr::fromBits(Export::encode(alloc::just(alloc::boxed(Export::decode(key.toBits())), true)));
}

HPtr Elm_Kernel_VirtualDom_noJavaScriptOrHtmlUri(HPtr value) {
    // Prevent javascript: and data:text/html URIs.
    std::string valStr = elmStringToStd(Export::toPtr(value.toBits()));

    if (valStr.length() >= 11 && valStr.substr(0, 11) == "javascript:") {
        return HPtr::fromBits(Export::encode(alloc::nothing()));
    }
    if (valStr.length() >= 14 && valStr.substr(0, 14) == "data:text/html") {
        return HPtr::fromBits(Export::encode(alloc::nothing()));
    }

    return HPtr::fromBits(Export::encode(alloc::just(alloc::boxed(Export::decode(value.toBits())), true)));
}

HPtr Elm_Kernel_VirtualDom_noJavaScriptOrHtmlJson(HPtr value) {
    // Similar to noJavaScriptOrHtmlUri but for JSON values.
    return HPtr::fromBits(Export::encode(alloc::just(alloc::boxed(Export::decode(value.toBits())), true)));
}

} // extern "C"
