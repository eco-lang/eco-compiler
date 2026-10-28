// The free-space manager for large-object blocks: it decides where inside a set of fixed-size blocks
// each large allocation goes, and takes the space back when it is freed.
//
// An allocation no larger than a block's whole granules is given a run of whole *granules* inside
// one block. A granule is the unit of placement here. `init` makes it 1 KiB, doubled
// until a block has at most `kMaxGranules` of them, so a block's state fits a fixed-size bitmap with
// one bit per granule, set when the granule is allocated. A block's free space is the clear runs of
// its bitmap, so freeing needs no merging of neighbours: clearing the bits is the merge. The bytes
// rounded up to a whole granule are waste, which `Stats` reports.
//
// This class never reads or writes the blocks' memory. The caller acquires a block, registers its
// start address with `addBlock`, and gets back addresses inside it. Blocks are named by a small integer
// id the caller chooses.
//
// Blocks fall into two *pools*, chosen at `addBlock` by the `raw` flag. A block stays in its pool until
// `removeBlock`, and an allocation is placed only in a block of the pool it asks for, so the two pools
// never share a block. What each pool holds is the caller's choice.
//
// Finding a block is done by binning. Each block caches the length of its *largest free run*, and the
// blocks of each pool are kept in bins by that length, in powers of two. An allocation searches the
// bins from the smallest that could hold it upwards, takes the first block in which a run fits, and
// within that block uses the shortest free run that fits (best fit).
//
// Nothing here is locked or atomic. Callers must not use one object from two threads at once.
#ifndef ECO_LARGE_OBJECT_SPACE_H
#define ECO_LARGE_OBJECT_SPACE_H

#include <cstddef>
#include <cstdint>
#include <vector>

namespace Elm {

/// The granule allocator for a set of large-object blocks, in two pools.
///
/// `init` must be called before any other function, because until then the object's state is
/// indeterminate. `init` and `reset` forget every block. The object is copyable, and a
/// copy is an independent allocator over the same block addresses, so using both would place two
/// objects in the same granules.
///
/// Every function that takes a block `id`, apart from `hasBlock` and `addBlock`, requires `id` to be
/// registered. `removeBlock` and `free` assert it when assertions are enabled (`NDEBUG` unset); the
/// accessors do not check it at all. An id larger than any registered since the last `init` or
/// `reset` gives undefined behaviour.
class LargeObjectSpace {
public:
    /// The most granules one block may have. It fixes the size of a block's bitmap.
    static constexpr size_t kMaxGranules = 1024;
    /// The number of 64-bit words in a block's bitmap.
    static constexpr size_t kWords = kMaxGranules / 64;
    /// The id that names no block.
    static constexpr uint32_t kNone = UINT32_MAX;

    /// Cumulative counts of this allocator's work since the last `init` or `reset`.
    struct Stats {
        uint64_t allocs = 0, frees = 0;
        /// Both in bytes, counting whole granules rather than the bytes requested.
        uint64_t alloc_bytes = 0, free_bytes = 0;
        /// The bytes requested by successful allocations. The difference from `alloc_bytes` is rounding
        /// waste. A free does not reduce it.
        uint64_t object_bytes = 0;
        uint64_t blocks_added = 0, blocks_removed = 0;
        /// Calls to `tryAllocate` for a size a block can hold that found no room in any block.
        uint64_t fit_misses = 0;
        /// Successful allocations that `tryAllocate` page-aligned under its page-size rule.
        uint64_t aligned_allocs = 0;
    };

    /// Sets the block size to `block_bytes` and the page size to `page_bytes`, chooses the granule
    /// from the block size, and forgets every block and statistic.
    ///
    /// The granule is the smallest power of two times 1 KiB that leaves a block at most
    /// `kMaxGranules` granules. Bytes after a block's last whole granule are never used; a block
    /// smaller than 1 KiB has no granules, so nothing can be allocated in it.
    void init(size_t block_bytes, size_t page_bytes);
    /// Forgets every block and zeroes the statistics, keeping the sizes set by `init`.
    void reset();

