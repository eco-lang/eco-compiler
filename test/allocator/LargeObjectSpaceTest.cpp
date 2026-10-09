/**
 * LargeObjectSpace (plans/large-object-space.md D2): the free-space manager
 * inside LOS blocks, tested on plain memory (no heap): coalescing, best fit,
 * page alignment, pool separation, empty detection, and a seeded random churn
 * checked against validate() and a shadow model after every operation.
 */
#include "LargeObjectSpaceTest.hpp"

#include <cstdlib>
#include <map>
#include <random>
#include <vector>

#include "Allocator.hpp"
#include "Heap.hpp"
#include "HeapHelpers.hpp"
#include "StringOps.hpp"
#include "LargeObjectSpace.hpp"
#include "OldGenSpace.hpp"
#include "TestHelpers.hpp"
#include "ThreadLocalHeap.hpp"

using namespace Elm;

namespace {

constexpr size_t kBlock = 512 * 1024;
constexpr size_t kPage = 4096;
constexpr size_t KiB = 1024;

// Plain, block-aligned memory standing in for LOS blocks.
struct Arena {
    std::vector<char*> blocks;
    explicit Arena(size_t n) {
        for (size_t i = 0; i < n; ++i)
            blocks.push_back(static_cast<char*>(std::aligned_alloc(kBlock, kBlock)));
    }
    ~Arena() { for (char* b : blocks) std::free(b); }
};

void assertValid(const LargeObjectSpace& los) {
    const char* why = nullptr;
    if (!los.validate(&why)) {
        std::fprintf(stderr, "LOS validate: %s\n", why);
        TEST_ASSERT(false);
    }
}

}  // namespace

Testing::TestCase testLosCoalescesBothNeighbours(
    "LOS: freeing coalesces with both neighbours", []() {
    Arena a(1);
    LargeObjectSpace los;
    los.init(kBlock, kPage);
    TEST_ASSERT(los.granuleBytes() == KiB && los.granulesPerBlock() == 512);
    los.addBlock(0, a.blocks[0], true);
    uint32_t id = 99;
    void* x = los.tryAllocate(64 * KiB, true, &id);
    void* y = los.tryAllocate(64 * KiB, true, &id);
    void* z = los.tryAllocate(64 * KiB, true, &id);
    TEST_ASSERT(x && y && z && id == 0);
    TEST_ASSERT(los.largestFree(0) == 512 - 192);
    TEST_ASSERT(!los.free(0, y, 64 * KiB));
    assertValid(los);
    TEST_ASSERT(!los.free(0, x, 64 * KiB));   // merges with y's run: 128 KiB at the front
    TEST_ASSERT(los.largestFree(0) == 512 - 192);
    TEST_ASSERT(los.free(0, z, 64 * KiB));    // everything free again
    TEST_ASSERT(los.largestFree(0) == 512);
    TEST_ASSERT(los.usedGranules(0) == 0);
    assertValid(los);
});

Testing::TestCase testLosBestFitAndExactReuse(
    "LOS: best fit picks the smallest hole; a freed chunk is reused exactly", []() {
    Arena a(1);
    LargeObjectSpace los;
    los.init(kBlock, kPage);
    los.addBlock(0, a.blocks[0], true);
    uint32_t id;
    std::vector<void*> v;
    for (int i = 0; i < 8; ++i) v.push_back(los.tryAllocate(64 * KiB, true, &id));
    TEST_ASSERT(los.largestFree(0) == 0);
    TEST_ASSERT(los.tryAllocate(KiB, true, &id) == nullptr);   // full
    los.free(0, v[1], 64 * KiB);                                // 64 KiB hole
    los.free(0, v[4], 64 * KiB);
    los.free(0, v[5], 64 * KiB);                                // 128 KiB hole
    void* p = los.tryAllocate(60 * KiB, true, &id);
    TEST_ASSERT(p == v[1]);                                     // the 64 KiB hole, not the 128
    los.free(0, p, 60 * KiB);
    void* q = los.tryAllocate(64 * KiB, true, &id);             // an exact 64 KiB chunk
    TEST_ASSERT(q == v[1]);
    assertValid(los);
});

