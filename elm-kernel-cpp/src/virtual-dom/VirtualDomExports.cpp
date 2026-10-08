//===- VirtualDomExports.cpp - Elm.Kernel.VirtualDom (heap model) -----------===//
//
// plans/elm-html-native-kernel.md §3-§5. Every VirtualDom value is an ordinary
// Tag_Custom object with the layout of eco/system's transparent `Http.Dom.Node`
// / `Http.Dom.Fact` (VirtualDomLayout.hpp, D3). There is no off-heap state and
// nothing is written after construction (R6, HEAP_SNAPSHOT_001). `lazy*`
// evaluate eagerly (D5), as VirtualDom.server.js does. The XSS filters return
// what elm/virtual-dom 1.0.5's PROD arms return (§6, VDOM_003).
//
// Rooting (§5):
//   R1  single-allocation constructors hand their decoded arguments straight to
//       alloc::custom, which roots them across its allocation;
//   R2  two-allocation constructors guard every HPointer used after the first
//       allocation with one StackRootGuard;
//   R3  strings are read through Export::toPtr (arguments may be raw pointers
//       to global literals) and copied out before any allocation;
//   R4  lazy* call Elm and return its result; nothing is live after the call.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "VirtualDomLayout.hpp"
#include "XssFilters.hpp"
#include "../json/JsonRead.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"
#include <initializer_list>
#include <string>
#include <vector>

using namespace Elm;
using namespace Elm::Kernel;
using namespace Elm::Kernel::VirtualDom;

namespace {

HPointer dec(HPtr h) { return Export::decode(h.toBits()); }
HPtr enc(HPointer h) { return HPtr::fromBits(Export::encode(h)); }

// R1: one allocation; alloc::custom roots `v` across it.
HPointer make(u16 ctor, std::initializer_list<HPointer> fields) {
    std::vector<Unboxable> v;
    v.reserve(fields.size());
    for (HPointer f : fields) {
        Unboxable u;
        u.p = f;
        v.push_back(u);
    }
    return alloc::custom(ctor, v, u64{0});
}

// R2: `Just ns` first, then the element. tag/facts/kids are guarded across the
// `just` allocation; `justNs` is handed to `make`, which roots it.
HPointer makeNS(u16 ctor, HPtr ns, HPtr tag, HPtr facts, HPtr kids) {
    HPointer n = dec(ns), t = dec(tag), f = dec(facts), k = dec(kids);
    Elm::StackRootGuard g(&t, &f, &k);
    HPointer justNs = alloc::just(alloc::boxed(n), true);   // may GC: t/f/k updated
    return make(ctor, {justNs, t, f, k});
}

// R3: copy the string out before any allocation.
std::u16string toU16(HPtr s) { return StringOps::toStdU16String(Export::toPtr(s.toBits())); }

HPtr dataPrefixed(const std::u16string& key) {
    return enc(alloc::allocString(u"data-" + key));
}

// R4, D5: lazy evaluates at construction; the result is the node itself.
HPtr applyNow(HPtr fn, std::initializer_list<HPtr> args) {
    uint64_t buf[8];
    uint32_t n = 0;
    for (HPtr a : args) buf[n++] = a.toBits();
    return eco_apply_closure(fn, buf, n);
}

} // namespace

extern "C" {

//===----------------------------------------------------------------------===//
// Nodes
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_VirtualDom_text(HPtr str) {
    return enc(make(NODE_TEXT, {dec(str)}));
}

HPtr Elm_Kernel_VirtualDom_node(HPtr tag, HPtr factList, HPtr kidList) {
    return enc(make(NODE_ELEMENT, {alloc::nothing(), dec(tag), dec(factList), dec(kidList)}));
}

HPtr Elm_Kernel_VirtualDom_nodeNS(HPtr ns, HPtr tag, HPtr factList, HPtr kidList) {
    return enc(makeNS(NODE_ELEMENT, ns, tag, factList, kidList));
}

HPtr Elm_Kernel_VirtualDom_keyedNode(HPtr tag, HPtr factList, HPtr keyedKidList) {
    return enc(make(NODE_KEYED_ELEMENT,
                    {alloc::nothing(), dec(tag), dec(factList), dec(keyedKidList)}));
}

HPtr Elm_Kernel_VirtualDom_keyedNodeNS(HPtr ns, HPtr tag, HPtr factList, HPtr keyedKidList) {
    return enc(makeNS(NODE_KEYED_ELEMENT, ns, tag, factList, keyedKidList));
}

// D6: the tagger is kept; C++ never builds closures.
HPtr Elm_Kernel_VirtualDom_map(HPtr closure, HPtr vnode) {
    return enc(make(NODE_MAPPED, {dec(closure), dec(vnode)}));
}

//===----------------------------------------------------------------------===//
// Facts
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_VirtualDom_attribute(HPtr key, HPtr value) {
    return enc(make(FACT_ATTRIBUTE, {dec(key), dec(value)}));
}

HPtr Elm_Kernel_VirtualDom_attributeNS(HPtr ns, HPtr key, HPtr value) {
    return enc(make(FACT_ATTRIBUTE_NS, {dec(ns), dec(key), dec(value)}));
}

HPtr Elm_Kernel_VirtualDom_property(HPtr key, HPtr value) {
    return enc(make(FACT_PROPERTY, {dec(key), dec(value)}));
}

HPtr Elm_Kernel_VirtualDom_style(HPtr key, HPtr value) {
    return enc(make(FACT_STYLE, {dec(key), dec(value)}));
}

HPtr Elm_Kernel_VirtualDom_on(HPtr event, HPtr decoder) {
    return enc(make(FACT_EVENT, {dec(event), dec(decoder), alloc::listNil()}));
}

// JS: an event gets `func` wrapped around its handler; any other fact is
// returned unchanged. Natively `func` is consed onto the tagger list, so the
// list is outermost first (D6).
HPtr Elm_Kernel_VirtualDom_mapAttribute(HPtr closure, HPtr fact) {
    void* p = Export::toPtr(fact.toBits());
    if (p == nullptr || alloc::getTag(p) != Tag_Custom ||
        static_cast<Custom*>(p)->ctor != FACT_EVENT) {
        return fact;
    }
    Custom* ev = static_cast<Custom*>(p);
    HPointer name = ev->values[EV_NAME].p;
    HPointer handler = ev->values[EV_HANDLER].p;
    HPointer taggers = ev->values[EV_TAGGERS].p;
    HPointer f = dec(closure);
    // `ev` is dead from here: the next line may GC (R2).
    Elm::StackRootGuard g({&name, &handler, &taggers, &f});
    HPointer consed = alloc::cons(alloc::boxed(f), taggers, true);
    return enc(make(FACT_EVENT, {name, handler, consed}));
}

//===----------------------------------------------------------------------===//
// Lazy (eager, D5)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_VirtualDom_lazy(HPtr closure, HPtr arg) {
    return applyNow(closure, {arg});
}

