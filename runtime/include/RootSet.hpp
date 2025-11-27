#ifndef ECO_ROOTSET_H
#define ECO_ROOTSET_H

#include <cstddef>
#include <vector>
#include "Heap.hpp"

namespace Elm {

/**
 * Tracks GC roots: pointers into the heap that must be scanned during collection.
 *
 * Maintains two types of roots:
 * - Long-lived roots: Registered with addRoot/removeRoot, persist across GC cycles.
 * - Stack roots: Temporary roots pushed/popped as functions execute.
 *
 * Each thread has its own RootSet in its NurserySpace, so no mutex is needed.
 */
class RootSet {
public:
    // ===== Long-lived roots =====

    // Registers a pointer location as a GC root.
    void addRoot(HPointer *root);

    // Unregisters a pointer location from the root set.
    void removeRoot(HPointer *root);

    // Returns the list of registered root pointers.
    const std::vector<HPointer *> &getRoots() const { return roots; }

    // ===== Stack roots (temporary, frame-based) =====

    // Returns the current stack root point (for later restoration).
    size_t stackRootPoint() const { return stack_roots.size(); }

    // Pushes a new stack root.
    void pushStackRoot(HPointer *root) { stack_roots.push_back(root); }

    // Replaces the value stored at the top stack root location.
    void replaceHead(HPointer new_value) {
        if (!stack_roots.empty()) {
            *stack_roots.back() = new_value;
        }
    }

    // Restores to a previous stack root point, discarding all pushes since.
    void restoreStackRootPoint(size_t point) { stack_roots.resize(point); }

    // Returns the list of stack root pointers.
    const std::vector<HPointer *> &getStackRoots() const { return stack_roots; }

    // ===== Utility =====

    // Resets to initial empty state. Used for testing.
    void reset();

private:
    std::vector<HPointer *> roots;        // Long-lived roots.
    std::vector<HPointer *> stack_roots;  // Temporary stack roots.
};

} // namespace Elm

#endif // ECO_ROOTSET_H
