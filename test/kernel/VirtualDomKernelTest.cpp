// Native elm/html kernel tests (plans/elm-html-native-kernel.md P0.3, P0.4, P2, P4).
//
// Values are built through the exported kernels, exactly as compiled Elm code
// builds them, and every intermediate value is kept in one RootedSlots buffer
// (`Tree`), because any kernel call may collect.

#include "VirtualDomKernelTest.hpp"
#include "../../runtime/src/allocator/Heap.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/RootedSlots.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/StringOps.hpp"
#include "../../elm-kernel-cpp/src/KernelExports.h"
#include "../../elm-kernel-cpp/src/ExportHelpers.hpp"
#include "../../elm-kernel-cpp/src/json/JsonRead.hpp"
#include "../../elm-kernel-cpp/src/virtual-dom/HtmlWriter.hpp"
#include "../../elm-kernel-cpp/src/virtual-dom/VirtualDomLayout.hpp"
#include "../../elm-kernel-cpp/src/virtual-dom/XssFilters.hpp"
#include "../allocator/TestHelpers.hpp"
#include "../TestSuite.hpp"
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

using namespace Elm;
namespace Ex = Elm::Kernel::Export;
namespace JR = Elm::Kernel::JsonRead;
namespace Xss = Elm::Kernel::Xss;
namespace VD = Elm::Kernel::VirtualDom;

