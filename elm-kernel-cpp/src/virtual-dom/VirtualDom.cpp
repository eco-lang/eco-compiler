#include "VirtualDom.hpp"
#include <stdexcept>

namespace Elm::Kernel::VirtualDom {

VNode* text(const std::u16string& str) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.text not implemented");
}

VNode* node(const std::u16string& tag, List* attrs, List* children) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.node not implemented");
}

VNode* nodeNS(const std::u16string& ns, const std::u16string& tag, List* attrs, List* children) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.nodeNS not implemented");
}

VNode* keyedNode(const std::u16string& tag, List* attrs, List* children) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.keyedNode not implemented");
}

VNode* keyedNodeNS(const std::u16string& ns, const std::u16string& tag, List* attrs, List* children) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.keyedNodeNS not implemented");
}

Attribute* attribute(const std::u16string& key, const std::u16string& value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.attribute not implemented");
}

Attribute* attributeNS(const std::u16string& ns, const std::u16string& key, const std::u16string& value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.attributeNS not implemented");
}

Attribute* property(const std::u16string& key, Value* value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.property not implemented");
}

Attribute* style(const std::u16string& key, const std::u16string& value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.style not implemented");
}

Attribute* on(const std::u16string& event, Decoder* decoder) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.on not implemented");
}

VNode* map(std::function<Value*(Value*)> func, VNode* vnode) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.map not implemented");
}

Attribute* mapAttribute(std::function<Value*(Value*)> func, Attribute* attr) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.mapAttribute not implemented");
}

VNode* lazy(std::function<VNode*(Value*)> func, Value* arg) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.lazy not implemented");
}

VNode* lazy2(std::function<VNode*(Value*, Value*)> func, Value* a, Value* b) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.lazy2 not implemented");
}

VNode* lazy3(std::function<VNode*(Value*, Value*, Value*)> func, Value* a, Value* b, Value* c) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.lazy3 not implemented");
}

VNode* lazy4(std::function<VNode*(Value*, Value*, Value*, Value*)> func, Value* a, Value* b, Value* c, Value* d) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.lazy4 not implemented");
}

VNode* lazy5(std::function<VNode*(Value*, Value*, Value*, Value*, Value*)> func, Value* a, Value* b, Value* c, Value* d, Value* e) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.lazy5 not implemented");
}

VNode* lazy6(std::function<VNode*(Value*, Value*, Value*, Value*, Value*, Value*)> func, Value* a, Value* b, Value* c, Value* d, Value* e, Value* f) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.lazy6 not implemented");
}

VNode* lazy7(std::function<VNode*(Value*, Value*, Value*, Value*, Value*, Value*, Value*)> func, Value* a, Value* b, Value* c, Value* d, Value* e, Value* f, Value* g) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.lazy7 not implemented");
}

VNode* lazy8(std::function<VNode*(Value*, Value*, Value*, Value*, Value*, Value*, Value*, Value*)> func, Value* a, Value* b, Value* c, Value* d, Value* e, Value* f, Value* g, Value* h) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.lazy8 not implemented");
}

std::u16string noScript(const std::u16string& tag) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.noScript not implemented");
}

std::u16string noOnOrFormAction(const std::u16string& key) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.noOnOrFormAction not implemented");
}

std::u16string noInnerHtmlOrFormAction(const std::u16string& key) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.noInnerHtmlOrFormAction not implemented");
}

std::u16string noJavaScriptOrHtmlUri(const std::u16string& value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.noJavaScriptOrHtmlUri not implemented");
}

std::u16string noJavaScriptOrHtmlJson(Value* value) {
    // TODO: implement
    throw std::runtime_error("Elm.Kernel.VirtualDom.noJavaScriptOrHtmlJson not implemented");
}

} // namespace Elm::Kernel::VirtualDom
