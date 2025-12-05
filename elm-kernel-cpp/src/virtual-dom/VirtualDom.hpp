#ifndef ELM_KERNEL_VIRTUALDOM_HPP
#define ELM_KERNEL_VIRTUALDOM_HPP

/**
 * Elm Kernel VirtualDom Module - Runtime Heap Integration
 *
 * Provides virtual DOM operations using GC-managed heap values.
 * Note: This is a stub - full implementation requires platform-specific rendering.
 */

#include "allocator/Heap.hpp"
#include "allocator/HeapHelpers.hpp"
#include "../json/Json.hpp"
#include <functional>
#include <memory>
#include <vector>
#include <map>

namespace Elm::Kernel::VirtualDom {

using DecoderPtr = Json::DecoderPtr;

// VNode types (matching JS implementation)
enum class VNodeTag {
    Text = 0,      // Text node
    Node = 1,      // Element node
    KeyedNode = 2, // Keyed element node
    Custom = 3,    // Custom element with render/diff
    Tagger = 4,    // Message mapper
    Thunk = 5      // Lazy node
};

// Fact (attribute) types
enum class FactTag {
    Style = 0,     // CSS style
    Event = 1,     // Event handler
    Attr = 2,      // Attribute (setAttribute)
    AttrNS = 3,    // Namespaced attribute
    Prop = 4       // Property (direct assignment)
};

// Forward declarations
struct VNode;
struct Fact;

using VNodePtr = std::shared_ptr<VNode>;
using FactPtr = std::shared_ptr<Fact>;

// Callback type for message tagger
using TaggerFn = std::function<HPointer(HPointer)>;

// Callback type for thunk
using ThunkFn = std::function<VNodePtr()>;

// Fact (attribute/property/event) representation
struct Fact {
    FactTag tag;
    std::vector<u16> name;
    std::vector<u16> stringValue;      // For Style, Attr, AttrNS
    HPointer jsonValue{0, Const_Nil + 1, 0};  // For Prop
    std::vector<u16> namespace_;       // For AttrNS

    // Event-specific fields
    DecoderPtr eventDecoder;
    bool stopPropagation = false;
    bool preventDefault = false;
};

// VNode representation
struct VNode {
    VNodeTag tag;
    std::vector<u16> text;             // For Text nodes
    std::vector<u16> tagName;          // For Node/KeyedNode
    std::vector<u16> namespace_;       // For namespaced elements (SVG, etc.)

    std::map<FactTag, std::vector<FactPtr>> facts;  // Organized by category
    std::vector<VNodePtr> children;                  // For Node
    std::vector<std::pair<std::vector<u16>, VNodePtr>> keyedChildren;  // For KeyedNode

    size_t descendantsCount = 0;       // For diff optimization

    // For Tagger nodes
    TaggerFn tagger;
    VNodePtr wrappedNode;

