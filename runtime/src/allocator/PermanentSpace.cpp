// `eco_caf_promote` copies a value graph in two phases, so that giving up never leaves anything
// reachable half-done.
//
// Phase 1 walks the graph from the root with `visitHeapChildren`, following every child slot that holds
// a heap pointer, and records each object once. It allocates nothing. Any object it cannot copy (a large
// String or Bytes header, whose body is not a heap object, or a tag the walk declines) refuses the whole
// value, which then stays on the heap and is rooted.
//
// Phase 2a allocates a permanent block for each recorded object, copies the object into it, and records
// the original-to-copy map. Phase 2b walks each copy with the same filter as phase 1 and rewrites each
// heap pointer to the copy of its target. Because the filters agree, every target is in the map; a miss,
// or running out of permanent space in phase 2a, abandons the copies already made. They are unreachable,
// so they are only counted.

#include "PermanentSpace.hpp"
#include "HeapChildWalk.hpp"

#include "Allocator.hpp"
#include "AllocatorCommon.hpp"
#include "Heap.hpp"
#include "PlatformVirtualMemory.hpp"
#include "RootSet.hpp"

#include <cstdlib>
#include <cstring>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace Elm {

// The size of the permanent space's address reservation: 8 GiB, the most it can ever hold.
static constexpr std::size_t kPermanentReserve = 8ull << 30;
// How much of the reservation `allocate` commits at a time when it needs more: 16 MiB.
static constexpr std::size_t kPermanentCommitStep = 16ull << 20;

PermanentSpace &PermanentSpace::instance() {
    static PermanentSpace s;
    return s;
}

bool PermanentSpace::ensureReservedLocked() {
    if (base_.load(std::memory_order_relaxed) != nullptr)
        return true;
    // Below the HPointer address limit, so a permanent address fits an HPointer word. The reservation is
    // not at a fixed address, so it cannot overlap the heap's mapping, which keeps isInHeap false for it.
    void *p = Elm::platform::reserveAddressSpaceBelow(kPermanentReserve,
                                                      HPOINTER_ADDRESS_LIMIT);
    if (p == nullptr)
        return false;
    reserved_ = kPermanentReserve;
    base_.store(static_cast<char *>(p), std::memory_order_release);
    return true;
}

void *PermanentSpace::allocate(std::size_t bytes) {
    bytes = (bytes + 7) & ~static_cast<std::size_t>(7);
    std::lock_guard<std::mutex> lock(mutex_);
    if (!ensureReservedLocked())
        return nullptr;
    std::size_t used = used_.load(std::memory_order_relaxed);
    if (used + bytes > reserved_)
        return nullptr;
    while (used + bytes > committed_) {
        std::size_t step = kPermanentCommitStep;
        if (committed_ + step > reserved_)
            step = reserved_ - committed_;
        if (step == 0 ||
            Elm::platform::commitAt(base_.load(std::memory_order_relaxed) +
                                        committed_,
                                    step) == nullptr)
            return nullptr;
        committed_ += step;
    }
    void *r = base_.load(std::memory_order_relaxed) + used;
    used_.store(used + bytes, std::memory_order_release);
    return r;
}

} // namespace Elm

extern "C" std::uint64_t eco_caf_promote(std::uint64_t bits,
                                         std::uint64_t *slot) {
    using namespace Elm;

    static const bool enabled = [] {
        const char *e = std::getenv("ECO_CAF_PERMANENT");
        return e == nullptr || e[0] != '0';
    }();

    Allocator &alloc = Allocator::instance();
    PermanentSpace &perm = PermanentSpace::instance();

    // Roots the slot, for a value that stays on the heap.
    const auto rootSlot = [&] {
        alloc.getRootSet().addJitRoot(slot);
        perm.stats.slots_rooted++;
    };

    // Embedded constants are never rooted, in either mode.
    if (isConstantBits(bits)) {
        perm.stats.values_constant++;
        return bits;
    }

    if (!enabled) {
        rootSlot();
        return bits;
    }

    void *root = alloc.resolve(hpFromBits(bits));
    if (root == nullptr || !alloc.isInHeap(root)) {
        perm.stats.values_constant++;
        return bits;
    }

    // Phase 1: record the graph, allocating nothing.
    std::vector<void *> order;
    std::unordered_set<void *> visited;
    std::vector<void *> work;
    work.push_back(root);
    visited.insert(root);
    bool supported = true;
    while (!work.empty() && supported) {
        void *o = work.back();
        work.pop_back();
        order.push_back(o);
        // A large String or Bytes body has no header and is not a heap object, so it cannot be copied.
        {
            const u32 t = static_cast<Header *>(o)->tag;
            if (t == Tag_LargeStringHeader || t == Tag_LargeByteHeader) {
                supported = false;
                break;
            }
        }
        supported = visitHeapChildren(o, [&](HPointer &hp) {
            if (hp.ptr_ind != 0 || hp.ptr == 0)
                return; // constant or null
            void *c = alloc.resolve(hp);
            if (c == nullptr || !alloc.isInHeap(c))
                return;
            if (visited.insert(c).second)
                work.push_back(c);
        });
    }
    if (!supported) {
        perm.stats.values_declined++;
        rootSlot();
        return bits;
    }

    // Phase 2a: copy each object and map original to copy.
    std::unordered_map<void *, void *> map;
    map.reserve(order.size() * 2);
    std::size_t total = 0;
    for (void *o : order) {
        std::size_t sz = getObjectSize(o);
        void *c = perm.allocate(sz);
        if (c == nullptr) {
            perm.stats.values_declined++;
            perm.stats.bytes_abandoned += total;
            rootSlot();
            return bits;
        }
        std::memcpy(c, o, sz);
        map.emplace(o, c);
        total += sz;
    }

    // Phase 2b: point the copies at each other.
    bool fixed = true;
    for (void *o : order) {
        void *c = map[o];
        bool r = visitHeapChildren(c, [&](HPointer &hp) {
            if (!fixed || hp.ptr_ind != 0 || hp.ptr == 0)
                return; // constant or null, kept as copied
            void *t = alloc.resolve(hp);
            if (t == nullptr || !alloc.isInHeap(t))
                return;
            auto it = map.find(t);
            if (it == map.end()) {
                fixed = false; // the filter differs from phase 1's
                return;
            }
            hp = hpFromBits(reinterpret_cast<std::uint64_t>(it->second));
        });
        if (!r || !fixed) {
            fixed = false;
            break;
        }
    }
    if (!fixed) {
        perm.stats.values_declined++;
        perm.stats.bytes_abandoned += total;
        rootSlot();
        return bits;
    }

    perm.stats.values_promoted++;
    perm.stats.objects_copied += order.size();
    perm.stats.bytes_copied += total;
    return reinterpret_cast<std::uint64_t>(map[root]);
}
