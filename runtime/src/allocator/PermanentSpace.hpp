// Some heap values, once made, are never changed and are needed until the process ends: the value
// a top-level constant (a CAF) evaluates to, a string literal, a closure that captures nothing.
// Keeping them on the collected heap costs every collection work to trace or root them, for nothing.
// This component is a place to put such values where no collector looks: permanent space.
//
// Permanent space is one virtual-address reservation (`kPermanentReserve`) made below
// `HPOINTER_ADDRESS_LIMIT`, so a word pointing into it is an ordinary HPointer, but outside the heap
// range, so `Allocator::isInHeap` is false for every address in it. No collector traces, moves or frees an
// object outside the heap range, so a permanent object is never traced, moved or freed. Memory is handed out by
// bump allocation and never returned.
//
// Two rules follow, and nothing in this component enforces them for a caller of `allocate`:
//
// - A permanent object must not be written after it is published, because no collector would see a
//   heap pointer stored into it.
// - A permanent object may point only at other permanent objects, embedded constants, or memory outside
//   the heap. A pointer into the heap would not keep its target alive, and would not be updated when the
//   target moved.
//
// `eco_caf_promote` keeps both rules for a CAF value by copying the whole graph the value reaches.
// Other code may allocate here directly, for objects that hold no heap pointers.
//
// Nothing in permanent space is registered as a GC root. `eco_caf_promote` roots a CAF's slot when
// the value is left where it was (see its comment).
/*
 * Allocation is mutex-serialized (multiple Elm threads can intern/promote
 * under the embed API).
 */

#ifndef ECO_PERMANENT_SPACE_H
#define ECO_PERMANENT_SPACE_H

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <mutex>

namespace Elm {

/// The process's permanent space: memory outside the heap range that no collector traces, moves or frees.
///
/// There is one, obtained with `instance`; it is created on first use and never destroyed. The
/// reservation is made by the first `allocate`, and is retried by later calls if it failed.
class PermanentSpace {
public:
    /// Returns the process's permanent space.
    static PermanentSpace &instance();

    /// Returns an 8-aligned block of `bytes`, rounded up to a multiple of 8, of permanent memory, or null
    /// if the reservation could not be made, the reservation is full, or committing pages failed.
    ///
    /// Pages are committed in 16 MiB steps as the space grows. The block is never freed or reused.
    /// Calls are serialized by a mutex.
    void *allocate(std::size_t bytes);

    /// Returns whether `p` lies in the part of permanent space handed out so far; false before the first
    /// successful `allocate`. Takes no lock: it reads the base and the used size with acquire loads.
    bool contains(const void *p) const {
        const char *b = base_.load(std::memory_order_acquire);
        const char *c = static_cast<const char *>(p);
        return b != nullptr && c >= b &&
               c < b + used_.load(std::memory_order_acquire);
    }

    /// Counters of what has been put in permanent space. `eco_caf_promote` updates all but the
    /// `interned_*` pair, which code allocating here directly is expected to update.
    struct Stats {
        std::atomic<std::uint64_t> values_promoted{0}; ///< CAF values copied into permanent space.
        /// CAF values left as they were because they are not heap pointers: embedded constants and, when
        /// promotion is enabled, null words and addresses outside the heap.
        std::atomic<std::uint64_t> values_constant{0};
        /// CAF values left on the heap because a copy was refused or could not be completed.
        std::atomic<std::uint64_t> values_declined{0};
        std::atomic<std::uint64_t> objects_copied{0};
        std::atomic<std::uint64_t> bytes_copied{0};
        /// Bytes allocated for copies that were then given up; they stay allocated and nothing points at them.
        std::atomic<std::uint64_t> bytes_abandoned{0};
        std::atomic<std::uint64_t> slots_rooted{0}; ///< CAF slots registered as JIT roots.
        std::atomic<std::uint64_t> interned_objects{0};
        std::atomic<std::uint64_t> interned_bytes{0};
    };
    /// The counters, read and written without a lock.
    Stats stats;

private:
    /// Creates the space with nothing reserved.
    PermanentSpace() = default;

    /// Makes the reservation if it has not been made, and returns whether it exists. `mutex_` must be held.
    bool ensureReservedLocked();

    std::mutex mutex_; ///< Held by `allocate` throughout; guards `reserved_` and `committed_`.
    std::atomic<char *> base_{nullptr};
    std::size_t reserved_ = 0;
    std::size_t committed_ = 0;
    std::atomic<std::size_t> used_{0};
};

} // namespace Elm

/// Returns the word to store in a CAF's memo slot for the freshly computed value `bits`: a pointer to a
/// copy of the value in permanent space, or `bits` itself.
///
/// The copy is of the whole graph the value reaches through the heap, with its internal pointers
/// rewritten to the copies, so it obeys permanent space's rules. `bits` is returned unchanged when it is
/// an embedded constant, null or an address outside the heap, and when promotion is disabled or refused.
/// Promotion is disabled when the environment variable `ECO_CAF_PERMANENT` starts with `0` (read once).
/// It is refused when the graph holds a large String or Bytes, or an object `visitHeapChildren`
/// declines, and abandoned if permanent space runs out partway. A refused or abandoned value is not
/// changed; an abandoned copy's bytes stay allocated (`Stats::bytes_abandoned`).
///
/// Whenever `bits` is returned and is not an embedded constant, `slot` is registered as a JIT root of the
/// calling thread's root set, so the slot must stay valid for as long as that root set may be scanned.
/// With promotion enabled, a null word or an address outside the heap is the exception and is not rooted.
/// The function never writes `*slot`.
///
/// The calling thread must have a heap. No collection may run during the call: the graph is traversed
/// and copied by raw address. The function itself allocates nothing on the managed heap.
extern "C" std::uint64_t eco_caf_promote(std::uint64_t bits, std::uint64_t *slot);

#endif // ECO_PERMANENT_SPACE_H
