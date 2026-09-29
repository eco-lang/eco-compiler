// W4b: a promotion worker claims a chunk of a block another worker just
// materialized (plans/threaded-gc-tla-W-weak-memory.md §8.3, W4b). A pinned
// REDUCTION of
//   worker A, under promo_mu_ (the REAL minorwork::SpinMutex, taken with
//     try_lock under an assumption): startVirginBlockShared
//     (OldGenSpace.cpp:1249-1275) -> materializeBlock (plain BlockInfo, bitmap
//     slot zeroed), retire the block it replaces (plain alloc_state),
//     publishShared (:1201-1213: plain alloc_state, then the shared word with
//     a RELEASE store);
//   worker B, lock-free: claimChunkW (:1171-1197): the shared word with
//     ACQUIRE, plain BlockInfo reads (cellsIn) before the CAS, CAS
//     acq_rel / acquire; then its cursor reads the claimed chunk's bitmap word
//     (bitscan::nextFreeCell, the REAL function) and sets a bit (setBit).
//
// A publishes block 1 in one lock hold and block 2 in a later one, so B's CAS
// can fail by reading block 2's word (the W4_RELAXED_CLAIM_FAIL mutant). The
// claim loop is copied with its two iterations written out, and these rows run
// with -disable-spin-assume: GenMC's spin-assume cuts a side-effect-free
// iteration after a failed CAS before the retry's reads (it made the W5 claim
// mutant pass silently, test/genmc/AUDIT.md).
#include <atomic>
#include <cstring>
#include "BitmapScan.hpp"
#include "MinorWork.hpp"
#include "wdriver.hpp"               // last: it redefines assert

#ifdef MUTANT_W4_RELAXED_SHARED
constexpr std::memory_order kPublish = std::memory_order_relaxed;
#else
constexpr std::memory_order kPublish = std::memory_order_release;      // OldGenSpace.cpp:1211-1212
#endif
#ifdef MUTANT_W4_RELAXED_CLAIM_FAIL
constexpr std::memory_order kClaimFail = std::memory_order_relaxed;
#else
constexpr std::memory_order kClaimFail = std::memory_order_acquire;    // OldGenSpace.cpp:1184-1185
#endif

constexpr uint32_t kChunkUnitCells = 64;     // OldGenSpace.hpp:646
constexpr uint8_t kAllocNone = 0, kAllocCurrent = 1;

struct BlockInfo { char* start; char* end_of_objects; uint32_t cell_bytes; uint8_t alloc_state; };
static char heap[3][128 * 8];                // blocks 1, 2: 128 cells of 8 bytes
static BlockInfo info[3];                    // BlockTable::info_ (plain)
alignas(64) static uint8_t mark[3][64];      // MarkBitArena slots, 64-byte stride
static std::atomic<uint64_t> shared{0};      // PromoCtx::shared[cls].w: (id + 1) << 32 | next unit
static Elm::minorwork::SpinMutex promo_mu;
static int claimed_id = -1;                  // written by B only

static void lockPromo() { VERIFIER_ASSUME(promo_mu.try_lock()); }

static uint32_t cellsIn(const BlockInfo& b) {                   // OldGenSpace.hpp:578-582
    return static_cast<uint32_t>(static_cast<size_t>(b.end_of_objects - b.start) / b.cell_bytes);
}

static void startVirginBlockShared(uint32_t id) {               // under promo_mu_
    info[id].start = heap[id];                                  // materializeBlock: blocks_.add
    info[id].end_of_objects = heap[id] + 128 * 8;
    info[id].cell_bytes = 8;
    info[id].alloc_state = kAllocNone;
    std::memset(mark[id], 0, 16);                               //   mark_.assign
    const uint64_t w = shared.load(std::memory_order_relaxed);  // :1265
    if (w != 0) info[static_cast<uint32_t>(w >> 32) - 1].alloc_state = kAllocNone;   // retire
    info[id].alloc_state = kAllocCurrent;                       // publishShared :1210
    shared.store((static_cast<uint64_t>(id) + 1) << 32, kPublish);   // :1211
}

static void* workerA(void*) {
    lockPromo();
    startVirginBlockShared(1);
    promo_mu.unlock();
    lockPromo();                                                // a later lock hold
    startVirginBlockShared(2);
    promo_mu.unlock();
    return nullptr;
}

static void* workerB(void*) {                                   // claimChunkW, one unit
    uint64_t w = shared.load(std::memory_order_acquire);        // :1173
    for (int attempt = 0; attempt < 2; ++attempt) {             // for (;;), unrolled
        if (w == 0) return nullptr;
        const uint32_t id = static_cast<uint32_t>(w >> 32) - 1;
        const uint32_t k = static_cast<uint32_t>(w);
        const BlockInfo& b = info[id];                          // plain, before the CAS
        const uint32_t ncell = cellsIn(b);
        const uint64_t lo = static_cast<uint64_t>(k) * kChunkUnitCells;
        if (lo >= ncell) return nullptr;
        if (shared.compare_exchange_weak(w, w + 1, std::memory_order_acq_rel, kClaimFail)) {
            uint8_t* bits = mark[id];                           // c.bits = mark_.slot(id)
            const uint32_t end = static_cast<uint32_t>(lo) + kChunkUnitCells;
            const uint32_t cell = Elm::bitscan::nextFreeCell(bits, 1, static_cast<uint32_t>(lo), end);
            assert(cell == lo);                                 // a fresh chunk: every cell free
            Elm::bitscan::setBit(bits, cell);
            claimed_id = static_cast<int>(id);
            return nullptr;
        }
    }
    return nullptr;
}

int main() {
    wthread a = spawn(workerA), b = spawn(workerB);
    join(a);
    join(b);
    assert(claimed_id == -1 || claimed_id == 1 || claimed_id == 2);
    return 0;
}
