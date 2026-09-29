// threaded-gc-07 (plans/threaded-gc-07-concurrent-tenuring.md P§3.12,
// HEAP_070): the promotion grant. A tenure job allocates its copies from
// uniform blocks in state kAllocTenure, chosen in the hand-over pause and
// owned by the job until the merge. The collector touches only the cursors
// cached here (block start, bitmap slot, cell size and count): never blocks_,
// the page index, partial_, the free lists or any stats the mutator updates.

#include "OldGenSpace.hpp"

#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <cstring>

#include "Allocator.hpp"
#include "BitmapScan.hpp"

namespace Elm {

namespace {

// OldGenSpace.cpp's padCellSlack (a later demotion walks the cell as mixed).
inline void padSlack(void* obj, size_t requested_size, size_t cell_size) {
    requested_size = (requested_size + 7) & ~static_cast<size_t>(7);
    if (cell_size <= requested_size) return;
    const size_t slack = cell_size - requested_size;
    if (slack < sizeof(Header)) return;
    Header* trailing = reinterpret_cast<Header*>(static_cast<char*>(obj) + requested_size);
    std::memset(trailing, 0, sizeof(Header));
    trailing->tag = Tag_Free;
    trailing->size = static_cast<u32>(slack);
    trailing->color = static_cast<u32>(Color::White);
}

[[noreturn]] void grantFatal(const char* what, size_t cls, uint64_t a, uint64_t b) {
    std::fprintf(stderr, "[gc] FATAL: tenure grant: %s (class %zu, %llu / %llu)\n", what, cls,
                 (unsigned long long)a, (unsigned long long)b);
    std::fflush(stderr);
    std::abort();
}

}  // namespace

// TLA-REGION(OGT.grantTenure) begin
bool OldGenSpace::grantTenure(const uint32_t count[NUM_SIZE_CLASSES], TenureGrant& g,
                              uint32_t slack_participants) {
    assert(config_->old_gen_bitmap_alloc && "the tenure grant needs bitmap allocation");
    if (g.active) grantFatal("a grant was built over a live one", 0, 0, 0);
#if ECO_HEAP_VALIDATE
    DecisionScope decision(*this);   // IM16: nothing here reads collector progress
#endif
    for (size_t c = 0; c < NUM_SIZE_CLASSES; ++c) {
        g.blocks[c].clear();
        g.next[c] = 0;
    }
    g.allocated_bytes = g.old_alloc_total = 0;
    std::memset(g.size_hist, 0, sizeof(g.size_hist));
    g.size_16_24 = 0;
    g.granted_cells = g.used_cells = g.block_count = g.virgin_blocks = 0;
#if ECO_HEAP_VALIDATE
    g.cycle_active = marking_active || gc_phase_ != GCPhase::Idle || cycleActive();
    g.cycle_alloc_log.clear();
#endif
    auto take = [&](size_t cls, BlockId id) -> uint32_t {
        BlockInfo& b = blocks_.info(id);
        b.alloc_state = kAllocTenure;
        TenureCursor tc;
        tc.block = id;
        tc.base = b.start;
        tc.bits = mark_.slot(id);
        tc.num_cells = cellsIn(b);
        tc.cell_bytes = static_cast<uint32_t>(classToSize(cls));
        tc.stride_bits = tc.cell_bytes / 8;
        tc.next_cell = 0;
        const uint32_t used = static_cast<uint32_t>(
            bitscan::popcountCellStarts(tc.bits, tc.stride_bits, tc.num_cells));
        g.blocks[cls].push_back(tc);
        ++g.block_count;
        return tc.num_cells - used;
    };
    for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) g.claim[cls].w.store(0, std::memory_order_relaxed);
    for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
        if (count[cls] == 0) continue;
        if (cls >= num_size_classes_) grantFatal("a survivor size class the old gen does not have", cls, count[cls], 0);
        const uint64_t need = static_cast<uint64_t>(count[cls]) +
            static_cast<uint64_t>(slack_participants) *
                tenureChunkCells(static_cast<uint32_t>(classToSize(cls) / 8));
        uint64_t free_cells = 0;
        // (1) Reuse first (W6): the FRONT of partial_[cls], as refillCursor pops it.
        std::vector<BlockId>& q = partial_[cls];
        size_t& h = partial_head_[cls];
        while (free_cells < need && h < q.size()) {
            const BlockId id = q[h++];
            if (!blocks_.isLive(id)) continue;
            BlockInfo& b = blocks_.info(id);
            if (b.alloc_state != kAllocQueued || b.is_large || b.size_class != cls) continue;
            // A handoff's classifyBlocksAfterMark queues any uniform block with
            // free cells that is not already Queued -- including the mutator's
            // own Current cursor block (its state is overwritten). Granting it
            // would let the collector and the mutator allocate in one block.
            if (cursor_[cls].block == id) continue;
#if ECO_HEAP_VALIDATE
            // IM13 / TV5: mid-cycle, partial_ holds only post-t0 blocks.
            if (isT0Block(id)) {
                std::fprintf(stderr, "[heap-validate] TV5: the tenure grant took t0 block %u "
                             "during a mark cycle\n", id.v);
                std::fflush(stderr);
                std::abort();
            }
#endif
            free_cells += take(cls, id);
        }
        if (h == q.size()) { q.clear(); h = 0; }
        // Negative control (TV5): a t0 block granted mid-cycle.
        if (__builtin_expect(test_grant_t0_block_, 0) && cycleActive()) {
            test_grant_t0_block_ = false;
            for (size_t pos = 0; pos < blocks_.size(); ++pos) {
                const BlockId id = blocks_.idAt(pos);
                BlockInfo& b = blocks_.info(id);
                if (b.is_large || b.size_class != cls || b.alloc_state != kAllocNone) continue;
#if ECO_HEAP_VALIDATE
                if (isT0Block(id)) {
                    std::fprintf(stderr, "[heap-validate] TV5: the tenure grant took t0 block "
                                 "%u during a mark cycle\n", id.v);
                    std::fflush(stderr);
                    std::abort();
                }
#endif
            }
        }
        // (2) Growth: virgin blocks (never above the reuse rung).
        while (free_cells < need) {
            const BlockId id = materializeVirginBlock(cls);
            if (!id.valid()) {
                // Near the old-gen cap: no virgin block. The caller falls back.
                g.granted_cells += free_cells;
                g.active = true;
                ++active_tenure_grants_;
                return false;
            }
            ++g.virgin_blocks;
#if ENABLE_GC_STATS
            alloc_stats_.bm.virgin_blocks++;
#endif
            free_cells += take(cls, id);
        }
        g.granted_cells += free_cells;
    }
    g.active = true;
    ++active_tenure_grants_;
    return true;
}
// TLA-REGION(OGT.grantTenure) end