namespace {

// ---- helpers --------------------------------------------------------------

// Every value built in a test, rooted in one buffer; handles are indices.
struct Tree {
    alloc::RootedSlots slots{256};
    size_t keep(HPtr h) {
        slots.push(h.toHPointer());
        return slots.size() - 1;
    }
    HPtr operator[](size_t i) { return HPtr::fromHPointer(slots[i]); }
    uint64_t bits(size_t i) { return (*this)[i].toBits(); }
};

size_t str(Tree& t, const std::string& utf8) {
    return t.keep(HPtr::fromHPointer(alloc::allocStringFromUTF8(utf8)));
}

size_t u16str(Tree& t, const std::u16string& s) {
    return t.keep(HPtr::fromHPointer(alloc::allocString(s)));
}

size_t list(Tree& t, const std::vector<size_t>& items) {
    std::vector<HPointer> elems;
    elems.reserve(items.size());
    for (size_t i : items) elems.push_back(t.slots[i]);   // read now; listFromPointers roots them
    return t.keep(HPtr::fromHPointer(alloc::listFromPointers(elems)));
}

std::string utf8Of(uint64_t bits) { return StringOps::toStdString(Ex::toPtr(bits)); }

std::string html(Tree& t, size_t node) {
    std::string out;
    VD::writeHtml(t.bits(node), out);
    return out;
}

void expectHtml(Tree& t, size_t node, const std::string& want, const char* name) {
    std::string got = html(t, node);
    if (got != want) TEST_FAIL(std::string(name) + ": got `" + got + "`, want `" + want + "`");
}

// ---- closures used by the tests ------------------------------------------

void* identityEvaluator(void* args[]) { return args[0]; }

HPtr identityClosure() {
    return eco_alloc_closure_fn(reinterpret_cast<void*>(&identityEvaluator), 1, 0);
}

// lazy evaluator of arity N: returns `text <last argument>` after allocating
// garbage (a GC point) with the result rooted.
template <int N>
void* lazyEvaluator(void* args[]) {
    HPtr last = HPtr::fromBits(reinterpret_cast<uint64_t>(args[N - 1]));
    HPointer r = Elm_Kernel_VirtualDom_text(last).toHPointer();
    {
        Elm::StackRootGuard g(&r);
        allocateGarbageInts(Allocator::instance(), 2000);
    }
    return reinterpret_cast<void*>(HPtr::fromHPointer(r).toBits());
}

// ---- Html-equivalent builders (elm/html 1.0.0 + elm/virtual-dom 1.0.3) ----

// Html.text
size_t text(Tree& t, const std::string& s) {
    size_t sx = str(t, s);
    return t.keep(Elm_Kernel_VirtualDom_text(t[sx]));
}

// VirtualDom.node (with noScript) when `filtered`, else Html.<tag> (raw kernel node).
size_t node(Tree& t, const std::string& tag, const std::vector<size_t>& facts,
            const std::vector<size_t>& kids, bool filtered = false) {
    size_t tg = str(t, tag);
    if (filtered) tg = t.keep(Elm_Kernel_VirtualDom_noScript(t[tg]));
    size_t fl = list(t, facts);
    size_t kl = list(t, kids);
    return t.keep(Elm_Kernel_VirtualDom_node(t[tg], t[fl], t[kl]));
}

size_t nodeNS(Tree& t, const std::string& ns, const std::string& tag,
              const std::vector<size_t>& facts, const std::vector<size_t>& kids) {
    size_t n = str(t, ns);
    size_t tg = str(t, tag);
    size_t fl = list(t, facts);
    size_t kl = list(t, kids);
    return t.keep(Elm_Kernel_VirtualDom_nodeNS(t[n], t[tg], t[fl], t[kl]));
}

// Html.Keyed.node: kids are ( key, node ) pairs.
size_t keyed(Tree& t, const std::string& tag, const std::vector<size_t>& facts,
             const std::vector<std::pair<std::string, size_t>>& kids) {
    std::vector<size_t> pairs;
    for (const auto& kv : kids) {
        size_t k = str(t, kv.first);
        HPointer kh = t.slots[k];
        HPointer nh = t.slots[kv.second];
        pairs.push_back(t.keep(HPtr::fromHPointer(alloc::tuple2(alloc::boxed(kh), alloc::boxed(nh), 0))));
    }
    size_t tg = str(t, tag);
    size_t fl = list(t, facts);
    size_t kl = list(t, pairs);
    return t.keep(Elm_Kernel_VirtualDom_keyedNode(t[tg], t[fl], t[kl]));
}

// VirtualDom.attribute (with its two filters).
size_t attribute(Tree& t, const std::string& k, const std::string& v) {
    size_t kk = str(t, k);
    kk = t.keep(Elm_Kernel_VirtualDom_noOnOrFormAction(t[kk]));
    size_t vv = str(t, v);
    vv = t.keep(Elm_Kernel_VirtualDom_noJavaScriptOrHtmlUri(t[vv]));
    return t.keep(Elm_Kernel_VirtualDom_attribute(t[kk], t[vv]));
}

// VirtualDom.property (with its two filters).
size_t property(Tree& t, const std::string& k, size_t json) {
    size_t kk = str(t, k);
    kk = t.keep(Elm_Kernel_VirtualDom_noInnerHtmlOrFormAction(t[kk]));
    size_t vv = t.keep(Elm_Kernel_VirtualDom_noJavaScriptOrHtmlJson(t[json]));
    return t.keep(Elm_Kernel_VirtualDom_property(t[kk], t[vv]));
}

size_t jsonString(Tree& t, const std::string& s) {
    size_t sx = str(t, s);
    return t.keep(Elm_Kernel_Json_wrap(t[sx]));
}

size_t jsonBool(Tree& t, bool b) {
    return t.keep(Elm_Kernel_Json_wrap(HPtr::fromBits(Ex::encodeBoxedBool(b))));
}

// Html.Attributes.stringProperty / boolProperty (raw kernel property).
size_t stringProperty(Tree& t, const std::string& k, size_t valueStr) {
    size_t kk = str(t, k);
    size_t vv = t.keep(Elm_Kernel_Json_wrap(t[valueStr]));
    return t.keep(Elm_Kernel_VirtualDom_property(t[kk], t[vv]));
}

size_t stringProp(Tree& t, const std::string& k, const std::string& v) {
    return stringProperty(t, k, str(t, v));
}

size_t boolProp(Tree& t, const std::string& k, bool b) {
    size_t kk = str(t, k);
    size_t vv = jsonBool(t, b);
    return t.keep(Elm_Kernel_VirtualDom_property(t[kk], t[vv]));
}

size_t style(Tree& t, const std::string& k, const std::string& v) {
    size_t kk = str(t, k);
    size_t vv = str(t, v);
    return t.keep(Elm_Kernel_VirtualDom_style(t[kk], t[vv]));
}

// Json.Encode.list identity over already-encoded values.
size_t jsonList(Tree& t, const std::vector<size_t>& encoded) {
    size_t f = t.keep(identityClosure());
    size_t arr = t.keep(Elm_Kernel_Json_emptyArray());
    for (size_t e : encoded) arr = t.keep(Elm_Kernel_Json_addEntry(t[f], t[e], t[arr]));
    return arr;
}

Custom* resolveCustom(Tree& t, size_t i) {
    void* p = Ex::toPtr(t.bits(i));
    TEST_ASSERT(p != nullptr);
    TEST_ASSERT(static_cast<Header*>(p)->tag == Tag_Custom);
    return static_cast<Custom*>(p);
}

void expectCustom(Custom* c, u16 ctor, u32 size) {
    TEST_ASSERT(c->ctor == ctor);
    TEST_ASSERT(c->header.size == size);
    for (u32 i = 0; i < size; ++i) TEST_ASSERT(customSlotKind(c, i) == 0);   // all boxed
}

// ---- P0.3: JsonRead mirrors the Json heap forms ----------------------------

void test_jsonread_encoder_forms() {
    initAllocator();
    Tree t;
    size_t s = jsonString(t, "abc");
    JR::View v = JR::view(t.bits(s));
    TEST_ASSERT(v.kind == JR::Kind::String);
    TEST_ASSERT(StringOps::toStdString(v.string) == "abc");

    size_t empty = t.keep(Elm_Kernel_Json_wrap(HPtr::fromHPointer(alloc::emptyString())));
    v = JR::view(t.bits(empty));
    TEST_ASSERT(v.kind == JR::Kind::String);
    TEST_ASSERT(v.string == nullptr);

    v = JR::view(t.bits(jsonBool(t, true)));
    TEST_ASSERT(v.kind == JR::Kind::Bool && v.boolean);
    v = JR::view(t.bits(jsonBool(t, false)));
    TEST_ASSERT(v.kind == JR::Kind::Bool && !v.boolean);

    v = JR::view(Elm_Kernel_Json_wrap_Int(-7).toBits());
    TEST_ASSERT(v.kind == JR::Kind::Number && v.number == -7.0);
    v = JR::view(Elm_Kernel_Json_wrap_Float(2.5).toBits());
    TEST_ASSERT(v.kind == JR::Kind::Number && v.number == 2.5);
    v = JR::view(Elm_Kernel_Json_encodeNull().toBits());
    TEST_ASSERT(v.kind == JR::Kind::Null);
    v = JR::view(Elm_Kernel_Json_emptyObject().toBits());
    TEST_ASSERT(v.kind == JR::Kind::Object);

    // F2: encoder arrays are stored reversed; arrayElements restores the order.
    size_t a = jsonString(t, "a");
    size_t b = t.keep(Elm_Kernel_Json_wrap_Int(2));
    size_t c = jsonBool(t, true);
    size_t arr = jsonList(t, {a, b, c});
    v = JR::view(t.bits(arr));
    TEST_ASSERT(v.kind == JR::Kind::Array);
    std::vector<uint64_t> elems;
    JR::arrayElements(v, elems);
    TEST_ASSERT(elems.size() == 3);
    TEST_ASSERT(JR::view(elems[0]).kind == JR::Kind::String);
    TEST_ASSERT(JR::view(elems[1]).kind == JR::Kind::Number);
    TEST_ASSERT(JR::view(elems[2]).kind == JR::Kind::Bool);
    std::u16string js;
    TEST_ASSERT(JR::jsToString(t.bits(arr), js));
    TEST_ASSERT(js == u"a,2,true");
}

// Decoded (CTOR_JSON_*) forms through Json.Decode.value.
HPtr decodeJson(Tree& t, const std::string& text) {
    size_t s = str(t, text);
    HPtr result = Elm_Kernel_Json_runOnString(Elm_Kernel_Json_decodeValue(), t[s]);
    Custom* r = static_cast<Custom*>(Ex::toPtr(result.toBits()));
    TEST_ASSERT(r != nullptr && r->ctor == 0);   // Ok
    return HPtr::fromHPointer(r->values[0].p);
}

void test_jsonread_decoded_forms() {
    initAllocator();
    Tree t;
    size_t d = t.keep(decodeJson(t, "[1,\"a\",[null,true],{\"k\":1},2.5]"));
    JR::View v = JR::view(t.bits(d));
    TEST_ASSERT(v.kind == JR::Kind::Array);
    std::vector<uint64_t> elems;
    JR::arrayElements(v, elems);
    TEST_ASSERT(elems.size() == 5);
    TEST_ASSERT(JR::view(elems[0]).kind == JR::Kind::Number && JR::view(elems[0]).number == 1.0);
    TEST_ASSERT(JR::view(elems[1]).kind == JR::Kind::String);
    TEST_ASSERT(JR::view(elems[2]).kind == JR::Kind::Array);
    TEST_ASSERT(JR::view(elems[3]).kind == JR::Kind::Object);
    TEST_ASSERT(JR::view(elems[4]).number == 2.5);
    std::u16string js;
    TEST_ASSERT(JR::jsToString(t.bits(d), js));
    TEST_ASSERT(js == u"1,a,,true,[object Object],2.5");

    v = JR::view(decodeJson(t, "null").toBits());
    TEST_ASSERT(v.kind == JR::Kind::Null);
    v = JR::view(decodeJson(t, "false").toBits());
    TEST_ASSERT(v.kind == JR::Kind::Bool && !v.boolean);
    v = JR::view(decodeJson(t, "\"x\"").toBits());
    TEST_ASSERT(v.kind == JR::Kind::String);

    // A long array, so the parser builds CTOR_JSON_ARRAY_CHUNKED.
    std::string big = "[";
    const int n = 200000;
    for (int i = 0; i < n; ++i) {
        if (i) big += ",";
        big += std::to_string(i);
    }
    big += "]";
    size_t bd = t.keep(decodeJson(t, big));
    elems.clear();
    JR::arrayElements(JR::view(t.bits(bd)), elems);
    TEST_ASSERT(elems.size() == static_cast<size_t>(n));
    for (int i = 0; i < n; i += 9973) TEST_ASSERT(JR::view(elems[i]).number == static_cast<double>(i));
    TEST_ASSERT(JR::view(elems[n - 1]).number == static_cast<double>(n - 1));
}

// ---- P0.4: XSS filter truth table (Appendix D.2) ----------------------------

void test_xss_truth_table() {
    for (auto s : {u"script", u"SCRIPT", u"ScRiPt"}) TEST_ASSERT(Xss::isScriptTag(s));
    for (auto s : {u"script ", u"scripts", u"ſcript", u""}) TEST_ASSERT(!Xss::isScriptTag(s));
    for (auto s : {u"onclick", u"ONLOAD", u"on", u"formAction", u"FORMACTION"})
        TEST_ASSERT(Xss::isOnOrFormAction(s));
    for (auto s : {u"x onclick", u"formActions", u"data-on", u"o"}) TEST_ASSERT(!Xss::isOnOrFormAction(s));
    for (auto s : {u"innerHTML", u"outerHTML", u"formAction"}) TEST_ASSERT(Xss::isInnerHtmlOrFormAction(s));
    for (auto s : {u"innerhtml", u"InnerHTML"}) TEST_ASSERT(!Xss::isInnerHtmlOrFormAction(s));

    std::vector<std::u16string> js = {u"javascript:x", u"  JaVaScRiPt:", u"\tjava\tscript:",
                                      u" javascript:", u" j a v a s c r i p t :",
                                      u"　java script:"};
    for (auto& s : js) TEST_ASSERT(Xss::isJavaScriptUri(s));
    for (auto s : {u"javascript", u"java-script:", u"xjavascript:", u"https://x"})
        TEST_ASSERT(!Xss::isJavaScriptUri(s));
    for (auto& s : js) TEST_ASSERT(Xss::isJavaScriptOrHtmlUri(s));
    for (auto s : {u"data:text/html,", u"DATA : text / HTML ;", u"  data:text/html ,x"})
        TEST_ASSERT(Xss::isJavaScriptOrHtmlUri(s));
    for (auto s : {u"data:text/html", u"data:text/plain,", u"data:text/htmlx,"})
        TEST_ASSERT(!Xss::isJavaScriptOrHtmlUri(s));
}

// ---- P2 V4: export-level filters --------------------------------------------

void test_filter_exports() {
    initAllocator();
    Tree t;
    // No match: the input word comes back unchanged.
    size_t div = str(t, "div");
    TEST_ASSERT(Elm_Kernel_VirtualDom_noScript(t[div]).toBits() == t.bits(div));
    size_t scr = str(t, "SCRIPT");
    TEST_ASSERT(utf8Of(Elm_Kernel_VirtualDom_noScript(t[scr]).toBits()) == "p");
    size_t onc = str(t, "onClick");
    TEST_ASSERT(utf8Of(Elm_Kernel_VirtualDom_noOnOrFormAction(t[onc]).toBits()) == "data-onClick");
    size_t ih = str(t, "innerHTML");
    TEST_ASSERT(utf8Of(Elm_Kernel_VirtualDom_noInnerHtmlOrFormAction(t[ih]).toBits()) == "data-innerHTML");
    size_t ok = str(t, "https://x");
    TEST_ASSERT(Elm_Kernel_VirtualDom_noJavaScriptUri(t[ok]).toBits() == t.bits(ok));
    TEST_ASSERT(Elm_Kernel_VirtualDom_noJavaScriptOrHtmlUri(t[ok]).toBits() == t.bits(ok));
    size_t bad = str(t, " javascript:alert(1)");
    TEST_ASSERT(utf8Of(Elm_Kernel_VirtualDom_noJavaScriptUri(t[bad]).toBits()).empty());
    size_t html = str(t, "data:text/html;base64,");
    TEST_ASSERT(utf8Of(Elm_Kernel_VirtualDom_noJavaScriptOrHtmlUri(t[html]).toBits()).empty());
    TEST_ASSERT(Elm_Kernel_VirtualDom_noJavaScriptUri(t[html]).toBits() == t.bits(html));

    // noJavaScriptOrHtmlJson (D.2): matches become Json.Encode.string "".
    auto replaced = [&](size_t value) {
        HPtr r = Elm_Kernel_VirtualDom_noJavaScriptOrHtmlJson(t[value]);
        if (r.toBits() == t.bits(value)) return false;
        JR::View v = JR::view(r.toBits());
        TEST_ASSERT(v.kind == JR::Kind::String && v.string == nullptr);
        return true;
    };
    TEST_ASSERT(replaced(jsonString(t, "javascript:x")));
    TEST_ASSERT(replaced(jsonList(t, {jsonString(t, "javascript:x")})));
    TEST_ASSERT(replaced(jsonList(t, {jsonList(t, {jsonString(t, "data:text/html;")})})));
    TEST_ASSERT(replaced(jsonString(t, std::string(100, ' ') + "javascript:")));
    TEST_ASSERT(!replaced(t.keep(Elm_Kernel_Json_wrap_Int(1))));
    TEST_ASSERT(!replaced(t.keep(Elm_Kernel_Json_emptyObject())));
    TEST_ASSERT(!replaced(jsonList(t, {t.keep(Elm_Kernel_Json_encodeNull()), jsonString(t, "javascript:x")})));
    TEST_ASSERT(!replaced(jsonList(t, {jsonString(t, "java"), jsonString(t, "script:")})));
    TEST_ASSERT(!replaced(jsonString(t, "https://x")));
}

// ---- P2 V1: constructor layout = Http.Dom declaration ----------------------

void test_layout() {
    initAllocator();
    Tree t;
    size_t tx = text(t, "hi");
    Custom* c = resolveCustom(t, tx);
    expectCustom(c, VD::NODE_TEXT, 1);
    TEST_ASSERT(utf8Of(Ex::encode(c->values[VD::TEXT_STRING].p)) == "hi");

    size_t a = attribute(t, "title", "x");
    c = resolveCustom(t, a);
    expectCustom(c, VD::FACT_ATTRIBUTE, 2);
    TEST_ASSERT(utf8Of(Ex::encode(c->values[VD::FACT_KEY].p)) == "title");
    TEST_ASSERT(utf8Of(Ex::encode(c->values[VD::FACT_VALUE].p)) == "x");

    size_t el = node(t, "div", {a}, {tx});
    c = resolveCustom(t, el);
    expectCustom(c, VD::NODE_ELEMENT, 4);
    TEST_ASSERT(Ex::toPtr(Ex::encode(c->values[VD::EL_NS].p)) == nullptr);   // Nothing
    TEST_ASSERT(utf8Of(Ex::encode(c->values[VD::EL_TAG].p)) == "div");

    size_t ns = nodeNS(t, "http://www.w3.org/2000/svg", "svg", {}, {});
    c = resolveCustom(t, ns);
    expectCustom(c, VD::NODE_ELEMENT, 4);
    Custom* just = static_cast<Custom*>(Ex::toPtr(Ex::encode(c->values[VD::EL_NS].p)));
    TEST_ASSERT(just != nullptr && just->ctor == 0 && just->header.size == 1);
    TEST_ASSERT(utf8Of(Ex::encode(just->values[0].p)) == "http://www.w3.org/2000/svg");

    size_t k = keyed(t, "ul", {}, {{"a", tx}});
    expectCustom(resolveCustom(t, k), VD::NODE_KEYED_ELEMENT, 4);

    size_t f = t.keep(identityClosure());
    size_t m = t.keep(Elm_Kernel_VirtualDom_map(t[f], t[el]));
    expectCustom(resolveCustom(t, m), VD::NODE_MAPPED, 2);

    size_t ans = str(t, "http://www.w3.org/1999/xlink");
    size_t ak = str(t, "xlink:href");
    size_t av = str(t, "#a");
    size_t ansF = t.keep(Elm_Kernel_VirtualDom_attributeNS(t[ans], t[ak], t[av]));
    expectCustom(resolveCustom(t, ansF), VD::FACT_ATTRIBUTE_NS, 3);

    expectCustom(resolveCustom(t, stringProp(t, "id", "x")), VD::FACT_PROPERTY, 2);
    expectCustom(resolveCustom(t, style(t, "color", "red")), VD::FACT_STYLE, 2);

    size_t ev = str(t, "click");
    size_t on = t.keep(Elm_Kernel_VirtualDom_on(t[ev], t[f]));
    c = resolveCustom(t, on);
    expectCustom(c, VD::FACT_EVENT, 3);
    TEST_ASSERT(alloc::isNil(c->values[VD::EV_TAGGERS].p));

    // mapAttribute: events get the tagger consed on; other facts pass through.
    size_t g = t.keep(identityClosure());
    size_t mapped = t.keep(Elm_Kernel_VirtualDom_mapAttribute(t[g], t[on]));
    c = resolveCustom(t, mapped);
    expectCustom(c, VD::FACT_EVENT, 3);
    int taggers = 0;
    for (alloc::ListCursor lc(c->values[VD::EV_TAGGERS].p); !lc.done(); lc.next()) ++taggers;
    TEST_ASSERT(taggers == 1);
    TEST_ASSERT(Elm_Kernel_VirtualDom_mapAttribute(t[g], t[a]).toBits() == t.bits(a));
}

// ---- P2 V2: rooting in the two-allocation constructors ----------------------

void test_rooting_under_gc() {
    Allocator& alloc = initAllocatorScaled(0);   // 64 KB nursery
    for (size_t i = 0; i < 4096; i += 7) {
        Tree t;
        size_t ns = str(t, "urn:x");
        size_t tag = str(t, "tag" + std::to_string(i));
        size_t facts = list(t, {attribute(t, "a", "b")});
        size_t kids = list(t, {text(t, "k")});
        size_t kpair = keyed(t, "ul", {}, {{"key", text(t, "kk")}});
        size_t ev = str(t, "click");
        size_t f = t.keep(identityClosure());
        size_t on = t.keep(Elm_Kernel_VirtualDom_on(t[ev], t[f]));
        size_t kkey = str(t, "outer");
        size_t ktup = t.keep(HPtr::fromHPointer(
            alloc::tuple2(alloc::boxed(t.slots[kkey]), alloc::boxed(t.slots[kpair]), 0)));
        size_t ki = list(t, {ktup});

        allocateGarbageInts(alloc, i);
        size_t el = t.keep(Elm_Kernel_VirtualDom_nodeNS(t[ns], t[tag], t[facts], t[kids]));
        allocateGarbageInts(alloc, i);
        size_t kel = t.keep(Elm_Kernel_VirtualDom_keyedNodeNS(t[ns], t[tag], t[facts], t[ki]));
        allocateGarbageInts(alloc, i);
        size_t mapped = t.keep(Elm_Kernel_VirtualDom_mapAttribute(t[f], t[on]));
        allocateGarbageInts(alloc, 3000);

        std::string want = "<tag" + std::to_string(i) + " a=\"b\">k</tag" + std::to_string(i) + ">";
        expectHtml(t, el, want, "nodeNS under GC");
        expectHtml(t, kel,
                   "<tag" + std::to_string(i) + " a=\"b\"><ul>kk</ul></tag" + std::to_string(i) + ">",
                   "keyedNodeNS under GC");
        Custom* c = resolveCustom(t, mapped);
        expectCustom(c, VD::FACT_EVENT, 3);
        TEST_ASSERT(utf8Of(Ex::encode(c->values[VD::EV_NAME].p)) == "click");
    }
}

// ---- P2 V3: lazy evaluates eagerly, with the arguments in order ------------

void test_lazy_eager() {
    initAllocator();
    Tree t;
    std::vector<size_t> args;
    for (int i = 1; i <= 8; ++i) args.push_back(str(t, "a" + std::to_string(i)));
    auto closure = [&](int n, void* fn) { return t.keep(eco_alloc_closure_fn(fn, n, 0)); };
    struct Case { int n; size_t node; };
    std::vector<Case> cases;
    size_t c1 = closure(1, reinterpret_cast<void*>(&lazyEvaluator<1>));
    cases.push_back({1, t.keep(Elm_Kernel_VirtualDom_lazy(t[c1], t[args[0]]))});
    size_t c2 = closure(2, reinterpret_cast<void*>(&lazyEvaluator<2>));
    cases.push_back({2, t.keep(Elm_Kernel_VirtualDom_lazy2(t[c2], t[args[0]], t[args[1]]))});
    size_t c3 = closure(3, reinterpret_cast<void*>(&lazyEvaluator<3>));
    cases.push_back({3, t.keep(Elm_Kernel_VirtualDom_lazy3(t[c3], t[args[0]], t[args[1]], t[args[2]]))});
    size_t c4 = closure(4, reinterpret_cast<void*>(&lazyEvaluator<4>));
    cases.push_back({4, t.keep(Elm_Kernel_VirtualDom_lazy4(t[c4], t[args[0]], t[args[1]], t[args[2]],
                                                           t[args[3]]))});
    size_t c5 = closure(5, reinterpret_cast<void*>(&lazyEvaluator<5>));
    cases.push_back({5, t.keep(Elm_Kernel_VirtualDom_lazy5(t[c5], t[args[0]], t[args[1]], t[args[2]],
                                                           t[args[3]], t[args[4]]))});
    size_t c6 = closure(6, reinterpret_cast<void*>(&lazyEvaluator<6>));
    cases.push_back({6, t.keep(Elm_Kernel_VirtualDom_lazy6(t[c6], t[args[0]], t[args[1]], t[args[2]],
                                                           t[args[3]], t[args[4]], t[args[5]]))});
    size_t c7 = closure(7, reinterpret_cast<void*>(&lazyEvaluator<7>));
    cases.push_back({7, t.keep(Elm_Kernel_VirtualDom_lazy7(t[c7], t[args[0]], t[args[1]], t[args[2]],
                                                           t[args[3]], t[args[4]], t[args[5]],
                                                           t[args[6]]))});
    size_t c8 = closure(8, reinterpret_cast<void*>(&lazyEvaluator<8>));
    cases.push_back({8, t.keep(Elm_Kernel_VirtualDom_lazy8(t[c8], t[args[0]], t[args[1]], t[args[2]],
                                                           t[args[3]], t[args[4]], t[args[5]],
                                                           t[args[6]], t[args[7]]))});
    for (const Case& c : cases) expectHtml(t, c.node, "a" + std::to_string(c.n), "lazy");
}

// ---- P4 V6: serializer goldens (Appendix D.1 cases 1-17, 20-24) -------------

void test_html_goldens() {
    initAllocator();
    Tree t;
    expectHtml(t, text(t, "a<b>&\"'"), "a&lt;b&gt;&amp;&quot;&#039;", "1");
    expectHtml(t, node(t, "div", {}, {}), "<div></div>", "2");
    expectHtml(t,
               node(t, "div", {stringProp(t, "id", "x"), stringProp(t, "className", "a"),
                               stringProp(t, "className", "b")},
                    {text(t, "hi")}),
               "<div id=\"x\" class=\"a b\">hi</div>", "3");
    expectHtml(t, node(t, "div", {stringProp(t, "className", "a"), attribute(t, "class", "b")}, {}),
               "<div class=\"b\"></div>", "4");
    expectHtml(t, node(t, "div", {attribute(t, "class", "b"), stringProp(t, "className", "a")}, {}),
               "<div class=\"a\"></div>", "5");
    expectHtml(t,
               node(t, "input", {stringProp(t, "type", "checkbox"), boolProp(t, "checked", true),
                                 boolProp(t, "disabled", false)},
                    {}),
               "<input type=\"checkbox\" checked>", "6");
    expectHtml(t, node(t, "br", {}, {text(t, "x")}), "<br>", "7");
    expectHtml(t,
               node(t, "div", {style(t, "color", "red"), style(t, "backgroundColor", "blue"),
                               style(t, "color", "green")},
                    {}),
               "<div style=\"color:green;background-color:blue;\"></div>", "8");
    expectHtml(t, node(t, "div", {attribute(t, "style", "margin: 0"), style(t, "color", "red")}, {}),
               "<div style=\"margin: 0;color:red;\"></div>", "9");
    expectHtml(t, node(t, "div", {style(t, "color", "red"), attribute(t, "style", "margin: 0")}, {}),
               "<div style=\"margin: 0\"></div>", "10");
    expectHtml(t, node(t, "style", {}, {text(t, "a > b {}</style><script>")}, true),
               "<style>a > b {}<\\/style><script></style>", "11");
    expectHtml(t, node(t, "script", {}, {text(t, "x")}, true), "<p>x</p>", "12");
    expectHtml(t, node(t, "div", {attribute(t, "onclick", "alert(1)")}, {}),
               "<div data-onclick=\"alert(1)\"></div>", "13");
    auto href = [&](const std::string& url) {
        size_t u = str(t, url);
        u = t.keep(Elm_Kernel_VirtualDom_noJavaScriptUri(t[u]));
        return stringProperty(t, "href", u);
    };
    expectHtml(t, node(t, "a", {href("javascript:alert(1)")}, {text(t, "x")}), "<a href=\"\">x</a>", "14");
    expectHtml(t, node(t, "a", {href("\tjava\tSCRIPT:alert(1)")}, {}), "<a href=\"\"></a>", "15");
    {
        size_t u = str(t, "data:text/html,<b>");
        u = t.keep(Elm_Kernel_VirtualDom_noJavaScriptOrHtmlUri(t[u]));
        expectHtml(t, node(t, "iframe", {stringProperty(t, "src", u)}, {}), "<iframe src=\"\"></iframe>", "16");
    }
    expectHtml(t, node(t, "div", {property(t, "innerHTML", jsonString(t, "<b>"))}, {}), "<div></div>", "17");
    expectHtml(t, node(t, "div onclick=alert(1)", {}, {text(t, "x")}, true), "x", "18");
    expectHtml(t, node(t, "script ", {}, {text(t, "x")}, true), "x", "19");
    expectHtml(t,
               node(t, "div", {attribute(t, "x onclick", "y"), attribute(t, "a=b", "z"),
                               attribute(t, "data-ok", "1")},
                    {}),
               "<div data-ok=\"1\"></div>", "20");
    expectHtml(t, node(t, "my-widget", {attribute(t, "aria-label", "q\"<")}, {}, true),
               "<my-widget aria-label=\"q&quot;&lt;\"></my-widget>", "21");
    expectHtml(t, node(t, "div", {attribute(t, "tabIndex", "1"), attribute(t, "TABINDEX", "2")}, {}),
               "<div tabindex=\"2\"></div>", "22");
    {
        size_t li = node(t, "li", {}, {text(t, "1")});
        size_t ul = keyed(t, "ul", {}, {{"a", li}});
        size_t f = t.keep(identityClosure());
        size_t m = t.keep(Elm_Kernel_VirtualDom_map(t[f], t[ul]));
        expectHtml(t, m, "<ul><li>1</li></ul>", "23");
    }
    expectHtml(t, node(t, "textarea", {stringProp(t, "value", "a<b")}, {text(t, "ignored")}),
               "<textarea>a&lt;b</textarea>", "24");
    // 26 (SVG through nodeNS / attributeNS, E7).
    {
        size_t xns = str(t, "http://www.w3.org/1999/xlink");
        size_t xk = str(t, "xlink:href");
        size_t xv = str(t, "#a");
        size_t xl = t.keep(Elm_Kernel_VirtualDom_attributeNS(t[xns], t[xk], t[xv]));
        size_t use = nodeNS(t, "http://www.w3.org/2000/svg", "use", {xl}, {});
        size_t svg = nodeNS(t, "http://www.w3.org/2000/svg", "svg", {attribute(t, "viewBox", "0 0 10 10")}, {use});
        expectHtml(t, svg, "<svg viewBox=\"0 0 10 10\"><use xlink:href=\"#a\"></use></svg>", "26");
    }
    expectHtml(t, node(t, "div", {stringProperty(t, "title", t.keep(Elm_Kernel_Json_wrap_Int(3)))}, {}),
               "<div title=\"3\"></div>", "29");
}

// ---- P4 V7: totality fuzz ----------------------------------------------------

void test_totality_fuzz() {
    initAllocator();
    // Every breaking character, ASCII letters (both cases), digits, and two
    // non-ASCII characters.
    std::vector<std::string> alphabet = {"\"", "'", "<", ">", "/", "=", " ", "\t", "\n", "\x7f",
                                         "\x01", "&", "-", "_", ":", ";", "\xc3\xa9", "\xe2\x82\xac"};
    for (char c = 'a'; c <= 'z'; ++c) alphabet.push_back(std::string(1, c));
    for (char c = 'A'; c <= 'Z'; ++c) alphabet.push_back(std::string(1, c));
    for (char c = '0'; c <= '9'; ++c) alphabet.push_back(std::string(1, c));
    uint64_t seed = 0x9E3779B97F4A7C15ull;
    auto next = [&]() {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        return seed;
    };
    auto randStr = [&](size_t maxLen) {
        std::string s;
        size_t n = next() % (maxLen + 1);
        for (size_t i = 0; i < n; ++i) s += alphabet[next() % alphabet.size()];
        return s;
    };
    for (int iter = 0; iter < 10000; ++iter) {
        Tree t;
        std::vector<size_t> facts;
        int nf = static_cast<int>(next() % 4);
        for (int i = 0; i < nf; ++i) {
            switch (next() % 4) {
                case 0: facts.push_back(attribute(t, randStr(6), randStr(6))); break;
                case 1: facts.push_back(style(t, randStr(6), randStr(6))); break;
                case 2: facts.push_back(stringProp(t, next() % 2 ? "title" : randStr(6), randStr(6))); break;
                default: facts.push_back(property(t, randStr(4), t.keep(Elm_Kernel_Json_wrap_Float(
                                                                     static_cast<double>(next() % 1000) / 7.0))));
            }
        }
        size_t inner = node(t, randStr(5), facts, {text(t, randStr(8))});
        size_t outer = node(t, randStr(5), {}, {inner});
        std::string out = html(t, outer);
        // No emitted name may contain a breaking character: check every `<name`
        // and ` name=` / ` name` token that the writer produced.
        for (size_t i = 0; i < out.size(); ++i) {
            if (out[i] != '<') continue;
            size_t j = i + 1;
            if (j < out.size() && out[j] == '/') ++j;
            while (j < out.size() && out[j] != '>' && out[j] != ' ') {
                unsigned char c = static_cast<unsigned char>(out[j]);
                TEST_ASSERT(!(c <= 0x20 || c == 0x7F || c == '"' || c == '\'' || c == '<' || c == '/'));
                ++j;
            }
        }
    }
}

// ---- P2 V5: raw pointers to static string literals (R3) ---------------------
//
// Export::toPtr accepts a word that is a raw pointer outside the heap (a global
// string literal) as well as a heap HPointer. Compiled code now interns
// literals as permanent heap objects, but the kernels must not depend on that:
// they read every string through toPtr. The values built here are checked
// before any collection can run (a GC traces only heap and permanent objects).

struct StaticString {
    alignas(8) Header header;
    u16 chars[16];
};

HPtr staticString(StaticString& s, const char* ascii) {
    std::memset(&s, 0, sizeof(s));
    s.header.tag = Tag_String;
    u32 n = 0;
    for (; ascii[n] != '\0' && n < 16; ++n) s.chars[n] = static_cast<u16>(ascii[n]);
    s.header.size = n;
    return HPtr::fromBits(reinterpret_cast<uint64_t>(&s));
}

void test_raw_literal_arguments() {
    initAllocator();
    static StaticString tagLit, keyLit, valueLit, textLit, scriptLit, onLit, jsLit;
    HPtr tag = staticString(tagLit, "section");
    HPtr key = staticString(keyLit, "title");
    HPtr value = staticString(valueLit, "a<b");
    HPtr txt = staticString(textLit, "hi&");
    TEST_ASSERT(!Allocator::instance().isInHeap(&tagLit));
    TEST_ASSERT(Ex::toPtr(tag.toBits()) == &tagLit);

    // Filters read the literal and either return it unchanged or a new string.
    TEST_ASSERT(Elm_Kernel_VirtualDom_noScript(tag).toBits() == tag.toBits());
    TEST_ASSERT(utf8Of(Elm_Kernel_VirtualDom_noScript(staticString(scriptLit, "SCRIPT")).toBits()) == "p");
    TEST_ASSERT(utf8Of(Elm_Kernel_VirtualDom_noOnOrFormAction(staticString(onLit, "onload")).toBits()) ==
                "data-onload");
    TEST_ASSERT(utf8Of(Elm_Kernel_VirtualDom_noJavaScriptUri(staticString(jsLit, "javascript")).toBits()) ==
                "javascript");

    // Constructors store the words as given; the writer reads them back.
    Tree t;
    size_t attr = t.keep(Elm_Kernel_VirtualDom_attribute(key, value));
    size_t kid = t.keep(Elm_Kernel_VirtualDom_text(txt));
    size_t facts = list(t, {attr});
    size_t kids = list(t, {kid});
    size_t el = t.keep(Elm_Kernel_VirtualDom_node(tag, t[facts], t[kids]));
    expectHtml(t, el, "<section title=\"a&lt;b\">hi&amp;</section>", "raw literals");
}

// ---- P4 V8: a lone surrogate is written in its 3-byte form ------------------

void test_lone_surrogate() {
    initAllocator();
    Tree t;
    std::u16string s = u"a";
    s.push_back(static_cast<char16_t>(0xD800));
    s.push_back(u'b');
    size_t sx = u16str(t, s);
    size_t tx = t.keep(Elm_Kernel_VirtualDom_text(t[sx]));
    TEST_ASSERT(html(t, tx) == std::string("a\xED\xA0\x80" "b"));
}

}  // namespace

