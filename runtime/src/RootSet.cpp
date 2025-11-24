#include "RootSet.hpp"
#include <algorithm>

namespace Elm {

void RootSet::addRoot(HPointer *root) {
    roots.push_back(root);
}

void RootSet::removeRoot(HPointer *root) {
    roots.erase(std::remove(roots.begin(), roots.end(), root), roots.end());
}

void RootSet::addStackRoot(void *stack_ptr, size_t size) {
    stack_roots.push_back({stack_ptr, size});
}

void RootSet::clearStackRoots() {
    stack_roots.clear();
}

void RootSet::reset() {
    roots.clear();
    stack_roots.clear();
}

} // namespace Elm