// TLA-REGION(OGT.grantAllocate) begin
void* OldGenSpace::grantAllocate(TenureGrant& g, size_t cls, size_t requested_size) {
    std::vector<TenureCursor>& v = g.blocks[cls];
    for (;;) {
        if (g.next[cls] >= v.size()) {
            grantFatal("exhausted (the per-class survivor histogram is wrong)", cls,
                       g.next[cls], v.size());
        }
        TenureCursor& c = v[g.next[cls]];
        uint32_t k = c.next_cell;
        if (k < c.num_cells) {
            const size_t bit = static_cast<size_t>(k) * c.stride_bits;
            if (((c.bits[bit >> 3] >> (bit & 7)) & 1u) != 0) {
                k = bitscan::nextFreeCell(c.bits, c.stride_bits, k, c.num_cells);
            }
        }
        if (k >= c.num_cells) {
            ++g.next[cls];
            continue;
        }
        c.next_cell = k + 1;
        const size_t cell = c.cell_bytes;
        char* p = c.base + static_cast<size_t>(k) * cell;
        // The bit is the allocation record, and mid-cycle the mark
        // (allocate-black): a post-t0 block, never touched by markers.
        bitscan::setBit(c.bits, static_cast<size_t>(k) * c.stride_bits);
        std::memset(p, 0, sizeof(Header));
        c.pending_live += cell;
        c.pending_allocs++;
        g.allocated_bytes += cell;
        g.old_alloc_total += cell;
        g.used_cells++;
#if ENABLE_GC_STATS
        const size_t sz = (requested_size + 7) & ~static_cast<size_t>(7);
        g.size_hist[GCStats::oldGenAllocBucket(sz)]++;
        if (sz >= 16 && sz < 24) g.size_16_24++;
#endif
#if ECO_HEAP_VALIDATE
        if (g.cycle_active) g.cycle_alloc_log.push_back(p);
#endif
        padSlack(p, requested_size, cell);
        return p;
    }
}
// TLA-REGION(OGT.grantAllocate) end