void registerVirtualDomKernelTests(Testing::TestSuite& suite) {
    suite.add(Testing::UnitTest("VirtualDomKernel J1 JsonRead encoder forms", test_jsonread_encoder_forms));
    suite.add(Testing::UnitTest("VirtualDomKernel J2 JsonRead decoded forms", test_jsonread_decoded_forms));
    suite.add(Testing::UnitTest("VirtualDomKernel X1 XSS truth table", test_xss_truth_table));
    suite.add(Testing::UnitTest("VirtualDomKernel V1 layout", test_layout));
    suite.add(Testing::UnitTest("VirtualDomKernel V2 rooting under GC", test_rooting_under_gc));
    suite.add(Testing::UnitTest("VirtualDomKernel V3 lazy eager", test_lazy_eager));
    suite.add(Testing::UnitTest("VirtualDomKernel V4 filter exports", test_filter_exports));
    suite.add(Testing::UnitTest("VirtualDomKernel V5 raw literal arguments", test_raw_literal_arguments));
    suite.add(Testing::UnitTest("VirtualDomKernel V6 html goldens", test_html_goldens));
    suite.add(Testing::UnitTest("VirtualDomKernel V7 totality fuzz", test_totality_fuzz));
    suite.add(Testing::UnitTest("VirtualDomKernel V8 lone surrogate", test_lone_surrogate));
}
