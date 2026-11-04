//===- JsonExports.cpp - C-linkage exports for Json module -----------------===//
//
// The native implementation of elm/json: the kernel functions behind Json.Decode and Json.Encode.
// nlohmann/json (its `ordered_json`) does the parsing; `writeJsJson` prints the text as JavaScript's
// `JSON.stringify` does. Everything Elm sees is a value on the GC heap.
//
// A `Json.Value` is a heap value of one of two families. The *encoder family* is what Json.Encode
// builds: `ENC_*` Customs (ctors 0-6). Its arrays and objects hold Elm lists in the reverse of the
// order their entries were added, because `addEntry` and `addField` prepend. The *decoder family* is
// what parsing builds: `CTOR_JSON_*` Customs (ctors 100-107). Its arrays hold ElmArrays and its
// objects hold lists of (key, value) Tuple2s. In each family null is a null-cons constant: an
// embedded constant word that carries a ctor and is never a heap object.
//
// The decoder interpreter reads only the decoder family, so `Json.run` first converts an
// encoder-family value to the decoder family by way of nlohmann. Every object this file builds,
// parses or prints has its keys in JavaScript's order, the order Elm's objects have: array-index
// keys ("0", "7") first, ascending, then the others in the order they were added. Of two fields
// given the same key, the key keeps its first position and takes the last value.
//
// A decoder-family array longer than `jsonArrayChunkSize()` is *chunked* (ctor 107): its elements are
// split over several ElmArrays so that no one of them reaches the large-object threshold. Code here
// reads either form only through `jsonArrayLength` and `jsonArrayAt`.
//
// A `Decoder` is a heap value too: a `DEC_*` Custom (ctors 0-22) whose fields are its arguments, or,
// for a decoder with no arguments, a null-cons constant. `runDecoder` interprets one against a
// decoder-family value and returns an Elm `Result`.
//
// Most of the file is rooting. Any allocation and any call to an Elm closure may move heap objects
// (the rule `elm-kernel-cpp/ExportHelpers` states), and decoding allocates at almost every step, so
// each function roots the handles it still needs after an allocation and re-derives raw pointers
// from them afterwards.
//
// The *escape points* are `Json.run` and `Json.runOnString`, where a `Result` leaves this file for
// compiled Elm code. Inside the file an Int, Float or Char `Ok` payload is boxed; compiled code
// expects it unboxed, so `rewrapEscapingResult` rewrites it there.
//
// `json/JsonRead` copies the `ENC_*` and `CTOR_JSON_*` values instead of including this file, so its
// copies must change with these. This file is listed in the kernel licence manifest
// (`kernel-license-files.csv`), and any change to its bytes, comments included, fails the
// `kernel-license-check` build target until it is re-audited.
//
//===----------------------------------------------------------------------===//

#include "../KernelExports.h"
#include "../ExportHelpers.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/Allocator.hpp"
#include "allocator/RuntimeExports.h"
#include "allocator/StringOps.hpp"
#if defined(__clang__)
#  pragma clang diagnostic push
#  pragma clang diagnostic ignored "-Wcovered-switch-default"
#elif defined(__GNUC__)
#  pragma GCC diagnostic push
#  pragma GCC diagnostic ignored "-Wcovered-switch-default"
#endif
#include <nlohmann/json.hpp>
#if defined(__clang__)
#  pragma clang diagnostic pop
#elif defined(__GNUC__)
#  pragma GCC diagnostic pop
#endif
#include <string>
#include <cstring>
#include <cmath>
#include <charconv>
#include <cstdio>
#include <cstdlib>
#include <cassert>
#include <vector>
#include <algorithm>
#include <deque>

// Objects keep their keys in insertion order, so `putInJsKeyOrder` can give them JavaScript's order.
using json = nlohmann::ordered_json;
using namespace Elm;
using namespace Elm::Kernel;
using namespace Elm::alloc;

// Applies an Elm closure to `num_args` encoded words. A GC point.
extern "C" HPtr eco_apply_closure(HPtr closure, uint64_t* args, uint32_t num_args);

//===----------------------------------------------------------------------===//
// JSON Value Heap ADT
//===----------------------------------------------------------------------===//

// The ctors of the decoder family of `Json.Value`, each a `Tag_Custom` heap object except null.
// The numbers start at 100 so that they cannot be mistaken for an `ENC_*` ctor.

/// The ctor of JSON null, which is the null-cons constant for this ctor and never a heap object.
static constexpr u16 CTOR_JSON_NULL   = 100;
static constexpr u16 CTOR_JSON_BOOL   = 101;  ///< One boxed field, the True or False constant.
static constexpr u16 CTOR_JSON_INT    = 102;  ///< One unboxed Int field.
static constexpr u16 CTOR_JSON_FLOAT  = 103;  ///< One unboxed Float field.
static constexpr u16 CTOR_JSON_STRING = 104;  ///< One boxed field, an Elm String.
static constexpr u16 CTOR_JSON_ARRAY  = 105;  ///< One boxed field, an ElmArray of JSON values.
static constexpr u16 CTOR_JSON_OBJECT = 106;  ///< One boxed field, an Elm List of (String, JSON value) Tuple2s.
/// The ctor of an array of more than F = `jsonArrayChunkSize()` elements.
///
/// `values[0]` is an ElmArray of chunk ElmArrays, where chunk i holds elements
/// [i*F, min(n, (i+1)*F)); `values[1]` is the element count n, an unboxed Int.
static constexpr u16 CTOR_JSON_ARRAY_CHUNKED = 107;

// The ctors of a `Decoder`, one per kernel constructor function below. A decoder with no arguments
// (`DEC_STRING`, `DEC_BOOL`, `DEC_INT`, `DEC_FLOAT`, `DEC_VALUE`) is the null-cons constant for its
// ctor; every other is a heap Custom whose fields are its arguments in the order the export takes
// them.
static constexpr u16 DEC_STRING = 0;
static constexpr u16 DEC_BOOL = 1;
static constexpr u16 DEC_INT = 2;
static constexpr u16 DEC_FLOAT = 3;
static constexpr u16 DEC_NULL = 4;
static constexpr u16 DEC_LIST = 5;
static constexpr u16 DEC_ARRAY = 6;
static constexpr u16 DEC_FIELD = 7;
static constexpr u16 DEC_INDEX = 8;
static constexpr u16 DEC_KEYVALUE = 9;
static constexpr u16 DEC_VALUE = 10;
static constexpr u16 DEC_SUCCEED = 11;
static constexpr u16 DEC_FAIL = 12;
static constexpr u16 DEC_ANDTHEN = 13;
static constexpr u16 DEC_ONEOF = 14;
static constexpr u16 DEC_MAP1 = 15;
static constexpr u16 DEC_MAP2 = 16;
static constexpr u16 DEC_MAP3 = 17;
static constexpr u16 DEC_MAP4 = 18;
static constexpr u16 DEC_MAP5 = 19;
static constexpr u16 DEC_MAP6 = 20;
static constexpr u16 DEC_MAP7 = 21;
static constexpr u16 DEC_MAP8 = 22;

// The ctors of the encoder family of `Json.Value`. `ENC_NULL` is a null-cons constant; the others
// are heap Customs with one field. `json/JsonRead` holds copies of these values.
static constexpr u16 ENC_NULL = 0;
static constexpr u16 ENC_BOOL = 1;
static constexpr u16 ENC_INT = 2;
static constexpr u16 ENC_FLOAT = 3;
static constexpr u16 ENC_STRING = 4;
static constexpr u16 ENC_ARRAY = 5;
static constexpr u16 ENC_OBJECT = 6;

//===----------------------------------------------------------------------===//
// Helper Functions
//===----------------------------------------------------------------------===//

// Allocates an Elm String holding the UTF-8 text `str`. A GC point.
static HPointer allocElmString(const std::string& str) {
    return allocStringFromUTF8(str);
}

// Returns the text of the Elm String `strEnc`, of any string form, as UTF-8. Does not allocate on the
// GC heap.
static std::string elmStringToStd(uint64_t strEnc) {
    HPointer h = Export::decode(strEnc);
    if (Elm::alloc::isEmptyString(h)) {
        return "";
    }

    void* ptr = Export::toPtr(strEnc);
    return Elm::StringOps::toStdString(ptr);
}

// Allocates `Ok value`, with `value` in a boxed slot. `value` is rooted across the allocation, so a
// caller may pass a handle it has not rooted itself.
static uint64_t makeOk(HPointer value) {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;

    uint64_t roots[1];
    std::memcpy(&roots[0], &value, sizeof(value));
    Custom* result = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&value, &roots[0], sizeof(value));
    result->header.size = 1;
    result->ctor = 0;  // Ok
    result->unboxed = 0;
    result->values[0].p = value;
    return Export::encode(Allocator::instance().wrap(result));
}


// The constructor tags of elm/json's `Json.Decode.Error`, in declaration order:
//
//     type Error
//         = Field String Error      -- tag 0
//         | Index Int Error         -- tag 1, the Int stored unboxed
//         | OneOf (List Error)      -- tag 2
//         | Failure String Value    -- tag 3
//
// The fields keep their declared order. The errors below are built as elm/json's JavaScript kernel
// builds them (`_Json_runHelp`), so `errorToString` gives the same text.
static constexpr u16 ERR_FIELD = 0;
static constexpr u16 ERR_INDEX = 1;
static constexpr u16 ERR_ONE_OF = 2;
static constexpr u16 ERR_FAILURE = 3;

// Allocates `Err error`, rooting `error` across the allocation.
static uint64_t makeErrResult(HPointer error) {
    return Export::encode(err(boxed(error), true));
}

// Returns the `Error` inside the `Err` result `result`. Does not allocate; the handle is unrooted.
static HPointer getErrValue(uint64_t result) {
    return static_cast<Custom*>(Export::toPtr(result))->values[0].p;
}

// Allocates `Err (Failure message value)`, where `value` is the decoder-family value, a heap
// Custom or the null constant, that the decoder failed on.
static uint64_t makeFailure(const std::string& message, HPointer value) {
    StackRootGuard valueRoot(&value);
    HPointer msgStr = allocElmString(message);
    StackRootGuard msgRoot(&msgStr);
    HPointer failure = custom(ERR_FAILURE, { boxed(msgStr), boxed(value) }, 0);
    return makeErrResult(failure);
}

// Allocates `Err (Failure ("Expecting " ++ type) value)`, as elm/json's `_Json_expecting` does.
static uint64_t expecting(const std::string& type, HPointer value) {
    return makeFailure("Expecting " + type, value);
}

// Allocates `Err (Field key inner)`, where `innerResult` is `Err inner`.
static uint64_t wrapField(HPointer key, uint64_t innerResult) {
    HPointer inner = getErrValue(innerResult);
    StackRootGuard roots(&key, &inner);
    return makeErrResult(custom(ERR_FIELD, { boxed(key), boxed(inner) }, 0));
}

// Allocates `Err (Index index inner)`, where `innerResult` is `Err inner`.
static uint64_t wrapIndex(int64_t index, uint64_t innerResult) {
    HPointer inner = getErrValue(innerResult);
    StackRootGuard roots(&inner);
    return makeErrResult(custom(ERR_INDEX, { unboxedInt(index), boxed(inner) }, /*slot 0 Int*/ 0x1));
}

// Returns whether `key` is an array index ("0", "7", up to "4294967294"), the kind of key a
// JavaScript object lists first, in numeric order, and if so writes its value to `index`.
static bool isArrayIndexKey(const std::string& key, uint64_t& index) {
    if (key.empty() || key.size() > 10) return false;
    if (key.size() > 1 && key[0] == '0') return false;
    uint64_t n = 0;
    for (char c : key) {
        if (c < '0' || c > '9') return false;
        n = n * 10 + static_cast<uint64_t>(c - '0');
    }
    if (n > 4294967294ULL) return false;
    index = n;
    return true;
}

// The members of an `ordered_json` object, in order. Its map is a vector of pairs whose `operator[]`
// and `emplace` search it linearly, so this file appends members straight to the vector and removes
// repeated keys once per object with `dedupeObject`: an object of n keys costs O(n log n), not O(n^2).
using JsonMembers = std::vector<std::pair<const std::string, json>>;

// Returns the member vector of the object `obj`.
static JsonMembers& membersOf(json& obj) {
    return static_cast<JsonMembers&>(obj.get_ref<json::object_t&>());
}

