//===- HtmlWriter.cpp - HTML serialization of native VirtualDom values ------===//
//
// plans/elm-html-native-kernel.md §8. A line-by-line mirror of the Elm
// reference `Http.Dom.render` (system-kernel-cpp/src/Http/Dom.elm), with the
// same function names; the two must produce byte-identical output (VDOM_005,
// DomDifferentialTest). Keep them in step.
//
// R8 / VDOM_004: nothing here allocates on the Eco heap or calls Elm code, so
// every resolved object stays where it is for the whole walk. All state lives
// in std:: containers. Total (D17): any input produces some output and nothing
// asserts, throws (other than std::bad_alloc) or recurses with the tree size.
//
//===----------------------------------------------------------------------===//

#include "HtmlWriter.hpp"
#include "VirtualDomLayout.hpp"
#include "../ExportHelpers.hpp"
#include "../json/JsonRead.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/StringOps.hpp"

#include <optional>
#include <utility>
#include <vector>

namespace Elm::Kernel::VirtualDom {

namespace {

using Pairs = std::vector<std::pair<std::string, std::string>>;
using AttrList = std::vector<std::pair<std::string, std::optional<std::string>>>;

//===----------------------------------------------------------------------===//
// Heap reading (R3: always through Export::toPtr)
//===----------------------------------------------------------------------===//

// The Custom object behind `bits`, or nullptr for a constant or a non-Custom.
Custom* asCustom(uint64_t bits) {
    void* p = Export::toPtr(bits);
    if (p == nullptr || static_cast<Header*>(p)->tag != Tag_Custom) return nullptr;
    return static_cast<Custom*>(p);
}

uint64_t field(Custom* c, u32 i) {
    if (i >= c->header.size) return Export::encode(alloc::nothing());
    return Export::encode(c->values[i].p);
}

std::string str(uint64_t bits) {
    return StringOps::toStdString(Export::toPtr(bits));
}

// `Nothing` -> nullopt; `Just s` -> s.
std::optional<std::string> maybeStr(uint64_t bits) {
    Custom* j = asCustom(bits);
    if (j == nullptr) return std::nullopt;
    return str(field(j, 0));
}

//===----------------------------------------------------------------------===//
// Text helpers
//===----------------------------------------------------------------------===//

bool breaksToken(bool isAttribute, unsigned char c) {
    return c <= 0x20 || c == 0x7F || c == '"' || c == '\'' || c == '<' || c == '>' || c == '/' ||
           (isAttribute && c == '=');
}

bool isTokenBreaking(bool isAttribute, const std::string& name) {
    if (name.empty()) return true;
    for (unsigned char c : name)
        if (breaksToken(isAttribute, c)) return true;
    return false;
}

bool isUpper(char c) { return c >= 'A' && c <= 'Z'; }

char lowerChar(char c) { return isUpper(c) ? static_cast<char>(c + 32) : c; }

std::string asciiLower(const std::string& s) {
    std::string r = s;
    for (char& c : r) c = lowerChar(c);
    return r;
}

bool startsWith(const std::string& s, const char* prefix) {
    return s.rfind(prefix, 0) == 0;
}

std::string cssName(const std::string& key) {
    bool anyUpper = false;
    for (char c : key)
        if (isUpper(c)) anyUpper = true;
    if (key.find('-') != std::string::npos || !anyUpper) return key;
    if (key == "cssFloat") return "float";
    std::string kebab;
    for (char c : key) {
        if (isUpper(c)) {
            kebab.push_back('-');
            kebab.push_back(lowerChar(c));
        } else {
            kebab.push_back(c);
        }
    }
    for (const char* p : {"webkit-", "moz-", "ms-", "o-"})
        if (startsWith(kebab, p)) return "-" + kebab;
    return kebab;
}

void escapeText(const std::string& s, std::string& out) {
    for (char c : s) {
        switch (c) {
            case '&': out += "&amp;"; break;
            case '<': out += "&lt;"; break;
            case '>': out += "&gt;"; break;
            case '"': out += "&quot;"; break;
            case '\'': out += "&#039;"; break;
            default: out.push_back(c);
        }
    }
}

void escapeAttr(const std::string& s, std::string& out) {
    for (char c : s) {
        switch (c) {
            case '&': out += "&amp;"; break;
            case '"': out += "&quot;"; break;
            case '<': out += "&lt;"; break;
            case '>': out += "&gt;"; break;
            default: out.push_back(c);
        }
    }
}

void rawText(const std::string& s, std::string& out) {
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '<' && i + 1 < s.size() && s[i + 1] == '/') {
            out += "<\\/";
            ++i;
        } else {
            out.push_back(s[i]);
        }
    }
}

