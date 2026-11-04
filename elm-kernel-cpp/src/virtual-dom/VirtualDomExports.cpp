//===- VirtualDomExports.cpp - Elm.Kernel.VirtualDom (heap model) -----------===//
//
// Implements the `Elm.Kernel.VirtualDom` kernel natively, so that a native program can build
// `Html msg` and `Svg msg` values.
//
// Every VirtualDom value is an ordinary `Tag_Custom` object with the layout of eco/system's
// transparent `Html.Dom.Node` and `Html.Dom.Fact`, as `VirtualDomLayout.hpp` defines it. A node or
// fact holds nothing off the heap and is never written after it is built (HEAP_SNAPSHOT_001); a
// function that "changes" one, such as `mapAttribute`, builds a new object.
//
// Two kernel operations behave differently from the browser runtime. The `lazy` functions apply
// their function at once and return its node, so nothing is ever deferred or memoised. `map` and
// `mapAttribute` keep the tagger function in the value instead of composing a new closure: `map`
// builds a `Mapped` node, and `mapAttribute` conses the tagger onto an event's tagger list, so the
// list holds the outermost tagger first. The XSS filters return what elm/virtual-dom 1.0.5's
// production build returns (VDOM_003), using the predicates in `XssFilters.hpp`; when nothing
// matches, a filter returns its argument word unchanged.
//
// Every allocation is a GC point, at which unrooted handles go stale. The functions here follow
// four rooting rules:
//   R1  a constructor that allocates once hands its decoded arguments straight to `alloc::custom`,
//       which roots them across its allocation;
//   R2  a constructor that allocates twice guards every `HPointer` it uses after the first
//       allocation with one `StackRootGuard`;
//   R3  a String argument whose characters are read is read through `Export::toPtr`, because it may
//       be the raw address of an interned literal, and is copied into C++ memory before anything
//       allocates;
//   R4  a `lazy` function calls Elm and returns its result, holding nothing across the call.
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

/// Returns the heap handle that the kernel word `h` carries.
HPointer dec(HPtr h) { return Export::decode(h.toBits()); }
/// Returns the kernel word for the heap handle `h`.
HPtr enc(HPointer h) { return HPtr::fromBits(Export::encode(h)); }

/// Returns a new object of constructor `ctor` whose boxed fields are `fields`, in order. A GC point,
/// across which `alloc::custom` roots the fields (R1).
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

/// Returns a new element of constructor `ctor` whose namespace field is `Just ns`, followed by `tag`,
/// `facts` and `kids`. Two GC points (R2): `t`, `f` and `k` are guarded across the `just`
/// allocation, and `make` roots `justNs` across the second.
HPointer makeNS(u16 ctor, HPtr ns, HPtr tag, HPtr facts, HPtr kids) {
    HPointer n = dec(ns), t = dec(tag), f = dec(facts), k = dec(kids);
    Elm::StackRootGuard g(&t, &f, &k);
    HPointer justNs = alloc::just(alloc::boxed(n), true);
    return make(ctor, {justNs, t, f, k});
}

/// Returns a copy, in C++ memory, of the UTF-16 units of the String `s` (R3). The copy stays valid
/// across collections.
std::u16string toU16(HPtr s) { return StringOps::toStdU16String(Export::toPtr(s.toBits())); }

/// Returns a new String of `key` with `data-` before it. A GC point.
HPtr dataPrefixed(const std::u16string& key) {
    return enc(alloc::allocString(u"data-" + key));
}

/// Returns the result of applying the closure `fn` to `args`, at most 8 of them (R4).
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

// The tagger is kept in a `Mapped` node; no closure is built.
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
    // `ev` is a bare address and is not used past here: the next line may GC (R2).
    Elm::StackRootGuard g({&name, &handler, &taggers, &f});
    HPointer consed = alloc::cons(alloc::boxed(f), taggers, true);
    return enc(make(FACT_EVENT, {name, handler, consed}));
}

//===----------------------------------------------------------------------===//
// Lazy: each applies its function at once and returns the node.
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
// XSS filters (elm/virtual-dom 1.0.5 production behaviour, VDOM_003)
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

HPtr Elm_Kernel_VirtualDom_noJavaScriptOrHtmlJson(HPtr value) {
    std::u16string s;
    if (!JsonRead::jsToString(value.toBits(), s) || !Xss::isJavaScriptOrHtmlUri(s)) return value;
    return Elm_Kernel_Json_wrap(enc(alloc::emptyString()));
}

} // extern "C"
