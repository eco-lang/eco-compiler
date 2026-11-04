//===- HtmlWriter.cpp - HTML serialization of native VirtualDom values ------===//
//
// This file mirrors the Elm serializer in `Html.Dom` (system-kernel-cpp/src/Html/Dom.elm)
// function by function, and many helpers carry the same names. The two must produce
// byte-identical output (invariant VDOM_005), so a change to one is made to the other.
//
// An element is written in two steps. Its facts (attributes, namespaced attributes, styles and
// properties) are first resolved, the way the browser runtime's organize-then-apply would set
// them on a live element, into the ordered list of attributes its opening tag carries. Then the
// tag, those attributes and the children are written. Children are pushed onto a work stack
// with a closing-tag item beneath them, so the walk never recurses.
//
// Nothing here allocates on the Eco heap or calls Elm code (invariant VDOM_004), so the raw
// pointers it takes into heap objects stay valid for the whole walk. All of its own state lives
// in std:: containers.
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

// Attribute name/value pairs, in output order.
using Pairs = std::vector<std::pair<std::string, std::string>>;
// Attribute names in output order, each with its value; `nullopt` writes the name without a value.
using AttrList = std::vector<std::pair<std::string, std::optional<std::string>>>;

//===----------------------------------------------------------------------===//
// Heap reading. Every word is decoded with `Export::toPtr`, because a word may be an embedded
// constant or a raw pointer to a literal outside the heap.
//===----------------------------------------------------------------------===//

// Returns the `Custom` object behind `bits`, or nullptr for a constant or an object of another kind.
Custom* asCustom(uint64_t bits) {
    void* p = Export::toPtr(bits);
    if (p == nullptr || static_cast<Header*>(p)->tag != Tag_Custom) return nullptr;
    return static_cast<Custom*>(p);
}

// Returns field `i` of `c` as an encoded word, or the `Nothing` constant if `c` has no such field.
uint64_t field(Custom* c, u32 i) {
    if (i >= c->header.size) return Export::encode(alloc::nothing());
    return Export::encode(c->values[i].p);
}

// Returns the Elm string `bits` as UTF-8, or the empty string for a constant. `bits` must be a
// string or a constant; nothing here checks the kind of another object.
std::string str(uint64_t bits) {
    return StringOps::toStdString(Export::toPtr(bits));
}

// Returns `s` for `Just s`, and nullopt for `Nothing` or anything else that is not a `Custom`.
std::optional<std::string> maybeStr(uint64_t bits) {
    Custom* j = asCustom(bits);
    if (j == nullptr) return std::nullopt;
    return str(field(j, 0));
}

//===----------------------------------------------------------------------===//
// Text helpers
//===----------------------------------------------------------------------===//

// Returns whether byte `c` cannot appear in a tag name, or in an attribute name when
// `isAttribute` is set: whitespace, controls, DEL, quotes, `<`, `>`, `/`, and for attributes `=`.
bool breaksToken(bool isAttribute, unsigned char c) {
    return c <= 0x20 || c == 0x7F || c == '"' || c == '\'' || c == '<' || c == '>' || c == '/' ||
           (isAttribute && c == '=');
}

// Returns whether `name` is empty or contains a byte that `breaksToken` rejects.
bool isTokenBreaking(bool isAttribute, const std::string& name) {
    if (name.empty()) return true;
    for (unsigned char c : name)
        if (breaksToken(isAttribute, c)) return true;
    return false;
}

// Returns whether `c` is an ASCII capital letter.
bool isUpper(char c) { return c >= 'A' && c <= 'Z'; }

// Returns `c` in lower case if it is an ASCII capital letter, and `c` otherwise.
char lowerChar(char c) { return isUpper(c) ? static_cast<char>(c + 32) : c; }

// Returns `s` with its ASCII capital letters lowered; other bytes are unchanged.
std::string asciiLower(const std::string& s) {
    std::string r = s;
    for (char& c : r) c = lowerChar(c);
    return r;
}

// Returns whether `s` begins with `prefix`.
bool startsWith(const std::string& s, const char* prefix) {
    return s.rfind(prefix, 0) == 0;
}

// Returns the CSS property name for style key `key`. A key that contains `-` or no capital letter
// is returned unchanged, `cssFloat` becomes `float`, and any other camelCase key becomes kebab
// case, with a leading `-` added when it then starts with a vendor prefix (`webkit-`, `moz-`,
// `ms-`, `o-`).
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