//===----------------------------------------------------------------------===//
// Property values
//===----------------------------------------------------------------------===//

struct PropValue {
    enum Kind { PString, PBool, PNumber, PNull, PCompound } kind = PNull;
    std::string s;
    bool b = false;
    double f = 0.0;
};

PropValue propValue(uint64_t json) {
    JsonRead::View v = JsonRead::view(json);
    PropValue p;
    switch (v.kind) {
        case JsonRead::Kind::String:
            p.kind = PropValue::PString;
            p.s = StringOps::toStdString(v.string);
            break;
        case JsonRead::Kind::Bool:
            p.kind = PropValue::PBool;
            p.b = v.boolean;
            break;
        case JsonRead::Kind::Number:
            p.kind = PropValue::PNumber;
            p.f = v.number;
            break;
        case JsonRead::Kind::Null:
            p.kind = PropValue::PNull;
            break;
        case JsonRead::Kind::Array:
        case JsonRead::Kind::Object:
            p.kind = PropValue::PCompound;
            break;
    }
    return p;
}

std::optional<std::string> jsString(const PropValue& v) {
    switch (v.kind) {
        case PropValue::PString: return v.s;
        case PropValue::PBool: return std::string(v.b ? "true" : "false");
        case PropValue::PNumber: {
            char buf[32];
            size_t n = StringOps::formatFloatShortest(v.f, buf);
            return std::string(buf, n);
        }
        case PropValue::PNull: return std::string("null");
        case PropValue::PCompound: return std::nullopt;
    }
    return std::nullopt;
}

bool truthy(const PropValue& v) {
    switch (v.kind) {
        case PropValue::PString: return !v.s.empty();
        case PropValue::PBool: return v.b;
        case PropValue::PNumber: return v.f != 0 && v.f == v.f;   // not 0, not NaN
        case PropValue::PNull: return false;
        case PropValue::PCompound: return true;
    }
    return false;
}

std::string jsStringOrEmpty(const PropValue& v) {
    std::optional<std::string> s = jsString(v);
    return s ? *s : std::string();
}

//===----------------------------------------------------------------------===//
// Organize helpers
//===----------------------------------------------------------------------===//

template <typename V>
const V* lookup(const std::string& key, const std::vector<std::pair<std::string, V>>& entries) {
    for (const auto& e : entries)
        if (e.first == key) return &e.second;
    return nullptr;
}

template <typename V>
void upsert(const std::string& key, V value, std::vector<std::pair<std::string, V>>& entries) {
    for (auto& e : entries) {
        if (e.first == key) {
            e.second = std::move(value);
            return;
        }
    }
    entries.emplace_back(key, std::move(value));
}

std::string joinClass(const std::string& old, const std::string& neu) {
    if (old.empty()) return neu;
    return old + " " + neu;
}

struct Slot {
    enum Kind { StyleSlot, AttrSlot, AttrNSSlot, PropSlot } kind;
    std::string key;     // PropSlot only
    PropValue value;     // PropSlot only
};

void addSlot(Slot::Kind kind, std::vector<Slot>& slots) {
    for (const Slot& s : slots)
        if (s.kind == kind) return;
    slots.push_back(Slot{kind, {}, {}});
}

