#ifndef ECO_ROOTSET_H
#define ECO_ROOTSET_H

#include <mutex>
#include <utility>
#include <vector>
#include "heap.hpp"

namespace Elm {

// Root set management
class RootSet {
public:
    void addRoot(HPointer *root);
    void removeRoot(HPointer *root);
    void addStackRoot(void *stack_ptr, size_t size);
    void clearStackRoots();

    const std::vector<HPointer *> &getRoots() const { return roots; }
    const std::vector<std::pair<void *, size_t>> &getStackRoots() const { return stack_roots; }

private:
    std::vector<HPointer *> roots;
    std::vector<std::pair<void *, size_t>> stack_roots;
    std::mutex mutex;
};

} // namespace Elm

#endif // ECO_ROOTSET_H