// Removes repeated keys from the object `obj` whose members were appended
// without a check, the JavaScript way: a repeated key keeps its first position
// and takes its last value.
static void dedupeObject(json& obj) {
    JsonMembers& members = membersOf(obj);
    const size_t n = members.size();
    if (n < 2) return;
    std::vector<uint32_t> byKey(n);
    for (size_t i = 0; i < n; i++) byKey[i] = static_cast<uint32_t>(i);
    std::stable_sort(byKey.begin(), byKey.end(), [&](uint32_t a, uint32_t b) {
        return members[a].first < members[b].first;
    });
    // For the first occurrence `i` of a repeated key, `lastOf[i]` is the index of its last occurrence;
    // `repeat` marks the later occurrences. Both stay empty when no key repeats.
    std::vector<uint32_t> lastOf;
    std::vector<bool> repeat;
    for (size_t k = 1; k < n; k++) {
        if (members[byKey[k]].first != members[byKey[k - 1]].first) continue;
        if (lastOf.empty()) {
            lastOf.resize(n);
            for (size_t i = 0; i < n; i++) lastOf[i] = static_cast<uint32_t>(i);
            repeat.assign(n, false);
        }
        size_t first = k - 1;
        while (first > 0 && members[byKey[first - 1]].first == members[byKey[k]].first) first--;
        lastOf[byKey[first]] = byKey[k];
        repeat[byKey[k]] = true;
    }
    if (lastOf.empty()) return;
    JsonMembers out;
    out.reserve(n);
    for (size_t i = 0; i < n; i++) {
        if (repeat[i]) continue;
        out.emplace_back(members[i].first, std::move(members[lastOf[i]].second));
    }
    members.swap(out);
}

// Puts the members of the object `obj`, which has no repeated keys, into
// JavaScript's order: array-index keys first, ascending, then the others in
// insertion order. Together with `dedupeObject` this gives the order Elm, on JavaScript, gives an
// object's keys when it builds, parses or prints one.
static void putInJsKeyOrder(json& obj) {
    JsonMembers& members = membersOf(obj);
    std::vector<std::pair<uint64_t, uint32_t>> indexed;
    for (size_t i = 0; i < members.size(); i++) {
        uint64_t index;
        if (isArrayIndexKey(members[i].first, index)) {
            indexed.push_back({ index, static_cast<uint32_t>(i) });
        }
    }
    if (indexed.empty()) return;
    std::sort(indexed.begin(), indexed.end());
    std::vector<bool> moved(members.size(), false);
    JsonMembers out;
    out.reserve(members.size());
    for (auto& [index, i] : indexed) {
        out.emplace_back(members[i].first, std::move(members[i].second));
        moved[i] = true;
    }
    for (size_t i = 0; i < members.size(); i++) {
        if (!moved[i]) out.emplace_back(members[i].first, std::move(members[i].second));
    }
    members.swap(out);
}

// Appends the member (key, value) to the object `obj` without a check; the
// caller finishes the object with `dedupeObject` and `putInJsKeyOrder`.
static void appendMember(json& obj, std::string key, json value) {
    membersOf(obj).emplace_back(std::move(key), std::move(value));
}

//===----------------------------------------------------------------------===//
// Lone surrogates: JSON.parse keeps a lone-surrogate escape such as `\ud83d` as one UTF-16 unit, but
// the nlohmann lexer rejects it. `parseJson` therefore hides each one from the lexer behind the
// noncharacter U+FDD0 and puts it back into the parsed strings (as the WTF-8 bytes `ED A0-BF xx`,
// which `allocStringFromUTF8` reads as the one unit).
//===----------------------------------------------------------------------===//

// The stand-in for a hidden lone surrogate: U+FDD0, written `\ufdd0` (as long as the escape it
// replaces, so the parser's error positions stay those of the original text) and lexed to the
// UTF-8 bytes `EF B7 90`.
static constexpr char kSurrogateMarkUtf8[] = "\xEF\xB7\x90";

// The value in `marks` for an occurrence of U+FDD0 that was in the text itself.
static constexpr int32_t kRealMark = -1;

// Returns the value of the four hex digits at `p`, or -1 when `p[0..3]` are not all hex digits.
static int32_t hex4(const char* p) {
    int32_t v = 0;
    for (int k = 0; k < 4; k++) {
        char c = p[k];
        int d = (c >= '0' && c <= '9') ? c - '0'
              : (c >= 'a' && c <= 'f') ? c - 'a' + 10
              : (c >= 'A' && c <= 'F') ? c - 'A' + 10 : -1;
        if (d < 0) return -1;
        v = v * 16 + d;
    }
    return v;
}

// Returns the surrogate that the `\uXXXX` escape at `text[i]` names, or -1 when there is no such
// escape at `i`.
static int32_t surrogateEscapeAt(const std::string& text, size_t i) {
    if (i + 6 > text.size() || text[i] != '\\' || text[i + 1] != 'u') return -1;
    int32_t v = hex4(text.data() + i + 2);
    return (v >= 0xD800 && v <= 0xDFFF) ? v : -1;
}

// When `text` holds a lone-surrogate escape (one not part of an escaped high + low pair), sets `out`
// to `text` with each one replaced by `\ufdd0`, and `marks` to one entry per U+FDD0 the lexer will
// see, in text order: the hidden surrogate, or `kRealMark` for a U+FDD0 already in the text (raw or
// escaped). Returns whether it found one; `out` and `marks` are untouched otherwise.
static bool hideLoneSurrogates(const std::string& text, std::string& out, std::vector<int32_t>& marks) {
    if (text.find("\\u") == std::string::npos) return false;
    std::vector<int32_t> found;
    std::string result;
    bool anyLone = false;
    const size_t n = text.size();
    size_t copied = 0;  // text[0, copied) is in `result`
    size_t i = 0;
    while (i < n) {
        unsigned char c = static_cast<unsigned char>(text[i]);
        if (c == 0xEF && text.compare(i, 3, kSurrogateMarkUtf8) == 0) {
            found.push_back(kRealMark);
            i += 3;
        } else if (c != '\\') {
            i++;
        } else if (i + 1 < n && text[i + 1] != 'u') {
            i += 2;  // a two-character escape such as `\\`: its second character starts nothing
        } else {
            int32_t v = surrogateEscapeAt(text, i);
            if (v < 0) {
                if (i + 6 <= n && hex4(text.data() + i + 2) == 0xFDD0) found.push_back(kRealMark);
                i += (i + 6 <= n) ? 6 : 1;
                continue;
            }
            int32_t lo = (v <= 0xDBFF) ? surrogateEscapeAt(text, i + 6) : -1;
            if (lo >= 0xDC00) {
                i += 12;  // a valid pair, which the lexer joins
                continue;
            }
            anyLone = true;
            result.append(text, copied, i - copied);
            result += "\\ufdd0";
            found.push_back(v);
            i += 6;
            copied = i;
        }
    }
    if (!anyLone) return false;
    result.append(text, copied, n - copied);
    out = std::move(result);
    marks = std::move(found);
    return true;
}

// The SAX handler that parses JSON text into an `ordered_json` whose objects are in JavaScript's key
// order. It replaces `json::parse`, whose DOM builder inserts each key with a linear search.
//
// When `marks` is set (by `hideLoneSurrogates`), each U+FDD0 in a parsed string or key is replaced by
// the next entry: its hidden lone surrogate, or itself for a `kRealMark`.
class OrderedDomBuilder {
public:
    json root;
    const std::vector<int32_t>* marks = nullptr;

    bool null() { add(json(nullptr)); return true; }
    bool boolean(bool b) { add(json(b)); return true; }
    bool number_integer(json::number_integer_t n) { add(json(n)); return true; }
    // An integer above INT64_MAX does not fit eco's Int, so it is kept as the double JavaScript
    // would read, as an integer too large for nlohmann's unsigned type already is.
    bool number_unsigned(json::number_unsigned_t n) {
        if (n > static_cast<json::number_unsigned_t>(INT64_MAX)) {
            add(json(static_cast<json::number_float_t>(n)));
        } else {
            add(json(n));
        }
        return true;
    }
    bool number_float(json::number_float_t d, const json::string_t&) { add(json(d)); return true; }
    bool string(json::string_t& str) { restoreMarks(str); add(json(std::move(str))); return true; }
    bool binary(json::binary_t& b) { add(json::binary(std::move(b))); return true; }
    bool start_object(std::size_t) { stack_.push_back(add(json::object())); return true; }
    bool key(json::string_t& k) { restoreMarks(k); key_ = std::move(k); return true; }
    bool end_object() {
        dedupeObject(*stack_.back());
        putInJsKeyOrder(*stack_.back());
        stack_.pop_back();
        return true;
    }
    bool start_array(std::size_t) { stack_.push_back(add(json::array())); return true; }
    bool end_array() { stack_.pop_back(); return true; }
    bool parse_error(std::size_t, const std::string&, const nlohmann::detail::exception& e) {
        error = e.what();
        return false;
    }

    std::string error;  // the parser's message, when it failed

private:
    // Replaces each U+FDD0 in `str` by the next entry of `marks`, in place (both are three bytes).
    void restoreMarks(json::string_t& str) {
        if (!marks) return;
        size_t at = 0;
        while ((at = str.find(kSurrogateMarkUtf8, at)) != json::string_t::npos) {
            int32_t v = nextMark_ < marks->size() ? (*marks)[nextMark_++] : kRealMark;
            if (v != kRealMark) {
                str[at] = static_cast<char>(0xE0 | (v >> 12));
                str[at + 1] = static_cast<char>(0x80 | ((v >> 6) & 0x3F));
                str[at + 2] = static_cast<char>(0x80 | (v & 0x3F));
            }
            at += 3;
        }
    }

    size_t nextMark_ = 0;  // the entry of `marks` for the next U+FDD0

    // Adds `value` to the innermost open container, or makes it the root, and returns where it now
    // lives. A container on the stack is always the last element of its parent, and only the
    // innermost one grows, so the pointers on the stack stay valid.
    json* add(json value) {
        if (stack_.empty()) {
            root = std::move(value);
            return &root;
        }
        json& top = *stack_.back();
        if (top.is_array()) {
            auto& elems = top.get_ref<json::array_t&>();
            elems.push_back(std::move(value));
            return &elems.back();
        }
        JsonMembers& members = membersOf(top);
        members.emplace_back(std::move(key_), std::move(value));
        return &members.back().second;
    }

    std::vector<json*> stack_;
    std::string key_;
};

// Parses `text` into `out` and returns true, or returns false with the parser's message in `error`.
// A lone-surrogate escape is kept as that one unit, as JSON.parse keeps it (`hideLoneSurrogates`).
// Does not allocate on the GC heap.
static bool parseJson(const std::string& text, json& out, std::string& error) {
    OrderedDomBuilder builder;
    std::string hidden;
    std::vector<int32_t> marks;
    const bool lone = hideLoneSurrogates(text, hidden, marks);
    if (lone) builder.marks = &marks;
    if (!json::sax_parse(lone ? hidden : text, &builder)) {
        error = builder.error;
        return false;
    }
    out = std::move(builder.root);
    return true;
}

// Returns whether the `Result` word `result` is an `Ok`.
static bool isOk(uint64_t result) {
    void* ptr = Export::toPtr(result);
    if (!ptr) return false;
    Custom* c = static_cast<Custom*>(ptr);
    return c->ctor == 0;
}

// Returns the payload of `result`, which must be an `Ok` as built by `makeOk`. The handle is unrooted.
static HPointer getOkValue(uint64_t result) {
    void* ptr = Export::toPtr(result);
    Custom* c = static_cast<Custom*>(ptr);
    return c->values[0].p;
}

//===----------------------------------------------------------------------===//
// JSON Value ADT - Construction Helpers
//===----------------------------------------------------------------------===//

// Returns decoder-family JSON null, the null-cons constant for `CTOR_JSON_NULL`. Does not allocate.
static HPointer makeJsonNull() {
    return hpFromBits(nullConsWordFor(CTOR_JSON_NULL));
}

// Allocates a decoder-family JSON boolean holding `b`.
static HPointer makeJsonBool(bool b) {
    // The field is a constant, which no collection moves, so nothing needs rooting.
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* c = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    c->header.size = 1;
    c->ctor = CTOR_JSON_BOOL;
    c->unboxed = 0;
    c->values[0].p = b ? elmTrue() : elmFalse();
    return Allocator::instance().wrap(c);
}

// Allocates a decoder-family JSON integer holding `val`.
static HPointer makeJsonInt(i64 val) {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* c = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    c->header.size = 1;
    c->ctor = CTOR_JSON_INT;
    c->unboxed = 1;
    c->values[0].i = val;
    return Allocator::instance().wrap(c);
}

// Allocates a decoder-family JSON float holding `val`.
static HPointer makeJsonFloat(f64 val) {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* c = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    c->header.size = 1;
    c->ctor = CTOR_JSON_FLOAT;
    c->unboxed = 2;  // Float in slot 0
    c->values[0].f = val;
    return Allocator::instance().wrap(c);
}