Testing::TestCase testLosPageAlignsPageMultiples(
    "LOS: page-multiple sizes are placed page-aligned", []() {
    Arena a(1);
    LargeObjectSpace los;
    los.init(kBlock, kPage);
    los.addBlock(0, a.blocks[0], true);
    uint32_t id;
    void* odd = los.tryAllocate(9 * KiB, true, &id);             // 9 granules: not page-aligned after it
    TEST_ASSERT(odd == a.blocks[0]);
    void* aligned = los.tryAllocate(64 * KiB, true, &id);
    TEST_ASSERT(aligned != nullptr);
    TEST_ASSERT(reinterpret_cast<uintptr_t>(aligned) % kPage == 0);
    TEST_ASSERT(static_cast<char*>(aligned) - a.blocks[0] == 12 * KiB);
    TEST_ASSERT(los.stats().aligned_allocs == 1);
    assertValid(los);
});

Testing::TestCase testLosPoolsNeverShareABlock(
    "LOS: raw and object pools never share a block", []() {
    Arena a(2);
    LargeObjectSpace los;
    los.init(kBlock, kPage);
    los.addBlock(0, a.blocks[0], true);
    uint32_t id = 99;
    TEST_ASSERT(los.tryAllocate(16 * KiB, false, &id) == nullptr);   // no object block yet
    los.addBlock(1, a.blocks[1], false);
    void* o = los.tryAllocate(16 * KiB, false, &id);
    TEST_ASSERT(o == a.blocks[1] && id == 1 && !los.isRaw(1));
    void* r = los.tryAllocate(16 * KiB, true, &id);
    TEST_ASSERT(r == a.blocks[0] && id == 0 && los.isRaw(0));
    TEST_ASSERT(los.tryAllocate(kBlock + KiB, true, &id) == nullptr);   // over one block
    assertValid(los);
});

Testing::TestCase testLosEmptyBlocksAndRemoval(
    "LOS: empty blocks are reported and can be removed", []() {
    Arena a(3);
    LargeObjectSpace los;
    los.init(kBlock, kPage);
    for (uint32_t i = 0; i < 3; ++i) los.addBlock(i, a.blocks[i], false);
    uint32_t id;
    // Fill block choice: a request goes to one block; the others stay empty.
    void* p = los.tryAllocate(300 * KiB, false, &id);
    TEST_ASSERT(p != nullptr);
    const uint32_t used = id;
    auto empty = los.emptyBlocks();
    TEST_ASSERT(empty.size() == 2);
    for (uint32_t e : empty) {
        TEST_ASSERT(e != used);
        los.removeBlock(e);
    }
    TEST_ASSERT(los.blockCount() == 1);
    TEST_ASSERT(los.free(used, p, 300 * KiB));
    assertValid(los);
});

Testing::TestCase testLosRandomChurnMatchesShadow(
    "LOS: random churn keeps bitmap, bins and a shadow model in agreement", []() {
    Arena a(6);
    LargeObjectSpace los;
    los.init(kBlock, kPage);
    for (uint32_t i = 0; i < 6; ++i) los.addBlock(i, a.blocks[i], (i & 1) != 0);
    std::mt19937_64 rng(20261009);
    struct Obj { void* p; size_t bytes; uint32_t id; bool raw; };
    std::vector<Obj> live;
    std::map<char*, char*> shadow;   // [start, end) of every live object, by start
    for (int op = 0; op < 20000; ++op) {
        const bool doAlloc = live.empty() || (rng() % 100) < 55;
        if (doAlloc) {
            static const size_t sizes[] = {8 * KiB + 8, 12 * KiB, 16 * KiB, 64 * KiB,
                                           64 * KiB + 8, 100 * KiB, 256 * KiB, 9 * KiB};
            const size_t bytes = sizes[rng() % 8];
            const bool raw = (rng() & 1) != 0;
            uint32_t id = 0;
            void* p = los.tryAllocate(bytes, raw, &id);
            if (!p) continue;
            TEST_ASSERT(los.isRaw(id) == raw);
            char* s = static_cast<char*>(p);
            char* e = s + los.granulesFor(bytes) * los.granuleBytes();
            // No overlap with any live object.
            auto it = shadow.lower_bound(s);
            if (it != shadow.end()) TEST_ASSERT(it->first >= e);
            if (it != shadow.begin()) TEST_ASSERT(std::prev(it)->second <= s);
            shadow[s] = e;
            live.push_back({p, bytes, id, raw});
        } else {
            const size_t k = rng() % live.size();
            Obj o = live[k];
            live[k] = live.back();
            live.pop_back();
            shadow.erase(static_cast<char*>(o.p));
            los.free(o.id, o.p, o.bytes);
        }
        if (op % 97 == 0) assertValid(los);
    }
    assertValid(los);
    for (const Obj& o : live) los.free(o.id, o.p, o.bytes);
    TEST_ASSERT(los.emptyBlocks().size() == 6);
    assertValid(los);
});

