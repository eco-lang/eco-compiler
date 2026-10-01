// W3: one mark byte, many writers; promo_mu_ as a lock; and the access
// patterns of register entries CR-001 and CR-002
// (plans/threaded-gc-tla-W-weak-memory.md §7). One case per compile
// (-DW3_CASE='a' .. 'f'): the checker stops at the first report. W3c/W3d raced
// until CR-002 / CR-001 were fixed (2026-09-30); their pre-fix shapes are the
// mutants MUTANT_W3_CR002_UNLOCKED_FINALIZE / MUTANT_W3_CR001_PLAIN_PHASE.
//
// Real code: bitscan::nextFreeCell / nextSetBit / setBit / clearBit
// (BitmapScan.hpp) and minorwork::SpinMutex (MinorWork.hpp, promo_mu_'s type).
// Copies (canary-pinned, §11): markerTAS = testAndSetMark<ParallelMark>'s
// parallel branch (OldGenSpace.cpp:3067-3068); allocateBlack =
// setMarkBitAtomic's non-large branch (OldGenSpace.hpp:1832).
#include <atomic>
#include "BitmapScan.hpp"
#include "MinorWork.hpp"
#include "wdriver.hpp"               // last: it redefines assert

#ifndef W3_CASE
#define W3_CASE 'a'
#endif

// Two MarkBitArena slots (64-byte stride, OldGenSpace's layout): block 0 is a
// t0 mixed block (bytes 0..63), block 1 a post-t0 cursor block (bytes 64..127).
alignas(64) static uint8_t bits[128];
static Elm::minorwork::SpinMutex promo_mu;
static int phase_idle;                       // stands for OldGenSpace::gc_phase_ (atomic_ref at the racing sites, CR-001)
static int counter;                          // a plain field guarded by promo_mu_

// SpinMutex::lock() spins through __builtin_ia32_pause, yield and sleep_for
// (MinorWork.hpp:91-108). The real try_lock(), under an assumption, is the
// same lock with the spin pruned.
static void lockPromo() { VERIFIER_ASSUME(promo_mu.try_lock()); }

static bool markerTAS(uint8_t* b, uint8_t mask) {            // OldGenSpace.cpp:3066-3068
    std::atomic_ref<uint8_t> r(*b);
    if (r.load(std::memory_order_relaxed) & mask) return true;
    return (r.fetch_or(mask, std::memory_order_relaxed) & mask) != 0;
}
static void allocateBlack(uint8_t* b, uint8_t mask) {        // OldGenSpace.hpp:1832
#ifdef MUTANT_W3_PLAIN_ALLOCATE_BLACK
    *b = static_cast<uint8_t>(*b | mask);                    // setMarkBitInBlock (05c negative control)
#else
    std::atomic_ref<uint8_t>(*b).fetch_or(mask, std::memory_order_relaxed);
#endif
}

// a: a marker (bit 0) and allocate-black (bit 1) on the same byte.
static void* a_marker(void*) { markerTAS(&bits[0], 0x01); return nullptr; }
static void* a_alloc(void*) { allocateBlack(&bits[0], 0x02); return nullptr; }

// b: IM13. The cursor allocates in ITS OWN slot (block 1): a 64-bit word read
// (nextFreeCell -> loadWord) and a plain setBit, while a marker marks block 0.
static void* b_cursor(void*) {
#ifdef MUTANT_W3_CURSOR_ON_T0_BYTE
    const size_t base = 0;                   // IM13 violated: the cursor owns the t0 block
#else
    const size_t base = 64 * 8;
#endif
    const uint32_t k = Elm::bitscan::nextFreeCell(bits + base / 8, 1, 0, 64);
    Elm::bitscan::setBit(bits + base / 8, k);
    return nullptr;
}

