#ifndef ECO_BLOCKTABLE_H
#define ECO_BLOCKTABLE_H

// The old generation's per-block metadata, kept at addresses that do not move while GC threads hold
// references into it.
//
// The old generation is made of blocks: pages carved into cells, dedicated blocks that each hold one
// large object, and LOS blocks that hold many large bodies for `LargeObjectSpace`. A block is
// *materialized* when it is taken into use and given metadata, and *released* when it is given back.
// This file holds that metadata: the description of a block (`BlockInfo`), its statistics
// (`BufferMetadata`), its mark bitmap (`MarkBitArena`) and the live bytes a marker attributes to it
// (`LiveBytesAccumulator`).
//
// Everything here rests on one distinction. A block has an *identity* and a *position*, and they are
// separate things.
//
//   * Its identity is a `BlockId`, assigned at materialization and unchanged until release. The arrays
//     that hold per-block data (metadata, mark slots, live counts) are indexed by `BlockId`, and every
//     array is a `ReservedArray`, whose storage never moves once reserved, so a reference to a block's
//     entry stays valid while other blocks are added and released.
//
//   * Its position is its index in the *iteration order*, the sequence that loops over the live blocks.
//     Positions change: releasing a block with `swapRemove` moves the last block into the freed position,
//     and `eraseOrdered` shifts every later block down by one. The sweep order, the order in which
//     partially free blocks are reused, and the reclaim order all follow this sequence, so the two kinds
//     of release are not interchangeable.
//
// A position is therefore fit only for a loop variable or a cursor that is patched when blocks move. A
// block reference that is kept should be a `BlockId`, which has no implicit conversion to or from an
// integer so that the two cannot be mixed by accident.
//
// Ids are reused. A released id goes on a stack, and the next materialization takes the most recently
// released one. `BlockTable::generation` tells two incarnations of the same id apart.
//
// The classes here take no locks and use no atomics. Any atomic access to mark bits is made by the
// caller, through the slot addresses `MarkBitArena` hands out.

#include <cstddef>
#include <cstdint>
#include <cstring>

#include "AllocatorCommon.hpp"
#include "ReservedArray.hpp"

namespace Elm {

// The value of `BlockInfo::free_cells_in_block` that means the block has no cells on its free-cell
// thread.
static constexpr uint16_t FREE_CELLS_EMPTY = 0xFFFF;

// ============================================================================
// Block Info Structure
// ============================================================================

// The description of one materialized old-generation block: its address range, how far it holds
// objects, and how the allocator is currently using it.
struct BlockInfo {
    char* start;            // Start of the page/block (inclusive).
    char* end;              // End of the page/block (exclusive).
    char* end_of_objects;   // Sweep watermark: parse [start, end_of_objects).
    size_t size_class;      // Advisory: preferred class for this page (or
                            // NUM_SIZE_CLASSES if mixed/large).
    bool is_large;          // True for dedicated large-object (pinned) blocks.

    // The head of this block's thread of free cells, as an offset from `start` in units of 8 bytes, or
    // `FREE_CELLS_EMPTY` when the thread is empty. Only Tier-M cells are threaded here; Tier-S (class 1)
    // cells are not.
    uint16_t free_cells_in_block = FREE_CELLS_EMPTY;

    // Which bitmap allocator, if any, owns this block. The values are `OldGenSpace::kAllocNone`,
    // `kAllocQueued`, `kAllocCurrent` and `kAllocTenure`, whose meanings `OldGenSpace` states.
    uint8_t alloc_state = 0;

    // Large-object-space flags, a combination of `kLosBlock` and `kLosRaw`. Markers read them.
    uint8_t los = 0;

