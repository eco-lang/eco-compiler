/**
 * Differential tests for the UTF-8 (all-ASCII) String forms
 * (Tag_StringUtf8Leaf / Tag_StringUtf8View).
 *
 * The contract (design_docs/utf8-string-encoding-investigation.md, HEAP_032):
 * a UTF-8 form holds 1 ASCII byte per logical UTF-16 code unit, so every
 * StringOps operation must produce results bit-identical to the UTF-16 twin.
 * These tests build the same ASCII content in four representations —
 *   (a) UTF-16 leaf, (b) UTF-8 leaf, (c) UTF-8 view over a Tag_ByteBuffer,
 *   (d) UTF-8 view over a large (Tag_LargeByteHeader) buffer —
 * and assert each operation agrees with (a). Mixed-operand cases additionally
 * pair a UTF-8 form against a non-ASCII UTF-16 string (which the gate forbids
 * from ever becoming UTF-8) to exercise equal/compare across widths.
 */

#include "Utf8StringTest.hpp"
#include "../../runtime/src/allocator/StringOps.hpp"
#include "../../runtime/src/allocator/HeapHelpers.hpp"
#include "../../runtime/src/allocator/Allocator.hpp"
#include "TestHelpers.hpp"
#include <rapidcheck.h>
#include <string>
#include <algorithm>
#include <vector>

using namespace Elm;
using namespace Elm::TestHelpers;

// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

static void* rz(HPointer hp) {
    if (alloc::isConstant(hp)) return nullptr;  // empty-string constant, etc.
    return Allocator::instance().resolve(hp);
}

static std::string content(HPointer hp) { return StringOps::toStdString(rz(hp)); }

static HPointer makeU16(const std::string& s) {
    std::u16string u16(s.begin(), s.end());
    return alloc::allocString(u16);
}

static HPointer makeU8Leaf(const std::string& s) {
    return StringOps::makeUtf8LeafFromBytes(
        reinterpret_cast<const u8*>(s.data()), static_cast<u32>(s.size()));
}

// A UTF-8 view over a fresh Tag_ByteBuffer (or Tag_LargeByteHeader if large).
static HPointer makeU8View(const std::string& s) {
    if (s.empty()) return alloc::emptyString();
    HPointer bb = alloc::allocByteBuffer(
        reinterpret_cast<const u8*>(s.data()), s.size());
    // makeUtf8View roots `bb` across its own allocation.
    return StringOps::makeUtf8View(bb, 0, static_cast<u32>(s.size()));
}

// Non-ASCII UTF-16 string from a UTF-8-encoded byte string (built by decoding
// via allocStringFromUTF8, i.e. always a UTF-16 leaf — never a UTF-8 form).
static HPointer makeU16FromUtf8(const std::string& utf8) {
    return alloc::allocStringFromUTF8(utf8);
}

// ---------------------------------------------------------------------------
// Per-form single-operand checks against a reference ASCII string
// ---------------------------------------------------------------------------

static std::string asciiUpper(const std::string& s) {
    std::string r = s;
    for (char& c : r) if (c >= 'a' && c <= 'z') c -= 32;
    return r;
}
static std::string asciiLower(const std::string& s) {
    std::string r = s;
    for (char& c : r) if (c >= 'A' && c <= 'Z') c += 32;
    return r;
}

