#ifndef ECO_BLOCKTABLE_H
#define ECO_BLOCKTABLE_H

// Old-gen block metadata with STABLE IDENTITY (threaded-gc-01,
// plans/threaded-gc-01-stable-metadata.md P§3.1 / P§3.5 / P§3.6, HEAP_048,
// HEAP_050, HEAP_051).
//
// A block has two separate things:
//
//   * an IDENTITY, `BlockId`, assigned when the block is materialized and
//     stable until it is released. Its BlockInfo, BufferMetadata, large-mark
//     byte, mark-bit slot and live-bytes accumulator entry live at fixed
//     addresses (ReservedArray storage never moves);
//
//   * a POSITION in the iteration order. The order sequence reproduces the
//     former `std::vector<BlockInfo> blocks_` EXACTLY, including swap-remove
//     on release and order-preserving erase in compaction, because lazy-sweep
//     order, first-fit reuse and reclaim order depend on it.
//
// Positions are only loop variables and the two sweep/fixup cursors; every
// other stored block reference is a BlockId. BlockId is a struct with no
// implicit integer conversion so the two cannot be mixed silently.

#include <cstddef>
#include <cstdint>
#include <cstring>

#include "AllocatorCommon.hpp"
#include "ReservedArray.hpp"

namespace Elm {

// FREE_CELLS_EMPTY (0xFFFF) marks the end of a block's per-block Tier-M
// free-cell thread (see OldGenSpace.hpp's free-cell comment).
static constexpr uint16_t FREE_CELLS_EMPTY = 0xFFFF;

// ============================================================================
// Block Info Structure
// ============================================================================

// Tracks a page (or large block) currently materialized in the old gen. A
// page is materialized only once it has been pulled from `unassigned_blocks_`
// and either populated for a size class or wrapped as a single splittable
// cell.
struct BlockInfo {
    char* start;            // Start of the page/block (inclusive).
    char* end;              // End of the page/block (exclusive).
    char* end_of_objects;   // Sweep watermark: parse [start, end_of_objects).
    size_t size_class;      // Advisory: preferred class for this page (or
                            // NUM_SIZE_CLASSES if mixed/large).
    bool is_large;          // True for dedicated large-object (pinned) blocks.

    // Head (16-bit offset/8 from `start`) of this block's intrusive Tier-M
    // free-cell thread. Tier-S (class 1) cells are NOT in this thread.
    // FREE_CELLS_EMPTY (0xFFFF) when no Tier-M cells from this block are
    // currently linked. Stored as an offset so the thread is position-
    // independent.
    uint16_t free_cells_in_block = FREE_CELLS_EMPTY;

    // threaded-gc-02 (HEAP_054): bitmap-allocation ownership of a uniform
    // block — 0 None, 1 Queued (on OldGenSpace::partial_[size_class]),
    // 2 Current (owned by cursor_[size_class]). Always 0 with the flag off.
    uint8_t alloc_state = 0;

    size_t totalBytes() const { return static_cast<size_t>(end - start); }
};
static_assert(sizeof(BlockInfo) == 40, "BlockInfo must stay 40 bytes");

// ============================================================================
// Per-Block Metadata
// ============================================================================

// Tracks per-block statistics for compaction and reclaim decisions.
// Addressed by BlockId (threaded-gc-01); there is no stored back-reference.
struct BufferMetadata {
    size_t live_bytes;      // Live object bytes. Written ONLY by the owner
                            // (allocator side); marking attributes to a
                            // LiveBytesAccumulator merged in at
                            // finalizeMetaAfterMark (HEAP_051).
    size_t garbage_bytes;   // Garbage bytes (computed after mark / in sweep).
    bool fully_swept;       // True when this block has been fully swept.
};

// ============================================================================
// BlockId
// ============================================================================

struct BlockId {
    uint32_t v;
    static constexpr uint32_t kNone = UINT32_MAX;
    constexpr bool valid() const { return v != kNone; }
    friend constexpr bool operator==(BlockId a, BlockId b) { return a.v == b.v; }
    friend constexpr bool operator!=(BlockId a, BlockId b) { return a.v != b.v; }
};
inline constexpr BlockId NO_BLOCK_ID{BlockId::kNone};

// ============================================================================
// BlockTable
// ============================================================================

class BlockTable {
public:
    BlockTable() = default;
    BlockTable(const BlockTable&) = delete;
    BlockTable& operator=(const BlockTable&) = delete;

