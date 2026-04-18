#ifndef ECO_STACKMAPROOTS_H
#define ECO_STACKMAPROOTS_H

#include <cstddef>
#include <vector>
#include "Heap.hpp"

namespace Elm {

/**
 * Per-thread container for stackmap-derived GC roots.
 *
 * Holds single-slot HPointer* roots discovered by walking the thread's
 * call stack via LLVM StackMaps. Cleared at the start of each GC cycle
 * by collectStackRootsFromStackMap().
 *
 * This class is GC-internal only. Runtime and kernel code must use
 * RootSet::pushStackRootRange (via StackRootGuard / StackRootRangeGuard)
 * for stack rooting.
 */
class StackMapRoots {
public:
    void push(HPointer* root) { roots_.push_back(root); }

    void clear() { roots_.clear(); }

    size_t point() const { return roots_.size(); }
    void restore(size_t p) { roots_.resize(p); }

    const std::vector<HPointer*>& get() const { return roots_; }

private:
    std::vector<HPointer*> roots_;
};

} // namespace Elm

#endif // ECO_STACKMAPROOTS_H
