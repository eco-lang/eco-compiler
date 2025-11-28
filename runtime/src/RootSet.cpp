/**
 * RootSet Implementation.
 *
 * Simple implementation of the root set - a collection of pointer locations
 * that the GC must trace during collection. Thread-local, so no locking needed.
 *
 * Uses unordered_set for O(1) add/remove of long-lived roots.
 */

#include "RootSet.hpp"

namespace Elm {

// Registers a pointer location as a GC root. O(1) average.
void RootSet::addRoot(HPointer *root) {
    roots.insert(root);
}

// Unregisters a pointer location from the root set. O(1) average.
void RootSet::removeRoot(HPointer *root) {
    roots.erase(root);
}

// Clears all roots. Used for testing.
void RootSet::reset() {
    roots.clear();
    stack_roots.clear();
}

} // namespace Elm
