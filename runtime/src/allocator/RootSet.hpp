#ifndef ECO_ROOTSET_H
#define ECO_ROOTSET_H

#include <cstddef>
#include <cstdint>
#include <cassert>
#include <cstdlib>
#include <functional>
#include <unordered_set>
#include <vector>
#include "AllocatorCommon.hpp"
#include "Heap.hpp"

namespace Elm {

//===----------------------------------------------------------------------===//
// TLS shadow stack for stack root ranges (plans/gc-root-registration-cost.md O1)
//
// A contiguous range of stack-allocated i64 values that may contain HPointers.
// hpointer_mask is MANDATORY for correctness on mixed arrays:
//   - Bit i set   -> base[i] is treated as an HPointer root.
//   - Bit i clear -> base[i] is ignored by the GC.
// For all-boxed arrays, hpointer_mask is simply ((1ULL << count) - 1).
//
// The stack used to be a `std::vector<StackRootRange>` inside RootSet, reached
// through `tl_heap_ -> nursery_ -> root_set` and pushed by an out-of-line
// `eco_gc_push_stack_range` call (libEcoRuntimeStatic is not LTO'd against
// generated code, so nothing inlined). `eco_gc_push_stack_range` was the single
// hottest symbol of the self-compile at 14.53% self, on ~1.99 B events — one per
// closure-dispatch entry. It is now a raw three-cursor stack in initial-exec TLS,
// so a push is `load fs:sp; 3 stores; store fs:sp` with no call and no capacity
// check, and the restore point IS the cursor (nothing to unwind: the record is
// trivially destructible).
//
// LAYOUT IS FROZEN: compiled code writes base at +0, count at +8, mask at +16
// and advances the cursor by 24 (EcoBackend.cpp expandRootRangeOps). Changing
// this struct means changing that emission in lockstep.
//===----------------------------------------------------------------------===//

struct StackRootRangeRec {
    HPointer* base;
    size_t    count;
    uint64_t  hpointer_mask;
};
static_assert(sizeof(StackRootRangeRec) == 24,
              "compiled code hard-codes the 24-byte shadow-stack stride");
static_assert(offsetof(StackRootRangeRec, base) == 0, "base at +0");
static_assert(offsetof(StackRootRangeRec, count) == 8, "count at +8");
static_assert(offsetof(StackRootRangeRec, hpointer_mask) == 16, "mask at +16");

// Cursor, array start and usable end for the calling thread's shadow stack.
// Written ONLY by `Allocator::setThreadHeap` (base/limit, and the cursor reset)
// and by the push/restore operations below (the cursor). A value that disagrees
// with `tl_heap_` is heap corruption, not a wrong statistic — exactly as for
// `eco_tl_bump_state`, which is set in the same one place for the same reason.
//
// initial-exec + constinit: no dynamic-init guard and no `__tls_get_addr` call
// under -fPIC, so both the runtime C++ and generated code reach them with one
// %fs-relative load (plans/inline-bump-state-tls.md:145 records LLVM 21.1.8
// lowering `llvm.threadlocal.address` on such a global exactly that way).
extern "C" {
extern thread_local StackRootRangeRec* eco_tl_root_sp
    __attribute__((tls_model("initial-exec")));
extern thread_local StackRootRangeRec* eco_tl_root_base
    __attribute__((tls_model("initial-exec")));
extern thread_local StackRootRangeRec* eco_tl_root_limit
    __attribute__((tls_model("initial-exec")));

// Single-slot shadow stack (plan §3.3): 8 bytes per entry instead of 24.
// `StackRootGuard(a,b,c,d)` used to push four separate one-element RANGES —
// 96 bytes and four pushes to root four pointers — and the runtime's own apply
// paths push `&closure_bits` as a one-element range on every dispatch. Those
// carry no count and no mask worth storing: the count is 1 and the mask is 1 by
// construction, so the entry is just the slot address and a push is `*sp++ = p`.
//
// NOT used at `Scheduler.cpp`'s `EncodedStackRootGuard`, which plan §3.3 names:
// that file is pinned by the LSS_022 kernel-parametricity manifest (six
// `Scheduler.*` licences hash it), so ANY edit — a comment included — requires
// re-auditing `KernelSetFacts.elm`, which is COMPILER SOURCE and therefore the
// benchmark's own workload. Moving the workload to save two stores at a cold
// effect-manager site is a bad trade; after Phase 1 its range push is already
// inline and call-free.
//
// Kept as a SEPARATE stack rather than a tagged entry in the range stack so the
// compiled-code fast path (which only ever pushes ranges) is untouched: its
// push, and `stackRangePoint`/`restoreStackRangePoint`, still move exactly one
// cursor. Scopes that can push to both take an `EcoRootMark` below.
extern thread_local HPointer** eco_tl_root1_sp
    __attribute__((tls_model("initial-exec")));
extern thread_local HPointer** eco_tl_root1_base
    __attribute__((tls_model("initial-exec")));
extern thread_local HPointer** eco_tl_root1_limit
    __attribute__((tls_model("initial-exec")));
}

// Fatal shadow-stack overflow. Never returns.
[[noreturn]] void ecoRootStackOverflow(std::size_t depth);

// Usable slots per thread. The old vector reserved 4096 and the comment on it
// recorded "steady-state depth in the Stage 7 self-compile stays under a few
// hundred entries", so 65536 is ~16x headroom on the deepest figure ever seen.
inline constexpr std::size_t kRootRangeStackSlots = 65536;
// Slack allocated PAST the limit. An overflow is a bug, but with the slack it
// lands in memory this RootSet owns instead of in someone else's, which turns a
// silent heap corruption into a diagnosable one even in a build with the
// overflow check compiled out.
inline constexpr std::size_t kRootRangeStackSlack = 1024;

// Single-slot stack. Its depth is bounded by C++ recursion depth across guarded
// scopes (each `StackRootGuard` pushes at most 8), so it needs no more headroom
// than the range stack; at 8 bytes an entry the whole array is 512 KiB.
inline constexpr std::size_t kRoot1StackSlots = 65536;
inline constexpr std::size_t kRoot1StackSlack = 1024;

// Depth of the calling thread's shadow stack, as an opaque token. The cursor IS
// the depth, so this is one TLS load; the token is a pointer value rather than
// an index, but the `size_t` ABI is unchanged so no signature moved.
inline std::size_t ecoRootRangePoint() noexcept {
    return reinterpret_cast<std::size_t>(eco_tl_root_sp);
}

// Pops back to `point`. CLAMPED, preserving the old `resize`-based semantics
// exactly: a restore to a point ABOVE the cursor (a double restore, or a stale
// token used after an outer scope already popped) must not republish entries the
// GC would then read as live roots. Compiled code emits the unconditional store
// instead — its point/push/call/restore quads are emitted as one balanced unit.
inline void ecoRootRangeRestore(std::size_t point) noexcept {
    auto* p = reinterpret_cast<StackRootRangeRec*>(point);
    if (p <= eco_tl_root_sp)
        eco_tl_root_sp = p;
}

inline void ecoRootRangePush(HPointer* base, std::size_t count,
                             std::uint64_t hpointer_mask) noexcept {
    StackRootRangeRec* sp = eco_tl_root_sp;
#if ECO_HEAP_VALIDATE || !defined(NDEBUG)
    if (sp >= eco_tl_root_limit)
        ecoRootStackOverflow(static_cast<std::size_t>(sp - eco_tl_root_base));
#endif
    sp->base = base;
    sp->count = count;
    sp->hpointer_mask = hpointer_mask;
    eco_tl_root_sp = sp + 1;
}

// ---- single-slot stack (plan §3.3) ----

inline HPointer** ecoRoot1Point() noexcept { return eco_tl_root1_sp; }

inline void ecoRoot1Restore(HPointer** p) noexcept {
    if (p <= eco_tl_root1_sp)
        eco_tl_root1_sp = p;
}

inline void ecoRoot1Push(HPointer* slot) noexcept {
    HPointer** sp = eco_tl_root1_sp;
#if ECO_HEAP_VALIDATE || !defined(NDEBUG)
    if (sp >= eco_tl_root1_limit)
        ecoRootStackOverflow(static_cast<std::size_t>(sp - eco_tl_root1_base));
#endif
    *sp = slot;
    eco_tl_root1_sp = sp + 1;
}

// A scope that may push to EITHER stack saves both cursors. Two loads and two
// stores, still far below the vector push_back this replaces. Compiled code
// never needs this: its quads only ever touch the range stack.
struct EcoRootMark {
    StackRootRangeRec* range;
    HPointer** one;
};

inline EcoRootMark ecoRootMark() noexcept {
    return EcoRootMark{eco_tl_root_sp, eco_tl_root1_sp};
}

inline void ecoRootRelease(EcoRootMark m) noexcept {
    if (m.range <= eco_tl_root_sp)
        eco_tl_root_sp = m.range;
    if (m.one <= eco_tl_root1_sp)
        eco_tl_root1_sp = m.one;
}

// Iterable `[base, sp)` view over the single-slot stack, for the two collectors.
struct SingleRootView {
    HPointer* const* b;
    HPointer* const* e;
    HPointer* const* begin() const { return b; }
    HPointer* const* end() const { return e; }
    std::size_t size() const { return static_cast<std::size_t>(e - b); }
    bool empty() const { return b == e; }
};

// Iterable `[base, sp)` view, replacing the `const std::vector&` the collector
// used to walk. Same `begin/end/size/operator[]` surface, so the four scan and
// debug sites are unchanged.
struct StackRootRangeView {
    const StackRootRangeRec* b;
    const StackRootRangeRec* e;
    const StackRootRangeRec* begin() const { return b; }
    const StackRootRangeRec* end() const { return e; }
    std::size_t size() const { return static_cast<std::size_t>(e - b); }
    bool empty() const { return b == e; }
    const StackRootRangeRec& operator[](std::size_t i) const { return b[i]; }
};

/**
 * Tracks GC roots: pointers into the heap that must be scanned during collection.
 *
 * Maintains two types of roots:
 * - Long-lived roots: Registered with addRoot/removeRoot, persist across GC cycles.
 * - Stack roots: Temporary roots pushed/popped as functions execute.
 *
 * Each thread has its own RootSet in its NurserySpace, so no mutex is needed.
 *
 * HEAP_020's container split is preserved: the TLS shadow stack replaces the
 * `stack_root_ranges` vector ONLY. `StackMapRoots` is a separate structure and
 * is untouched, so `restoreStackRangePoint` can never reach it.
 */
class RootSet {
public:
    // Kept as a nested alias: existing code names `RootSet::StackRootRange`.
    using StackRootRange = StackRootRangeRec;

