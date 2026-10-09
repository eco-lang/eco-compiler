// Large-object space: free space inside LOS blocks (plans/large-object-space.md D2).
#include "LargeObjectSpace.hpp"

#include <cassert>
#include <cstring>

namespace Elm {

void LargeObjectSpace::init(size_t block_bytes, size_t page_bytes) {
    block_bytes_ = block_bytes;
    page_bytes_ = page_bytes;
    granule_ = 1024;
    while (block_bytes_ / granule_ > kMaxGranules) granule_ *= 2;
    per_block_ = block_bytes_ / granule_;
    reset();
}

void LargeObjectSpace::reset() {
    meta_.clear();
    blocks_ = 0;
    for (auto& pool : heads_)
        for (uint32_t& h : pool) h = kNone;
    stats_ = Stats{};
}

size_t LargeObjectSpace::binFor(uint32_t largest) {
    assert(largest > 0);
    size_t b = 0;
    while ((size_t{1} << b) < largest) ++b;
    return b;
}

void LargeObjectSpace::setRange(BlockMeta& m, size_t g, size_t n, bool v) {
    for (size_t i = g; i < g + n; ++i) {
        const uint64_t bit = uint64_t{1} << (i & 63);
        if (v) m.bits[i >> 6] |= bit;
        else m.bits[i >> 6] &= ~bit;
    }
}

uint32_t LargeObjectSpace::computeLargest(const BlockMeta& m) const {
    size_t best = 0, run = 0, g = 0;
    while (g < per_block_) {
        if ((g & 63) == 0 && g + 64 <= per_block_) {
            const uint64_t w = m.bits[g >> 6];
            if (w == 0) { run += 64; g += 64; continue; }
            if (w == ~uint64_t{0}) {
                if (run > best) best = run;
                run = 0; g += 64; continue;
            }
        }
        if (test(m, g)) {
            if (run > best) best = run;
            run = 0;
        } else {
            ++run;
        }
        ++g;
    }
    if (run > best) best = run;
    return static_cast<uint32_t>(best);
}

size_t LargeObjectSpace::findRun(const BlockMeta& m, size_t need, size_t align) const {
    size_t best_start = SIZE_MAX, best_len = SIZE_MAX;
    size_t g = 0;
    while (g < per_block_) {
        if (test(m, g)) { ++g; continue; }
        const size_t s = g;
        while (g < per_block_ && !test(m, g)) ++g;
        const size_t e = g;   // free run [s, e)
        const size_t a = (s + align - 1) / align * align;
        if (a + need <= e && (e - s) < best_len) {
            best_len = e - s;
            best_start = a;
            if (best_len == need) break;   // exact fit
        }
    }
    return best_start;
}

void LargeObjectSpace::unbin(uint32_t id) {
    BlockMeta& m = meta_[id];
    if (m.bin == 0xFF) return;
    uint32_t& head = heads_[m.raw][m.bin];
    if (m.prev != kNone) meta_[m.prev].next = m.next;
    else head = m.next;
    if (m.next != kNone) meta_[m.next].prev = m.prev;
    m.prev = m.next = kNone;
    m.bin = 0xFF;
}

void LargeObjectSpace::rebin(uint32_t id) {
    unbin(id);
    BlockMeta& m = meta_[id];
    if (m.largest == 0) return;
    const size_t b = binFor(m.largest);
    m.bin = static_cast<uint8_t>(b);
    uint32_t& head = heads_[m.raw][b];
    m.prev = kNone;
    m.next = head;
    if (head != kNone) meta_[head].prev = id;
    head = id;
}

void LargeObjectSpace::addBlock(uint32_t id, char* start, bool raw) {
    if (id >= meta_.size()) meta_.resize(id + 1);
    BlockMeta& m = meta_[id];
    assert(m.start == nullptr && "LargeObjectSpace::addBlock: id already registered");
    m = BlockMeta{};
    m.start = start;
    m.raw = raw ? 1 : 0;
    m.largest = static_cast<uint32_t>(per_block_);
    rebin(id);
    ++blocks_;
    ++stats_.blocks_added;
}

void LargeObjectSpace::removeBlock(uint32_t id) {
    assert(hasBlock(id));
    assert(meta_[id].used == 0 && "LargeObjectSpace::removeBlock: block still holds objects");
    unbin(id);
    meta_[id] = BlockMeta{};
    --blocks_;
    ++stats_.blocks_removed;
}

void* LargeObjectSpace::tryAllocate(size_t bytes, bool raw, uint32_t* block_out) {
    const size_t need = granulesFor(bytes);
    if (need == 0 || need > per_block_) return nullptr;
    size_t align = 1;
    if (page_bytes_ > granule_ && bytes % page_bytes_ == 0) align = page_bytes_ / granule_;
    const int pool = raw ? 1 : 0;
    for (size_t b = binFor(static_cast<uint32_t>(need)); b < kBins; ++b) {
        for (uint32_t id = heads_[pool][b]; id != kNone; id = meta_[id].next) {
            BlockMeta& m = meta_[id];
            if (m.largest < need) continue;
            const size_t g = findRun(m, need, align);
            if (g == SIZE_MAX) continue;
            setRange(m, g, need, true);
            m.used += static_cast<uint32_t>(need);
            m.largest = computeLargest(m);
            rebin(id);
            ++stats_.allocs;
            stats_.alloc_bytes += need * granule_;
            stats_.object_bytes += bytes;
            if (align > 1) ++stats_.aligned_allocs;
            *block_out = id;
            return m.start + g * granule_;
        }
    }
    ++stats_.fit_misses;
    return nullptr;
}

bool LargeObjectSpace::free(uint32_t id, void* p, size_t bytes) {
    assert(hasBlock(id));
    BlockMeta& m = meta_[id];
    const size_t off = static_cast<size_t>(static_cast<char*>(p) - m.start);
    assert(off % granule_ == 0 && "LargeObjectSpace::free: not a granule start");
    const size_t g = off / granule_;
    const size_t n = granulesFor(bytes);
    assert(g + n <= per_block_);
#ifndef NDEBUG
    for (size_t i = g; i < g + n; ++i) assert(test(m, i) && "LargeObjectSpace::free: granule not allocated");
#endif
    setRange(m, g, n, false);
    assert(m.used >= n);
    m.used -= static_cast<uint32_t>(n);
    m.largest = computeLargest(m);
    rebin(id);
    ++stats_.frees;
    stats_.free_bytes += n * granule_;
    return m.used == 0;
}

std::vector<uint32_t> LargeObjectSpace::emptyBlocks() const {
    std::vector<uint32_t> out;
    for (uint32_t id = 0; id < meta_.size(); ++id)
        if (meta_[id].start != nullptr && meta_[id].used == 0) out.push_back(id);
    return out;
}

bool LargeObjectSpace::validate(const char** why) const {
    size_t count = 0;
    for (uint32_t id = 0; id < meta_.size(); ++id) {
        const BlockMeta& m = meta_[id];
        if (m.start == nullptr) continue;
        ++count;
        size_t used = 0;
        for (size_t g = 0; g < per_block_; ++g) used += test(m, g) ? 1 : 0;
        for (size_t g = per_block_; g < kMaxGranules; ++g)
            if (test(m, g)) { *why = "bit set past the block's granules"; return false; }
        if (used != m.used) { *why = "used count disagrees with the bitmap"; return false; }
        if (computeLargest(m) != m.largest) { *why = "largest-run cache is stale"; return false; }
        const uint8_t want = m.largest == 0 ? uint8_t{0xFF} : static_cast<uint8_t>(binFor(m.largest));
        if (m.bin != want) { *why = "block is in the wrong bin"; return false; }
    }
    if (count != blocks_) { *why = "block count disagrees"; return false; }
    // Every binned block is reachable from its bin's list exactly once.
    size_t linked = 0;
    for (int pool = 0; pool < 2; ++pool) {
        for (size_t b = 0; b < kBins; ++b) {
            uint32_t prev = kNone;
            for (uint32_t id = heads_[pool][b]; id != kNone; id = meta_[id].next) {
                const BlockMeta& m = meta_[id];
                if (m.bin != b || m.raw != pool || m.prev != prev) {
                    *why = "bin list links are inconsistent";
                    return false;
                }
                prev = id;
                ++linked;
                if (linked > meta_.size()) { *why = "bin list cycle"; return false; }
            }
        }
    }
    size_t binned = 0;
    for (const BlockMeta& m : meta_) if (m.start != nullptr && m.bin != 0xFF) ++binned;
    if (binned != linked) { *why = "a binned block is missing from its list"; return false; }
    return true;
}

} // namespace Elm
