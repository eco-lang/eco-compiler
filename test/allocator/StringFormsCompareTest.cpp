/**
 * HEAP_025: equality and ordering across all six String heap forms.
 *
 * The six forms (runtime/src/allocator/Heap.hpp):
 *   Tag_String            flat UTF-16 leaf
 *   Tag_StringRope        concat node (children may mix UTF-8 and UTF-16)
 *   Tag_StringSlice       view over a Tag_String or Tag_LargeStringHeader
 *   Tag_LargeStringHeader split header, body = pinned Tag_String
 *   Tag_StringUtf8View    zero-copy ASCII view over a ByteBuffer /
 *                         LargeByteHeader / UTF-8 leaf
 *   Tag_StringUtf8Leaf    inline ASCII bytes
 *
 * The rule under test:
 *   - equal(a, b) is true and compare(a, b) == 0 for every pair of forms
 *     holding the same content;
 *   - for differing content, equal is false and the sign of compare is the
 *     lexicographic UTF-16 code-unit order (the oracle is std::u16string
 *     comparison), hence consistent across forms and antisymmetric;
 *   - equal and compare never flatten and never allocate: after the whole
 *     matrix every object still resolves to the same address with the same
 *     tag and size, rope children are the same words, and the allocator's
 *     object counter has not moved.
 *
 * A Tag_String leaf and a Tag_LargeStringHeader can never hold the same
 * content under one heap config (alloc::allocString picks the form from the
 * size against large_object_threshold), so the content set has a SMALL text
 * (300 units; five forms) and a LARGE text (5000 units, >= the 8 KiB
 * threshold as UTF-16, below it as UTF-8; the large header plus the other
 * five forms built at that size). SMALL is a prefix of LARGE, so the two
 * sets also meet in the differing-content matrix.
 *
 * The matrix runs twice: once as built, once after a forced minor + major GC
 * (the pool is rooted), so moved forms are compared as well.
 */

#include "StringFormsCompareTest.hpp"
#include "../../runtime/src/allocator/StringOps.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/RootSet.hpp"
#include "TestHelpers.hpp"
#include <string>
#include <vector>
#include <cstring>
#include <iostream>

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

// A fixed block of HPointer slots rooted as ONE range record, so builders
// can keep intermediates across allocations.
struct RootedPool {
    static constexpr unsigned kMax = 64;
    HPointer slot[kMax];
    unsigned used = 0;
    EcoRootMark mark;
    RootedPool() {
        for (auto& s : slot) s = alloc::emptyString();
        mark = ecoRootMark();
        ecoRootRangePush(slot, kMax, ~0ULL);
    }
    ~RootedPool() { ecoRootRelease(mark); }
    RootedPool(const RootedPool&) = delete;
    RootedPool& operator=(const RootedPool&) = delete;
    unsigned put(HPointer h) {
        if (used >= kMax) TEST_FAIL("RootedPool full");
        slot[used] = h;
        return used++;
    }
    void reset() {
        for (unsigned i = 0; i < used; ++i) slot[i] = alloc::emptyString();
        used = 0;
    }
};

void* rz(HPointer hp) {
    if (alloc::isConstant(hp)) return nullptr;
    return Allocator::instance().resolve(hp);
}

std::string ascii(const std::u16string& s) {
    std::string r;
    r.reserve(s.size());
    for (char16_t c : s) {
        if (c >= 0x80) TEST_FAIL("ascii(): non-ASCII content given to a UTF-8 builder");
        r.push_back(static_cast<char>(c));
    }
    return r;
}

const char* tagName(u32 t) {
    switch (t) {
        case Tag_String: return "Tag_String";
        case Tag_StringRope: return "Tag_StringRope";
        case Tag_StringSlice: return "Tag_StringSlice";
        case Tag_LargeStringHeader: return "Tag_LargeStringHeader";
        case Tag_StringUtf8View: return "Tag_StringUtf8View";
        case Tag_StringUtf8Leaf: return "Tag_StringUtf8Leaf";
        case Tag_ByteBuffer: return "Tag_ByteBuffer";
        case Tag_LargeByteHeader: return "Tag_LargeByteHeader";
        default: return "other";
    }
}