// ----------------------------------------------------------------------------
// Heap level (plans/large-object-space.md D3): every large kind lands in an
// LOS block, and 64 KiB chunk churn reuses LOS blocks instead of growing.
// ----------------------------------------------------------------------------

namespace {

HeapConfig losHeapConfig() {
    HeapConfig cfg;
    cfg.alloc_buffer_size = 512 * 1024;
    cfg.nursery_block_count = 4;
    cfg.initial_old_gen_size = 2 * 1024 * 1024;
    cfg.max_heap_size = 256ULL * 1024 * 1024;
    cfg.large_ptr_nursery_divisor = 0;   // every pointer-bearing object >= LOT is a YLOS
    cfg.validate();
    return cfg;
}

OldGenSpace& losOldGen(Allocator& a) { return AllocatorTestAccess::getThreadHeap(a)->getOldGen(); }

bool inLos(Allocator& a, const void* p) {
    OldGenSpace& og = losOldGen(a);
    const BlockId b = OldGenSpaceTestAccess::blockIdFor(og, p);
    return b.valid() && og.isLosBlock(b);
}

}  // namespace

Testing::TestCase testLosPlacementOfEveryLargeKind(
    "LOS: split bodies, YLOS and pinned large objects all live in LOS blocks", []() {
    auto& a = initAllocator(losHeapConfig());
    OldGenSpace& og = losOldGen(a);
    // A split Bytes body.
    HPointer bytes = a.allocLargeByteBuffer(nullptr, 64 * KiB);
    a.getRootSet().addRoot(&bytes);
    auto* lh = static_cast<LargeByteHeader*>(a.resolve(bytes));
    TEST_ASSERT(lh->header.tag == Tag_LargeByteHeader);
    TEST_ASSERT(inLos(a, largeBodyAddr(lh)));
    // A split String body.
    HPointer str = alloc::allocString(std::u16string(20000, u'q'));
    a.getRootSet().addRoot(&str);
    auto* sh = static_cast<LargeStringHeader*>(a.resolve(str));
    TEST_ASSERT(sh->header.tag == Tag_LargeStringHeader);
    TEST_ASSERT(inLos(a, largeBodyAddr(sh)));
    // A YLOS (pointer-bearing, over the nursery placement cap).
    HPointer arr = alloc::arrayFromPointers(std::vector<HPointer>(3000, alloc::listNil()));
    a.getRootSet().addRoot(&arr);
    void* ylos = a.resolve(arr);
    TEST_ASSERT(og.isYoungLarge(ylos));
    TEST_ASSERT(inLos(a, ylos));
    // A pinned pointer-free large object (an unsplit ByteBuffer-tagged cell).
    void* pinned = a.allocate(40 * KiB, Tag_ByteBuffer);
    TEST_ASSERT(pinned != nullptr && inLos(a, pinned));
    // Raw and object pools are not mixed yet (bodies keep headers until Phase 5),
    // and no LOS object sits in an ordinary block.
    a.minorGC();
    a.majorGC();
    TEST_ASSERT(inLos(a, largeBodyAddr(static_cast<LargeByteHeader*>(a.resolve(bytes)))));
    TEST_ASSERT(inLos(a, a.resolve(arr)));
    const char* why = nullptr;
    TEST_ASSERT(og.largeObjectSpace().validate(&why));
    a.getRootSet().removeRoot(&arr);
    a.getRootSet().removeRoot(&str);
    a.getRootSet().removeRoot(&bytes);
});

Testing::TestCase testLosChunkChurnReusesBlocks(
    "LOS: 1 GiB of dropped 64 KiB chunks stays within a few LOS blocks", []() {
    auto& a = initAllocator(losHeapConfig());
    OldGenSpace& og = losOldGen(a);
    for (size_t i = 0; i < 16384; ++i) {   // 1 GiB of 64 KiB Bytes, none kept
        alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(64 * KiB);
        bb.bytes[0] = static_cast<u8>(i);
    }
    // Minors (HEAP_079's debt) free the dead bodies; a mark cycle may defer
    // frees for its 33 minors, so allow a generous bound.
    const size_t blocks = og.largeObjectSpace().blockCount();
    std::fprintf(stderr, "  LOS blocks after 1 GiB of churn: %zu (granule %zu B)\n", blocks,
                 og.largeObjectSpace().granuleBytes());
    TEST_ASSERT(blocks <= 64);
    // Every chunk not yet freed (a running cycle defers frees) still fits in
    // the remaining blocks: 8 header-less 64 KiB bodies per 512 KiB block.
    const auto& st = og.largeObjectSpace().stats();
    TEST_ASSERT(st.allocs >= 16384);
    TEST_ASSERT(st.allocs - st.frees <= blocks * 8);
    const char* why = nullptr;
    TEST_ASSERT(og.largeObjectSpace().validate(&why));
});