    /// Returns the granule size in bytes.
    size_t granuleBytes() const { return granule_; }
    /// Returns how many granules each block has.
    size_t granulesPerBlock() const { return per_block_; }
    /// Returns how many granules an object of `bytes` occupies.
    size_t granulesFor(size_t bytes) const { return (bytes + granule_ - 1) / granule_; }
    /// Returns the size of the largest object one block can hold, which is the block's whole
    /// granules and may be less than the block size.
    size_t maxObjectBytes() const { return per_block_ * granule_; }

    /// Registers block `id`, starting at `start`, in the raw pool if `raw` is set and in the other
    /// pool if not, with every granule free.
    ///
    /// `id` must not already be registered, which is asserted. `start` is kept until `removeBlock`
    /// and addresses returned for this block are offsets from it; the memory itself is never touched.
    /// `start` must not be null. Storage here grows with the largest id registered.
    void addBlock(uint32_t id, char* start, bool raw);
    /// Unregisters block `id`, which must hold no allocated granules; both are asserted. The id may be
    /// registered again afterwards.
    void removeBlock(uint32_t id);
    /// Returns whether block `id` is registered. Any id may be passed.
    bool hasBlock(uint32_t id) const { return id < meta_.size() && meta_[id].start != nullptr; }

    /// Allocates room for `bytes`, rounded up to whole granules, in a block of the raw pool if `raw`
    /// is set and of the other pool if not. Returns the address, and writes the block's id to
    /// `*block_out`.
    ///
    /// `block_out` must not be null. The granules stay reserved until `free` is called for them or
    /// `init`, `reset` or `removeBlock` forgets the block; the memory belongs to the caller.
    ///
    /// Returns a null pointer, and leaves `*block_out` unwritten, when `bytes` is zero or more than
    /// `maxObjectBytes()`, or when no block of the pool has a free run that fits. Only the last case
    /// counts as a fit miss, and only in that case does adding a block of the pool make a retry
    /// succeed.
    ///
    /// When the page size is larger than the granule and `bytes` is a multiple of the page size, the
    /// object is placed at an offset from the block's start that is a multiple of the page size. Such
    /// a request can miss in a block whose largest free run is long enough.
    ///
    /// The search visits the bins from the one holding runs of the needed length upwards, and takes
    /// the first block with a fitting run; within it, the shortest fitting run. Each block tried costs a
    /// scan of its bitmap, and a success one more.
    void* tryAllocate(size_t bytes, bool raw, uint32_t* block_out);

    /// Frees the object of `bytes` at `p` in block `id`, and returns whether the block now has no
    /// allocated granules. The block stays registered.
    ///
    /// `p` and `bytes` must be what the allocation was made with, or `bytes` must round to the same
    /// number of granules. With assertions enabled (`NDEBUG` unset), it asserts that `p` is a granule
    /// start and that every granule freed was allocated. The cost is a scan of the block's bitmap.
    bool free(uint32_t id, void* p, size_t bytes);

    /// Returns how many granules of block `id` are allocated.
    size_t usedGranules(uint32_t id) const { return meta_[id].used; }
    /// Returns whether the granule of block `id` that contains `p` is allocated. `p` may be any
    /// address inside the block's whole granules (the first `maxObjectBytes()` bytes), not only an
    /// object's start; any other address gives undefined behaviour.
    bool isAllocated(uint32_t id, const void* p) const {
        const BlockMeta& m = meta_[id];
        return test(m, static_cast<size_t>(static_cast<const char*>(p) - m.start) / granule_);
    }
    /// Returns the bytes of block `id` in allocated granules.
    size_t usedBytes(uint32_t id) const { return static_cast<size_t>(meta_[id].used) * granule_; }
    /// Returns whether block `id` is in the raw pool.
    bool isRaw(uint32_t id) const { return meta_[id].raw != 0; }
    /// Returns the length, in granules, of the longest run of free granules in block `id`.
    size_t largestFree(uint32_t id) const { return meta_[id].largest; }

