#ifndef ECO_ROOTSET_H
#define ECO_ROOTSET_H

#include <cstddef>
#include <utility>
#include <vector>
#include "Heap.hpp"

namespace Elm {

/**
 * Tracks GC roots: pointers into the heap that must be scanned during collection.
 *
 * Maintains both explicit roots (registered HPointer locations) and stack roots
 * (memory regions containing potential pointers). Each thread has its own RootSet
 * in its NurserySpace, so no mutex is needed.
 */
class RootSet {
public:
    // Registers a pointer location as a GC root.
    void addRoot(HPointer *root);

    // Unregisters a pointer location from the root set.
    void removeRoot(HPointer *root);

    // Registers a stack region to scan for pointers during GC.
    void addStackRoot(void *stack_ptr, size_t size);

    // Clears all registered stack roots.
    void clearStackRoots();

    // Resets to initial empty state. Used for testing.
    void reset();

    // Returns the list of registered root pointers.
    const std::vector<HPointer *> &getRoots() const { return roots; }

    // Returns the list of registered stack regions.
    const std::vector<std::pair<void *, size_t>> &getStackRoots() const { return stack_roots; }

private:
    std::vector<HPointer *> roots;                      // Registered pointer locations.
    std::vector<std::pair<void *, size_t>> stack_roots; // Stack regions to scan.
};

} // namespace Elm

#endif // ECO_ROOTSET_H
