//===- VirtualDomExports.cpp - C-linkage exports for VirtualDom module -----===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "VirtualDom.hpp"

using namespace Elm;
using namespace Elm::Kernel;

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

} // extern "C"