    // Returns the size of the block's address range in bytes.
    size_t totalBytes() const { return static_cast<size_t>(end - start); }
};
// The `BlockInfo::los` flag for a block whose space `LargeObjectSpace` manages. Such a block is not
// on a free list and is not swept, flipped, demoted or evacuated.
constexpr uint8_t kLosBlock = 1;
// The `BlockInfo::los` flag for a block that holds header-less large bodies. It is set only on
// raw blocks, LOS or `is_large`.
constexpr uint8_t kLosRaw = 2;
static_assert(sizeof(BlockInfo) == 40, "BlockInfo must stay 40 bytes");

// ============================================================================
// Per-Block Metadata
// ============================================================================

// The live and garbage byte counts of one block, and whether it has been swept, used to decide which
// blocks to compact and reclaim.
struct BufferMetadata {
    // Live object bytes. Markers do not add to this field directly: they add to a
    // `LiveBytesAccumulator`, which `LiveBytesAccumulator::mergeInto` folds in here.
    uint64_t live_bytes;
    size_t garbage_bytes;   // Garbage bytes (computed after mark / in sweep).
    bool fully_swept;       // True when this block has been fully swept.
};

// ============================================================================
// BlockId
// ============================================================================

// The identity of an old-generation block, valid from its materialization until its release.
//
// The id is the index into the arrays in this file that hold per-block data. It does not convert to or from an
// integer implicitly, so it cannot be confused with a position in the iteration order. An id is reused
// after release; `BlockTable::generation` distinguishes its incarnations. Two ids are equal when they
// hold the same index, whatever the incarnation.
struct BlockId {
    uint32_t v;
    // The index that means no block.
    static constexpr uint32_t kNone = UINT32_MAX;
    // Returns whether this id is anything other than `kNone`. It does not say whether the block is live.
    constexpr bool valid() const { return v != kNone; }
    // Returns whether `a` and `b` hold the same index.
    friend constexpr bool operator==(BlockId a, BlockId b) { return a.v == b.v; }
    // Returns whether `a` and `b` hold different indices.
    friend constexpr bool operator!=(BlockId a, BlockId b) { return a.v != b.v; }
};
// The id that refers to no block.
inline constexpr BlockId NO_BLOCK_ID{BlockId::kNone};

// ============================================================================
// BlockTable
// ============================================================================

// The set of materialized old-generation blocks, each with its metadata at a fixed address and its place
// in the iteration order.
//
// A table is made with no storage and is usable after `reserve` succeeds. It cannot be copied. A
// reference returned by `info`, `meta` or `largeMark` stays at the same address until
// `releaseStorage`; what it holds belongs to whichever block has that id at the time. The accessors
// do not check that an id is live or below `highWater()`; passing one that is not reads stale or
// uncommitted storage.
class BlockTable {
public:
    BlockTable() = default;
    BlockTable(const BlockTable&) = delete;
    BlockTable& operator=(const BlockTable&) = delete;

    // Reserves VA for `max_blocks` ids in every array; commits nothing.
    // Returns false if any reservation fails, and then holds no storage.
    bool reserve(size_t max_blocks) {
        capacity_ = 0;
        size_ = 0;
        free_count_ = 0;
        high_water_ = 0;
        if (!info_.reserve(max_blocks) || !meta_.reserve(max_blocks) ||
            !lmark_.reserve(max_blocks) || !live_.reserve(max_blocks) ||
            !pos_of_.reserve(max_blocks) || !order_.reserve(max_blocks) ||
            !free_.reserve(max_blocks) || !gen_.reserve(max_blocks)) {
            releaseStorage();
            return false;
        }
        capacity_ = max_blocks;
        return true;
    }

    // Gives back every array's reservation and leaves the table empty with no capacity.
    void releaseStorage() {
        info_.release(); meta_.release(); lmark_.release(); live_.release();
        pos_of_.release(); order_.release(); free_.release(); gen_.release();
        capacity_ = 0; size_ = 0; free_count_ = 0; high_water_ = 0;
    }

    // Returns the number of live blocks, which is the length of the iteration order.
    size_t size() const { return size_; }
    // Returns the number of ids the table was reserved for.
    size_t capacity() const { return capacity_; }
    // Returns the number of ids handed out since the last `clear()`. Every id below it is either live or
    // on the free stack.
    uint32_t highWater() const { return high_water_; }
    // Returns the number of released ids waiting to be reused.
    size_t freeCount() const { return free_count_; }
    // Returns the `k`th released id on the free stack, counting from the bottom. `k` must be less than
    // `freeCount()`.
    BlockId freeIdAt(size_t k) const { return free_[k]; }

    // Returns the id of the block at position `pos`, which must be less than `size()`.
    BlockId idAt(size_t pos) const { return order_[pos]; }
    // Returns the position of block `id`, which must be live.
    size_t posOf(BlockId id) const { return pos_of_[id.v]; }
    // Returns whether `id` names a block that is materialized now.
    bool isLive(BlockId id) const {
        return id.v < high_water_ && live_[id.v] != 0;
    }
    // Returns the incarnation number of `id`. It goes up by one each time `add` hands the id out and is
    // never reset, not even by `clear()`, so the same id reissued for a block at the same address still
    // has a different generation. The first incarnation is 1.
    uint32_t generation(BlockId id) const { return gen_[id.v]; }