HPtr Elm_Kernel_VirtualDom_lazy2(HPtr closure, HPtr a, HPtr b) {
    return applyNow(closure, {a, b});
}

HPtr Elm_Kernel_VirtualDom_lazy3(HPtr closure, HPtr a, HPtr b, HPtr c) {
    return applyNow(closure, {a, b, c});
}

HPtr Elm_Kernel_VirtualDom_lazy4(HPtr closure, HPtr a, HPtr b, HPtr c, HPtr d) {
    return applyNow(closure, {a, b, c, d});
}

HPtr Elm_Kernel_VirtualDom_lazy5(HPtr closure, HPtr a, HPtr b, HPtr c, HPtr d, HPtr e) {
    return applyNow(closure, {a, b, c, d, e});
}

HPtr Elm_Kernel_VirtualDom_lazy6(HPtr closure, HPtr a, HPtr b, HPtr c, HPtr d, HPtr e, HPtr f) {
    return applyNow(closure, {a, b, c, d, e, f});
}

HPtr Elm_Kernel_VirtualDom_lazy7(HPtr closure, HPtr a, HPtr b, HPtr c, HPtr d, HPtr e, HPtr f,
                                 HPtr g) {
    return applyNow(closure, {a, b, c, d, e, f, g});
}

HPtr Elm_Kernel_VirtualDom_lazy8(HPtr closure, HPtr a, HPtr b, HPtr c, HPtr d, HPtr e, HPtr f,
                                 HPtr g, HPtr h) {
    return applyNow(closure, {a, b, c, d, e, f, g, h});
}

//===----------------------------------------------------------------------===//
// XSS filters (elm/virtual-dom 1.0.5 PROD arms, VDOM_003)
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_VirtualDom_noScript(HPtr tag) {
    return Xss::isScriptTag(toU16(tag)) ? enc(alloc::allocStringFromUTF8("p")) : tag;
}

HPtr Elm_Kernel_VirtualDom_noOnOrFormAction(HPtr key) {
    std::u16string k = toU16(key);
    return Xss::isOnOrFormAction(k) ? dataPrefixed(k) : key;
}

HPtr Elm_Kernel_VirtualDom_noInnerHtmlOrFormAction(HPtr key) {
    std::u16string k = toU16(key);
    return Xss::isInnerHtmlOrFormAction(k) ? dataPrefixed(k) : key;
}

HPtr Elm_Kernel_VirtualDom_noJavaScriptUri(HPtr value) {
    return Xss::isJavaScriptUri(toU16(value)) ? enc(alloc::emptyString()) : value;
}

HPtr Elm_Kernel_VirtualDom_noJavaScriptOrHtmlUri(HPtr value) {
    return Xss::isJavaScriptOrHtmlUri(toU16(value)) ? enc(alloc::emptyString()) : value;
}

// A String, or an Array whose JS String(value) matches RE_js_html, becomes
// `Json.Encode.string ""`; anything else is returned unchanged.
HPtr Elm_Kernel_VirtualDom_noJavaScriptOrHtmlJson(HPtr value) {
    std::u16string s;
    if (!JsonRead::jsToString(value.toBits(), s) || !Xss::isJavaScriptOrHtmlUri(s)) return value;
    return Elm_Kernel_Json_wrap(enc(alloc::emptyString()));   // built by the Json kernel (D18)
}

} // extern "C"