int sgn(int v) { return (v > 0) - (v < 0); }

int oracleCompare(const std::u16string& a, const std::u16string& b) {
    return sgn(a.compare(b));
}

struct Entry {
    unsigned slot;          // index into the entries pool
    std::u16string content; // expected logical content
    std::string name;
};

// ---------------------------------------------------------------------------
// Form builders. Each puts its result into `entries` and checks the tag, so
// a changed construction rule shows up as a precondition failure, not as a
// silently weaker test.
// ---------------------------------------------------------------------------

struct Builder {
    RootedPool& entries;
    RootedPool& scratch;
    std::vector<Entry>& out;

    void expectTag(HPointer h, u32 tag, const std::string& name) {
        void* o = rz(h);
        if (!o) TEST_FAIL("precondition: " + name + " built the empty constant");
        u32 got = alloc::getTag(o);
        if (got != tag)
            TEST_FAIL("precondition: " + name + " built " + tagName(got) + ", expected " +
                      tagName(tag));
    }

    void add(HPointer h, const std::u16string& c, u32 tag, const std::string& name) {
        expectTag(h, tag, name);
        out.push_back(Entry{entries.put(h), c, name});
    }

    // Tag_String for small content, Tag_LargeStringHeader at/above the LOT.
    void u16(const std::u16string& c, u32 tag, const std::string& name) {
        add(alloc::allocString(c), c, tag, name);
    }

    void utf8Leaf(const std::u16string& c, const std::string& name) {
        std::string b = ascii(c);
        add(StringOps::makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(b.data()),
                                             static_cast<u32>(b.size())),
            c, Tag_StringUtf8Leaf, name);
    }

    // UTF-8 view at byte offset `pad` into a buffer of pad + c + tail bytes.
    // With a total >= LOT the buffer is a Tag_LargeByteHeader.
    void utf8View(const std::u16string& c, size_t pad, size_t tail, u32 bufTag,
                  const std::string& name) {
        std::string b = std::string(pad, '#') + ascii(c) + std::string(tail, '~');
        HPointer bb = alloc::allocByteBuffer(reinterpret_cast<const u8*>(b.data()), b.size());
        expectTag(bb, bufTag, name + " (backing buffer)");
        unsigned s = scratch.put(bb);
        add(StringOps::makeUtf8View(scratch.slot[s], static_cast<u32>(pad),
                                    static_cast<u32>(c.size())),
            c, Tag_StringUtf8View, name);
    }

    // Slice at `pad` into a UTF-16 base of pad + c + tail units (the base is
    // a Tag_String or a Tag_LargeStringHeader by size).
    void slice(const std::u16string& c, size_t pad, size_t tail, u32 baseTag,
               const std::string& name) {
        std::u16string b = std::u16string(pad, u'#') + c + std::u16string(tail, u'~');
        HPointer base = alloc::allocString(b);
        expectTag(base, baseTag, name + " (base)");
        unsigned s = scratch.put(base);
        add(StringOps::makeSlice(scratch.slot[s], static_cast<u32>(pad),
                                 static_cast<u32>(c.size())),
            c, Tag_StringSlice, name);
    }

    // Piece kinds for ropes.
    enum Piece { P_U16, P_UTF8LEAF, P_UTF8VIEW, P_SLICE };

    unsigned piece(const std::u16string& c, Piece k) {
        HPointer h{};
        switch (k) {
            case P_U16: h = alloc::allocString(c); break;
            case P_UTF8LEAF: {
                std::string b = ascii(c);
                h = StringOps::makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(b.data()),
                                                     static_cast<u32>(b.size()));
                break;
            }
            case P_UTF8VIEW: {
                std::string b = "##" + ascii(c);
                unsigned s = scratch.put(
                    alloc::allocByteBuffer(reinterpret_cast<const u8*>(b.data()), b.size()));
                h = StringOps::makeUtf8View(scratch.slot[s], 2, static_cast<u32>(c.size()));
                break;
            }
            case P_SLICE: {
                std::u16string b = u"##" + c + u"~";
                unsigned s = scratch.put(alloc::allocString(b));
                h = StringOps::makeSlice(scratch.slot[s], 2, static_cast<u32>(c.size()));
                break;
            }
        }
        return scratch.put(h);
    }

    // Rope over the pieces of `c` cut at `cuts` (ascending), piece i of kind
    // kinds[i]. `rightLeaning` folds as p0 + (p1 + (p2 ...)), else left-leaning.
    void rope(const std::u16string& c, const std::vector<size_t>& cuts,
              const std::vector<Piece>& kinds, bool rightLeaning, const std::string& name) {
        std::vector<size_t> b = {0};
        b.insert(b.end(), cuts.begin(), cuts.end());
        b.push_back(c.size());
        if (kinds.size() + 1 != b.size()) TEST_FAIL("rope(): kinds/cuts mismatch");
        std::vector<unsigned> ps;
        for (size_t i = 0; i + 1 < b.size(); ++i)
            ps.push_back(piece(c.substr(b[i], b[i + 1] - b[i]), kinds[i]));
        unsigned acc;
        if (rightLeaning) {
            acc = ps.back();
            for (size_t i = ps.size() - 1; i-- > 0;)
                acc = scratch.put(StringOps::makeRope(scratch.slot[ps[i]], scratch.slot[acc]));
        } else {
            acc = ps.front();
            for (size_t i = 1; i < ps.size(); ++i)
                acc = scratch.put(StringOps::makeRope(scratch.slot[acc], scratch.slot[ps[i]]));
        }
        add(scratch.slot[acc], c, Tag_StringRope, name);
    }
};