// Runs the single-operand op battery on a form holding `ref` (ASCII).
static void checkSingle(HPointer s, const std::string& ref) {
    void* o = rz(s);
    const i64 n = static_cast<i64>(ref.size());

    // length
    RC_ASSERT(StringOps::length(o) == n);
    // toStdString round-trip
    RC_ASSERT(content(s) == ref);
    // charAt at every index
    for (i64 i = 0; i < n; ++i) {
        RC_ASSERT(StringOps::charAt(o, i) == static_cast<u16>(
                      static_cast<unsigned char>(ref[static_cast<size_t>(i)])));
    }
    // toStdU16String widens exactly
    {
        auto u16 = StringOps::toStdU16String(o);
        RC_ASSERT(u16.size() == ref.size());
        for (size_t i = 0; i < ref.size(); ++i)
            RC_ASSERT(u16[i] == static_cast<char16_t>(
                          static_cast<unsigned char>(ref[i])));
    }
    // toUpper / toLower (ASCII)
    RC_ASSERT(content(StringOps::toUpper(o)) == asciiUpper(ref));
    RC_ASSERT(content(StringOps::toLower(o)) == asciiLower(ref));
    // reverse
    {
        std::string rev(ref.rbegin(), ref.rend());
        RC_ASSERT(content(StringOps::reverse(o)) == rev);
    }
    // slice family at a few index pairs
    auto sub = [&](i64 a, i64 b) {
        a = std::max<i64>(0, std::min<i64>(a, n));
        b = std::max<i64>(a, std::min<i64>(b, n));
        return ref.substr(static_cast<size_t>(a), static_cast<size_t>(b - a));
    };
    for (i64 a = 0; a <= n; a += (n / 3 + 1)) {
        for (i64 b = a; b <= n; b += (n / 3 + 1)) {
            RC_ASSERT(content(StringOps::slice(o, a, b)) == sub(a, b));
        }
    }
    if (n > 0) {
        RC_ASSERT(content(StringOps::left(o, n / 2)) == sub(0, n / 2));
        RC_ASSERT(content(StringOps::right(o, n / 2)) == sub(n - n / 2, n));
        RC_ASSERT(content(StringOps::dropLeft(o, n / 2)) == sub(n / 2, n));
        RC_ASSERT(content(StringOps::dropRight(o, n / 2)) == sub(0, n - n / 2));
    }
    // uncons: non-empty yields Just(...) (a heap tuple, not the Nothing
    // constant). Deep destructuring of the (char, rest) tuple is covered by
    // the E2E suite where Elm can pattern-match the Maybe.
    if (n > 0) {
        HPointer u = StringOps::uncons(o);
        RC_ASSERT(!alloc::isEmptyString(u));
    }
}

// ---------------------------------------------------------------------------
// Property: all four forms agree with the UTF-16 twin
// ---------------------------------------------------------------------------

static std::string genAscii() {
    // printable ASCII, mixed case + digits + spaces
    return *rc::gen::container<std::string>(rc::gen::inRange<char>(32, 127));
}

static void test_forms_agree_single() {
    rc::check("all UTF-8 forms agree with UTF-16 (single-operand ops)", []() {
        initAllocator();
        std::string s = genAscii();
        if (s.empty()) return;  // empty is the shared constant; trivial

        checkSingle(makeU16(s), s);
        checkSingle(makeU8Leaf(s), s);
        checkSingle(makeU8View(s), s);
    });
}

static void test_large_view_agrees() {
    rc::check("large UTF-8 view agrees with UTF-16", [](){
        initAllocator();
        // Force a Tag_LargeByteHeader backing buffer (> 8 KiB).
        size_t len = 9000 + *rc::gen::inRange<size_t>(0, 200);
        std::string s;
        s.reserve(len);
        for (size_t i = 0; i < len; ++i) s.push_back(static_cast<char>(33 + (i % 94)));
        checkSingle(makeU8View(s), s);
    });
}

// ---------------------------------------------------------------------------
// Binary ops: append / equal / compare / contains / startsWith / endsWith,
// across every representation pairing.
// ---------------------------------------------------------------------------

static int sign(int x) { return (x > 0) - (x < 0); }

