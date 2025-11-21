#include "RootSet.hpp"
#include <algorithm>

namespace Elm {

void RootSet::addRoot(HPointer *root) {
    std::lock_guard<std::mutex> lock(mutex);
    roots.push_back(root);
}

void RootSet::removeRoot(HPointer *root) {
    std::lock_guard<std::mutex> lock(mutex);
    roots.erase(std::remove(roots.begin(), roots.end(), root), roots.end());
}

void RootSet::addStackRoot(void *stack_ptr, size_t size) {
    std::lock_guard<std::mutex> lock(mutex);
    stack_roots.push_back({stack_ptr, size});
}

void RootSet::clearStackRoots() {
    std::lock_guard<std::mutex> lock(mutex);
    stack_roots.clear();
}

void RootSet::reset() {
    std::lock_guard<std::mutex> lock(mutex);
    roots.clear();
    stack_roots.clear();
}

} // namespace Elm