// Appends `s` to `out` as HTML text content, escaping `&`, `<`, `>`, `"` and `'`.
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

// Appends `s` to `out` as a double-quoted attribute value, escaping `&`, `"`, `<` and `>` but not
// `'`, unlike `escapeText`.
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

// Appends `s` to `out` unescaped, as the content of a `style` element, except that each `</`
// becomes `<\/` so that the text cannot close the element.
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

// A property's JSON value, reduced to what reflecting it into an attribute needs. `s` is meaningful
// only for `PString`, `b` only for `PBool` and `f` only for `PNumber`; an array or object is
// `PCompound` and keeps no content.
struct PropValue {
    enum Kind { PString, PBool, PNumber, PNull, PCompound } kind = PNull;
    std::string s;
    bool b = false;
    double f = 0.0;
};

// Returns the `PropValue` of the encoded `Json.Value` word `json`.
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

// Returns `v` as JavaScript's `String(v)` would give it for a scalar, with numbers in shortest
// round-trip form, or nullopt for an array or object.
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

// Returns whether `v` is truthy in JavaScript's sense. An array or object is always truthy.
bool truthy(const PropValue& v) {
    switch (v.kind) {
        case PropValue::PString: return !v.s.empty();
        case PropValue::PBool: return v.b;
        case PropValue::PNumber: return v.f != 0 && v.f == v.f;   // NaN is not equal to itself
        case PropValue::PNull: return false;
        case PropValue::PCompound: return true;
    }
    return false;
}

// Returns `jsString(v)`, or the empty string for an array or object.
std::string jsStringOrEmpty(const PropValue& v) {
    std::optional<std::string> s = jsString(v);
    return s ? *s : std::string();
}

//===----------------------------------------------------------------------===//
// Organize helpers
//===----------------------------------------------------------------------===//

// Returns the value of the first entry keyed `key`, or nullptr if there is none. The pointer is
// valid until `entries` is next changed.
template <typename V>
const V* lookup(const std::string& key, const std::vector<std::pair<std::string, V>>& entries) {
    for (const auto& e : entries)
        if (e.first == key) return &e.second;
    return nullptr;
}

// Replaces the value of the first entry keyed `key` with `value`, or appends a new entry at the
// end if there is none, so entries keep the order their keys were first seen in.
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

// Returns the class lists `old` and `neu` joined by a space, or `neu` alone if `old` is empty.
std::string joinClass(const std::string& old, const std::string& neu) {
    if (old.empty()) return neu;
    return old + " " + neu;
}

// One step of applying an element's facts, in the order its first fact of that kind was seen.
// There is at most one slot each for styles, attributes and namespaced attributes, which apply
// the whole collected group, and one per distinct property key.
struct Slot {
    enum Kind { StyleSlot, AttrSlot, AttrNSSlot, PropSlot } kind;
    std::string key;     // PropSlot only
    PropValue value;     // PropSlot only
};

// Appends a slot of `kind` to `slots`, unless one is already there.
void addSlot(Slot::Kind kind, std::vector<Slot>& slots) {
    for (const Slot& s : slots)
        if (s.kind == kind) return;
    slots.push_back(Slot{kind, {}, {}});
}

