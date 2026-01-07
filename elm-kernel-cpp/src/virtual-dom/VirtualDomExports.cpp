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

uint64_t Elm_Kernel_VirtualDom_text(uint64_t str) {
    auto vnode = VirtualDom::text(Export::toPtr(str));
    return Export::encode(VirtualDom::wrapVNode(vnode));
}

uint64_t Elm_Kernel_VirtualDom_node(uint64_t tag, uint64_t factList, uint64_t kidList) {
    auto vnode = VirtualDom::node(
        Export::toPtr(tag),
        Export::decode(factList),
        Export::decode(kidList)
    );
    return Export::encode(VirtualDom::wrapVNode(vnode));
}

uint64_t Elm_Kernel_VirtualDom_nodeNS(uint64_t ns, uint64_t tag, uint64_t factList, uint64_t kidList) {
    auto vnode = VirtualDom::nodeNS(
        Export::toPtr(ns),
        Export::toPtr(tag),
        Export::decode(factList),
        Export::decode(kidList)
    );
    return Export::encode(VirtualDom::wrapVNode(vnode));
}

uint64_t Elm_Kernel_VirtualDom_keyedNode(uint64_t tag, uint64_t factList, uint64_t keyedKidList) {
    auto vnode = VirtualDom::keyedNode(
        Export::toPtr(tag),
        Export::decode(factList),
        Export::decode(keyedKidList)
    );
    return Export::encode(VirtualDom::wrapVNode(vnode));
}

uint64_t Elm_Kernel_VirtualDom_keyedNodeNS(uint64_t ns, uint64_t tag, uint64_t factList, uint64_t keyedKidList) {
    auto vnode = VirtualDom::keyedNodeNS(
        Export::toPtr(ns),
        Export::toPtr(tag),
        Export::decode(factList),
        Export::decode(keyedKidList)
    );
    return Export::encode(VirtualDom::wrapVNode(vnode));
}

uint64_t Elm_Kernel_VirtualDom_attribute(uint64_t key, uint64_t value) {
    auto fact = VirtualDom::attribute(Export::toPtr(key), Export::toPtr(value));
    // For now, wrap the fact as a Custom type - full implementation needed
    // This is a stub that returns Nothing
    return Export::encode(Elm::alloc::nothing());
}

uint64_t Elm_Kernel_VirtualDom_attributeNS(uint64_t ns, uint64_t key, uint64_t value) {
    auto fact = VirtualDom::attributeNS(Export::toPtr(ns), Export::toPtr(key), Export::toPtr(value));
    return Export::encode(Elm::alloc::nothing());
}

uint64_t Elm_Kernel_VirtualDom_property(uint64_t key, uint64_t value) {
    auto fact = VirtualDom::property(Export::toPtr(key), Export::decode(value));
    return Export::encode(Elm::alloc::nothing());
}

uint64_t Elm_Kernel_VirtualDom_style(uint64_t key, uint64_t value) {
    auto fact = VirtualDom::style(Export::toPtr(key), Export::toPtr(value));
    return Export::encode(Elm::alloc::nothing());
}

uint64_t Elm_Kernel_VirtualDom_on(uint64_t event, uint64_t decoder) {
    (void)event;
    (void)decoder;
    assert(false && "Elm_Kernel_VirtualDom_on not implemented - requires event system");
    return 0;
}

uint64_t Elm_Kernel_VirtualDom_map(uint64_t closure, uint64_t vnode) {
    (void)closure;
    (void)vnode;
    assert(false && "Elm_Kernel_VirtualDom_map not implemented");
    return 0;
}

uint64_t Elm_Kernel_VirtualDom_mapAttribute(uint64_t closure, uint64_t fact) {
    (void)closure;
    (void)fact;
    assert(false && "Elm_Kernel_VirtualDom_mapAttribute not implemented");
    return 0;
}

//===----------------------------------------------------------------------===//
// Lazy nodes (stubs)
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_VirtualDom_lazy(uint64_t closure, uint64_t arg) {
    (void)closure;
    (void)arg;
    assert(false && "Elm_Kernel_VirtualDom_lazy not implemented");
    return 0;
}

uint64_t Elm_Kernel_VirtualDom_lazy2(uint64_t closure, uint64_t a, uint64_t b) {
    (void)closure; (void)a; (void)b;
    assert(false && "Elm_Kernel_VirtualDom_lazy2 not implemented");
    return 0;
}

uint64_t Elm_Kernel_VirtualDom_lazy3(uint64_t closure, uint64_t a, uint64_t b, uint64_t c_arg) {
    (void)closure; (void)a; (void)b; (void)c_arg;
    assert(false && "Elm_Kernel_VirtualDom_lazy3 not implemented");
    return 0;
}

