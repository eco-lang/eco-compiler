//===- JsonRead.cpp - Read-only view of Json.Value heap forms ---------------===//
//
// Every walk here holds raw addresses from `Export::toPtr` and `Allocator::resolve` while it reads.
// They stay valid only because nothing in this file allocates on the Elm heap or calls Elm, so no
// collection can run in the middle of a walk. A change that allocates must re-derive them.
//
//===----------------------------------------------------------------------===//

#include "JsonRead.hpp"
#include "../ExportHelpers.hpp"
#include "allocator/HeapHelpers.hpp"
#include "allocator/StringOps.hpp"

#include <algorithm>

namespace Elm::Kernel::JsonRead {

namespace {

// Returns the word of element `i` of the decoder-family array `jarr`, chunked or not, read the way
// `jsonArrayAt` in `JsonExports.cpp` reads it. `i` must be less than `jsonArrayLength(jarr)`; nothing
// checks it.
//
// The chunk length is read from chunk 0, which is full whenever there is more than one chunk.
uint64_t jsonArrayAt(Custom* jarr, u32 i) {
    auto& allocator = Allocator::instance();
    ElmArray* top = static_cast<ElmArray*>(allocator.resolve(jarr->values[0].p));
    if (jarr->ctor != CTOR_JSON_ARRAY_CHUNKED) return Export::encode(top->elements[i].p);
    const u32 F = static_cast<ElmArray*>(allocator.resolve(top->elements[0].p))->length;
    ElmArray* chunk = static_cast<ElmArray*>(allocator.resolve(top->elements[i / F].p));
    return Export::encode(chunk->elements[i % F].p);
}

// Returns the number of elements of the decoder-family array `jarr`, chunked or not.
u32 jsonArrayLength(Custom* jarr) {
    if (jarr->ctor == CTOR_JSON_ARRAY_CHUNKED) return static_cast<u32>(jarr->values[1].i);
    return static_cast<ElmArray*>(Allocator::instance().resolve(jarr->values[0].p))->length;
}

// Appends the `n` ASCII characters at `s` to `out`, one UTF-16 unit each.
void appendAscii(std::u16string& out, const char* s, size_t n) {
    for (size_t i = 0; i < n; ++i) out.push_back(static_cast<char16_t>(s[i]));
}

void appendJs(uint64_t bits, std::u16string& out, int depth);

// Appends the elements of the array `v` to `out`, rendered by `appendJs` and joined by commas.
// `depth` is the nesting depth of `v`; past 256 nothing is appended.
void appendArray(const View& v, std::u16string& out, int depth) {
    if (depth > 256) return;
    std::vector<uint64_t> elems;
    arrayElements(v, elems);
    for (size_t i = 0; i < elems.size(); ++i) {
        if (i > 0) out.push_back(u',');
        appendJs(elems[i], out, depth + 1);
    }
}

// Appends to `out` the value word `bits` as `Array.prototype.join` renders an element, where `depth`
// is the nesting depth of the array that holds it.
void appendJs(uint64_t bits, std::u16string& out, int depth) {
    View v = view(bits);
    switch (v.kind) {
        case Kind::Null:
            return;   // join renders null as the empty string
        case Kind::Bool:
            if (v.boolean) appendAscii(out, "true", 4);
            else appendAscii(out, "false", 5);
            return;
        case Kind::Number: {
            char buf[32];
            size_t n = StringOps::formatFloatShortest(v.number, buf);
            appendAscii(out, buf, n);
            return;
        }
        case Kind::String:
            out += StringOps::toStdU16String(v.string);
            return;
        case Kind::Array:
            appendArray(v, out, depth);
            return;
        case Kind::Object:
            appendAscii(out, "[object Object]", 15);
            return;
    }
}

} // namespace

View view(uint64_t valueBits) {
    View v;
    v.bits = valueBits;
    if (isConstantBits(valueBits)) {
        HPointer h = Export::decode(valueBits);
        if (alloc::isBoolConst(h)) {
            v.kind = Kind::Bool;
            v.boolean = alloc::boolValue(h);
        }
        return v;
    }
    void* ptr = Export::toPtr(valueBits);
    if (!ptr) return v;
    Header* hdr = static_cast<Header*>(ptr);
    if (hdr->tag == Tag_Int) {
        v.kind = Kind::Number;
        v.number = static_cast<double>(static_cast<ElmInt*>(ptr)->value);
        return v;
    }
    if (hdr->tag == Tag_Float) {
        v.kind = Kind::Number;
        v.number = static_cast<ElmFloat*>(ptr)->value;
        return v;
    }
    if (hdr->tag != Tag_Custom) {
        if (alloc::isString(ptr)) {
            v.kind = Kind::String;
            v.string = ptr;
        }
        return v;
    }
    Custom* c = static_cast<Custom*>(ptr);
    switch (c->ctor) {
        case ENC_BOOL:
        case CTOR_JSON_BOOL: {
            HPointer b = c->values[0].p;
            v.kind = Kind::Bool;
            v.boolean = alloc::isBoolConst(b) && alloc::boolValue(b);
            return v;
        }
        case ENC_INT:
        case CTOR_JSON_INT:
            v.kind = Kind::Number;
            v.number = static_cast<double>(c->values[0].i);
            return v;
        case ENC_FLOAT:
        case CTOR_JSON_FLOAT:
            v.kind = Kind::Number;
            v.number = c->values[0].f;
            return v;
        case ENC_STRING:
        case CTOR_JSON_STRING:
            v.kind = Kind::String;
            v.string = Export::toPtr(Export::encode(c->values[0].p));
            return v;
        case ENC_ARRAY:
        case CTOR_JSON_ARRAY:
        case CTOR_JSON_ARRAY_CHUNKED:
            v.kind = Kind::Array;
            return v;
        case ENC_OBJECT:
        case CTOR_JSON_OBJECT:
            v.kind = Kind::Object;
            return v;
        default:
            return v;
    }
}

void arrayElements(const View& array, std::vector<uint64_t>& out) {
    if (array.kind != Kind::Array) return;
    void* ptr = Export::toPtr(array.bits);
    if (!ptr || static_cast<Header*>(ptr)->tag != Tag_Custom) return;
    Custom* c = static_cast<Custom*>(ptr);
    if (c->ctor == ENC_ARRAY) {
        // `addEntry` prepends, so the list holds the elements in reverse of the order they were added.
        size_t start = out.size();
        for (alloc::ListCursor l(c->values[0].p); !l.done(); l.next())
            out.push_back(Export::encode(l.current().p));
        std::reverse(out.begin() + static_cast<std::ptrdiff_t>(start), out.end());
        return;
    }
    const u32 n = jsonArrayLength(c);
    out.reserve(out.size() + n);
    for (u32 i = 0; i < n; ++i) out.push_back(jsonArrayAt(c, i));
}

bool jsToString(uint64_t valueBits, std::u16string& out) {
    View v = view(valueBits);
    if (v.kind == Kind::String) {
        out = StringOps::toStdU16String(v.string);
        return true;
    }
    if (v.kind == Kind::Array) {
        out.clear();
        appendArray(v, out, 1);
        return true;
    }
    return false;
}

} // namespace Elm::Kernel::JsonRead