void upsertProp(const std::string& key, const PropValue& value, std::vector<Slot>& slots) {
    for (Slot& s : slots) {
        if (s.kind == Slot::PropSlot && s.key == key) {
            // mergePropSlot
            if (key == "className") {
                PropValue joined;
                joined.kind = PropValue::PString;
                joined.s = joinClass(jsStringOrEmpty(s.value), jsStringOrEmpty(value));
                s.value = joined;
            } else {
                s.value = value;
            }
            return;
        }
    }
    slots.push_back(Slot{Slot::PropSlot, key, value});
}

//===----------------------------------------------------------------------===//
// Resolve: _VirtualDom_organizeFacts followed by _VirtualDom_applyFacts (§8.5)
//===----------------------------------------------------------------------===//

struct Organized {
    std::vector<Slot> slots;
    Pairs styles;
    Pairs attrs;
    Pairs attrsNS;
};

struct Applied {
    AttrList attrs;
    std::string styleRaw;
    Pairs styleProps;
    std::optional<std::string> textareaValue;
};

struct Resolved {
    AttrList attrs;
    std::optional<std::string> textareaValue;
};

enum class ReflectKind { AsString, AsBool, AsValue, NoReflect };

struct Reflect {
    ReflectKind kind;
    const char* name;
};

Reflect reflection(const std::string& key) {
    static const std::pair<const char*, const char*> renamedString[] = {
        {"className", "class"},        {"htmlFor", "for"},         {"httpEquiv", "http-equiv"},
        {"acceptCharset", "accept-charset"}, {"accessKey", "accesskey"}, {"useMap", "usemap"},
        {"contentEditable", "contenteditable"}, {"spellcheck", "spellcheck"}};
    static const std::pair<const char*, const char*> renamedBool[] = {
        {"isMap", "ismap"}, {"noValidate", "novalidate"}, {"readOnly", "readonly"}};
    static const char* sameNameString[] = {
        "accept", "action", "align", "alt", "autocomplete", "cite", "coords", "dir", "download",
        "dropzone", "enctype", "headers", "href", "hreflang", "id", "kind", "label", "lang", "max",
        "method", "min", "name", "pattern", "ping", "placeholder", "poster", "preload", "sandbox",
        "scope", "shape", "span", "src", "srcdoc", "srclang", "start", "step", "target", "title",
        "type", "wrap"};
    static const char* sameNameBool[] = {
        "autofocus", "autoplay", "checked", "controls", "default", "disabled", "hidden", "loop",
        "multiple", "required", "reversed", "selected"};

    for (const auto& r : renamedString)
        if (key == r.first) return {ReflectKind::AsString, r.second};
    for (const auto& r : renamedBool)
        if (key == r.first) return {ReflectKind::AsBool, r.second};
    if (key == "value") return {ReflectKind::AsValue, nullptr};
    for (const char* n : sameNameString)
        if (key == n) return {ReflectKind::AsString, n};
    for (const char* n : sameNameBool)
        if (key == n) return {ReflectKind::AsBool, n};
    return {ReflectKind::NoReflect, nullptr};
}

void organizeFact(uint64_t factBits, Organized& o) {
    Custom* f = asCustom(factBits);
    if (f == nullptr) return;
    switch (f->ctor) {
        case FACT_ATTRIBUTE: {
            std::string k = str(field(f, FACT_KEY));
            std::string v = str(field(f, FACT_VALUE));
            addSlot(Slot::AttrSlot, o.slots);
            const std::string* old = (k == "class") ? lookup(k, o.attrs) : nullptr;
            if (old != nullptr) upsert(k, joinClass(*old, v), o.attrs);
            else upsert(k, v, o.attrs);
            return;
        }
        case FACT_ATTRIBUTE_NS:
            addSlot(Slot::AttrNSSlot, o.slots);
            upsert(str(field(f, NS_KEY)), str(field(f, NS_VALUE)), o.attrsNS);
            return;
        case FACT_STYLE:
            addSlot(Slot::StyleSlot, o.slots);
            upsert(str(field(f, FACT_KEY)), str(field(f, FACT_VALUE)), o.styles);
            return;
        case FACT_PROPERTY:
            upsertProp(str(field(f, FACT_KEY)), propValue(field(f, FACT_VALUE)), o.slots);
            return;
        default:
            return;   // FACT_EVENT and anything unknown
    }
}

