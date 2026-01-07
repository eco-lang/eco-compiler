/**
 * Elm Kernel VirtualDom Module - Runtime Heap Integration
 *
 * Provides virtual DOM operations using GC-managed heap values.
 * Note: This is a stub - full implementation requires platform-specific rendering.
 */

#include "VirtualDom.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/StringOps.hpp"
#include "allocator/ListOps.hpp"

namespace Elm::Kernel::VirtualDom {

// ============================================================================
// Helper functions
// ============================================================================

static std::vector<u16> stringToVec(void* str) {
    if (!str) return {};
    ElmString* s = static_cast<ElmString*>(str);
    return std::vector<u16>(s->chars, s->chars + s->header.size);
}

static bool startsWith(const std::vector<u16>& str, const char* prefix) {
    size_t prefixLen = strlen(prefix);
    if (str.size() < prefixLen) return false;
    for (size_t i = 0; i < prefixLen; i++) {
        if (str[i] != static_cast<u16>(prefix[i])) return false;
    }
    return true;
}

static std::vector<u16> toLower(const std::vector<u16>& str) {
    std::vector<u16> result;
    result.reserve(str.size());
    for (u16 c : str) {
        if (c >= 'A' && c <= 'Z') {
            result.push_back(c + ('a' - 'A'));
        } else {
            result.push_back(c);
        }
    }
    return result;
}

// ============================================================================
// Node constructors
// ============================================================================

VNodePtr text(void* str) {
    auto vnode = std::make_shared<VNode>();
    vnode->tag = VNodeTag::Text;
    vnode->text = stringToVec(str);
    vnode->descendantsCount = 0;
    return vnode;
}

VNodePtr node(void* tag, HPointer factList, HPointer kidList) {
    return nodeNS(nullptr, tag, factList, kidList);
}

VNodePtr nodeNS(void* ns, void* tag, HPointer factList, HPointer kidList) {
    auto vnode = std::make_shared<VNode>();
    vnode->tag = VNodeTag::Node;
    vnode->tagName = stringToVec(tag);
    vnode->namespace_ = stringToVec(ns);

    // Convert kids list to vector (stub - would iterate Elm list)
    (void)factList;
    (void)kidList;

    vnode->descendantsCount = vnode->children.size();
    for (const auto& child : vnode->children) {
        if (child) vnode->descendantsCount += child->descendantsCount;
    }

    return vnode;
}

VNodePtr keyedNode(void* tag, HPointer factList, HPointer keyedKidList) {
    return keyedNodeNS(nullptr, tag, factList, keyedKidList);
}

VNodePtr keyedNodeNS(void* ns, void* tag, HPointer factList, HPointer keyedKidList) {
    auto vnode = std::make_shared<VNode>();
    vnode->tag = VNodeTag::KeyedNode;
    vnode->tagName = stringToVec(tag);
    vnode->namespace_ = stringToVec(ns);

    // Convert keyed kids list to vector (stub)
    (void)factList;
    (void)keyedKidList;

    vnode->descendantsCount = vnode->keyedChildren.size();
    for (const auto& [key, child] : vnode->keyedChildren) {
        if (child) vnode->descendantsCount += child->descendantsCount;
    }

    return vnode;
}

// ============================================================================
// Fact constructors
// ============================================================================

FactPtr attribute(void* key, void* value) {
    auto fact = std::make_shared<Fact>();
    fact->tag = FactTag::Attr;
    fact->name = stringToVec(key);
    fact->stringValue = stringToVec(value);
    return fact;
}

FactPtr attributeNS(void* ns, void* key, void* value) {
    auto fact = std::make_shared<Fact>();
    fact->tag = FactTag::AttrNS;
    fact->name = stringToVec(key);
    fact->stringValue = stringToVec(value);
    fact->namespace_ = stringToVec(ns);
    return fact;
}

FactPtr property(void* key, HPointer value) {
    auto fact = std::make_shared<Fact>();
    fact->tag = FactTag::Prop;
    fact->name = stringToVec(key);
    fact->jsonValue = value;
    return fact;
}

FactPtr style(void* key, void* value) {
    auto fact = std::make_shared<Fact>();
    fact->tag = FactTag::Style;
    fact->name = stringToVec(key);
    fact->stringValue = stringToVec(value);
    return fact;
}

FactPtr on(void* event, DecoderPtr decoder) {
    auto fact = std::make_shared<Fact>();
    fact->tag = FactTag::Event;
    fact->name = stringToVec(event);
    fact->eventDecoder = decoder;
    fact->stopPropagation = false;
    fact->preventDefault = false;
    return fact;
}

// ============================================================================
// Mapping
// ============================================================================

VNodePtr map(TaggerFn func, VNodePtr vnode) {
    if (!vnode) return nullptr;

    auto taggerNode = std::make_shared<VNode>();
    taggerNode->tag = VNodeTag::Tagger;
    taggerNode->tagger = func;
    taggerNode->wrappedNode = vnode;
    taggerNode->descendantsCount = 1 + vnode->descendantsCount;

    return taggerNode;
}

FactPtr mapAttribute(TaggerFn func, FactPtr fact) {
    if (!fact) return nullptr;

    // For event handlers, we need to wrap the decoder result with the tagger
    if (fact->tag == FactTag::Event) {
        auto newFact = std::make_shared<Fact>();
        newFact->tag = fact->tag;
        newFact->name = fact->name;
        newFact->eventDecoder = fact->eventDecoder;  // Would need to wrap decoder
        newFact->stopPropagation = fact->stopPropagation;
        newFact->preventDefault = fact->preventDefault;
        // Store tagger for later use when decoding events
        return newFact;
    }

    // Non-event facts don't need mapping
    return fact;
}

// ============================================================================
// Lazy nodes
// ============================================================================

VNodePtr lazy(Lazy1Fn func, HPointer arg) {
    auto thunkNode = std::make_shared<VNode>();
    thunkNode->tag = VNodeTag::Thunk;
    thunkNode->refs.push_back(arg);
    thunkNode->thunk = [func, arg]() { return func(arg); };
    thunkNode->cachedNode = nullptr;
    return thunkNode;
}

VNodePtr lazy2(Lazy2Fn func, HPointer a, HPointer b) {
    auto thunkNode = std::make_shared<VNode>();
    thunkNode->tag = VNodeTag::Thunk;
    thunkNode->refs.push_back(a);
    thunkNode->refs.push_back(b);
    thunkNode->thunk = [func, a, b]() { return func(a, b); };
    thunkNode->cachedNode = nullptr;
    return thunkNode;
}

VNodePtr lazy3(Lazy3Fn func, HPointer a, HPointer b, HPointer c) {
    auto thunkNode = std::make_shared<VNode>();
    thunkNode->tag = VNodeTag::Thunk;
    thunkNode->refs.push_back(a);
    thunkNode->refs.push_back(b);
    thunkNode->refs.push_back(c);
    thunkNode->thunk = [func, a, b, c]() { return func(a, b, c); };
    thunkNode->cachedNode = nullptr;
    return thunkNode;
}

VNodePtr lazy4(Lazy4Fn func, HPointer a, HPointer b, HPointer c, HPointer d) {
    auto thunkNode = std::make_shared<VNode>();
    thunkNode->tag = VNodeTag::Thunk;
    thunkNode->refs.push_back(a);
    thunkNode->refs.push_back(b);
    thunkNode->refs.push_back(c);
    thunkNode->refs.push_back(d);
    thunkNode->thunk = [func, a, b, c, d]() { return func(a, b, c, d); };
    thunkNode->cachedNode = nullptr;
    return thunkNode;
}

VNodePtr lazy5(Lazy5Fn func, HPointer a, HPointer b, HPointer c, HPointer d, HPointer e) {
    auto thunkNode = std::make_shared<VNode>();
    thunkNode->tag = VNodeTag::Thunk;
    thunkNode->refs.push_back(a);
    thunkNode->refs.push_back(b);
    thunkNode->refs.push_back(c);
    thunkNode->refs.push_back(d);
    thunkNode->refs.push_back(e);
    thunkNode->thunk = [func, a, b, c, d, e]() { return func(a, b, c, d, e); };
    thunkNode->cachedNode = nullptr;
    return thunkNode;
}

VNodePtr lazy6(Lazy6Fn func, HPointer a, HPointer b, HPointer c, HPointer d, HPointer e, HPointer f) {
    auto thunkNode = std::make_shared<VNode>();
    thunkNode->tag = VNodeTag::Thunk;
    thunkNode->refs.push_back(a);
    thunkNode->refs.push_back(b);
    thunkNode->refs.push_back(c);
    thunkNode->refs.push_back(d);
    thunkNode->refs.push_back(e);
    thunkNode->refs.push_back(f);
    thunkNode->thunk = [func, a, b, c, d, e, f]() { return func(a, b, c, d, e, f); };
    thunkNode->cachedNode = nullptr;
    return thunkNode;
}

VNodePtr lazy7(Lazy7Fn func, HPointer a, HPointer b, HPointer c, HPointer d, HPointer e, HPointer f, HPointer g) {
    auto thunkNode = std::make_shared<VNode>();
    thunkNode->tag = VNodeTag::Thunk;
    thunkNode->refs.push_back(a);
    thunkNode->refs.push_back(b);
    thunkNode->refs.push_back(c);
    thunkNode->refs.push_back(d);
    thunkNode->refs.push_back(e);
    thunkNode->refs.push_back(f);
    thunkNode->refs.push_back(g);
    thunkNode->thunk = [func, a, b, c, d, e, f, g]() { return func(a, b, c, d, e, f, g); };
    thunkNode->cachedNode = nullptr;
    return thunkNode;
}

VNodePtr lazy8(Lazy8Fn func, HPointer a, HPointer b, HPointer c, HPointer d, HPointer e, HPointer f, HPointer g, HPointer h) {
    auto thunkNode = std::make_shared<VNode>();
    thunkNode->tag = VNodeTag::Thunk;
    thunkNode->refs.push_back(a);
    thunkNode->refs.push_back(b);
    thunkNode->refs.push_back(c);
    thunkNode->refs.push_back(d);
    thunkNode->refs.push_back(e);
    thunkNode->refs.push_back(f);
    thunkNode->refs.push_back(g);
    thunkNode->refs.push_back(h);
    thunkNode->thunk = [func, a, b, c, d, e, f, g, h]() { return func(a, b, c, d, e, f, g, h); };
    thunkNode->cachedNode = nullptr;
    return thunkNode;
}

// ============================================================================
// Security filters
// ============================================================================

HPointer noScript(void* tag) {
    if (!tag) return alloc::emptyString();

    std::vector<u16> tagVec = stringToVec(tag);
    std::vector<u16> lower = toLower(tagVec);

    // Check if it's "script"
    const char* script = "script";
    bool isScript = (lower.size() == 6);
    for (size_t i = 0; i < 6 && isScript; i++) {
        if (lower[i] != script[i]) isScript = false;
    }

    if (isScript) {
        // Replace with "p"
        return alloc::allocStringFromUTF8("p");
    }

    return Allocator::instance().wrap(tag);
}

HPointer noOnOrFormAction(void* key) {
    if (!key) return alloc::emptyString();

    std::vector<u16> keyVec = stringToVec(key);
    std::vector<u16> lower = toLower(keyVec);

    // Block on* attributes
    if (lower.size() > 2 && lower[0] == 'o' && lower[1] == 'n') {
        return alloc::emptyString();
    }

    // Block formaction
    if (startsWith(lower, "formaction")) {
        return alloc::emptyString();
    }

    return Allocator::instance().wrap(key);
}

HPointer noInnerHtmlOrFormAction(void* key) {
    if (!key) return alloc::emptyString();

    std::vector<u16> keyVec = stringToVec(key);
    std::vector<u16> lower = toLower(keyVec);

    if (startsWith(lower, "innerhtml") || startsWith(lower, "outerhtml") || startsWith(lower, "formaction")) {
        return alloc::emptyString();
    }

    return Allocator::instance().wrap(key);
}

HPointer noJavaScriptOrHtmlUri(void* value) {
    if (!value) return alloc::emptyString();

    std::vector<u16> valVec = stringToVec(value);
    std::vector<u16> lower = toLower(valVec);

    // Trim leading whitespace
    size_t start = 0;
    while (start < lower.size() && (lower[start] == ' ' || lower[start] == '\t' || lower[start] == '\n')) {
        start++;
    }

    std::vector<u16> trimmed(lower.begin() + start, lower.end());

    if (startsWith(trimmed, "javascript:") || startsWith(trimmed, "data:text/html")) {
        return alloc::emptyString();
    }

    return Allocator::instance().wrap(value);
}

HPointer noJavaScriptOrHtmlJson(HPointer value) {
    // For JSON values, we need to check if it's a string containing dangerous URIs
    void* resolved = Allocator::instance().resolve(value);
    if (!resolved) return value;

    Header* hdr = static_cast<Header*>(resolved);
    if (hdr->tag != Tag_String) {
        // Non-string JSON values are safe
        return value;
    }

    // It's a string, apply the same check as noJavaScriptOrHtmlUri
    return noJavaScriptOrHtmlUri(resolved);
}

// ============================================================================
// VNode wrapping
// ============================================================================

// We use a global map to store VNodePtrs and return indices as Custom values
// This is a simple approach; a more sophisticated version would integrate with GC
static std::vector<VNodePtr> vnodeRegistry;

HPointer wrapVNode(VNodePtr node) {
    if (!node) return alloc::nothing();

    // Store in registry and return index as Custom
    u32 index = static_cast<u32>(vnodeRegistry.size());
    vnodeRegistry.push_back(node);

    // Return Custom with index stored as unboxed int
    return alloc::custom(0, {alloc::unboxedInt(static_cast<i64>(index))}, 1);
}

VNodePtr unwrapVNode(void* value) {
    if (!value) return nullptr;

    Header* hdr = static_cast<Header*>(value);
    if (hdr->tag != Tag_Custom) return nullptr;

    Custom* custom = static_cast<Custom*>(value);
    if (custom->header.size == 0) return nullptr;

    // Get index from unboxed value
    u32 index = static_cast<u32>(custom->values[0].i);
    if (index >= vnodeRegistry.size()) return nullptr;

    return vnodeRegistry[index];
}

} // namespace Elm::Kernel::VirtualDom
