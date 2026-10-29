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

// The collector must find every HPointer that something outside the heap still needs, and this component
// holds the roots that no stack map describes.
//
// A collection may move any nursery object, so every place that holds an HPointer across an allocation must
// be known to the collector, which rewrites it. Compiled Elm frames are described by stack maps, and those
// roots are not here (`StackMapRoots` holds them, and runtime or kernel code must not push into it). Every
// other root is one of four kinds, and a heap's `RootSet` holds all four:
//
// - A long-lived root is the address of an HPointer slot, such as a global, registered until it is
//   removed.
// - A JIT root is the address of a 64-bit word holding a raw heap address. A heap object's HPointer is its
//   address, so the word has the same bits; the collectors read these through their own raw-word paths.
// - An external root scanner is a callback that reports the HPointer words held in some C++ structure each
//   time the roots are scanned.
// - A shadow-stack root is pushed and popped by a running scope.
//
// There are two shadow stacks, and both live in thread-local storage. The range stack holds 24-byte
// records, each naming a run of 64-bit slots and a mask saying which of them hold HPointers. The
// single-slot stack holds the addresses of single HPointer slots, 8 bytes each. Each stack is three TLS
// words: `base`, the start of its array; `limit`, the end of the usable part; and `sp`, the cursor, one
// past the newest entry. A push writes at the cursor and advances it. A restore point is the cursor value
// itself, so restoring is one store. Pushes and restores must nest: a scope restores to the point it took
// before its pushes, after every scope it contains has done the same.
//
// A `RootSet` owns the arrays behind both stacks. `Allocator::setThreadHeap` points the TLS words at a
// `RootSet`'s arrays. Until it has, the inline push and restore functions below have nowhere to write.
//
// The bounds check on a push exists only in builds with assertions or `ECO_HEAP_VALIDATE`. Each array has
// slack past its limit and an inaccessible guard page after its page-rounded end, so an overflow in any
// other build that advances one entry at a time lands in the slack or padding, or faults.