// Allocates a decoder-family JSON string around the Elm String `elmStr`, which is rooted across the
// allocation.
static HPointer makeJsonString(HPointer elmStr) {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t roots[1];
    std::memcpy(&roots[0], &elmStr, sizeof(elmStr));
    Custom* c = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&elmStr, &roots[0], sizeof(elmStr));
    c->header.size = 1;
    c->ctor = CTOR_JSON_STRING;
    c->unboxed = 0;
    c->values[0].p = elmStr;
    return Allocator::instance().wrap(c);
}

// Roots every element of `v` with one range record on the range stack of `rs`, whatever its length,
// since an all-ones mask makes every slot of a range a root (`stackRangeSlotIsRoot`).
//
// The record points into `v`'s buffer, so `v` must not be resized or destroyed until the caller has
// restored the range stack to a point saved before this call. An empty `v` pushes nothing.
static void rootBuffer(RootSet& rs, std::vector<HPointer>& v) {
    if (!v.empty()) rs.pushStackRootRange(v.data(), v.size(), ~0ULL);
}

// Allocates a JsArray holding elems[start, start+count), with slot kind `kind` (0 boxed, 1 Int, 2
// Float). For kind 1 or 2 each element must be a boxed Int or Float, whose number is stored
// unboxed; for kind 0 the handles are stored as they are.
//
// `elems` must be rooted by the caller; it is read only after the one allocation. Every caller
// passes `count` of at most 32.
static HPointer jsArrayFromSlice(std::vector<HPointer>& elems, size_t start, size_t count,
                                 u8 kind) {
    auto& allocator = Allocator::instance();
    HPointer jsArr = alloc::allocArray(count);
    void* arrObj = allocator.resolve(jsArr);
    for (size_t i = 0; i < count; ++i) {
        if (kind == 1) {
            ElmInt* ei = static_cast<ElmInt*>(allocator.resolve(elems[start + i]));
            Unboxable u; u.i = ei->value;
            alloc::arrayPushKind(arrObj, u, 1);
        } else if (kind == 2) {
            ElmFloat* ef = static_cast<ElmFloat*>(allocator.resolve(elems[start + i]));
            Unboxable u; u.f = ef->value;
            alloc::arrayPushKind(arrObj, u, 2);
        } else if (kind == 3) {
            ElmChar* ec = static_cast<ElmChar*>(allocator.resolve(elems[start + i]));
            alloc::arrayPushKind(arrObj, alloc::unboxedChar(ec->value), 3);
        } else {
            Unboxable u; u.p = elems[start + i];
            alloc::arrayPush(arrObj, u, true);
        }
    }
    return jsArr;
}

// Allocates an elm/core Array `Node` with ctor `ctor` around the JsArray `child`, which is rooted
// across the allocation. Ctor 0 is `SubTree` and 1 is `Leaf`, their order in elm/core's Array.elm.
static HPointer makeArrayNode(u16 ctor, HPointer child) {
    size_t sz = (sizeof(Custom) + 1 * sizeof(Unboxable) + 7) & ~size_t{7};
    uint64_t roots[1];
    std::memcpy(&roots[0], &child, sizeof(child));
    Custom* node = static_cast<Custom*>(eco_alloc_with_roots(Tag_Custom, sz, roots, 1, 0x1));
    std::memcpy(&child, &roots[0], sizeof(child));
    node->ctor = ctor;
    node->unboxed = 0;
    node->values[0].p = child;
    return Allocator::instance().wrap(node);
}

// Allocates an elm/core `Array` holding `elements` in order, with slot kind `elemKind` for its
// leaves (as `jsArrayFromSlice` takes it).
//
// The result has the shape elm/core's `Array.fromList` gives the same elements, because elm/core's
// Array functions read that shape: `Array_elm_builtin length startShift tree tail`. The tail holds the
// last `len % 32` elements, and is empty when `len` is a multiple of 32. Every full run of 32
// elements before it is a `Leaf`. While more than 32 nodes remain at a level they are grouped, 32 at
// a time, into `SubTree` nodes, and the top level is a JsArray of at most 32 nodes. `startShift` is
// `max 5 (5 * floor (log32 (treeLen - 1)))`, where treeLen is the number of elements in leaves.
// Every JsArray built here holds at most 32 elements.
//
// `elements` must be rooted by the caller (with `rootBuffer`) and is not resized.
static HPointer buildElmArrayFromElements(std::vector<HPointer>& elements, u8 elemKind) {
    constexpr size_t kBranch = 32;
    auto& allocator = Allocator::instance();
    auto& rs = allocator.getRootSet();
    const size_t len = elements.size();
    const size_t tailLen = len % kBranch;
    const size_t tailStart = len - tailLen;
    const size_t numLeaves = tailStart / kBranch;

    size_t saved = rs.stackRangePoint();
    HPointer tailJsArr = jsArrayFromSlice(elements, tailStart, tailLen, elemKind);
    rs.pushStackRootRange(&tailJsArr, 1, 1);

    // Each level's vector is rooted by a range record that points into its buffer, so it must stay in
    // place until the function returns. Growing a std::deque at its end never moves the vectors
    // already in it, as growing a std::vector of vectors could.
    std::deque<std::vector<HPointer>> levels;

    // Level 0: the Leaf nodes, in index order.
    levels.emplace_back(numLeaves, alloc::listNil());
    rootBuffer(rs, levels.back());
    for (size_t k = 0; k < numLeaves; ++k) {
        HPointer leafArr = jsArrayFromSlice(elements, k * kBranch, kBranch, elemKind);
        levels.back()[k] = makeArrayNode(/*Leaf*/ 1, leafArr);
    }

    // Group into SubTree nodes while more than 32 nodes remain.
    while (levels.back().size() > kBranch) {
        std::vector<HPointer>& below = levels.back();
        const size_t groups = (below.size() + kBranch - 1) / kBranch;
        levels.emplace_back(groups, alloc::listNil());
        std::vector<HPointer>& above = levels.back();
        rootBuffer(rs, above);
        for (size_t g = 0; g < groups; ++g) {
            const size_t start = g * kBranch;
            const size_t count = std::min(kBranch, below.size() - start);
            HPointer sub = jsArrayFromSlice(below, start, count, /*boxed*/ 0);
            above[g] = makeArrayNode(/*SubTree*/ 0, sub);
        }
    }

    HPointer treeJsArr = jsArrayFromSlice(levels.back(), 0, levels.back().size(), /*boxed*/ 0);
    rs.pushStackRootRange(&treeJsArr, 1, 1);

    size_t startShift = 5;
    if (numLeaves > 0) {
        size_t v = numLeaves * kBranch - 1;   // treeLen - 1
        size_t depth = 0;
        while (v >= kBranch) { v /= kBranch; ++depth; }
        startShift = std::max<size_t>(5, 5 * depth);
    }

    size_t sz = (sizeof(Custom) + 4 * sizeof(Unboxable) + 7) & ~size_t{7};
    uint64_t roots[4] = {static_cast<uint64_t>(len), static_cast<uint64_t>(startShift), 0, 0};
    std::memcpy(&roots[2], &treeJsArr, sizeof(treeJsArr));
    std::memcpy(&roots[3], &tailJsArr, sizeof(tailJsArr));
    Custom* c = static_cast<Custom*>(eco_alloc_with_roots(Tag_Custom, sz, roots, 4, 0xC));
    c->ctor = 0;       // Array_elm_builtin
    c->unboxed = 0x5;  // Int in slots 0 (length) and 1 (startShift)
    c->values[0].i = static_cast<i64>(roots[0]);
    c->values[1].i = static_cast<i64>(roots[1]);
    std::memcpy(&c->values[2].p, &roots[2], sizeof(HPointer));
    std::memcpy(&c->values[3].p, &roots[3], sizeof(HPointer));
    rs.restoreStackRangePoint(saved);
    return allocator.wrap(c);
}

// Allocates an unchunked decoder-family JSON array around the ElmArray `elmArray`, which is rooted
// across the allocation.
static HPointer makeJsonArray(HPointer elmArray) {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t roots[1];
    std::memcpy(&roots[0], &elmArray, sizeof(elmArray));
    Custom* c = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&elmArray, &roots[0], sizeof(elmArray));
    c->header.size = 1;
    c->ctor = CTOR_JSON_ARRAY;
    c->unboxed = 0;
    c->values[0].p = elmArray;
    return Allocator::instance().wrap(c);
}

// Returns the most elements an ElmArray can hold while staying below the allocator's large-object
// threshold: the length of every chunk of a chunked JSON array but the last, and the longest array
// left unchunked. 1,021 for an 8 KiB threshold.
static size_t jsonArrayChunkSize() {
    return (Allocator::instance().getLargeObjectThreshold() - 1 - sizeof(ElmArray)) /
           sizeof(Unboxable);
}

// Allocates a chunked decoder-family JSON array, where `index` is an ElmArray of chunk ElmArrays
// holding `n` elements in total. `index` is rooted across the allocation.
static HPointer makeJsonArrayChunked(HPointer index, u32 n) {
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t roots[1];
    std::memcpy(&roots[0], &index, sizeof(index));
    Custom* c = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&index, &roots[0], sizeof(index));
    c->header.size = 2;
    c->ctor = CTOR_JSON_ARRAY_CHUNKED;
    c->unboxed = 0x4;              // Int in slot 1
    c->values[0].p = index;
    c->values[1].i = static_cast<i64>(n);
    return Allocator::instance().wrap(c);
}

// Allocates the decoder-family JSON array holding `elements`: unchunked up to `jsonArrayChunkSize()`
// elements, chunked above. `elements` must be rooted by the caller and is not resized.
static HPointer makeJsonArrayFrom(std::vector<HPointer>& elements) {
    const size_t n = elements.size();
    const size_t F = jsonArrayChunkSize();
    if (n <= F) return makeJsonArray(arrayFromPointers(elements));

    auto& rs = Allocator::instance().getRootSet();
    const size_t saved = rs.stackRangePoint();
    std::vector<HPointer> chunks((n + F - 1) / F, alloc::listNil());
    rootBuffer(rs, chunks);
    for (size_t c = 0; c < chunks.size(); ++c) {
        const size_t lo = c * F;
        const size_t hi = std::min(n, lo + F);
        // arrayFromPointers roots its own copy of the slice.
        std::vector<HPointer> slice(elements.begin() + lo, elements.begin() + hi);
        chunks[c] = arrayFromPointers(slice);
#if ECO_HEAP_VALIDATE
        assert(sizeof(ElmArray) + slice.size() * sizeof(Unboxable) <
                   Allocator::instance().getLargeObjectThreshold() &&
               "JSON array chunk reached the large-object threshold");
#endif
    }
    HPointer index = arrayFromPointers(chunks);
    rs.restoreStackRangePoint(saved);
    return makeJsonArrayChunked(index, static_cast<u32>(n));
}

// Returns whether `ctor` is the ctor of a decoder-family JSON array of either form.
static bool isJsonArrayCtor(u16 ctor) {
    return ctor == CTOR_JSON_ARRAY || ctor == CTOR_JSON_ARRAY_CHUNKED;
}

// Returns the number of elements of the JSON array `jarr`, of either form. Does not allocate.
static u32 jsonArrayLength(Custom* jarr) {
    if (jarr->ctor == CTOR_JSON_ARRAY_CHUNKED) return static_cast<u32>(jarr->values[1].i);
    return static_cast<ElmArray*>(Allocator::instance().resolve(jarr->values[0].p))->length;
}

// Returns element `i` of the JSON array `jarr`, of either form. `i` must be less than
// `jsonArrayLength(jarr)`; nothing checks it. Does not allocate.
//
// The chunk size is read from chunk 0, which is full whenever there is more than one chunk, so an
// array built under one large-object threshold reads correctly under another.
static HPointer jsonArrayAt(Custom* jarr, u32 i) {
    auto& allocator = Allocator::instance();
    ElmArray* top = static_cast<ElmArray*>(allocator.resolve(jarr->values[0].p));
    if (jarr->ctor != CTOR_JSON_ARRAY_CHUNKED) return top->elements[i].p;
    const u32 F = static_cast<ElmArray*>(allocator.resolve(top->elements[0].p))->length;
    ElmArray* chunk = static_cast<ElmArray*>(allocator.resolve(top->elements[i / F].p));
    return chunk->elements[i % F].p;
}

// Allocates a decoder-family JSON object around `kvList`, an Elm List of (String, JSON value)
// Tuple2s, which is rooted across the allocation.
static HPointer makeJsonObject(HPointer kvList) {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t roots[1];
    std::memcpy(&roots[0], &kvList, sizeof(kvList));
    Custom* c = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&kvList, &roots[0], sizeof(kvList));
    c->header.size = 1;
    c->ctor = CTOR_JSON_OBJECT;
    c->unboxed = 0;
    c->values[0].p = kvList;
    return Allocator::instance().wrap(c);
}