void setAttr(const std::string& name, std::optional<std::string> value, Applied& st) {
    if (isTokenBreaking(true, name)) return;
    if (name == "style") {
        upsert(std::string("style"), std::optional<std::string>(), st.attrs);
        st.styleRaw = value ? *value : std::string();
        st.styleProps.clear();
        return;
    }
    upsert(name, std::move(value), st.attrs);
}

void removeAttr(const std::string& name, Applied& st) {
    AttrList kept;
    for (auto& e : st.attrs)
        if (e.first != name) kept.push_back(std::move(e));
    st.attrs = std::move(kept);
}

void setStyle(const std::string& key, const std::string& value, Applied& st) {
    std::string name = cssName(key);
    if (value.empty()) {
        Pairs kept;
        for (auto& e : st.styleProps)
            if (e.first != name) kept.push_back(std::move(e));
        st.styleProps = std::move(kept);
        return;
    }
    upsert(name, value, st.styleProps);
    if (lookup(std::string("style"), st.attrs) == nullptr)
        st.attrs.emplace_back("style", std::nullopt);
}

void setString(const std::string& name, const PropValue& value, Applied& st) {
    std::optional<std::string> s = jsString(value);
    if (s) setAttr(name, std::move(s), st);
}

void reflectProp(const std::string& lowerTag, const std::string& key, const PropValue& value,
                 Applied& st) {
    Reflect r = reflection(key);
    switch (r.kind) {
        case ReflectKind::AsString:
            setString(r.name, value, st);
            return;
        case ReflectKind::AsBool:
            if (truthy(value)) setAttr(r.name, std::nullopt, st);
            else removeAttr(r.name, st);
            return;
        case ReflectKind::AsValue:
            if (lowerTag == "textarea") st.textareaValue = jsString(value);
            else if (lowerTag == "select") return;
            else setString("value", value, st);
            return;
        case ReflectKind::NoReflect:
            return;
    }
}

void applySlot(bool isHtml, const std::string& lowerTag, const Organized& o, const Slot& slot,
               Applied& st) {
    switch (slot.kind) {
        case Slot::StyleSlot:
            for (const auto& e : o.styles) setStyle(e.first, e.second, st);
            return;
        case Slot::AttrSlot:
            for (const auto& e : o.attrs) setAttr(isHtml ? asciiLower(e.first) : e.first, e.second, st);
            return;
        case Slot::AttrNSSlot:
            for (const auto& e : o.attrsNS) setAttr(e.first, e.second, st);
            return;
        case Slot::PropSlot:
            reflectProp(lowerTag, slot.key, slot.value, st);
            return;
    }
}

std::pair<std::string, std::optional<std::string>>
finishStyle(const Applied& st, const std::pair<std::string, std::optional<std::string>>& attr) {
    if (attr.first != "style") return attr;
    std::string props;
    for (const auto& e : st.styleProps) props += e.first + ":" + e.second + ";";
    if (props.empty() || st.styleRaw.empty() || st.styleRaw.back() == ';')
        return {attr.first, st.styleRaw + props};
    return {attr.first, st.styleRaw + ";" + props};
}

Resolved resolve(bool isHtml, const std::string& lowerTag, uint64_t facts) {
    Organized organized;
    for (alloc::ListCursor c(Export::decode(facts)); !c.done(); c.next())
        organizeFact(Export::encode(c.current().p), organized);
    Applied applied;
    for (const Slot& slot : organized.slots) applySlot(isHtml, lowerTag, organized, slot, applied);
    Resolved r;
    r.attrs.reserve(applied.attrs.size());
    for (const auto& a : applied.attrs) r.attrs.push_back(finishStyle(applied, a));
    r.textareaValue = applied.textareaValue;
    return r;
}