// c (CR-002): the gap sweep, under the lock, finds the live object with a
// WORD read (nextSetBit, lazySweep) and plain-clears its bit, while a popped
// cell of the SAME block gets its allocate-black fetch_or on the same byte.
// Fixed (register-fixes 4.3, HEAP_055): a cell of a block that is not fully
// swept is finalized BEFORE promo_mu_ is released (cellInUnsweptBlock), so the
// fetch_or is ordered with the sweeper's plain accesses by the lock.
// MUTANT_W3_CR002_UNLOCKED_FINALIZE: the pre-fix batch (finalized after the unlock).
static void* c_sweeper(void*) {
    lockPromo();
    const size_t nb = Elm::bitscan::nextSetBit(bits, 0, 64);
    Elm::bitscan::clearBit(bits, nb);
    promo_mu.unlock();
    return nullptr;
}
static void* c_finalizer(void*) {
    lockPromo();                             // the batch pop
#ifdef MUTANT_W3_CR002_UNLOCKED_FINALIZE
    promo_mu.unlock();
    allocateBlack(&bits[0], 0x01);           // pre-fix: outside the lock
#else
    allocateBlack(&bits[0], 0x01);           // CR-002: before the unlock
    promo_mu.unlock();
#endif
    return nullptr;
}

// d (CR-001): lazySweep writes gc_phase_ under the lock (completeSweep); another
// worker reads it without the lock (finalizePoppedCellW, finalizeBitmapCellW).
// Fixed (register-fixes 4.2, HEAP_067): the write is a relaxed atomic_ref store
// and the unlocked read a relaxed atomic_ref load. MUTANT_W3_CR001_PLAIN_PHASE:
// the pre-fix plain accesses (a race on phase_idle).
static void* d_sweeper(void*) {
    lockPromo();
#ifdef MUTANT_W3_CR001_PLAIN_PHASE
    phase_idle = 1;
#else
    std::atomic_ref<int>(phase_idle).store(1, std::memory_order_relaxed);
#endif
    promo_mu.unlock();
    return nullptr;
}
static void* d_reader(void*) {
#ifdef MUTANT_W3_CR001_PLAIN_PHASE
    const int p = phase_idle;
#else
    const int p = std::atomic_ref<int>(phase_idle).load(std::memory_order_relaxed);
#endif
    (void)p;
    return nullptr;
}

// e: 7c L3 members in adjacent grant chunks (grantAllocateShared,
// OldGenTenure.cpp:208-214). nextFreeCell reads whole 64-bit words, so chunks
// must own whole WORDS, not just bytes (tenureChunkCells, OldGenSpace.hpp:696-699).
#if defined(MUTANT_W3_SMALL_CHUNK)
constexpr uint32_t kChunk = 4;               // two members in one byte
#elif defined(MUTANT_W3_BYTE_CHUNK)
constexpr uint32_t kChunk = 8;               // byte-disjoint, but one 64-bit word
#else
constexpr uint32_t kChunk = 64;              // a multiple of 64 cells (m = 1 here)
#endif
static void* e_member(void* arg) {
    const uint32_t lo = static_cast<uint32_t>(intOf(arg)) * kChunk;
    const uint32_t k = Elm::bitscan::nextFreeCell(bits, 1, lo, lo + kChunk);
    Elm::bitscan::setBit(bits, k);
    return nullptr;
}

// f: promo_mu_ is a lock (M4, M7 assume it): two plain increments under it.
static void* f_worker(void*) { lockPromo(); ++counter; promo_mu.unlock(); return nullptr; }

int main() {
    wthread x{}, y{};
    switch (W3_CASE) {
    case 'a': x = spawn(a_marker); y = spawn(a_alloc); break;
    case 'b': x = spawn(a_marker); y = spawn(b_cursor); break;
    case 'c': bits[0] = 0x10;                // the live object's bit (4) is set
              x = spawn(c_sweeper); y = spawn(c_finalizer); break;
    case 'd': x = spawn(d_sweeper); y = spawn(d_reader); break;
    case 'e': x = spawn(e_member, argOf(0)); y = spawn(e_member, argOf(1)); break;
    default:  x = spawn(f_worker); y = spawn(f_worker); break;
    }
    join(x);
    join(y);
    if (W3_CASE == 'a') assert(bits[0] == 0x03);
    if (W3_CASE == 'f') assert(counter == 2);
    return 0;
}