namespace Elm {

/**
 * One entry of the range shadow stack: a run of `count` 64-bit slots starting at `base`, with
 * `hpointer_mask` saying which of them the collector treats as HPointer roots.
 *
 * For a slot index below 64, bit `i` of the mask decides; beyond that, only an all-ones mask makes a slot
 * a root (see `stackRangeSlotIsRoot`). A range whose slots all hold HPointers can therefore use `~0` for
 * any `count`. The layout is fixed: AOT-compiled code writes `base` at offset 0, `count` at 8 and the mask at
 * 16, and advances the cursor by 24 bytes. The code generator's root-range expansion
 * (`expandRootRangeOps` in `EcoBackend.cpp`) must change with this struct; the `static_assert`s below
 * check only the C++ side.
 */
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

// Returns whether slot `i` of a range with mask `mask` is a root: bit `i` of the mask for `i` below 64,
// and otherwise whether the mask is all ones.
inline bool stackRangeSlotIsRoot(uint64_t mask, size_t i) {
    // Written out because `1ULL << i` is undefined for i >= 64.
    return i < 64 ? ((mask >> i) & 1) != 0 : mask == ~uint64_t{0};
}

// The six TLS words of the two shadow stacks, as the file comment describes. They have C linkage and the
// initial-exec TLS model, and are constant-initialised to null, so compiled code reads them directly by
// name with no initialisation guard. `Allocator::setThreadHeap` sets the base and limit words; the
// cursors are also moved by the push and restore functions below.
extern "C" {
// The range stack's cursor: one past the newest record.
extern thread_local StackRootRangeRec* eco_tl_root_sp
    __attribute__((tls_model("initial-exec")));
// The first record of the range stack's array.
extern thread_local StackRootRangeRec* eco_tl_root_base
    __attribute__((tls_model("initial-exec")));
// One past the last usable record of the range stack; the slack lies beyond it.
extern thread_local StackRootRangeRec* eco_tl_root_limit
    __attribute__((tls_model("initial-exec")));

// The single-slot stack is kept separate from the range stack so that compiled code, which pushes only
// ranges, moves one cursor and never needs to save the other.
// The single-slot stack's cursor: one past the newest slot address.
extern thread_local HPointer** eco_tl_root1_sp
    __attribute__((tls_model("initial-exec")));
// The first entry of the single-slot stack's array.
extern thread_local HPointer** eco_tl_root1_base
    __attribute__((tls_model("initial-exec")));
// One past the last usable entry of the single-slot stack; the slack lies beyond it.
extern thread_local HPointer** eco_tl_root1_limit
    __attribute__((tls_model("initial-exec")));
}

// Reports a shadow-stack overflow at `depth` entries on standard error and aborts the process.
//
// The message names `kRootRangeStackSlots` as the capacity, whichever stack overflowed.
[[noreturn]] void ecoRootStackOverflow(std::size_t depth);

// The number of usable records in a `RootSet`'s range stack.
inline constexpr std::size_t kRootRangeStackSlots = 65536;
// The number of records allocated past the range stack's limit, so that an overflow in a build without the
// bounds check lands in memory the `RootSet` owns.
inline constexpr std::size_t kRootRangeStackSlack = 1024;

// The number of usable entries in a `RootSet`'s single-slot stack.
inline constexpr std::size_t kRoot1StackSlots = 65536;
// The number of entries allocated past the single-slot stack's limit, for the same reason as
// `kRootRangeStackSlack`.
inline constexpr std::size_t kRoot1StackSlack = 1024;

// Returns a restore point for the calling thread's range stack.
//
// The value is the cursor's address, not a depth or an index, so it means nothing except as an argument
// to `ecoRootRangeRestore`.
inline std::size_t ecoRootRangePoint() noexcept {
    return reinterpret_cast<std::size_t>(eco_tl_root_sp);
}

// Pops the calling thread's range stack back to `point`, a value from `ecoRootRangePoint`.
//
// A point above the current cursor is ignored, so restoring twice, or restoring to a point taken inside a
// scope that an outer scope has already popped, cannot make popped records live again.
inline void ecoRootRangeRestore(std::size_t point) noexcept {
    auto* p = reinterpret_cast<StackRootRangeRec*>(point);
    if (p <= eco_tl_root_sp)
        eco_tl_root_sp = p;
}

// Pushes the range of `count` slots at `base`, with mask `hpointer_mask`, onto the calling thread's range
// stack.
//
// The slots must stay valid until the range is popped, and the collector rewrites the slots the mask
// marks. The record is pushed even when `count` is 0. With assertions or `ECO_HEAP_VALIDATE` on, a push at
// the limit calls `ecoRootStackOverflow`; otherwise it is not checked.
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

// Returns a restore point for the calling thread's single-slot stack, for `ecoRoot1Restore`.
inline HPointer** ecoRoot1Point() noexcept { return eco_tl_root1_sp; }

// Pops the calling thread's single-slot stack back to `p`, ignoring a point above the cursor as
// `ecoRootRangeRestore` does.
inline void ecoRoot1Restore(HPointer** p) noexcept {
    if (p <= eco_tl_root1_sp)
        eco_tl_root1_sp = p;
}

// Pushes the HPointer slot `slot` onto the calling thread's single-slot stack.
//
// The slot must stay valid until it is popped. The overflow check is as for `ecoRootRangePush`.
inline void ecoRoot1Push(HPointer* slot) noexcept {
    HPointer** sp = eco_tl_root1_sp;
#if ECO_HEAP_VALIDATE || !defined(NDEBUG)
    if (sp >= eco_tl_root1_limit)
        ecoRootStackOverflow(static_cast<std::size_t>(sp - eco_tl_root1_base));
#endif
    *sp = slot;
    eco_tl_root1_sp = sp + 1;
}

/**
 * A restore point for both shadow stacks at once, for a scope that may push to either: `range` is the
 * range stack's cursor and `one` the single-slot stack's cursor, not a count.
 */
struct EcoRootMark {
    StackRootRangeRec* range;
    HPointer** one;
};

// Returns a restore point for both of the calling thread's shadow stacks, for `ecoRootRelease`.
inline EcoRootMark ecoRootMark() noexcept {
    return EcoRootMark{eco_tl_root_sp, eco_tl_root1_sp};
}

// Pops both of the calling thread's shadow stacks back to `m`, ignoring either point if it is above that
// stack's cursor.
inline void ecoRootRelease(EcoRootMark m) noexcept {
    if (m.range <= eco_tl_root_sp)
        eco_tl_root_sp = m.range;
    if (m.one <= eco_tl_root1_sp)
        eco_tl_root1_sp = m.one;
}

/**
 * The live entries of a single-slot stack, from its base to its cursor, as a range of slot addresses.
 *
 * It does not own the entries. It describes the stack as it was when the view was made, and is stale once
 * that stack is pushed or popped.
 */
struct SingleRootView {
    HPointer* const* b;
    HPointer* const* e;
    // Returns the oldest entry.
    HPointer* const* begin() const { return b; }
    // Returns one past the newest entry.
    HPointer* const* end() const { return e; }
    // Returns the number of entries.
    std::size_t size() const { return static_cast<std::size_t>(e - b); }
    // Returns whether there are no entries.
    bool empty() const { return b == e; }
};

/**
 * The live records of a range stack, from its base to its cursor.
 *
 * It does not own the records, and is stale once that stack is pushed or popped, as for `SingleRootView`.
 */
struct StackRootRangeView {
    const StackRootRangeRec* b;
    const StackRootRangeRec* e;
    // Returns the oldest record.
    const StackRootRangeRec* begin() const { return b; }
    // Returns one past the newest record.
    const StackRootRangeRec* end() const { return e; }
    // Returns the number of records.
    std::size_t size() const { return static_cast<std::size_t>(e - b); }
    // Returns whether there are no records.
    bool empty() const { return b == e; }
    // Returns record `i`, counting from the oldest. `i` must be less than `size()`.
    const StackRootRangeRec& operator[](std::size_t i) const { return b[i]; }
};

/**
 * The roots of one heap that are not in stack maps: long-lived roots, JIT roots, external root scanners,
 * and the storage of the two shadow stacks, as the file comment describes.
 *
 * A `RootSet` owns its two shadow-stack arrays from construction until destruction. The constructor throws
 * `std::bad_alloc` if either cannot be mapped. A `RootSet` cannot be copied or moved, because the TLS
 * cursors point into its arrays. The shadow-stack accessors read and write the calling thread's TLS words,
 * not this object's arrays directly, so they describe this `RootSet` only on a thread whose TLS
 * `Allocator::setThreadHeap` has pointed at it. The destructor clears the calling thread's TLS words if
 * they still point at this `RootSet`'s arrays, then unmaps both.
 *
 * Nothing here takes a lock.
 */
class RootSet {
public:
    // Another name for `StackRootRangeRec`.
    using StackRootRange = StackRootRangeRec;