//===----------------------------------------------------------------------===//
// Render
//===----------------------------------------------------------------------===//

bool isVoidElement(const std::string& lowerTag) {
    static const char* voids[] = {"area", "base", "br", "col", "embed", "hr", "img",
                                  "input", "link", "meta", "source", "track", "wbr"};
    for (const char* v : voids)
        if (lowerTag == v) return true;
    return false;
}

void renderAttrs(const AttrList& attrs, std::string& out) {
    for (const auto& a : attrs) {
        out.push_back(' ');
        out += a.first;
        if (a.second) {
            out += "=\"";
            escapeAttr(*a.second, out);
            out.push_back('"');
        }
    }
}

// One work item: Visit raw node, or Emit text.
struct Work {
    bool emit;
    bool raw;
    uint64_t node;
    std::string text;
};

void pushVisits(std::vector<Work>& work, bool raw, const std::vector<uint64_t>& kids) {
    // Reverse, so the first kid is visited first.
    for (size_t i = kids.size(); i-- > 0;) work.push_back(Work{false, raw, kids[i], {}});
}

// Elements and keyed elements; `keyed` kids are ( key, node ) tuples.
void expand(Custom* el, bool keyed, std::vector<Work>& work, std::string& out) {
    std::optional<std::string> ns = maybeStr(field(el, EL_NS));
    std::string tag = str(field(el, EL_TAG));
    std::vector<uint64_t> kids;
    for (alloc::ListCursor c(Export::decode(field(el, EL_KIDS))); !c.done(); c.next()) {
        uint64_t kid = Export::encode(c.current().p);
        if (keyed) {
            void* t = Export::toPtr(kid);
            if (t == nullptr || static_cast<Header*>(t)->tag != Tag_Tuple2) continue;
            kid = Export::encode(static_cast<Tuple2*>(t)->b.p);
        }
        kids.push_back(kid);
    }

    if (isTokenBreaking(false, tag)) {   // D17: unwrap
        pushVisits(work, false, kids);
        return;
    }
    std::string lowerTag = asciiLower(tag);
    bool isHtml = !ns.has_value();
    Resolved resolved = resolve(isHtml, lowerTag, field(el, EL_FACTS));

    out.push_back('<');
    out += tag;
    renderAttrs(resolved.attrs, out);
    out.push_back('>');

    if (isHtml && isVoidElement(lowerTag)) return;
    if (isHtml && lowerTag == "textarea" && resolved.textareaValue) {
        escapeText(*resolved.textareaValue, out);
        out += "</" + tag + ">";
        return;
    }
    work.push_back(Work{true, false, 0, "</" + tag + ">"});
    pushVisits(work, isHtml && lowerTag == "style", kids);
}

} // namespace

void writeHtml(uint64_t nodeBits, std::string& out) {
    std::vector<Work> work;
    work.push_back(Work{false, false, nodeBits, {}});
    while (!work.empty()) {
        Work w = std::move(work.back());
        work.pop_back();
        if (w.emit) {
            out += w.text;
            continue;
        }
        Custom* n = asCustom(w.node);
        if (n == nullptr) continue;   // total: not a node, nothing to write
        switch (n->ctor) {
            case NODE_TEXT:
                if (w.raw) rawText(str(field(n, TEXT_STRING)), out);
                else escapeText(str(field(n, TEXT_STRING)), out);
                break;
            case NODE_MAPPED:
                work.push_back(Work{false, w.raw, field(n, MAPPED_NODE), {}});
                break;
            case NODE_ELEMENT:
                expand(n, false, work, out);
                break;
            case NODE_KEYED_ELEMENT:
                expand(n, true, work, out);
                break;
            default:
                break;
        }
    }
}

} // namespace Elm::Kernel::VirtualDom