    // Returns the description of block `id`.
    BlockInfo& info(BlockId id) { return info_[id.v]; }
    // Returns the description of block `id`.
    const BlockInfo& info(BlockId id) const { return info_[id.v]; }
    // Returns the statistics of block `id`.
    BufferMetadata& meta(BlockId id) { return meta_[id.v]; }
    // Returns the statistics of block `id`.
    const BufferMetadata& meta(BlockId id) const { return meta_[id.v]; }
    // Returns the single mark byte of block `id`, used in place of a mark bitmap for an `is_large` block.
    uint8_t& largeMark(BlockId id) { return lmark_[id.v]; }
    // Returns the single mark byte of block `id`.
    uint8_t largeMark(BlockId id) const { return lmark_[id.v]; }

    // Materializes a block described by `bi` and `m`, and returns its id. The id is the most recently
    // released one if there is any, and otherwise the next never-used id. The block is appended to the
    // end of the iteration order, its large-mark byte is cleared and its generation goes up by one.
    //
    // Aborts with a message if every id is in use. The capacity is meant to exceed the number of blocks
    // the reservation can hold, so that is a broken invariant rather than running out of memory.
    BlockId add(const BlockInfo& bi, const BufferMetadata& m) {
        BlockId id;
        if (free_count_ > 0) {
            id = free_[--free_count_];
        } else {
            if (high_water_ >= capacity_) {
                std::fprintf(stderr,
                    "[oldgen] BlockTable full (capacity %zu ids): more live "
                    "blocks than old-gen reservation / alloc_buffer_size + 1 "
                    "allows — a block-size invariant was broken\n",
                    capacity_);
                std::abort();
            }
            id = BlockId{high_water_++};
            const size_t n = static_cast<size_t>(high_water_);
            info_.ensureCommitted(n); meta_.ensureCommitted(n);
            lmark_.ensureCommitted(n); live_.ensureCommitted(n);
            pos_of_.ensureCommitted(n); free_.ensureCommitted(n);
            gen_.ensureCommitted(n);
        }
        order_.ensureCommitted(size_ + 1);
        info_[id.v] = bi;
        meta_[id.v] = m;
        lmark_[id.v] = 0;
        live_[id.v] = 1;
        ++gen_[id.v];   // Fresh commits read as 0, so an id's first generation is 1.
        pos_of_[id.v] = static_cast<uint32_t>(size_);
        order_[size_] = id;
        ++size_;
        return id;
    }

    // Releases live block `id` and puts its id on the free stack. The block that was last in the
    // iteration order takes the released position; no other block moves.
    void swapRemove(BlockId id) {
        const size_t pos = pos_of_[id.v];
        const size_t last = size_ - 1;
        if (pos != last) {
            const BlockId moved = order_[last];
            order_[pos] = moved;
            pos_of_[moved.v] = static_cast<uint32_t>(pos);
        }
        --size_;
        retireId(id);
    }

    // Releases live block `id` and puts its id on the free stack. Every later block moves down one
    // position, so the relative order of the rest is kept. This costs time linear in the number of later
    // blocks.
    void eraseOrdered(BlockId id) {
        const size_t pos = pos_of_[id.v];
        for (size_t i = pos; i + 1 < size_; ++i) {
            const BlockId b = order_[i + 1];
            order_[i] = b;
            pos_of_[b.v] = static_cast<uint32_t>(i);
        }
        --size_;
        retireId(id);
    }

    // Empties the table, so that the next id handed out is 0 again. Storage stays reserved and committed,
    // and generations are kept.
    void clear() {
        for (uint32_t i = 0; i < high_water_; ++i) live_[i] = 0;
        size_ = 0;
        free_count_ = 0;
        high_water_ = 0;
    }

    // Returns the base address of storage array `k`, for a check that the arrays never move. `k` runs
    // from 0 to `kStorageArrays - 1`; any other `k` returns the last array.
    const void* storageBase(int k) const {
        switch (k) {
            case 0: return info_.data();
            case 1: return meta_.data();
            case 2: return lmark_.data();
            case 3: return live_.data();
            case 4: return pos_of_.data();
            case 5: return order_.data();
            case 6: return free_.data();
            default: return gen_.data();
        }
    }
    // The number of storage arrays `storageBase` reports.
    static constexpr int kStorageArrays = 8;

private:
    // Marks `id` not live and pushes it on the free stack.
    void retireId(BlockId id) {
        live_[id.v] = 0;
        free_[free_count_++] = id;
    }