// Deterministic ASCII text: letters, digits and punctuation, no runs.
std::u16string makeText(size_t n) {
    static const char kAlpha[] =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,;:!?-_()[]";
    const size_t m = sizeof(kAlpha) - 1;
    std::u16string s;
    s.reserve(n);
    for (size_t i = 0; i < n; ++i) s.push_back(static_cast<char16_t>(kAlpha[(i * 7 + i / 13) % m]));
    return s;
}

std::u16string withUnit(std::u16string s, size_t at, char16_t u) {
    s[at] = u;
    return s;
}

struct Snapshot {
    void* addr;
    u32 tag;
    u32 size;
    uint64_t left, right;  // rope children words, else 0
};

Snapshot snap(HPointer h) {
    Snapshot s{};
    s.addr = rz(h);
    if (!s.addr) return s;
    s.tag = alloc::getTag(s.addr);
    s.size = static_cast<Header*>(s.addr)->size;
    if (s.tag == Tag_StringRope) {
        auto* r = static_cast<ElmStringRope*>(s.addr);
        std::memcpy(&s.left, &r->left, sizeof(u64));
        std::memcpy(&s.right, &r->right, sizeof(u64));
    }
    return s;
}

// Runs the full pair matrix; returns the number of pairs checked.
size_t runMatrix(RootedPool& entries, const std::vector<Entry>& es, const char* phase) {
    std::vector<Snapshot> before;
    for (const auto& e : es) before.push_back(snap(entries.slot[e.slot]));

    const uint64_t allocs0 = Allocator::instance().getCombinedStats().objects_allocated;
    size_t pairs = 0;
    std::string failures;
    unsigned nfail = 0;
    auto fail = [&](const std::string& m) {
        if (nfail++ < 20) failures += "    " + m + "\n";
    };

    for (size_t i = 0; i < es.size(); ++i) {
        for (size_t j = 0; j < es.size(); ++j) {
            void* a = rz(entries.slot[es[i].slot]);
            void* b = rz(entries.slot[es[j].slot]);
            const bool same = es[i].content == es[j].content;
            const int want = oracleCompare(es[i].content, es[j].content);
            const bool eq = StringOps::equal(a, b);
            const int c = sgn(StringOps::compare(a, b));
            const int cr = sgn(StringOps::compare(b, a));
            const std::string pair = es[i].name + " vs " + es[j].name;
            if (eq != same)
                fail(pair + ": equal = " + (eq ? "true" : "false") + ", content " +
                     (same ? "equal" : "differs"));
            if (c != want)
                fail(pair + ": compare sign " + std::to_string(c) + ", oracle " +
                     std::to_string(want));
            if (c != -cr)
                fail(pair + ": not antisymmetric (" + std::to_string(c) + " vs reverse " +
                     std::to_string(cr) + ")");
            if (eq != (c == 0))
                fail(pair + ": equal and compare disagree");
            ++pairs;
        }
    }

    const uint64_t allocs1 = Allocator::instance().getCombinedStats().objects_allocated;
    if (allocs1 != allocs0)
        fail("equal/compare allocated " + std::to_string(allocs1 - allocs0) +
             " objects (they must never flatten or allocate)");
    for (size_t i = 0; i < es.size(); ++i) {
        Snapshot now = snap(entries.slot[es[i].slot]);
        const Snapshot& was = before[i];
        if (now.addr != was.addr || now.tag != was.tag || now.size != was.size ||
            now.left != was.left || now.right != was.right)
            fail(es[i].name + ": object changed across equal/compare (was " + tagName(was.tag) +
                 ", now " + tagName(now.tag) + ")");
    }

    if (nfail) {
        TEST_FAIL(std::string("HEAP_025 matrix (") + phase + "): " + std::to_string(nfail) +
                  " failure(s), first ones:\n" + failures);
    }
    return pairs;
}

