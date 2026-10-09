/**
 * Large-object space (plans/large-object-space.md D2, HEAP_080).
 *
 * The LOS is made of ordinary old-gen blocks of `alloc_buffer_size` bytes that
 * OldGenSpace acquires and materializes like any page (so the page index, the
 * mark arena, region bounds and every block-based check keep working) and marks
 * with `BlockInfo::los`. This class manages the free space INSIDE those blocks:
 * one bit per granule, coalescing implicit in the bitmap, blocks binned by their
 * largest free run, best fit within a block. Two pools never share a block: raw
 * blocks hold header-less large bodies (D4), object blocks hold headered large
 * objects (YLOS, pinned pointer-free, permanent fallback).
 *
 * Mutator-thread only (HEAP_007): nothing here is read by markers or workers;
 * a marker learns a block's pool from BlockInfo::los alone.
 */
#ifndef ECO_LARGE_OBJECT_SPACE_H
#define ECO_LARGE_OBJECT_SPACE_H

#include <cstddef>
#include <cstdint>
#include <vector>

namespace Elm {

class LargeObjectSpace {
public:
    // Granules per block are capped so the per-block bitmap stays fixed-size.
    static constexpr size_t kMaxGranules = 1024;
    static constexpr size_t kWords = kMaxGranules / 64;
    static constexpr uint32_t kNone = UINT32_MAX;

    struct Stats {
        uint64_t allocs = 0, frees = 0;
        uint64_t alloc_bytes = 0, free_bytes = 0;        // granule bytes
        uint64_t object_bytes = 0;                       // requested bytes (waste = granule - object)
        uint64_t blocks_added = 0, blocks_removed = 0;
        uint64_t fit_misses = 0;                         // tryAllocate found no room
        uint64_t aligned_allocs = 0;
    };

    // `block_bytes` = alloc_buffer_size; `page_bytes` = OS_PAGE_SIZE.
    void init(size_t block_bytes, size_t page_bytes);
    void reset();

    size_t granuleBytes() const { return granule_; }
    size_t granulesPerBlock() const { return per_block_; }
    size_t granulesFor(size_t bytes) const { return (bytes + granule_ - 1) / granule_; }
    // The largest single object an LOS block can hold.
    size_t maxObjectBytes() const { return per_block_ * granule_; }

    // Registers a freshly materialized LOS block (all granules free).
    void addBlock(uint32_t id, char* start, bool raw);
    // Forgets a block (it must be empty). Called before it is released.
    void removeBlock(uint32_t id);
    bool hasBlock(uint32_t id) const { return id < meta_.size() && meta_[id].start != nullptr; }

    // Allocates `bytes` (granule-rounded) from the given pool. A request whose
    // size is a multiple of the OS page is placed page-aligned when the granule
    // is smaller than a page. Returns nullptr when no LOS block has room (the
    // caller then adds a block and retries); `*block_out` names the block.
    void* tryAllocate(size_t bytes, bool raw, uint32_t* block_out);

    // Frees the granules of an object of `bytes` at `p` in block `id`.
    // Returns true when the block is now entirely free.
    bool free(uint32_t id, void* p, size_t bytes);

    size_t usedGranules(uint32_t id) const { return meta_[id].used; }
    // Is the granule holding address `p` of block `id` allocated?
    bool isAllocated(uint32_t id, const void* p) const {
        const BlockMeta& m = meta_[id];
        return test(m, static_cast<size_t>(static_cast<const char*>(p) - m.start) / granule_);
    }
    size_t usedBytes(uint32_t id) const { return static_cast<size_t>(meta_[id].used) * granule_; }
    bool isRaw(uint32_t id) const { return meta_[id].raw != 0; }
    size_t largestFree(uint32_t id) const { return meta_[id].largest; }

    // Ids of the registered blocks that are entirely free.
    std::vector<uint32_t> emptyBlocks() const;
    size_t blockCount() const { return blocks_; }
    size_t usedBytesTotal() const {
        size_t n = 0;
        for (const BlockMeta& m : meta_) if (m.start != nullptr) n += m.used;
        return n * granule_;
    }
    const Stats& stats() const { return stats_; }

    // Consistency check for tests and validate builds: recomputes every
    // block's used count and largest run and checks the bins. Returns false
    // (and the first problem in *why) on a mismatch.
    bool validate(const char** why) const;

private:
    struct BlockMeta {
        char* start = nullptr;
        uint64_t bits[kWords] = {};   // 1 = granule allocated
        uint32_t used = 0;            // allocated granules
        uint32_t largest = 0;         // largest free run (granules)
        uint32_t prev = kNone, next = kNone;
        uint8_t bin = 0xFF;           // 0xFF = not binned (no free run)
        uint8_t raw = 0;
    };
    static constexpr size_t kBins = 12;   // bin b: largest in (2^(b-1), 2^b], b >= 0

    static size_t binFor(uint32_t largest);
    bool test(const BlockMeta& m, size_t g) const { return (m.bits[g >> 6] >> (g & 63)) & 1; }
    void setRange(BlockMeta& m, size_t g, size_t n, bool v);
    uint32_t computeLargest(const BlockMeta& m) const;
    // Best-fit run of `need` granules aligned to `align` granules; returns
    // the start granule or SIZE_MAX.
    size_t findRun(const BlockMeta& m, size_t need, size_t align) const;
    void unbin(uint32_t id);
    void rebin(uint32_t id);

    size_t block_bytes_ = 0;
    size_t page_bytes_ = 0;
    size_t granule_ = 1024;
    size_t per_block_ = 0;
    size_t blocks_ = 0;
    std::vector<BlockMeta> meta_;          // indexed by BlockId.v
    uint32_t heads_[2][kBins];             // [raw][bin] -> first block
    Stats stats_;
};

} // namespace Elm

#endif // ECO_LARGE_OBJECT_SPACE_H
