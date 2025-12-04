#ifndef ELM_KERNEL_VIRTUALDOM_HPP
#define ELM_KERNEL_VIRTUALDOM_HPP

#include <string>
#include <functional>

namespace Elm::Kernel::VirtualDom {

// Forward declarations
struct Value;
struct VNode;
struct Attribute;
struct Decoder;
struct List;

// Create a text node
VNode* text(const std::u16string& str);

// Create an element node
VNode* node(const std::u16string& tag, List* attrs, List* children);

// Create a namespaced element node
VNode* nodeNS(const std::u16string& ns, const std::u16string& tag, List* attrs, List* children);

// Create a keyed element node
VNode* keyedNode(const std::u16string& tag, List* attrs, List* children);

// Create a namespaced keyed element node
VNode* keyedNodeNS(const std::u16string& ns, const std::u16string& tag, List* attrs, List* children);

// Create an attribute
Attribute* attribute(const std::u16string& key, const std::u16string& value);

// Create a namespaced attribute
Attribute* attributeNS(const std::u16string& ns, const std::u16string& key, const std::u16string& value);

// Create a property
Attribute* property(const std::u16string& key, Value* value);

// Create a style
Attribute* style(const std::u16string& key, const std::u16string& value);

// Create an event handler
Attribute* on(const std::u16string& event, Decoder* decoder);

// Map over a virtual node
VNode* map(std::function<Value*(Value*)> func, VNode* vnode);

// Map over an attribute
Attribute* mapAttribute(std::function<Value*(Value*)> func, Attribute* attr);

// Lazy nodes (memoization)
VNode* lazy(std::function<VNode*(Value*)> func, Value* arg);
VNode* lazy2(std::function<VNode*(Value*, Value*)> func, Value* a, Value* b);
VNode* lazy3(std::function<VNode*(Value*, Value*, Value*)> func, Value* a, Value* b, Value* c);
VNode* lazy4(std::function<VNode*(Value*, Value*, Value*, Value*)> func, Value* a, Value* b, Value* c, Value* d);
VNode* lazy5(std::function<VNode*(Value*, Value*, Value*, Value*, Value*)> func, Value* a, Value* b, Value* c, Value* d, Value* e);
VNode* lazy6(std::function<VNode*(Value*, Value*, Value*, Value*, Value*, Value*)> func, Value* a, Value* b, Value* c, Value* d, Value* e, Value* f);
VNode* lazy7(std::function<VNode*(Value*, Value*, Value*, Value*, Value*, Value*, Value*)> func, Value* a, Value* b, Value* c, Value* d, Value* e, Value* f, Value* g);
VNode* lazy8(std::function<VNode*(Value*, Value*, Value*, Value*, Value*, Value*, Value*, Value*)> func, Value* a, Value* b, Value* c, Value* d, Value* e, Value* f, Value* g, Value* h);

// Security filters
std::u16string noScript(const std::u16string& tag);
std::u16string noOnOrFormAction(const std::u16string& key);
std::u16string noInnerHtmlOrFormAction(const std::u16string& key);
std::u16string noJavaScriptOrHtmlUri(const std::u16string& value);
std::u16string noJavaScriptOrHtmlJson(Value* value);

} // namespace Elm::Kernel::VirtualDom

#endif // ELM_KERNEL_VIRTUALDOM_HPP