    ReservedArray<BlockInfo>      info_;
    ReservedArray<BufferMetadata> meta_;
    ReservedArray<uint8_t>        lmark_;   // Mark byte of an is_large block.
    ReservedArray<uint8_t>        live_;    // 1 while the id is materialized.
    ReservedArray<uint32_t>       pos_of_;  // Position; stale for an id that is not live.
    ReservedArray<BlockId>        order_;
    ReservedArray<BlockId>        free_;    // LIFO stack of released ids
    ReservedArray<uint32_t>       gen_;     // Per-id generation, never reset.
    size_t   capacity_   = 0;
    size_t   size_       = 0;
    size_t   free_count_ = 0;
    uint32_t high_water_ = 0;
};

// ============================================================================
// MarkBitArena (HEAP_050)
// ============================================================================
//
// The mark bitmaps of the old generation's blocks, one fixed-size slot per `BlockId`.
//
// Block `id`'s bitmap starts at `slot(id)`, `id * stride()` bytes into the arena, with one bit for
// each 8-byte heap slot. A slot's address never moves, so a marker can set bits in it with an atomic
// operation on the address while other blocks are added and released.
//
// Only a prefix of each slot is in use. Its *valid length*, `len(id)`, is the bitmap size the caller
// gave `assign` for a regular block, and 0 for a block dropped to `is_large` and for a released id. Bit
// accessors outside this class must treat a byte at or past the valid length as absent.
//
// When the arena zeroes a slot:
//   * `assign`, at materialization, zeroes the valid length.
//   * `drop`, when a block becomes `is_large`, zeroes it and sets the valid length to 0.
//   * `retire`, at release, sets the valid length to 0 and leaves the bytes alone.
//   * `clearForMark`, at the start of a mark, zeroes every live block's valid bytes.
//
// A slot is *dirty* once `assign` has given it a non-zero valid length. `clearForMark` gives the memory
// of dirty slots of released ids back to the operating system and marks them clean. Dirtiness only
// decides which memory is returned; nothing reads a bit through it.
//
// An arena is made with no storage and is usable after `reserve` succeeds. It cannot be copied.
class MarkBitArena {
public:
    MarkBitArena() = default;
    MarkBitArena(const MarkBitArena&) = delete;
    MarkBitArena& operator=(const MarkBitArena&) = delete;

    // Reserves address space for `max_blocks` slots of `stride` bytes each, and returns whether every
    // reservation succeeded. On failure the arena holds no storage.
    bool reserve(size_t max_blocks, size_t stride) {
        stride_ = stride;
        // Huge-page granule: the arena is large and the marker reaches into it at random, so small pages
        // would cost TLB misses.
        if (!bytes_.reserve(max_blocks * stride,
                            ReservedArray<uint8_t>::kHugePageBytes) ||
            !len_.reserve(max_blocks) ||
            !dirty_.reserve(max_blocks)) {
            release();
            return false;
        }
        return true;
    }
    // Gives back the arena's reservations.
    void release() {
        bytes_.release(); len_.release(); dirty_.release(); stride_ = 0;
    }

    // Returns the size of each slot in bytes.
    size_t stride() const { return stride_; }
    // Returns the start of block `id`'s slot. The address is fixed until `release`.
    uint8_t* slot(BlockId id) {
        return bytes_.data() + static_cast<size_t>(id.v) * stride_;
    }
    // Returns the start of block `id`'s slot. The address is fixed until `release`.
    const uint8_t* slot(BlockId id) const {
        return bytes_.data() + static_cast<size_t>(id.v) * stride_;
    }
    // Returns the valid length of block `id`'s bitmap in bytes.
    uint32_t len(BlockId id) const { return len_[id.v]; }

    // Gives the newly materialized block `id` a zeroed bitmap of `len` bytes, committing its slot first.
    // `len` must not exceed `stride()`, which is checked by `assert`.
    void assign(BlockId id, uint32_t len) {
        assert(len <= stride_ && "MarkBitArena: bitmap larger than stride");
        const size_t n = static_cast<size_t>(id.v) + 1;
        bytes_.ensureCommitted(n * stride_);
        len_.ensureCommitted(n);
        dirty_.ensureCommitted(n);
        std::memset(slot(id), 0, len);
        len_[id.v] = len;
        if (len > 0) dirty_[id.v] = 1;
    }
    // Zeroes the valid bytes of block `id`'s bitmap.
    void clearBlock(BlockId id) { std::memset(slot(id), 0, len_[id.v]); }
    // Zeroes block `id`'s bitmap and sets its valid length to 0, for a block that becomes `is_large`.
    void drop(BlockId id) { clearBlock(id); len_[id.v] = 0; }
    // Sets block `id`'s valid length to 0 at release, leaving its bytes as they are.
    void retire(BlockId id) { len_[id.v] = 0; }