//===----------------------------------------------------------------------===//
// jsonToHeap - Convert nlohmann::json to heap-resident JSON value ADT
//===----------------------------------------------------------------------===//

// Allocates the decoder-family value for the parsed JSON `j`. A GC point.
//
// Object entries are listed in the object's member order, which is already JavaScript's key order,
// as `parseJson` and `elmToJson` build every object that reaches here. A number nlohmann
// parsed as an integer becomes `CTOR_JSON_INT` and any other number `CTOR_JSON_FLOAT`; `parseJson`
// has already made every integer outside the i64 range a float.
static HPointer jsonToHeap(const json& j) {
    auto& allocator = Allocator::instance();

    if (j.is_null()) {
        return makeJsonNull();
    }

    if (j.is_boolean()) {
        return makeJsonBool(j.get<bool>());
    }

    if (j.is_number_integer()) {
        return makeJsonInt(j.get<i64>());
    }

    if (j.is_number_float()) {
        return makeJsonFloat(j.get<f64>());
    }

    if (j.is_string()) {
        HPointer str = allocElmString(j.get<std::string>());
        return makeJsonString(str);
    }

    if (j.is_array()) {
        // Each recursive call is a GC point, so every element converted so far must stay rooted. The
        // vector is sized once and filled with Nil, a constant, so one record roots all of it.
        size_t n = j.size();
        std::vector<HPointer> elements(n, listNil());
        auto& rs = Allocator::instance().getRootSet();
        size_t saved = rs.stackRangePoint();
        rootBuffer(rs, elements);

        size_t i = 0;
        for (const auto& elem : j) {
            elements[i++] = jsonToHeap(elem);
        }

        HPointer jarr = makeJsonArrayFrom(elements);
        rs.restoreStackRangePoint(saved);
        return jarr;
    }

    if (j.is_object()) {
        // The list is built by prepending from the last member, so it ends in member order.
        const JsonMembers& members = static_cast<const JsonMembers&>(j.get_ref<const json::object_t&>());

        HPointer kvList = listNil();
        HPointer keyStr = listNil();  // placeholder; assigned per-iteration
        // `keyStr` is rooted once, outside the loop, and overwritten on each iteration.
        Elm::StackRootGuard objRoots(&kvList, &keyStr);
        for (auto it = members.rbegin(); it != members.rend(); ++it) {
            keyStr = allocElmString(it->first);
            HPointer val = jsonToHeap(it->second);

            HPointer tup = tuple2(boxed(keyStr), boxed(val), 0);
            kvList = cons(boxed(tup), kvList, true);
        }

        return makeJsonObject(kvList);
    }

    return makeJsonNull();
}

//===----------------------------------------------------------------------===//
// heapJsonToNlohmann - Convert heap-resident JSON value ADT to nlohmann::json
//===----------------------------------------------------------------------===//

// Returns the nlohmann value for the decoder-family value `jvalEnc`. Anything that is not a
// decoder-family value becomes JSON null. Does not allocate on the GC heap.
static json heapJsonToNlohmann(uint64_t jvalEnc) {
    auto& allocator = Allocator::instance();

    if (isNullConsBits(jvalEnc)) return json(nullptr);

    void* ptr = Export::toPtr(jvalEnc);
    if (!ptr) return json(nullptr);

    Header* hdr = static_cast<Header*>(ptr);
    if (hdr->tag != Tag_Custom) return json(nullptr);

    Custom* c = static_cast<Custom*>(ptr);

    switch (c->ctor) {
        case CTOR_JSON_NULL:
            return json(nullptr);

        case CTOR_JSON_BOOL: {
            HPointer boolVal = c->values[0].p;
            return json(boolValue(boolVal));
        }

        case CTOR_JSON_INT:
            return json(c->values[0].i);

        case CTOR_JSON_FLOAT:
            return json(c->values[0].f);

        case CTOR_JSON_STRING: {
            return json(elmStringToStd(Export::encode(c->values[0].p)));
        }

        case CTOR_JSON_ARRAY:
        case CTOR_JSON_ARRAY_CHUNKED: {
            json arr = json::array();
            const u32 len = jsonArrayLength(c);
            for (u32 i = 0; i < len; i++) {
                arr.push_back(heapJsonToNlohmann(Export::encode(jsonArrayAt(c, i))));
            }
            return arr;
        }

        case CTOR_JSON_OBJECT: {
            json obj = json::object();
            for (alloc::ListCursor kv(c->values[0].p); !kv.done(); kv.next()) {
                void* tuplePtr = allocator.resolve(kv.current().p);
                Tuple2* tup = static_cast<Tuple2*>(tuplePtr);

                appendMember(obj, elmStringToStd(Export::encode(tup->a.p)),
                             heapJsonToNlohmann(Export::encode(tup->b.p)));
            }
            dedupeObject(obj);
            putInJsKeyOrder(obj);
            return obj;
        }

        default:
            return json(nullptr);
    }
}

//===----------------------------------------------------------------------===//
// Decoder Creation Helpers
//===----------------------------------------------------------------------===//

// Returns the decoder with no arguments for `ctor`, the null-cons constant for that ctor. Does not
// allocate.
static uint64_t makeDecoder0(u16 ctor) {
    return nullConsWordFor(ctor);
}

// Writes to `slot` the form the decoded value `v` takes in a heap field, and returns that slot's kind
// (0 boxed, 1 Int, 2 Float, 3 Char). A boxed Int, Float or Char gives its number and kind; anything
// else gives `v` itself and kind 0. Does not allocate.
//
// Compiled code reads a list head or tuple field of type Int, Float or Char as an unboxed number,
// so the kind is read off the value, not off the decoder: `Decode.field "v" Decode.int` and
// `Decode.map f Decode.int` decode Ints, though their ctors are `DEC_FIELD` and `DEC_MAP`.
static u8 decodedSlot(Allocator& allocator, HPointer v, Unboxable& slot) {
    slot.p = v;
    if (isEmbeddedConstant(v)) return 0;
    void* obj = allocator.resolve(v);
    switch (getTag(obj)) {
        case Tag_Int:
            slot.i = static_cast<ElmInt*>(obj)->value;
            return 1;
        case Tag_Float:
            slot.f = static_cast<ElmFloat*>(obj)->value;
            return 2;
        case Tag_Char:
            slot = alloc::unboxedChar(static_cast<ElmChar*>(obj)->value);
            return 3;
        default:
            return 0;
    }
}

// Allocates a decoder with ctor `ctor` and the one boxed argument `arg`, rooted across the allocation.
static uint64_t makeDecoder1(u16 ctor, uint64_t arg) {
    HPointer payload = Export::decode(arg);
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t roots[1];
    std::memcpy(&roots[0], &payload, sizeof(payload));
    Custom* dec = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&payload, &roots[0], sizeof(payload));
    dec->header.size = 1;
    dec->ctor = ctor;
    dec->unboxed = 0;
    dec->values[0].p = payload;
    return Export::encode(Allocator::instance().wrap(dec));
}

// Allocates a decoder with ctor `ctor` and the two boxed arguments `arg1` and `arg2`, in that order,
// both rooted across the allocation.
static uint64_t makeDecoder2(u16 ctor, uint64_t arg1, uint64_t arg2) {
    HPointer p0 = Export::decode(arg1);
    HPointer p1 = Export::decode(arg2);
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t roots[2];
    std::memcpy(&roots[0], &p0, sizeof(p0));
    std::memcpy(&roots[1], &p1, sizeof(p1));
    Custom* dec = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 2, 0x3));
    std::memcpy(&p0, &roots[0], sizeof(p0));
    std::memcpy(&p1, &roots[1], sizeof(p1));
    dec->header.size = 2;
    dec->ctor = ctor;
    dec->unboxed = 0;
    dec->values[0].p = p0;
    dec->values[1].p = p1;
    return Export::encode(Allocator::instance().wrap(dec));
}

// Allocates a decoder with ctor `ctor`, the unboxed Int `arg1` in slot 0 and the boxed `arg2` in slot
// 1, which is rooted across the allocation.
static uint64_t makeDecoder2ip(u16 ctor, int64_t arg1, uint64_t arg2) {
    HPointer p1 = Export::decode(arg2);
    size_t size = sizeof(Custom) + 2 * sizeof(Unboxable);
    size = (size + 7) & ~7;
    // Only roots[1] is an HPointer, so the mask is 0x2.
    uint64_t roots[2] = { static_cast<uint64_t>(arg1), 0 };
    std::memcpy(&roots[1], &p1, sizeof(p1));
    Custom* dec = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 2, 0x2));
    std::memcpy(&p1, &roots[1], sizeof(p1));
    dec->header.size = 2;
    dec->ctor = ctor;
    dec->unboxed = 1;  // Int in slot 0
    dec->values[0].i = arg1;
    dec->values[1].p = p1;
    return Export::encode(Allocator::instance().wrap(dec));
}

//===----------------------------------------------------------------------===//
// Decoder Execution - operates on heap-resident JSON values
//===----------------------------------------------------------------------===//

static uint64_t runDecoder(HPointer decoderHP, uint64_t jvalEncIn);

// elm/json decodes a list, an array or an object's values from the first to the last and reports
// the first that fails, wrapped in `Index` or `Field`. The list and key-value decoders below decode
// from the last, so on a failure they decode again from the front with these two, which return that
// error. Decoders are pure, so the same element fails again; only the error path pays for the rescan.

// Allocates `Err (Index i e)` for the first element `i` of the JSON array `arrayHP`, of `len`
// elements, that `elemDecHP` fails on with `e`. A GC point.
static uint64_t firstFailingElement(HPointer elemDecHP, HPointer arrayHP, u32 len) {
    auto& allocator = Allocator::instance();
    StackRootGuard roots(&elemDecHP, &arrayHP);
    for (u32 i = 0; i < len; i++) {
        Custom* array = static_cast<Custom*>(allocator.resolve(arrayHP));
        uint64_t result = runDecoder(elemDecHP, Export::encode(jsonArrayAt(array, i)));
        if (!isOk(result)) return wrapIndex(i, result);
    }
    assert(false && "firstFailingElement: no element fails on the rescan");
    return makeFailure("Expecting a LIST", arrayHP);
}

// Allocates `Err (Field key e)` for the first member `key` of the JSON object `objectHP` whose value
// `valDecHP` fails on with `e`. A GC point.
static uint64_t firstFailingField(HPointer valDecHP, HPointer objectHP) {
    auto& allocator = Allocator::instance();
    StackRootGuard roots(&valDecHP, &objectHP);
    Custom* object = static_cast<Custom*>(allocator.resolve(objectHP));
    alloc::RootedListCursor kv(object->values[0].p);
    Unboxable kvHead;
    u8 kvKind;
    while (kv.read(kvHead, kvKind)) {
        Tuple2* tup = static_cast<Tuple2*>(allocator.resolve(kvHead.p));
        HPointer keyHP = tup->a.p;
        StackRootGuard keyRoot(&keyHP);
        uint64_t result = runDecoder(valDecHP, Export::encode(tup->b.p));
        if (!isOk(result)) return wrapField(keyHP, result);
        kv.advance();
    }
    assert(false && "firstFailingField: no member fails on the rescan");
    return makeFailure("Expecting an OBJECT", objectHP);
}

