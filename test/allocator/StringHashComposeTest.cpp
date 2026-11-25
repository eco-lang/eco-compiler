/**
 * Tests for value-hash definition v4 and the hashes Strings are given at build
 * (plans/hash-reuse-explicit-vs-cached.md B5a-B5c; HEAP_088).
 *
 * B5a: Crc32c.cpp (hardware and portable paths) against a bit-by-bit CRC32C, for UTF-16 and UTF-8 runs,
 * continued states and joins of many pieces; every String form's raw state and hash against the
 * definition. B5b: a new form of a String keeps its slot. B5c: a rope hashed on demand fills its
 * children's slots, and every build site gives its result the raw state of its units, or leaves the slot
 * 0, as the configuration says. Every slot is also checked with `checkStringHashSlot`, the validate
 * builds' check.
 */

#include "StringHashComposeTest.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "../../runtime/src/allocator/Crc32c.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/RootSet.hpp"
#include "../../runtime/src/allocator/RuntimeExports.h"
#include "../../runtime/src/allocator/StringOps.hpp"
#include "../../runtime/src/allocator/ValueHash.hpp"
#include "TestHelpers.hpp"
#include <algorithm>
#include <cstring>
#include <random>
#include <string>
#include <vector>

using namespace Elm;
using namespace Elm::TestHelpers;