    // Reserves VA for `max_blocks` ids in every array; commits nothing.
    // Returns false if any reservation fails.
    bool reserve(size_t max_blocks) {
        capacity_ = 0;
        size_ = 0;
        free_count_ = 0;
        high_water_ = 0;
        if (!info_.reserve(max_blocks) || !meta_.reserve(max_blocks) ||
            !lmark_.reserve(max_blocks) || !live_.reserve(max_blocks) ||
            !pos_of_.reserve(max_blocks) || !order_.reserve(max_blocks) ||
            !free_.reserve(max_blocks)) {
            releaseStorage();
            return false;
        }
        capacity_ = max_blocks;
        return true;
    }

    void releaseStorage() {
        info_.release(); meta_.release(); lmark_.release(); live_.release();
        pos_of_.release(); order_.release(); free_.release();
        capacity_ = 0; size_ = 0; free_count_ = 0; high_water_ = 0;
    }

    // Live block count == length of the iteration order.
    size_t size() const { return size_; }
    size_t capacity() const { return capacity_; }
    // Number of ids ever handed out since the last clear(); every id below
    // it is either live or on the free stack.
    uint32_t highWater() const { return high_water_; }
    size_t freeCount() const { return free_count_; }
    BlockId freeIdAt(size_t k) const { return free_[k]; }

    BlockId idAt(size_t pos) const { return order_[pos]; }
    size_t posOf(BlockId id) const { return pos_of_[id.v]; }
    bool isLive(BlockId id) const {
        return id.v < high_water_ && live_[id.v] != 0;
    }

    BlockInfo& info(BlockId id) { return info_[id.v]; }
    const BlockInfo& info(BlockId id) const { return info_[id.v]; }
    BufferMetadata& meta(BlockId id) { return meta_[id.v]; }
    const BufferMetadata& meta(BlockId id) const { return meta_[id.v]; }
    uint8_t& largeMark(BlockId id) { return lmark_[id.v]; }
    uint8_t largeMark(BlockId id) const { return lmark_[id.v]; }

    // Materializes a block: takes the most recently freed id (LIFO) or the
    // next never-used id, and APPENDS it to the order (== vector push_back).
    // Aborts if the table is full: by construction (capacity = reservation /
    // alloc_buffer_size + 1, every block >= alloc_buffer_size) that is a bug,
    // not an out-of-memory condition.
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
        }
        order_.ensureCommitted(size_ + 1);
        info_[id.v] = bi;
        meta_[id.v] = m;
        lmark_[id.v] = 0;
        live_[id.v] = 1;
        pos_of_[id.v] = static_cast<uint32_t>(size_);
        order_[size_] = id;
        ++size_;
        return id;
    }

    // Releases `id` with vector swap-remove semantics on the order: the last
    // position moves into the released one. The id goes on the free stack.
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

    // Releases `id` with vector::erase semantics: later positions shift left
    // by one, preserving relative order (compaction only).
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

    // Empties the table; the next id handed out is 0 again. Storage stays
    // reserved and committed.
    void clear() {
        for (uint32_t i = 0; i < high_water_; ++i) live_[i] = 0;
        size_ = 0;
        free_count_ = 0;
        high_water_ = 0;
    }

    // Storage base addresses, for the stability validator (V7).
    const void* storageBase(int k) const {
        switch (k) {
            case 0: return info_.data();
            case 1: return meta_.data();
            case 2: return lmark_.data();
            case 3: return live_.data();
            case 4: return pos_of_.data();
            case 5: return order_.data();
            default: return free_.data();
        }
    }
    static constexpr int kStorageArrays = 7;

private:
    void retireId(BlockId id) {
        live_[id.v] = 0;
        free_[free_count_++] = id;
    }

    ReservedArray<BlockInfo>      info_;
    ReservedArray<BufferMetadata> meta_;
    ReservedArray<uint8_t>        lmark_;   // former large_block_mark_
    ReservedArray<uint8_t>        live_;
    ReservedArray<uint32_t>       pos_of_;
    ReservedArray<BlockId>        order_;
    ReservedArray<BlockId>        free_;    // LIFO stack of released ids
    size_t   capacity_   = 0;
    size_t   size_       = 0;
    size_t   free_count_ = 0;
    uint32_t high_water_ = 0;
};