// TLA-REGION(OGT.grantAllocateShared) begin
void* OldGenSpace::grantAllocateShared(TenureGrant& g, TenureMemberCursor& m, size_t cls,
                                       size_t requested_size) {
    // A chunk owns >= 128 bitmap bytes (two cache lines): 64-cell chunks of
    // small classes are 8-16 bitmap bytes, and members setting bits in one
    // line ping-ponged it (measured: 77 % of this function on the load).
    // Always a multiple of 64 cells, so a chunk owns whole 64-bit bitmap
    // words: the scans read a word at a time (bitscan::loadWord), so whole
    // bytes would not be enough (CR-022).
    std::vector<TenureCursor>& v = g.blocks[cls];
    TenureMemberCursor::Cls& mc = m.c[cls];
    for (;;) {
        if (mc.bi >= 0) {
            const TenureCursor& b = v[static_cast<size_t>(mc.bi)];
            const uint32_t k = bitscan::nextFreeCell(b.bits, b.stride_bits, mc.k, mc.kend);
            if (k < mc.kend) {
                mc.k = k + 1;
                ++mc.used;
                const size_t cell = b.cell_bytes;
                char* p = b.base + static_cast<size_t>(k) * cell;
                bitscan::setBit(b.bits, static_cast<size_t>(k) * b.stride_bits);   // our bytes only
                std::memset(p, 0, sizeof(Header));
#if ENABLE_GC_STATS
                const size_t sz = (requested_size + 7) & ~static_cast<size_t>(7);
                m.size_hist[GCStats::oldGenAllocBucket(sz)]++;
                if (sz >= 16 && sz < 24) m.size_16_24++;
#endif
#if ECO_HEAP_VALIDATE
                if (g.cycle_active) m.cycle_alloc_log.push_back(p);
#endif
                padSlack(p, requested_size, cell);
                return p;
            }
            if (mc.used != 0)
                m.uses.push_back(TenureMemberCursor::Use{static_cast<uint16_t>(cls),
                                                         static_cast<uint32_t>(mc.bi), mc.used});
            mc.bi = -1;
            mc.used = 0;
        }
        // Claim the next chunk: CAS on block index << 32 | unit.
        std::atomic<uint64_t>& cw = g.claim[cls].w;
        uint64_t w = cw.load(std::memory_order_relaxed);
        for (;;) {
            const uint32_t bi = static_cast<uint32_t>(w >> 32);
            const uint32_t u = static_cast<uint32_t>(w);
            if (bi >= v.size()) {
                grantFatal("exhausted by the collector members (the slack is wrong)", cls, bi, v.size());
            }
            const uint32_t nc = v[bi].num_cells;
            const uint32_t kUnit = tenureChunkCells(v[bi].stride_bits);
            if (static_cast<uint64_t>(u) * kUnit >= nc) {
                const uint64_t nw = static_cast<uint64_t>(bi + 1) << 32;
                if (cw.compare_exchange_weak(w, nw, std::memory_order_relaxed)) w = nw;
                continue;
            }
            if (cw.compare_exchange_weak(w, w + 1, std::memory_order_relaxed)) {
                mc.bi = static_cast<int32_t>(bi);
                mc.k = u * kUnit;
                mc.kend = std::min<uint32_t>(nc, (u + 1) * kUnit);
                mc.used = 0;
                break;
            }
        }
    }
}
// TLA-REGION(OGT.grantAllocateShared) end

