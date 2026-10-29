#ifndef ECO_STACKMAPROOTS_H
#define ECO_STACKMAPROOTS_H

// The collector's list of the stack slots that hold heap pointers in the frames of compiled code.
//
// Compiled code keeps some of its live heap pointers in stack slots, and the stack map (`StackMap`) records, for each
// return address, where those slots are. A walk of a thread's stack that looks each frame up in the stack map finds
// them, and the slots it keeps are roots. A moving collection updates each such slot in place, so a root here is the
// slot's address, not the pointer it holds. This header holds only the list; the walk that fills it, and when it
// runs, belong to the thread's heap (`ThreadLocalHeap`).

#include <cstddef>
#include <vector>
#include "Heap.hpp"

namespace Elm {

/**
 * The stack-map roots of one thread: the addresses of stack slots, found by walking that thread's stack, that each
 * hold an `HPointer` the collector must treat as a root.
 *
 * The slots are in live stack frames, so the list is meaningful only during the pause in which it was built: once
 * the thread runs again those frames may be gone. It is GC-internal. Runtime and kernel code must root values
 * through `RootSet` (`StackRootGuard`, `StackRootRangeGuard`), never by pushing here, and this list is separate from
 * the shadow stacks `RootSet` keeps.
 */
class StackMapRoots {
public:
    // Adds the slot `root`, which must stay valid for as long as the list is used.
    void push(HPointer* root) { roots_.push_back(root); }

    // Removes every root.
    void clear() { roots_.clear(); }

    // Returns a mark of the current length, for `restore`.
    size_t point() const { return roots_.size(); }
    // Cuts the list back to the first `p` roots, `p` being a mark from `point`. A `p` greater than the length
    // appends null slots.
    void restore(size_t p) { roots_.resize(p); }

    // Returns the roots in the order they were pushed. The reference is to the list itself and is valid while this
    // object lives; any push, clear or restore may invalidate iterators and element pointers into it.
    const std::vector<HPointer*>& get() const { return roots_; }

private:
    std::vector<HPointer*> roots_;
};

} // namespace Elm

#endif // ECO_STACKMAPROOTS_H