    // For Thunk (lazy) nodes
    std::vector<HPointer> refs;        // Arguments for equality check
    ThunkFn thunk;                     // Function to compute node
    VNodePtr cachedNode;               // Cached result
};

// ============================================================================
// Node constructors
// ============================================================================

/**
 * Create a text node.
 */
VNodePtr text(void* str);

/**
 * Create an element node.
 * @param tag Element tag name
 * @param factList Elm list of facts (attributes/properties/etc)
 * @param kidList Elm list of child VNodes
 */
VNodePtr node(void* tag, HPointer factList, HPointer kidList);

/**
 * Create a namespaced element node (SVG, MathML, etc.).
 */
VNodePtr nodeNS(void* ns, void* tag, HPointer factList, HPointer kidList);

/**
 * Create a keyed element node.
 */
VNodePtr keyedNode(void* tag, HPointer factList, HPointer keyedKidList);

/**
 * Create a namespaced keyed element node.
 */
VNodePtr keyedNodeNS(void* ns, void* tag, HPointer factList, HPointer keyedKidList);

// ============================================================================
// Fact constructors
// ============================================================================

/**
 * Create an attribute.
 */
FactPtr attribute(void* key, void* value);

/**
 * Create a namespaced attribute.
 */
FactPtr attributeNS(void* ns, void* key, void* value);

/**
 * Create a property.
 */
FactPtr property(void* key, HPointer value);

/**
 * Create a style.
 */
FactPtr style(void* key, void* value);

/**
 * Create an event handler.
 */
FactPtr on(void* event, DecoderPtr decoder);

// ============================================================================
// Mapping
// ============================================================================

/**
 * Map over a virtual node (transform messages).
 */
VNodePtr map(TaggerFn func, VNodePtr vnode);

/**
 * Map over an attribute (transform messages).
 */
FactPtr mapAttribute(TaggerFn func, FactPtr fact);

// ============================================================================
// Lazy nodes
// ============================================================================

using Lazy1Fn = std::function<VNodePtr(HPointer)>;
using Lazy2Fn = std::function<VNodePtr(HPointer, HPointer)>;
using Lazy3Fn = std::function<VNodePtr(HPointer, HPointer, HPointer)>;
using Lazy4Fn = std::function<VNodePtr(HPointer, HPointer, HPointer, HPointer)>;
using Lazy5Fn = std::function<VNodePtr(HPointer, HPointer, HPointer, HPointer, HPointer)>;
using Lazy6Fn = std::function<VNodePtr(HPointer, HPointer, HPointer, HPointer, HPointer, HPointer)>;
using Lazy7Fn = std::function<VNodePtr(HPointer, HPointer, HPointer, HPointer, HPointer, HPointer, HPointer)>;
using Lazy8Fn = std::function<VNodePtr(HPointer, HPointer, HPointer, HPointer, HPointer, HPointer, HPointer, HPointer)>;

VNodePtr lazy(Lazy1Fn func, HPointer arg);
VNodePtr lazy2(Lazy2Fn func, HPointer a, HPointer b);
VNodePtr lazy3(Lazy3Fn func, HPointer a, HPointer b, HPointer c);
VNodePtr lazy4(Lazy4Fn func, HPointer a, HPointer b, HPointer c, HPointer d);
VNodePtr lazy5(Lazy5Fn func, HPointer a, HPointer b, HPointer c, HPointer d, HPointer e);
VNodePtr lazy6(Lazy6Fn func, HPointer a, HPointer b, HPointer c, HPointer d, HPointer e, HPointer f);
VNodePtr lazy7(Lazy7Fn func, HPointer a, HPointer b, HPointer c, HPointer d, HPointer e, HPointer f, HPointer g);
VNodePtr lazy8(Lazy8Fn func, HPointer a, HPointer b, HPointer c, HPointer d, HPointer e, HPointer f, HPointer g, HPointer h);

// ============================================================================
// Security filters
// ============================================================================

/**
 * Filter to prevent <script> tags.
 */
HPointer noScript(void* tag);

/**
 * Filter to prevent on* event attributes and formaction.
 */
HPointer noOnOrFormAction(void* key);

/**
 * Filter to prevent innerHTML/outerHTML properties.
 */
HPointer noInnerHtmlOrFormAction(void* key);

/**
 * Filter to prevent javascript: and data:text/html URIs.
 */
HPointer noJavaScriptOrHtmlUri(void* value);

/**
 * Filter to prevent javascript: and data:text/html in JSON values.
 */
HPointer noJavaScriptOrHtmlJson(HPointer value);

// ============================================================================
// Converting VNodes to/from Elm values
// ============================================================================

/**
 * Wrap a VNodePtr as an Elm Custom value.
 */
HPointer wrapVNode(VNodePtr node);

/**
 * Unwrap an Elm Custom value to VNodePtr.
 */
VNodePtr unwrapVNode(void* value);

} // namespace Elm::Kernel::VirtualDom

#endif // ELM_KERNEL_VIRTUALDOM_HPP