    // Owns the calling thread's shadow-stack storage. The array is allocated
    // once per thread heap and published into TLS by Allocator::setThreadHeap.
    RootSet();
    ~RootSet();

    // Owns raw storage that TLS points at: never copy or move a RootSet.
    RootSet(const RootSet&) = delete;
    RootSet& operator=(const RootSet&) = delete;

    // ===== Long-lived roots =====

    // Registers a pointer location as a GC root. O(1) average.
    void addRoot(HPointer *root);

    // Unregisters a pointer location from the root set. O(1) average.
    void removeRoot(HPointer *root);

    // Returns the set of registered root pointers.
    const std::unordered_set<HPointer *> &getRoots() const { return roots; }

    // ===== JIT roots (raw 64-bit pointers) =====
    // In JIT mode, globals store full 64-bit heap pointers rather than
    // HPointer-encoded values. These need separate handling.

    // Registers a JIT root (location storing a raw 64-bit heap pointer).
    void addJitRoot(uint64_t *root);

    // Unregisters a JIT root.
    void removeJitRoot(uint64_t *root);

    // Returns the set of JIT root pointers.
    const std::unordered_set<uint64_t *> &getJitRoots() const { return jit_roots; }

    // ===== Stack root ranges (temporary, frame-based) =====
    // Thin wrappers over the TLS cursor above, so every caller — runtime,
    // kernels, and the `eco_gc_*` exports generated code calls — gets the
    // inline form with no change at the call site.

