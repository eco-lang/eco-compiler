/* PermanentSpace — immortal, GC-invisible storage for memoized CAF values
 * and interned literals/closures.
 *
 * plans/caf-permanent-space.md. A separate VA reservation OUTSIDE the unified
 * heap range but below HPOINTER_ADDRESS_LIMIT: `Allocator::isInHeap` is false
 * for every permanent address, so minor evacuation, major mark, sweep, and
 * the nursery tripwires all ignore permanent objects with no code changes
 * (markHPointer/pushMarkRoot bail on the bounds checks). Contents must be
 * IMMUTABLE and CLOSED under references (may point only at other permanent
 * objects, embedded constants, or non-heap statics) — guaranteed by the
 * transitive deep copy in eco_caf_promote, and by construction for interned
 * string literals (pointer-free leaves) and zero-capture closures (zeroed
 * value slots, code-pointer evaluator). HEAP_036.
 *
 * Nothing permanent is ever GC-rooted: CAF slots register as JIT roots ONLY
 * when a promotion declines (or ECO_CAF_PERMANENT=0 keeps values on the
 * heap), and intern-table slots root ONLY on the old-gen fallback path.
 *
 * Allocation is mutex-serialized (multiple Elm threads can intern/promote
 * under the embed API); `contains` is lock-free over atomic bounds.
 */

#ifndef ECO_PERMANENT_SPACE_H
#define ECO_PERMANENT_SPACE_H

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>

namespace Elm {

class PermanentSpace {
public:
    static PermanentSpace &instance();

    // 8-aligned bump allocation; commits pages on demand. Returns nullptr on
    // reservation failure or VA exhaustion (callers fall back to heap
    // allocation + rooting).
    void *allocate(std::size_t bytes);

    // O(1), lock-free: inside the reserved region's used prefix. False
    // before first use.
    bool contains(const void *p) const {
        const char *b = base_.load(std::memory_order_acquire);
        const char *c = static_cast<const char *>(p);
        return b != nullptr && c >= b &&
               c < b + used_.load(std::memory_order_acquire);
    }

    // ---- statistics (printed in the GC stats dump) ----
    struct Stats {
        std::atomic<std::uint64_t> values_promoted{0}; // slots whose value was deep-copied
        std::atomic<std::uint64_t> values_constant{0}; // constants/non-heap: nothing to do at all
        std::atomic<std::uint64_t> values_declined{0}; // fallback: unsupported tag / OOM
        std::atomic<std::uint64_t> objects_copied{0};
        std::atomic<std::uint64_t> bytes_copied{0};
        std::atomic<std::uint64_t> bytes_abandoned{0}; // phase-2 abort residue (never reachable)
        std::atomic<std::uint64_t> slots_rooted{0};    // CAF slots JIT-rooted (declined / flag-off)
        std::atomic<std::uint64_t> interned_objects{0}; // literals + closure0s born permanent
        std::atomic<std::uint64_t> interned_bytes{0};
    };
    Stats stats;

private:
    PermanentSpace() = default;
    bool ensureReservedLocked();

    std::mutex mutex_;
    std::atomic<char *> base_{nullptr};
    std::size_t reserved_ = 0;
    std::size_t committed_ = 0;
    std::atomic<std::size_t> used_{0};
};

} // namespace Elm

// The memo-guard hook (emitted by installCafMemoGuard on every caf_memo
// thunk's return path; declared gc-leaf — never triggers GC, never calls
// back into Elm). Returns the bits to store/return: a permanent copy on
// successful promotion, `bits` unchanged otherwise. Slots are NOT
// pre-registered as GC roots; this hook registers `slot` exactly when the
// stored value stays heap-resident (declined promotion or
// ECO_CAF_PERMANENT=0).
extern "C" std::uint64_t eco_caf_promote(std::uint64_t bits, std::uint64_t *slot);

#endif // ECO_PERMANENT_SPACE_H