static void test_binary_ops_cross_form() {
    rc::check("append/equal/compare/search agree across forms", []() {
        initAllocator();
        std::string a = genAscii();
        std::string b = genAscii();
        if (a.empty() || b.empty()) return;

        // Builder table: index 0..2 -> {u16, u8leaf, u8view}.
        auto build = [](int kind, const std::string& s) -> HPointer {
            switch (kind) {
                case 0: return makeU16(s);
                case 1: return makeU8Leaf(s);
                default: return makeU8View(s);
            }
        };

        for (int ka = 0; ka < 3; ++ka) {
            for (int kb = 0; kb < 3; ++kb) {
                HPointer ha = build(ka, a);
                HPointer hb = build(kb, b);
                void* oa = rz(ha);
                void* ob = rz(hb);

                // append
                RC_ASSERT(content(StringOps::append(oa, ob)) == a + b);
                // equal: same content across forms => true; a vs b => (a==b)
                RC_ASSERT(StringOps::equal(oa, ob) == (a == b));
                // self-equal across the two encodings of `a`
                {
                    HPointer ha2 = build(kb, a);
                    RC_ASSERT(StringOps::equal(rz(ha), rz(ha2)));
                }
                // compare sign matches std::string::compare sign
                RC_ASSERT(sign(StringOps::compare(oa, ob)) ==
                          sign(a.compare(b)));
                // startsWith / endsWith / contains with prefix/suffix of a
                if (a.size() >= 2) {
                    std::string pre = a.substr(0, a.size() / 2);
                    std::string suf = a.substr(a.size() / 2);
                    HPointer hpre = build(kb, pre);
                    HPointer hsuf = build(kb, suf);
                    RC_ASSERT(StringOps::startsWith(rz(hpre), oa));
                    RC_ASSERT(StringOps::endsWith(rz(hsuf), oa));
                    RC_ASSERT(StringOps::contains(rz(hpre), oa));
                }
            }
        }
    });
}

// Mixed against a non-ASCII UTF-16 operand: equal must be false and compare
// sign must match UTF-16 code-unit order (ASCII always sorts below >=0x80).
static void test_mixed_nonascii_operand() {
    initAllocator();
    // "café" — é is U+00E9 (non-ASCII, stays UTF-16); ASCII twin "cafe".
    std::string asciiStr = "cafe";
    std::string nonAscii = "caf\xC3\xA9";  // UTF-8 for "café"

    HPointer utf8 = makeU8View(asciiStr);
    HPointer u16 = makeU16FromUtf8(nonAscii);
    void* a = rz(utf8);
    void* b = rz(u16);

    // Different content => not equal.
    TEST_ASSERT(!StringOps::equal(a, b));
    // "cafe" vs "café": first 3 chars equal, then 'e'(0x65) vs 'é'(0xE9).
    // 0x65 < 0xE9 => cafe < café.
    TEST_ASSERT(StringOps::compare(a, b) < 0);
    TEST_ASSERT(StringOps::compare(b, a) > 0);
    // The non-ASCII string is a plain UTF-16 leaf (never a UTF-8 form).
    TEST_ASSERT(!StringOps::isUtf8(b));
    TEST_ASSERT(alloc::getTag(b) == Tag_String);
    // length: "café" is 4 UTF-16 units.
    TEST_ASSERT(StringOps::length(b) == 4);
}

// Astral content: length is 2 UTF-16 units, and it never becomes a UTF-8 form.
static void test_astral_stays_utf16() {
    initAllocator();
    std::string emoji = "\xF0\x9F\x98\x80";  // U+1F600, 4 UTF-8 bytes
    HPointer h = makeU16FromUtf8(emoji);
    void* o = rz(h);
    TEST_ASSERT(StringOps::length(o) == 2);          // surrogate pair
    TEST_ASSERT(!StringOps::isUtf8(o));
    TEST_ASSERT(content(h) == emoji);                // round-trips to same UTF-8
}

// ---------------------------------------------------------------------------
// Representation checks: which form does each construction path yield?
// ---------------------------------------------------------------------------

static void test_representation_tags() {
    initAllocator();
    // Leaf construction yields Tag_StringUtf8Leaf below the large threshold.
    HPointer leaf = makeU8Leaf("hello world");
    TEST_ASSERT(alloc::getTag(rz(leaf)) == Tag_StringUtf8Leaf);
    TEST_ASSERT(StringOps::isUtf8(rz(leaf)));

    // View construction yields Tag_StringUtf8View.
    HPointer view = makeU8View("some longer ascii content here");
    TEST_ASSERT(alloc::getTag(rz(view)) == Tag_StringUtf8View);

    // Empty always canonicalises to the embedded constant.
    TEST_ASSERT(alloc::isEmptyString(StringOps::makeUtf8LeafFromBytes(nullptr, 0)));
    HPointer bb = alloc::allocByteBuffer(nullptr, 0);
    TEST_ASSERT(alloc::isEmptyString(StringOps::makeUtf8View(bb, 0, 0)));

    // A UTF-8 leaf at/above the large-object threshold falls back to UTF-16.
    std::string big(9000, 'x');
    HPointer bigLeaf = makeU8Leaf(big);
    TEST_ASSERT(!StringOps::isUtf8(rz(bigLeaf)));    // widened to UTF-16 split
    TEST_ASSERT(content(bigLeaf) == big);
}