    size_t stackRangePoint() const { return ecoRootRangePoint(); }

    void pushStackRootRange(HPointer* base, size_t count, uint64_t hpointer_mask) {
        // The calling thread's TLS must be published from THIS RootSet: a push
        // through a reference to another thread's RootSet would silently land
        // on the caller's stack instead.
        assert(eco_tl_root_base == range_storage_ &&
               "pushStackRootRange on a RootSet that is not the calling thread's");
        if (base && count > 0)
            ecoRootRangePush(base, count, hpointer_mask);
    }

    void restoreStackRangePoint(size_t point) { ecoRootRangeRestore(point); }

    StackRootRangeView getStackRootRanges() const {
        return StackRootRangeView{eco_tl_root_base, eco_tl_root_sp};
    }

    // Single-slot roots pushed in this thread's guarded scopes (plan §3.3).
    // The collector walks this ALONGSIDE getStackRootRanges(); both are live
    // roots and neither subsumes the other.
    SingleRootView getSingleRoots() const {
        return SingleRootView{eco_tl_root1_base, eco_tl_root1_sp};
    }

    // Storage published into TLS by Allocator::setThreadHeap — the sole writer.
    StackRootRangeRec* rangeStorage() const { return range_storage_; }
    HPointer** root1Storage() const { return root1_storage_; }

    // ===== External root scanners =====
    // Callbacks invoked during GC to discover additional roots held in
    // C++ data structures (e.g., Scheduler run queue, PlatformRuntime state).
    // The callback receives a function it must call for each uint64_t* that
    // holds an encoded HPointer needing evacuation.
    using EvacuateFn = std::function<void(uint64_t&)>;
    using ExternalRootScanner = std::function<void(EvacuateFn)>;

    void addExternalRootScanner(ExternalRootScanner scanner);

    const std::vector<ExternalRootScanner>& getExternalRootScanners() const {
        return external_scanners;
    }

    // ===== Utility =====

    // Resets to initial empty state. Used for testing.
    void reset();

private:
    std::unordered_set<HPointer *> roots;     // Long-lived roots (O(1) add/remove).
    std::unordered_set<uint64_t *> jit_roots; // JIT roots storing raw 64-bit pointers.
    std::vector<ExternalRootScanner> external_scanners; // External root callbacks.
    StackRootRangeRec* range_storage_ = nullptr;        // Range shadow-stack array.
    HPointer** root1_storage_ = nullptr;                // Single-slot shadow-stack array.
};

} // namespace Elm

#endif // ECO_ROOTSET_H
