#ifndef ECO_ROOTED_SLOTS_H
#define ECO_ROOTED_SLOTS_H

// Roots for a growable C++ buffer of heap values, held by one shadow-stack record however many
// values it holds.
//
// A kernel that keeps heap pointers in a C++ buffer across an allocation, or across a call back into
// Elm, must root them, because a collection may move the objects and rewrites only the slots it knows
// about. Rooting each element with its own shadow-stack record would exhaust the range stack, which
// holds `kRootRangeStackSlots` records, on a long enough list.
//
// A `RootedSlots` therefore pushes a single record over its whole buffer. The record's mask is all
// ones, and under an all-ones mask every slot of a range is a root whatever its length
// (`stackRangeSlotIsRoot`). Each append updates the record's `count`, and an append that moves the
// buffer also updates its `base`. Those updates are plain stores from the owning thread, made while
// the program cannot collect.
//
// A `RootedElems` holds values that may be boxed or unboxed, each with its slot kind. Boxed values go
// into a `RootedSlots`; unboxed ones go into an array the collector never sees, because an unboxed
// Int's bits must never be traced as a pointer.
//
// Both types push onto the calling thread's range stack on construction and pop on destruction
// (RootedElems through its RootedSlots member), so they nest last-in first-out with every other
// user of that stack. One must be destroyed before the stack is
// restored to a point taken before it was constructed.

#include "Heap.hpp"
#include "RootSet.hpp"
#include <cstdint>
#include <cstring>
#include <vector>

namespace Elm {
namespace alloc {

/**
 * A growable sequence of `HPointer` slots that the collector treats as roots for as long as the
 * object lives, rewriting them when it moves what they point to.
 *
 * Construction pushes one range record onto the calling thread's range stack, and destruction pops
 * the stack back to where it was before. The object must be used and destroyed on the thread that
 * made it, and destroyed before that stack is restored to a point taken before construction. It
 * is neither copyable nor movable.
 */
class RootedSlots {
public:
    // Creates an empty sequence with room for `reserve` slots before its buffer must move, and
    // pushes its record onto the calling thread's range stack.
    explicit RootedSlots(size_t reserve = 0) {
        slots_.reserve(reserve);
        saved_ = ecoRootRangePoint();
        rec_ = eco_tl_root_sp;
        ecoRootRangePush(slots_.data(), 0, ~uint64_t{0});
    }

    ~RootedSlots() { ecoRootRangeRestore(saved_); }

    RootedSlots(const RootedSlots&) = delete;
    RootedSlots& operator=(const RootedSlots&) = delete;

    // Appends `hp` as a new rooted slot.
    //
    // `hp` must be current: read since the last point at which a collection could have run. An
    // append may move the buffer, which invalidates every reference `operator[]` returned.
    void push(HPointer hp) {
        if (slots_.size() == slots_.capacity()) {
            slots_.push_back(hp);
            rec_->base = slots_.data();
        } else {
            slots_.push_back(hp);
        }
        rec_->count = slots_.size();
    }

    // Returns slot `i`, which must be less than `size()`.
    //
    // A collection rewrites the slot in place, so a value read from it is stale after any point
    // that may collect. The reference itself is valid until the next `push` or destruction.
    HPointer& operator[](size_t i) { return slots_[i]; }
    // Returns slot `i` for reading, as the non-const overload does.
    const HPointer& operator[](size_t i) const { return slots_[i]; }
    // Returns the number of slots appended.
    size_t size() const { return slots_.size(); }
    // Returns whether no slot has been appended.
    bool empty() const { return slots_.empty(); }

private:
    std::vector<HPointer> slots_;
    // This object's own record on the range stack; it stays at the same address until the
    // destructor pops it.
    StackRootRangeRec* rec_;
    // The range stack's restore point from before the record was pushed.
    size_t saved_;
};

/**
 * A growable sequence of values, each boxed or unboxed, in which the boxed values are rooted.
 *
 * Each element carries its slot kind: 0 for a boxed `HPointer`, 1 for an Int, 2 for a Float and 3
 * for a Char. Only the boxed elements are visible to the collector, through a `RootedSlots` this
 * object owns, so it has the same thread and nesting rules as `RootedSlots`. It is neither
 * copyable nor movable.
 */
class RootedElems {
public:
    // Creates an empty sequence with room for `reserve` elements, and pushes the record that roots
    // its boxed elements onto the calling thread's range stack.
    explicit RootedElems(size_t reserve = 0) : boxed_(reserve) {
        vals_.reserve(reserve);
        kinds_.reserve(reserve);
    }

    RootedElems(const RootedElems&) = delete;
    RootedElems& operator=(const RootedElems&) = delete;

    // Appends `v` with slot kind `kind`, which says which member of `v` is live.
    //
    // For kind 0, `v.p` must be current, as for `RootedSlots::push`. Any other kind is stored as
    // `v`'s raw bits; nothing checks that `kind` is in the range 0 to 3.
    void push(Unboxable v, u8 kind) {
        if (kind == 0) {
            vals_.push_back(boxed_.size());
            boxed_.push(v.p);
        } else {
            uint64_t bits;
            std::memcpy(&bits, &v, sizeof(bits));
            vals_.push_back(bits);
        }
        kinds_.push_back(kind);
    }

    // Returns element `i`, which must be less than `size()`.
    //
    // A boxed element is read from its rooted slot, so it reflects any collection since it was
    // appended. An unboxed element is returned with the bits it was appended with.
    Unboxable get(size_t i) const {
        Unboxable u;
        if (kinds_[i] == 0) {
            u.p = boxed_[static_cast<size_t>(vals_[i])];
        } else {
            std::memcpy(&u, &vals_[i], sizeof(u));
        }
        return u;
    }

    // Returns the slot kind element `i` was appended with.
    u8 kind(size_t i) const { return kinds_[i]; }
    // Returns the number of elements appended.
    size_t size() const { return kinds_.size(); }
    // Returns whether no element has been appended.
    bool empty() const { return kinds_.empty(); }

    // Returns whether every element has the same slot kind. An empty sequence is uniform.
    bool uniform() const {
        for (u8 k : kinds_)
            if (k != kinds_[0]) return false;
        return true;
    }

private:
    RootedSlots boxed_;
    std::vector<uint64_t> vals_;  // An unboxed element's bits, or a boxed one's index in boxed_.
    std::vector<u8> kinds_;
};

}  // namespace alloc
}  // namespace Elm

#endif  // ECO_ROOTED_SLOTS_H