// Records property `key` = `value` in its slot, appending the slot if it is new. A repeated
// `className` is joined to the earlier value with a space; any other repeated key replaces it.
void upsertProp(const std::string& key, const PropValue& value, std::vector<Slot>& slots) {
    for (Slot& s : slots) {
        if (s.kind == Slot::PropSlot && s.key == key) {
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
// Resolve: the facts of one element are organized, which groups them into slots, and then
// applied, which sets attributes in slot order as a live element would be set.
//===----------------------------------------------------------------------===//

// The facts of one element, grouped by kind, with the slots that fix the order they apply in.
struct Organized {
    std::vector<Slot> slots;
    Pairs styles;
    Pairs attrs;
    Pairs attrsNS;
};

// The attributes of one element as applying its slots sets them. A `style` entry in `attrs` holds
// no value; its text is `styleRaw`, from a `style` attribute, followed by `styleProps`. A value
// of nullopt in `attrs` is an attribute written without a value.
struct Applied {
    AttrList attrs;
    std::string styleRaw;
    Pairs styleProps;
    std::optional<std::string> textareaValue;
};

// The final attributes of an element's opening tag, in order, with the `value` property of a
// `textarea`, which becomes its content instead of an attribute.
struct Resolved {
    AttrList attrs;
    std::optional<std::string> textareaValue;
};

// How a property is reflected into an attribute: as its string form, as an attribute present
// only when the value is truthy, by the special rules for `value`, or not at all.
enum class ReflectKind { AsString, AsBool, AsValue, NoReflect };

// The reflection of one property. `name` is the attribute name, and is null for `AsValue` and
// `NoReflect`; it points to a string literal.
struct Reflect {
    ReflectKind kind;
    const char* name;
};

// Returns how property `key` is reflected into an attribute, from a fixed table of HTML properties.
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

// Adds the fact `factBits` to `o`. A repeated attribute replaces the earlier one, except `class`,
// which is joined to it. Events, and words that are not facts, are ignored.
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

// Sets attribute `name` to `value`, ignoring a name that breaks a token. Setting `style` replaces
// the style text and clears the style properties collected so far.
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

// Removes every attribute named `name`.
void removeAttr(const std::string& name, Applied& st) {
    AttrList kept;
    for (auto& e : st.attrs)
        if (e.first != name) kept.push_back(std::move(e));
    st.attrs = std::move(kept);
}

// Sets style property `key` to `value`, or removes it when `value` is empty. Setting one adds a
// valueless `style` attribute if there is none yet.
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

// Sets attribute `name` to the string form of `value`, or does nothing for an array or object.
void setString(const std::string& name, const PropValue& value, Applied& st) {
    std::optional<std::string> s = jsString(value);
    if (s) setAttr(name, std::move(s), st);
}

// Applies property `key` = `value` to `st` as its reflection says. `value` on a `textarea` becomes
// its content, on a `select` is dropped, and elsewhere becomes the `value` attribute.
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

// Applies one slot of `o` to `st`. When `isHtml` is set (the element has no namespace), plain
// attribute names are lowered.
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

// Returns `attr` unchanged unless it is `style`, whose value becomes the raw style text followed by
// the style properties as `name:value;`, with a `;` between them when the text lacks one.
std::pair<std::string, std::optional<std::string>>
finishStyle(const Applied& st, const std::pair<std::string, std::optional<std::string>>& attr) {
    if (attr.first != "style") return attr;
    std::string props;
    for (const auto& e : st.styleProps) props += e.first + ":" + e.second + ";";
    if (props.empty() || st.styleRaw.empty() || st.styleRaw.back() == ';')
        return {attr.first, st.styleRaw + props};
    return {attr.first, st.styleRaw + ";" + props};
}

// Returns the attributes and textarea content that the fact list `facts` gives an element whose
// lowered tag is `lowerTag`.
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

// Returns whether HTML element `lowerTag` is void, and so is written with no closing tag.
bool isVoidElement(const std::string& lowerTag) {
    static const char* voids[] = {"area", "base", "br", "col", "embed", "hr", "img",
                                  "input", "link", "meta", "source", "track", "wbr"};
    for (const char* v : voids)
        if (lowerTag == v) return true;
    return false;
}

// Appends each attribute of `attrs` to `out` as ` name` or ` name="value"`.
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

// One item on the writer's work stack. With `emit` set it appends `text` as is; otherwise it
// visits `node`, writing its text as raw `style` text (`raw`) when it is inside a `style` element.
struct Work {
    bool emit;
    bool raw;
    uint64_t node;
    std::string text;
};

// Pushes a visit to each of `kids` onto `work`, so that they are popped in order.
void pushVisits(std::vector<Work>& work, bool raw, const std::vector<uint64_t>& kids) {
    for (size_t i = kids.size(); i-- > 0;) work.push_back(Work{false, raw, kids[i], {}});
}

// Writes the opening tag of element `el` to `out`, and pushes its closing tag and its children onto
// `work`. With `keyed` set, the children are `(key, node)` tuples, and one that is not a tuple is
// skipped. A tag that breaks a token is replaced by its children; a void HTML element gets no children
// or closing tag; an HTML `textarea` whose `value` property is a scalar gets that value as its
// content instead of its children.
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

    if (isTokenBreaking(false, tag)) {
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
        if (n == nullptr) continue;
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