    // Maps the two shadow-stack arrays, each with its slack and a trailing guard page.
    RootSet();
    ~RootSet();

    RootSet(const RootSet&) = delete;
    RootSet& operator=(const RootSet&) = delete;

    // ========== Long-lived roots ==========

    // Registers `root`, the address of an HPointer slot, as a root until `removeRoot`.
    //
    // The slot must stay valid while registered. Registering the same address twice registers it once.
    void addRoot(HPointer *root);

    // Unregisters `root`. An address that is not registered is ignored.
    void removeRoot(HPointer *root);

    // Returns the registered long-lived roots. The reference is to this object's set, which `addRoot`,
    // `removeRoot` and `reset` change.
    const std::unordered_set<HPointer *> &getRoots() const { return roots; }

    // ========== JIT roots ==========

    // Registers `root`, the address of a 64-bit word holding a raw heap address, as a root until
    // `removeJitRoot`.
    //
    // The word must stay valid while registered. Registering the same address twice registers it once.
    void addJitRoot(uint64_t *root);

    // Unregisters `root`. An address that is not registered is ignored.
    void removeJitRoot(uint64_t *root);

    // Returns the registered JIT roots. The reference is to this object's set, which `addJitRoot`,
    // `removeJitRoot` and `reset` change.
    const std::unordered_set<uint64_t *> &getJitRoots() const { return jit_roots; }