// ---------------------------------------------------------------------------
// GC: UTF-8 views over nursery and large buffers survive minor + major GC.
// ---------------------------------------------------------------------------

static void test_utf8_survives_gc() {
    auto& alloc = initAllocator(pressureHeapConfig());

    std::string small = "the quick brown fox jumps over the lazy dog";
    std::string large(9000, 'q');  // Tag_LargeByteHeader-backed view

    HPointer v0 = makeU8View(small);
    HPointer v1 = makeU8View(large);
    alloc.getRootSet().addRoot(&v0);   // long-lived roots (liveness + fixup)
    alloc.getRootSet().addRoot(&v1);

    // Churn the (tiny) nursery to drive minor GCs; periodic safepoints promote
    // survivors and eventually run a major GC that must mark/fix the views.
    for (int i = 0; i < 5000; ++i) {
        HPointer junk = makeU16("garbage allocation to churn the heap here");
        (void)junk;  // allocString has observable heap side effects; not elided
        if (i % 64 == 0) alloc.collectAtSafepoint();
    }
    alloc.collectAtSafepoint();

    TEST_ASSERT(content(v0) == small);
    TEST_ASSERT(content(v1) == large);

    alloc.getRootSet().removeRoot(&v0);
    alloc.getRootSet().removeRoot(&v1);
}

// W2: alloc::allocStringFromUTF8 (the kernel ingestion chokepoint) produces a
// UTF-8 form for ASCII and keeps UTF-16 for non-ASCII / invalid / kill-switch.
static void test_ingestion_gate() {
    {
        auto& alloc = initAllocator();
        // Small ASCII -> inline leaf.
        HPointer small = alloc::allocStringFromUTF8("hello world");
        TEST_ASSERT(alloc::getTag(rz(small)) == Tag_StringUtf8Leaf);
        TEST_ASSERT(content(small) == "hello world");

        // Large ASCII (>= large_object_threshold) -> ByteBuffer + view.
        std::string big(9000, 'a');
        HPointer large = alloc::allocStringFromUTF8(big);
        TEST_ASSERT(alloc::getTag(rz(large)) == Tag_StringUtf8View);
        TEST_ASSERT(content(large) == big);
        TEST_ASSERT(StringOps::length(rz(large)) == 9000);

        // Non-ASCII -> legacy UTF-16 leaf, content preserved (café).
        HPointer nonAscii = alloc::allocStringFromUTF8("caf\xC3\xA9");
        TEST_ASSERT(alloc::getTag(rz(nonAscii)) == Tag_String);
        TEST_ASSERT(StringOps::length(rz(nonAscii)) == 4);

        // Invalid UTF-8 -> legacy path (Tag_String), must not crash.
        HPointer invalid = alloc::allocStringFromUTF8(std::string("\x80\xC2", 2));
        (void)invalid;
        TEST_ASSERT(alloc::getTag(rz(invalid)) == Tag_String);

        // Empty -> embedded constant.
        TEST_ASSERT(alloc::isConstant(alloc::allocStringFromUTF8("")));
    }
    {
        // Kill switch off -> ASCII stays UTF-16.
        HeapConfig cfg;
        cfg.utf8_strings_enabled = false;
        initAllocator(cfg);
        HPointer s = alloc::allocStringFromUTF8("hello world");
        TEST_ASSERT(alloc::getTag(rz(s)) == Tag_String);
        TEST_ASSERT(content(s) == "hello world");
    }
}