void test_six_forms_equal_and_compare() {
    initAllocator();
    if (!Allocator::instance().getConfig().utf8_strings_enabled)
        TEST_FAIL("precondition: utf8_strings_enabled is off, the UTF-8 forms cannot be built");

    RootedPool entries;
    RootedPool scratch;
    std::vector<Entry> es;
    Builder B{entries, scratch, es};

    const std::u16string L = makeText(5000);
    const std::u16string S = L.substr(0, 300);
    // Check the size assumptions against the live threshold.
    const size_t lot = Allocator::instance().getLargeObjectThreshold();
    if (!(sizeof(ElmString) + 2 * L.size() >= lot && sizeof(ElmStringUtf8Leaf) + L.size() + 8 < lot))
        TEST_FAIL("precondition: large_object_threshold " + std::to_string(lot) +
                  " does not split the 5000-unit text between UTF-16 (large) and UTF-8 (small)");

    // ---- SMALL text S, five forms (a large header cannot be this small) ----
    B.u16(S, Tag_String, "S:u16leaf");
    B.utf8Leaf(S, "S:utf8leaf");
    B.utf8View(S, 3, 5, Tag_ByteBuffer, "S:utf8view");
    B.slice(S, 4, 9, Tag_String, "S:slice");
    B.rope(S, {150}, {Builder::P_U16, Builder::P_U16}, false, "S:rope(u16+u16)");
    B.rope(S, {7, 150, 151, 299},
           {Builder::P_UTF8LEAF, Builder::P_SLICE, Builder::P_U16, Builder::P_UTF8VIEW,
            Builder::P_U16},
           true, "S:rope(mixed,5 pieces)");
    B.rope(S, {100, 200},
           {Builder::P_UTF8VIEW, Builder::P_UTF8LEAF, Builder::P_SLICE}, false,
           "S:rope(utf8view+utf8leaf+slice)");

    // ---- LARGE text L: the large header plus the other five forms ----
    B.u16(L, Tag_LargeStringHeader, "L:largeheader");
    B.utf8Leaf(L, "L:utf8leaf");
    B.utf8View(L, 10, 20, Tag_ByteBuffer, "L:utf8view(bytebuffer)");
    B.utf8View(L, 100, 4000, Tag_LargeByteHeader, "L:utf8view(largebytes)");
    B.slice(L, 50, 60, Tag_LargeStringHeader, "L:slice(of largeheader)");
    B.rope(L, {2500}, {Builder::P_U16, Builder::P_U16}, false, "L:rope(u16+u16)");
    B.rope(L, {1, 2500, 4999},
           {Builder::P_U16, Builder::P_UTF8LEAF, Builder::P_SLICE, Builder::P_UTF8VIEW}, true,
           "L:rope(mixed,4 pieces)");
    scratch.reset();

    // ---- differing content (each in several forms) ----
    const std::u16string sLast = withUnit(S, 299, u'~');            // > S at the end
    const std::u16string sFirst = withUnit(S, 0, u' ');             // < S at the start
    const std::u16string sShort = S.substr(0, 299);                 // proper prefix of S
    const std::u16string lMid = withUnit(L, 2500, u'`');            // differs ON the rope cut
    const std::u16string lLast = withUnit(L, 4999, u'~');
    const std::u16string sHigh = withUnit(S, 150, u'é');       // non-ASCII > ASCII
    const std::u16string sCjk = withUnit(S, 150, u'中');        // > é
    const std::u16string sLow = withUnit(S, 150, u'\u0001');        // non-letter < ASCII text

    B.u16(sLast, Tag_String, "sLast:u16leaf");
    B.utf8Leaf(sLast, "sLast:utf8leaf");
    B.rope(sLast, {298}, {Builder::P_UTF8VIEW, Builder::P_U16}, false, "sLast:rope");
    B.utf8View(sFirst, 1, 1, Tag_ByteBuffer, "sFirst:utf8view");
    B.slice(sFirst, 1, 1, Tag_String, "sFirst:slice");
    B.utf8Leaf(sShort, "sShort:utf8leaf");
    B.rope(sShort, {150}, {Builder::P_SLICE, Builder::P_UTF8LEAF}, true, "sShort:rope");
    B.u16(lMid, Tag_LargeStringHeader, "lMid:largeheader");
    B.rope(lMid, {2500}, {Builder::P_UTF8LEAF, Builder::P_U16}, false, "lMid:rope");
    B.utf8Leaf(lLast, "lLast:utf8leaf");
    B.slice(lLast, 7, 0, Tag_LargeStringHeader, "lLast:slice(of largeheader)");
    B.u16(sHigh, Tag_String, "sHigh:u16leaf");
    B.rope(sHigh, {150, 151}, {Builder::P_UTF8LEAF, Builder::P_U16, Builder::P_UTF8VIEW}, false,
           "sHigh:rope(utf8+u16+utf8)");
    B.slice(sCjk, 2, 2, Tag_String, "sCjk:slice");
    B.rope(sLow, {150}, {Builder::P_UTF8LEAF, Builder::P_U16}, true, "sLow:rope");
    scratch.reset();

    // Every one of the six tags is present.
    bool seen[6] = {};
    const u32 six[6] = {Tag_String, Tag_StringRope, Tag_StringSlice, Tag_LargeStringHeader,
                        Tag_StringUtf8View, Tag_StringUtf8Leaf};
    for (const auto& e : es) {
        u32 t = alloc::getTag(rz(entries.slot[e.slot]));
        for (int k = 0; k < 6; ++k) if (t == six[k]) seen[k] = true;
    }
    for (int k = 0; k < 6; ++k)
        if (!seen[k]) TEST_FAIL(std::string("precondition: no entry has ") + tagName(six[k]));

    size_t pairs = runMatrix(entries, es, "as built");

    // Move everything that can move, then compare again.
    Allocator::instance().minorGC();
    Allocator::instance().majorGC();
    pairs += runMatrix(entries, es, "after minor+major GC");
    std::cout << "    HEAP_025: " << es.size() << " strings, " << pairs << " ordered pairs\n";
}

} // namespace

void registerStringFormsCompareTests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase(
        "HEAP_025 equal/compare agree across all six string forms and never flatten",
        test_six_forms_equal_and_compare));
}