// Runs the decoder `decoderHP` on the decoder-family value `jvalEncIn` and returns the `Result`. An
// `Ok` payload is always in a boxed slot, an Int, Float or Char included. A GC point: it allocates
// and may call Elm closures.
//
// The errors are elm/json's. A list, array or key-value decoder fails with the first element, in
// JSON order, that fails, wrapped in `Index` or `Field`; `mapN` decoders run in argument order and
// return the first failure. `oneOf` returns the first success, and if none succeeds, `OneOf` of every
// alternative's error in order.
//
// Implementation: both arguments are rooted (as `decoderHP` and `jvalHP`) for the whole body, and the
// raw `decoder` and `jval` pointers are valid only until the first GC point; after one, re-derive
// them through `resolveDecoder` and `resolveJval`. A recursive call must be passed
// `Export::encode(jvalHP)`, not `jvalEncIn`, which is an unrooted copy.
static uint64_t runDecoder(HPointer decoderHP, uint64_t jvalEncIn) {
    auto& allocator = Allocator::instance();

    HPointer jvalHP = Export::decode(jvalEncIn);
    StackRootGuard topRoots(&decoderHP, &jvalHP);

    // Each returns null for a constant: a decoder with no arguments, or JSON null.
    auto resolveDecoder = [&]() -> Custom* {
        // The arms for decoders with no arguments never dereference `decoder`.
        if (decoderHP.ptr_ind != 0) return nullptr;
        return static_cast<Custom*>(allocator.resolve(decoderHP));
    };
    auto resolveJval = [&]() -> Custom* {
        if (jvalHP.ptr_ind != 0) return nullptr;
        void* p = allocator.resolve(jvalHP);
        if (static_cast<Header*>(p)->tag != Tag_Custom) return nullptr;
        return static_cast<Custom*>(p);
    };

    Custom* decoder = resolveDecoder();
    // A constant that is not null-cons gives ctor 0.
    const u16 dctor = decoder ? decoder->ctor
                              : static_cast<u16>(isNullConsBits(hpBits(decoderHP))
                                                     ? nullConsTagBits(hpBits(decoderHP))
                                                     : 0);
    Custom* jval = resolveJval();
    u16 jctor = jval ? jval->ctor
                     : static_cast<u16>(isNullConsBits(hpBits(jvalHP))
                                            ? nullConsTagBits(hpBits(jvalHP))
                                            : 0);

    switch (dctor) {
        case DEC_STRING: {
            if (!jval || jctor != CTOR_JSON_STRING) {
                return expecting("a STRING", jvalHP);
            }
            return makeOk(jval->values[0].p);
        }

        case DEC_BOOL: {
            if (!jval || jctor != CTOR_JSON_BOOL) {
                return expecting("a BOOL", jvalHP);
            }
            return makeOk(jval->values[0].p);
        }

        case DEC_INT: {
            // Elm accepts any number for which `Number.isInteger` holds, so an integral float such
            // as 1.0 or 1e3 decodes too (-0.0 as 0). One outside the i64 range fails, a documented
            // divergence: Elm would answer with a double that eco's 64-bit Int cannot hold.
            if (!jval || (jctor != CTOR_JSON_INT && jctor != CTOR_JSON_FLOAT)) {
                return expecting("an INT", jvalHP);
            }
            i64 n;
            if (jctor == CTOR_JSON_INT) {
                n = jval->values[0].i;
            } else {
                f64 d = jval->values[0].f;
                if (!std::isfinite(d) || std::trunc(d) != d
                    || d < -9223372036854775808.0 || d >= 9223372036854775808.0) {
                    return expecting("an INT", jvalHP);
                }
                n = static_cast<i64>(d);
            }
            HPointer intVal = allocInt(n);
            return makeOk(intVal);
        }

        case DEC_FLOAT: {
            if (!jval || (jctor != CTOR_JSON_FLOAT && jctor != CTOR_JSON_INT)) {
                return expecting("a FLOAT", jvalHP);
            }
            f64 d;
            if (jctor == CTOR_JSON_FLOAT) {
                d = jval->values[0].f;
            } else {
                d = static_cast<f64>(jval->values[0].i);
            }
            HPointer floatVal = allocFloat(d);
            return makeOk(floatVal);
        }

        case DEC_NULL: {
            // JSON null is a constant, so `jval` is null here and only the ctor can be tested.
            if (jctor != CTOR_JSON_NULL) {
                return expecting("null", jvalHP);
            }
            HPointer fallback = decoder->values[0].p;
            return makeOk(fallback);
        }

        case DEC_VALUE: {
            return makeOk(jvalHP);
        }

        case DEC_LIST: {
            if (!jval || !isJsonArrayCtor(jctor)) {
                return expecting("a LIST", jvalHP);
            }

            // Each head's kind is read off the decoded value (decodedSlot). Every element has the
            // list's element type, so the kinds agree, and the chunk path takes the first one's.
            HPointer elemDecHP = decoder->values[0].p;
            u8 elemConsKind = 0;  // 0 = boxed

            const u32 len = jsonArrayLength(jval);

            // When the runtime builds lists from chunks, the heads go on its rooted scratch stack and
            // `eco_scratch_finish` builds one chunked list from them, instead of `len` cons cells. It
            // decodes in the same order as the cell path below, so both report the same failure, and
            // `eco_scratch_finish` reverses what was pushed, so both give the same list.
            if (eco_g_list_chunks) {
                StackRootGuard decRoots(&elemDecHP);
                int64_t mark = eco_scratch_mark();
                for (i64 i = static_cast<i64>(len) - 1; i >= 0; i--) {
                    uint64_t elemEnc = Export::encode(
                        jsonArrayAt(resolveJval(), static_cast<u32>(i)));
                    uint64_t elemResult = runDecoder(elemDecHP, elemEnc);
                    if (!isOk(elemResult)) {
                        eco_scratch_abandon(mark);
                        return firstFailingElement(elemDecHP, jvalHP, len);
                    }
                    HPointer elemVal = getOkValue(elemResult);
                    Unboxable slot;
                    u8 kind = decodedSlot(allocator, elemVal, slot);
                    if (i == static_cast<i64>(len) - 1) elemConsKind = kind;
                    if (kind != 0) {
                        eco_scratch_push_scalar(static_cast<uint64_t>(slot.i), kind);
                    } else {
                        eco_scratch_push_boxed(
                            HPtr::fromBits(hpBits(elemVal)));
                    }
                }
                HPtr chunked = eco_scratch_finish(
                    mark, HPtr::fromBits(hpBits(listNil())), elemConsKind);
                return makeOk(chunked.toHPointer());
            }

            // Decoding from the last element lets each head be prepended.
            HPointer result = listNil();
            StackRootGuard listRoots(&result, &elemDecHP);

            for (i64 i = static_cast<i64>(len) - 1; i >= 0; i--) {
                uint64_t elemEnc = Export::encode(
                    jsonArrayAt(resolveJval(), static_cast<u32>(i)));

                uint64_t elemResult = runDecoder(elemDecHP, elemEnc);
                if (!isOk(elemResult)) {
                    return firstFailingElement(elemDecHP, jvalHP, len);
                }
                HPointer elemVal = getOkValue(elemResult);

                Unboxable headSlot;
                elemConsKind = decodedSlot(allocator, elemVal, headSlot);
                // A boxed head is a handle and must be rooted across `cons`; an unboxed one is a number.
                if (elemConsKind == 0) {
                    StackRootGuard headRoot(&headSlot.p);
                    result = cons(headSlot, result, /*head_kind=*/(u8)0);
                } else {
                    result = cons(headSlot, result, /*head_kind=*/elemConsKind);
                }
            }
            return makeOk(result);
        }

        case DEC_ARRAY: {
            if (!jval || !isJsonArrayCtor(jctor)) {
                return expecting("an ARRAY", jvalHP);
            }

            HPointer elemDecHP = decoder->values[0].p;

            const u32 len = jsonArrayLength(jval);

            // Sized once and filled with Nil, a constant, so one record roots every decoded element.
            std::vector<HPointer> elements(len, alloc::listNil());

            auto& rs = allocator.getRootSet();
            size_t savedRoots = rs.stackRangePoint();
            rs.pushStackRootRange(&elemDecHP, 1, 1);
            rootBuffer(rs, elements);

            for (u32 i = 0; i < len; i++) {
                uint64_t elemEnc = Export::encode(jsonArrayAt(resolveJval(), i));

                uint64_t elemResult = runDecoder(elemDecHP, elemEnc);
                if (!isOk(elemResult)) {
                    rs.restoreStackRangePoint(savedRoots);
                    return wrapIndex(i, elemResult);
                }
                elements[i] = getOkValue(elemResult);
            }

            // As for a list, the slot kind comes from the decoded values, since `array (field "v" int)`
            // gives an Array Int too. Every element has the one element type, so the first decides.
            u8 elemKind = 0;
            if (len > 0) {
                Unboxable firstSlot;
                elemKind = decodedSlot(allocator, elements[0], firstSlot);
            }
            HPointer resultArr = buildElmArrayFromElements(elements, elemKind);
            rs.restoreStackRangePoint(savedRoots);
            return makeOk(resultArr);
        }

        case DEC_FIELD: {
            // `elmStringToStd` does not allocate, so `decoder` is still valid for the reads below.
            std::string fieldName =
                elmStringToStd(Export::encode(decoder->values[0].p));
            if (!jval || jctor != CTOR_JSON_OBJECT) {
                return expecting("an OBJECT with a field named `" + fieldName + "`", jvalHP);
            }
            HPointer fieldNameHP = decoder->values[0].p;
            HPointer nestedDecHP = decoder->values[1].p;

            // The first entry whose key matches is decoded; nothing below allocates until that call.
            // The name is rooted for the `Field` a failure is wrapped in.
            StackRootGuard fieldRoots(&nestedDecHP, &fieldNameHP);
            alloc::RootedListCursor kv(jval->values[0].p);
            Unboxable kvHead;
            u8 kvKind;

            while (kv.read(kvHead, kvKind)) {
                Tuple2* tup = static_cast<Tuple2*>(allocator.resolve(kvHead.p));
                HPointer keyHP = tup->a.p;
                HPointer valHP = tup->b.p;

                std::string key = elmStringToStd(Export::encode(keyHP));
                if (key == fieldName) {
                    uint64_t result = runDecoder(nestedDecHP, Export::encode(valHP));
                    return isOk(result) ? result : wrapField(fieldNameHP, result);
                }

                kv.advance();
            }

            return expecting("an OBJECT with a field named `" + fieldName + "`", jvalHP);
        }

        case DEC_INDEX: {
            if (!jval || !isJsonArrayCtor(jctor)) {
                return expecting("an ARRAY", jvalHP);
            }

            int64_t index = decoder->values[0].i;
            HPointer nestedDecHP = decoder->values[1].p;
            const u32 len = jsonArrayLength(jval);

            if (index < 0 || static_cast<u64>(index) >= len) {
                return expecting("a LONGER array. Need index " + std::to_string(index) +
                                     " but only see " + std::to_string(len) + " entries",
                                 jvalHP);
            }

            uint64_t elemEnc = Export::encode(jsonArrayAt(jval, static_cast<u32>(index)));
            uint64_t result = runDecoder(nestedDecHP, elemEnc);
            return isOk(result) ? result : wrapIndex(index, result);
        }

        case DEC_KEYVALUE: {
            if (!jval || jctor != CTOR_JSON_OBJECT) {
                return expecting("an OBJECT", jvalHP);
            }

            // Each tuple's value slot takes the kind read off its decoded value (decodedSlot).
            HPointer valDecHP = decoder->values[0].p;

            // Nothing allocates while the entries are collected, so a plain cursor is enough.
            std::vector<HPointer> tuples;
            for (alloc::ListCursor kv(jval->values[0].p); !kv.done(); kv.next()) {
                tuples.push_back(kv.current().p);
            }

            // The list is built by prepending from the last entry. The base roots below cover the
            // accumulator, the value decoder, the current key and every collected entry.
            HPointer result = listNil();
            HPointer keyStr = listNil();

            auto& rs = allocator.getRootSet();
            size_t kvSaved = rs.stackRangePoint();

            // Four records, whatever the number of entries.
            auto pushBaseRoots = [&]() {
                rs.pushStackRootRange(&result,    1, 1);
                rs.pushStackRootRange(&valDecHP,  1, 1);
                rs.pushStackRootRange(&keyStr,    1, 1);
                rootBuffer(rs, tuples);
            };
            pushBaseRoots();

            for (auto it = tuples.rbegin(); it != tuples.rend(); ++it) {
                Tuple2* srcTup = static_cast<Tuple2*>(allocator.resolve(*it));
                uint64_t valEnc = Export::encode(srcTup->b.p);
                keyStr = srcTup->a.p;

                uint64_t valResult = runDecoder(valDecHP, valEnc);
                if (!isOk(valResult)) {
                    rs.restoreStackRangePoint(kvSaved);
                    return firstFailingField(valDecHP, jvalHP);
                }

                HPointer decodedVal = getOkValue(valResult);

                Unboxable valSlot;
                u8 valKind = decodedSlot(allocator, decodedVal, valSlot);
                u64 tupleBitmap = static_cast<u64>(valKind) << 2;

                if (valKind == 0) rs.pushStackRootRange(&valSlot.p, 1, 1);
                HPointer resTup = tuple2(boxed(keyStr), valSlot, tupleBitmap);
                if (valKind == 0) {
                    rs.restoreStackRangePoint(kvSaved);
                    pushBaseRoots();
                }

                rs.pushStackRootRange(&resTup, 1, 1);
                result = cons(boxed(resTup), result, true);
                // Drop the `resTup` record, which `result` now reaches.
                rs.restoreStackRangePoint(kvSaved);
                pushBaseRoots();
            }
            rs.restoreStackRangePoint(kvSaved);
            return makeOk(result);
        }

        case DEC_SUCCEED: {
            return makeOk(decoder->values[0].p);
        }

        case DEC_FAIL: {
            std::string msg = elmStringToStd(Export::encode(decoder->values[0].p));
            return makeFailure(msg, jvalHP);
        }

        case DEC_ANDTHEN: {
            HPointer innerDecHP = decoder->values[1].p;
            HPointer callbackHP = decoder->values[0].p;

            uint64_t innerResult;
            {
                StackRootGuard guard(&callbackHP);
                innerResult = runDecoder(innerDecHP, Export::encode(jvalHP));
            }
            if (!isOk(innerResult)) return innerResult;

            HPointer value = getOkValue(innerResult);
            HPointer newDecHP;
            {
                StackRootGuard guard(&callbackHP, &value);
                uint64_t args[1] = { Export::encode(value) };
                uint64_t newDecEnc = eco_apply_closure(
                    HPtr::fromBits(Export::encode(callbackHP)), args, 1).toBits();
                newDecHP = Export::decode(newDecEnc);
            }

            return runDecoder(newDecHP, Export::encode(jvalHP));
        }

        case DEC_ONEOF: {
            // A rooted cursor, because each recursive call is a GC point. Every alternative's error is
            // kept, in order, for `OneOf`; they cross later decodes, so `RootedSlots` roots them all
            // with one record.
            alloc::RootedListCursor decs(decoder->values[0].p);
            Unboxable decHead;
            u8 decKind;
            Elm::alloc::RootedSlots errors;

            while (decs.read(decHead, decKind)) {
                uint64_t result = runDecoder(decHead.p, Export::encode(jvalHP));
                if (isOk(result)) {
                    return result;
                }
                errors.push(getErrValue(result));
                decs.advance();
            }

            HPointer errorList = listFromPointers(errors);
            StackRootGuard listRoot(&errorList);
            return makeErrResult(custom(ERR_ONE_OF, { boxed(errorList) }, 0));
        }

        case DEC_MAP1: {
            HPointer dec1HP = decoder->values[1].p;
            HPointer callbackHP = decoder->values[0].p;

            uint64_t result1;
            {
                StackRootGuard guard(&dec1HP, &callbackHP);
                result1 = runDecoder(dec1HP, Export::encode(jvalHP));
            }
            if (!isOk(result1)) return result1;

            HPointer v1 = getOkValue(result1);
            uint64_t mapped;
            {
                StackRootGuard guard(&callbackHP, &v1);
                uint64_t args[1] = { Export::encode(v1) };
                mapped = eco_apply_closure(
                    HPtr::fromBits(Export::encode(callbackHP)), args, 1).toBits();
            }
            return makeOk(Export::decode(mapped));
        }

        case DEC_MAP2: {
            HPointer dec1HP = decoder->values[1].p;
            HPointer dec2HP = decoder->values[2].p;
            HPointer callbackHP = decoder->values[0].p;

            uint64_t result1;
            {
                StackRootGuard guard(&dec2HP, &callbackHP);
                result1 = runDecoder(dec1HP, Export::encode(jvalHP));
            }
            if (!isOk(result1)) return result1;

            HPointer v1 = getOkValue(result1);
            uint64_t result2;
            {
                StackRootGuard guard(&v1, &callbackHP);
                result2 = runDecoder(dec2HP, Export::encode(jvalHP));
            }
            if (!isOk(result2)) return result2;

            HPointer v2 = getOkValue(result2);
            uint64_t mapped;
            {
                StackRootGuard guard(&v1, &v2, &callbackHP);
                uint64_t args[2] = { Export::encode(v1), Export::encode(v2) };
                mapped = eco_apply_closure(
                    HPtr::fromBits(Export::encode(callbackHP)), args, 2).toBits();
            }
            return makeOk(Export::decode(mapped));
        }

        case DEC_MAP3:
        case DEC_MAP4:
        case DEC_MAP5:
        case DEC_MAP6:
        case DEC_MAP7:
        case DEC_MAP8: {
            int n = decoder->ctor - DEC_MAP1 + 1;

            HPointer callbackHP = decoder->values[0].p;
            std::vector<HPointer> subDecHPs;
            subDecHPs.reserve(n);
            for (int i = 0; i < n; i++) {
                subDecHPs.push_back(decoder->values[i + 1].p);
            }

            // Every decoded value must stay rooted across the later sub-decoders and the closure call.
            std::vector<HPointer> results;
            results.reserve(n);

            auto& rs = allocator.getRootSet();
            size_t mapSaved = rs.stackRangePoint();
            rs.pushStackRootRange(&callbackHP, 1, 1);
            if (!subDecHPs.empty()) {
                rs.pushStackRootRange(subDecHPs.data(), subDecHPs.size(),
                                      /*hpointer_mask=*/~uint64_t(0));
            }

            for (int i = 0; i < n; i++) {
                uint64_t r = runDecoder(subDecHPs[i], Export::encode(jvalHP));
                if (!isOk(r)) {
                    rs.restoreStackRangePoint(mapSaved);
                    return r;
                }
                results.push_back(getOkValue(r));

                // Push the ranges again so that the `results` record covers the value just added.
                rs.restoreStackRangePoint(mapSaved);
                rs.pushStackRootRange(&callbackHP, 1, 1);
                if (!subDecHPs.empty()) {
                    rs.pushStackRootRange(subDecHPs.data(), subDecHPs.size(),
                                          /*hpointer_mask=*/~uint64_t(0));
                }
                rs.pushStackRootRange(results.data(), results.size(),
                                      /*hpointer_mask=*/~uint64_t(0));
            }

            uint64_t args[8];
            for (int i = 0; i < n; i++) {
                args[i] = Export::encode(results[i]);
            }
            uint64_t mapped = eco_apply_closure(
                HPtr::fromBits(Export::encode(callbackHP)), args, static_cast<u32>(n)).toBits();
            rs.restoreStackRangePoint(mapSaved);
            return makeOk(Export::decode(mapped));
        }

        default:
            return makeFailure("Unknown decoder type", jvalHP);
    }
}