void OldGenSpace::grantFoldMember(TenureGrant& g, TenureMemberCursor& m) {
    for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
        TenureMemberCursor::Cls& mc = m.c[cls];
        if (mc.bi >= 0 && mc.used != 0)
            m.uses.push_back(TenureMemberCursor::Use{static_cast<uint16_t>(cls),
                                                     static_cast<uint32_t>(mc.bi), mc.used});
        mc = TenureMemberCursor::Cls{};
    }
    for (const TenureMemberCursor::Use& u : m.uses) {
        TenureCursor& c = g.blocks[u.cls][u.bi];
        const uint64_t bytes = static_cast<uint64_t>(u.cells) * c.cell_bytes;
        c.pending_live += bytes;
        c.pending_allocs += u.cells;
        g.allocated_bytes += bytes;
        g.old_alloc_total += bytes;
        g.used_cells += u.cells;
    }
    m.uses.clear();
    for (size_t i = 0; i < GCStats::OLDGEN_ALLOC_BUCKETS; ++i) g.size_hist[i] += m.size_hist[i];
    g.size_16_24 += m.size_16_24;
    std::memset(m.size_hist, 0, sizeof(m.size_hist));
    m.size_16_24 = 0;
#if ECO_HEAP_VALIDATE
    g.cycle_alloc_log.insert(g.cycle_alloc_log.end(), m.cycle_alloc_log.begin(), m.cycle_alloc_log.end());
    m.cycle_alloc_log.clear();
#endif
}

// TLA-REGION(OGT.returnTenureGrant) begin
void OldGenSpace::returnTenureGrant(TenureGrant& g) {
    if (!g.active) return;
    for (size_t cls = 0; cls < NUM_SIZE_CLASSES; ++cls) {
        std::vector<TenureCursor>& v = g.blocks[cls];
        // Flush in grant order.
        for (TenureCursor& c : v) {
            if (c.pending_allocs != 0) {
                blocks_.meta(c.block).live_bytes += c.pending_live;
#if ENABLE_GC_STATS
                alloc_stats_.bm.bitmap_allocs += c.pending_allocs;
                alloc_stats_.bm.bitmap_alloc_bytes += c.pending_live;
#endif
            }
            c.pending_live = c.pending_allocs = 0;
        }
        // Requeue in REVERSE grant order at the front: the first-granted
        // block is served first (W6: reuse before growth).
        for (size_t i = v.size(); i > 0; --i) {
            TenureCursor& c = v[i - 1];
            BlockInfo& b = blocks_.info(c.block);
            if (b.alloc_state != kAllocTenure) {
                std::fprintf(stderr, "[gc] FATAL: TV5: granted block %u changed state to %u "
                             "before the merge\n", c.block.v, (unsigned)b.alloc_state);
                std::fflush(stderr);
                std::abort();
            }
            b.alloc_state = kAllocNone;
            if (bitscan::nextFreeCell(c.bits, c.stride_bits, 0, c.num_cells) < c.num_cells) {
                requeueFront(cls, c.block);
            }
        }
        v.clear();
        g.next[cls] = 0;
    }
    allocated_bytes += g.allocated_bytes;
    old_alloc_total_ += g.old_alloc_total;
#if ENABLE_GC_STATS
    alloc_stats_.mergeOldGenAllocHistogram(g.size_hist, g.size_16_24);
#endif
#if ECO_HEAP_VALIDATE
    cycle_alloc_log_.insert(cycle_alloc_log_.end(), g.cycle_alloc_log.begin(), g.cycle_alloc_log.end());
    g.cycle_alloc_log.clear();
#endif
    g.allocated_bytes = g.old_alloc_total = 0;
    g.active = false;
    --active_tenure_grants_;
#if ECO_HEAP_VALIDATE
    if (active_tenure_grants_ == 0) validateTenureBlocks("merge");
#endif
}
// TLA-REGION(OGT.returnTenureGrant) end

void OldGenSpace::validateTenureBlocks(const char* where) const {
    if (active_tenure_grants_ != 0) return;
    for (size_t pos = 0; pos < blocks_.size(); ++pos) {
        const BlockId id = blocks_.idAt(pos);
        if (blocks_.info(id).alloc_state == kAllocTenure) {
            std::fprintf(stderr, "[heap-validate] TV5 (%s): block %u is kAllocTenure with no "
                         "live grant\n", where, id.v);
            std::fflush(stderr);
            std::abort();
        }
    }
}

}  // namespace Elm