namespace {

constexpr u32 T = kStringHashSlotMinUnits;

// A fixed block of HPointer slots rooted as one range record.
struct Pool {
    static constexpr unsigned kMax = 64;
    HPointer slot[kMax];
    unsigned used = 0;
    EcoRootMark mark;
    Pool() {
        for (auto& s : slot) s = alloc::emptyString();
        mark = ecoRootMark();
        ecoRootRangePush(slot, kMax, ~0ULL);
    }
    ~Pool() { ecoRootRelease(mark); }
    Pool(const Pool&) = delete;
    Pool& operator=(const Pool&) = delete;
    unsigned put(HPointer h) {
        if (used >= kMax) TEST_FAIL("Pool full");
        slot[used] = h;
        return used++;
    }
    void* obj(unsigned i) { return Allocator::instance().resolve(slot[i]); }
};

// Restores the build-hash configuration when it goes out of scope.
struct ConfigGuard {
    StringOps::BuildHashConfig saved = StringOps::buildHashConfig();
    ~ConfigGuard() { StringOps::buildHashConfig() = saved; }
};

// CRC32C bit by bit over the little-endian bytes of `units`, from register `c`, no final inversion.
u32 refCrc(u32 c, const u16* units, size_t n) {
    for (size_t i = 0; i < n; ++i) {
        for (u32 byte : {static_cast<u32>(units[i] & 0xFF), static_cast<u32>(units[i] >> 8)}) {
            c ^= byte;
            for (int k = 0; k < 8; ++k) c = (c >> 1) ^ (0x82F63B78u & (0u - (c & 1)));
        }
    }
    return c;
}
u32 refRaw(void* s) {
    std::u16string u = StringOps::toStdU16String(s);
    return refCrc(crc32c::kEmpty, reinterpret_cast<const u16*>(u.data()), u.size());
}

std::string text(size_t n, char seed) {
    std::string s(n, 'a');
    for (size_t i = 0; i < n; ++i) s[i] = static_cast<char>('a' + (i * 7 + seed) % 26);
    return s;
}
std::u16string wide(const std::string& s) { return std::u16string(s.begin(), s.end()); }
std::u16string nonAscii(size_t n, int seed) {
    std::u16string w(n, u'a');
    for (size_t i = 0; i < n; ++i) w[i] = static_cast<char16_t>(0x4E00 + (i * 13 + seed) % 3000);
    return w;
}
HPointer utf8(const std::string& s) {
    return StringOps::makeUtf8LeafFromBytes(reinterpret_cast<const u8*>(s.data()), static_cast<u32>(s.size()));
}
HPointer utf16(const std::u16string& w) { return alloc::allocString(reinterpret_cast<const u16*>(w.data()), w.size()); }
void* res(HPointer h) { return Allocator::instance().resolve(h); }

// The slot of `o` must hold its raw state (`filled`) or 0, and pass the validate check.
void expectSlot(void* o, bool filled, const std::string& what) {
    u32* slot = stringHashSlot(o);
    if (!slot) TEST_FAIL(what + ": no slot");
    const u32 v = loadStringHashSlot(o);
    if (filled && v != refRaw(o)) TEST_FAIL(what + ": slot is not the raw CRC32C of its units");
    if (!filled && v != 0) TEST_FAIL(what + ": slot filled, expected 0");
    if (const char* bad = checkStringHashSlot(o)) TEST_FAIL(what + ": " + bad);
}

// ---- B5a: the CRC module

void test_crc_module_matches_reference() {
    std::mt19937_64 rng(7);
    std::vector<u16> u16s(70000 + 16);
    for (auto& u : u16s) u = static_cast<u16>(rng());
    std::vector<u8> u8s(70000 + 16);
    for (auto& b : u8s) b = static_cast<u8>(rng() & 0x7F);
    std::vector<size_t> lens;
    for (size_t n = 0; n <= 700; ++n) lens.push_back(n);
    for (size_t n : {1023, 1024, 1025, 4099, 65536, 65539}) lens.push_back(n);
    for (size_t n : lens) {
        for (size_t off = 0; off < 8; ++off) {
            const u32 st = (off & 1) ? crc32c::kEmpty : static_cast<u32>(rng());
            const u16* p = u16s.data() + off;
            const u32 want = refCrc(st, p, n);
            if (crc32c::update16(st, p, n) != want || crc32c::update16Portable(st, p, n) != want)
                TEST_FAIL("update16 n=" + std::to_string(n) + " off=" + std::to_string(off));
            const u8* q = u8s.data() + off;
            std::vector<u16> w(q, q + n);
            const u32 want8 = refCrc(st, w.data(), n);
            if (crc32c::update8(st, q, n) != want8 || crc32c::update8Portable(st, q, n) != want8)
                TEST_FAIL("update8 n=" + std::to_string(n) + " off=" + std::to_string(off));
        }
    }
    // Joins: every split of a String, and many pieces joined left to right, right to left and as a tree.
    const u16* p = u16s.data();
    for (size_t na = 0; na < 300; na += 7) {
        for (size_t nb = 0; nb < 1500; nb += 13) {
            const u32 ra = crc32c::update16(crc32c::kEmpty, p, na), rb = crc32c::update16(crc32c::kEmpty, p + na, nb);
            const u32 rab = crc32c::update16(crc32c::kEmpty, p, na + nb);
            if (crc32c::combine(ra, rb, nb) != rab || crc32c::combinePortable(ra, rb, nb) != rab)
                TEST_FAIL("combine na=" + std::to_string(na) + " nb=" + std::to_string(nb));
        }
    }
    const size_t total = 20000;
    const u32 whole = crc32c::update16(crc32c::kEmpty, p, total);
    for (int trial = 0; trial < 20; ++trial) {
        std::vector<size_t> cuts = {0, total};
        const size_t k = 2 + rng() % 60;
        for (size_t i = 0; i + 1 < k; ++i) cuts.push_back(rng() % (total + 1));
        std::sort(cuts.begin(), cuts.end());
        std::vector<std::pair<u32, size_t>> pieces;
        for (size_t i = 0; i + 1 < cuts.size(); ++i)
            pieces.push_back({crc32c::update16(crc32c::kEmpty, p + cuts[i], cuts[i + 1] - cuts[i]), cuts[i + 1] - cuts[i]});
        u32 left = crc32c::kEmpty;
        for (auto& pc : pieces) left = crc32c::combine(left, pc.first, pc.second);
        u32 right = crc32c::kEmpty;
        size_t rlen = 0;
        for (size_t i = pieces.size(); i-- > 0;) {
            right = crc32c::combine(pieces[i].first, right, rlen);
            rlen += pieces[i].second;
        }
        std::vector<std::pair<u32, size_t>> lvl = pieces;
        while (lvl.size() > 1) {
            std::vector<std::pair<u32, size_t>> nx;
            for (size_t i = 0; i + 1 < lvl.size(); i += 2)
                nx.push_back({crc32c::combine(lvl[i].first, lvl[i + 1].first, lvl[i + 1].second),
                              lvl[i].second + lvl[i + 1].second});
            if (lvl.size() % 2) nx.push_back(lvl.back());
            lvl = nx;
        }
        if (left != whole || right != whole || lvl[0].first != whole)
            TEST_FAIL("many-piece join, trial " + std::to_string(trial));
    }
}

// Every String form's raw state is the CRC32C of its units, and its hash is the definition's.
void test_forms_follow_definition_v4() {
    initAllocator();
    Pool p;
    const std::string s = text(300, 1);
    std::vector<unsigned> ids;
    ids.push_back(p.put(utf16(wide(s))));
    ids.push_back(p.put(utf8(s)));
    ids.push_back(p.put(utf16(nonAscii(300, 2))));
    ids.push_back(p.put(StringOps::slice(p.obj(ids[0]), 3, 250)));
    ids.push_back(p.put(StringOps::slice(p.obj(ids[1]), 3, 250)));
    ids.push_back(p.put(StringOps::makeRope(p.slot[ids[0]], p.slot[ids[2]])));
    ids.push_back(p.put(utf16(wide(text(Allocator::instance().getLargeObjectThreshold(), 3)))));
    ids.push_back(p.put(utf8(text(10, 4))));
    for (unsigned i : ids) {
        void* o = p.obj(i);
        const u32 raw = refRaw(o);
        if (stringRawUncached(o) != raw) TEST_FAIL("stringRawUncached differs from CRC32C, form " + std::to_string(i));
        const u32 n = static_cast<Header*>(o)->size;
        u32 sh = (raw ^ n);
        sh ^= sh >> 16; sh *= 0x85ebca6bu; sh ^= sh >> 13; sh *= 0xc2b2ae35u; sh ^= sh >> 16;
        if (sh == 0) sh = 1;
        u32 h = 2166136261u;
        h = (h ^ 4u) * 16777619u;  // kString
        h = (h ^ sh) * 16777619u;
        h ^= h >> 16; h *= 0x85ebca6bu; h ^= h >> 13; h *= 0xc2b2ae35u; h ^= h >> 16;
        if (h == 0) h = 1;
        if (static_cast<u32>(eco_hash_string(HPtr::fromHPointer(p.slot[i]))) != h)
            TEST_FAIL("eco_hash_string is not definition v4, form " + std::to_string(i));
        if (stringHashSlot(o)) expectSlot(o, true, "after hashing, form " + std::to_string(i));
    }
}

// ---- B5c: ropes composed on demand

void test_rope_hash_fills_children() {
    initAllocator();
    Pool p;
    unsigned a = p.put(utf16(nonAscii(300, 5)));
    unsigned b = p.put(utf8(text(400, 6)));
    unsigned r = p.put(StringOps::makeRope(p.slot[a], p.slot[b]));
    expectSlot(p.obj(r), false, "a rope of two unhashed long children");
    eco_hash_string(HPtr::fromHPointer(p.slot[r]));
    expectSlot(p.obj(r), true, "the rope after hashing");
    expectSlot(p.obj(a), true, "the rope's left child after hashing the rope");
    expectSlot(p.obj(b), true, "the rope's right child after hashing the rope");
    // A new rope from a hashed child and a hashed String is given its raw state at build.
    unsigned c = p.put(utf8(text(500, 7)));
    eco_hash_string(HPtr::fromHPointer(p.slot[c]));
    unsigned r2 = p.put(StringOps::makeRope(p.slot[a], p.slot[c]));
    expectSlot(p.obj(r2), true, "a rope of two hashed children");
    unsigned r3 = p.put(StringOps::makeRope(p.slot[r], p.slot[c]));
    expectSlot(p.obj(r3), true, "a rope of a hashed rope and a hashed String");
    // A short child (no slot) is hashed at build.
    unsigned sh = p.put(utf8(text(5, 8)));
    unsigned r4 = p.put(StringOps::makeRope(p.slot[c], p.slot[sh]));
    expectSlot(p.obj(r4), true, "a rope of a hashed String and a short one");
}

// ---- B5c: composition at the build sites

void test_compose_at_build_sites() {
    initAllocator();
    ConfigGuard guard;
    auto& hc = StringOps::buildHashConfig();
    hc = StringOps::BuildHashConfig{};  // compose, hash unknown parts, budget T
    Pool p;

    // append, both UTF-8: an unhashed long part is hashed (its slot filled) and the result composed.
    unsigned a8 = p.put(utf8(text(300, 1)));
    unsigned s8 = p.put(utf8(text(10, 2)));
    unsigned r = p.put(StringOps::append(p.obj(a8), p.obj(s8)));
    expectSlot(p.obj(r), true, "append UTF-8 ++ UTF-8");
    expectSlot(p.obj(a8), true, "append's long part after the build");
    // append, UTF-16 non-ASCII ++ UTF-8: a UTF-16 result.
    unsigned a16 = p.put(utf16(nonAscii(200, 3)));
    r = p.put(StringOps::append(p.obj(a16), p.obj(s8)));
    if (static_cast<Header*>(p.obj(r))->tag != Tag_String) TEST_FAIL("precondition: UTF-16 result");
    expectSlot(p.obj(r), true, "append UTF-16 ++ UTF-8");
    // append, UTF-16 ASCII ++ UTF-8: re-encoded as UTF-8.
    unsigned w16 = p.put(utf16(wide(text(100, 4))));
    r = p.put(StringOps::append(p.obj(w16), p.obj(s8)));
    if (!StringOps::isUtf8(p.obj(r))) TEST_FAIL("precondition: re-encoded UTF-8 result");
    expectSlot(p.obj(r), true, "append UTF-16 ASCII ++ UTF-8");
    // A short result (no slot) is left alone.
    r = p.put(StringOps::append(p.obj(s8), p.obj(s8)));
    if (stringHashSlot(p.obj(r))) TEST_FAIL("a 20-unit result has a slot");

    // Known parts only: an unhashed long part leaves the result's slot 0, a hashed one composes.
    hc.hashUnknown = false;
    unsigned b8 = p.put(utf8(text(300, 5)));
    r = p.put(StringOps::append(p.obj(b8), p.obj(s8)));
    expectSlot(p.obj(r), false, "append of an unhashed part, known parts only");
    expectSlot(p.obj(b8), false, "the unhashed part, known parts only");
    eco_hash_string(HPtr::fromHPointer(p.slot[b8]));
    r = p.put(StringOps::append(p.obj(b8), p.obj(s8)));
    expectSlot(p.obj(r), true, "append of a hashed part, known parts only");
    // Budget 0: a short part may not be hashed, so nothing composes.
    hc.shortBudget = 0;
    r = p.put(StringOps::append(p.obj(b8), p.obj(s8)));
    expectSlot(p.obj(r), false, "append with a short part and budget 0");
    hc = StringOps::BuildHashConfig{};
    // Composition off.
    hc.compose = false;
    r = p.put(StringOps::append(p.obj(b8), p.obj(s8)));
    expectSlot(p.obj(r), false, "append with composition off");
    hc = StringOps::BuildHashConfig{};

    // concat and join, UTF-8 and UTF-16 paths, with long, short and empty parts.
    unsigned c8 = p.put(utf8(text(250, 9)));
    unsigned e = p.put(alloc::emptyString());
    for (bool nonAsciiPart : {false, true}) {
        unsigned x = nonAsciiPart ? a16 : w16;
        HPointer list = alloc::listFromPointers(std::vector<HPointer>{p.slot[c8], p.slot[s8], p.slot[e], p.slot[x], p.slot[s8]});
        r = p.put(StringOps::concat(list));
        expectSlot(p.obj(r), true, std::string("concat") + (nonAsciiPart ? " (UTF-16)" : " (re-encoded)"));
        unsigned sep = p.put(utf8(", "));
        list = alloc::listFromPointers(std::vector<HPointer>{p.slot[c8], p.slot[s8], p.slot[e], p.slot[x]});
        r = p.put(StringOps::join(p.obj(sep), list));
        expectSlot(p.obj(r), true, std::string("join") + (nonAsciiPart ? " (UTF-16)" : " (re-encoded)"));
        unsigned longSep = p.put(utf8(text(40, 11)));
        list = alloc::listFromPointers(std::vector<HPointer>{p.slot[s8], p.slot[e], p.slot[s8]});
        r = p.put(StringOps::join(p.obj(longSep), list));
        expectSlot(p.obj(r), true, "join with a long separator");
    }
    HPointer allUtf8 = alloc::listFromPointers(std::vector<HPointer>{p.slot[c8], p.slot[s8], p.slot[c8]});
    r = p.put(StringOps::concat(allUtf8));
    expectSlot(p.obj(r), true, "concat of UTF-8 parts");

    // cons, ASCII and non-ASCII Char.
    r = p.put(StringOps::cons('x', p.obj(c8)));
    expectSlot(p.obj(r), true, "cons ASCII");
    r = p.put(StringOps::cons(0x1F600, p.obj(c8)));
    expectSlot(p.obj(r), true, "cons non-ASCII");

    // The rope path of append (over string_flatten_limit): composed only when both sides are known.
    const size_t half = Allocator::instance().getConfig().string_flatten_limit / 2 + 10;
    unsigned big1 = p.put(utf8(text(half, 12)));
    unsigned big2 = p.put(utf16(nonAscii(half, 13)));
    r = p.put(StringOps::append(p.obj(big1), p.obj(big2)));
    if (static_cast<Header*>(p.obj(r))->tag != Tag_StringRope) TEST_FAIL("precondition: a rope");
    expectSlot(p.obj(r), false, "append rope of unhashed sides");
    eco_hash_string(HPtr::fromHPointer(p.slot[big1]));
    eco_hash_string(HPtr::fromHPointer(p.slot[big2]));
    r = p.put(StringOps::append(p.obj(big1), p.obj(big2)));
    expectSlot(p.obj(r), true, "append rope of hashed sides");
}

// ---- B5b: propagation

void test_propagation() {
    initAllocator();
    ConfigGuard guard;
    auto& hc = StringOps::buildHashConfig();
    hc = StringOps::BuildHashConfig{};
    Pool p;
    unsigned base = p.put(utf16(nonAscii(400, 1)));
    unsigned sl = p.put(StringOps::slice(p.obj(base), 10, 300));
    eco_hash_string(HPtr::fromHPointer(p.slot[sl]));
    unsigned flat = p.put(StringOps::flattenToLeaf(p.slot[sl]));
    if (static_cast<Header*>(p.obj(flat))->tag != Tag_String) TEST_FAIL("precondition: flattened leaf");
    expectSlot(p.obj(flat), true, "flattenToLeaf of a hashed slice");
    hc.propagate = false;
    flat = p.put(StringOps::flattenToLeaf(p.slot[sl]));
    expectSlot(p.obj(flat), false, "flattenToLeaf with propagation off");
}

} // namespace

void registerStringHashComposeTests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase("HEAP_088 B5a Crc32c matches a bit-by-bit CRC32C, and joins compose",
                                test_crc_module_matches_reference));
    suite.add(Testing::TestCase("HEAP_088 B5a every String form follows definition v4", test_forms_follow_definition_v4));
    suite.add(Testing::TestCase("HEAP_088 B5c a rope hashed on demand fills its children's slots",
                                test_rope_hash_fills_children));
    suite.add(Testing::TestCase("HEAP_088 B5c every build site composes its result's raw state",
                                test_compose_at_build_sites));
    suite.add(Testing::TestCase("HEAP_088 B5b a new form of a hashed String keeps its slot", test_propagation));
}