//===----------------------------------------------------------------------===//
// Encoding Helper
//===----------------------------------------------------------------------===//

// Returns the nlohmann value for the `Json.Value` `valueEnc`, of either family. Does not allocate on
// the GC heap.
//
// An encoder-family array is emitted in the order its entries were added. An object of either family
// has its keys in JavaScript's order, and of two fields with the same key the key keeps its first
// position and takes the last value. A heap Int,
// Float or String that is not wrapped in an `ENC_*` Custom is emitted as that primitive, a Bool
// constant as a boolean, and anything else unrecognised as null.
static json elmToJson(uint64_t valueEnc) {
    auto& allocator = Allocator::instance();
    HPointer h = Export::decode(valueEnc);

    // `Json.wrap` puts every primitive in an `ENC_*` Custom, so in well-typed use a constant here is
    // `ENC_NULL` or `CTOR_JSON_NULL`.
    if (isConstantBits(valueEnc)) {
        if (isBoolConst(h)) return json(boolValue(h));
        return json(nullptr);
    }

    void* ptr = Export::toPtr(valueEnc);
    if (!ptr) return json(nullptr);

    Header* header = static_cast<Header*>(ptr);

    if (header->tag == Tag_Custom) {
        Custom* c = static_cast<Custom*>(ptr);

        switch (c->ctor) {
            case ENC_NULL:
                return json(nullptr);

            case ENC_BOOL: {
                HPointer boolVal = c->values[0].p;
                return json(boolValue(boolVal));
            }

            case ENC_INT:
                return json(c->values[0].i);

            case ENC_FLOAT:
                return json(c->values[0].f);

            case ENC_STRING:
                return json(elmStringToStd(Export::encode(c->values[0].p)));

            case ENC_ARRAY: {
                // `addEntry` prepends, so the list is newest first.
                std::vector<json> elements;
                for (alloc::ListCursor l(c->values[0].p); !l.done(); l.next()) {
                    elements.push_back(elmToJson(Export::encode(l.current().p)));
                }
                std::reverse(elements.begin(), elements.end());
                return json(elements);
            }

            case ENC_OBJECT: {
                // `addField` prepends, so the list is newest first; the fields are appended in the
                // order the program gave them, then deduplicated and put in JavaScript's order.
                std::vector<HPointer> fields;
                for (alloc::ListCursor l(c->values[0].p); !l.done(); l.next()) {
                    fields.push_back(l.current().p);
                }
                json obj = json::object();
                for (auto it = fields.rbegin(); it != fields.rend(); ++it) {
                    Tuple2* tuple = static_cast<Tuple2*>(allocator.resolve(*it));
                    appendMember(obj, elmStringToStd(Export::encode(tuple->a.p)),
                                 elmToJson(Export::encode(tuple->b.p)));
                }
                dedupeObject(obj);
                putInJsKeyOrder(obj);
                return obj;
            }

            case CTOR_JSON_NULL:
            case CTOR_JSON_BOOL:
            case CTOR_JSON_INT:
            case CTOR_JSON_FLOAT:
            case CTOR_JSON_STRING:
            case CTOR_JSON_ARRAY:
            case CTOR_JSON_ARRAY_CHUNKED:
            case CTOR_JSON_OBJECT:
                return heapJsonToNlohmann(valueEnc);

            default:
                break;
        }
    }

    if (header->tag == Tag_Int) {
        ElmInt* i = static_cast<ElmInt*>(ptr);
        return json(i->value);
    }

    if (header->tag == Tag_Float) {
        ElmFloat* f = static_cast<ElmFloat*>(ptr);
        return json(f->value);
    }

    if (isString(ptr)) {
        return json(elmStringToStd(valueEnc));
    }

    return json(nullptr);
}

//===----------------------------------------------------------------------===//
// Serializer - JSON text as JavaScript's JSON.stringify writes it
//===----------------------------------------------------------------------===//

// Decodes the sequence that starts at `p[0]`, of `n` > 0 bytes, as WTF-8: UTF-8 that may also hold
// a surrogate (U+D800-U+DFFF) as the three bytes `ED A0-BF xx`, which is how `StringOps::toStdString`
// writes a lone surrogate. Sets `len` to the length of the sequence and returns its code point, or
// returns -1 with `len` 1 when the byte at `p[0]` does not start a well-formed sequence.
static int32_t decodeWtf8(const unsigned char* p, size_t n, size_t& len) {
    auto cont = [&](size_t k, unsigned char lo, unsigned char hi) {
        return k < n && p[k] >= lo && p[k] <= hi;
    };
    unsigned char c = p[0];
    len = 1;
    if (c < 0x80) return c;
    if (c >= 0xC2 && c <= 0xDF && cont(1, 0x80, 0xBF)) {
        len = 2;
        return ((c & 0x1F) << 6) | (p[1] & 0x3F);
    }
    if (c >= 0xE0 && c <= 0xEF && cont(1, c == 0xE0 ? 0xA0 : 0x80, 0xBF) && cont(2, 0x80, 0xBF)) {
        len = 3;
        return ((c & 0x0F) << 12) | ((p[1] & 0x3F) << 6) | (p[2] & 0x3F);
    }
    if (c >= 0xF0 && c <= 0xF4 && cont(1, c == 0xF0 ? 0x90 : 0x80, c == 0xF4 ? 0x8F : 0xBF)
        && cont(2, 0x80, 0xBF) && cont(3, 0x80, 0xBF)) {
        len = 4;
        return ((c & 0x07) << 18) | ((p[1] & 0x3F) << 12) | ((p[2] & 0x3F) << 6) | (p[3] & 0x3F);
    }
    return -1;
}

// Appends the code point `cp`, which is not a surrogate, to `out` as UTF-8.
static void appendUtf8(int32_t cp, std::string& out) {
    if (cp < 0x80) {
        out.push_back(static_cast<char>(cp));
    } else if (cp < 0x800) {
        out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    } else {
        out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
    }
}