// ----------------------------------------------------------------------------
// Header-less bodies (plans/large-object-space.md D4, HEAP_081).
// ----------------------------------------------------------------------------

Testing::TestCase testLosHeaderlessForwardingHazard(
    "LOS: header-less bodies whose first byte reads as Tag_Forward survive minors and majors", []() {
    // 'Z' = 0x5A and 0x1A: low 5 bits 26 = Tag_Forward. Allocator::resolve on
    // such a body would follow a bogus forwarding pointer; every reader must
    // go through the raw accessors.
    static_assert(Tag_Forward == 26, "the hazard needs Tag_Forward == 26");
    auto& a = initAllocator(losHeapConfig());
    std::u16string zs(20000, u'y');
    zs[0] = u'Z';
    zs[1] = u'z';
    HPointer s = alloc::allocString(zs);
    a.getRootSet().addRoot(&s);
    std::vector<u8> zb(70000, 0x77);
    zb[0] = 0x1A;
    zb[1] = 0x3A;
    HPointer b = alloc::allocByteBuffer(zb.data(), zb.size());
    a.getRootSet().addRoot(&b);
    for (int round = 0; round < 3; ++round) {
        a.minorGC();
        a.majorGC();
        void* so = a.resolve(s);
        TEST_ASSERT(getHeader(so)->tag == Tag_LargeStringHeader);
        TEST_ASSERT(StringOps::toStdU16String(so) == zs);
        TEST_ASSERT(StringOps::charAt(so, 0) == u'Z');
        void* bo = a.resolve(b);
        TEST_ASSERT(getHeader(bo)->tag == Tag_LargeByteHeader);
        const alloc::ByteBufferView v = alloc::byteBufferView(bo);
        TEST_ASSERT(v.length == zb.size());
        TEST_ASSERT(std::memcmp(v.data, zb.data(), zb.size()) == 0);
        // A slice over the large Bytes and a String slice/upper-case read through it.
        HPointer sl = alloc::makeByteBufferSlice(b, 0, 64);
        const alloc::ByteBufferView sv = alloc::byteBufferView(a.resolve(sl));
        TEST_ASSERT(sv.length == 64 && sv.data[0] == 0x1A && sv.data[1] == 0x3A);
        HPointer up = StringOps::toUpper(a.resolve(s));
        TEST_ASSERT(StringOps::charAt(a.resolve(up), 1) == u'Z');
    }
    a.getRootSet().removeRoot(&b);
    a.getRootSet().removeRoot(&s);
});

Testing::TestCase testLosHeaderless64KiBChunkIsExact(
    "LOS: a 64 KiB Bytes body occupies exactly 64 page-aligned granules and is reused exactly", []() {
    auto& a = initAllocator(losHeapConfig());
    OldGenSpace& og = losOldGen(a);
    HPointer x = a.allocLargeByteBuffer(nullptr, 64 * KiB);
    void* body = largeBodyAddr(static_cast<LargeByteHeader*>(a.resolve(x)));
    TEST_ASSERT(og.isRawBody(body));
    TEST_ASSERT(reinterpret_cast<uintptr_t>(body) % 4096 == 0);
    const BlockId bid = OldGenSpaceTestAccess::blockIdFor(og, body);
    TEST_ASSERT(og.largeObjectSpace().usedGranules(bid.v) == 64 * KiB / og.largeObjectSpace().granuleBytes());
    // Dead after the next minor; the next 64 KiB body takes exactly its granules.
    x = alloc::listNil();
    a.minorGC();
    TEST_ASSERT(og.largeObjectSpace().usedGranules(bid.v) == 0);
    HPointer y = a.allocLargeByteBuffer(nullptr, 64 * KiB);
    TEST_ASSERT(largeBodyAddr(static_cast<LargeByteHeader*>(a.resolve(y))) == body);
});