// W4/W6.2: conservative widening — a UTF-8 input must yield a UTF-8 result
// (leaf or view), not decay to a UTF-16 Tag_String, for every arm.
static bool isU8(HPointer hp) {
    void* o = rz(hp);
    return o != nullptr && StringOps::isUtf8(o);
}

static void test_conservative_widening() {
    auto& alloc = initAllocator();
    HPointer a = makeU8Leaf("Hello, World foo bar baz qux 123");  // 32 ASCII
    HPointer b = makeU8Leaf("XYZ");
    alloc.getRootSet().addRoot(&a);
    alloc.getRootSet().addRoot(&b);

    TEST_ASSERT(isU8(StringOps::toUpper(rz(a))));
    TEST_ASSERT(isU8(StringOps::toLower(rz(a))));
    TEST_ASSERT(isU8(StringOps::reverse(rz(a))));
    TEST_ASSERT(isU8(StringOps::repeat(rz(a), 3)));
    TEST_ASSERT(isU8(StringOps::padLeft(rz(a), 50, static_cast<u16>(' '))));
    TEST_ASSERT(isU8(StringOps::padRight(rz(a), 50, static_cast<u16>(' '))));
    TEST_ASSERT(isU8(StringOps::filter([](u16 c) { return c != static_cast<u16>(' '); },
                                       rz(a))));
    TEST_ASSERT(isU8(StringOps::append(rz(a), rz(b))));

    // concat of a UTF-8 list stays UTF-8.
    HPointer list = alloc::listFromPointers(std::vector<HPointer>{a, b, a});
    TEST_ASSERT(isU8(StringOps::concat(list)));

    // join of a UTF-8 list with a UTF-8 separator stays UTF-8.
    HPointer sep = makeU8Leaf(", ");
    alloc.getRootSet().addRoot(&sep);
    HPointer list2 = alloc::listFromPointers(std::vector<HPointer>{a, b});
    TEST_ASSERT(isU8(StringOps::join(rz(sep), list2)));

    // split parts stay UTF-8.
    HPointer csv = makeU8Leaf("aaa,bbb,ccc");
    HPointer comma = makeU8Leaf(",");
    alloc.getRootSet().addRoot(&csv);
    HPointer parts = StringOps::split(rz(comma), rz(csv));
    void* cell = rz(parts);
    TEST_ASSERT(cell != nullptr);
    Cons* c = static_cast<Cons*>(cell);
    TEST_ASSERT(StringOps::isUtf8(alloc.resolve(c->head.p)));

    // Mixed operand: append(UTF-8, UTF-16) must still give the right VALUE
    // (representation may be either — assert value, not form).
    HPointer u16 = makeU16("MID");
    alloc.getRootSet().addRoot(&u16);
    TEST_ASSERT(content(StringOps::append(rz(a), rz(u16))) ==
                std::string("Hello, World foo bar baz qux 123") + "MID");
}

void registerUtf8StringTests(Testing::TestSuite& suite) {
    suite.add(Testing::TestCase("Utf8String: conservative widening (UTF-8 in => UTF-8 out)",
                                test_conservative_widening));
    suite.add(Testing::TestCase("Utf8String: ingestion gate (allocStringFromUTF8)",
                                test_ingestion_gate));
    suite.add(Testing::TestCase("Utf8String: all forms agree (single-operand)",
                                test_forms_agree_single));
    suite.add(Testing::TestCase("Utf8String: large view agrees",
                                test_large_view_agrees));
    suite.add(Testing::TestCase("Utf8String: binary ops agree across forms",
                                test_binary_ops_cross_form));
    suite.add(Testing::TestCase("Utf8String: mixed non-ASCII operand",
                                test_mixed_nonascii_operand));
    suite.add(Testing::TestCase("Utf8String: astral stays UTF-16",
                                test_astral_stays_utf16));
    suite.add(Testing::TestCase("Utf8String: representation tags",
                                test_representation_tags));
    suite.add(Testing::TestCase("Utf8String: survives GC", test_utf8_survives_gc));
}