// Appends the WTF-8 text `s` to `out` as a JSON string literal, as `JSON.stringify` quotes a string.
//
// `"` and `\` are escaped, as are `\b \f \n \r \t`, and every other character below U+0020 is written
// `\u00xx`. A lone surrogate is written `\udxxx`; a surrogate pair is joined into its code point.
// Every other character is copied as it is, so the result is always valid UTF-8. A byte that starts no
// well-formed sequence, which an Elm String never produces, is written as U+FFFD.
static void writeJsString(const std::string& s, std::string& out) {
    static constexpr char hex[] = "0123456789abcdef";
    const auto* p = reinterpret_cast<const unsigned char*>(s.data());
    const size_t n = s.size();
    out.push_back('"');
    size_t i = 0;
    while (i < n) {
        unsigned char c = p[i];
        if (c < 0x80) {
            switch (c) {
                case '"':  out += "\\\""; break;
                case '\\': out += "\\\\"; break;
                case '\b': out += "\\b"; break;
                case '\f': out += "\\f"; break;
                case '\n': out += "\\n"; break;
                case '\r': out += "\\r"; break;
                case '\t': out += "\\t"; break;
                default:
                    if (c < 0x20) {
                        out += "\\u00";
                        out.push_back(hex[c >> 4]);
                        out.push_back(hex[c & 0xF]);
                    } else {
                        out.push_back(static_cast<char>(c));
                    }
                    break;
            }
            ++i;
            continue;
        }
        size_t len;
        int32_t cp = decodeWtf8(p + i, n - i, len);
        if (cp < 0) {
            out += "\xEF\xBF\xBD";
        } else if (cp >= 0xD800 && cp <= 0xDFFF) {
            size_t len2 = 0;
            int32_t lo = (cp <= 0xDBFF && i + len < n) ? decodeWtf8(p + i + len, n - i - len, len2) : -1;
            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                appendUtf8(0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00), out);
                len += len2;
            } else {
                out += "\\u";
                for (int shift = 12; shift >= 0; shift -= 4) out.push_back(hex[(cp >> shift) & 0xF]);
            }
        } else {
            out.append(s, i, len);
        }
        i += len;
    }
    out.push_back('"');
}

// Appends `j` to `out` as `JSON.stringify(j, null, indent)` writes it, where `level` is the nesting
// depth of `j`. Does not allocate on the GC heap.
//
// An `indent` above 0 puts each array element and object member on its own line, indented by
// `indent` spaces per level, with `": "` after a key; an empty array or object is `[]` or `{}`. 0
// writes everything on one line with no whitespace. A float is written as `Number.prototype.toString`
// writes it (`3`, `1e+21`, `1.5e-7`), and NaN and the infinities as `null`. An integer is written in
// full: unlike JavaScript, eco keeps all 64 bits of an Int. Object members are written in their
// stored order, which is already JavaScript's.
static void writeJsJson(const json& j, int indent, int level, std::string& out) {
    auto newline = [&](int depth) {
        out.push_back('\n');
        out.append(static_cast<size_t>(indent) * static_cast<size_t>(depth), ' ');
    };
    switch (j.type()) {
        case json::value_t::boolean:
            out += j.get<bool>() ? "true" : "false";
            return;
        case json::value_t::number_integer:
        case json::value_t::number_unsigned: {
            char buf[24];
            auto [end, ec] = j.is_number_unsigned()
                ? std::to_chars(buf, buf + sizeof(buf), j.get<uint64_t>())
                : std::to_chars(buf, buf + sizeof(buf), j.get<i64>());
            (void)ec;
            out.append(buf, end);
            return;
        }
        case json::value_t::number_float: {
            f64 d = j.get<f64>();
            if (!std::isfinite(d)) {
                out += "null";
                return;
            }
            char buf[32];
            out.append(buf, StringOps::formatFloatShortest(d, buf));
            return;
        }
        case json::value_t::string:
            writeJsString(j.get_ref<const json::string_t&>(), out);
            return;
        case json::value_t::array: {
            const auto& elems = j.get_ref<const json::array_t&>();
            if (elems.empty()) {
                out += "[]";
                return;
            }
            out.push_back('[');
            for (size_t i = 0; i < elems.size(); ++i) {
                if (i > 0) out.push_back(',');
                if (indent > 0) newline(level + 1);
                writeJsJson(elems[i], indent, level + 1, out);
            }
            if (indent > 0) newline(level);
            out.push_back(']');
            return;
        }
        case json::value_t::object: {
            const JsonMembers& members =
                static_cast<const JsonMembers&>(j.get_ref<const json::object_t&>());
            if (members.empty()) {
                out += "{}";
                return;
            }
            out.push_back('{');
            for (size_t i = 0; i < members.size(); ++i) {
                if (i > 0) out.push_back(',');
                if (indent > 0) newline(level + 1);
                writeJsString(members[i].first, out);
                out += indent > 0 ? ": " : ":";
                writeJsJson(members[i].second, indent, level + 1, out);
            }
            if (indent > 0) newline(level);
            out.push_back('}');
            return;
        }
        case json::value_t::null:
        case json::value_t::binary:
        case json::value_t::discarded:
            break;
    }
    out += "null";
}

//===----------------------------------------------------------------------===//
// Extern C Functions
//===----------------------------------------------------------------------===//

extern "C" {

//===----------------------------------------------------------------------===//
// Primitive Decoders
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Json_decodeString() {
    return HPtr::fromBits(makeDecoder0(DEC_STRING));
}

HPtr Elm_Kernel_Json_decodeBool() {
    return HPtr::fromBits(makeDecoder0(DEC_BOOL));
}

HPtr Elm_Kernel_Json_decodeInt() {
    return HPtr::fromBits(makeDecoder0(DEC_INT));
}

HPtr Elm_Kernel_Json_decodeFloat() {
    return HPtr::fromBits(makeDecoder0(DEC_FLOAT));
}

HPtr Elm_Kernel_Json_decodeNull(HPtr fallback) {
    return HPtr::fromBits(makeDecoder1(DEC_NULL, fallback.toBits()));
}

HPtr Elm_Kernel_Json_decodeList(HPtr decoder) {
    return HPtr::fromBits(makeDecoder1(DEC_LIST, decoder.toBits()));
}

HPtr Elm_Kernel_Json_decodeArray(HPtr decoder) {
    return HPtr::fromBits(makeDecoder1(DEC_ARRAY, decoder.toBits()));
}

HPtr Elm_Kernel_Json_decodeField(HPtr fieldName, HPtr decoder) {
    return HPtr::fromBits(makeDecoder2(DEC_FIELD, fieldName.toBits(), decoder.toBits()));
}

HPtr Elm_Kernel_Json_decodeIndex(int64_t index, HPtr decoder) {
    return HPtr::fromBits(makeDecoder2ip(DEC_INDEX, index, decoder.toBits()));
}

HPtr Elm_Kernel_Json_decodeKeyValuePairs(HPtr decoder) {
    return HPtr::fromBits(makeDecoder1(DEC_KEYVALUE, decoder.toBits()));
}

HPtr Elm_Kernel_Json_decodeValue() {
    return HPtr::fromBits(makeDecoder0(DEC_VALUE));
}

//===----------------------------------------------------------------------===//
// Decoder Combinators
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Json_succeed(HPtr value) {
    return HPtr::fromBits(makeDecoder1(DEC_SUCCEED, value.toBits()));
}

HPtr Elm_Kernel_Json_fail(HPtr message) {
    return HPtr::fromBits(makeDecoder1(DEC_FAIL, message.toBits()));
}

HPtr Elm_Kernel_Json_andThen(HPtr closure, HPtr decoder) {
    return HPtr::fromBits(makeDecoder2(DEC_ANDTHEN, closure.toBits(), decoder.toBits()));
}

HPtr Elm_Kernel_Json_oneOf(HPtr decoders) {
    return HPtr::fromBits(makeDecoder1(DEC_ONEOF, decoders.toBits()));
}

//===----------------------------------------------------------------------===//
// Map Functions
//===----------------------------------------------------------------------===//

HPtr Elm_Kernel_Json_map1(HPtr closure, HPtr d1) {
    return HPtr::fromBits(makeDecoder2(DEC_MAP1, closure.toBits(), d1.toBits()));
}

// Allocates a `mapN` decoder with ctor `ctor` and `nFields` boxed fields, the closure followed by the
// decoders, from `args` in that order. Every argument is rooted across the allocation. `args` must
// hold exactly `nFields` words.
static uint64_t buildMapDecoder(u16 ctor, u32 nFields, std::initializer_list<uint64_t> args) {
    std::vector<uint64_t> roots;
    roots.reserve(args.size());
    for (uint64_t a : args) {
        HPointer hp = Export::decode(a);
        uint64_t b;
        std::memcpy(&b, &hp, sizeof(b));
        roots.push_back(b);
    }

    size_t size = sizeof(Custom) + nFields * sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t mask = (roots.size() >= 64) ? ~uint64_t{0}
                                         : ((uint64_t{1} << roots.size()) - 1);
    Custom* dec = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots.data(),
                             static_cast<uint32_t>(roots.size()), mask));
    dec->header.size = nFields;
    dec->ctor = ctor;
    dec->unboxed = 0;
    for (size_t i = 0; i < roots.size(); ++i) {
        std::memcpy(&dec->values[i].p, &roots[i], sizeof(HPointer));
    }
    return Export::encode(Allocator::instance().wrap(dec));
}

HPtr Elm_Kernel_Json_map2(HPtr closure, HPtr d1, HPtr d2) {
    return HPtr::fromBits(buildMapDecoder(DEC_MAP2, 3,
        { closure.toBits(), d1.toBits(), d2.toBits() }));
}

HPtr Elm_Kernel_Json_map3(HPtr closure, HPtr d1, HPtr d2, HPtr d3) {
    return HPtr::fromBits(buildMapDecoder(DEC_MAP3, 4,
        { closure.toBits(), d1.toBits(), d2.toBits(), d3.toBits() }));
}

HPtr Elm_Kernel_Json_map4(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4) {
    return HPtr::fromBits(buildMapDecoder(DEC_MAP4, 5,
        { closure.toBits(), d1.toBits(), d2.toBits(), d3.toBits(), d4.toBits() }));
}

HPtr Elm_Kernel_Json_map5(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4, HPtr d5) {
    return HPtr::fromBits(buildMapDecoder(DEC_MAP5, 6,
        { closure.toBits(), d1.toBits(), d2.toBits(), d3.toBits(), d4.toBits(), d5.toBits() }));
}

HPtr Elm_Kernel_Json_map6(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4, HPtr d5, HPtr d6) {
    return HPtr::fromBits(buildMapDecoder(DEC_MAP6, 7,
        { closure.toBits(), d1.toBits(), d2.toBits(), d3.toBits(), d4.toBits(), d5.toBits(), d6.toBits() }));
}

HPtr Elm_Kernel_Json_map7(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4, HPtr d5, HPtr d6, HPtr d7) {
    return HPtr::fromBits(buildMapDecoder(DEC_MAP7, 8,
        { closure.toBits(), d1.toBits(), d2.toBits(), d3.toBits(), d4.toBits(), d5.toBits(), d6.toBits(), d7.toBits() }));
}

HPtr Elm_Kernel_Json_map8(HPtr closure, HPtr d1, HPtr d2, HPtr d3, HPtr d4, HPtr d5, HPtr d6, HPtr d7, HPtr d8) {
    return HPtr::fromBits(buildMapDecoder(DEC_MAP8, 9,
        { closure.toBits(), d1.toBits(), d2.toBits(), d3.toBits(), d4.toBits(), d5.toBits(), d6.toBits(), d7.toBits(), d8.toBits() }));
}

//===----------------------------------------------------------------------===//
// Running Decoders
//===----------------------------------------------------------------------===//

//===----------------------------------------------------------------------===//
// Escape-point rewrap
//===----------------------------------------------------------------------===//

// Returns `result` with a boxed Int, Float or Char `Ok` payload replaced by a new `Ok` holding the
// number unboxed, with its slot kind; any other `result` is returned unchanged. May allocate.
//
// Compiled code decides the layout of a heap field from the field's type alone, and for
// `Result Error Int` it reads the `Ok` payload as an unboxed Int without looking at the header's kind
// bits. Inside this file every `Ok` payload is boxed, because primitives reach the kernel boxed and
// `getOkValue` and the decoder recursion read them that way. So a `Result` is rewritten here, at the
// escape points and nowhere else. Constants, strings, Customs and `Err` results already have the
// layout compiled code expects.
static uint64_t rewrapEscapingResult(uint64_t result) {
    void* ptr = Export::toPtr(result);
    if (!ptr) return result;
    Custom* c = static_cast<Custom*>(ptr);
    if (c->ctor != 0 || c->header.size != 1 || (c->unboxed & 0x3) != 0) {
        return result;
    }
    HPointer payload = c->values[0].p;
    if (isConstant(payload)) return result;
    void* p = Allocator::instance().resolve(payload);
    Header* h = static_cast<Header*>(p);
    // The number is copied out before the allocation, and the old box and `Ok` are not used after it,
    // so nothing needs rooting.
    Unboxable v;
    u64 kind;
    switch (h->tag) {
        case Tag_Int:
            v.i = static_cast<ElmInt*>(p)->value;
            kind = 1;
            break;
        case Tag_Float:
            v.f = static_cast<ElmFloat*>(p)->value;
            kind = 2;
            break;
        case Tag_Char:
            v = alloc::unboxedChar(static_cast<ElmChar*>(p)->value);
            kind = 3;
            break;
        default:
            return result;
    }
    return Export::encode(alloc::custom(0, { v }, kind));
}