// ============================================================================
// MarkBitArena (HEAP_050)
// ============================================================================
//
// One fixed-stride mark-bitmap slot per BlockId: block `id`'s bits live at
// `base + id * stride` (1 bit per 8-byte heap slot). The slot address never
// moves, so there is no re-pack and no per-block offset table; the flat
// per-id address is also what phase 5b's (parallel mark) atomic `fetch_or` needs.
//
// `len(id)` is the block's VALID bitmap length: bitmapBytesForBlock for a
// regular block, 0 for is_large and free ids. The `byte_index >= len` guard in
// the bit accessors is load-bearing (W12b) and is preserved exactly.
//
// Zeroing discipline:
//   * assign()  — at materialize: zero the slot (the old append wrote zeros).
//   * drop()    — flip to is_large: zero, len = 0.
//   * retire()  — release: len = 0; bytes and `dirty` left alone.
//   * clearForMark() — at startMark: zero every LIVE slot (the load-bearing
//     bulk clear, W11b), then discard runs of free-and-dirty slots so their
//     RSS goes back to the OS (what the old re-pack + shrink_to_fit did;
//     W12's +172 MB holes). Correctness never depends on `dirty`.
class MarkBitArena {
public:
    MarkBitArena() = default;
    MarkBitArena(const MarkBitArena&) = delete;
    MarkBitArena& operator=(const MarkBitArena&) = delete;

    bool reserve(size_t max_blocks, size_t stride) {
        stride_ = stride;
        // Huge-page granule: the arena is large and randomly accessed by the
        // marker; 4 KiB pages cost +5.5 % mark time in TLB misses (measured).
        if (!bytes_.reserve(max_blocks * stride,
                            ReservedArray<uint8_t>::kHugePageBytes) ||
            !len_.reserve(max_blocks) ||
            !dirty_.reserve(max_blocks)) {
            release();
            return false;
        }
        return true;
    }
    void release() {
        bytes_.release(); len_.release(); dirty_.release(); stride_ = 0;
    }

    size_t stride() const { return stride_; }
    uint8_t* slot(BlockId id) {
        return bytes_.data() + static_cast<size_t>(id.v) * stride_;
    }
    const uint8_t* slot(BlockId id) const {
        return bytes_.data() + static_cast<size_t>(id.v) * stride_;
    }
    uint32_t len(BlockId id) const { return len_[id.v]; }

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
    void clearBlock(BlockId id) { std::memset(slot(id), 0, len_[id.v]); }
    void drop(BlockId id) { clearBlock(id); len_[id.v] = 0; }
    void retire(BlockId id) { len_[id.v] = 0; }

    // startMark: zero every live slot and its large-mark byte (in order),
    // then return the memory of free-and-dirty slots.
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

    // Validator V4 support: true iff live slot `id`'s valid bytes are zero.
    bool slotIsZero(BlockId id) const {
        const uint8_t* p = slot(id);
        for (uint32_t k = 0; k < len_[id.v]; ++k) if (p[k] != 0) return false;
        return true;
    }
    const void* storageBase() const { return bytes_.data(); }
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
// Marker-side live-bytes attribution, indexed by BlockId. Marking adds ONLY
// here, never to BufferMetadata::live_bytes (which only the owning heap's
// allocator side writes); `mergeInto` folds the accumulator into the table at
// the mark->sweep sync point (the first statement of finalizeMetaAfterMark)
// and leaves it all-zero. Phase 1 has exactly one (the mutator marks); phase 5b
// gives each marker thread its own and merges them all at the same statement.
class LiveBytesAccumulator {
public:
    LiveBytesAccumulator() = default;
    LiveBytesAccumulator(const LiveBytesAccumulator&) = delete;
    LiveBytesAccumulator& operator=(const LiveBytesAccumulator&) = delete;

    bool reserve(size_t max_blocks) { return bytes_.reserve(max_blocks); }
    void release() { bytes_.release(); }

    // Called when `id` is materialized, so add() stays a plain `+=`.
    void commitThrough(BlockId id) {
        bytes_.ensureCommitted(static_cast<size_t>(id.v) + 1);
    }
    void add(BlockId id, uint64_t n) { bytes_[id.v] += n; }
    uint64_t peek(BlockId id) const { return bytes_[id.v]; }
    uint64_t take(BlockId id) {
        const uint64_t v = bytes_[id.v];
        bytes_[id.v] = 0;
        return v;
    }
    // Sum over every live id (threaded-gc-05a: the cycle's traced live).
    uint64_t sum(const BlockTable& t) const {
        uint64_t s = 0;
        for (size_t pos = 0; pos < t.size(); ++pos) s += bytes_[t.idAt(pos).v];
        return s;
    }
    // meta(id).live_bytes += take(id) for every live id, in order.
    void mergeInto(BlockTable& t) {
        for (size_t pos = 0; pos < t.size(); ++pos) {
            const BlockId id = t.idAt(pos);
            t.meta(id).live_bytes += take(id);
        }
    }
    const void* storageBase() const { return bytes_.data(); }

private:
    ReservedArray<uint64_t> bytes_;
};

}  // namespace Elm

#endif  // ECO_BLOCKTABLE_H
