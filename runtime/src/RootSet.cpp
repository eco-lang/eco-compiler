/**
 * RootSet Implementation.
 *
 * Simple implementation of the root set - a collection of pointer locations
 * that the GC must trace during collection. Thread-local, so no locking needed.
 */

#include "RootSet.hpp"
#include <algorithm>

namespace Elm {

// Registers a pointer location as a GC root.
void RootSet::addRoot(HPointer *root) {
    roots.push_back(root);
}

// Unregisters a pointer location from the root set.
void RootSet::removeRoot(HPointer *root) {
    roots.erase(std::remove(roots.begin(), roots.end(), root), roots.end());
}

// Clears all roots. Used for testing.
void RootSet::reset() {
    roots.clear();
    stack_roots.clear();
}

} // namespace Elm