// Implementation: a decoder must be a null-cons constant or a heap object; anything else gives
// `Err` "Invalid decoder". An encoder-family `value` is converted to the decoder family first.
HPtr Elm_Kernel_Json_run(HPtr decoder, HPtr value) {
    HPointer decoderHP = Export::decode(decoder.toBits());
    if (!isNullConsBits(decoder.toBits()) &&
        (decoderHP.ptr_ind != 0 ||
         !Allocator::instance().resolve(decoderHP))) {
        return HPtr::fromBits(makeFailure("Invalid decoder", Export::decode(value.toBits())));
    }
    uint64_t valueBits = value.toBits();
    // `Json.Encode.null` is the `ENC_NULL` constant, which `Decode.null` would not recognise.
    if (isNullConsBits(valueBits) && nullConsTagBits(valueBits) == ENC_NULL) {
        valueBits = nullConsWordFor(CTOR_JSON_NULL);
    }
    // An encoder-family Custom is converted through nlohmann. A heap Custom here is a `Json.Value`,
    // so a ctor no greater than `ENC_OBJECT` means the encoder family.
    if (!isConstantBits(valueBits)) {
        void* vptr = Export::toPtr(valueBits);
        if (vptr) {
            Header* vh = static_cast<Header*>(vptr);
            if (vh->tag == Tag_Custom &&
                static_cast<Custom*>(vptr)->ctor <= ENC_OBJECT) {
                json j = elmToJson(valueBits);
                StackRootGuard guard(&decoderHP);
                valueBits = Export::encode(jsonToHeap(j));
            }
        }
    }
    return HPtr::fromBits(
        rewrapEscapingResult(runDecoder(decoderHP, valueBits)));
}

// Implementation: text that does not parse gives `Err (Failure ("This is not valid JSON! " ++ message)
// string)`, as elm/json does, where `message` is the parser's own and `string` is the text as a
// `Json.Value`.
HPtr Elm_Kernel_Json_runOnString(HPtr decoder, HPtr jsonString) {
    uint64_t jsonStringEnc = jsonString.toBits();
    std::string str = elmStringToStd(jsonStringEnc);

    json jval;
    std::string parseError;
    if (!parseJson(str, jval, parseError)) {
        HPointer strHP = Export::decode(jsonStringEnc);
        HPointer jsonStr;
        {
            StackRootGuard guard(&strHP);
            jsonStr = makeJsonString(strHP);
        }
        return HPtr::fromBits(makeFailure("This is not valid JSON! " + parseError, jsonStr));
    }

    // `jsonToHeap` allocates, so the decoder is rooted across it.
    HPointer decoderHP = Export::decode(decoder.toBits());
    HPointer heapJson;
    {
        StackRootGuard guard(&decoderHP);
        heapJson = jsonToHeap(jval);
    }

    return HPtr::fromBits(
        rewrapEscapingResult(runDecoder(decoderHP, Export::encode(heapJson))));
}

//===----------------------------------------------------------------------===//
// Encoding
//===----------------------------------------------------------------------===//

// Implementation: the text is what `JSON.stringify(value, null, indent)` gives (`writeJsJson`). An
// `indent` above 0 prints one element or field per line, indented by `indent` spaces per level, at
// most 10 as in JavaScript; 0 or less prints on one line with no whitespace between tokens. No C++
// exception leaves this export: one that would, such as `std::bad_alloc`, ends the process with a
// message instead of unwinding through compiled code.
HPtr Elm_Kernel_Json_encode(int64_t indent, HPtr value) {
    uint64_t valueEnc = value.toBits();
    std::string str;
    try {
        json j = elmToJson(valueEnc);
        writeJsJson(j, static_cast<int>(std::clamp<int64_t>(indent, 0, 10)), 0, str);
    } catch (const std::exception& e) {
        std::fprintf(stderr, "Elm runtime error: Json.Encode.encode failed: %s\n", e.what());
        std::abort();
    }
    HPointer result = allocElmString(str);
    return HPtr::fromBits(Export::encode(result));
}

// Implementation: `value` arrives boxed. A Bool constant, the empty-String constant, a heap Int, a
// heap Float or a String of any form is wrapped in a new `ENC_*` Custom; any other constant becomes
// `ENC_NULL`; any other heap value, such as an array or object `Json.Value`, is returned as it is.
HPtr Elm_Kernel_Json_wrap(HPtr value) {
    uint64_t valueEnc = value.toBits();
    auto& allocator = Allocator::instance();
    HPointer h = Export::decode(valueEnc);

    if (isBoolConst(h)) {
        size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
        Custom* enc = static_cast<Custom*>(
            eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
        enc->header.size = 1;
        enc->ctor = ENC_BOOL;
        enc->unboxed = 0;
        enc->values[0].p = h;
        return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
    }

    // `Json.Encode.string ""` arrives as the empty-String constant, which needs no rooting.
    if (isEmptyString(h)) {
        size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
        Custom* enc = static_cast<Custom*>(
            eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
        enc->header.size = 1;
        enc->ctor = ENC_STRING;
        enc->unboxed = 0;
        enc->values[0].p = h;
        return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
    }

    if (isConstantBits(valueEnc)) {
        return Elm_Kernel_Json_encodeNull();
    }

    void* ptr = Export::toPtr(valueEnc);
    if (!ptr) return Elm_Kernel_Json_encodeNull();

    Header* header = static_cast<Header*>(ptr);

    if (header->tag == Tag_Int) {
        // Read before the allocation, which may move the box.
        int64_t intVal = static_cast<ElmInt*>(ptr)->value;
        size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
        Custom* enc = static_cast<Custom*>(
            eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
        enc->header.size = 1;
        enc->ctor = ENC_INT;
        enc->unboxed = 1;
        enc->values[0].i = intVal;
        return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
    }

    if (header->tag == Tag_Float) {
        // Read before the allocation, which may move the box.
        double floatVal = static_cast<ElmFloat*>(ptr)->value;
        size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
        Custom* enc = static_cast<Custom*>(
            eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
        enc->header.size = 1;
        enc->ctor = ENC_FLOAT;
        enc->unboxed = 2;  // Float in slot 0
        enc->values[0].f = floatVal;
        return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
    }

    // `isString`, not a test for `Tag_String`: a slice or rope String has another tag.
    if (isString(ptr)) {
        size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
        uint64_t roots[1];
        std::memcpy(&roots[0], &h, sizeof(h));
        Custom* enc = static_cast<Custom*>(
            eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
        std::memcpy(&h, &roots[0], sizeof(h));
        enc->header.size = 1;
        enc->ctor = ENC_STRING;
        enc->unboxed = 0;
        enc->values[0].p = h;
        return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
    }

    return value;
}

// The `_Int`, `_Float` and `_Char` variants of `Json.wrap` take the number unboxed and build the
// `ENC_*` Custom straight from it. A Char becomes an `ENC_INT` holding its code point, since JSON has
// no character type.
HPtr Elm_Kernel_Json_wrap_Int(int64_t value) {
    auto& allocator = Allocator::instance();
    size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    enc->header.size = 1;
    enc->ctor = ENC_INT;
    enc->unboxed = 1;  // Int in slot 0
    enc->values[0].i = value;
    return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
}

HPtr Elm_Kernel_Json_wrap_Float(double value) {
    auto& allocator = Allocator::instance();
    size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    enc->header.size = 1;
    enc->ctor = ENC_FLOAT;
    enc->unboxed = 2;  // Float in slot 0
    enc->values[0].f = value;
    return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
}

// Implementation: the code point is the low 32 bits of `value_raw`, as for every Char crossing the
// kernel ABI (`elm-kernel-cpp/KernelExports`).
HPtr Elm_Kernel_Json_wrap_Char(uint64_t value_raw) {
    const uint32_t value = static_cast<uint32_t>(value_raw & 0xFFFFFFFFu);
    auto& allocator = Allocator::instance();
    size_t size = (sizeof(Custom) + sizeof(Unboxable) + 7) & ~7;
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    enc->header.size = 1;
    enc->ctor = ENC_INT;
    enc->unboxed = 1;
    enc->values[0].i = static_cast<int64_t>(value);
    return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
}

// Implementation: the result is the null-cons constant for `ENC_NULL`; nothing is allocated.
HPtr Elm_Kernel_Json_encodeNull() {
    return HPtr::fromBits(nullConsWordFor(ENC_NULL));
}

HPtr Elm_Kernel_Json_emptyArray() {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    enc->header.size = 1;
    enc->ctor = ENC_ARRAY;
    enc->unboxed = 0;
    enc->values[0].p = listNil();
    return HPtr::fromBits(Export::encode(Allocator::instance().wrap(enc)));
}

HPtr Elm_Kernel_Json_emptyObject() {
    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, nullptr, 0, 0));
    enc->header.size = 1;
    enc->ctor = ENC_OBJECT;
    enc->unboxed = 0;
    enc->values[0].p = listNil();
    return HPtr::fromBits(Export::encode(Allocator::instance().wrap(enc)));
}

// Implementation: returns a new `ENC_ARRAY` whose list is `func entry` prepended to `array`'s list,
// so the list is newest first; `elmToJson` reverses it. `array` itself is not changed.
HPtr Elm_Kernel_Json_addEntry(HPtr func, HPtr entry, HPtr array) {
    auto& allocator = Allocator::instance();

    HPointer arrayHP = Export::decode(array.toBits());
    HPointer encodedHP;
    {
        StackRootGuard guard(&arrayHP);
        uint64_t args[] = { entry.toBits() };
        uint64_t encoded = eco_apply_closure(func, args, 1).toBits();
        encodedHP = Export::decode(encoded);
    }

    HPointer newList;
    {
        StackRootGuard guard(&arrayHP, &encodedHP);
        Custom* arr = static_cast<Custom*>(allocator.resolve(arrayHP));
        HPointer tailHP = arr->values[0].p;
        StackRootGuard guard2(&tailHP);
        newList = cons(boxed(encodedHP), tailHP, true);
    }

    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t roots[1];
    std::memcpy(&roots[0], &newList, sizeof(newList));
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&newList, &roots[0], sizeof(newList));
    enc->header.size = 1;
    enc->ctor = ENC_ARRAY;
    enc->unboxed = 0;
    enc->values[0].p = newList;

    return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
}

// Implementation: returns a new `ENC_OBJECT` whose list is the Tuple2 (`key`, `value`) prepended to
// `object`'s list, so the list is newest first. `object` itself is not changed.
HPtr Elm_Kernel_Json_addField(HPtr key, HPtr value, HPtr object) {
    auto& allocator = Allocator::instance();
    HPointer keyHP    = Export::decode(key.toBits());
    HPointer valueHP  = Export::decode(value.toBits());
    HPointer objectHP = Export::decode(object.toBits());

    // `keyHP` and `valueHP` are rooted by the allocation itself, `objectHP` by the guard.
    HPointer tupleHP;
    {
        StackRootGuard guardObj(&objectHP);
        uint64_t roots[2];
        std::memcpy(&roots[0], &keyHP, sizeof(keyHP));
        std::memcpy(&roots[1], &valueHP, sizeof(valueHP));
        Tuple2* tuple = static_cast<Tuple2*>(
            eco_alloc_with_roots(Tag_Tuple2, sizeof(Tuple2), roots, 2, 0x3));
        std::memcpy(&keyHP, &roots[0], sizeof(keyHP));
        std::memcpy(&valueHP, &roots[1], sizeof(valueHP));
        tuple->header.unboxed = 0;
        tuple->a.p = keyHP;
        tuple->b.p = valueHP;
        tupleHP = allocator.wrap(tuple);
    }

    HPointer newList;
    {
        StackRootGuard guard(&tupleHP, &objectHP);
        Custom* obj = static_cast<Custom*>(allocator.resolve(objectHP));
        HPointer tailHP = obj->values[0].p;
        StackRootGuard guard2(&tailHP);
        newList = cons(boxed(tupleHP), tailHP, true);
    }

    size_t size = sizeof(Custom) + sizeof(Unboxable);
    size = (size + 7) & ~7;
    uint64_t roots[1];
    std::memcpy(&roots[0], &newList, sizeof(newList));
    Custom* enc = static_cast<Custom*>(
        eco_alloc_with_roots(Tag_Custom, size, roots, 1, 0x1));
    std::memcpy(&newList, &roots[0], sizeof(newList));
    enc->header.size = 1;
    enc->ctor = ENC_OBJECT;
    enc->unboxed = 0;
    enc->values[0].p = newList;

    return HPtr::fromBits(Export::encode(allocator.wrap(enc)));
}

} // extern "C"