    // ========== Shadow stacks ==========

    // Returns a restore point for the calling thread's range stack, as `ecoRootRangePoint` does.
    size_t stackRangePoint() const { return ecoRootRangePoint(); }

    // Pushes a range onto the calling thread's range stack as `ecoRootRangePush` does, except that a null
    // `base` or a `count` of 0 pushes nothing.
    //
    // The calling thread's range stack must be this `RootSet`'s; that is asserted.
    void pushStackRootRange(HPointer* base, size_t count, uint64_t hpointer_mask) {
        assert(eco_tl_root_base == range_storage_ &&
               "pushStackRootRange on a RootSet that is not the calling thread's");
        if (base && count > 0)
            ecoRootRangePush(base, count, hpointer_mask);
    }

    // Pops the calling thread's range stack back to `point`, as `ecoRootRangeRestore` does.
    void restoreStackRangePoint(size_t point) { ecoRootRangeRestore(point); }

    // Returns a view of the calling thread's range stack.
    StackRootRangeView getStackRootRanges() const {
        return StackRootRangeView{eco_tl_root_base, eco_tl_root_sp};
    }

    // Returns a view of the calling thread's single-slot stack. Its entries are roots as well as those of
    // `getStackRootRanges`; neither stack includes the other.
    SingleRootView getSingleRoots() const {
        return SingleRootView{eco_tl_root1_base, eco_tl_root1_sp};
    }

    // Returns the first record of this object's range-stack array, for `Allocator::setThreadHeap` to
    // publish. It stays valid until this object is destroyed.
    StackRootRangeRec* rangeStorage() const { return range_storage_; }
    // Returns the first entry of this object's single-slot-stack array, for `Allocator::setThreadHeap` to
    // publish. It stays valid until this object is destroyed.
    HPointer** root1Storage() const { return root1_storage_; }

    // ========== External root scanners ==========

    // A function a scanner calls once for each 64-bit word it holds that contains an HPointer. The
    // function may rewrite the word, to the object's new address.
    using EvacuateFn = std::function<void(uint64_t&)>;
    // A callback that reports the HPointer words held by some C++ structure, by calling the `EvacuateFn`
    // it is given on each of them. It is called each time this heap's roots are scanned.
    using ExternalRootScanner = std::function<void(EvacuateFn)>;

    // Registers `scanner` under `name`, which labels it in per-scanner statistics.
    //
    // `name` is kept, so it must have static lifetime. A null `name`, or one equal to `"unnamed"`, is
    // replaced by a label built from the caller's return address: `unnamed@` followed by the enclosing
    // symbol name if `dladdr` finds one, otherwise the offset within the loaded object, otherwise the
    // address. A scanner cannot be removed except by `reset`.
    void addExternalRootScanner(ExternalRootScanner scanner,
                                const char* name = "unnamed");

    // Returns the registered scanners, in registration order. The reference is to this object's vector,
    // which `addExternalRootScanner` and `reset` change.
    const std::vector<ExternalRootScanner>& getExternalRootScanners() const {
        return external_scanners;
    }

    // Returns the scanners' names, element `i` naming scanner `i` of `getExternalRootScanners`.
    const std::vector<const char*>& getExternalRootScannerNames() const {
        return external_scanner_names;
    }

    // Removes every long-lived root, JIT root and external scanner, and, if the calling thread's TLS points
    // at this object's arrays, empties both shadow stacks.
    void reset();

private:
    std::unordered_set<HPointer *> roots;
    std::unordered_set<uint64_t *> jit_roots;
    std::vector<ExternalRootScanner> external_scanners;
    std::vector<const char*> external_scanner_names;    // Same length and order as `external_scanners`.
    // The two shadow-stack arrays, owned, mapped by the constructor and unmapped by the destructor.
    StackRootRangeRec* range_storage_ = nullptr;
    HPointer** root1_storage_ = nullptr;
};

} // namespace Elm

#endif // ECO_ROOTSET_H
