/* PermanentSpace — immortal, GC-invisible storage for memoized CAF values.
 *
 * plans/caf-permanent-space.md. A separate VA reservation OUTSIDE the unified
 * heap range but below HPOINTER_ADDRESS_LIMIT: `Allocator::isInHeap` is false
 * for every permanent address, so minor evacuation, major mark, sweep, and
 * the nursery tripwires all ignore permanent objects with no code changes
 * (markHPointer/pushMarkRoot bail on the bounds checks). Contents must be
 * IMMUTABLE and CLOSED under references (may point only at other permanent
 * objects, embedded constants, or non-heap statics) — guaranteed by the
 * transitive deep copy in eco_caf_promote (HEAP_036).
 *
 * Runtime-gated by ECO_CAF_PERMANENT=1 (default off): the guard's promote
 * call is emitted unconditionally but degenerates to a return of its
 * argument when the gate is off.
 */

#ifndef ECO_PERMANENT_SPACE_H
#define ECO_PERMANENT_SPACE_H

#include <cstddef>
#include <cstdint>

namespace Elm {

class PermanentSpace {
public:
    static PermanentSpace &instance();

    // 8-aligned bump allocation; commits pages on demand. Returns nullptr on
    // reservation failure or VA exhaustion (caller declines the promotion).
    void *allocate(std::size_t bytes);

    // O(1): inside the reserved region's used prefix. False before first use.
    bool contains(const void *p) const {
        const char *c = static_cast<const char *>(p);
        return base_ != nullptr && c >= base_ && c < base_ + used_;
    }

    // ---- promotion statistics (printed in the GC stats dump) ----
    struct Stats {
        std::uint64_t values_promoted = 0;   // slots whose value was deep-copied
        std::uint64_t values_constant = 0;   // slots holding constants/non-heap (deregistered only)
        std::uint64_t values_declined = 0;   // fallback: unsupported tag / OOM
        std::uint64_t objects_copied = 0;
        std::uint64_t bytes_copied = 0;
        std::uint64_t bytes_abandoned = 0;   // phase-2 abort residue (never reachable)
        std::uint64_t slots_deregistered = 0;
    };
    Stats stats;

private:
    PermanentSpace() = default;
    bool ensureReserved();

    char *base_ = nullptr;
    std::size_t reserved_ = 0;
    std::size_t committed_ = 0;
    std::size_t used_ = 0;
};

} // namespace Elm

// The memo-guard hook (emitted by installCafMemoGuard on every caf_memo
// thunk's return path; declared gc-leaf — never triggers GC, never calls
// back into Elm). Returns the bits to store/return: a permanent copy on
// successful promotion, `bits` unchanged otherwise. Deregisters `slot`
// from the JIT root set when the stored value can never need GC attention
// (promoted, constant, or non-heap).
extern "C" std::uint64_t eco_caf_promote(std::uint64_t bits, std::uint64_t *slot);

#endif // ECO_PERMANENT_SPACE_H