uint64_t Elm_Kernel_VirtualDom_lazy4(uint64_t closure, uint64_t a, uint64_t b, uint64_t c_arg, uint64_t d) {
    (void)closure; (void)a; (void)b; (void)c_arg; (void)d;
    assert(false && "Elm_Kernel_VirtualDom_lazy4 not implemented");
    return 0;
}

uint64_t Elm_Kernel_VirtualDom_lazy5(uint64_t closure, uint64_t a, uint64_t b, uint64_t c_arg, uint64_t d, uint64_t e) {
    (void)closure; (void)a; (void)b; (void)c_arg; (void)d; (void)e;
    assert(false && "Elm_Kernel_VirtualDom_lazy5 not implemented");
    return 0;
}

uint64_t Elm_Kernel_VirtualDom_lazy6(uint64_t closure, uint64_t a, uint64_t b, uint64_t c_arg, uint64_t d, uint64_t e, uint64_t f) {
    (void)closure; (void)a; (void)b; (void)c_arg; (void)d; (void)e; (void)f;
    assert(false && "Elm_Kernel_VirtualDom_lazy6 not implemented");
    return 0;
}

uint64_t Elm_Kernel_VirtualDom_lazy7(uint64_t closure, uint64_t a, uint64_t b, uint64_t c_arg, uint64_t d, uint64_t e, uint64_t f, uint64_t g) {
    (void)closure; (void)a; (void)b; (void)c_arg; (void)d; (void)e; (void)f; (void)g;
    assert(false && "Elm_Kernel_VirtualDom_lazy7 not implemented");
    return 0;
}

uint64_t Elm_Kernel_VirtualDom_lazy8(uint64_t closure, uint64_t a, uint64_t b, uint64_t c_arg, uint64_t d, uint64_t e, uint64_t f, uint64_t g, uint64_t h) {
    (void)closure; (void)a; (void)b; (void)c_arg; (void)d; (void)e; (void)f; (void)g; (void)h;
    assert(false && "Elm_Kernel_VirtualDom_lazy8 not implemented");
    return 0;
}

//===----------------------------------------------------------------------===//
// Security/XSS protection
//===----------------------------------------------------------------------===//

uint64_t Elm_Kernel_VirtualDom_noScript(uint64_t tag) {
    // Prevent <script> tags.
    std::string tagStr = elmStringToStd(Export::toPtr(tag));

    if (tagStr == "script" || tagStr == "SCRIPT") {
        // Replace with a <p> tag.
        HPointer safe = alloc::allocStringFromUTF8("p");
        return Export::encode(safe);
    }
    return tag;
}

uint64_t Elm_Kernel_VirtualDom_noOnOrFormAction(uint64_t key) {
    // Prevent on* attributes and formaction.
    std::string keyStr = elmStringToStd(Export::toPtr(key));

    if (keyStr.length() >= 2 && keyStr[0] == 'o' && keyStr[1] == 'n') {
        return Export::encode(alloc::nothing());
    }
    if (keyStr == "formaction" || keyStr == "formAction") {
        return Export::encode(alloc::nothing());
    }

    return Export::encode(alloc::just(alloc::boxed(Export::decode(key)), true));
}

uint64_t Elm_Kernel_VirtualDom_noInnerHtmlOrFormAction(uint64_t key) {
    // Prevent innerHTML and formaction.
    std::string keyStr = elmStringToStd(Export::toPtr(key));

    if (keyStr == "innerHTML" || keyStr == "formaction" || keyStr == "formAction") {
        return Export::encode(alloc::nothing());
    }

    return Export::encode(alloc::just(alloc::boxed(Export::decode(key)), true));
}

uint64_t Elm_Kernel_VirtualDom_noJavaScriptOrHtmlUri(uint64_t value) {
    // Prevent javascript: and data:text/html URIs.
    std::string valStr = elmStringToStd(Export::toPtr(value));

    if (valStr.length() >= 11 && valStr.substr(0, 11) == "javascript:") {
        return Export::encode(alloc::nothing());
    }
    if (valStr.length() >= 14 && valStr.substr(0, 14) == "data:text/html") {
        return Export::encode(alloc::nothing());
    }

    return Export::encode(alloc::just(alloc::boxed(Export::decode(value)), true));
}

uint64_t Elm_Kernel_VirtualDom_noJavaScriptOrHtmlJson(uint64_t value) {
    // Similar to noJavaScriptOrHtmlUri but for JSON values.
    return Export::encode(alloc::just(alloc::boxed(Export::decode(value)), true));
}

} // extern "C"
