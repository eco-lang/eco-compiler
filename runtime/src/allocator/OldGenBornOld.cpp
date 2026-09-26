// threaded-gc-04 (plans/threaded-gc-04-frozen-published-heap.md Step 7b,
// HEAP_061): mark-end maintenance of OldGenSpace's born-old pending list.
// Kept out of OldGenSpace.cpp so that file's mark loop stays where it is
// (the -falign-loops trap, threaded-gc-01 P§9a.13).

#include "OldGenSpace.hpp"

namespace Elm {

void OldGenSpace::pruneBornOldAtMarkEnd() {
    if (born_old_.empty()) return;
    std::vector<BornOld> kept;
    kept.reserve(born_old_.size());
    auto marked = [&](const char* obj) {
        const BlockId id = blockIdFor(obj);
        return id.valid() && isMarkedInBlock(id, obj);
    };
    for (const BornOld& b : born_old_) {
        if (!b.region) {
            if (marked(b.obj)) kept.push_back(b);
            continue;
        }
        // A region's objects are marked one by one; its dead parts may be
        // freed and reused by the next sweep, so keep only the live objects.
        for (char* p = b.obj; p < b.obj + b.size;) {
            const size_t sz = getObjectSize(p);
            if (sz == 0) break;
            if (marked(p)) {
                kept.push_back(BornOld{p, static_cast<uint32_t>(sz), 0, b.quiet_minors});
            }
            p += sz;
        }
    }
    born_old_.swap(kept);
}

} // namespace Elm