    // Prepares for a mark: zeroes the valid bytes of every live block in `t`, and its large-mark byte,
    // in iteration order. Then gives the memory of each run of dirty slots of released ids back to the
    // operating system and marks those slots clean.
    void clearForMark(BlockTable& t) {
        for (size_t pos = 0; pos < t.size(); ++pos) {
            const BlockId id = t.idAt(pos);
            std::memset(slot(id), 0, len_[id.v]);
            t.largeMark(id) = 0;
        }
        const uint32_t hw = t.highWater();
        uint32_t i = 0;
        while (i < hw) {
            if (t.isLive(BlockId{i}) || dirty_.committed() <= i ||
                dirty_[i] == 0) {
                ++i;
                continue;
            }
            uint32_t j = i;
            while (j < hw && !t.isLive(BlockId{j}) && j < dirty_.committed() &&
                   dirty_[j] != 0) {
                dirty_[j] = 0;
                ++j;
            }
            bytes_.discard(static_cast<size_t>(i) * stride_,
                           static_cast<size_t>(j - i) * stride_);
            i = j;
        }
    }

    // Returns whether every valid byte of block `id`'s bitmap is zero.
    bool slotIsZero(BlockId id) const {
        const uint8_t* p = slot(id);
        for (uint32_t k = 0; k < len_[id.v]; ++k) if (p[k] != 0) return false;
        return true;
    }
    // Returns the base address of the slot storage, for a check that it never moves.
    const void* storageBase() const { return bytes_.data(); }
    // Returns how many bytes of slot storage are committed.
    size_t committedBytes() const { return bytes_.committedBytes(); }

private:
    ReservedArray<uint8_t>  bytes_;
    ReservedArray<uint32_t> len_;
    ReservedArray<uint8_t>  dirty_;
    size_t stride_ = 0;
};

// ============================================================================
// LiveBytesAccumulator (HEAP_051)
// ============================================================================
//
// One marker's count of the live bytes it has found in each block, indexed by `BlockId`.
//
// Marking adds here and never to `BufferMetadata::live_bytes`, so a marker writes only memory of its
// own. `mergeInto` later adds the counts into the table's metadata. The class has no synchronisation:
// each accumulator must be written by one thread at a time, and merged only when that thread has
// stopped adding.
//
// An accumulator is made with no storage and is usable after `reserve` succeeds. It cannot be copied.
class LiveBytesAccumulator {
public:
    LiveBytesAccumulator() = default;
    LiveBytesAccumulator(const LiveBytesAccumulator&) = delete;
    LiveBytesAccumulator& operator=(const LiveBytesAccumulator&) = delete;

    // Reserves address space for `max_blocks` counts, and returns whether it succeeded.
    bool reserve(size_t max_blocks) { return bytes_.reserve(max_blocks); }
    // Gives back the reservation.
    void release() { bytes_.release(); }

    // Commits the counts up to and including `id`. It must be called when `id` is materialized, so that
    // `add` needs no check.
    void commitThrough(BlockId id) {
        bytes_.ensureCommitted(static_cast<size_t>(id.v) + 1);
    }
    // Adds `n` live bytes to block `id`'s count.
    void add(BlockId id, uint64_t n) { bytes_[id.v] += n; }
    // Returns block `id`'s count without changing it.
    uint64_t peek(BlockId id) const { return bytes_[id.v]; }
    // Returns block `id`'s count and sets it to zero.
    uint64_t take(BlockId id) {
        const uint64_t v = bytes_[id.v];
        bytes_[id.v] = 0;
        return v;
    }
    // Returns the sum of the counts of every live block in `t`.
    uint64_t sum(const BlockTable& t) const {
        uint64_t s = 0;
        for (size_t pos = 0; pos < t.size(); ++pos) s += bytes_[t.idAt(pos).v];
        return s;
    }
    // Adds each live block's count to its `live_bytes` in `t`, in iteration order, and zeroes the count.
    // The counts of ids that are not live are left as they are.
    void mergeInto(BlockTable& t) {
        for (size_t pos = 0; pos < t.size(); ++pos) {
            const BlockId id = t.idAt(pos);
            t.meta(id).live_bytes += take(id);
        }
    }
    // Returns the base address of the counts, for a check that they never move.
    const void* storageBase() const { return bytes_.data(); }

private:
    ReservedArray<uint64_t> bytes_;
};

}  // namespace Elm

#endif  // ECO_BLOCKTABLE_H
