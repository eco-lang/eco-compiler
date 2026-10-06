#ifndef ECO_ROOTED_SLOTS_H
#define ECO_ROOTED_SLOTS_H

// Bounded GC rooting for kernel buffers (plans/kernel-root-stack-bounded-rooting.md §2.2).
//
// A kernel that holds heap pointers in a C++ buffer across an allocation or a
// call back into Elm must root them. Pushing one shadow-stack record PER
// ELEMENT overflows the 65,536-record stack on a long list (the
// `RootStack*Test` E2E pins). `RootedSlots` roots its whole buffer with ONE
// record, whatever its size:
//
//   - the record covers the filled prefix with an all-ones mask (a range of any
//     length is all-pointer under an all-ones mask, `stackRangeSlotIsRoot`);
//   - when the buffer grows, the record's `base` and `count` are patched in
//     place. The record is this object's own; the mutator owns its shadow
//     stack, the collector reads it only inside a pause, and no GC can run
//     during the C++ reallocation, so the patch is never observed half-done;
//   - a slot the GC sees holding a null HPointer is skipped (`evacuate`).
//
// `RootedElems` holds (value, kind) elements: boxed values go to a
// `RootedSlots`, unboxed values to an untraced array (an unboxed Int must never
// be traced as a pointer).
//
// Scoping: these are LIFO with every other shadow-stack user. Destroy (or let
// go out of scope) before restoring to a point taken before construction.

#include "Heap.hpp"
#include "RootSet.hpp"
#include <cstdint>
#include <cstring>
#include <vector>

namespace Elm {
namespace alloc {

class RootedSlots {
public:
    explicit RootedSlots(size_t reserve = 0) {
        slots_.reserve(reserve);
        saved_ = ecoRootRangePoint();
        rec_ = eco_tl_root_sp;
        ecoRootRangePush(slots_.data(), 0, ~uint64_t{0});
    }

    ~RootedSlots() { ecoRootRangeRestore(saved_); }

    RootedSlots(const RootedSlots&) = delete;
    RootedSlots& operator=(const RootedSlots&) = delete;

    // Appends `hp`, which must be valid now (read since the last possible GC).
    void push(HPointer hp) {
        if (slots_.size() == slots_.capacity()) {
            slots_.push_back(hp);
            rec_->base = slots_.data();
        } else {
            slots_.push_back(hp);
        }
        rec_->count = slots_.size();
    }

    // The slots are GC-updated in place; read them after any possible GC.
    HPointer& operator[](size_t i) { return slots_[i]; }
    const HPointer& operator[](size_t i) const { return slots_[i]; }
    size_t size() const { return slots_.size(); }
    bool empty() const { return slots_.empty(); }

private:
    std::vector<HPointer> slots_;
    StackRootRangeRec* rec_;
    size_t saved_;
};

class RootedElems {
public:
    explicit RootedElems(size_t reserve = 0) : boxed_(reserve) {
        vals_.reserve(reserve);
        kinds_.reserve(reserve);
    }

    RootedElems(const RootedElems&) = delete;
    RootedElems& operator=(const RootedElems&) = delete;

    // Appends a value of slot kind `kind` (0 boxed, 1 Int, 2 Float, 3 Char).
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

    // The element's current value (a boxed one is read through the rooted slot).
    Unboxable get(size_t i) const {
        Unboxable u;
        if (kinds_[i] == 0) {
            u.p = boxed_[static_cast<size_t>(vals_[i])];
        } else {
            std::memcpy(&u, &vals_[i], sizeof(u));
        }
        return u;
    }

    u8 kind(size_t i) const { return kinds_[i]; }
    size_t size() const { return kinds_.size(); }
    bool empty() const { return kinds_.empty(); }

    // Whether every element has the same slot kind (the chunked-list path
    // needs a kind-uniform batch).
    bool uniform() const {
        for (u8 k : kinds_)
            if (k != kinds_[0]) return false;
        return true;
    }

private:
    RootedSlots boxed_;
    std::vector<uint64_t> vals_;  // unboxed bits, or the index into boxed_
    std::vector<u8> kinds_;
};

}  // namespace alloc
}  // namespace Elm

#endif  // ECO_ROOTED_SLOTS_H