    /// Returns the ids of the registered blocks that have no allocated granules, in increasing order.
    std::vector<uint32_t> emptyBlocks() const;
    /// Returns how many blocks are registered.
    size_t blockCount() const { return blocks_; }
    /// Returns the bytes in allocated granules across every registered block. The cost is linear in
    /// the largest id registered.
    size_t usedBytesTotal() const {
        size_t n = 0;
        for (const BlockMeta& m : meta_) if (m.start != nullptr) n += m.used;
        return n * granule_;
    }
    /// Returns the counts since the last `init` or `reset`; the reference is valid as long as this
    /// object and is updated in place by later calls.
    const Stats& stats() const { return stats_; }

    /// Returns whether the internal bookkeeping agrees with the bitmaps.
    ///
    /// It recounts each block's allocated granules and longest free run from its bitmap, checks that no
    /// bit is set past the block's granules, that each block is in the bin its longest run calls for,
    /// that the block count is right, and that the bin lists are well linked and hold every binned
    /// block. On the first disagreement it returns false and writes a description, a string literal, to
    /// `*why`; `why` must not be null. On success `*why` is not written.
    bool validate(const char** why) const;

private:
    // The state of one block id. `start` is null for an id that is not registered. `used` and
    // `largest` cache what `bits` shows, and `prev`/`next` link the block into the list of its bin.
    struct BlockMeta {
        char* start = nullptr;
        uint64_t bits[kWords] = {};   // Bit g set when granule g is allocated.
        uint32_t used = 0;            // Allocated granules.
        uint32_t largest = 0;         // Longest free run, in granules.
        uint32_t prev = kNone, next = kNone;
        uint8_t bin = 0xFF;           // 0xFF when in no bin: no free run, or not registered.
        uint8_t raw = 0;
    };
    /// The number of bins per pool. Bin 0 holds blocks whose longest free run is one granule, and bin
    /// b > 0 those whose run is in (2^(b-1), 2^b]. With at most `kMaxGranules` granules, bins 0 to 10
    /// are used.
    static constexpr size_t kBins = 12;

    /// Returns the bin for a longest free run of `largest` granules, which must be positive.
    static size_t binFor(uint32_t largest);
    /// Returns whether granule `g` of `m` is allocated.
    bool test(const BlockMeta& m, size_t g) const { return (m.bits[g >> 6] >> (g & 63)) & 1; }
    /// Marks the `n` granules of `m` from `g` allocated if `v` is set and free if not. Leaves the
    /// cached counts alone.
    void setRange(BlockMeta& m, size_t g, size_t n, bool v);
    /// Returns the longest run of free granules in `m`, found by a scan of its bitmap.
    uint32_t computeLargest(const BlockMeta& m) const;
    /// Returns the granule at which to place `need` granules in `m`, starting at a multiple of
    /// `align`, or `SIZE_MAX` if no free run can hold them.
    ///
    /// The choice is the shortest free run that can hold the aligned placement, the lowest such run
    /// on a tie, and the placement is at the run's first aligned granule. A run of exactly `need`
    /// granules ends the search.
    size_t findRun(const BlockMeta& m, size_t need, size_t align) const;
    /// Takes block `id` out of its bin's list, if it is in one.
    void unbin(uint32_t id);
    /// Moves block `id` to the front of the list of the bin its cached longest run calls for, or out
    /// of every bin if that run is zero.
    void rebin(uint32_t id);

    size_t block_bytes_ = 0;
    size_t page_bytes_ = 0;
    size_t granule_ = 1024;
    size_t per_block_ = 0;
    size_t blocks_ = 0;
    std::vector<BlockMeta> meta_;          // Indexed by block id.
    uint32_t heads_[2][kBins];             // The first block of each bin, by pool (1 = raw) and bin.
    Stats stats_;
};

} // namespace Elm

#endif // ECO_LARGE_OBJECT_SPACE_H
